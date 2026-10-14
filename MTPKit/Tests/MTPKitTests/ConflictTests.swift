import Foundation
import Testing
@testable import MTPKit

/// Name clashes at a Mac destination (XFER-07, XFER-08 Mac side): reported up front, then resolved by the answers.
@Suite struct ConflictTests {
    static let chunk: UInt32 = 65_536        // small chunks keep the fake's packetization fast (Pitfall 12)
    static let first = ItemKey(top: 0)

    private func openedSession(_ fake: sending FakeAndroidResponder = FakeAndroidResponder()) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// A fresh empty folder; the caller removes it.
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ConflictTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func entries(_ handles: [UInt32], on session: DeviceSession) async throws -> [ObjectEntry] {
        try await session.entries(handles, parent: 0xFFFF_FFFF)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func fakeBytes(_ handle: UInt32, _ count: Int) -> Data {
        Data(FakeAndroidResponder.content(handle: handle, offset: 0, count: count))
    }

    /// Sums progress callbacks on the MainActor.
    @MainActor final class Progress {
        var total: UInt64 = 0
    }

    /// Plans `items` into `dest` the way a job's attempt does (answers, unanswered → Keep Both) and runs the plan.
    private func copy(_ items: [ObjectEntry], into dest: URL, answers: ClashAnswers, unanswered: Unanswered = .keepBoth,
                      on session: DeviceSession) async throws -> (TransferPlan, TransferOutcome) {
        let plan = try await Transfer.planDownload(items, into: dest, answers: answers, unanswered: unanswered, session: session)
        return (plan, await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in })
    }

    /// "IMG_2.jpg" (handle 5) already in `dest`, holding "keep".
    @discardableResult
    private func keep(in dest: URL, name: String = "IMG_2.jpg") throws -> URL {
        let url = dest.appending(component: name)
        try Data("keep".utf8).write(to: url)
        return url
    }

    // MARK: The tracer: asked first, then replaced in one rename (D-01, D-09, D-20)

    @Test func replaceAnsweredOnTheSheetReplacesTheMacFileAtomically() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try keep(in: dest)
        let items = try await entries([5], on: session)

        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(scan.clashes.count == 1)
        let clash = try #require(scan.clashes.first)
        #expect(clash.id == ItemKey(top: 0, path: []))
        #expect(clash.existing.name == "IMG_2.jpg" && clash.existing.size == 4 && !clash.existing.isFolder)
        #expect(clash.incoming.size == 2_345_678)
        #expect(clash.allowsReplace)
        #expect(scan.steps.isEmpty && scan.totalBytes == 0)
        #expect(fake.opCounts[0x95C1] == nil)                  // nothing read from the phone before the answer

        var answers = ClashAnswers()
        answers.byItem[clash.id] = .replace
        let (plan, outcome) = try await copy(items, into: dest, answers: answers, on: session)

