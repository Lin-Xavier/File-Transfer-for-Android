import Foundation
import IOKit
import os

// MARK: - Transport seam

/// Bulk-pipe level transport. `USBTransport` (IOUSBHost) and `FakeAndroidResponder` conform.
public protocol MTPTransport: AnyObject {
    var maxPacketSize: Int { get }
    func write(_ bytes: [UInt8], timeout: TimeInterval) throws
    /// One bulk-IN transfer: returns when `maxLength` bytes arrived or a short / zero-length packet ended it.
    func read(maxLength: Int, timeout: TimeInterval) throws -> [UInt8]
    /// Starts reading the interrupt endpoint; `yield` gets each raw event container, on the transport's IO queue.
    /// Called once, after OpenSession (AOSP sends events only while a session is open).
    func startEvents(_ yield: @escaping @Sendable ([UInt8]) -> Void)
    /// Clears a transaction the session abandoned by reading away its reply; best effort, never throws.
    /// Without it Android's MtpServer stays blocked writing that reply and NAKs every later command (G-02-7).
    func cancelTransaction(_ tid: UInt32)
    /// Clears endpoints the phone halted mid-transfer. Called by the session only after a bulk call failed with a
    /// pipe stall (0xE0005000), before `cancelTransaction`. Best effort, never throws (02-REVIEW WR-04).
    func recoverStall()
}

extension MTPTransport {
    /// No interrupt pipe (the fake): no events.
    public func startEvents(_ yield: @escaping @Sendable ([UInt8]) -> Void) {}
    /// No phone (the fake): nothing to drain.
    public func cancelTransaction(_ tid: UInt32) {}
    /// No phone (the fake): no halted endpoints.
    public func recoverStall() {}
}

// MARK: - Errors

public enum MTPError: Error, Sendable, Equatable {
    case deviceGone
    case exclusiveAccess(owner: String?)
    case response(code: UInt16, op: UInt16)
    case malformed(String)
    case io(operation: String, code: UInt32)

    /// The C-13 detail line shown under an error state.
    public var detail: String {
        switch self {
        case .deviceGone:
            return "The phone was disconnected."
        case let .exclusiveAccess(owner):
            // No fixed code: macOS 27 refuses a held interface with 0xE00002C9, not 0xE00002C5 (01-SPIKE-REPORT).
            return "Open interface failed: in use by " + (owner ?? "another process")
        case let .response(code, op):
            let hex = String(format: "0x%04X", code)
            if let name = MTPCode.names[code] { return "\(MTPOp.name(op)) failed: \(hex) (\(name))" }
            return "\(MTPOp.name(op)) failed: \(hex)"
        case let .malformed(message):
            return "Unexpected data from the phone (\(message))"
        case let .io(operation, code):
            return "\(operation) failed: " + String(format: "0x%08X", code)
        }
    }

    /// The D-26 secondary line under a mutation alert, e.g. "MTP error 0x200F (Access Denied)". Nil unless the phone answered.
    public var codeLine: String? {
        guard case let .response(code, _) = self else { return nil }
        let line = String(format: "MTP error 0x%04X", code)
        return MTPCode.names[code].map { "\(line) (\($0))" } ?? line
    }

    /// The phone answered Invalid Object Handle (0x2009): the object is already gone.
    public var isInvalidObjectHandle: Bool {
        if case .response(MTPCode.invalidObjectHandle, _) = self { true } else { false }
    }

    /// D-09: the phone answered Invalid StorageID (0x2008) or Store Not Available (0x2013), so the storage isn't shared
    /// right now. AOSP only ever answers 0x2008 (RESEARCH Pitfall 5).
    public var isStorageUnavailable: Bool {
        if case let .response(code, _) = self { code == MTPCode.invalidStorageID || code == MTPCode.storeNotAvailable }
        else { false }
    }

    /// The phone answered with an error code: the session is still in step and usable.
    public var isResponse: Bool {
        if case .response = self { true } else { false }
    }
}

/// True for kIOReturnExclusiveAccess (0xE00002C5), whether the NSError code carries it signed or unsigned.
public func isExclusiveAccess(_ error: NSError) -> Bool {
    UInt32(truncatingIfNeeded: error.code) == UInt32(bitPattern: kIOReturnExclusiveAccess)
}

// MARK: - Constants

