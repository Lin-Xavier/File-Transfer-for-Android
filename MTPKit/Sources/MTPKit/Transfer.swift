import Foundation
import os

// The copy engine. No actor annotations: its async functions run off the MainActor (RESEARCH Anti-Patterns), and
// every phone call is one short DeviceSession call, so browsing interleaves between chunks (D-22).

let transferLog = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "transfer")

/// An item that couldn't be copied; `detail` says why. `key` is the item itself, never its name (two "IMG.jpg" from
/// different folders differ, RESEARCH Pitfall 11). `retryable` is false when trying again can't help: a name one side
/// can't hold, a link, a file too large for the volume, an item or folder that is gone (CONTEXT discretion).
public struct TransferFailure: Sendable, Equatable {
    public var name: String
    public var detail: String
    public var key: ItemKey?
    public var retryable: Bool

    public init(name: String = "", detail: String = "", key: ItemKey? = nil, retryable: Bool = true) {
        self.name = name; self.detail = detail; self.key = key; self.retryable = retryable
    }
}

/// What a finished, stopped or interrupted job did: facts only; the queue decides what the failed row lists (D-15).
/// `unreached`: when the run ended early, the item in flight (unless it already failed) and every step after it,
/// folder steps included, in plan order; detail: the loss's, or empty on a stop. `settled`: the files that finished
/// and the plan's Skips, never a folder (a folder is finished only when everything inside it is, D-17). `folders`:
/// every folder made or merged into, with its name at the destination, so a Retry continues inside it (D-08, D-10).
/// `touched`: phone folders that changed (uploads); `created`: the phone objects made in them, which a re-list must
/// read back even if a listing mid-copy cached them (WR-02).
/// `lost`: the session dropped its transport mid-job (D-10); the app reconnects.
/// `unfinished`: the item in progress when the run ended early (a stop or a lost session); nil when it ran to the end.
/// A silent reconnect tries it once more (D-16).
/// `leftovers`: upload temps the run couldn't finish or delete, for the fix-up (D-24).
public struct TransferOutcome: Sendable, Equatable {
    public var failed: [TransferFailure]
    public var unreached: [TransferFailure]
    public var settled: Set<ItemKey>
    public var folders: [ItemKey: String]
    public var touched: Set<FolderKey>
    public var created: Set<UInt32>
    public var cancelled: Bool
    public var lost: MTPError?
    public var unfinished: ItemKey?
    public var leftovers: [PhoneLeftover]

    public init(failed: [TransferFailure] = [], unreached: [TransferFailure] = [],
                settled: Set<ItemKey> = [], folders: [ItemKey: String] = [:], touched: Set<FolderKey> = [],
                created: Set<UInt32> = [], cancelled: Bool = false, lost: MTPError? = nil, unfinished: ItemKey? = nil,
                leftovers: [PhoneLeftover] = []) {
        self.failed = failed; self.unreached = unreached; self.settled = settled
        self.folders = folders; self.touched = touched; self.created = created
        self.cancelled = cancelled; self.lost = lost
        self.unfinished = unfinished
        self.leftovers = leftovers
    }
}

/// An upload's hidden temp that may still be on the phone after its run ended (a lost session, or a cleanup the phone
/// refused), recorded so the fix-up can finish or delete exactly that object later (D-24). `folder` is the handle of
/// the phone folder the temp was created in, in the session that made it; `folderPath` is that folder's names from the
/// storage root, which the fix-up finds it by (handles change on replug, Pitfall 12); `size` is the Mac file's
/// planned size. `handle`: the temp's own object in that session, nil when the phone never answered its creation.
public struct PhoneLeftover: Sendable, Equatable {
    public var storage: UInt32
    public var folder: UInt32
    public var temp: String
    public var name: String
    public var size: UInt64
    public var key: ItemKey
    public var folderPath: [String]
    public var handle: UInt32?

    public init(storage: UInt32, folder: UInt32, temp: String, name: String, size: UInt64, key: ItemKey,
                folderPath: [String] = [], handle: UInt32? = nil) {
        self.storage = storage; self.folder = folder; self.temp = temp; self.name = name; self.size = size; self.key = key
        self.folderPath = folderPath; self.handle = handle
    }
}

/// Which phone a job copies with (D-14): a Retry needs that same phone, whatever session it is on now.
/// `registryID`: the IOKit registry ID of its USB interface, the same until the phone is replugged.
public struct PhoneID: Sendable, Equatable {
    public var serial: String
    public var name: String
    public var registryID: UInt64

    public init(serial: String, name: String, registryID: UInt64 = 0) {
        self.serial = serial; self.name = name; self.registryID = registryID
    }

    /// The same phone across a silent reconnect (D-16): `isSame(as:)`, or with no serial on either side the same
    /// non-zero registry ID, which holds because no replug happened (RESEARCH Pitfall 13). Never used for a Retry.
    public func isSameDevice(as other: PhoneID?) -> Bool {
        guard let other else { return false }
        return isSame(as: other) || serial.isEmpty && other.serial.isEmpty && registryID != 0 && registryID == other.registryID
    }

    /// The same phone: both serials non-empty and equal. A phone that reports no serial never matches (P2 D-36,
    /// RESEARCH Pitfall 13).
    public func isSame(as other: PhoneID?) -> Bool {
        !serial.isEmpty && serial == other?.serial
    }
}

/// One item of a job, stable across plans: the index of its top-level item in the request, plus the SOURCE names
/// below that item (empty for the item itself). Two "IMG.jpg" picked in different folders differ by `top` (D-10, D-21).
public struct ItemKey: Hashable, Sendable {
    public var top: Int
    public var path: [String]

    public init(top: Int, path: [String] = []) {
        self.top = top; self.path = path
    }

    func appending(_ name: String) -> ItemKey { ItemKey(top: top, path: path + [name]) }
}

/// A name already at the destination (D-01): what is there and what is being copied onto it.
public struct Clash: Sendable, Equatable, Identifiable {
    public struct Side: Sendable, Equatable {
        public var name: String
        public var isFolder: Bool
        public var size: UInt64?
        public var modified: Date?

        public init(name: String, isFolder: Bool = false, size: UInt64? = nil, modified: Date? = nil) {
            self.name = name; self.isFolder = isFolder; self.size = size; self.modified = modified
        }
    }

    public var id: ItemKey
    public var existing: Side
    public var incoming: Side

    /// D-08: Replace only puts a file over a file; a type clash would delete a tree the user didn't copy.
    public var allowsReplace: Bool { !existing.isFolder && !incoming.isFolder }

    public init(id: ItemKey, existing: Side, incoming: Side) {
        self.id = id; self.existing = existing; self.incoming = incoming
    }
}

public enum ClashAnswer: Sendable, Equatable { case replace, skip, keepBoth }

/// A job's answers (D-01, D-03): each item's own, and the Apply to All answer for the rest.
public struct ClashAnswers: Sendable, Equatable {
    public var byItem: [ItemKey: ClashAnswer]
    public var all: ClashAnswer?

    public init(byItem: [ItemKey: ClashAnswer] = [:], all: ClashAnswer? = nil) {
        self.byItem = byItem; self.all = all
    }

    /// The item's own answer, else Apply to All; nil when neither applies. Apply to All + Replace never covers a type
    /// clash, which still gets its own sheet (CONTEXT discretion, D-08).
    public func answer(for clash: Clash) -> ClashAnswer? {
        if let own = byItem[clash.id] { return own }
        guard let all, all != .replace || clash.allowsReplace else { return nil }
        return all
    }
}

/// How a planner treats a clash nobody has answered: `.ask` reports it and plans nothing for it (the scan);
/// `.keepBoth` keeps both (attempt start: the destination changed since the scan, CONTEXT discretion).
public enum Unanswered: Sendable { case ask, keepBoth }

/// A job worked out before any byte moves: the steps to run, their total, and what already failed. `settled`: the
/// items answered Skip (D-19); `folders`: the folders it merges into, with their name at the destination.
public struct TransferPlan: Sendable, Equatable {
    enum Destination: Sendable, Equatable {
        case mac(URL)
        case phone(storage: UInt32, folder: UInt32)
    }

    /// Where an upload step goes: a phone folder that already exists, or the one the step at this index creates.
    enum PhoneParent: Sendable, Equatable {
        case existing(UInt32)
        case made(Int)
    }

    enum Step: Sendable, Equatable {
        /// Download `entry` to the file URL; `replace`: the user chose Replace, so it goes over what is there (D-20).
        case file(ObjectEntry, URL, key: ItemKey, replace: Bool)
        /// Create this Mac folder, dated with the phone's date once everything inside it is written.
        case folder(URL, Date?, key: ItemKey)
        /// Create a phone folder called `name` in `parent` for this Mac folder (its own name, or Keep Both's).
        case mkdir(URL, name: String, parent: PhoneParent, key: ItemKey)
        /// Upload this Mac file of `size` bytes into `parent` under a hidden temp, renamed to `name` once the phone has
        /// all of it (D-22); `replacing`: the phone file a Replace answer goes over, deleted just before that rename;
        /// `folderPath`: `parent`'s names from the storage root, recorded with a temp the run leaves (D-24).
        case send(URL, name: String, size: UInt64, parent: PhoneParent, key: ItemKey, replacing: UInt32?,
                  folderPath: [String])

        /// The destination name for an upload step and a folder step; a download file step's phone name.
        var name: String {
            switch self {
            case let .file(entry, _, _, _): entry.name
            case let .folder(url, _, _): url.lastPathComponent
            case let .mkdir(_, name, _, _), let .send(_, name, _, _, _, _, _): name
            }
        }

        var url: URL {
            switch self {
            case let .file(_, url, _, _), let .folder(url, _, _), let .mkdir(url, _, _, _), let .send(url, _, _, _, _, _, _):
                url
            }
        }

        var key: ItemKey {
            switch self {
            case let .file(_, _, key, _), let .folder(_, _, key), let .mkdir(_, _, _, key), let .send(_, _, _, _, key, _, _):
                key
            }
        }
    }

    public internal(set) var totalBytes: UInt64 = 0
    public internal(set) var fileCount = 0
    public internal(set) var failed: [TransferFailure] = []
    public internal(set) var settled: Set<ItemKey> = []
    public internal(set) var folders: [ItemKey: String] = [:]
    /// The clashes nobody has answered yet, in the order the job would copy the items (`Unanswered.ask`).
    public internal(set) var clashes: [Clash] = []
    var steps: [Step] = []
    var destination: Destination
}

/// A thrown copy error sorted the one way items and whole jobs both use (PATTERNS "Response vs session-lost").
public enum TransferEnd: Equatable {
    /// The user stopped it: no alert, the session untouched (D-06).
    case stopped
    /// This item failed; the session is still in step (an error response, a short read, a Mac file error).
    case failed(String)
    /// The session dropped its transport (CR-01); the app reconnects (D-10).
    case lost(MTPError)

    public init(_ error: any Error) {
        switch error {
        case is CancellationError: self = .stopped
        case let e as MTPError: self = e.isResponse ? .failed(e.codeLine ?? e.detail) : .lost(e)
        case let e as TransferItemError: self = .failed(e.detail)
        default: self = .failed(TransferText.macReason(error))
        }
    }
}

/// One item failed after a completed transaction, so the session is still usable.
struct TransferItemError: Error {
    var detail: String
}

/// An upload's temp may still be on the phone: the session was lost after the item's first phone call, or the phone
/// refused to delete the temp. `run` records it as a `PhoneLeftover` (D-24); `cause` is how the item ended; `handle`
/// is the temp's object, if the phone answered its creation.
struct TempKept: Error {
    var temp: String
    var handle: UInt32?
    var cause: any Error
}

/// The phone refused to delete the original a Replace goes over (e.g. write-protected): the original and the
/// complete temp are both still there.
struct OriginalKept: Error {
    var cause: MTPError
}

public enum Transfer {
    /// Bytes per GetPartialObject64: ~0.2 s at the measured 40 MB/s, so a stop lands quickly (RESEARCH Pattern 2).
    public static let chunkSize: UInt32 = 8 << 20

