import Foundation
import Synchronization
import Testing
@testable import MTPKit

@Suite struct MutationTests {
    static let phone = UInt32(0x0001_0001)   // internal storage

    private func openedSession(_ fake: sending FakeAndroidResponder) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    /// A fake with an open session, driven through `transact` directly so the test can inspect it.
    private func openedFake(maxPacketSize: Int = 512) throws -> FakeAndroidResponder {
        let fake = FakeAndroidResponder(maxPacketSize: maxPacketSize)
        _ = try transact(fake, op: MTPOp.openSession, tid: 0, params: [1])
        return fake
    }

    // MARK: Data-out framing (T-02-11)

    @Test(arguments: [64, 512], [true, false])
    func zeroLengthPacketOnlyAfterAnExactMultiple(maxPacketSize: Int, exact: Bool) throws {
        let fake = try openedFake(maxPacketSize: maxPacketSize)
        var p = Payload()
        p.string("notes.txt")
        // The phone ignores bytes after the string, so padding makes the container fill its last packet exactly.
        if exact { p.bytes += [UInt8](repeating: 0, count: maxPacketSize - 12 - p.bytes.count) }
        #expect(((12 + p.bytes.count) % maxPacketSize == 0) == exact)
        _ = try transact(fake, op: MTPOp.setObjectPropValue, tid: 1, params: [7, 0xDC07], dataOut: p.bytes)
        #expect(fake.zlpCount == (exact ? 1 : 0))
    }