enum MTPOp {
    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let closeSession: UInt16 = 0x1003
    static let getStorageIDs: UInt16 = 0x1004
    static let getStorageInfo: UInt16 = 0x1005
    static let getObjectHandles: UInt16 = 0x1007
    static let getObjectInfo: UInt16 = 0x1008
    static let getObjectPropValue: UInt16 = 0x9803
    static let deleteObject: UInt16 = 0x100B
    static let sendObjectInfo: UInt16 = 0x100C
    static let setObjectPropValue: UInt16 = 0x9804
    static let getPartialObject64: UInt16 = 0x95C1
    static let sendObject: UInt16 = 0x100D
    static let sendPartialObject: UInt16 = 0x95C2
    static let beginEditObject: UInt16 = 0x95C4
    static let endEditObject: UInt16 = 0x95C5
    static let moveObject: UInt16 = 0x1019

    static let names: [UInt16: String] = [
        getDeviceInfo: "GetDeviceInfo", openSession: "OpenSession", closeSession: "CloseSession",
        getStorageIDs: "GetStorageIDs", getStorageInfo: "GetStorageInfo",
        getObjectHandles: "GetObjectHandles", getObjectInfo: "GetObjectInfo",
        getObjectPropValue: "GetObjectPropValue", deleteObject: "DeleteObject",
        sendObjectInfo: "SendObjectInfo", setObjectPropValue: "SetObjectPropValue",
        getPartialObject64: "GetPartialObject64", sendObject: "SendObject", sendPartialObject: "SendPartialObject",
        beginEditObject: "BeginEditObject", endEditObject: "EndEditObject", moveObject: "MoveObject",
    ]
    static func name(_ op: UInt16) -> String { names[op] ?? String(format: "Operation 0x%04X", op) }
}

enum MTPCode {
    static let ok: UInt16 = 0x2001
    static let generalError: UInt16 = 0x2002
    static let sessionNotOpen: UInt16 = 0x2003
    static let operationNotSupported: UInt16 = 0x2005
    static let invalidStorageID: UInt16 = 0x2008
    static let storeNotAvailable: UInt16 = 0x2013
    static let invalidObjectHandle: UInt16 = 0x2009
    static let sessionAlreadyOpen: UInt16 = 0x201E
    static let storeFull: UInt16 = 0x200C
    static let objectWriteProtected: UInt16 = 0x200D
    static let storeReadOnly: UInt16 = 0x200E
    static let accessDenied: UInt16 = 0x200F
    static let transactionCancelled: UInt16 = 0x201F

    static let names: [UInt16: String] = [
        0x2002: "General Error", 0x2003: "Session Not Open", 0x2005: "Operation Not Supported",
        0x2008: "Invalid StorageID", 0x2009: "Invalid Object Handle", 0x2013: "Store Not Available",
        0x2019: "Device Busy", 0x201D: "Invalid Parameter", 0x201E: "Session Already Open",
        0x201F: "Transaction Cancelled",
        0x200C: "Store Full", 0x200D: "Object Write-Protected", 0x200E: "Store Read-Only",
        0x200F: "Access Denied", 0x2012: "Partial Deletion", 0x201A: "Invalid Parent Object",
        0xA809: "Object Too Large", 0xA80A: "Object Prop Not Supported",
    ]
}

enum ContainerType {
    static let command: UInt16 = 1
    static let data: UInt16 = 2
    static let response: UInt16 = 3
    static let event: UInt16 = 4
}

/// Bulk-IN request size: 1 MiB, a multiple of every wMaxPacketSize (64 / 512 / 1024).
let readChunk = 1 << 20

let mtpLog = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "mtp")

// MARK: - Reader (untrusted device bytes: every access bounds-checked)

struct Reader {
    let bytes: [UInt8]
    var i = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - i }

    private mutating func uint<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { throw MTPError.malformed("truncated") }
        var v: T = 0
        for k in 0..<n { v |= T(bytes[i + k]) << (8 * k) }
        i += n
        return v
    }

    mutating func u8() throws -> UInt8 { try uint(UInt8.self) }
    mutating func u16() throws -> UInt16 { try uint(UInt16.self) }
    mutating func u32() throws -> UInt32 { try uint(UInt32.self) }
    mutating func u64() throws -> UInt64 { try uint(UInt64.self) }

    /// u8 count INCLUDING the NUL (0 = empty), then UTF-16LE units. Lossy, never traps.
    mutating func string() throws -> String {
        let n = Int(try u8())
        guard n > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for _ in 0..<n { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= remaining / 2 else { throw MTPError.malformed("array count \(count)") }
        return try (0..<count).map { _ in try u16() }
    }

    mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        guard count <= remaining / 4 else { throw MTPError.malformed("array count \(count)") }
        return try (0..<count).map { _ in try u32() }
    }
}