        #expect(plan.clashes.isEmpty)
        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2.jpg"])          // the old file is gone, no temp left
        #expect(try Data(contentsOf: original) == fakeBytes(5, 2_345_678))
        #expect(try modified(original) == parsePTPDate("20260312T184005"))
    }

    @Test func keepBothSavesTheIncomingFileBesideTheOriginal() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try keep(in: dest)
        let (_, outcome) = try await copy(try await entries([5], on: session), into: dest,
                                          answers: ClashAnswers(byItem: [Self.first: .keepBoth]), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2 2.jpg", "IMG_2.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2 2.jpg")) == fakeBytes(5, 2_345_678))
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
    }

    @Test func skipCopiesNothingAndReportsNothing() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try keep(in: dest)
        let (plan, outcome) = try await copy(try await entries([5], on: session), into: dest,
                                             answers: ClashAnswers(byItem: [Self.first: .skip]), on: session)

        #expect(plan.steps.isEmpty && plan.clashes.isEmpty)
        #expect(outcome.problems == TransferOutcome())                  // a user's Skip is not a failure (D-19)
        #expect(try names(in: dest) == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
        #expect(fake.opCounts[0x95C1] == nil)
    }

    /// XFER-07 empty edge: nothing to ask, so the job copies straight away.
    @Test func aJobWithNoClashAsksNothingAndCopies() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let items = try await entries([5, 6], on: session)
        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(scan.clashes.isEmpty && scan.fileCount == 2)

        let outcome = await Transfer.run(scan, session: session, chunk: Self.chunk) { _ in }
        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_10.jpg", "IMG_2.jpg"])
    }

    /// XFER-07 empty edge: a folder merged into a same-name folder with no clashing file inside asks nothing (D-06).
    @Test func aMergedFolderWithoutAClashInsideAsksNothing() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let dcim = dest.appending(component: "DCIM")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: false)
        try Data("other".utf8).write(to: dcim.appending(component: "other.jpg"))
        let scan = try await Transfer.planDownload(try await entries([1], on: session), into: dest, session: session)

        #expect(scan.clashes.isEmpty)
        #expect(scan.steps.map(\.key) == [ItemKey(top: 0, path: ["inside.jpg"])])   // no folder step: merged
    }

    /// The prohibition: nothing at the destination is replaced unless its answer, or Apply to All, is Replace.
    @Test(arguments: [
        (ClashAnswers(), Unanswered.ask),
        (ClashAnswers(), Unanswered.keepBoth),
        (ClashAnswers(byItem: [ItemKey(top: 0): .skip]), Unanswered.keepBoth),
        (ClashAnswers(byItem: [ItemKey(top: 0): .keepBoth]), Unanswered.keepBoth),
        (ClashAnswers(all: .skip), Unanswered.keepBoth),
        (ClashAnswers(all: .keepBoth), Unanswered.ask),
        (ClashAnswers(byItem: [ItemKey(top: 1): .replace]), Unanswered.keepBoth),   // another item's Replace
    ] as [(ClashAnswers, Unanswered)])
    func nothingIsReplacedWithoutAReplaceAnswer(answers: ClashAnswers, unanswered: Unanswered) async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try keep(in: dest)
        let (plan, _) = try await copy(try await entries([5], on: session), into: dest, answers: answers,
                                       unanswered: unanswered, on: session)

        #expect(try Data(contentsOf: original) == Data("keep".utf8))
        #expect(!plan.steps.contains { if case .file(_, _, _, true) = $0 { true } else { false } })
        #expect(plan.clashes.isEmpty || plan.steps.isEmpty)    // an unanswered clash plans no step
    }

    /// D-08: Replace never goes over a folder, whatever the answer; that item is kept both instead.
    @Test func replaceNeverPutsAFileOverAFolder() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let folder = dest.appending(component: "IMG_2.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try keep(in: folder, name: "inside.txt")
        let items = try await entries([5], on: session)

        let scan = try await Transfer.planDownload(items, into: dest, answers: ClashAnswers(all: .replace), session: session)
        #expect(scan.clashes.map(\.allowsReplace) == [false])  // Apply to All + Replace doesn't cover it
        let (_, outcome) = try await copy(items, into: dest, answers: ClashAnswers(byItem: [Self.first: .replace]), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2 2.jpg", "IMG_2.jpg"])
        #expect(try names(in: folder) == ["inside.txt"])
    }

    // MARK: Clash shapes (D-06, D-08, D-10, XFER-07 edges)

    /// Folders "A", "B" and "C", each holding a different "IMG.jpg" (handles 4, 5, 6: 100, 200 and 300 bytes).
    static let twins: [FakeObject] = {
        let phone: UInt32 = 0x0001_0001, root: UInt32 = 0xFFFF_FFFF
        return ["A", "B", "C"].enumerated().flatMap { i, folder in
            let h = UInt32(i + 1)
            return [FakeObject(handle: h, storageID: phone, parent: root, name: folder, format: 0x3001, size: 0,
                               modified: "20260301T090000"),
                    FakeObject(handle: h + 3, storageID: phone, parent: h, name: "IMG.jpg", format: 0x3000,
                               size: UInt64(h) * 100, modified: "20260314T120000")]
        }
    }()

    /// D-06: a folder onto a same-name folder merges with no question; only its clashing file is asked, and nothing
    /// the phone folder lacks is touched.
    @Test func mergeAsksOnlyAboutClashingFilesInside() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let dcim = dest.appending(component: "DCIM")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: false)
        try keep(in: dcim, name: "inside.jpg")
        try Data("mine".utf8).write(to: dcim.appending(component: "mine.txt"))
        let items = try await entries([1], on: session)

        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(scan.clashes.map(\.id) == [ItemKey(top: 0, path: ["inside.jpg"])])   // never one about DCIM itself
        let clash = try #require(scan.clashes.first)
        let (_, outcome) = try await copy(items, into: dest, answers: ClashAnswers(byItem: [clash.id: .keepBoth]),
                                          on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["DCIM"])
        #expect(try names(in: dcim) == ["inside 2.jpg", "inside.jpg", "mine.txt"])
        #expect(try Data(contentsOf: dcim.appending(component: "inside.jpg")) == Data("keep".utf8))
        #expect(try Data(contentsOf: dcim.appending(component: "inside 2.jpg")) == fakeBytes(9, 1_234))
        #expect(try Data(contentsOf: dcim.appending(component: "mine.txt")) == Data("mine".utf8))
    }

    /// D-08: a folder onto a file is asked without Replace; Keep Both copies the whole folder as "DCIM 2".
    @Test func typeClashFolderOntoFileKeepsBothAsDCIM2() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let file = try keep(in: dest, name: "DCIM")
        let items = try await entries([1], on: session)

        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        let clash = try #require(scan.clashes.first)
        #expect(scan.clashes.count == 1 && !clash.allowsReplace)
        #expect(!clash.existing.isFolder && clash.incoming.isFolder)
        let (_, outcome) = try await copy(items, into: dest, answers: ClashAnswers(byItem: [Self.first: .keepBoth]),
                                          on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["DCIM", "DCIM 2"])
        #expect(try Data(contentsOf: dest.appending(path: "DCIM 2/inside.jpg")) == fakeBytes(9, 1_234))
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    /// D-08: Skip on a folder-onto-file clash copies nothing of that subtree; the folder isn't even listed.
    @Test func typeClashFolderOntoFileSkippedCopiesNothing() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let file = try keep(in: dest, name: "DCIM")
        let (plan, outcome) = try await copy(try await entries([1], on: session), into: dest,
                                             answers: ClashAnswers(byItem: [Self.first: .skip]), on: session)

        #expect(plan.steps.isEmpty && outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["DCIM"])
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        #expect(fake.opCounts[0x1007] == nil && fake.opCounts[0x95C1] == nil)
    }

    /// D-08: a file onto a folder kept both lands beside the folder, which is left as it was.
    @Test func typeClashFileOntoFolderKeepsBoth() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let folder = dest.appending(component: "IMG_2.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let inside = try keep(in: folder, name: "inside.txt")
        let (_, outcome) = try await copy(try await entries([5], on: session), into: dest,
                                          answers: ClashAnswers(byItem: [Self.first: .keepBoth]), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2 2.jpg", "IMG_2.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2 2.jpg")) == fakeBytes(5, 2_345_678))
        #expect(try names(in: folder) == ["inside.txt"])
        #expect(try Data(contentsOf: inside) == Data("keep".utf8))
    }

    /// T-04-10: a Replace recorded for a type clash, as its own answer or as Apply to All, is kept both; the Mac item
    /// is never removed or replaced, either way round.
    @Test(arguments: [true, false],
          [ClashAnswers(byItem: [ItemKey(top: 0): .replace]), ClashAnswers(all: .replace)])
    func replaceNeverAppliesToATypeClash(folderOntoFile: Bool, answers: ClashAnswers) async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let there = dest.appending(component: folderOntoFile ? "DCIM" : "IMG_2.jpg")
        if folderOntoFile {
            try keep(in: dest, name: "DCIM")
        } else {
            try FileManager.default.createDirectory(at: there, withIntermediateDirectories: false)
            try keep(in: there, name: "inside.txt")
        }
        let (plan, outcome) = try await copy(try await entries([folderOntoFile ? 1 : 5], on: session), into: dest,
                                             answers: answers, on: session)

        #expect(!plan.steps.contains { if case .file(_, _, _, true) = $0 { true } else { false } })
        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == (folderOntoFile ? ["DCIM", "DCIM 2"] : ["IMG_2 2.jpg", "IMG_2.jpg"]))
        if folderOntoFile {
            #expect(try Data(contentsOf: there) == Data("keep".utf8))
        } else {
            #expect(try names(in: there) == ["inside.txt"])
        }
    }

    /// D-03 + discretion: Apply to All Skip / Keep Both settle every clash of the job; Apply to All Replace settles the
    /// file clashes, and a type clash still gets its own question.
    @Test(arguments: [
        (ClashAnswer.skip, [] as [ItemKey], [] as [String]),
        (.keepBoth, [], ["IMG_2 2.jpg", "IMG_10 2.jpg"]),
        (.replace, [ItemKey(top: 1)], ["IMG_2.jpg"]),
    ] as [(ClashAnswer, [ItemKey], [String])])
    func applyToAllCoversLaterClashes(all: ClashAnswer, asked: [ItemKey], planned: [String]) async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        try keep(in: dest)                                                     // IMG_2.jpg: a file clash
        try FileManager.default.createDirectory(at: dest.appending(component: "IMG_10.jpg"),
                                                withIntermediateDirectories: false)   // IMG_10.jpg: a type clash
        let scan = try await Transfer.planDownload(try await entries([5, 6], on: session), into: dest,
                                                   answers: ClashAnswers(all: all), session: session)

        #expect(scan.clashes.map(\.id) == asked)
        #expect(scan.steps.map(\.url.lastPathComponent) == planned)
        #expect(scan.steps.allSatisfy { if case let .file(_, _, _, replace) = $0 { replace == (all == .replace) } else { false } })
    }

    /// D-10: two items of one job heading for one name never ask; the first selected keeps it and the later ones are
    /// "IMG 2.jpg", "IMG 3.jpg", in selection order.
    @Test func duplicatesInOneJobAreKeptBothInSelectionOrder() async throws {
        let session = try await openedSession(FakeAndroidResponder(objects: Self.twins))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let scan = try await Transfer.planDownload(try await entries([5, 4, 6], on: session), into: dest, session: session)

        #expect(scan.clashes.isEmpty)
        #expect(scan.steps.map(\.url.lastPathComponent) == ["IMG.jpg", "IMG 2.jpg", "IMG 3.jpg"])
        let outcome = await Transfer.run(scan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG 2.jpg", "IMG 3.jpg", "IMG.jpg"])
        #expect(try Data(contentsOf: dest.appending(component: "IMG.jpg")) == fakeBytes(5, 200))
        #expect(try Data(contentsOf: dest.appending(component: "IMG 2.jpg")) == fakeBytes(4, 100))
        #expect(try Data(contentsOf: dest.appending(component: "IMG 3.jpg")) == fakeBytes(6, 300))
    }

    /// D-10 with the name already on the Mac: only the first of the group is asked; the later one is kept both
    /// whatever the answer. Expected contents by name: a handle, or nil for the Mac's original.
    @Test(arguments: [
        (ClashAnswer.replace, ["IMG.jpg": UInt32?.some(4), "IMG 2.jpg": 5]),
        (.keepBoth, ["IMG.jpg": nil, "IMG 2.jpg": 4, "IMG 3.jpg": 5]),
        (.skip, ["IMG.jpg": nil, "IMG 2.jpg": 5]),
    ] as [(ClashAnswer, [String: UInt32?])])
    func onlyTheFirstOfDuplicatesInOneJobIsAsked(answer: ClashAnswer, expected: [String: UInt32?]) async throws {
        let session = try await openedSession(FakeAndroidResponder(objects: Self.twins))
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        try keep(in: dest, name: "IMG.jpg")
        let items = try await entries([4, 5], on: session)

        let scan = try await Transfer.planDownload(items, into: dest, session: session)
        #expect(scan.clashes.map(\.id) == [Self.first])
        let (_, outcome) = try await copy(items, into: dest, answers: ClashAnswers(byItem: [Self.first: answer]), on: session)

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == expected.keys.sorted())
        for (name, handle) in expected {
            let bytes = handle.map { fakeBytes($0, Int($0 - 3) * 100) } ?? Data("keep".utf8)
            #expect(try Data(contentsOf: dest.appending(component: name)) == bytes, "\(name)")
        }
    }

    /// CONTEXT discretion: a name taken between planning and the copy is never overwritten; the download is kept both.
    @Test func aNameTakenAfterPlanningIsKeptBoth() async throws {
        let session = try await openedSession()
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let scan = try await Transfer.planDownload(try await entries([5], on: session), into: dest, session: session)
        #expect(scan.clashes.isEmpty && scan.steps.count == 1)
        let original = try keep(in: dest)                     // something takes the name before the run
        let outcome = await Transfer.run(scan, session: session, chunk: Self.chunk) { _ in }

        #expect(outcome.problems == TransferOutcome())
        #expect(try names(in: dest) == ["IMG_2 2.jpg", "IMG_2.jpg"])
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
        #expect(try Data(contentsOf: dest.appending(component: "IMG_2 2.jpg")) == fakeBytes(5, 2_345_678))
    }

    /// T-04-12: a Keep Both name past what a Mac volume holds (255 UTF-16 units) fails the item instead of being cut
    /// short onto another name; nothing is read or written for it.
    @Test func aKeepBothNameTooLongForTheMacFails() async throws {
        let long = String(repeating: "a", count: 250) + ".jpg"      // 254: fits both sides; "… 2.jpg" doesn't
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: [
            FakeObject(handle: 1, storageID: 0x0001_0001, parent: 0xFFFF_FFFF, name: long, format: 0x3000, size: 10,
                       modified: "20260314T120000"),
        ])
        let session = try await openedSession(fake)
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = try keep(in: dest, name: long)
        let (plan, outcome) = try await copy(try await entries([1], on: session), into: dest,
                                             answers: ClashAnswers(byItem: [Self.first: .keepBoth]), on: session)

        #expect(plan.steps.isEmpty)
        #expect(outcome.failed == [TransferFailure(name: long, detail: "The name is too long for this Mac.", key: Self.first,
                                                   retryable: false)])
        #expect(try names(in: dest) == [long])
        #expect(try Data(contentsOf: original) == Data("keep".utf8))
        #expect(fake.opCounts[0x95C1] == nil)
    }

    /// T-04-13: a run-time Keep Both whose names all stay taken gives up after 1,000 and fails with the rename error.
    @Test func aRunTimeKeepBothGivesUpAfter1000Names() throws {
        let dest = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dest) }
        let temp = try keep(in: dest, name: ".x.aft-download")
        var tries = 0
        #expect(throws: POSIXError(.EEXIST)) {
            try Transfer.moveKeepingBoth(temp, to: dest.appending(component: "IMG.jpg"), name: "IMG.jpg") { _, _ in
                tries += 1
                errno = EEXIST
                return -1
            }
        }
        #expect(tries == 1_000)
        #expect(try names(in: dest) == [".x.aft-download"])     // the caller's cleanup removes the temp
    }

    // MARK: Upload clashes (XFER-07 phone side, D-06..D-11)

    static let phone = UInt32(0x0001_0001)   // internal storage
    static let root = UInt32(0xFFFF_FFFF)

    /// A Mac file of `count` bytes in `folder`, filled with a pattern that differs by name.
    @discardableResult
    private func macFile(_ name: String, _ count: Int, in folder: URL) throws -> URL {
        let url = folder.appending(component: name)
        let seed = UInt8(truncatingIfNeeded: name.hashValue)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }).write(to: url)
        return url
    }

    /// A Mac folder `name` in `parent`.
    @discardableResult
    private func macFolder(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appending(component: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// The phone object called `name` in `parent`.
    private func phoneItem(_ name: String, in parent: UInt32 = 0xFFFF_FFFF, on session: DeviceSession) async throws -> ObjectEntry? {
        try await session.children(storage: Self.phone, parent: parent).first { $0.name == name }
    }

    /// Plans `urls` into the phone folder `parent` the way a job's attempt does (answers, unanswered → Keep Both) and
    /// runs the plan.
    private func upload(_ urls: [URL], parent: UInt32 = 0xFFFF_FFFF, answers: ClashAnswers,
                        on session: DeviceSession) async throws -> (TransferPlan, TransferOutcome) {
        let plan = try await Transfer.planUpload(urls, storage: Self.phone, parent: parent, answers: answers,
                                                 unanswered: .keepBoth, session: session)
        return (plan, await Transfer.run(plan, session: session, chunk: Self.chunk) { _ in })
    }

    /// The scan (`.ask`) of `urls` into the phone root.
    private func scanUpload(_ urls: [URL], answers: ClashAnswers = ClashAnswers(),
                            on session: DeviceSession) async throws -> TransferPlan {
        try await Transfer.planUpload(urls, storage: Self.phone, parent: Self.root, answers: answers, session: session)
    }

    /// The phone file a planned upload step replaces, if any.
    private func replacing(_ step: TransferPlan.Step) -> UInt32? {
        if case let .send(_, _, _, _, _, replacing, _) = step { replacing } else { nil }
    }

    /// D-01, D-04: a Mac file onto a phone file is asked before anything is sent, with the phone item's size and date
    /// against the Mac file's.
    @Test func uploadClashReportsBothSidesAndSendsNothing() async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let mac = try macFile("IMG_2.jpg", 500, in: src)
        let scan = try await scanUpload([mac], on: session)

        let clash = try #require(scan.clashes.first)
        #expect(scan.clashes.count == 1 && clash.id == Self.first && clash.allowsReplace)
        let date = try #require(try await session.entry(5)?.modified)
        #expect(clash.existing == Clash.Side(name: "IMG_2.jpg", size: 2_345_678, modified: date))
        let macDate = try URL(filePath: mac.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(clash.incoming == Clash.Side(name: "IMG_2.jpg", size: 500, modified: try #require(macDate)))
        #expect(scan.steps.isEmpty && scan.totalBytes == 0)
        #expect(await Transfer.run(scan, session: session, chunk: Self.chunk) { _ in } == TransferOutcome())
        #expect(fake.opCounts[0x100C] == nil)                  // nothing sent
    }

    /// D-07, D-19: Keep Both uploads "IMG_2 2.jpg" beside the untouched phone file; Skip sends nothing and reports
    /// nothing.
    @Test(arguments: [ClashAnswer.keepBoth, .skip])
    func uploadKeepBothAndSkip(answer: ClashAnswer) async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let (plan, outcome) = try await upload([try macFile("IMG_2.jpg", 500, in: src)],
                                               answers: ClashAnswers(byItem: [Self.first: answer]), on: session)

        #expect(plan.clashes.isEmpty)
        #expect(outcome.failed.isEmpty && outcome.lost == nil)
        let original = try #require(try await session.entry(5))
        #expect(original.name == "IMG_2.jpg" && original.size == 2_345_678)
        #expect(fake.opCounts[0x100B] == nil)                  // nothing deleted
        if answer == .keepBoth {
            #expect(try await phoneItem("IMG_2 2.jpg", on: session)?.size == 500)
            #expect(fake.renamedNames == ["IMG_2 2.jpg"])
        } else {
            #expect(plan.steps.isEmpty && fake.opCounts[0x100C] == nil)
        }
    }

    /// D-11, Pitfall 3: a name the phone has in another case or normalization is a clash, never an automatic skip and
    /// never a second object beside the first (shared storage is case-insensitive: it would overwrite it).
    @Test(arguments: [("img_2.JPG", "IMG_2.jpg"), ("Cafe\u{301}.jpg", "Caf\u{E9}.jpg")])
    func uploadCaseOnlyNameIsAClash(mac: String, phone: String) async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: [
            FakeObject(handle: 1, storageID: Self.phone, parent: Self.root, name: phone, format: 0x3000, size: 10,
                       modified: "20260314T120000"),
        ])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let scan = try await scanUpload([try macFile(mac, 500, in: src)], on: session)

        #expect(scan.clashes.map(\.id) == [Self.first])
        #expect(scan.clashes.first?.existing.name == phone && scan.clashes.first?.incoming.name == mac)
        #expect(scan.steps.isEmpty)
        _ = await Transfer.run(scan, session: session, chunk: Self.chunk) { _ in }
        #expect(fake.opCounts[0x100C] == nil && fake.objects.count == 1)
    }

    /// D-08: a Mac folder onto a phone file and a Mac file onto a phone folder are asked without Replace; Keep Both
    /// and a Replace answer alike upload them beside the phone item ("IMG_2.jpg 2": a folder name never splits, D-07),
    /// and nothing on the phone is deleted or replaced.
    @Test(arguments: [true, false], [ClashAnswer.keepBoth, .replace])
    func uploadTypeClashesNeverReplace(folderOntoFile: Bool, answer: ClashAnswer) async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let url: URL
        if folderOntoFile {
            url = try macFolder("IMG_2.jpg", in: src)
            try macFile("x.jpg", 20, in: url)
        } else {
            url = try macFile("DCIM", 30, in: src)
        }
        let scan = try await scanUpload([url], answers: ClashAnswers(all: .replace), on: session)
        let clash = try #require(scan.clashes.first)
        #expect(scan.clashes.count == 1 && !clash.allowsReplace)   // Apply to All + Replace doesn't cover it
        #expect(clash.incoming.isFolder == folderOntoFile && clash.existing.isFolder == !folderOntoFile)

        let (plan, outcome) = try await upload([url], answers: ClashAnswers(byItem: [Self.first: answer]), on: session)
        #expect(!plan.steps.contains { replacing($0) != nil })
        #expect(outcome.failed.isEmpty && outcome.lost == nil)
        #expect(fake.opCounts[0x100B] == nil)
        if folderOntoFile {
            #expect(try await session.entry(5)?.size == 2_345_678)
            let kept = try #require(try await phoneItem("IMG_2.jpg 2", on: session))
            #expect(kept.isFolder)
            #expect(try await phoneItem("x.jpg", in: kept.id, on: session)?.size == 20)
        } else {
            #expect(try await phoneItem("DCIM 2", on: session)?.size == 30)
            #expect(try await phoneItem("DCIM", on: session)?.isFolder == true)
            #expect(try await phoneItem("inside.jpg", in: 1, on: session)?.size == 1_234)
        }
    }

    /// D-06: a Mac folder onto a same-name phone folder merges with no question; only its clashing file is asked, the
    /// rest uploads, and Keep Both leaves the phone's own file untouched.
    @Test func uploadMergeAsksOnlyAboutClashingFiles() async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let dcim = try macFolder("DCIM", in: src)
        try macFile("inside.jpg", 50, in: dcim)
        try macFile("new.jpg", 60, in: dcim)

        let scan = try await scanUpload([dcim], on: session)
        #expect(scan.clashes.map(\.id) == [ItemKey(top: 0, path: ["inside.jpg"])])   // never one about DCIM itself
        #expect(scan.steps.map(\.name) == ["new.jpg"])
        let clash = try #require(scan.clashes.first)
        let (_, outcome) = try await upload([dcim], answers: ClashAnswers(byItem: [clash.id: .keepBoth]), on: session)

        #expect(outcome.failed.isEmpty)
        #expect(try await session.children(storage: Self.phone).filter { $0.name == "DCIM" }.count == 1)
        #expect(try await phoneItem("inside.jpg", in: 1, on: session)?.size == 1_234)
        #expect(try await phoneItem("inside 2.jpg", in: 1, on: session)?.size == 50)
        #expect(try await phoneItem("new.jpg", in: 1, on: session)?.size == 60)
    }

    /// D-10 with the name already on the phone: only the first of the group is asked; the later one is kept both
    /// whatever the answer, and selection order decides who gets which name.
    @Test(arguments: [
        (ClashAnswer.keepBoth, ["IMG_2 2.jpg": 500, "img_2 3.jpg": 700]),
        (.skip, ["img_2 2.jpg": 700]),
    ] as [(ClashAnswer, [String: UInt64])])
    func uploadDuplicatesInOneJobAreKeptBoth(answer: ClashAnswer, expected: [String: UInt64]) async throws {
        nonisolated(unsafe) let fake = FakeAndroidResponder()
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let one = try macFile("IMG_2.jpg", 500, in: try macFolder("one", in: src))
        let two = try macFile("img_2.jpg", 700, in: try macFolder("two", in: src))

        let scan = try await scanUpload([one, two], on: session)
        #expect(scan.clashes.map(\.id) == [Self.first])
        let (_, outcome) = try await upload([one, two], answers: ClashAnswers(byItem: [Self.first: answer]), on: session)

        #expect(outcome.failed.isEmpty)
        #expect(try await session.entry(5)?.size == 2_345_678)
        let listed = try await session.children(storage: Self.phone).filter { Transfer.phoneKey($0.name).hasPrefix("img_2 ") }
        #expect(Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0.size) }) == expected)
    }

    /// D-03 + discretion: Apply to All Skip / Keep Both settle every clash of the job; Apply to All Replace settles the
    /// file clash (a Replace of handle 5), and the type clash still gets its own question.
    @Test(arguments: [
        (ClashAnswer.skip, [] as [ItemKey], [] as [String], nil as UInt32?),
        (.keepBoth, [], ["IMG_2 2.jpg", "DCIM 2"], nil),
        (.replace, [ItemKey(top: 1)], ["IMG_2.jpg"], 5),
    ] as [(ClashAnswer, [ItemKey], [String], UInt32?)])
    func uploadApplyToAll(all: ClashAnswer, asked: [ItemKey], planned: [String], replaced: UInt32?) async throws {
        let session = try await openedSession()
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let file = try macFile("IMG_2.jpg", 500, in: src), typeClash = try macFile("DCIM", 30, in: src)
        let scan = try await scanUpload([file, typeClash], answers: ClashAnswers(all: all), on: session)

        #expect(scan.clashes.map(\.id) == asked)
        #expect(scan.steps.map(\.name) == planned)
        #expect(scan.steps.first.flatMap(replacing) == replaced)
    }

    /// XFER-07 encoding edge: a Keep Both name past the 254 UTF-16 units a phone name holds fails the item instead of
    /// being cut short onto another name; nothing is sent for it.
    @Test func uploadKeepBothNameTooLongForThePhoneFails() async throws {
        let long = String(repeating: "a", count: 250) + ".jpg"      // 254: fits; "… 2.jpg" doesn't
        nonisolated(unsafe) let fake = FakeAndroidResponder(objects: [
            FakeObject(handle: 1, storageID: Self.phone, parent: Self.root, name: long, format: 0x3000, size: 10,
                       modified: "20260314T120000"),
        ])
        let session = try await openedSession(fake)
        let src = try tempFolder()
        defer { try? FileManager.default.removeItem(at: src) }
        let (plan, outcome) = try await upload([try macFile(long, 500, in: src)],
                                               answers: ClashAnswers(byItem: [Self.first: .keepBoth]), on: session)

        #expect(plan.steps.isEmpty)
        #expect(outcome.failed == [TransferFailure(name: long, detail: "The name is too long for the phone.", key: Self.first,
                                                   retryable: false)])
        #expect(fake.opCounts[0x100C] == nil && fake.objects.count == 1)
    }

    // MARK: Wording (D-04)

    private func clash(existing: Date?, incoming: Date?, existingIsFolder: Bool = false) -> Clash {
        Clash(id: Self.first,
              existing: Clash.Side(name: "IMG.jpg", isFolder: existingIsFolder, size: existingIsFolder ? nil : 4, modified: existing),
              incoming: Clash.Side(name: "IMG.jpg", size: 2_345_678, modified: incoming))
    }

    static let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    static let later = Date(timeIntervalSince1970: 1_700_000_060)

    @Test(arguments: [
        (ConflictTests.earlier, ConflictTests.later, "An older item named “IMG.jpg” already exists in this location. Do you want to replace it with the newer one you’re copying?"),
        (ConflictTests.later, ConflictTests.earlier, "A newer item named “IMG.jpg” already exists in this location. Do you want to replace it with the older one you’re copying?"),
        (ConflictTests.earlier.addingTimeInterval(0.4), ConflictTests.earlier, "An item named “IMG.jpg” already exists in this location. Do you want to replace it with the one you’re copying?"),
        (nil, ConflictTests.later, "An item named “IMG.jpg” already exists in this location. Do you want to replace it with the one you’re copying?"),
        (ConflictTests.earlier, nil, "An item named “IMG.jpg” already exists in this location. Do you want to replace it with the one you’re copying?"),
    ] as [(Date?, Date?, String)])
    func fileClashWordingFollowsTheDates(existing: Date?, incoming: Date?, message: String) {
        #expect(TransferText.clash(clash(existing: existing, incoming: incoming)).message == message)
    }

    @Test func typeClashAsksNothingAboutReplacing() {
        let text = TransferText.clash(clash(existing: Self.later, incoming: Self.earlier, existingIsFolder: true))
        #expect(text.message == "An item named “IMG.jpg” already exists in this location.")
        #expect(text.detail == "Existing item: folder, modified \(EntryFormat.date(Self.later))\n"
                + "Item you’re copying: \(EntryFormat.bytes(2_345_678)), modified \(EntryFormat.date(Self.earlier))")
    }

    @Test func detailGivesBothSizesAndDates() {
        #expect(TransferText.clash(clash(existing: Self.earlier, incoming: Self.later)).detail
                == "Existing item: \(EntryFormat.bytes(4)), modified \(EntryFormat.date(Self.earlier))\n"
                + "Item you’re copying: \(EntryFormat.bytes(2_345_678)), modified \(EntryFormat.date(Self.later))")
        #expect(TransferText.clash(clash(existing: nil, incoming: nil)).detail
                == "Existing item: \(EntryFormat.bytes(4))\nItem you’re copying: \(EntryFormat.bytes(2_345_678))")
        #expect(TransferText.asking == "Waiting for your answer…")
    }
}