    /// Consecutive (offset, length) pieces covering `size`, each at most `chunk` long.
    static func chunks(size: UInt64, chunk: UInt32) -> [(offset: UInt64, length: UInt32)] {
        stride(from: 0, to: size, by: Int(chunk)).map { ($0, UInt32(min(UInt64(chunk), size - $0))) }
    }

    /// Whether a phone name can be one Mac path component: not empty, ".", "..", and no "/" or NUL (T-03-01).
    /// ":" is fine on APFS, so this is not `NameRules.validate`.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\u{0}")
    }

    /// The download steps for `items` into the Mac folder `folder`, folders walked recursively. Throws only
    /// `CancellationError` (a stop) or a non-response `MTPError` (the session dropped); a folder the phone refuses
    /// to list becomes a failed item. Top-level items are read back first: the browser's cached size may be stale
    /// (a file still growing when listed), and exactly that many bytes are copied (WR-02); a folder's cached date may
    /// predate the phone's zone being learned, and it becomes the Mac folder's date beside freshly read files (WR-01).
    /// A name already at the destination is resolved by `answers`, else by `unanswered` (D-01): nothing there is ever
    /// replaced without a Replace answer, and nothing of a clash is read from the phone until it is answered.
    /// The same call plans the first scan, a Retry and the D-16 continuation (RESEARCH Pattern 1): `settled` items are
    /// passed by (subtree and all), and a folder in `folders` is continued inside under that name.
    public static func planDownload(_ items: [ObjectEntry], into folder: URL, answers: ClashAnswers = ClashAnswers(),
                                    settled: Set<ItemKey> = [], folders: [ItemKey: String] = [:],
                                    unanswered: Unanswered = .ask, session: DeviceSession) async throws -> TransferPlan {
        var plan = TransferPlan(destination: .mac(folder))
        var fresh: [(entry: ObjectEntry, key: ItemKey)] = []
        for (top, item) in items.enumerated() {
            try Task.checkCancellation()
            let key = ItemKey(top: top)
            if settled.contains(key) {                  // nothing to read: `add` only claims its name
                fresh.append((item, key))
                continue
            }
            do {
                // Handle 0: `resolve` didn't find it again after a replug; no object has it, so nothing is asked.
                if item.id != 0, let entry = try await session.entry(item.id) {
                    fresh.append((entry, key))
                } else {
                    plan.failed.append(TransferFailure(name: item.name, detail: TransferText.itemGone, key: key,
                                                       retryable: false))
                }
            } catch let e as MTPError where e.isResponse {
                plan.failed.append(TransferFailure(name: item.name, detail: e.codeLine ?? e.detail, key: key))
            }
        }
        var visited: Set<UInt32> = []
        try await add(fresh, into: folder, limit: maxFileSize(in: folder), answers: answers, settled: settled,
                      folders: folders, unanswered: unanswered, visited: &visited, to: &plan, session: session)
        return plan
    }

    /// The biggest file the volume holding `folder` stores, from FILESIZEBITS, a signed size (FAT32 answers 33 bits:
    /// 4 GiB − 1); unknown → no limit. A file over it fails at plan time instead of at the 4 GiB mark (IN-01).
    static func maxFileSize(in folder: URL) -> UInt64 {
        let bits = pathconf(folder.path, _PC_FILESIZEBITS)
        return bits > 1 && bits < 64 ? (1 << UInt64(bits - 1)) - 1 : .max
    }

    /// `visited`: every folder walked so far. A phone listing a folder inside itself fails that folder instead of
    /// recursing until memory runs out (the device is untrusted, IN-03). No temp is swept here: another job may be
    /// writing into this folder while this one is scanned (D-05, RESEARCH Pitfall 6); `run` sweeps.
    /// Each destination folder is planned by exactly one call (a second item of that name is kept both, D-10), so
    /// `claimed` here covers every name this job gives in `folder`.
    /// Each item is checked in this order (RESEARCH Pattern 1): settled → passed by, its subtree unwalked (a Skip, or a
    /// first run's Stop cut it off), its incoming name still claimed so a later duplicate keeps its Keep Both name; in
    /// `folders` (an earlier attempt made or merged into it) → continued inside under that name, no clash, no D-10
    /// rename, or listed with `folderMoved` if it is no longer there (D-17: never re-made under a new name); else
    /// classified and resolved as on the first scan.
    private static func add(_ items: [(entry: ObjectEntry, key: ItemKey)], into folder: URL, limit: UInt64,
                            answers: ClashAnswers, settled: Set<ItemKey>, folders: [ItemKey: String],
                            unanswered: Unanswered, visited: inout Set<UInt32>,
                            to plan: inout TransferPlan, session: DeviceSession) async throws {
        var claimed: Set<String> = []       // D-10: earlier items' incoming and final names in `folder`, by phoneKey
        for (item, key) in items {
            if settled.contains(key) {
                claimed.insert(phoneKey(item.name))
                continue
            }
            guard isSafeName(item.name) else {             // its whole subtree is left unscanned
                plan.failed.append(TransferFailure(name: item.name, detail: "The name can’t be used on this Mac.", key: key,
                                                   retryable: false))
                continue
            }
            /// Keep Both's name (D-07): the first free against the folder and every name claimed in it.
            func keptBoth() -> URL {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return folder.appending(component: NameRules.keepBothName(item.name, isFolder: item.isFolder,
                                                                          among: names + claimed))
            }
            var dest = folder.appending(component: item.name)
            var replace = false
            var kind = Existing.create
            if item.isFolder, let made = folders[key] {
                claimed.insert(phoneKey(item.name))
                dest = folder.appending(component: made)
                guard existing(at: dest, isFolder: true) == .merge else {
                    plan.failed.append(TransferFailure(name: item.name, detail: TransferText.folderMoved, key: key,
                                                       retryable: false))
                    continue
                }
                kind = .merge
            } else if !claimed.insert(phoneKey(item.name)).inserted {
                // D-10: an earlier item of this job heads for this name here, so this one is kept both with no
                // question, even when the Mac has the name too: only the first of the group is asked, and earlier
                // items win, so selection order decides. Checked before classification for that reason.
                dest = keptBoth()
            } else {
                kind = existing(at: dest, isFolder: item.isFolder)  // D-06 merge, D-08 type clash, D-11 case-only clash
                if kind == .fileClash || kind == .typeClash {
                    let clash = Clash(id: key, existing: macSide(dest),
                                      incoming: Clash.Side(name: item.name, isFolder: item.isFolder,
                                                           size: item.isFolder ? nil : item.size, modified: item.modified))
                    switch answers.answer(for: clash) ?? (unanswered == .keepBoth ? .keepBoth : nil) {
                    case nil:                               // asked first; nothing below a clashing folder is read yet
                        plan.clashes.append(clash)
                        continue
                    case .skip?:                            // not reported (D-19), and a folder's subtree isn't walked
                        plan.settled.insert(key)
                        continue
                    case .replace? where clash.allowsReplace:
                        replace = true
                    case .replace?, .keepBoth?:             // a Replace never crosses a type clash: kept both (D-08)
                        dest = keptBoth()
                    }
                }
            }
            // A Mac name holds 255 UTF-16 units (probed on APFS: 255 CJK = 765 UTF-8 bytes is fine, 256 is not; HFS+,
            // exFAT and FAT32 count UTF-16 too). Phone names stop at 254, so only a Keep Both name gets here; it
            // fails rather than being cut short onto another name (T-04-12).
            guard dest.lastPathComponent.utf16.count <= 255 else {
                plan.failed.append(TransferFailure(name: item.name, detail: "The name is too long for this Mac.", key: key,
                                                   retryable: false))
                continue
            }
            claimed.insert(phoneKey(dest.lastPathComponent))
            guard item.isFolder else {
                guard item.size <= limit else {
                    plan.failed.append(TransferFailure(name: item.name, detail: "The file is too large for the volume’s format.",
                                                       key: key, retryable: false))
                    continue
                }
                plan.steps.append(.file(item, dest, key: key, replace: replace))
                plan.totalBytes += item.size
                plan.fileCount += 1
                continue
            }
            guard visited.insert(item.id).inserted else {
                plan.failed.append(TransferFailure(name: item.name, detail: "The phone listed this folder inside itself.",
                                                   key: key, retryable: false))
                continue
            }
            let children: [ObjectEntry]
            do {
                children = try await list(storage: item.storageID, parent: item.id, session: session)
            } catch let e as MTPError where e.isResponse {
                plan.failed.append(TransferFailure(name: item.name, detail: e.codeLine ?? e.detail, key: key))
                continue
            }
            // A merge (D-06) has no step and is recorded; a new or Keep Both folder is made, and nothing inside it can
            // clash.
            if kind == .merge {
                plan.folders[key] = dest.lastPathComponent
            } else {
                plan.steps.append(.folder(dest, item.modified, key: key))
            }
            try await add(children.map { ($0, key.appending($0.name)) }, into: dest, limit: limit, answers: answers,
                          settled: settled, folders: folders, unanswered: unanswered, visited: &visited, to: &plan,
                          session: session)
        }
    }

    /// The Mac item at `url` as the clash sheet shows it, read like `existing` without following a link. `name` is the
    /// stored name, which can differ in case from the incoming one on a case-insensitive volume.
    static func macSide(_ url: URL) -> Clash.Side {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isFolder = attributes?[.type] as? FileAttributeType == .typeDirectory
        return Clash.Side(name: (try? url.resourceValues(forKeys: [.nameKey]))?.name ?? url.lastPathComponent,
                          isFolder: isFolder,
                          size: isFolder ? nil : (attributes?[.size] as? NSNumber)?.uint64Value,
                          modified: attributes?[.modificationDate] as? Date)
    }

    /// Removes `.<UUID>.aft-download` temps left in `folder` by a download that never reached its cleanup (Stop &
    /// Quit's 10 s bound, a force quit, a crash, power loss). The app is single-instance and copies one job at a time,
    /// and `run` calls this as its job starts copying (never while a job is scanned, Pitfall 6), so any such file is a
    /// leftover; they can be as big as the file (WR-04). Only names `download` makes match.
    /// A fresh upload temp name: hidden for MediaStore, never its `.pending-`/`.trashed-` expiry form, 48 UTF-16 units
    /// (04-PROBE-REPORT "Temp name form": the MIX 4 took the plain form in DCIM on both upload paths).
    static func uploadTempName() -> String { ".\(UUID().uuidString).aft-upload" }

    /// Whether `name` is exactly the form `uploadTempName` makes. Used only to hide the app's own temps in the browser
    /// (D-23); never to delete or rename anything on the phone, where the app touches only the temp it is uploading
    /// or one it recorded (D-25).
    public static func isUploadTemp(_ name: String) -> Bool { isTemp(name, suffix: ".aft-upload") }

    /// "." + a UUID + `suffix`, nothing else: the one exact test both temp matchers share.
    private static func isTemp(_ name: String, suffix: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(suffix)
            && UUID(uuidString: String(name.dropFirst().dropLast(suffix.count))) != nil
    }

    static func sweepTemps(in folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where isTemp(name, suffix: ".aft-download") {
            unlink(folder.appending(component: name).path)
        }
    }

    /// A folder's children in `Listing.batchSize` batches (the browser's loop), with a stop check before every
    /// call, so a stop during planning always surfaces as `CancellationError`. The fix-up lists through it too, so a
    /// big folder never holds the session actor in one call (D-22, IN-06).
    public static func list(storage: UInt32, parent: UInt32, session: DeviceSession) async throws -> [ObjectEntry] {
        try Task.checkCancellation()
        let handles = try await session.handles(storage: storage, parent: parent)
        var out: [ObjectEntry] = []
        for i in stride(from: 0, to: handles.count, by: Listing.batchSize) {
            try Task.checkCancellation()
            out += try await session.entries(Array(handles[i..<min(i + Listing.batchSize, handles.count)]), parent: parent)
        }
        return out
    }

    /// The upload steps for the Mac items `urls` into the phone folder `parent` (0xFFFFFFFF = storage root), Mac
    /// folders walked recursively. Nothing is sent. Throws only `CancellationError` or a session-lost `MTPError`;
    /// a refused listing of the destination fails the whole job (there is nowhere to check names against).
    /// A name the phone already has is resolved by `answers`, else by `unanswered`, as on downloads (D-01): nothing on
    /// the phone is ever replaced without a Replace answer, and nothing of a clash is read from the Mac until it is
    /// answered. `settled` and `folders` continue a job as on downloads; a recorded folder is found again by name.
    /// `path`: `parent`'s names from the storage root, extended by each folder made or merged into, so every file step
    /// carries the path of its phone folder for a temp the run may leave (D-24).
    public static func planUpload(_ urls: [URL], storage: UInt32, parent: UInt32, path: [String] = [],
                                  answers: ClashAnswers = ClashAnswers(),
                                  settled: Set<ItemKey> = [], folders: [ItemKey: String] = [:],
                                  unanswered: Unanswered = .ask, session: DeviceSession) async throws -> TransferPlan {
        var plan = TransferPlan(destination: .phone(storage: storage, folder: parent))
        let children = try await list(storage: storage, parent: parent, session: session)
        try await add(urls.enumerated().map { ($1, ItemKey(top: $0)) }, to: .existing(parent), path: path, listed: children,
                      storage: storage, answers: answers, settled: settled, folders: folders, unanswered: unanswered,
                      plan: &plan, session: session)
        return plan
    }

    /// Upload steps for `urls` into `parent`, whose phone children are `listed`. Mac metadata is dropped silently
    /// (D-13); links and special files are listed, never followed (T-03-07); folders, packages included (D-14), are
    /// created before their contents, or merged into when the phone already has that folder (D-06). Names are compared
    /// by `phoneKey`, as the phone's case-insensitive storage does: a case variant is a clash, never a second object
    /// that would overwrite the first (D-11, Pitfall 3). Two items of this job with one `phoneKey` never both take it:
    /// the later one is kept both (D-10). Settled items and recorded folders are checked first, as on downloads; a
    /// recorded folder is the listed child with exactly its name, else the one `phoneKey` match, so a new session's
    /// handles don't matter. `path` is `parent`'s names from the storage root.
    private static func add(_ items: [(url: URL, key: ItemKey)], to parent: TransferPlan.PhoneParent, path: [String],
                            listed: [ObjectEntry], storage: UInt32, answers: ClashAnswers, settled: Set<ItemKey>,
                            folders: [ItemKey: String], unanswered: Unanswered, plan: inout TransferPlan,
                            session: DeviceSession) async throws {
        let taken = Dictionary(listed.map { (phoneKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var claimed: Set<String> = []       // D-10: earlier items' incoming and final names in `parent`, by phoneKey
        for (url, key) in items {
            let name = url.lastPathComponent
            if isMacMetadata(name) { continue }
            if settled.contains(key) {
                claimed.insert(phoneKey(name))
                continue
            }
            if let problem = phoneNameProblem(name) {           // its whole subtree is left unscanned
                plan.failed.append(TransferFailure(name: name, detail: problem, key: key, retryable: false))
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                                          .fileSizeKey, .contentModificationDateKey])
            } catch {
                plan.failed.append(TransferFailure(name: name, detail: TransferText.macReason(error), key: key))
                continue
            }
            let isFolder = values.isDirectory == true
            guard values.isSymbolicLink != true, isFolder || values.isRegularFile == true else {
                plan.failed.append(TransferFailure(name: name, detail: TransferText.linkNotCopied, key: key, retryable: false))
                continue
            }
            let size = isFolder ? 0 : UInt64(values.fileSize ?? 0)
            /// Keep Both's name (D-07): the first free against the phone folder and every name claimed in it.
            func keptBoth() -> String {
                NameRules.keepBothName(name, isFolder: isFolder, among: listed.map(\.name) + claimed)
            }
            var there = taken[phoneKey(name)]
            var dest = name
            var replacing: UInt32?
            var kind = Existing.create
            if isFolder, let made = folders[key] {
                claimed.insert(phoneKey(name))
                guard let folder = match(made, in: listed), folder.isFolder else {
                    plan.failed.append(TransferFailure(name: name, detail: TransferText.folderMoved, key: key, retryable: false))
                    continue
                }
                there = folder
                dest = folder.name
                kind = .merge
            } else if !claimed.insert(phoneKey(name)).inserted {
                dest = keptBoth()               // D-10, before classification as on downloads: only the first is asked
            } else {
                kind = existing(there, isFolder: isFolder)          // D-06 merge, D-08 type clash, D-11 case-only clash
                if let there, kind == .fileClash || kind == .typeClash {
                    let clash = Clash(id: key,
                                      existing: Clash.Side(name: there.name, isFolder: there.isFolder,
                                                           size: there.isFolder ? nil : there.size, modified: there.modified),
                                      incoming: Clash.Side(name: name, isFolder: isFolder, size: isFolder ? nil : size,
                                                           modified: values.contentModificationDate))
                    switch answers.answer(for: clash) ?? (unanswered == .keepBoth ? .keepBoth : nil) {
                    case nil:                               // asked first; nothing inside a clashing folder is read yet
                        plan.clashes.append(clash)
                        continue
                    case .skip?:                            // not reported (D-19), and a folder's subtree isn't walked
                        plan.settled.insert(key)
                        continue
                    case .replace? where clash.allowsReplace:
                        replacing = there.id                // sent under the incoming name, case included (D-11)
                    case .replace?, .keepBoth?:             // a Replace never crosses a type clash: kept both (D-08)
                        dest = keptBoth()
                    }
                }
            }
            // Only a Keep Both name can be too long here; it fails rather than being cut short onto another name.
            if let problem = phoneNameProblem(dest) {
                plan.failed.append(TransferFailure(name: name, detail: problem, key: key, retryable: false))
                continue
            }
            claimed.insert(phoneKey(dest))
            guard isFolder else {
                plan.steps.append(.send(url, name: dest, size: size, parent: parent, key: key, replacing: replacing,
                                        folderPath: path))
                plan.totalBytes += size
                plan.fileCount += 1
                continue
            }
            try Task.checkCancellation()
            let inside: [URL]
            do {   // hidden files included, so ".nomedia" uploads; sorted for a stable order
                inside = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                plan.failed.append(TransferFailure(name: name, detail: TransferText.macReason(error), key: key))
                continue
            }
            let keyed = inside.map { ($0, key.appending($0.lastPathComponent)) }
            if let there, kind == .merge {
                let children: [ObjectEntry]
                do {
                    children = try await list(storage: storage, parent: there.id, session: session)
                } catch let e as MTPError where e.isResponse {
                    plan.failed.append(TransferFailure(name: name, detail: e.codeLine ?? e.detail, key: key))
                    continue
                }
                plan.folders[key] = there.name
                try await add(keyed, to: .existing(there.id), path: path + [there.name], listed: children,
                              storage: storage, answers: answers, settled: settled, folders: folders,
                              unanswered: unanswered, plan: &plan, session: session)
            } else {
                // A new or Keep Both folder has no children, so nothing inside it can clash.
                plan.steps.append(.mkdir(url, name: dest, parent: parent, key: key))
                try await add(keyed, to: .made(plan.steps.count - 1), path: path + [dest], listed: [], storage: storage,
                              answers: answers, settled: settled, folders: folders, unanswered: unanswered,
                              plan: &plan, session: session)
            }
        }
    }

    /// Mac metadata that never uploads (D-13), at any depth: AppleDouble "._*" files and Finder, Spotlight and
    /// Time Machine items. Every other dotfile (".nomedia") uploads.
    static func isMacMetadata(_ name: String) -> Bool {
        name.hasPrefix("._") || [".DS_Store", ".localized", "Icon\r", ".Spotlight-V100", ".Trashes", ".fseventsd",
                                 ".TemporaryItems", ".DocumentRevisions-V100"].contains(name)
    }

    /// The phone-name comparison of D-12 (`NameRules.uniqueName`'s): NFC, then lowercased, since shared storage is
    /// case-insensitive and AOSP would truncate a case variant (Pitfall 5). Downloads compare names claimed within
    /// one job the same way (D-10), as `keepBothName` does.
    static func phoneKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// The entry called `name` among `entries`, as an item is found again on a new session: the exact name, else the
    /// one `phoneKey` match; nil when there is none or more than one (T-04-33).
    static func match(_ name: String, in entries: [ObjectEntry]) -> ObjectEntry? {
        if let exact = entries.first(where: { $0.name == name }) { return exact }
        let same = entries.filter { phoneKey($0.name) == phoneKey(name) }
        return same.count == 1 ? same[0] : nil
    }

    /// Why a Mac name can't be sent as one: empty, or past the 254 UTF-16 units SendObjectInfo carries (Pitfall 3).
    static func phoneNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "The name can’t be used on the phone." }
        if name.utf16.count > 254 { return "The name is too long for the phone." }
        return nil
    }

    enum Existing { case create, merge, fileClash, typeClash }

    /// What is at a destination name, in one place (D-01: only classified here; the user's answer decides): nothing →
    /// create; a real folder where a folder goes → merge into it with no question (D-06); a file onto a file, symlink
    /// or any other non-folder → file clash; anything else (a file onto a folder, a folder onto a file or a symlink)
    /// → type clash (D-08). `attributesOfItem` is lstat: a link is never followed, so nothing is merged or written
    /// through it (T-03-02, T-04-02).
    static func existing(at url: URL, isFolder: Bool) -> Existing {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        else { return .create }
        if type == .typeDirectory { return isFolder ? .merge : .typeClash }
        return isFolder ? .typeClash : .fileClash
    }

    /// The same classification against the phone's listing (name matched by `phoneKey`), for uploads.
    private static func existing(_ entry: ObjectEntry?, isFolder: Bool) -> Existing {
        guard let entry else { return .create }
        if entry.isFolder { return isFolder ? .merge : .typeClash }
        return isFolder ? .typeClash : .fileClash
    }

    /// Runs `plan`. Never throws: every stop, failure and session loss is reported in the outcome. A stop or a lost
    /// session ends the run; files that finished stay (D-07). `onFile` gets each file's name as it starts, so a run
    /// cut off before it returns can still name its item in progress (IN-06). `landed` gets each uploaded file's handle
    /// once its rename is done, and the handle of the original it replaced (D-23): the phone sends no event for the
    /// app's own rename, so the browser re-reads that one object (RESEARCH Pitfall 10). The outcome records each file
    /// that finished in `settled`, each folder made in `folders`, and, after an early end, `unreached`. `temps`: a folder
    /// of the app's own for download temps (a drag out's, G-05-1-2), used for each file on its volume.
    public static func run(_ plan: TransferPlan, session: DeviceSession, chunk: UInt32 = chunkSize, temps: URL? = nil,
                           onFile: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                           landed: @escaping @MainActor @Sendable (UInt32, UInt32?) -> Void = { _, _ in },
                           progress: @escaping @MainActor @Sendable (UInt64) -> Void) async -> TransferOutcome {
        precondition(chunk > 0, "chunk must be positive")                // `chunks` strides by it (IN-02)
        var outcome = TransferOutcome(failed: plan.failed, settled: plan.settled, folders: plan.folders)
        let phoneStorage: UInt32 = if case let .phone(storage, _) = plan.destination { storage } else { 0 }
        var created: [(url: URL, date: Date?)] = []
        var dead: Set<String> = []          // folders that couldn't be made: that failure covers their contents
        var made: [Int: UInt32] = [:]       // phone folders made, by step index
        var cut: Int?                       // an early end: this step and every later one are unreached
        /// The phone folder an upload step goes into; nil inside a folder that wasn't made (its failure covers it).
        func phoneFolder(_ parent: TransferPlan.PhoneParent) -> UInt32? {
            switch parent {
            case let .existing(handle): handle
            case let .made(index): made[index]
            }
        }
        defer {
            // Folders get their phone date last, children before parents (steps are in pre-order), so no later
            // write inside bumps it (D-15, Pitfall 9). Merged folders are never touched.
            for (url, date) in created.reversed() {
                guard let date else { continue }
                try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        if case let .mac(root) = plan.destination {
            // This job is the only copier now, so any temp in a folder it writes into is a leftover (Pitfall 6).
            var folders: Set<URL> = [root]
            for case let .file(_, dest, _, _) in plan.steps { folders.insert(dest.deletingLastPathComponent()) }
            folders.forEach(sweepTemps(in:))
        }
        steps: for (index, step) in plan.steps.enumerated() {
            if dead.contains(step.url.deletingLastPathComponent().path) {
                if case .folder = step { dead.insert(step.url.path) }
                continue
            }
            // Inside a phone folder that wasn't made, the folder's failure covers the step. Passed by before the stop
            // check, as `dead` is, so a cut never lands inside a failed folder and settles its contents (CR-01).
            switch step {
            case let .mkdir(_, _, parent, _), let .send(_, _, _, parent, _, _, _):
                if phoneFolder(parent) == nil { continue steps }
            default: break
            }
            do {
                try Task.checkCancellation()        // between items; big files also check between chunks
                switch step {
                case let .file(entry, dest, key, replace):
                    await onFile(entry.name)
                    try await download(entry, to: dest, replace: replace, temps: temps, session: session, chunk: chunk,
                                       progress: progress)
                    outcome.settled.insert(key)
                case let .folder(url, date, key):
                    if try makeFolder(url) { created.append((url, date)) }
                    outcome.folders[key] = url.lastPathComponent
                case let .mkdir(_, name, parent, key):
                    guard let folder = phoneFolder(parent) else { continue steps }
                    let handle = try await session.makeFolder(storage: phoneStorage, parent: folder, name: name)
                    made[index] = handle
                    outcome.folders[key] = name
                    outcome.touched.insert(FolderKey(storage: phoneStorage, folder: folder))
                    outcome.created.insert(handle)
                case let .send(url, name, size, parent, key, replacing, folderPath):
                    guard let folder = phoneFolder(parent) else { continue steps }
                    await onFile(name)
                    let handle: UInt32
                    do {
                        handle = try await upload(url, as: name, size: size, replacing: replacing,
                                                  into: FolderKey(storage: phoneStorage, folder: folder),
                                                  session: session, chunk: chunk, touched: &outcome.touched,
                                                  created: &outcome.created, progress: progress)
                    } catch let kept as TempKept {
                        outcome.leftovers.append(PhoneLeftover(storage: phoneStorage, folder: folder, temp: kept.temp,
                                                               name: name, size: size, key: key, folderPath: folderPath,
                                                               handle: kept.handle))
                        throw kept.cause
                    }
                    outcome.settled.insert(key)
                    await landed(handle, replacing)
                }
            } catch {
                switch TransferEnd(error) {
                case .stopped:
                    outcome.cancelled = true
                    outcome.unfinished = step.key
                    cut = index
                    break steps
                case let .failed(detail):
                    transferLog.error("\(step.name, privacy: .private) failed: \(detail, privacy: .private)")
                    outcome.failed.append(TransferFailure(name: step.name, detail: detail, key: step.key))
                    if case .folder = step { dead.insert(step.url.path) }
                case let .lost(e):
                    // A stop the phone didn't settle shows no error (D-10); an upload's temp is recorded above.
                    let stopped = Task.isCancelled
                    if !stopped { outcome.failed.append(TransferFailure(name: step.name, detail: e.detail, key: step.key)) }
                    outcome.cancelled = stopped
                    outcome.lost = e
                    outcome.unfinished = step.key
                    cut = stopped ? index : index + 1
                    break steps
                }
            }
        }
        if let cut {
            // Steps are in pre-order and a failed folder's subtree never runs, so nothing after the cut is covered by an
            // earlier failure: every one is listed. Whether they count as listed or settled is the queue's rule (D-15).
            let detail = outcome.cancelled ? "" : outcome.lost?.detail ?? ""
            outcome.unreached = plan.steps[cut...].map { TransferFailure(name: $0.name, detail: detail, key: $0.key) }
        }
        transferLog.info("""
            run ended: \(outcome.failed.count, privacy: .public) failed, \(outcome.unreached.count, privacy: .public) \
            unreached, cancelled \(outcome.cancelled, privacy: .public), lost \(outcome.lost?.detail ?? "no", privacy: .public)
            """)
        return outcome
    }

    /// Makes a folder step's folder. False when a real folder took the name since planning: merged, not dated.
    private static func makeFolder(_ url: URL) throws -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return true
        } catch let e as CocoaError where e.code == .fileWriteFileExists && existing(at: url, isFolder: true) == .merge {
            return false
        }
    }

    /// One file, chunk by chunk, into a hidden fixed-length temp in the destination folder (same volume, never over
    /// NAME_MAX, Pitfall 8), dated, then put in place: `replace` → one rename(2) over what is there (D-20); otherwise
    /// renamed without replacing anything, under the next Keep Both name if something took the name since planning,
    /// so nothing is overwritten without an answer (CONTEXT discretion). The temp is gone on every other exit.
    /// With `temps` on the destination's volume the temp goes there instead: a promise receiver such as Mail grants
    /// only the promised path, so no sibling can be made beside it (G-05-1-2).
    private static func download(_ entry: ObjectEntry, to dest: URL, replace: Bool, temps: URL? = nil,
                                 session: DeviceSession, chunk: UInt32,
                                 progress: @MainActor @Sendable (UInt64) -> Void) async throws {
        let beside = dest.deletingLastPathComponent()
        let folder = temps.map { sameVolume($0, beside) ? $0 : beside } ?? beside
        let temp = folder.appending(component: ".\(UUID().uuidString).aft-download")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        for (offset, length) in chunks(size: entry.size, chunk: chunk) {
            try Task.checkCancellation()                                    // the only cancel point (Pattern 2)
            let bytes = try await session.readPartial(entry.id, offset: offset, length: length)
            // The transaction completed, so the session is in step and only this item fails (T-03-05).
            guard bytes.count == Int(length) else { throw TransferItemError(detail: "The phone sent less data than expected.") }
            try handle.write(contentsOf: bytes)
            await progress(UInt64(length))
        }
        // The bytes reach the disk before the rename can commit the name to them, or a crash could leave the name on a
        // hole-filled file with a Replace's original already gone (WR-01). A barrier orders them, which is all D-20
        // needs, without F_FULLFSYNC's cache flush per file; a volume without barriers gets a plain fsync.
        guard fcntl(fd, F_BARRIERFSYNC) == 0 || fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.close()
        if let date = entry.modified {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temp.path)
        }
        if replace {
            try Transfer.replace(temp, at: dest)
        } else {
            try moveKeepingBoth(temp, to: dest, name: entry.name)
        }
        renamed = true
    }

    /// False when the temps folder `a` is missing (the temp goes beside the destination, as before) or both can be read
    /// and are on different volumes, where a rename can't bring a temp over. A receiver's protected folder `b` can't be
    /// read; it is in its app's container, on the user's volume.
    /// ponytail: a home folder on another volume than $TMPDIR would make that rename fail (EXDEV, the item fails with
    /// nothing left); copy the temp over if that setup ever matters.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0 else { return false }
        return stat(b.path, &sb) != 0 || sa.st_dev == sb.st_dev
    }

    /// D-20: the complete, dated temp takes the original's place in one rename(2), so the name always resolves to the
    /// complete old file or the complete new one, and the old file is deleted, not moved to the Trash (D-09). A folder
    /// that took the name since planning answers EISDIR: the item fails and nothing is lost. A symlink there is replaced
    /// itself, never written through. APFS keeps the old name's case on a rename-over, so a case-only clash (D-11) gets
    /// a best-effort second rename to the incoming name.
    /// Never the swap flag of renamex_np (exFAT and HFS+ refuse it, and FAT32 reports success while destroying the old
    /// file), and never FileManager's replace-item API (it merges the old file's metadata over the phone's date):
    /// 04-RESEARCH Q3.
    static func replace(_ temp: URL, at dest: URL) throws {
        guard rename(temp.path, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A fresh URL: a URL caches resource values, and `dest` may have been read before the rename.
        let stored = (try? URL(filePath: dest.path).resourceValues(forKeys: [.nameKey]))?.name ?? dest.lastPathComponent
        if stored != dest.lastPathComponent {
            _ = rename(dest.deletingLastPathComponent().appending(component: stored).path, dest.path)
        }
    }

    /// Create and Keep Both: `temp` takes `dest` without replacing anything. If something took the name since
    /// planning, it goes under the next Keep Both name of `name` instead (CONTEXT discretion), at most 1,000 names,
    /// then the item fails with the rename's EEXIST (T-04-13). Each tried name is counted taken, so a folder listing
    /// that fails still moves on.
    static func moveKeepingBoth(_ temp: URL, to dest: URL, name: String,
                                renameExcl: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) })
        throws {
        let folder = dest.deletingLastPathComponent()
        var target = dest, tried: [String] = []
        for _ in 0..<1_000 {
            if try moveExclusive(temp, to: target, renameExcl: renameExcl) { return }
            tried.append(target.lastPathComponent)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            target = folder.appending(component: NameRules.keepBothName(name, isFolder: false, among: names + tried))
        }
        throw POSIXError(.EEXIST)
    }

    /// Renames `temp` to `dest` only if nothing has that name; false when something does. A volume without
    /// RENAME_EXCL (exFAT answers ENOTSUP, others EINVAL) gets the name reserved by an O_EXCL placeholder, which a
    /// plain rename then replaces, so even there nothing but our own placeholder is ever replaced (CR-01).
    /// `renameExcl` is injectable so tests can play such a volume.
    static func moveExclusive(_ temp: URL, to dest: URL,
                              renameExcl: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) })
        throws -> Bool {
        if renameExcl(temp.path, dest.path) == 0 { return true }
        var err = errno
        if err == ENOTSUP || err == EINVAL {
            let placeholder = open(dest.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if placeholder < 0 {
                err = errno
            } else {
                close(placeholder)
                if rename(temp.path, dest.path) == 0 { return true }
                err = errno
                unlink(dest.path)
            }
        }
        if err == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }

    /// Free space at `plan`'s destination, read fresh before the job copies anything (D-04).
    /// Mac: the larger of the volume's capacity for important usage (purgeable space counted, as Finder does on
    /// APFS) and its plain available capacity (the only real figure on exFAT, FAT and HFS+, where important usage
    /// reads 0); unknown never refuses. Phone: a fresh GetStorageInfo of the destination storage; a storage that
    /// is gone has 0.
    public static func availableSpace(for plan: TransferPlan, session: DeviceSession) async throws -> UInt64 {
        switch plan.destination {
        case let .mac(folder):
            let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey])
            return macFreeSpace(important: values.volumeAvailableCapacityForImportantUsage,
                                plain: values.volumeAvailableCapacity)
        case let .phone(storage, _):
            return try await session.storages().first { $0.id == storage }?.freeSpace ?? 0
        }
    }

    /// The larger known figure; neither known never refuses.
    static func macFreeSpace(important: Int64?, plain: Int?) -> UInt64 {
        [important.map { UInt64(clamping: $0) }, plain.map { UInt64(clamping: $0) }].compactMap { $0 }.max() ?? .max
    }

    /// Open and Quick Look's fetch (PREV-02): the phone file `handle` into `folder` under its phone name, through the
    /// copy engine's own chunked, dated, temp-then-rename `download` (no second download loop), so the returned URL
    /// exists only once the file is complete. The entry is read again first (a fresh size; gone → `itemGone`), and
    /// its untrusted name is checked before any Mac path is built (RESEARCH V5). The default 8 MiB chunk keeps a
    /// preview to few transactions when it interleaves with a running job's chunks on the session actor (D-17).
    public static func fetch(_ handle: UInt32, into folder: URL, session: DeviceSession, chunk: UInt32 = chunkSize,
                             progress: @MainActor @Sendable (UInt64) -> Void) async throws -> URL {
        guard let entry = try await session.entry(handle) else { throw TransferItemError(detail: TransferText.itemGone) }
        guard !entry.isFolder else { throw TransferItemError(detail: "A folder can’t be opened this way.") }
        guard isSafeName(entry.name) else { throw TransferItemError(detail: "The name can’t be used on this Mac.") }
        let url = folder.appending(component: entry.name)
        try await download(entry, to: url, replace: false, session: session, chunk: chunk, progress: progress)
        return url
    }

    /// Free space on `folder`'s volume, the same two-key read as `availableSpace` for a Mac destination, except that a
    /// failed read is unknown, which never refuses (a copy job's check keeps throwing, so its error paths are unchanged).
    public static func macFreeSpace(at folder: URL) -> UInt64 {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        return macFreeSpace(important: values?.volumeAvailableCapacityForImportantUsage,
                            plain: values?.volumeAvailableCapacity)
    }
}

