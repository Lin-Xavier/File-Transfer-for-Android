import Foundation

// Dataset layouts follow AOSP MtpServer.cpp (LineageOS 22.2), not just the spec.

public struct DeviceInfo: Sendable, Equatable {
    public var vendorExtensionDesc: String
    public var operationsSupported: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public init(decoding bytes: [UInt8]) throws {
        var r = Reader(bytes)
        _ = try r.u16()                       // standard version
        _ = try r.u32()                       // vendor extension ID
        _ = try r.u16()                       // vendor extension version
        vendorExtensionDesc = try r.string()
        _ = try r.u16()                       // functional mode
        operationsSupported = try r.u16Array()
        _ = try r.u16Array()                  // events
        _ = try r.u16Array()                  // device properties
        _ = try r.u16Array()                  // capture formats
        _ = try r.u16Array()                  // playback formats
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = try r.string()
        serialNumber = try r.string()
    }
}

public struct StorageInfo: Sendable, Equatable, Identifiable {
    public var id: UInt32                     // StorageID
    public var storageType: UInt16
    public var maxCapacity: UInt64
    public var freeSpace: UInt64
    public var description: String

    /// Removable ROM (0x0002) or removable RAM (0x0004), e.g. an SD card.
    public var isRemovable: Bool { storageType == 0x0002 || storageType == 0x0004 }
    public var displayName: String { description.isEmpty ? "Storage" : description }

    public init(id: UInt32, decoding bytes: [UInt8]) throws {
        var r = Reader(bytes)
        self.id = id
        storageType = try r.u16()
        _ = try r.u16()                       // filesystem type
        _ = try r.u16()                       // access capability
        maxCapacity = try r.u64()
        freeSpace = try r.u64()
        _ = try r.u32()                       // free space in objects
        description = try r.string()
        _ = try r.string()                    // volume identifier
    }
}

public struct ObjectEntry: Sendable, Equatable, Identifiable {
    public var id: UInt32                     // object handle
    public var storageID: UInt32
    public var parent: UInt32
    public var format: UInt16
    public var name: String
    public var size: UInt64
    public var modified: Date?

    public var isFolder: Bool { format == 0x3001 }   // Association

    public init(id: UInt32, storageID: UInt32, parent: UInt32, format: UInt16,
                name: String, size: UInt64, modified: Date?) {
        self.id = id; self.storageID = storageID; self.parent = parent; self.format = format
        self.name = name; self.size = size; self.modified = modified
    }
}

/// Raw ObjectInfo dataset. `compressedSize` is capped at 0xFFFFFFFF on Android for files ≥ 4 GiB.
struct ObjectInfo {
    var storageID: UInt32
    var format: UInt16
    var protection: UInt16
    var compressedSize: UInt32
    var thumbFormat: UInt16
    var thumbCompressedSize: UInt32
    var thumbPixWidth: UInt32
    var thumbPixHeight: UInt32
    var imagePixWidth: UInt32
    var imagePixHeight: UInt32
    var imagePixDepth: UInt32
    var parent: UInt32
    var associationType: UInt16
    var associationDesc: UInt32
    var sequenceNumber: UInt32
    var filename: String
    var dateCreated: String
    var dateModified: String
    var keywords: String

    init(decoding bytes: [UInt8]) throws {
        var r = Reader(bytes)
        storageID = try r.u32()
        format = try r.u16()
        protection = try r.u16()
        compressedSize = try r.u32()
        thumbFormat = try r.u16()
        thumbCompressedSize = try r.u32()
        thumbPixWidth = try r.u32()
        thumbPixHeight = try r.u32()
        imagePixWidth = try r.u32()
        imagePixHeight = try r.u32()
        imagePixDepth = try r.u32()
        parent = try r.u32()
        associationType = try r.u16()
        associationDesc = try r.u32()
        sequenceNumber = try r.u32()
        filename = try r.string()
        dateCreated = try r.string()
        dateModified = try r.string()
        keywords = try r.string()
    }
}

