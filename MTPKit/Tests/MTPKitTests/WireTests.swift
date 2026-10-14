import Foundation
import Testing
@testable import MTPKit

/// Replays scripted bulk-IN packets with the same packet / ZLP rules as the fake.
private final class ScriptedTransport: MTPTransport {
    let maxPacketSize: Int
    private var packets: [[UInt8]]

    init(maxPacketSize: Int = 512, packets: [[UInt8]]) {
        self.maxPacketSize = maxPacketSize
        self.packets = packets
    }

    convenience init(maxPacketSize: Int = 512, containers: [[UInt8]]) {
        self.init(maxPacketSize: maxPacketSize,
                  packets: containers.flatMap { ScriptedTransport.packetize($0, maxPacketSize) })
    }

    static func packetize(_ c: [UInt8], _ mps: Int) -> [[UInt8]] {
        var out = stride(from: 0, to: c.count, by: mps).map { Array(c[$0..<min($0 + mps, c.count)]) }
        if c.count % mps == 0 { out.append([]) }
        return out
    }

    func write(_ bytes: [UInt8], timeout: TimeInterval) throws {}

    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard !packets.isEmpty else { throw MTPError.io(operation: "Read", code: 0xE000_02D6) }
        var out: [UInt8] = []
        while !packets.isEmpty {
            let p = packets.removeFirst()
            out += p
            if out.count >= maxLength || p.count < maxPacketSize { break }
        }
        return out
    }
}

private func container(_ type: UInt16, code: UInt16, tid: UInt32 = 0, payload: [UInt8] = [], length: UInt32? = nil) -> [UInt8] {
    var c = Payload()
    c.u32(length ?? UInt32(12 + payload.count)); c.u16(type); c.u16(code); c.u32(tid)
    return c.bytes + payload
}

private let ok = container(3, code: 0x2001)
private func bytes(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) } }

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

@Suite struct WireTests {
    @Test(arguments: [0, 1, 500, 1012, 5000])
    func dataPhaseRoundTrips(payloadSize: Int) throws {
        let payload = bytes(payloadSize)
        let t = ScriptedTransport(containers: [container(2, code: 0x1001, payload: payload), ok])
        #expect(try transact(t, op: 0x1001, tid: 0).data == payload)
    }

    @Test(arguments: [3000, (1 << 20) - 12, (1 << 20) + 100])
    func unknownLengthDataPhaseEndsOnShortPacket(payloadSize: Int) throws {
        let payload = bytes(payloadSize)
        let t = ScriptedTransport(containers: [container(2, code: 0x1001, payload: payload, length: 0xFFFF_FFFF), ok])
        #expect(try transact(t, op: 0x1001, tid: 0).data == payload)
    }

    @Test func responseParamsAreReturned() throws {
        var p = Payload(); p.u32(7); p.u32(9)
        let t = ScriptedTransport(containers: [container(3, code: 0x2001, payload: p.bytes)])
        #expect(try transact(t, op: 0x1002, tid: 0).params == [7, 9])
    }

    @Test func strayZeroLengthPacketIsSkipped() throws {
        let t = ScriptedTransport(packets: [[]] + ScriptedTransport.packetize(ok, 512))
        #expect(try transact(t, op: 0x1002, tid: 0).data == [])
    }

    @Test func endlessZeroLengthPacketsAreMalformed() {
        let t = ScriptedTransport(packets: Array(repeating: [], count: 100) + ScriptedTransport.packetize(ok, 512))
        expectMalformed { _ = try transact(t, op: 0x1002, tid: 0) }
    }

    @Test func errorResponseThrowsWithCodeAndOp() {
        let t = ScriptedTransport(containers: [container(3, code: 0x2009, tid: 3)])
        #expect(throws: MTPError.response(code: 0x2009, op: 0x1008)) { try transact(t, op: 0x1008, tid: 3) }
    }

    /// 05-MOVE-PROBE Own Subtree: 0x0000 is no MTP answer; the session is out of step, so it must not read as one.
    @Test func zeroResponseCodeIsMalformedNotAResponse() {
        let t = ScriptedTransport(containers: [container(3, code: 0x0000, tid: 3)])
        expectMalformed { _ = try transact(t, op: 0x1008, tid: 3) }
    }

    /// CR-01: the late reply to a transaction abandoned after a timeout is queued ahead of the real one.
    @Test(arguments: [100, 1 << 20])
    func staleReplyFromAbandonedTransactionIsDropped(staleSize: Int) throws {
        let real = bytes(40)
        let t = ScriptedTransport(containers: [
            container(2, code: 0x1008, tid: 6, payload: bytes(staleSize)), container(3, code: 0x2001, tid: 6),
            container(2, code: 0x1008, tid: 7, payload: real), container(3, code: 0x2001, tid: 7),
        ])
        #expect(try transact(t, op: 0x1008, tid: 7).data == real)
    }

    /// IN-06: a data container ending on a packet boundary with no ZLP, so the response lands in the same transfer.
    @Test func responseMergedIntoDataTransferIsRead() throws {
        let payload = bytes(500)                                     // 12 + 500 = one full 512-byte packet
        var p = Payload(); p.u32(42)
        let merged = container(2, code: 0x1001, payload: payload) + container(3, code: 0x2001, payload: p.bytes)
        let t = ScriptedTransport(packets: [Array(merged[..<512]), Array(merged[512...])])
        let result = try transact(t, op: 0x1001, tid: 0)
        #expect(result.data == payload)
        #expect(result.params == [42])
    }

    @Test func dataForAnotherOperationIsMalformed() {
        let t = ScriptedTransport(containers: [container(2, code: 0x1001, payload: bytes(8)), ok])
        expectMalformed { _ = try transact(t, op: 0x1004, tid: 0) }
    }

