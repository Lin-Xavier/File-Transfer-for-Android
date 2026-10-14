import Foundation
import Testing
@testable import MTPKit

// Decoders and transact() against real bytes captured by HardwareSpike (Plan 01-03).
// The `pixel-` prefix is historical: the captures come from a Xiaomi MIX 4 (01-SPIKE-REPORT.md).
@Suite struct DatasetTests {
    @Test func deviceInfo() throws {
        let info = try DeviceInfo(decoding: fixture("pixel-deviceinfo", "bin"))
        #expect(!info.model.isEmpty)
        #expect(info.operationsSupported.contains(0x1001))
        #expect(info.operationsSupported.contains(0x1008))
        #expect(!info.serialNumber.isEmpty)
        #expect(info.serialNumber.allSatisfy { $0 == "X" })
    }

    @Test func storageIDsAndInfo() throws {
        var r = Reader(try fixture("pixel-storageids", "bin"))
        let ids = try r.u32Array()
        #expect(!ids.isEmpty)
        let info = try StorageInfo(id: ids[0], decoding: fixture("pixel-storageinfo", "bin"))
        #expect(!info.description.isEmpty)
        #expect(info.freeSpace <= info.maxCapacity)
    }

    @Test func dcimObjectInfo() throws {
        let info = try ObjectInfo(decoding: fixture("pixel-objectinfo-dcim", "bin"))
        #expect(info.filename == "DCIM")
        #expect(info.format == 0x3001)
    }

    @Test(arguments: [("pixel-wire-getstorageids", "pixel-storageids"),
                      ("pixel-wire-getstorageinfo", "pixel-storageinfo")])
    func wireReplay(wire: String, data: String) throws {
        let records = try parseRecords(fixture(wire, "bin"))
        let out = try #require(records.first { $0.out }).bytes
        var c = Reader(out)
        _ = try c.u32(); _ = try c.u16()                          // length, type
        let op = try c.u16(), tid = try c.u32()
        var params: [UInt32] = []
        while c.remaining >= 4 { params.append(try c.u32()) }

        let replay = ReplayTransport(records.filter { !$0.out }.map(\.bytes))
        let result = try transact(replay, op: op, tid: tid, params: params)
        #expect(replay.written == [out])
        #expect(result.data == (try fixture(data, "bin")))
    }

    @Test func ownerStrings() throws {
        let lines = String(decoding: try fixture("owner-busy", "txt"), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let owners = lines.map(ExclusiveOwner.init(raw:))           // must not trap
        // 01-SPIKE-REPORT ## Busy Device: the interface owner is ptpcamerad, with its PID.
        let iface = try #require(owners.first { $0.raw.hasPrefix("iface:") })
        #expect(iface.isCameraDaemon)
        #expect(iface.pid != nil)
    }
}

private func fixture(_ name: String, _ ext: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return Array(try Data(contentsOf: url))
}

/// Records written by HardwareSpike's RecordingTransport: u8 direction (0 OUT, 1 IN), u32 LE length, bytes.
private func parseRecords(_ bytes: [UInt8]) throws -> [(out: Bool, bytes: [UInt8])] {
    var r = Reader(bytes)
    var records: [(out: Bool, bytes: [UInt8])] = []
    while r.remaining > 0 {
        let direction = try r.u8()
        let n = Int(try r.u32())
        guard n <= r.remaining else { throw MTPError.malformed("truncated record") }
        records.append((direction == 0, Array(bytes[r.i..<r.i + n])))
        r.i += n
    }
    return records
}

/// Plays back recorded bulk-IN reads in order and records what transact writes.
private final class ReplayTransport: MTPTransport {
    private var reads: [[UInt8]]
    var written: [[UInt8]] = []
    init(_ reads: [[UInt8]]) { self.reads = reads }

    var maxPacketSize: Int { 512 }
    func write(_ bytes: [UInt8], timeout: TimeInterval) throws { written.append(bytes) }
    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard !reads.isEmpty else { throw MTPError.deviceGone }
        return reads.removeFirst()
    }
}
