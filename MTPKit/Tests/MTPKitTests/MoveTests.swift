import Foundation
import Testing
@testable import MTPKit

/// MoveObject on the session and the fake phone (AOSP doMoveObject rules), and the move plan built on it (FMGT-04).
@Suite struct MoveTests {
    static let phone = UInt32(0x0001_0001)   // internal storage
    static let root = UInt32(0xFFFF_FFFF)

    private func openedSession(_ fake: sending FakeAndroidResponder) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// The default tree plus `extra` objects (handles from 11 up).
    private static func tree(_ extra: [FakeObject]) -> [FakeObject] { FakeAndroidResponder.defaultObjects + extra }

    private static func file(_ h: UInt32, in parent: UInt32, _ name: String, size: UInt64 = 100) -> FakeObject {
        FakeObject(handle: h, storageID: phone, parent: parent, name: name, format: 0x3000, size: size, modified: "20250101T000000")
    }

    private static func folder(_ h: UInt32, in parent: UInt32, _ name: String) -> FakeObject {
        FakeObject(handle: h, storageID: phone, parent: parent, name: name, format: 0x3001, size: 0, modified: "20250101T000000")
    }

    private static func refused(_ code: UInt16) -> MTPError { .response(code: code, op: MTPOp.moveObject) }

    // MARK: MoveObject (Task 1)