/// Open and Quick Look wording (D-16, D-19).
public enum PreviewText {
    /// D-16's "about 1 GB", decimal like the sizes the list shows: bigger files ask before they're fetched.
    public static let bigFile: UInt64 = 1_000_000_000
    /// The Quick Look panel's title while a file comes from the phone.
    public static func fetching(_ name: String, percent: Int) -> String { "Getting “\(name)” from the phone… \(percent)%" }
    /// The status line while Open fetches a file.
    public static func opening(_ name: String, percent: Int) -> String { "Opening “\(name)”… \(percent)%" }

    /// The time a fetch of `bytes` takes at the measured ~40 MB/s (RESEARCH A9), in `TransferText.remaining`'s buckets.
    public static func duration(bytes: UInt64) -> String {
        let s = Double(bytes) / 40_000_000
        switch s {
        case ..<60: return "less than a minute"
        case ..<90: return "about 1 minute"
        case ..<3570: return "about \(Int((s / 60).rounded())) minutes"
        default:
            let hours = max(1, Int((s / 3600).rounded()))
            return hours == 1 ? "about 1 hour" : "about \(hours.formatted()) hours"
        }
    }

    /// D-16's question before fetching big files.
    public static func question(names: [String], size: UInt64) -> String {
        let what = names.count == 1 ? "“\(names[0])” is" : "The \(names.count.formatted()) items are"
        let verb = names.count == 1 ? "takes" : "take"
        return "\(what) \(EntryFormat.bytes(size)) and \(verb) \(duration(bytes: size)) to get from the phone."
    }

