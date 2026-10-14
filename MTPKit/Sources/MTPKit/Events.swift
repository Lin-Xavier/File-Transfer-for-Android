import Foundation

/// An MTP event from the phone's interrupt endpoint. Android sends object events only for folders listed this
/// session, and none for changes the app makes itself (RESEARCH Pattern 2).
public enum MTPEvent: Sendable, Equatable {
    case objectAdded(UInt32)
    case objectRemoved(UInt32)
    case objectInfoChanged(UInt32)
    case storeAdded(UInt32)
    case storeRemoved(UInt32)
    case storageInfoChanged(UInt32)
    case other(code: UInt16)

    /// One event container: `length u32, type u16, code u16, tid u32, params`. Untrusted bytes, read only through
    /// `Reader`: a truncated header throws `.malformed`; a non-event container, or a known code without its
    /// parameter, is nil. Params are clamped to the bytes received and to 3, as `transact` does (T-02-20).
    static func parse(_ bytes: [UInt8]) throws -> MTPEvent? {
        var r = Reader(bytes)
        let length = try r.u32(), type = try r.u16(), code = try r.u16()
        _ = try r.u32()                                      // transaction ID: unused
        guard type == ContainerType.event else { return nil }
        let declared = min(3, max(0, (Int(length) - 12) / 4))
        var params: [UInt32] = []
        while r.remaining >= 4, params.count < declared { params.append(try r.u32()) }
        let make: (UInt32) -> MTPEvent
        switch code {
        case 0x4002: make = MTPEvent.objectAdded
        case 0x4003: make = MTPEvent.objectRemoved
        case 0x4007: make = MTPEvent.objectInfoChanged
        case 0x4004: make = MTPEvent.storeAdded
        case 0x4005: make = MTPEvent.storeRemoved
        case 0x400C: make = MTPEvent.storageInfoChanged
        default: return .other(code: code)
        }
        return params.first.flatMap(make)
    }
}
