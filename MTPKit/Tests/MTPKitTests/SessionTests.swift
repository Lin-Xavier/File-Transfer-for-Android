import Foundation
import Testing
@testable import MTPKit

@Suite struct SessionTests {
    @Test func openSessionReturnsDeviceInfo() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder())
        let info = try await session.openSession()
        #expect(info.model == "Pixel 9")
        #expect(info.manufacturer == "Google")
        #expect(info.operationsSupported.contains(0x95C1))
    }

    @Test(arguments: [64, 512])
    func storagesInOrderWithFreeSpace(maxPacketSize: Int) async throws {
        let session = DeviceSession(transport: FakeAndroidResponder(maxPacketSize: maxPacketSize))
        _ = try await session.openSession()
        let storages = try await session.storages()
        #expect(storages.map(\.id) == [0x0001_0001, 0x0002_0001])
        #expect(storages.map(\.freeSpace) == [12_400_000_000, 30_000_000_000])
        #expect(storages.map(\.description) == ["Internal shared storage", "SD card"])
        #expect(storages.map(\.isRemovable) == [false, true])
    }

    @Test func staleSessionIsClosedAndReopened() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder(sessionAlreadyOpen: true))
        _ = try await session.openSession()
        #expect(try await session.storages().count == 2)
    }

    @Test func lockedPhoneHasNoStorages() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder(storages: []))
        _ = try await session.openSession()
        #expect(try await session.storages() == [])
    }

    /// The lock poll reuses the session: empty answers don't poison it, and the storages come back on it (D-33).
    @Test func lockedPhoneUnlocksLater() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder(lockedStorageReads: 2))
        _ = try await session.openSession()
        #expect(try await session.storages() == [])
        #expect(try await session.storages() == [])
        #expect(try await session.storages().map(\.id) == FakeAndroidResponder.defaultStorages.map(\.id))
    }

    @Test func storagesWithSameDescriptionStayDistinct() async throws {
        let twins = [
            FakeStorage(id: 0x0001_0001, type: 0x0003, capacity: 10, free: 1, description: "Phone"),
            FakeStorage(id: 0x0003_0001, type: 0x0003, capacity: 20, free: 2, description: "Phone"),
        ]
        let session = DeviceSession(transport: FakeAndroidResponder(storages: twins))
        _ = try await session.openSession()
        let storages = try await session.storages()
        #expect(storages.map(\.id) == [0x0001_0001, 0x0003_0001])
        #expect(storages.map(\.freeSpace) == [1, 2])
    }

    @Test func unknownOperationIsNotSupported() throws {
        let fake = FakeAndroidResponder()      // never handed to a DeviceSession (its init takes `sending`)
        _ = try transact(fake, op: MTPOp.openSession, tid: 0, params: [1])
        #expect(throws: MTPError.response(code: 0x2005, op: 0x1234)) {
            try transact(fake, op: 0x1234, tid: 1)
        }
    }

    @Test func noTransportMeansDeviceGone() async throws {
        let session = DeviceSession(transport: FakeAndroidResponder())
        _ = try await session.openSession()
        await session.close()
        await #expect(throws: MTPError.deviceGone) { try await session.storages() }
        await #expect(throws: MTPError.deviceGone) { try await DeviceSession().openSession() }
    }

    /// CR-01: after a timeout the session must not reuse the pipe, where the late reply is still queued.
    /// WR-01: later calls repeat the timeout instead of reporting an unplug.
    /// G-02-7: the timed-out transaction's reply is drained first, so the next session isn't NAKed.
    @Test func timeoutDropsTheSession() async throws {
        let (cancels, sink) = AsyncStream.makeStream(of: UInt32.self)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.getObjectHandles,
                                                         onCancel: { sink.yield($0) }))
        _ = try await session.openSession()
        let timeout = MTPError.io(operation: "Read", code: 0xE000_02D6)
        await #expect(throws: timeout) { try await session.children(storage: Self.phone) }
        sink.finish()
        #expect(await cancels.reduce(into: []) { $0.append($1) } == [1])      // the GetObjectHandles: the first tid after OpenSession
        await #expect(throws: timeout) { try await session.storages() }
    }

    /// An unplugged phone gets no Cancel, so an unplug stays fast.
    @Test func unplugSendsNoCancel() async throws {
        let (cancels, sink) = AsyncStream.makeStream(of: UInt32.self)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.getObjectHandles,
                                                         error: .deviceGone, onCancel: { sink.yield($0) }))
        _ = try await session.openSession()
        await #expect(throws: MTPError.deviceGone) { try await session.children(storage: Self.phone) }
        sink.finish()
        #expect(await cancels.reduce(into: []) { $0.append($1) } == [])
    }

    /// WR-04: a pipe stall recovers the halted endpoints first, then drains, then drops the session.
    @Test func stallRecoversEndpointsBeforeTheDrain() async throws {
        let (log, sink) = AsyncStream.makeStream(of: String.self)
        let stall = MTPError.io(operation: "Bulk read", code: 0xE000_5000)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.getStorageIDs, error: stall,
                                                         onCancel: { sink.yield("cancel \($0)") },
                                                         onStall: { sink.yield("stall") }))
        _ = try await session.openSession()
        await #expect(throws: stall) { try await session.storages() }
        await #expect(throws: stall) { try await session.storages() }        // poisoned: the transport is not touched again
        sink.finish()
        #expect(await log.reduce(into: []) { $0.append($1) } == ["stall", "cancel 1"])
    }

    /// G-02-17: a timeout keeps the Phase 2 path, drain only. No device status, no clearStall.
    @Test func timeoutDoesNotRecoverStall() async throws {
        let (log, sink) = AsyncStream.makeStream(of: String.self)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.getStorageIDs,
                                                         onCancel: { sink.yield("cancel \($0)") },
                                                         onStall: { sink.yield("stall") }))
        _ = try await session.openSession()
        await #expect(throws: MTPError.io(operation: "Read", code: 0xE000_02D6)) { try await session.storages() }
        sink.finish()
        #expect(await log.reduce(into: []) { $0.append($1) } == ["cancel 1"])
    }

    /// An error response leaves the session in step: no recoverStall, no drain, and the next call works.
    @Test func errorResponseNeedsNoRecovery() async throws {
        let (log, sink) = AsyncStream.makeStream(of: String.self)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.sendObject,
                                                         onCancel: { sink.yield("cancel \($0)") },
                                                         onStall: { sink.yield("stall") }))
        _ = try await session.openSession()
        await #expect(throws: MTPError.response(code: MTPCode.invalidStorageID, op: MTPOp.getObjectHandles)) {
            try await session.handles(storage: 0xDEAD, parent: 0xFFFF_FFFF)
        }
        #expect(try await session.storages().count == 2)
        sink.finish()
        #expect(await log.reduce(into: []) { $0.append($1) } == [])
    }

    /// An unplug calls neither hook, so it stays fast.
    @Test func unplugCallsNoRecoveryHook() async throws {
        let (log, sink) = AsyncStream.makeStream(of: String.self)
        let session = DeviceSession(transport: SlowReply(FakeAndroidResponder(), op: MTPOp.getStorageIDs, error: .deviceGone,
                                                         onCancel: { sink.yield("cancel \($0)") },
                                                         onStall: { sink.yield("stall") }))
        _ = try await session.openSession()
        await #expect(throws: MTPError.deviceGone) { try await session.storages() }
        sink.finish()
        #expect(await log.reduce(into: []) { $0.append($1) } == [])
    }

    /// AOSP's GetDeviceStatus quirks: wLength 8/12/20, zero padding, a wLength past the bytes received, no endpoints.
    @Test func deviceStatusSurvivesQuirks() {
        let eight = DeviceStatus([0x08, 0x00, 0x1F, 0x20, 0x81, 0x00, 0x01, 0x00])
        #expect(eight.code == 0x201F && eight.endpoints == [0x81, 0x01])
        let mix4 = DeviceStatus([0x08, 0x00, 0x1F, 0x20, 0xFF, 0x00, 0xFF, 0x00])  // what the MIX 4 sent (G-03-1)
        #expect(mix4.code == 0x201F && mix4.endpoints == [0xFF, 0xFF])
        let padded = DeviceStatus([0x0C, 0x00, 0x1F, 0x20, 0x81, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(padded.code == 0x201F && padded.endpoints == [0x81, 0x01])
        let cut = DeviceStatus([0x14, 0x00, 0x1F, 0x20, 0x81, 0x00])         // wLength 20, 6 bytes received
        #expect(cut.code == 0x201F && cut.endpoints == [0x81])
        let tiny = DeviceStatus([0x08, 0x00, 0x1F])
        #expect(tiny.code == 0 && tiny.endpoints.isEmpty)
        let bare = DeviceStatus([0x04, 0x00, 0x01, 0x20])
        #expect(bare.code == 0x2001 && bare.endpoints.isEmpty)
    }

    /// G-02-7: Retry reopens a phone still stuck writing an abandoned reply. openSession drains it and connects.
    @Test func retryRecoversAWedgedPhone() async throws {
        let session = DeviceSession(transport: Wedged(FakeAndroidResponder(sessionAlreadyOpen: true)))
        let info = try await session.openSession()
        #expect(info.model == "Pixel 9")
        #expect(try await session.storages().count == 2)
    }
}

extension SessionTests {
    static let phone = UInt32(0x0001_0001)   // internal storage

    private func openedSession(_ fake: sending FakeAndroidResponder) async throws -> DeviceSession {
        let session = DeviceSession(transport: fake)
        _ = try await session.openSession()
        return session
    }

    private func oneFile(size: UInt64, failPropValue: Bool = false) -> FakeAndroidResponder {
        FakeAndroidResponder(
            storages: [FakeAndroidResponder.defaultStorages[0]],
            objects: [FakeObject(handle: 1, storageID: Self.phone, parent: 0xFFFF_FFFF, name: "file.bin",
                                 format: 0x3000, size: size, modified: "20260312T184005")],
            failPropValue: failPropValue)
    }

    @Test func rootListingHasOnlyRootObjectsOfThatStorage() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let entries = try await session.children(storage: Self.phone)
        #expect(Set(entries.map(\.name)) == ["DCIM", "Download", "Music", "Pictures",
                                             "IMG_2.jpg", "IMG_10.jpg", "empty.txt", "big-video.mp4"])
        #expect(entries.allSatisfy { $0.storageID == Self.phone && $0.parent == 0xFFFF_FFFF })
    }

    @Test(arguments: [0, 1, 4_294_967_294, 4_294_967_295, 4_294_967_296, 4_294_967_297, 5_000_000_000] as [UInt64])
    func sizeIsExactAcrossThe4GiBBoundary(size: UInt64) async throws {
        let session = try await openedSession(oneFile(size: size))
        let entries = try await session.children(storage: Self.phone)
        #expect(entries.map(\.size) == [size])
    }

    @Test func foldersAndFilesAreTold() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        let byName = Dictionary(uniqueKeysWithValues: try await session.children(storage: Self.phone).map { ($0.name, $0) })
        #expect(byName["DCIM"]?.isFolder == true)
        #expect(byName["IMG_2.jpg"]?.isFolder == false)
        #expect(byName["IMG_2.jpg"]?.size == 2_345_678)
        #expect(byName["IMG_2.jpg"]?.modified != nil)
    }

    @Test func failedSizeLookupFailsTheListing() async throws {
        let session = try await openedSession(oneFile(size: 5_000_000_000, failPropValue: true))
        await #expect(throws: MTPError.response(code: 0x2002, op: 0x9803)) {
            try await session.children(storage: Self.phone)
        }
    }

    /// RESEARCH Pattern 3: a handle deleted on the phone between GetObjectHandles and GetObjectInfo is skipped.
    @Test func vanishedHandleIsSkipped() async throws {
        let session = try await openedSession(FakeAndroidResponder(vanishedHandles: [99]))
        #expect(try await session.handles(storage: Self.phone, parent: 0xFFFF_FFFF).contains(99))
        let entries = try await session.children(storage: Self.phone)
        #expect(Set(entries.map(\.name)) == ["DCIM", "Download", "Music", "Pictures",
                                             "IMG_2.jpg", "IMG_10.jpg", "empty.txt", "big-video.mp4"])
        #expect(!entries.contains { $0.id == 99 })
    }

    @Test func entriesOfNoHandlesIsEmpty() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        #expect(try await session.entries([], parent: 0xFFFF_FFFF) == [])
    }

    @Test func folderHandlesAndEntries() async throws {
        let session = try await openedSession(FakeAndroidResponder())
        #expect(try await session.handles(storage: Self.phone, parent: 1) == [9])
        let entries = try await session.entries([9], parent: 1)
        #expect(entries.map(\.name) == ["inside.jpg"])
        #expect(entries.map(\.parent) == [1])
    }

    /// RESEARCH Pitfall 1 / A1: GetObjectHandles gets 30 s, so a slow big folder doesn't poison the session.
    @Test func handlesUseLongTimeout() async throws {
        let session = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.getObjectHandles, atLeast: 30))
        _ = try await session.openSession()
        #expect(try await session.handles(storage: Self.phone, parent: 0xFFFF_FFFF).count == 8)
        // The wrapper does bite: demanding more than 30 s fails.
        let strict = DeviceSession(transport: MinTimeout(FakeAndroidResponder(), op: MTPOp.getObjectHandles, atLeast: 31))
        _ = try await strict.openSession()
        await #expect(throws: MTPError.io(operation: "short timeout", code: 0)) {
            try await strict.handles(storage: Self.phone, parent: 0xFFFF_FFFF)
        }
    }
}