    public static let pressReturn = "Press Return to preview."

    /// The alert when a file couldn't be fetched or opened.
    public static func failed(_ name: String, detail: String) -> AlertText {
        AlertText(message: "“\(name)” couldn’t be opened.", detail: detail)
    }

    /// O-10/O-11: Open with no default app for the file.
    public static func noApp(_ name: String) -> AlertText {
        AlertText(message: "There is no application set to open the document “\(name)”.",
                  detail: "Use the Download button to copy it to this Mac, then open it from Finder with Open With.")
    }

    /// O-12: Open refused because the Mac lacks space for the fetch.
    public static func noSpace(_ name: String, needed: UInt64, available: UInt64) -> AlertText {
        AlertText(message: "“\(name)” can’t be opened because there isn’t enough free space on this Mac.",
                  detail: TransferText.spaceLine(needed: needed, available: available))
    }

    /// O-13: the Quick Look panel's title when the Mac lacks space for the fetch.
    public static func previewNoSpace(_ name: String, needed: UInt64, available: UInt64) -> String {
        "“\(name)” can’t be previewed because there isn’t enough free space on this Mac. "
            + TransferText.spaceLine(needed: needed, available: available)
    }

    /// O-15: the Quick Look panel's title when the fetch failed.
    public static func previewFailed(_ name: String, detail: String) -> String { "“\(name)” couldn’t be previewed. \(detail)" }
}