    @Test func moveIntoAFolderKeepsTheHandle() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        try await session.move(5, storage: Self.phone, to: 1)
        let moved = try #require(try await session.entry(5))
        #expect(moved.parent == 1 && moved.name == "IMG_2.jpg")
        #expect(try await session.children(storage: Self.phone, parent: 1).contains { $0.id == 5 })
        #expect(try await !session.children(storage: Self.phone).contains { $0.id == 5 })
    }

    /// Pitfall 10: the fake answers 0x2009 for a raw 0xFFFFFFFF parent, so success proves the root went out as 0.
    @Test func moveToTheRootSendsParentZero() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        try await session.move(9, storage: Self.phone, to: Self.root)
        #expect(try await session.entry(9)?.parent == Self.root)
    }

    @Test func anExactNameClashIsGeneralErrorAndKeepsBoth() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")]))
        let session = try await openedSession(fake)
        await #expect(throws: Self.refused(MTPCode.generalError)) { try await session.move(5, storage: Self.phone, to: 1) }
        #expect(fake.objects.first { $0.handle == 5 }?.parent == Self.root)
        #expect(fake.objects.first { $0.handle == 11 }?.parent == 1)
    }

    /// Pitfall 11: AOSP checks the name case-sensitively and rename(2) then overwrites, so Move.plan must check names.
    @Test func aCaseVariantClobbersOnACaseInsensitivePhone() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "img_2.JPG")]),
                                                            caseInsensitiveNames: true)
        let session = try await openedSession(fake)
        try await session.move(5, storage: Self.phone, to: 1)
        #expect(fake.clobbered == [11])
        #expect(fake.objects.first { $0.handle == 5 }?.parent == 1)
    }

    @Test func aFileAsParentIsInvalidParentObject() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        await #expect(throws: Self.refused(0x201A)) { try await session.move(5, storage: Self.phone, to: 7) }
        #expect(fake.objects.first { $0.handle == 5 }?.parent == Self.root)
    }

    @Test func intoItsOwnSubtreeIsGeneralError() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.folder(11, in: Self.root, "A"),
                                                                                Self.folder(12, in: 11, "B")]))
        let session = try await openedSession(fake)
        await #expect(throws: Self.refused(MTPCode.generalError)) { try await session.move(11, storage: Self.phone, to: 12) }
        await #expect(throws: Self.refused(MTPCode.generalError)) { try await session.move(11, storage: Self.phone, to: 11) }
        #expect(fake.objects.first { $0.handle == 11 }?.parent == Self.root)
        #expect(fake.objects.first { $0.handle == 12 }?.parent == 11)
    }

    @Test func anUnknownHandleIsInvalidObjectHandle() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: Self.refused(MTPCode.invalidObjectHandle)) {
            try await session.move(9999, storage: Self.phone, to: 1)
        }
    }

    /// Pitfall 12: a move answers after two MediaStore scans, so it asks for 120 s.
    @Test func moveUsesTheLongTimeout() async throws {
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.moveObject, atLeast: 120))
        _ = try await session.openSession()
        try await session.move(5, storage: Self.phone, to: 1)
        #expect(try await session.entry(5)?.parent == 1)
    }

    /// FROZEN_ONESHOT_DEL: a just-deleted name in the destination still refuses a move for a moment.
    @Test func aJustDeletedNameIsRefusedForAWhile() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")]),
                                                            staleNameRenames: 2)
        let session = try await openedSession(fake)
        try await session.delete(11)
        for _ in 0..<2 {
            await #expect(throws: Self.refused(MTPCode.generalError)) { try await session.move(5, storage: Self.phone, to: 1) }
        }
        try await session.move(5, storage: Self.phone, to: 1)
        #expect(fake.objects.first { $0.handle == 5 }?.parent == 1)
    }

    @Test func moveObjectIsAdvertised() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder())
        #expect(try await session.openSession().operationsSupported.contains(0x1019))
    }

    // MARK: Move.plan / Move.perform (Task 2)

    /// A folder's entries by handle, read through the session as the app would.
    private func listed(_ session: DeviceSession, _ parent: UInt32 = root) async throws -> [UInt32: ObjectEntry] {
        Dictionary(uniqueKeysWithValues: try await session.children(storage: Self.phone, parent: parent).map { ($0.id, $0) })
    }

    private func plan(_ items: [ObjectEntry], into folder: UInt32, answers: ClashAnswers = ClashAnswers(),
                      unanswered: Unanswered = .ask, _ session: DeviceSession) async throws -> MovePlan {
        try await Move.plan(items, storage: Self.phone, into: folder, answers: answers, unanswered: unanswered, session: session)
    }

    private func perform(_ plan: MovePlan, into folder: UInt32, _ session: DeviceSession) async throws {
        for step in plan.steps { try await Move.perform(step, storage: Self.phone, into: folder, session: session) }
    }

    private static let keepBothFirst = ClashAnswers(byItem: [ItemKey(top: 0): .keepBoth])
    private static let replaceFirst = ClashAnswers(byItem: [ItemKey(top: 0): .replace])

    @Test func noClashPlansOneMovePerItemInOrder() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let root = try await listed(session)
        let (e6, e5) = (try #require(root[6]), try #require(root[5]))
        let plan = try await plan([e6, e5], into: 1, session)
        #expect(plan.steps == [.move(e6), .move(e5)] && plan.clashes.isEmpty)
        try await perform(plan, into: 1, session)
        #expect(fake.objects.filter { $0.parent == 1 }.map(\.handle).sorted() == [5, 6, 9])
        #expect(fake.ops.filter { $0 == MTPOp.moveObject }.count == 2)
    }

    /// D-11 empty case: an item already in the destination is no step and no phone change.
    @Test func itemsAlreadyInTheDestinationAreSkipped() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let e9 = try #require(try await listed(session, 1)[9])
        let before = fake.ops.count
        let plan = try await plan([e9], into: 1, session)
        #expect(plan == MovePlan())
        let reads: Set<UInt16> = [MTPOp.getObjectHandles, MTPOp.getObjectInfo, MTPOp.getObjectPropValue]
        #expect(fake.ops.dropFirst(before).allSatisfy { reads.contains($0) })
    }

    @Test func aClashIsReportedAndNothingIsSent() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")]))
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        let plan = try await plan([e5], into: 1, session)
        let clash = try #require(plan.clashes.first)
        #expect(plan.clashes.count == 1 && plan.steps.isEmpty)
        #expect(clash.id == ItemKey(top: 0) && clash.existing.name == "IMG_2.jpg" && clash.incoming.size == 2_345_678)
        #expect(!fake.ops.contains(MTPOp.moveObject))
    }

    /// Pitfall 11: a case-only clash is a clash, so a move never lands on a case variant.
    @Test func aCaseOnlyClashIsAClash() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "img_2.JPG")]),
                                                            caseInsensitiveNames: true)
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        #expect(try await plan([e5], into: 1, session).clashes.count == 1)
        let answered = try await plan([e5], into: 1, answers: Self.keepBothFirst, session)
        try await perform(answered, into: 1, session)
        #expect(fake.clobbered.isEmpty)
        #expect(Set(fake.objects.filter { $0.parent == 1 }.map(\.handle)) == [5, 9, 11])
    }

    /// D-13: a folder onto a folder offers no Replace, and a Replace answer keeps both: nothing is deleted or merged.
    @Test func folderOntoFolderNeverReplaces() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.folder(11, in: 4, "Camera"),
                                                                                Self.folder(12, in: Self.root, "Camera")]))
        let session = try await openedSession(fake)
        let camera = try #require(try await listed(session)[12])
        #expect(try await plan([camera], into: 4, session).clashes.first?.allowsReplace == false)
        let answered = try await plan([camera], into: 4, answers: Self.replaceFirst, session)
        #expect(answered.steps == [.keepBoth(camera, as: "Camera 2")])
        try await perform(answered, into: 4, session)
        #expect(!fake.ops.contains(MTPOp.deleteObject))
        #expect(Set(fake.objects.filter { $0.parent == 4 }.map(\.name)) == ["Camera", "Camera 2"])
    }

    /// Pitfall 14: the Keep Both name is free in both folders, the rename happens in the source, then the move.
    @Test func keepBothRenamesInTheSourceFirstThenMoves() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: Self.root, "IMG_2 2.jpg"),
                                                                                Self.file(12, in: 1, "IMG_2.jpg")]))
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        let plan = try await plan([e5], into: 1, answers: Self.keepBothFirst, session)
        #expect(plan.steps == [.keepBoth(e5, as: "IMG_2 3.jpg")])
        try await perform(plan, into: 1, session)
        let rename = try #require(fake.ops.firstIndex(of: MTPOp.setObjectPropValue))
        let move = try #require(fake.ops.firstIndex(of: MTPOp.moveObject))
        #expect(rename < move)
        let moved = try #require(fake.objects.first { $0.handle == 5 })
        #expect(moved.parent == 1 && moved.name == "IMG_2 3.jpg")
    }

    @Test func aRefusedMoveAfterKeepBothRenamesBack() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        await #expect(throws: Self.refused(0x201A)) {
            try await Move.perform(.keepBoth(e5, as: "IMG_2 2.jpg"), storage: Self.phone, into: 7, session: session)
        }
        let back = try #require(fake.objects.first { $0.handle == 5 })
        #expect(back.parent == Self.root && back.name == "IMG_2.jpg")
    }

    /// FROZEN_ONESHOT_DEL: the deleted name lingers, so the move after a Replace's delete is retried on 0x2002.
    @Test func replaceDeletesTheExistingThenMovesRetryingAStaleName() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")]),
                                                            staleNameRenames: 2)
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        let plan = try await plan([e5], into: 1, answers: Self.replaceFirst, session)
        #expect(plan.steps.count == 1)
        guard case .replace(_, let existing)? = plan.steps.first else { Issue.record("not a replace"); return }
        #expect(existing.id == 11)
        try await perform(plan, into: 1, session)
        #expect(fake.ops.filter { $0 == MTPOp.deleteObject || $0 == MTPOp.moveObject }
                    == [MTPOp.deleteObject, MTPOp.moveObject, MTPOp.moveObject, MTPOp.moveObject])
        #expect(fake.objects.first { $0.handle == 5 }?.parent == 1)
        #expect(!fake.objects.contains { $0.handle == 11 })
    }

    /// A cable pull between the Keep Both rename and its move leaves the item in its own folder under the new name.
    @Test func aCutAfterTheKeepBothRenameKeepsTheItem() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(goneAfter: [MTPOp.moveObject: 0])
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        do {
            try await Move.perform(.keepBoth(e5, as: "IMG_2 2.jpg"), storage: Self.phone, into: 1, session: session)
            Issue.record("the move should have failed")
        } catch let e as MTPError {
            #expect(!e.isResponse)
        }
        let kept = try #require(fake.objects.first { $0.handle == 5 })
        #expect(kept.parent == Self.root && kept.name == "IMG_2 2.jpg")
    }

    /// A cable pull between a Replace's delete and its move loses only the file the user chose to replace.
    @Test func aCutAfterTheReplaceDeleteKeepsTheMovedItem() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")]),
                                                            goneAfter: [MTPOp.moveObject: 0])
        let session = try await openedSession(fake)
        let e5 = try #require(try await listed(session)[5])
        let e11 = try #require(try await listed(session, 1)[11])
        await #expect(throws: MTPError.deviceGone) {
            try await Move.perform(.replace(e5, existing: e11), storage: Self.phone, into: 1, session: session)
        }
        #expect(fake.objects.first { $0.handle == 5 }?.parent == Self.root)
        #expect(!fake.objects.contains { $0.handle == 11 })
    }

    /// P4 D-10: two items with one name never both take it; the later one is kept both without a question.
    @Test func twoItemsWithOneNameKeepBothWithoutAsking() async throws {
        let session = try await openedSession(FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 2, "IMG.jpg"),
                                                                                       Self.file(12, in: 3, "IMG.jpg")])))
        let first = try #require(try await listed(session, 2)[11])
        let second = try #require(try await listed(session, 3)[12])
        let plan = try await plan([first, second], into: 4, session)
        #expect(plan.clashes.isEmpty)
        #expect(plan.steps == [.move(first), .keepBoth(second, as: "IMG 2.jpg")])
    }

    @Test func applyToAllSkipAnswersEveryClash() async throws {
        let session = try await openedSession(FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg"),
                                                                                       Self.file(12, in: 1, "IMG_10.jpg")])))
        let root = try await listed(session)
        let plan = try await plan([try #require(root[5]), try #require(root[6])], into: 1,
                                  answers: ClashAnswers(all: .skip), session)
        #expect(plan == MovePlan())
    }

    /// Re-planning after the questions: a clash nobody answered (the destination changed) is kept both.
    @Test func unansweredKeepBothResolvesNewClashes() async throws {
        let session = try await openedSession(FakeAndroidResponder(objects: Self.tree([Self.file(11, in: 1, "IMG_2.jpg")])))
        let e5 = try #require(try await listed(session)[5])
        let plan = try await plan([e5], into: 1, unanswered: .keepBoth, session)
        #expect(plan.clashes.isEmpty && plan.steps == [.keepBoth(e5, as: "IMG_2 2.jpg")])
    }

    // MARK: Own subtree (05-MOVE-PROBE: a refused own-subtree move leaves the phone answering 0x0000)

    private static let subtree = tree([folder(11, in: root, "A"), folder(12, in: 11, "Sub"), folder(13, in: 12, "Deep")])

    @Test func moveIntoOwnSubfolderIsRefusedBeforeAnythingIsSent() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.subtree)
        let session = try await openedSession(fake)
        let a = try #require(try await listed(session)[11])
        for destination: UInt32 in [12, 13] {
            let plan = try await plan([a], into: destination, session)
            #expect(plan.steps.isEmpty && plan.clashes.isEmpty && plan.refused == [a])
        }
        #expect(!fake.ops.contains(MTPOp.moveObject))
    }

    @Test func moveFolderOntoItselfIsRefused() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.subtree)
        let session = try await openedSession(fake)
        let a = try #require(try await listed(session)[11])
        #expect(try await plan([a], into: 11, session).refused == [a])
        #expect(!fake.ops.contains(MTPOp.moveObject))
    }

    @Test func onlyTheOwnSubtreeFolderIsRefusedInAMixedDrop() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: Self.subtree)
        let session = try await openedSession(fake)
        let root = try await listed(session)
        let (a, e5) = (try #require(root[11]), try #require(root[5]))
        let plan = try await plan([a, e5], into: 12, session)
        #expect(plan.refused == [a] && plan.steps == [.move(e5)])
        try await perform(plan, into: 12, session)
        #expect(fake.objects.first { $0.handle == 5 }?.parent == 12)
        #expect(fake.objects.first { $0.handle == 11 }?.parent == Self.root)
        #expect(fake.ops.filter { $0 == MTPOp.moveObject }.count == 1)
    }

    @Test func refusalsJoinTheFailureAlertAfterThePhonesFailures() {
        let e = MTPError.response(code: MTPCode.generalError, op: MTPOp.moveObject)
        let only = DeleteText.failures([], refused: [("A", MovePlan.ownSubtreeReason)], verb: "moved")
        #expect(only.message == "“A” couldn’t be moved." && only.detail == MovePlan.ownSubtreeReason)
        let mixed = DeleteText.failures([("x.txt", e)], refused: [("A", MovePlan.ownSubtreeReason)], verb: "moved")
        #expect(mixed.message == "2 items couldn’t be moved." && mixed.detail == "x.txt, A\nMTP error 0x2002 (General Error)")
    }

    @Test func moveClashWordingSaysMoving() {
        let clash = Clash(id: ItemKey(top: 0),
                          existing: Clash.Side(name: "IMG.jpg", size: 100, modified: Date(timeIntervalSince1970: 1_000_000)),
                          incoming: Clash.Side(name: "IMG.jpg", size: 200, modified: Date(timeIntervalSince1970: 2_000_000)))
        let moving = TransferText.clash(clash, verb: "moving")
        #expect(moving.message.hasSuffix("with the newer one you’re moving?"))
        #expect(moving.detail?.split(separator: "\n").last?.hasPrefix("Item you’re moving:") == true)
        let copying = TransferText.clash(clash)
        #expect(copying.message.hasSuffix("with the newer one you’re copying?"))
        #expect(copying.detail?.split(separator: "\n").last?.hasPrefix("Item you’re copying:") == true)
    }

    @Test func failuresSayMoved() {
        let e = MTPError.response(code: MTPCode.generalError, op: MTPOp.moveObject)
        #expect(DeleteText.failures([("IMG.jpg", e)], verb: "moved").message == "“IMG.jpg” couldn’t be moved.")
        #expect(DeleteText.failures([("a", e), ("b", e)], verb: "moved").message == "2 items couldn’t be moved.")
        #expect(DeleteText.failures([("IMG.jpg", e)]).message == "“IMG.jpg” couldn’t be deleted.")
    }
}