/// Parses a PTP date `YYYYMMDDThhmmss[.s][Z|±hhmm]`. AOSP (MtpUtils formatDateTime) sends the phone's wall clock
/// with no zone: callers pass the phone's learned zone as `zone` when known, otherwise it is read in the Mac's zone.
/// A trailing `Z` means UTC and `±hhmm` that offset, whatever `zone` says. Unparseable → nil (the UI shows "--").
public func parsePTPDate(_ s: String, zone: TimeZone? = nil) -> Date? {
    let c = Array(s.utf8)
    guard c.count >= 15, c[8] == UInt8(ascii: "T") else { return nil }
    func num(_ from: Int, _ to: Int) -> Int? {
        let digits = c[from..<to]
        guard digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    guard let year = num(0, 4), let month = num(4, 6), let day = num(6, 8),
          let hour = num(9, 11), let minute = num(11, 13), let second = num(13, 15) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = c.last == UInt8(ascii: "Z") ? .gmt : zone ?? .current
    if let sign = c[15...].firstIndex(where: { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }) {
        guard c.count == sign + 5, let hh = num(sign + 1, sign + 3), let mm = num(sign + 3, sign + 5),
              let zone = TimeZone(secondsFromGMT: (c[sign] == UInt8(ascii: "-") ? -1 : 1) * (hh * 3600 + mm * 60))
        else { return nil }
        cal.timeZone = zone
    }
    let parts = DateComponents(calendar: cal, year: year, month: month, day: day,
                               hour: hour, minute: minute, second: second)
    guard parts.isValidDate else { return nil }
    return parts.date
}

/// The phone's UTC offset in seconds, from the zoneless DateModified of an object the app has just created, read
/// against the Mac's clock at that moment. Rounded to the nearest 15 min (every real zone offset is a multiple), bounded
/// to ±14 h, and nil when the raw difference is more than 5 min off that quarter hour: an old stamp or one that isn't
/// "just now" teaches nothing. A zoned string (`Z` / `±hhmm`) or an unparseable one is nil too.
/// ponytail: fixed 5-min tolerance; widen if a phone with a badly drifting manual clock is seen.
public func inferPhoneUTCOffset(wallClock: String, macNow: Date) -> Int? {
    let c = Array(wallClock.utf8)
    guard c.last != UInt8(ascii: "Z"), c.count < 16 || !c[15...].contains(where: { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }),
          let asUTC = parsePTPDate(wallClock, zone: .gmt) else { return nil }
    let raw = Int(asUTC.timeIntervalSince(macNow).rounded())
    let rounded = Int((Double(raw) / 900).rounded()) * 900
    guard abs(rounded) <= 14 * 3600, abs(raw - rounded) <= 300 else { return nil }
    return rounded
}

/// Where learned phone zones live, keyed by DeviceInfo serial number; a saved nil means the Mac's zone. The app backs
/// it with UserDefaults;
/// closures, because UserDefaults isn't Sendable and the session calls these on its own queue.
public struct PhoneClockStore: Sendable {
    public var load: @Sendable (_ serial: String) -> TimeZone?
    public var save: @Sendable (_ serial: String, _ zone: TimeZone?) -> Void

    public init(load: @escaping @Sendable (_ serial: String) -> TimeZone?,
                save: @escaping @Sendable (_ serial: String, _ zone: TimeZone?) -> Void) {
        self.load = load; self.save = save
    }
}

// MARK: - List sorting and formatting (UI-SPEC "File list")

public enum ObjectSortKey: String, Sendable {
    case name, size, date
}

extension Array where Element == ObjectEntry {
    /// Finder list-view order. `ascending` flips only the primary key; ties always fall back to
    /// name ascending, then handle ascending, so the result is deterministic. Folders are not grouped.
    public func sorted(by key: ObjectSortKey, ascending: Bool) -> [ObjectEntry] {
        sorted { a, b in
            let primary: ComparisonResult = switch key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .size: order(a.isFolder ? -1 : Int64(clamping: a.size), b.isFolder ? -1 : Int64(clamping: b.size))
            case .date: order(a.modified ?? .distantPast, b.modified ?? .distantPast)
            }
            if primary != .orderedSame { return (primary == .orderedAscending) == ascending }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
    }
}

private func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
}

/// Finder-style cell text (UI-SPEC C-18, C-19).
public enum EntryFormat {
    public static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    /// Always the 64-bit size; "--" for folders, "Zero bytes" where ByteCountFormatter would say "Zero KB".
    public static func size(_ e: ObjectEntry) -> String {
        e.isFolder ? "--" : e.size == 0 ? "Zero bytes" : bytes(e.size)
    }

    /// "Today at 14:02", "12 Mar 2026 at 18:40"; "--" when the device gave no parseable date.
    public static func date(_ d: Date?) -> String {
        guard let d else { return "--" }
        return dateFormatter.string(from: d)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