extension Transfer {
    /// One Mac file into the phone folder `key` under a hidden temp name, renamed to its real name only once the phone
    /// has all of it (D-22); returns its handle, which the rename keeps. Up to one chunk (0 bytes included): read
    /// whole, then `createFile`. Bigger: the edit path, one `writePartial` per chunk with a stop check before each
    /// (03-SPIKE-REPORT ## Decision). The Mac file is opened before anything is sent, so an unreadable file creates
    /// nothing. With the session still in step, a temp that can't be finished (a stop, a refusal, the Mac file
    /// changing, the name taken since planning, the phone refusing to delete the original a Replace goes over) is deleted (D-09,
    /// T-03-13); `TempKept` is thrown instead whenever the temp may stay on the phone, so `run` records it (D-24),
    /// including a rename still refused after that original was deleted, when the temp is the only copy (D-27).
    fileprivate static func upload(_ url: URL, as name: String, size: UInt64, replacing: UInt32?,
                                   into key: FolderKey, session: DeviceSession,
                                   chunk: UInt32, touched: inout Set<FolderKey>, created: inout Set<UInt32>,
                                   progress: @MainActor @Sendable (UInt64) -> Void) async throws -> UInt32 {
        let temp = uploadTempName()
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch CocoaError.fileWriteNoPermission {      // Foundation's code for an unreadable file (513): O-06e, not O-06a
            throw CocoaError(.fileReadNoPermission)
        } catch CocoaError.fileNoSuchFile {             // gone since planning: O-06d
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { try? file.close() }
        func read(_ count: Int) throws -> [UInt8] {
            let bytes = count == 0 ? [] : [UInt8](try file.read(upToCount: count) ?? Data())
            guard bytes.count == count else { throw TransferItemError(detail: "The file changed while it was being copied.") }
            return bytes
        }
        /// After the planned size: a file that grew meanwhile would be committed cut short (IN-04).
        func checkEnd() throws {
            guard try file.read(upToCount: 1)?.isEmpty ?? true else {
                throw TransferItemError(detail: "The file changed while it was being copied.")
            }
        }
        /// Deletes this item's own temp, then rethrows `error`. If the phone refuses or the session drops, the temp is
        /// kept and recorded instead (D-24).
        func discard(_ handle: UInt32, after error: any Error) async throws -> Never {
            do {
                try await session.delete(handle)
            } catch let cleanup {
                transferLog.error("cleanup of \(name, privacy: .private) failed: \(String(describing: cleanup), privacy: .public)")
                if case .lost = TransferEnd(cleanup) { throw TempKept(temp: temp, handle: handle, cause: cleanup) }
                throw TempKept(temp: temp, handle: handle, cause: error)
            }
            throw error
        }
        let handle: UInt32
        var made: UInt32?                   // the temp's object, once the phone answered its creation
        // A session already dropped sends nothing, so a loss on it leaves no temp to record (IN-07).
        let live = await session.isLive
        do {
            if size <= UInt64(chunk) {
                let contents = try read(Int(size))
                try checkEnd()
                handle = try await session.createFile(storage: key.storage, parent: key.folder, name: temp, contents: contents)
                made = handle
                touched.insert(key)
                created.insert(handle)
                await progress(size)
            } else {
                // ponytail: a FAT32 SD card refuses a write past 4 GiB mid-file (phone disk error → endpoint stall →
                // 03-05's recovery → failed item), since size 0 skips the phone's early Object Too Large check (RESEARCH
                // Pitfall 10). Accepted: the MIX 4 has no SD slot; send the real size up front if an SD-card phone needs it.
                handle = try await session.createForEdit(storage: key.storage, parent: key.folder, name: temp)
                made = handle
                touched.insert(key)
                created.insert(handle)
                do {
                    for (offset, length) in chunks(size: size, chunk: chunk) {
                        try Task.checkCancellation()                     // stops land between chunks only (spike Issue 2)
                        try await session.writePartial(handle, offset: offset, bytes: try read(Int(length)))
                        await progress(UInt64(length))
                    }
                    try checkEnd()
                    try await session.endEdit(handle)
                } catch {
                    if case .lost = TransferEnd(error) { throw error }   // no cleanup is possible
                    try? await session.endEdit(handle)
                    try await discard(handle, after: error)
                }
            }
            do {
                try await finalize(handle, as: name, replacing: replacing, session: session)
            } catch let refused as OriginalKept {                   // the original stays, the new copy goes
                let line = refused.cause.codeLine ?? refused.cause.detail
                try await discard(handle, after: TransferItemError(detail: TransferText.replaceRefused + "\n" + line))
            } catch let e as MTPError where e.isResponse {
                let line = e.codeLine ?? e.detail
                // After the delete the temp is the only copy on the phone: kept and recorded for the fix-up (D-27).
                if replacing != nil {
                    throw TempKept(temp: temp, handle: handle,
                                   cause: TransferItemError(detail: TransferText.finishOnRetry + "\n" + line))
                }
                try await discard(handle, after: e)                // something took the name since planning
            }
        } catch {
            if live, case .lost = TransferEnd(error) { throw TempKept(temp: temp, handle: made, cause: error) }
            throw error
        }
        return handle
    }

    /// Renames a complete temp to its real name. Runs to the end even if the job is stopped meanwhile: an unstructured
    /// Task doesn't inherit cancellation (RESEARCH Pitfall 8). 120 s: the phone answers only after its MediaStore scans
    /// of both names (Pitfall 2), and a timeout would poison the session.
    /// A Replace first deletes `original` (an original already gone counts as deleted, 02-06), so the complete new copy
    /// is on the phone before anything is removed and only one hidden object can ever be left (RESEARCH Q2: every cut
    /// leaves a complete copy). A case-only Replace then renames onto the incoming name, safe since the original is
    /// gone (D-11). Throws `OriginalKept` when the phone refuses that delete. The rename is retried only after a delete
    /// and only on General Error, 50 ms × 2ⁿ for 6 retries (04-PROBE-REPORT "Rename backoff"): AOSP keeps a deleted
    /// name in its cache until the inotify event lands (FROZEN_ONESHOT_DEL, Pitfall 1). The unstructured Task also
    /// keeps a stop from landing between the delete and the rename, which would leave the only phone copy hidden.
    static func finalize(_ handle: UInt32, as name: String, replacing original: UInt32?, session: DeviceSession) async throws {
        try await Task {
            if let original {
                do {
                    try await session.delete(original)
                } catch let e as MTPError where e.isInvalidObjectHandle {
                    // already gone on the phone
                } catch let e as MTPError where e.isResponse {
                    throw OriginalKept(cause: e)
                }
            }
            for retry in 0... {
                do {
                    return try await session.rename(handle, to: name, timeout: 120)
                } catch MTPError.response(code: MTPCode.generalError, op: _) where original != nil && retry < 6 {
                    try? await Task.sleep(for: .milliseconds(50 << retry))
                }
            }
        }.value
    }

    /// The single fix-up rule for a temp a cut left (D-24, RESEARCH Q2), decided from the phone's listing of its folder
    /// alone: the temp isn't listed → nothing to do; another item has the real name (by `phoneKey`: the original, or
    /// anything else) → the temp is deleted; the temp is complete → it is renamed to the real name and the item is done
    /// (its handle is returned, so the browser can show it: no event comes for the app's own rename, Pitfall 10, WR-03);
    /// otherwise the partial temp is deleted. It never deletes the only copy: a complete temp whose name is free
    /// is a Replace's new copy whose original was deleted, or a create cut before its rename. It never touches an
    /// object but the recorded temp (D-25). A temp gone while its own handle now has the real name and the full size is
    /// a rename that landed with its answer lost (C5), which a silent reconnect sees as handles survive with no replug
    /// (D-16): that item is done (WR-02). Otherwise a temp already gone can't be told apart from a rename that
    /// finished, so that item stays retryable (Pitfall 17).
    public static func fixUp(_ left: PhoneLeftover, children: [ObjectEntry], session: DeviceSession) async throws
        -> UInt32? {
        guard let temp = children.first(where: { $0.name == left.temp }) else {
            return children.first { $0.id == left.handle && $0.name == left.name && $0.size == left.size }?.id
        }
        let taken = children.contains { $0.id != temp.id && phoneKey($0.name) == phoneKey(left.name) }
        if !taken, !temp.isFolder, temp.size == left.size {
            try await session.rename(temp.id, to: left.name, timeout: 120)
            return temp.id
        }
        try await session.delete(temp.id)
        return nil
    }

    /// The objects along `names` from the storage root, found by name because handles change on replug (RESEARCH
    /// Pattern 5, Pitfall 12): each level is listed in `Listing.batchSize` batches up to the batch holding the exact
    /// name, and matched by `match`. Every level but the last must be a folder. Nil when a level isn't there; [] for
    /// [] (the root). Used by Retry after a replug, the fix-up and the browser's reopen (D-14, D-24, D-36).
    public static func find(_ names: [String], storage: UInt32, session: DeviceSession) async throws -> [ObjectEntry]? {
        var path: [ObjectEntry] = []
        for (depth, name) in names.enumerated() {
            try Task.checkCancellation()
            let parent = path.last?.id ?? 0xFFFF_FFFF
            let handles = try await session.handles(storage: storage, parent: parent)
            var seen: [ObjectEntry] = []
            for i in stride(from: 0, to: handles.count, by: Listing.batchSize) where !seen.contains(where: { $0.name == name }) {
                try Task.checkCancellation()
                seen += try await session.entries(Array(handles[i..<min(i + Listing.batchSize, handles.count)]), parent: parent)
            }
            guard let entry = match(name, in: seen), entry.isFolder || depth == names.count - 1 else { return nil }
            path.append(entry)
        }
        return path
    }

    /// `request` as it is on the phone now, for a job planned on an earlier session (a Retry after a replug: a new
    /// MtpDatabase, new handles, RESEARCH Pitfall 12; D-14). Each download item is found again by its path in its own
    /// slot, so every `ItemKey.top` stays; one no longer there keeps its slot as handle 0, which no object has, and
    /// `planDownload` lists it as gone. Each parent folder is found and listed once, so a Retry of photos picked in one
    /// big folder lists it once. An upload's destination folder is found by its path, else `missingDestination`.
    /// Storage IDs are taken as kept across sessions (RESEARCH A7).
    public static func resolve(_ request: TransferJob.Request, session: DeviceSession) async throws
        -> (request: TransferJob.Request, missingDestination: Bool) {
        switch request {
        case let .download(entries, paths, folder):
            var listed: [[String]: [ObjectEntry]] = [:]
            var found = entries
            for i in entries.indices {
                let path = paths.indices.contains(i) ? paths[i] : []
                let parent = Array(path.dropLast())
                if listed[parent] == nil {
                    let storage = entries[i].storageID
                    if let up = try await find(parent, storage: storage, session: session), up.last?.isFolder ?? true {
                        listed[parent] = try await list(storage: storage, parent: up.last?.id ?? 0xFFFF_FFFF, session: session)
                    } else {
                        listed[parent] = []
                    }
                }
                if let name = path.last, let entry = match(name, in: listed[parent] ?? []) {
                    found[i] = entry
                } else {
                    found[i].id = 0
                }
            }
            return (.download(found, paths: paths, to: folder), false)
        case let .upload(urls, storage, _, path):
            guard let folder = try await find(path, storage: storage, session: session), folder.last?.isFolder ?? true else {
                return (request, true)
            }
            return (.upload(urls, storage: storage, parent: folder.last?.id ?? 0xFFFF_FFFF, path: path), false)
        }
    }
}

/// One copy job in the queue: what it copies, where, and how far it got (D-01).
public struct TransferJob: Identifiable, Sendable {
    public enum Direction: Sendable { case download, upload }
    /// scanning → asking (questions open) or waiting (answered) → preparing → copying → [canceling] (D-01, D-05);
    /// every end goes through `TransferJobs.close`: removed, or `failed` (the row listing what wasn't copied, D-12),
    /// which Retry puts back to scanning (D-17). `reconnecting`: paused for a silent reconnect (D-16) until the same
    /// phone is back.
    public enum State: Sendable { case scanning, asking, waiting, preparing, copying, canceling, failed, reconnecting }
    /// What a job copies: phone entries into a Mac folder, or Mac items into a phone folder. Each carries its phone
    /// side by path as well (D-14): `paths[i]` is entry i's folder names from the storage root down to and including
    /// its own name; `path` is the destination folder's names ([] = the storage root). Handles hold for one session
    /// only; `Transfer.resolve` finds the items again by these after a replug (Pitfall 12).
    public enum Request: Sendable, Equatable {
        case download([ObjectEntry], paths: [[String]], to: URL)
        case upload([URL], storage: UInt32, parent: UInt32, path: [String])
    }