    /// WR-05: a device claiming wMaxPacketSize 0 fails the change before anything is sent, instead of trapping on `%`.
    @Test func zeroMaxPacketSizeIsRefused() {
        final class ZeroPacketSize: MTPTransport {
            var maxPacketSize: Int { 0 }
            var writes = 0
            func write(_ bytes: [UInt8], timeout: TimeInterval) throws { writes += 1 }
            func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] { throw MTPError.deviceGone }
        }
        let t = ZeroPacketSize()
        #expect(throws: MTPError.malformed("wMaxPacketSize 0")) {
            try transact(t, op: MTPOp.setObjectPropValue, tid: 1, params: [7, 0xDC07], dataOut: [0])
        }
        #expect(t.writes == 0)
    }

    /// The fake takes a data container only when its length field equals the bytes of that one write,
    /// so `transact` succeeding proves header and payload went out together.
    @Test func headerWrittenApartFromItsPayloadIsRejected() throws {
        let fake = try openedFake()
        var p = Payload()
        p.string("notes.txt")
        try fake.write(commandContainer(op: MTPOp.setObjectPropValue, tid: 1, params: [7, 0xDC07]), timeout: 1)
        var header = Payload()
        header.u32(UInt32(12 + p.bytes.count)); header.u16(ContainerType.data); header.u16(MTPOp.setObjectPropValue); header.u32(1)
        #expect(throws: MTPError.self) { try fake.write(header.bytes, timeout: 1) }
    }

    @Test func onlyTheFileNameCanBeSet() throws {
        let fake = try openedFake()
        var p = Payload()
        p.string("x")
        #expect(throws: MTPError.response(code: 0xA80A, op: 0x9804)) {
            try transact(fake, op: MTPOp.setObjectPropValue, tid: 1, params: [7, 0xDC04], dataOut: p.bytes)
        }
    }

    // MARK: Rename with AOSP semantics

    @Test func renameIsReadBackFromThePhone() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        try await session.rename(7, to: "notes.txt")
        let entries = try await session.children(storage: Self.phone)
        #expect(entries.first { $0.name == "notes.txt" }?.id == 7)
        #expect(!entries.contains { $0.name == "empty.txt" })
    }

    /// AOSP answers a name already used in the folder with a bare General Error.
    @Test func renameToASiblingsNameIsAGeneralError() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.response(code: 0x2002, op: 0x9804)) {
            try await session.rename(7, to: "IMG_2.jpg")
        }
        #expect(try await session.children(storage: Self.phone).contains { $0.name == "empty.txt" })
    }

    @Test func renameOfAnUnknownHandleIsInvalidObjectHandle() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.response(code: 0x2009, op: 0x9804)) {
            try await session.rename(9999, to: "x")
        }
    }

    /// Prohibition: a name `Payload.string` would truncate is never sent as a different name.
    @Test func overlongNameIsRefusedBeforeAnythingIsSent() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.self) {
            try await session.rename(7, to: String(repeating: "a", count: 255))
        }
        let names = try await session.children(storage: Self.phone).map(\.name)
        #expect(names.contains("empty.txt"))
        #expect(!names.contains { $0.hasPrefix("aaaa") })
    }

    // MARK: New folder with AOSP semantics (FMGT-01)

    @Test func makeFolderAtTheRootIsReadBackAsAFolder() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let handle = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "untitled folder")
        #expect(FakeAndroidResponder.defaultObjects.allSatisfy { $0.handle < handle })
        let made = try await session.children(storage: Self.phone).first { $0.name == "untitled folder" }
        #expect(made?.id == handle)
        #expect(made?.isFolder == true)
    }

    /// AOSP never reuses a handle within a session (mNextObjectId++).
    @Test func eachMakeFolderGetsANewLargerHandle() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let first = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "a")
        let second = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "b")
        #expect(second > first)
    }

    @Test func makeFolderInASubfolderStaysThere() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let handle = try await session.makeFolder(storage: Self.phone, parent: 1, name: "x")
        #expect(try await session.children(storage: Self.phone, parent: 1).contains { $0.id == handle && $0.name == "x" })
        #expect(try await !session.children(storage: Self.phone).contains { $0.name == "x" })
    }

    @Test func makeFolderWithASiblingsNameIsAGeneralError() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.response(code: 0x2002, op: 0x100C)) {
            try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "DCIM")
        }
    }

    /// AOSP doSendObjectInfo: an unknown parent fails getObjectFilePath (Invalid Object Handle); a parent that is a
    /// file is Invalid Parent Object.
    @Test(arguments: [(UInt32(9999), UInt16(0x2009)), (7, 0x201A)])
    func makeFolderNeedsAnExistingParentFolder(parent: UInt32, code: UInt16) async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.response(code: code, op: 0x100C)) {
            try await session.makeFolder(storage: Self.phone, parent: parent, name: "x")
        }
    }

    // MARK: Delete with AOSP semantics (FMGT-03)

    @Test func deleteRemovesAFile() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        try await session.delete(7)
        #expect(try await !session.children(storage: Self.phone).contains { $0.id == 7 })
    }

    /// AOSP deletes a folder and everything in it in one DeleteObject.
    @Test func deletingAFolderTakesItsContents() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        try await session.delete(1)
        #expect(try await !session.children(storage: Self.phone).contains { $0.id == 1 })
        // `entries` skips a handle only when GetObjectInfo answers 0x2009; any other answer would throw.
        #expect(try await session.entries([9], parent: 1).isEmpty)
    }

    @Test func deleteOfAnUnknownHandleIsInvalidObjectHandle() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        await #expect(throws: MTPError.response(code: 0x2009, op: 0x100B)) {
            try await session.delete(9999)
        }
    }

    @Test func aProtectedObjectIsNotDeleted() async throws {
        let session = try await openedSession(FakeAndroidResponder(protectedHandles: [5]))
        await #expect(throws: MTPError.response(code: 0x200F, op: 0x100B)) {
            try await session.delete(5)
        }
        #expect(try await session.children(storage: Self.phone).contains { $0.id == 5 })
    }

    /// RESEARCH Pitfall 1 / A1: a big recursive delete gets 120 s, so it doesn't poison the session.
    @Test func deleteUsesTheLongTimeout() async throws {
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.deleteObject, atLeast: 120))
        _ = try await session.openSession()
        try await session.delete(7)
        #expect(try await !session.children(storage: Self.phone).contains { $0.id == 7 })
    }

    /// RESEARCH Pitfall 2: the finalize rename waits on two MediaStore scans, so it can ask for 120 s.
    @Test func renameCanUseTheLongTimeout() async throws {
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.setObjectPropValue, atLeast: 120))
        _ = try await session.openSession()
        try await session.rename(7, to: "notes.txt", timeout: 120)
        #expect(try await session.children(storage: Self.phone).first { $0.name == "notes.txt" }?.id == 7)
    }

    /// The browser's renames still send 5 s: the same wrapper refuses them and the session drops itself.
    @Test func renameKeepsTheShortTimeoutByDefault() async throws {
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.setObjectPropValue, atLeast: 120))
        _ = try await session.openSession()
        await #expect(throws: MTPError.io(operation: "short timeout", code: 0)) {
            try await session.rename(7, to: "notes.txt")
        }
    }

    // MARK: Re-list after a change (D-15)

    @Test func reconcileKeepsUntouchedReplacesFreshAndDropsGone() {
        func entry(_ id: UInt32, _ name: String) -> ObjectEntry {
            ObjectEntry(id: id, storageID: Self.phone, parent: 0xFFFF_FFFF, format: 0x3000, name: name, size: 0, modified: nil)
        }
        let key = FolderKey(storage: Self.phone, folder: 0xFFFF_FFFF)
        var cache = FolderCache()
        cache.begin(key)
        cache.append([entry(1, "a"), entry(2, "b"), entry(3, "c")], to: key)
        cache.reconcile(key, handles: [1, 2, 4], fresh: [entry(2, "renamed"), entry(4, "new")])
        #expect(cache[key]?.map(\.name) == ["a", "renamed", "new"])
        #expect(cache.isComplete(key))
    }

    /// WR-02: a row an event added after the re-list's GetObjectHandles stays; one that was cached before and is
    /// no longer listed still drops.
    @Test func reconcileKeepsRowsAnEventAddedMeanwhile() {
        func entry(_ id: UInt32, _ name: String) -> ObjectEntry {
            ObjectEntry(id: id, storageID: Self.phone, parent: 0xFFFF_FFFF, format: 0x3000, name: name, size: 0, modified: nil)
        }
        let key = FolderKey(storage: Self.phone, folder: 0xFFFF_FFFF)
        var cache = FolderCache()
        cache.begin(key)
        cache.append([entry(1, "a"), entry(2, "b")], to: key)
        cache.finish(key)
        let before = Set(cache[key]!.map(\.id))
        cache.upsert(entry(5, "from an event"))                // after GetObjectHandles returned [1]
        cache.reconcile(key, handles: [1], fresh: [], cachedBefore: before)
        #expect(cache[key]?.map(\.name) == ["a", "from an event"])
    }
}

