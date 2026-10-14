import Foundation

/// A Finder-style alert: a plain sentence plus an optional small secondary line (D-25, D-26).
public struct AlertText: Equatable, Sendable {
    public let message: String
    public let detail: String?

    public init(message: String, detail: String?) {
        self.message = message
        self.detail = detail
    }
}

/// Maps a failed rename / new-folder / delete to Finder wording (D-25..D-27).
public enum OperationAlert {
    /// O-03: Finder's sentence for a failure with no more specific wording.
    public static let unexpectedError = "The operation can’t be completed because an unexpected error occurred."

    public static func text(for error: MTPError, name: String) -> AlertText {
        let message: String
        switch error {
        case .response(MTPCode.accessDenied, _), .response(MTPCode.objectWriteProtected, _),
             .response(MTPCode.storeReadOnly, _):
            message = "The phone doesn’t allow changing “\(name)”."
        case .response(MTPCode.storeFull, _):
            message = "The phone is full. Delete some items on the phone, then try again."    // O-02
        default:
            message = unexpectedError
        }
        return AlertText(message: message, detail: error.codeLine ?? error.detail)
    }
}

/// How to connect a phone: the welcome sheet and the no-device screen read the same strings (UI-SPEC S1, S3).
public enum ConnectionText {
    /// W-02 = C-02: the three connect steps, in order.
    public static let steps = [
        "Connect your phone to this Mac with a USB cable.",
        "Unlock your phone.",
        "On your phone, tap the USB notification and choose File Transfer.",
    ]
    /// W-01.
    public static let welcomeTitle = "Welcome to File Transfer for Android"
    /// W-03: text only; the app never launches Image Capture (D-03). The quoted label is Image Capture's own.
    public static let imageCaptureTip = "To keep Photos and Image Capture from taking your phone when you plug it in, "
        + "open Image Capture, select your phone, click ⋯ in the toolbar and set “Connecting this camera opens:” to No application. "
        + "Then quit Image Capture."
    /// W-04.
    public static let dragTip = "Drag files and folders between this window and Finder to copy them."
    /// E-09: the session couldn't be opened (D-08).
    public static let connectFailedTitle = "Can’t connect to your phone"
    /// E-10: the phone stopped answering a listing (D-08).
    public static let lostContactTitle = "Lost contact with your phone"
    /// E-11: the body under E-09 and E-10.
    public static let retryBody = "Try reconnecting or restarting your phone."
    /// E-12: the selected storage is refused or left the list (D-09).
    public static let storageUnavailableTitle = "Can’t read this storage"
    /// E-13: the body under E-12, naming the storage.
    public static func storageUnavailableBody(_ storage: String) -> String {
        "Your phone isn’t sharing “\(storage)” right now. If it’s an SD card, check that it’s inserted, then click Retry."
    }
}

/// Outcome of checking a typed name before anything is sent to the phone.
public enum NameVerdict: Equatable, Sendable {
    case ok, unchanged, empty, invalidCharacter, reserved, tooLong, taken
}

/// Client-side name rules. AOSP's rename path has no path check, and `Payload.string` truncates
/// silently past 254 UTF-16 units, so this is the only guard (RESEARCH Pitfalls 3-4, T-02-29).
public enum NameRules {
    /// `current` is the item's own name when renaming (nil for a new item); it never counts as a clash.
    public static func validate(_ name: String, current: String?, siblings: [String]) -> NameVerdict {
        if name == current { return .unchanged }
        if name.isEmpty { return .empty }
        if name.contains("/") || name.contains(":") { return .invalidCharacter }
        if name == "." || name == ".." { return .reserved }
        if name.utf16.count > 254 { return .tooLong }
        let typed = name.precomposedStringWithCanonicalMapping
        let clash = siblings.contains {
            $0 != current && $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(typed) == .orderedSame
        }
        return clash ? .taken : .ok
    }

    /// Finder's new-folder name: `base`, else "`base` 2", "`base` 3"… the first one no sibling has, compared like
    /// `validate` (NFC, case-insensitive) (D-19).
    public static func uniqueName(_ base: String = "untitled folder", among siblings: [String]) -> String {
        let taken = Set(siblings.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var name = base, n = 1
        while taken.contains(name.precomposedStringWithCanonicalMapping.lowercased()) {
            n += 1
            name = "\(base) \(n)"
        }
        return name
    }

    /// Keep Both's name for an incoming item whose name is taken (D-07): "IMG 2.jpg", "IMG 3.jpg"… the first that no
    /// name in `taken` has, compared like `uniqueName` (NFC, case-insensitive). The number goes before the extension
    /// (`pathExtension`: ".nomedia" has none, "archive.tar.gz" splits at ".gz"); a folder never splits ("Photos 2").
    /// Inserting " n" keeps the result one path component (T-04-03).
    public static func keepBothName(_ name: String, isFolder: Bool, among taken: [String]) -> String {
        let keys = Set(taken.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !keys.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Finder's rejection wording (D-21); nil when the name is accepted.
    public static func alert(for verdict: NameVerdict, name: String) -> AlertText? {
        switch verdict {
        case .ok, .unchanged:
            return nil
        case .empty:
            return AlertText(message: "Please enter a name.", detail: nil)
        case .invalidCharacter, .reserved:
            return AlertText(message: "The name “\(name)” can’t be used.",
                             detail: "Try using a name with fewer characters, or with no punctuation marks.")
        case .tooLong:
            return AlertText(message: "The name “\(name)” is too long.", detail: "Try using a name with fewer characters.")
        case .taken:
            return AlertText(message: "The name “\(name)” is already taken. Please choose a different name.", detail: nil)
        }
    }
}