    public let id = UUID()
    /// The top-level names, for the row's label.
    public var names: [String]
    public var destinationName: String
    public var state: State = .scanning
    /// The user's answers so far; the copy is planned with them (D-01), and a Retry reuses them (D-17).
    public internal(set) var answers = ClashAnswers()
    /// The clashes still to ask about, in the order the job would copy the items.
    public internal(set) var questions: [Clash] = []
    /// What the failed row lists (D-12). Kept through a Retry: an attempt that ends early never lists less (D-13).
    public internal(set) var failures: [TransferFailure] = []
    /// Never planned again: finished files, the user's Skips (D-19) and what a first run's Stop cut off (D-15).
    public internal(set) var settled: Set<ItemKey> = []
    /// Folders made or merged into, with their name at the destination: a Retry continues inside them (D-17).
    public internal(set) var folders: [ItemKey: String] = [:]
    /// Upload temps a cut left on the phone, for the fix-up (D-24).
    public internal(set) var leftovers: [PhoneLeftover] = []
    /// Set by `ended` on a running job, whose task then reports: what it didn't copy is listed with this detail, never
    /// treated as the user's Stop.
    public internal(set) var endedDetail: String?
    public var done: UInt64 = 0
    public var total: UInt64 = 0
    /// What it copies, and the session its handles belong to; both change only by `TransferJobs.rebind`, when a Retry
    /// after a replug finds the items again by path (D-14).
    public internal(set) var request: Request
    public internal(set) var session: DeviceSession
    /// The phone it copies with; a Retry needs that same phone (D-14).
    public let phone: PhoneID
    /// Waiting for a silent reconnect (D-16): set on reconnecting jobs and on asking jobs of the dropped session.
    public internal(set) var isPaused = false
    /// The state it was paused from; `resumed` picks up there.
    public internal(set) var pausedFrom: State?
    /// How often each item was in flight when a reconnect cut the run: the second loss lists it (D-16).
    public internal(set) var lostCount: [ItemKey: Int] = [:]
    /// Real failures from before a reconnect, and items lost twice: listed at the end, never retried by the
    /// continuation.
    public internal(set) var carried: [TransferFailure] = []
    /// The item in flight and those not reached when a reconnect cut the run: the continuation copies them, and any
    /// end before it does lists them.
    public internal(set) var pending: [TransferFailure] = []
    /// Paused while its attempt was still running: that run hasn't reported yet, and holds the copy slot until it does.
    public internal(set) var awaitingRun = false
    /// What the next plan leaves out: settled items and carried failures. `close` folds `carried` into `failures`, so
    /// at a Retry this is `settled` alone and every listed item is planned again (SC4).
    public var excluded: Set<ItemKey> { settled.union(carried.compactMap(\.key)) }

    /// Nothing of a reconnect left: `close` has folded it into `failures`.
    mutating func forgetReconnect() {
        isPaused = false; pausedFrom = nil; lostCount = [:]; carried = []; pending = []; awaitingRun = false
    }

    public var direction: Direction {
        if case .upload = request { .upload } else { .download }
    }

    public init(names: [String], destinationName: String, request: Request, phone: PhoneID, session: DeviceSession) {
        self.names = names; self.destinationName = destinationName; self.request = request; self.phone = phone
        self.session = session
    }
}

/// The queue's transitions, pure (no tasks, clocks or UI). Every job is scanned and asks its questions as soon as it is
/// added (D-05); jobs copy one at a time, the oldest answered one first (P3 D-02); a stop per job (D-03, D-06). Every
/// way an attempt ends rebuilds the job's failed list through `close`. Each transition is a no-op outside the state it
/// expects, so a stop is never overwritten.
public struct TransferJobs: Sendable {
    /// Every job, in the order it was added (a Retry moves to the end).
    public private(set) var all: [TransferJob] = []
    /// No row at all: the Copy window closes (D-03). A failed row is a row (D-12).
    public var isEmpty: Bool { all.isEmpty }
    /// Any job but a failed row: failed rows don't keep the Mac awake, ask before quitting or block the browser
    /// (RESEARCH Pitfall 7, D-18).
    public var hasActive: Bool { all.contains { $0.state != .failed } }

    public init() {}

    /// Queues `job` as scanning.
    public mutating func add(_ job: TransferJob) {
        var job = job
        job.state = .scanning
        all.append(job)
    }

    /// The scan found `clashes` (in plan order): asking until they're answered, else waiting for its turn.
    public mutating func scanned(_ id: TransferJob.ID, clashes: [Clash]) {
        guard let i = index(id), all[i].state == .scanning else { return }
        all[i].questions = clashes
        all[i].state = clashes.isEmpty ? .waiting : .asking
    }

    /// `clash`, the job's first question, was answered. Apply to All also answers every remaining question it covers
    /// (a type clash stays when the answer is Replace, D-08). A Skip settles the items it covers, so a job ended before
    /// it copies never lists them (D-19). No question left → waiting, or still paused if a reconnect is under way, so
    /// nothing starts on the dropped session.
    public mutating func answer(_ id: TransferJob.ID, clash: ItemKey, with answer: ClashAnswer, applyToAll: Bool) {
        guard let i = index(id), all[i].state == .asking, all[i].questions.first?.id == clash else { return }
        all[i].answers.byItem[clash] = answer
        all[i].questions.removeFirst()
        var covered = [clash]
        if applyToAll {
            all[i].answers.all = answer
            let answers = all[i].answers
            covered += all[i].questions.filter { answers.answer(for: $0) != nil }.map(\.id)
            all[i].questions.removeAll { answers.answer(for: $0) != nil }
        }
        if answer == .skip { all[i].settled.formUnion(covered) }
        guard all[i].questions.isEmpty else { return }
        if all[i].isPaused {
            all[i].state = .reconnecting
            all[i].pausedFrom = .waiting
        } else {
            all[i].state = .waiting
        }
    }

    /// The question to show: the first asking job's first question (FIFO across jobs, D-05).
    public var nextQuestion: (job: TransferJob.ID, clash: Clash)? {
        guard let job = all.first(where: { $0.state == .asking }), let clash = job.questions.first else { return nil }
        return (job.id, clash)
    }

    /// The oldest waiting (answered) job, now preparing; nil while another job is running (preparing, copying or
    /// canceling, or a run a reconnect cut that hasn't reported: it still holds the slot, P3 D-02). A job still
    /// scanning or asking never holds up a later answered one (RESEARCH Open Question 9); a failed row or a
    /// reconnecting job never starts.
    public mutating func startNext() -> TransferJob? {
        guard !all.contains(where: { [.preparing, .copying, .canceling].contains($0.state) || $0.awaitingRun }),
              let i = all.firstIndex(where: { $0.state == .waiting }) else { return nil }
        all[i].state = .preparing
        return all[i]
    }

    /// Planning finished: preparing → copying with `total`, from 0 (a continuation plans only what is left). A no-op
    /// otherwise, so a stop is never overwritten.
    public mutating func begin(_ id: TransferJob.ID, total: UInt64) {
        guard let i = index(id), all[i].state == .preparing else { return }
        all[i].state = .copying
        all[i].total = total
        all[i].done = 0
    }

    public mutating func add(bytes: UInt64, to id: TransferJob.ID) {
        if let i = index(id) { all[i].done &+= bytes }
    }

    /// The row's stop button, or Stop on the clash sheet (D-03, D-15). A scanning, asking or waiting job ends now
    /// (true for a scanning one: the caller cancels its scan); a running one turns canceling and true tells the caller
    /// to cancel its task, whose `finish` ends it; canceling, failed or unknown → false. A first run leaves; a Retry
    /// goes back to its failed row with everything it listed. A reconnecting job ends now, unless the run a reconnect
    /// cut is still out: then it is a running one (its task is cancelled and its report ends it, leftovers kept).
    public mutating func stop(_ id: TransferJob.ID) -> Bool {
        guard let i = index(id) else { return false }
        switch all[i].state {
        case .reconnecting where all[i].awaitingRun, .preparing, .copying: all[i].state = .canceling; return true
        case .scanning: close(i, outcome: TransferOutcome(), stop: true, fallback: nil); return true
        case .asking, .waiting, .reconnecting: close(i, outcome: TransferOutcome(), stop: true, fallback: nil); return false
        case .canceling, .failed: return false
        }
    }