/// The GetDeviceStatus (class request 0x67) payload per AOSP: u16 wLength, u16 code, then u16 entries AOSP lists as
/// endpoints. On Android they come from FunctionFS's FUNCTIONFS_ENDPOINT_REVMAP and read 0xFF (never assigned), so
/// they are kept for logging and never used to pick pipes (G-03-1). Untrusted: parsing stops at min(wLength, bytes received), so a short or lying status never traps; zero entries
/// (padding) are ignored. AOSP's wLength may also count no endpoints at all (sizeof-pointer quirk).
struct DeviceStatus: Equatable {
    var code: UInt16 = 0
    var endpoints: [UInt8] = []

    init(_ bytes: [UInt8]) {
        var r = Reader(bytes)
        guard let length = try? r.u16(), let c = try? r.u16() else { return }
        code = c
        let end = min(Int(length), bytes.count)
        while r.i + 2 <= end, let v = try? r.u16() {
            if v != 0 { endpoints.append(UInt8(truncatingIfNeeded: v)) }
        }
    }
}

/// Little-endian MTP dataset writer (the fake's side of `Reader`).
struct Payload {
    var bytes: [UInt8] = []
    mutating func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u16(_ v: UInt16) { put(v) }
    mutating func u32(_ v: UInt32) { put(v) }
    mutating func u64(_ v: UInt64) { put(v) }
    mutating func string(_ s: String) {
        guard !s.isEmpty else { bytes.append(0); return }
        let units = Array(s.utf16.prefix(254)) + [0]    // u8 count includes the NUL
        bytes.append(UInt8(units.count))
        units.forEach { u16($0) }
    }
    mutating func u16Array(_ a: [UInt16]) { u32(UInt32(a.count)); a.forEach { u16($0) } }
    mutating func u32Array(_ a: [UInt32]) { u32(UInt32(a.count)); a.forEach { u32($0) } }
}

// MARK: - Containers and the transaction runner

func commandContainer(op: UInt16, tid: UInt32, params: [UInt32]) -> [UInt8] {
    var c = Payload()
    c.u32(UInt32(12 + 4 * params.count)); c.u16(ContainerType.command); c.u16(op); c.u32(tid)
    params.forEach { c.u32($0) }
    return c.bytes
}