// MARK: Phone clock zone, learned from created objects (quick 261007-cyl)

extension MutationTests {
    /// A PhoneClockStore over a dictionary, so a test can seed loads and see saves.
    final class RecordingStore: Sendable {
        let values: Mutex<[String: TimeZone]>
        let saves = Mutex<[(String, TimeZone?)]>([])
        init(_ seed: [String: TimeZone] = [:]) { values = Mutex(seed) }
        var store: PhoneClockStore {
            PhoneClockStore(load: { serial in self.values.withLock { $0[serial] } },
                            save: { serial, zone in
                                self.values.withLock { $0[serial] = zone }
                                self.saves.withLock { $0.append((serial, zone)) }
                            })
        }
    }

    /// Tokyo (+9, no DST) is the Mac's zone unless a test says otherwise: no offset the tests learn matches it.
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func clockSession(_ fake: sending FakeAndroidResponder, _ store: RecordingStore,
                              macZone: TimeZone = tokyo) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake, clockStore: store.store, macZone: macZone)
        _ = try await session.openSession()
        return session
    }

    @Test(arguments: [28800, 20700, -12600, 0])
    func makeFolderLearnsThePhonesOffset(offset: Int) async throws {
        let store = RecordingStore()
        let session = try await clockSession(FakeAndroidResponder(phoneUTCOffset: offset), store)
        _ = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "untitled folder")
        let zone = TimeZone(secondsFromGMT: offset)
        #expect(await session.phoneZone == zone)
        #expect(store.saves.withLock { $0.map(\.0) } == ["FAKE0001"])
        #expect(store.saves.withLock { $0.map(\.1) } == [zone])
        #expect(try await session.entry(5)?.modified == parsePTPDate("20260312T184005", zone: zone))
    }

    @Test func createFileLearnsThePhonesOffset() async throws {
        let store = RecordingStore()
        let session = try await clockSession(FakeAndroidResponder(phoneUTCOffset: 28800), store)
        _ = try await session.createFile(storage: Self.phone, parent: 0xFFFF_FFFF, name: "a.txt", contents: [1, 2, 3])
        #expect(await session.phoneZone == TimeZone(secondsFromGMT: 28800))
        #expect(store.values.withLock { $0["FAKE0001"] } == TimeZone(secondsFromGMT: 28800))
    }

    @Test func createForEditLearnsThePhonesOffset() async throws {
        let store = RecordingStore()
        let session = try await clockSession(FakeAndroidResponder(phoneUTCOffset: -12600), store)
        let handle = try await session.createForEdit(storage: Self.phone, parent: 0xFFFF_FFFF, name: "big.bin")
        try await session.endEdit(handle)
        #expect(await session.phoneZone == TimeZone(secondsFromGMT: -12600))
        #expect(store.values.withLock { $0["FAKE0001"] } == TimeZone(secondsFromGMT: -12600))
    }

    /// A phone in the Mac's own DST zone keeps that zone's rules (CR-01): a January and a July stamp both read as
    /// London wall clock, whichever side of the change today's offset was learned on. A fixed offset gets one of them
    /// an hour off in any season. It is saved as nil, not "Europe/London", so a later change of the Mac's zone follows
    /// (re-review WR-01).
    @Test func aPhoneInTheMacsZoneKeepsItsDSTRules() async throws {
        let london = TimeZone(identifier: "Europe/London")!
        let july = FakeObject(handle: 11, storageID: Self.phone, parent: 0xFFFF_FFFF, name: "summer.jpg",
                              format: 0x3000, size: 1, modified: "20260715T120000")
        let fake = FakeAndroidResponder(objects: FakeAndroidResponder.defaultObjects + [july],
                                        phoneUTCOffset: london.secondsFromGMT(for: Date()))
        let store = RecordingStore()
        let session = try await clockSession(fake, store, macZone: london)
        _ = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "untitled folder")
        #expect(await session.phoneZone == nil)
        #expect(store.saves.withLock { $0.map(\.0) } == ["FAKE0001"])
        #expect(store.saves.withLock { $0.map(\.1) } == [nil])
        #expect(try await session.entry(7)?.modified == parsePTPDate("20250101T000000", zone: london))
        #expect(try await session.entry(11)?.modified == parsePTPDate("20260715T120000", zone: london))
    }

    /// The default fake stamps created objects days in the past: a stale read teaches nothing.
    @Test func aStaleStampLeavesTheMacZone() async throws {
        let store = RecordingStore()
        let session = try await clockSession(FakeAndroidResponder(), store)
        _ = try await session.makeFolder(storage: Self.phone, parent: 0xFFFF_FFFF, name: "untitled folder")
        #expect(await session.phoneZone == nil)
        #expect(try await session.entry(5)?.modified == parsePTPDate("20260312T184005", zone: Self.tokyo))
        #expect(store.saves.withLock { $0.isEmpty })
    }

    /// A clock read that drops the session fails the call that created the object, so the loss is this item's (WR-02).
    @Test func aClockReadThatDropsTheSessionFailsTheCreation() async throws {
        let session = try await clockSession(FakeAndroidResponder(unansweredAfter: [0x1008: 0]), RecordingStore())
        do {
            _ = try await session.createFile(storage: Self.phone, parent: 0xFFFF_FFFF, name: "a.txt", contents: [1])
            Issue.record("the creation succeeded on a dropped session")
        } catch let e as MTPError {
            #expect(!e.isResponse)
        }
    }

    @Test func aStoredOffsetAppliesFromOpenSession() async throws {
        let plus8 = TimeZone(secondsFromGMT: 28800)!
        let session = try await clockSession(FakeAndroidResponder(), RecordingStore(["FAKE0001": plus8]))
        #expect(await session.phoneZone == plus8)
        #expect(try await session.entry(5)?.modified == parsePTPDate("20260312T184005", zone: plus8))
    }
}