    /// A silent reconnect began (D-16): every job that isn't failed or being stopped pauses, whatever session it is
    /// bound to (AppModel calls this exactly when its one session drops, as for `ended`). Scanning, waiting, preparing
    /// and copying jobs turn reconnecting; an asking one stays asking, so its sheet keeps working. A preparing or
    /// copying one's attempt is still running: `awaitingRun` until it reports. Returns the scanning jobs, whose scans
    /// the caller cancels (they only wait on the dead session, so they end before the new one opens).
    public mutating func paused() -> [TransferJob.ID] {
        var cancel: [TransferJob.ID] = []
        for i in all.indices where ![.failed, .canceling].contains(all[i].state) {
            all[i].isPaused = true
            switch all[i].state {
            case .reconnecting: continue                    // paused again before its run reported, or before resuming
            case .asking: all[i].pausedFrom = .asking; continue
            case .scanning: cancel.append(all[i].id)
            case .preparing, .copying: all[i].awaitingRun = true
            default: break
            }
            all[i].pausedFrom = all[i].state
            all[i].state = .reconnecting
        }
        return cancel
    }

    /// The same phone is back after a silent reconnect (`isSameDevice`, D-16): each paused job picks up where it
    /// was. A cut copy waits again in its place (once its run has reported, below), a scan starts again (the returned
    /// ids), an asking job keeps its questions and answers. No rebind: the scan or attempt finds the items again by
    /// path (`job.session` is the old one, 04-08). `pending` stays until the continuation ends.
    public mutating func resumed(_ phone: PhoneID) -> [TransferJob.ID] {
        var rescan: [TransferJob.ID] = []
        for i in all.indices where all[i].isPaused && all[i].phone.isSameDevice(as: phone) {
            all[i].isPaused = false
            guard !all[i].awaitingRun else { continue }     // its run's report moves it on (`finish`)
            switch all[i].pausedFrom {
            case .scanning?: all[i].state = .scanning; rescan.append(all[i].id)
            case .asking?: break
            default: all[i].state = .waiting
            }
            all[i].pausedFrom = nil
        }
        return rescan
    }

    /// A job's task ended with `outcome`; `fallback` is a planning failure's detail. Unknown or already failed → no
    /// change: a task that returns after its job was stopped, pulled or failed never empties or removes that row. The
    /// ended mark wins over the canceling state `ended` set, so a pulled job is never taken for a user Stop; otherwise
    /// a canceling job or a cancelled run is a Stop whatever `lost` says (its cleanup may have lost the session: still
    /// the user's Stop, P3 D-10, D-15); a loss lists with the loss's detail. A reconnecting job's run was cut by the
    /// reconnect: it is kept for the continuation (`cutRunReported`), not closed.
    public mutating func finish(_ id: TransferJob.ID, outcome: TransferOutcome, fallback: String? = nil) {
        guard let i = index(id), all[i].state != .failed else { return }
        if all[i].state == .reconnecting {
            cutRunReported(i, outcome: outcome)
        } else if let detail = all[i].endedDetail {
            close(i, outcome: outcome, stop: false, fallback: detail)
        } else if all[i].state == .canceling || outcome.cancelled {
            close(i, outcome: outcome, stop: true, fallback: nil)
        } else if let lost = outcome.lost {
            close(i, outcome: outcome, stop: false, fallback: lost.detail)
        } else {
            close(i, outcome: outcome, stop: false, fallback: fallback)
        }
    }

    /// The session ended (unplug, replug or reconnect; handles die with it, Pitfall 11). Every job that isn't failed or
    /// being stopped by the user ends (D-13): a scanning, asking, waiting or reconnecting one at once, through `close`
    /// with its answers, carried and pending items kept; a preparing or copying one, or a reconnecting one whose cut
    /// run is still out, turns canceling with the ended mark, and its `finish` ends it. Returns the ids
    /// whose task the caller cancels (scanning, preparing, copying). No session is taken: the app holds one at a time
    /// and calls this exactly when it ends, so every job left is bound to it or to an older, dead one.
    public mutating func ended(disconnected: Bool) -> [TransferJob.ID] {
        let detail = disconnected ? MTPError.deviceGone.detail : TransferText.connectionReset
        var cancel: [TransferJob.ID] = []
        for id in all.map(\.id) {
            guard let i = index(id) else { continue }
            switch all[i].state {
            case .reconnecting where all[i].awaitingRun, .preparing, .copying:
                all[i].state = .canceling
                all[i].endedDetail = detail
                cancel.append(id)
            case .scanning, .asking, .waiting, .reconnecting:
                if all[i].state == .scanning { cancel.append(id) }
                close(i, outcome: TransferOutcome(), stop: false, fallback: detail)
            case .canceling, .failed:
                break
            }
        }
        return cancel
    }

    /// Retry (D-17): a failed row scans again with everything it knows (answers, settled, folders, leftovers, and the
    /// failures `close` keeps if this attempt ends early), behind the jobs already waiting (FIFO). Nothing of a
    /// reconnect is excluded any more, so every retryable item the row lists is planned (SC4). Else false.
    public mutating func retry(_ id: TransferJob.ID) -> Bool {
        guard let i = index(id), all[i].state == .failed else { return false }
        var job = all.remove(at: i)
        job.forgetReconnect()
        job.state = .scanning
        job.done = 0
        all.append(job)
        return true
    }

    /// × on a failed row (D-18).
    public mutating func dismiss(_ id: TransferJob.ID) {
        if let i = index(id), all[i].state == .failed { all.remove(at: i) }
    }

    /// The fix-up handled `handled` (D-24): those leftovers are forgotten, and the items it `finished` are settled and
    /// no longer listed. A leftover it couldn't reach stays recorded. A failed row left listing nothing, with nothing
    /// on the phone, goes; a job in any other state (a Retry's attempt-start fix-up) never does.
    public mutating func fixedUp(_ id: TransferJob.ID, handled: [PhoneLeftover], finished: Set<ItemKey>) {
        guard let i = index(id) else { return }
        all[i].settled.formUnion(finished)
        all[i].failures.removeAll { $0.key.map(finished.contains) ?? false }
        all[i].leftovers.removeAll(where: handled.contains)
        if all[i].state == .failed && all[i].failures.isEmpty && all[i].leftovers.isEmpty { all.remove(at: i) }
    }

    /// Whether a failed row's Retry can run: something to retry (a retryable item, or a leftover to fix up) and the
    /// job's own phone connected, whatever session it is on now (D-14; CONTEXT discretion: a row of only
    /// non-retryable items offers no Retry).
    public func canRetry(_ id: TransferJob.ID, connected: PhoneID?) -> Bool {
        guard let job = all.first(where: { $0.id == id }), job.state == .failed, job.phone.isSame(as: connected)
        else { return false }
        return job.failures.contains(where: \.retryable) || !job.leftovers.isEmpty
    }

    /// A job planned on an earlier session, found again by path on the connected one (`Transfer.resolve`, D-14).
    public mutating func rebind(_ id: TransferJob.ID, session: DeviceSession, request: TransferJob.Request) {
        guard let i = index(id) else { return }
        all[i].session = session
        all[i].request = request
    }

    /// The one place a job's failed list is rebuilt, whatever ended the attempt: a finish, a stop in any state, a pull
    /// (D-12, D-13, D-15, D-19). What it listed before counts as listed: its failures, and after a silent reconnect
    /// what it carried and had pending (D-16). `stop`: the user's Stop. `fallback`: the detail for entries that have
    /// none, and for a job that never listed anything, one failure per top-level item it hasn't settled or made. The
    /// job leaves when nothing is listed and nothing is left on the phone; else it is a failed row.
    private mutating func close(_ i: Int, outcome: TransferOutcome, stop: Bool, fallback: String?) {
        var job = all[i]
        job.settled.formUnion(outcome.settled)
        job.folders.merge(outcome.folders) { _, made in made }
        job.leftovers += outcome.leftovers
        let earlier = job.failures + job.carried + job.pending
        // A first run never had a failed row. Its Stop settles what it cut off, and what a reconnect left pending: the
        // user chose not to copy those (D-15). Its carried failures are real ones from before the Stop: they stay.
        let firstRun = job.failures.isEmpty
        if stop && firstRun { job.settled.formUnion((outcome.unreached + job.pending).compactMap(\.key)) }
        let before = Dictionary(earlier.compactMap { f in f.key.map { ($0, f.detail) } }, uniquingKeysWith: { a, _ in a })
        var failures: [TransferFailure] = []
        for var f in Self.stillListed(earlier, after: outcome) + outcome.failed + (stop && firstRun ? [] : outcome.unreached) {
            if let key = f.key, job.settled.contains(key) { continue }
            if f.detail.isEmpty {               // the run saw a cancel as a stop
                f.detail = fallback ?? f.key.flatMap { before[$0] } ?? TransferText.stoppedBefore
            }
            if let key = f.key, let j = failures.firstIndex(where: { $0.key == key }) {
                failures[j] = f
            } else {
                failures.append(f)
            }
        }
        // Judged by the job, not this outcome (`ended` passes an empty one): a job that never ran lists every top-level
        // item the user didn't skip; one whose earlier run finished or made everything lists nothing.
        if failures.isEmpty, earlier.isEmpty, let fallback {
            failures = job.names.indices.compactMap { top in
                let key = ItemKey(top: top)
                guard !job.settled.contains(key), job.folders[key] == nil else { return nil }
                return TransferFailure(name: job.names[top], detail: fallback, key: key)
            }
        }
        if failures.isEmpty && job.leftovers.isEmpty {
            all.remove(at: i)
            return
        }
        job.failures = failures
        job.state = .failed
        job.questions = []
        job.endedDetail = nil
        job.forgetReconnect()
        all[i] = job
    }

    /// The run a silent reconnect cut has reported (D-16). What it finished and made is kept, its real failures are
    /// carried, and what it didn't get to waits for the continuation: earlier pending items it didn't reach, the item
    /// in flight (tried once more; lost a second time it is carried as failed and the job moves on), then the items
    /// it didn't reach. The job stays reconnecting; if it was already resumed it now waits for its turn.
    private mutating func cutRunReported(_ i: Int, outcome: TransferOutcome) {
        var job = all[i]
        job.settled.formUnion(outcome.settled)
        job.folders.merge(outcome.folders) { _, made in made }
        job.leftovers += outcome.leftovers
        let key = outcome.unfinished
        func inFlight(_ f: TransferFailure) -> Bool { key != nil && f.key == key }
        var retried = (outcome.failed + outcome.unreached).first(where: inFlight).map { [$0] } ?? []
        if let key, !retried.isEmpty {
            job.lostCount[key, default: 0] += 1
            if job.lostCount[key, default: 0] >= 2 {
                job.carried += retried
                retried = []
            }
        }
        job.carried += outcome.failed.filter { !inFlight($0) }
        job.pending = Self.stillListed(job.pending, after: outcome) + retried + outcome.unreached.filter { !inFlight($0) }
        if job.awaitingRun {
            job.awaitingRun = false
            if !job.isPaused {
                job.state = .waiting
                job.pausedFrom = nil
            }
        }
        all[i] = job
    }

    /// The entries a row listed that still stand after `outcome`: the attempt never got to them. An entry gives way
    /// when the outcome reached it or anything inside it (finished, made, failed or listed it again), so a listed
    /// folder gives way to its contents; and when the outcome failed something it is inside (a moved folder, a gone
    /// item), which a Retry would only repeat.
    private static func stillListed(_ entries: [TransferFailure], after outcome: TransferOutcome) -> [TransferFailure] {
        func inside(_ key: ItemKey, _ outer: ItemKey) -> Bool { key.top == outer.top && key.path.starts(with: outer.path) }
        let failed = outcome.failed.compactMap(\.key)
        let reached = Array(outcome.settled) + Array(outcome.folders.keys) + failed + outcome.unreached.compactMap(\.key)
        return entries.filter { entry in
            guard let key = entry.key else { return true }
            return !reached.contains { inside($0, key) } && !failed.contains { inside(key, $0) }
        }
    }

    private func index(_ id: TransferJob.ID) -> Int? { all.firstIndex { $0.id == id } }
}

/// D-11's answer to each quit request. Asking never holds the request open (no `.terminateLater`): AppKit's
/// terminate-later loop can't drain the main queue when quit came from a main-queue block, so the question, the stop
/// and the wait would all deadlock. Instead the request is refused while asking or stopping, and Stop & Quit quits
/// again once the jobs have settled.
public struct QuitGate: Sendable {
    public enum Step: Sendable, Equatable { case quit, ask, refuse }
    private enum State: Sendable { case idle, asking, stopping, stopped }
    private var state = State.idle

    public init() {}