/// Runs one MTP transaction: command → optional data phase (`dataOut` host → device, or device → host) → response.
/// Throws `MTPError.response` for any code other than OK, `.malformed` for hostile framing.
/// Containers carrying another transaction ID are late replies to an abandoned transaction: they are
/// read in full and dropped, so they can never be taken as this transaction's reply (CR-01).
func transact(_ t: any MTPTransport, op: UInt16, tid: UInt32, params: [UInt32] = [], dataOut: [UInt8]? = nil,
              maxDataLength: Int = 16 << 20, timeout: TimeInterval = 5) throws -> (data: [UInt8], params: [UInt32]) {
    mtpLog.debug("→ \(MTPOp.name(op), privacy: .public) tid \(tid) params \(params, privacy: .public)")
    // The ZLP check below divides by the device's wMaxPacketSize; a device claiming 0 fails here instead (WR-05).
    if dataOut != nil, t.maxPacketSize <= 0 { throw MTPError.malformed("wMaxPacketSize \(t.maxPacketSize)") }
    // The container length is a u32 that includes the 12-byte header; checked before the command goes out (IN-02).
    if let dataOut, dataOut.count > Int(UInt32.max) - 12 { throw MTPError.malformed("data phase of \(dataOut.count) bytes") }
    try t.write(commandContainer(op: op, tid: tid, params: params), timeout: timeout)
    if let dataOut {
        // Header and payload in ONE bulk transfer: AOSP reads the data phase with one read, so a header written
        // on its own would arrive as a 12-byte short packet and end the phase early.
        var c = Payload()
        c.u32(UInt32(12 + dataOut.count)); c.u16(ContainerType.data); c.u16(op); c.u32(tid)
        let container = c.bytes + dataOut
        try t.write(container, timeout: timeout)
        // A container that fills its last packet exactly needs a ZLP, or the phone waits for more data.
        if container.count % t.maxPacketSize == 0 { try t.write([], timeout: timeout) }
    }
    var data: [UInt8] = []
    var stale = 0, strayZLPs = 0
    var pending: [UInt8] = []       // bytes past a data container's end: the device skipped the ZLP (IN-06)
    while true {
        var buf = pending.isEmpty ? try t.read(maxLength: readChunk, timeout: timeout) : pending
        pending = []
        if buf.isEmpty {                                              // stray ZLP before a header
            // Bounded: the per-read timeout never fires while a faulty device keeps sending ZLPs (WR-04).
            strayZLPs += 1
            guard strayZLPs <= 4 else { throw MTPError.malformed("\(strayZLPs) stray zero-length packets") }
            continue
        }
        var r = Reader(buf)
        let length = try r.u32(), type = try r.u16(), code = try r.u16(), rtid = try r.u32()
        guard length >= 12 || length == 0xFFFF_FFFF else { throw MTPError.malformed("container length \(length)") }
        guard type == ContainerType.data || type == ContainerType.response else {
            throw MTPError.malformed("container type \(type)")
        }
        if type == ContainerType.data {
            (buf, pending) = try readDataContainer(buf, length: length, t, maxDataLength: maxDataLength, timeout: timeout)
        }
        guard rtid == tid else {
            // One abandoned transaction leaves at most a data and a response container behind.
            stale += 1
            guard stale <= 4 else { throw MTPError.malformed("\(stale) containers from other transactions") }
            mtpLog.error("dropped stale container tid \(rtid) (expected \(tid))")
            continue
        }
        if type == ContainerType.data {
            guard code == op else { throw MTPError.malformed("data for \(MTPOp.name(code)), expected \(MTPOp.name(op))") }
            data = Array(buf.dropFirst(12))
            continue
        }
        // 0x0000 is no MTP code: the phone's session is out of step (05-MOVE-PROBE Own Subtree), so callers take
        // their lost-session path (reconnect) instead of showing it as the phone's answer.
        if code == 0x0000 { throw MTPError.malformed("response code 0x0000 for \(MTPOp.name(op))") }
        guard code == MTPCode.ok else {
            mtpLog.debug("← \(MTPOp.name(op), privacy: .public) response 0x\(String(code, radix: 16), privacy: .public)")
            throw MTPError.response(code: code, op: op)
        }
        var ps: [UInt32] = []
        let end = min(Int(length), buf.count)
        while r.i + 4 <= end { ps.append(try r.u32()) }
        mtpLog.debug("← \(MTPOp.name(op), privacy: .public) OK data \(data.count) bytes")
        return (data, ps)
    }
}

/// Reads the rest of a data container whose first transfer is `first`, capped at `maxDataLength` payload bytes.
/// Also returns any bytes past its end: the next container, merged in when the device sent no ZLP between them.
private func readDataContainer(_ first: [UInt8], length: UInt32, _ t: any MTPTransport,
                               maxDataLength: Int, timeout: TimeInterval) throws -> (container: [UInt8], rest: [UInt8]) {
    var buf = first
    if length == 0xFFFF_FFFF {
        // Unknown length: the phase ends on the first transfer shorter than requested.
        var last = buf.count
        while last == readChunk {
            guard buf.count - 12 <= maxDataLength else { throw MTPError.malformed("data phase over \(maxDataLength) bytes") }
            let more = try t.read(maxLength: readChunk, timeout: timeout)
            buf += more
            last = more.count
        }
        guard buf.count - 12 <= maxDataLength else { throw MTPError.malformed("data phase over \(maxDataLength) bytes") }
        return (buf, [])
    }
    guard Int(length) - 12 <= maxDataLength else { throw MTPError.malformed("data length \(length)") }
    while buf.count < Int(length) {
        let more = try t.read(maxLength: readChunk, timeout: timeout)
        guard !more.isEmpty else { throw MTPError.malformed("data phase ended early") }
        buf += more
    }
    return (Array(buf[..<Int(length)]), Array(buf[Int(length)...]))
}
