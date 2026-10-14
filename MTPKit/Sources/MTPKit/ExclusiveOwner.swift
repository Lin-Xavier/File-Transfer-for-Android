import Darwin
import Foundation
import IOKit

/// The `UsbExclusiveOwner` string of a busy interface. Free-form text from other processes:
/// parsed as data only (substring + digit run), never executed or interpreted.
public struct ExclusiveOwner: Sendable, Equatable {
    public let raw: String
    /// The number after "pid", else the first decimal run, when positive. A hint only: never signalled directly.
    public let pid: pid_t?
    public let isCameraDaemon: Bool

    public init(raw: String) {
        self.raw = raw
        isCameraDaemon = raw.lowercased().contains("ptpcamerad")
        // A labelled PID first: in "Smart Switch 4, pid 812" the first digit run is part of the name (IN-04).
        let digits = raw.firstMatch(of: /pid\s+(\d+)/)?.1
            ?? raw.drop { !$0.isASCII || !$0.isNumber }.prefix { $0.isASCII && $0.isNumber }
        if let n = Int32(digits), n > 0 { pid = n } else { pid = nil }
    }

    /// `UsbExclusiveOwner` on the interface itself, then on its direct parent (the IOUSBHostDevice).
    /// Deliberately not a recursive registry search.
    public static func read(service: io_service_t) -> String? {
        if let s = property(service) { return s }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return property(parent)
    }

    /// `UsbExclusiveOwner` on `entry` alone (no parent fallback).
    static func property(_ entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(entry, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

extension ExclusiveOwner {
    /// The owner string without PID noise: macOS 27 writes `pid 61256, ptpcamerad` (owner-busy.txt).
    /// Drops "pid" labels, standalone digit runs and the brackets/commas left behind; nil when nothing remains.
    /// ponytail: also drops a standalone number that is part of a real name ("Foo 2" → "Foo").
    public var processName: String? {
        let name = raw.replacing(/(?i)\bpid\b|\b\d+\b/, with: "")
            .replacing(/\(\s*\)|\[\s*\]/, with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:#")))
        return name.isEmpty ? nil : name
    }
}

/// Which busy screen the detail pane shows (UI-SPEC claimed rows).
public enum BusyScreen: Sendable, Equatable {
    /// C-04 + C-05: ptpcamerad holds the phone, one Release is still allowed (D-02).
    case cameraDaemonCanRelease
    /// C-04 + C-06: ptpcamerad took the phone back after this plug-in's release (D-03).
    case cameraDaemonReclaimed
    /// C-04 + C-06b: release unsupported, or the signal failed so nothing was released (D-05).
    case cameraDaemonReleaseUnavailable
    /// C-07 + C-08: another process (or an unknown one) holds the phone; Retry only (D-04).
    case otherOwner(ExclusiveOwner?)
}

public enum BusyPolicy {
    /// D-03: never signal ptpcamerad twice for one plug-in; no kill loops.
    public static let maxReleasesPerPlugIn = 1

    public static func screen(owner: ExclusiveOwner?, releasesThisPlugIn: Int, releaseSupported: Bool,
                              lastReleaseFailed: Bool) -> BusyScreen {
        guard let owner, owner.isCameraDaemon else { return .otherOwner(owner) }
        if !releaseSupported || lastReleaseFailed { return .cameraDaemonReleaseUnavailable }
        if releasesThisPlugIn >= maxReleasesPerPlugIn { return .cameraDaemonReclaimed }
        return .cameraDaemonCanRelease
    }
}

// ponytail: debug builds only (the HardwareSpike suite and its safety tests). The spike decision is
// guidance-only (01-SPIKE-REPORT ## Decision: ptpcamerad ignored SIGTERM 4/4 on macOS 27), so the signed
// app ships no kill(2) path and BusyPolicy's release screens stay unreachable (IN-02). No phase schedules
// Release; bring this back into Release builds only if a later macOS lets ptpcamerad go on SIGTERM.
#if DEBUG
/// Finds and politely stops macOS's camera daemon. Only the exact binary at `path` is ever signalled,
/// only with SIGTERM, via kill(2) — no shell, no helper processes.
public enum CameraDaemon {
    public static let path = "/usr/libexec/ptpcamerad"

    /// PIDs whose executable path is exactly `path`.
    public static func pids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 16)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.prefix(Int(max(got, 0))).filter(isCameraDaemon)
    }

    /// SIGTERM `pid` only if it is still ptpcamerad (re-checked right before the signal: PID reuse).
    /// Returns 0 when the signal was delivered, otherwise an errno (ESRCH when the path no longer matches).
    @discardableResult
    public static func terminate(_ pid: pid_t) -> Int32 {
        guard isCameraDaemon(pid) else { return ESRCH }
        return kill(pid, SIGTERM) == 0 ? 0 : errno
    }

    private static func isCameraDaemon(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }                 // 0 / -1 would address process groups
        var p = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &p, UInt32(p.count)) > 0 else { return false }
        return String(decoding: p.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path
    }
}
#endif
