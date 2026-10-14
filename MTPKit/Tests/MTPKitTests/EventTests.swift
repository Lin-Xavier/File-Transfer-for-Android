import Foundation
import Testing
@testable import MTPKit

private func container(_ type: UInt16, code: UInt16, tid: UInt32 = 0, payload: [UInt8] = [], length: UInt32? = nil) -> [UInt8] {
    var c = Payload()
    c.u32(length ?? UInt32(12 + payload.count)); c.u16(type); c.u16(code); c.u32(tid)
    return c.bytes + payload
}

private func event(_ code: UInt16, _ params: [UInt32] = [], length: UInt32? = nil) -> [UInt8] {
    var p = Payload()
    params.forEach { p.u32($0) }
    return container(4, code: code, payload: p.bytes, length: length)
}

private func expectMalformed(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record("expected MTPError.malformed", sourceLocation: sourceLocation)
    } catch let MTPError.malformed(message) {
        #expect(!message.isEmpty, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected MTPError.malformed, got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite struct EventTests {
    static let phone: UInt32 = 0x0001_0001

    @Test(arguments: [
        (0x4002, MTPEvent.objectAdded(7)), (0x4003, .objectRemoved(7)), (0x4007, .objectInfoChanged(7)),
        (0x4004, .storeAdded(7)), (0x4005, .storeRemoved(7)), (0x400C, .storageInfoChanged(7)),
    ] as [(UInt16, MTPEvent)])
    func knownCodes(code: UInt16, expected: MTPEvent) throws {
        #expect(try MTPEvent.parse(event(code, [7])) == expected)
    }

    /// BRWS-08 empty edge: nothing to act on.
    @Test func ignoredPackets() throws {
        #expect(try MTPEvent.parse(container(3, code: 0x2001)) == nil)          // a response, not an event
        #expect(try MTPEvent.parse(event(0x4002)) == nil)                       // ObjectAdded without its handle
        #expect(try MTPEvent.parse(event(0x4008)) == .other(code: 0x4008))      // DeviceInfoChanged
    }

    @Test func truncatedHeaderIsMalformed() {
        expectMalformed { _ = try MTPEvent.parse(Array(event(0x4002, [7]).prefix(8))) }
    }

    /// The length claims two params but only one arrived: the one present is used.
    @Test func paramsClampedToBytesReceived() throws {
        #expect(try MTPEvent.parse(event(0x4003, [9], length: 20)) == .objectRemoved(9))
    }

    // MARK: - entry(_:) reads one object back for an event

    private func openedSession() async throws -> DeviceSession {
        let session = DeviceSession(transport: FakeAndroidResponder())
        _ = try await session.openSession()
        return session
    }

    /// Android reports root objects with parent 0; a wrong mapping would make every root-folder event a no-op.
    @Test func rootObjectHasRootParent() async throws {
        let session = try await openedSession()
        let entry = try #require(try await session.entry(7))
        #expect(entry.parent == 0xFFFF_FFFF)
        #expect(entry.storageID == Self.phone && entry.name == "empty.txt")
    }

    @Test func nestedObjectKeepsItsFolder() async throws {
        let session = try await openedSession()
        #expect(try await session.entry(9)?.parent == 1)
    }

    @Test func goneObjectIsNil() async throws {
        let session = try await openedSession()
        #expect(try await session.entry(9999) == nil)                            // 0x2009
    }
}