/// Fails the command write for `op` when it is sent with a timeout shorter than `atLeast`. Shared with MutationTests.
final class MinTimeout: MTPTransport {
    private let inner: FakeAndroidResponder
    private let op: UInt16
    private let atLeast: TimeInterval
    var maxPacketSize: Int { inner.maxPacketSize }

    init(_ inner: FakeAndroidResponder, op: UInt16, atLeast: TimeInterval) {
        self.inner = inner; self.op = op; self.atLeast = atLeast
    }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        let isOp = bytes.count >= 8 && UInt16(bytes[6]) | UInt16(bytes[7]) << 8 == op
        if isOp && timeout < atLeast { throw MTPError.io(operation: "short timeout", code: 0) }
        try inner.write(bytes, timeout: timeout)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        try inner.read(maxLength: maxLength, timeout: timeout)
    }
}

/// Times out (or fails with `error`) the first bulk read after `op` is sent, leaving the device's reply
/// queued (a slow phone). `onCancel` sees every cancelTransaction, `onStall` every recoverStall.
private final class SlowReply: MTPTransport {
    private let inner: FakeAndroidResponder
    private let op: UInt16
    private let error: MTPError
    private let onCancel: (@Sendable (UInt32) -> Void)?
    private let onStall: (@Sendable () -> Void)?
    private var timeOutNextRead = false
    var maxPacketSize: Int { inner.maxPacketSize }