    /// A quit was requested while `copying` (any job exists).
    public mutating func request(copying: Bool) -> Step {
        switch state {
        case .stopped: return .quit
        case .asking, .stopping: return .refuse
        case .idle:
            guard copying else { return .quit }
            state = .asking
            return .ask
        }
    }

    /// The question was answered: Stop & Quit (`stop`) or Cancel.
    public mutating func answered(stop: Bool) { state = stop ? .stopping : .idle }

    /// Stop & Quit's cleanup is over; the next request quits.
    public mutating func stopped() { state = .stopped }
}

/// The silent-reconnect bound shared by every reconnect path (WR-06, T-03-20): refused when it would be the third
/// within a minute, so a broken phone ends on the error screen instead of looping.
public struct ReconnectLimit: Sendable {
    private var recent: [ContinuousClock.Instant] = []

    public init() {}

    public mutating func allow(at now: ContinuousClock.Instant) -> Bool {
        recent = recent.filter { now - $0 < .seconds(60) } + [now]
        return recent.count < 3
    }
}

/// Bytes per second over the last 5 s of (time, cumulative bytes) samples; nil until 2 s of samples exist, so the
/// rate and time remaining settle instead of jumping with each chunk.
public struct RateMeter: Sendable {
    private var samples: [(time: Double, done: UInt64)] = []

    public init() {}

    public mutating func add(done: UInt64, at seconds: Double) {
        samples.append((seconds, done))
        samples.removeAll { $0.time < seconds - 5 }
    }

    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 2 else { return nil }
        return Double(last.done &- min(first.done, last.done)) / (last.time - first.time)
    }
}

/// Copy-window wording.
public enum TransferText {
    /// D-11's question before quitting or closing the main window while a copy exists.
    public static let quitQuestion = "A copy is in progress. Stop it and quit?"
    /// A phone Replace whose original the phone wouldn't delete: the new copy is removed, the original stays.
    public static let replaceRefused = "The phone didn’t allow replacing the item, so the original was kept."
    /// A phone Replace whose final rename was still refused after the original was deleted: the temp is kept (D-27).
    public static let finishOnRetry = "The new copy is on the phone under a hidden name. Retry finishes it."
    /// A link or special file in an upload: listed, never followed (T-03-07), and not retryable.
    public static let linkNotCopied = "It’s a link, so it wasn’t copied."
    /// A folder an earlier attempt of the job made or merged into is no longer there (D-17): its contents aren't
    /// copied into a new folder under another name.
    public static let folderMoved = "The folder it was being copied into was moved or deleted."

    /// An item a Stop cut off whose run gave no reason, on a row that keeps it (a Retry's).
    public static let stoppedBefore = "The copy was stopped before this item."
    /// A session end that wasn't an unplug (a reconnect past the bound, a replug).
    public static let connectionReset = "The connection to the phone was reset."
    /// An item of a job that is no longer on the phone: gone since it was picked, or not found again after a replug.
    public static let itemGone = "The item is no longer on the phone."
    /// An upload's destination folder isn't on the phone any more (D-14): nothing of the job can go there.
    public static let folderGone = "The folder you were copying to is no longer on the phone."
    /// A row paused for a silent reconnect (D-16).
    public static let reconnecting = "Reconnecting…"

    /// O-07: a change cut short by an unplug, e.g. "Moving “a.jpg” didn’t finish because the phone was disconnected."
    public static func interrupted(_ operation: String) -> String {
        "\(operation) didn’t finish because the phone was disconnected."
    }

    /// A failed row's Retry while its own phone isn't connected (D-14).
    public static func connectToRetry(_ phone: String) -> String { "Connect “\(phone)” to retry." }

    /// D-01: × on a failed row that still holds a phone temp asks first, naming the temps' items.
    public static func removeQuestion(names: [String]) -> String {
        names.count == 1 ? "Remove this row without finishing “\(names[0])”?"
                         : "Remove this row without finishing \(names.count.formatted()) items?"
    }
    /// D-02c: why removing that row loses something.
    public static let removeDetail = "Part of the copy is still on the phone under a hidden name. Retry finishes it, "
        + "but once you remove the row, the app can’t."
    /// D-03b: the × button's label and tooltip, and the confirmation's destructive button.
    public static let removeFromList = "Remove from List"

    /// The failed row's title (D-12): "“IMG_2.jpg” couldn’t be copied" / "3 items couldn’t be copied". One item is named
    /// by its key, as the Show sheet does (`itemPath` with the job's top-level `names`): its source name, never the Keep
    /// Both name a run-time failure carries (IN-04).
    public static func failedTitle(_ failures: [TransferFailure], names: [String] = []) -> String {
        guard failures.count == 1 else { return "\(failures.count.formatted()) items couldn’t be copied" }
        let one = failures[0]
        let name = one.key.flatMap { $0.path.last ?? (names.indices.contains($0.top) ? names[$0.top] : nil) } ?? one.name
        return "“\(name)” couldn’t be copied"
    }

    /// Where a failed item is in its job: the top-level name, then the key's path, joined with "/".
    public static func itemPath(_ key: ItemKey, names: [String]) -> String {
        ((names.indices.contains(key.top) ? [names[key.top]] : []) + key.path).joined(separator: "/")
    }

    /// "Copying “IMG_2.jpg” to “Downloads”" / "Copying 3 items to “Downloads”".
    public static func title(names: [String], destination: String) -> String {
        names.count == 1 ? "Copying “\(names[0])” to “\(destination)”"
                         : "Copying \(names.count.formatted()) items to “\(destination)”"
    }

    /// The top label while the tree is scanned (indeterminate bar).
    public static func preparing(destination: String) -> String { "Preparing to copy to “\(destination)”" }
    /// P-01: the move sheet's line while a move is checked.
    public static func preparingMove(names: [String]) -> String {
        names.count == 1 ? "Preparing to move “\(names[0])”…" : "Preparing to move \(names.count.formatted()) items…"
    }
    public static let waiting = "Waiting…"
    public static let canceling = "Canceling…"
    /// The bottom line of a row whose clash question is waiting on the user (D-02).
    public static let asking = "Waiting for your answer…"

    /// D-04: Finder's clash question, older/newer by modified date to the second (plain when equal or unknown), and a
    /// detail line with each item's size and date. A type clash has no Replace (D-08), so it asks nothing about one.
    /// `verb`: "moving" for a move on the phone (D-12); copies keep "copying".
    public static func clash(_ clash: Clash, verb: String = "copying") -> AlertText {
        let name = clash.existing.name
        let message: String
        if !clash.allowsReplace {
            message = "An item named “\(name)” already exists in this location."
        } else {
            let second = { (date: Date) in date.timeIntervalSinceReferenceDate.rounded(.down) }
            switch (clash.existing.modified.map(second), clash.incoming.modified.map(second)) {
            case let (old?, new?) where old < new:
                message = "An older item named “\(name)” already exists in this location. Do you want to replace it with the newer one you’re \(verb)?"
            case let (old?, new?) where old > new:
                message = "A newer item named “\(name)” already exists in this location. Do you want to replace it with the older one you’re \(verb)?"
            default:
                message = "An item named “\(name)” already exists in this location. Do you want to replace it with the one you’re \(verb)?"
            }
        }
        func line(_ label: String, _ side: Clash.Side) -> String {
            "\(label): \(side.isFolder ? "folder" : EntryFormat.bytes(side.size ?? 0))"
                + (side.modified.map { ", modified \(EntryFormat.date($0))" } ?? "")
        }
        return AlertText(message: message,
                         detail: line("Existing item", clash.existing) + "\n" + line("Item you’re \(verb)", clash.incoming))
    }

    /// The original app's time-remaining buckets, half-open; nil, negative or non-finite → still estimating.
    public static func remaining(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "Estimating time remaining…" }
        switch s {
        case ..<5: return "Less than 5 seconds remaining"
        case ..<15: return "Less than 15 seconds remaining"
        case ..<30: return "Less than 30 seconds remaining"
        case ..<90: return "About 1 minute remaining"
        case ..<3570: return "About \(Int((s / 60).rounded())) minutes remaining"
        case ..<5400: return "About 1 hour remaining"
        default: return "About \(Int((s / 3600).rounded()).formatted()) hours remaining"
        }
    }

    /// floor(done × 100 / total), exact in 128 bits; 0 for an empty job, never above 100 (untrusted sizes).
    public static func percent(done: UInt64, total: UInt64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(UInt128(done) * 100 / UInt128(total), 100))
    }

    /// "1.2 GB of 4.5 GB (40.2 MB/s) – About 1 minute remaining"; no rate yet → "… – Estimating time remaining…".
    public static func progress(done: UInt64, total: UInt64, bytesPerSecond: Double?) -> String {
        let rate = bytesPerSecond
        let speed = rate.map { " (\(EntryFormat.bytes(UInt64(clamping: Int64(exactly: $0.rounded()) ?? 0)))/s)" } ?? ""
        let left = rate.flatMap { $0 > 0 ? Double(total &- min(done, total)) / $0 : nil }
        return "\(EntryFormat.bytes(done)) of \(EntryFormat.bytes(total))\(speed) – \(remaining(left))"
    }

    /// The OK-only refusal of a job that doesn't fit (D-04).
    public static func noSpace(names: [String], needed: UInt64, available: UInt64) -> AlertText {
        let what = names.count == 1 ? "“\(names[0])”" : "The \(names.count.formatted()) items"
        return AlertText(message: "\(what) can’t be copied because there isn’t enough free space.",
                         detail: spaceLine(needed: needed, available: available))
    }

    /// The needed/available line under every out-of-space refusal.
    static func spaceLine(needed: UInt64, available: UInt64) -> String {
        "It needs \(EntryFormat.bytes(needed)), but only \(EntryFormat.bytes(available)) is available."
    }

    /// O-06a: the Mac refused a write.
    public static let macNoWritePermission = "You don’t have permission to save to this folder."
    /// O-06b: the Mac's disk filled up.
    public static let macFull = "There isn’t enough free space on this Mac."
    /// O-06c: the Mac destination is read-only.
    public static let macReadOnly = "The disk you’re copying to is read-only."
    /// O-06d: an upload source is gone.
    public static let sourceGone = "The item is no longer on this Mac."
    /// O-06e: an upload source can't be read.
    public static let sourceUnreadable = "You don’t have permission to read this item."

    /// O-06: a Mac file error as a plain reason; anything unmapped keeps the system's text.
    public static func macReason(_ error: any Error) -> String {
        switch error {
        case let e as CocoaError:
            switch e.code {
            case .fileWriteNoPermission: return macNoWritePermission
            case .fileWriteOutOfSpace: return macFull
            case .fileWriteVolumeReadOnly: return macReadOnly
            case .fileReadNoSuchFile: return sourceGone
            case .fileReadNoPermission: return sourceUnreadable
            default: break
            }
        case let e as POSIXError:       // only the download write path throws POSIXError
            switch e.code {
            case .EACCES, .EPERM: return macNoWritePermission
            case .ENOSPC: return macFull
            case .EROFS: return macReadOnly
            default: break              // ENOENT here is the destination folder gone, not the source (RESEARCH Pitfall 6)
            }
        default: break
        }
        return error.localizedDescription
    }

    /// O-16/O-17: promised files the dragging app never handed over, collected into one alert per drop.
    public static func promiseFailed(names: [String]) -> AlertText {
        let one = names.count == 1
        return AlertText(message: one ? "“\(names[0])” couldn’t be copied." : "\(names.count.formatted()) items couldn’t be copied.",
                         detail: one ? "The app you dragged from didn’t hand over the file. Save it to a folder on this Mac first, then drag it here."
                                     : "The app you dragged from didn’t hand over the files. Save them to a folder on this Mac first, then drag them here.")
    }

    /// O-18/O-19: promises still missing at the 10-minute deadline; no names, since none was delivered.
    public static func promiseTimedOut(count: Int) -> AlertText {
        let one = count == 1
        return AlertText(message: "\(count.formatted()) \(one ? "item" : "items") couldn’t be copied.",
                         detail: "The app you dragged from didn’t hand \(one ? "it" : "them") over within 10 minutes. "
                            + "Save \(one ? "it" : "them") to a folder on this Mac first, then drag \(one ? "it" : "them") here.")
    }
}