    @Test func headerLengthBelow12IsMalformed() {
        let t = ScriptedTransport(containers: [container(3, code: 0x2001, length: 8)])
        expectMalformed { _ = try transact(t, op: 0x1001, tid: 0) }
    }

    @Test func unknownContainerTypeIsMalformed() {
        let t = ScriptedTransport(containers: [container(4, code: 0x4002)])
        expectMalformed { _ = try transact(t, op: 0x1001, tid: 0) }
    }

    @Test func dataLengthOverCapIsMalformedBeforeAccumulating() {
        let t = ScriptedTransport(containers: [container(2, code: 0x1001, length: UInt32(12 + (20 << 20)))])
        expectMalformed { _ = try transact(t, op: 0x1001, tid: 0) }
    }

    @Test func unknownLengthDataOverCapIsMalformed() {
        let t = ScriptedTransport(containers: [container(2, code: 0x1001, payload: bytes(5000), length: 0xFFFF_FFFF), ok])
        expectMalformed { _ = try transact(t, op: 0x1001, tid: 0, maxDataLength: 1000) }
    }

    @Test func arrayCountIsBoundedByRemainingBytes() {
        var p = Payload(); p.u32(1_000_000); p.u64(0)
        expectMalformed { var r = Reader(p.bytes); _ = try r.u32Array() }
        expectMalformed { var r = Reader(p.bytes); _ = try r.u16Array() }
    }

    @Test func truncatedReadsAreMalformed() {
        expectMalformed { var r = Reader([1, 2, 3]); _ = try r.u32() }
        expectMalformed { var r = Reader([3, 0x41, 0]); _ = try r.string() }
    }

    @Test func stringsDecode() throws {
        var r0 = Reader([0])
        #expect(try r0.string() == "")
        var p = Payload(); p.string("Pixel 9 · 📱")
        var r = Reader(p.bytes)
        #expect(try r.string() == "Pixel 9 · 📱")
        #expect(r.remaining == 0)
    }

    @Test func errorDetailLines() {
        #expect(MTPError.response(code: 0x201E, op: 0x1002).detail == "OpenSession failed: 0x201E (Session Already Open)")
        #expect(MTPError.response(code: 0x2FFF, op: 0x1004).detail == "GetStorageIDs failed: 0x2FFF")
        #expect(MTPError.io(operation: "Open interface", code: 0xE000_02C5).detail == "Open interface failed: 0xE00002C5")
    }
}

extension WireTests {
    private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ tz: TimeZone = .current) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }

    @Test func localTimeWithoutZone() {
        #expect(parsePTPDate("20260312T184005") == local(2026, 3, 12, 18, 40, 5))
    }

    @Test func tenthsAreIgnored() {
        #expect(parsePTPDate("20260312T184005.0") == local(2026, 3, 12, 18, 40, 5))
    }

    @Test func trailingZIsUTC() {
        #expect(parsePTPDate("20260312T184005Z") == local(2026, 3, 12, 18, 40, 5, TimeZone(identifier: "UTC")!))
    }

    @Test func offsetSuffixIsThatZone() {
        #expect(parsePTPDate("20260312T184005+0530") == local(2026, 3, 12, 13, 10, 5, TimeZone(identifier: "UTC")!))
        #expect(parsePTPDate("20260312T184005.0-0800") == local(2026, 3, 13, 2, 40, 5, TimeZone(identifier: "UTC")!))
    }

    @Test(arguments: ["", "garbage", "20260312X184005", "2026031", "20261340T250000", "20260312T184005+05"])
    func unparseableIsNil(_ s: String) {
        #expect(parsePTPDate(s) == nil)
    }
}

// MARK: Phone clock zone (quick 261007-cyl)

extension WireTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [(28800, 10, 40), (20700, 12, 55), (-12600, 22, 10)])
    func zonelessDateReadsInTheInjectedZone(offset: Int, hour: Int, minute: Int) {
        #expect(parsePTPDate("20260312T184005", zone: TimeZone(secondsFromGMT: offset))
                == local(2026, 3, 12, hour, minute, 5, Self.utc))
    }

    @Test func noZoneIsTheMacZone() {
        #expect(parsePTPDate("20260312T184005", zone: nil) == local(2026, 3, 12, 18, 40, 5))
        #expect(parsePTPDate("20260312T184005", zone: nil) == parsePTPDate("20260312T184005"))
    }

    @Test func aSuffixWinsOverTheInjectedZone() {
        let plus8 = TimeZone(secondsFromGMT: 28800)
        #expect(parsePTPDate("20260312T184005Z", zone: plus8) == local(2026, 3, 12, 18, 40, 5, Self.utc))
        #expect(parsePTPDate("20260312T184005+0530", zone: plus8) == local(2026, 3, 12, 13, 10, 5, Self.utc))
    }

    private var macNow: Date { local(2026, 10, 7, 9, 25, 0, Self.utc)! }

    @Test(arguments: [("20261007T172500", 28800), ("20261007T172537", 28800), ("20261007T151000", 20700),
                      ("20261007T055500", -12600), ("20261007T092500", 0), ("20261007T232500", 50400),
                      ("20261006T212500", -43200)])
    func phoneOffsetIsInferredFromAJustCreatedStamp(wallClock: String, offset: Int) {
        #expect(inferPhoneUTCOffset(wallClock: wallClock, macNow: macNow) == offset)
    }

    @Test(arguments: ["20261008T012600", "20261007T093300", "20261002T120000", "20261007T172500Z",
                      "20261007T172500+0800", "", "garbage"])
    func implausibleStampsTeachNothing(_ wallClock: String) {
        #expect(inferPhoneUTCOffset(wallClock: wallClock, macNow: macNow) == nil)
    }
}