    init(_ inner: FakeAndroidResponder, op: UInt16, error: MTPError = .io(operation: "Read", code: 0xE000_02D6),
         onCancel: (@Sendable (UInt32) -> Void)? = nil, onStall: (@Sendable () -> Void)? = nil) {
        self.inner = inner; self.op = op; self.error = error; self.onCancel = onCancel; self.onStall = onStall
    }

    func cancelTransaction(_ tid: UInt32) { onCancel?(tid) }
    func recoverStall() { onStall?() }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        timeOutNextRead = bytes.count >= 8 && UInt16(bytes[6]) | UInt16(bytes[7]) << 8 == op
        try inner.write(bytes, timeout: timeout)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        if timeOutNextRead { timeOutNextRead = false; throw error }
        return try inner.read(maxLength: maxLength, timeout: timeout)
    }
}

/// The phone after an abandoned transaction (G-02-7): the reply to tid 41 sits in bulk-IN, the device-side
/// session is still open, and every command write NAKs until the host reads that reply away (G-02-17: the
/// recovery drains, it sends no class Cancel).
private final class Wedged: MTPTransport {
    private let inner: FakeAndroidResponder
    private var replyRead = false
    var maxPacketSize: Int { inner.maxPacketSize }

    init(_ inner: FakeAndroidResponder) {
        self.inner = inner
        try! inner.write(commandContainer(op: MTPOp.getStorageIDs, tid: 41, params: []), timeout: 1)
    }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        guard replyRead else { throw MTPError.io(operation: "Bulk write", code: 0xE000_02D6) }
        try inner.write(bytes, timeout: timeout)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        let bytes = try inner.read(maxLength: maxLength, timeout: timeout)
        replyRead = true
        return bytes
    }

    /// The USB transport's drain: read until the phone has nothing more to send.
    func cancelTransaction(_ tid: UInt32) {
        while (try? read(maxLength: readChunk, timeout: 0.2)) != nil {}
    }
}
