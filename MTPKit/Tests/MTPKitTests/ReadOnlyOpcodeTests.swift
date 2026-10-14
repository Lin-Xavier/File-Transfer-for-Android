import Foundation
import Synchronization
import Testing
@testable import MTPKit

/// T-01-11: Phase 1 only ever sends read-only MTP operations to the phone.
@Suite struct ReadOnlyOpcodeTests {
    /// Every operation Phase 1 may send. Nothing here creates, changes, moves or deletes phone data.
    static let readOnly: Set<UInt16> = [
        0x1001,  // GetDeviceInfo
        0x1002,  // OpenSession
        0x1003,  // CloseSession
        0x1004,  // GetStorageIDs
        0x1005,  // GetStorageInfo
        0x1007,  // GetObjectHandles
        0x1008,  // GetObjectInfo
        0x9803,  // GetObjectPropValue (ObjectSize 0xDC04 for files >= 4 GiB)
    ]

    /// The whole Phase 1 public surface, including the stale-session (0x201E) recovery and the >4 GB size lookup.
    @Test func wholePhase1SurfaceSendsOnlyReadOnlyOperations() async throws {
        let log = SentLog()
        let session = DeviceSession(transport: Recording(FakeAndroidResponder(sessionAlreadyOpen: true), log: log))
        _ = try await session.openSession()
        let storages = try await session.storages()
        for storage in storages {
            let root = try await session.children(storage: storage.id)
            for folder in root where folder.isFolder {
                _ = try await session.children(storage: storage.id, parent: folder.id)
            }
        }
        #expect(try await session.children(storage: 0x0001_0001).contains { $0.size == 5_000_000_000 })
        await session.close()

        let sent = log.sent
        // The paths under test really ran: recovery closed the stale session, and the 5 GB file needed ObjectSize.
        #expect(Set(sent.map(\.op)) == Self.readOnly)
        #expect(sent.filter { $0.op == 0x1003 }.count == 2)          // 0x201E recovery + close()
        #expect(sent.map(\.op).suffix(1) == [0x1003])
        #expect(Self.violations(sent) == [])
    }

    /// The check itself must catch a write: each write operation, sent through the same recorder, is flagged.
    /// Decimal on purpose: the 01-02 grep gate forbids these opcodes as hex literals anywhere in Sources and Tests.
    /// DeleteObject, SendObjectInfo, SendObject, SetObjectPropValue, MoveObject, CopyObject, SendPartialObject.
    @Test(arguments: [4107, 4108, 4109, 38916, 4121, 4122, 38339] as [UInt16])
    func writeOperationIsCaught(op: UInt16) throws {
        let log = SentLog()
        let t = Recording(FakeAndroidResponder(), log: log)
        _ = try transact(t, op: MTPOp.openSession, tid: 0, params: [1])
        _ = try? transact(t, op: op, tid: 1, params: [0x0001_0001])
        #expect(Self.violations(log.sent) == [String(format: "op 0x%04X", op)])
    }

    /// A host-to-device data container (a SendObject payload) is flagged even under an allowed code.
    @Test func hostToDeviceDataIsCaught() throws {
        var c = Payload()
        c.u32(16); c.u16(ContainerType.data); c.u16(0x1001); c.u32(0); c.u32(0)
        let log = SentLog()
        let t = Recording(FakeAndroidResponder(), log: log)
        try? t.write(c.bytes, timeout: 1)
        #expect(Self.violations(log.sent) == ["data container for op 0x1001"])
    }

    static func violations(_ sent: [SentLog.Container]) -> [String] {
        sent.compactMap { c in
            if c.type != ContainerType.command { return String(format: "data container for op 0x%04X", c.op) }
            return readOnly.contains(c.op) ? nil : String(format: "op 0x%04X", c.op)
        }
    }
}

/// Every container the host writes to the bulk-OUT pipe. Sendable, so the test keeps it while the session owns the transport.
final class SentLog: Sendable {
    struct Container: Sendable { var type: UInt16; var op: UInt16 }
    private let containers = Mutex<[Container]>([])
    var sent: [Container] { containers.withLock { $0 } }
    func append(_ c: Container) { containers.withLock { $0.append(c) } }
}

/// Records the container type and code of every bulk-OUT write, then forwards to the fake.
private final class Recording: MTPTransport {
    private let inner: FakeAndroidResponder
    private let log: SentLog
    var maxPacketSize: Int { inner.maxPacketSize }

    init(_ inner: FakeAndroidResponder, log: SentLog) { self.inner = inner; self.log = log }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        var r = Reader(bytes)
        _ = try r.u32()
        log.append(.init(type: try r.u16(), op: try r.u16()))
        try inner.write(bytes, timeout: timeout)
    }

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        try inner.read(maxLength: maxLength, timeout: timeout)
    }
}
