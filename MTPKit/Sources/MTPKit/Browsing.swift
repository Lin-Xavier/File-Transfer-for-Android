import Foundation

/// One folder on one storage. `folder` 0xFFFFFFFF is the storage root.
public struct FolderKey: Hashable, Sendable {
    public var storage: UInt32
    public var folder: UInt32

    public init(storage: UInt32, folder: UInt32) {
        self.storage = storage; self.folder = folder
    }
}

/// One opened folder in a path: its handle and the name shown in the title (D-02).
public struct Crumb: Hashable, Sendable {
    public var handle: UInt32
    public var name: String

    public init(handle: UInt32, name: String) {
        self.handle = handle; self.name = name
    }
}

/// Where the list is: a storage and the folders opened from its root. An empty path is the root.
public struct Location: Hashable, Sendable {
    public var storage: UInt32
    public var path: [Crumb]

    public init(storage: UInt32, path: [Crumb] = []) {
        self.storage = storage; self.path = path
    }

    public var key: FolderKey { FolderKey(storage: storage, folder: path.last?.handle ?? 0xFFFF_FFFF) }

    public func opening(_ crumb: Crumb) -> Location { Location(storage: storage, path: path + [crumb]) }
}

/// Listed folders for one session (D-15). A folder is shown while it fills; only a complete one is reused
/// without asking the phone again.
public struct FolderCache: Sendable, Equatable {
    public private(set) var folders: [FolderKey: [ObjectEntry]] = [:]
    public private(set) var complete: Set<FolderKey> = []
    /// Handles removed on the phone this session. AOSP never reuses a handle within a session, so a listing batch
    /// read before the removal was handled can't bring one back (RESEARCH Pattern 3 stale-batch guard).
    public private(set) var tombstones: Set<UInt32> = []

    public init() {}

    public subscript(key: FolderKey) -> [ObjectEntry]? { folders[key] }

    /// Starts (or restarts) a listing: the folder becomes empty and not complete.
    public mutating func begin(_ key: FolderKey) {
        folders[key] = []
        complete.remove(key)
    }

    /// Merges a batch by handle: an entry already in the folder is replaced, the rest are appended.
    public mutating func append(_ batch: [ObjectEntry], to key: FolderKey) {
        var list = folders[key] ?? []
        var index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in batch where !tombstones.contains(entry.id) {
            if let i = index[entry.id] {
                list[i] = entry
            } else {
                index[entry.id] = list.count
                list.append(entry)
            }
        }
        folders[key] = list
    }

    public mutating func finish(_ key: FolderKey) { complete.insert(key) }

    /// The re-list after a mutation (D-15, RESEARCH Pattern 4): `handles` is the folder's fresh GetObjectHandles,
    /// `fresh` the entries just re-read from the phone (new and touched handles). Other cached entries stay,
    /// handles no longer listed drop, and the folder is complete. `cachedBefore`: the folder's handles just before
    /// that GetObjectHandles; a row an event added since then stays even though `handles` misses it (WR-02).
    public mutating func reconcile(_ key: FolderKey, handles: [UInt32], fresh: [ObjectEntry],
                                   cachedBefore before: Set<UInt32>? = nil) {
        let current = folders[key] ?? []
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in fresh { byID[entry.id] = entry }
        let listed = Set(handles)
        let arrived = before.map { b in current.map(\.id).filter { !b.contains($0) && !listed.contains($0) } } ?? []
        folders[key] = (handles + arrived).compactMap { tombstones.contains($0) ? nil : byID[$0] }
        complete.insert(key)
    }

    public func isComplete(_ key: FolderKey) -> Bool { complete.contains(key) }

    /// ⌘R (D-16): the folder's fresh listing in one step, complete, so the list never blanks while it is re-read.
    public mutating func replace(_ key: FolderKey, entries: [ObjectEntry]) {
        folders[key] = entries.filter { !tombstones.contains($0.id) }
        complete.insert(key)
    }

    /// An event's object read back from the phone (BRWS-08): inserted or replaced by handle in its folder when that
    /// folder is cached, and taken out of any other folder (a move on the phone). Returns false when it didn't land
    /// in its folder: that folder was never listed, or the handle was removed.
    @discardableResult public mutating func upsert(_ entry: ObjectEntry) -> Bool {
        guard !tombstones.contains(entry.id) else { return false }
        let key = FolderKey(storage: entry.storageID, folder: entry.parent)
        for (other, list) in folders where other != key && list.contains(where: { $0.id == entry.id }) {
            folders[other] = list.filter { $0.id != entry.id }
        }
        guard var list = folders[key] else { return false }
        if let i = list.firstIndex(where: { $0.id == entry.id }) { list[i] = entry } else { list.append(entry) }
        folders[key] = list
        return true
    }

    public mutating func remove(_ key: FolderKey) {
        folders[key] = nil
        complete.remove(key)
    }

    /// An ObjectRemoved: tombstones the handle, drops it from the folder holding it (returned; nil when none
    /// does) and drops its own listing if it was a folder. Calling it again changes nothing.
    @discardableResult public mutating func removeObject(_ handle: UInt32) -> FolderKey? {
        tombstones.insert(handle)
        for key in folders.keys where key.folder == handle { remove(key) }
        guard let key = folders.first(where: { $0.value.contains { $0.id == handle } })?.key else { return nil }
        folders[key]?.removeAll { $0.id == handle }
        return key
    }

    /// The folder whose cached listing holds `handle` (0xFFFFFFFF for a storage root), or nil when none does.
    /// ponytail: linear scan over every cached entry; index by handle if selections of thousands get slow.
    public func parent(of handle: UInt32) -> UInt32? {
        folders.first { $0.value.contains { $0.id == handle } }?.key.folder
    }
}

/// Finder's delete wording (D-22, D-24, D-26).
public enum DeleteText {
    public static func confirmation(names: [String]) -> AlertText {
        let one = names.count == 1
        return AlertText(message: one ? "Are you sure you want to delete “\(names[0])”?"
                                      : "Are you sure you want to delete the \(names.count) selected items?",
                         detail: (one ? "This item" : "These items") + " will be deleted immediately. You can’t undo this action.")
    }

    /// One alert for everything that failed: the names, then the first failure's MTP code line. `refused`: items
    /// turned down on the Mac before anything was sent, listed after the phone's failures; their reason is the line
    /// only when the phone refused nothing.
    public static func failures(_ failed: [(name: String, error: MTPError)], refused: [(name: String, reason: String)] = [],
                                verb: String = "deleted") -> AlertText {
        let line = failed.first.map { $0.error.codeLine ?? $0.error.detail } ?? refused.first?.reason ?? ""
        let names = failed.map(\.name) + refused.map(\.name)
        if names.count == 1 { return AlertText(message: "“\(names[0])” couldn’t be \(verb).", detail: line) }
        return AlertText(message: "\(names.count) items couldn’t be \(verb).", detail: names.joined(separator: ", ") + "\n" + line)
    }
}

public enum DeletePlan {
    /// Drops every entry with a selected ancestor: deleting the ancestor already removes it. Keeps input order.
    public static func topLevel(_ selected: [ObjectEntry], parentOf: (UInt32) -> UInt32?) -> [ObjectEntry] {
        let ids = Set(selected.map(\.id))
        return selected.filter { entry in
            var handle = entry.parent
            for _ in 0..<256 {                             // a bound, in case a stale cache ever loops
                if ids.contains(handle) { return false }
                guard let up = parentOf(handle) else { return true }
                handle = up
            }
            return true
        }
    }
}

public enum Listing {
    /// Handles per `DeviceSession.entries` call: ~160 ms at the spike's 1.6 ms/item, so rows fill smoothly
    /// and a navigation cancel lands quickly (RESEARCH A5; tune on hardware).
    public static let batchSize = 100
}

/// One visited folder plus what the list looked like there, restored by Back/Forward (D-07, D-08).
public struct HistoryEntry: Hashable, Sendable {
    public var location: Location
    public var selected: Set<UInt32>
    public var expanded: Set<UInt32>
    public var scrollY: Double

    public init(location: Location, selected: Set<UInt32> = [], expanded: Set<UInt32> = [], scrollY: Double = 0) {
        self.location = location; self.selected = selected; self.expanded = expanded; self.scrollY = scrollY
    }
}

/// One storage's Finder-style back/forward history (D-06). Open and Enclosing Folder are new navigations that
/// clear Forward; Back and Forward move entries between the stacks with their recorded state (D-07).
public struct NavigationHistory: Sendable, Equatable {
    public private(set) var back: [HistoryEntry] = []
    public private(set) var current: HistoryEntry
    public private(set) var forward: [HistoryEntry] = []

    /// `path`: start already inside a folder, with nothing to go Back to (a reopened place, D-36).
    public init(storage: UInt32, path: [Crumb] = []) { current = HistoryEntry(location: Location(storage: storage, path: path)) }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public var canGoUp: Bool { !current.location.path.isEmpty }

    public mutating func open(_ crumb: Crumb) { open([crumb]) }

    /// Opens a folder below the current one; several crumbs when it sits inside expanded folders.
    public mutating func open(_ crumbs: [Crumb]) {
        guard !crumbs.isEmpty else { return }
        back.append(current)
        forward = []
        current = HistoryEntry(location: Location(storage: current.location.storage, path: current.location.path + crumbs))
    }

    @discardableResult public mutating func goBack() -> Bool {
        guard let destination = back.popLast() else { return false }
        forward.append(current)
        arrive(at: destination)
        return true
    }

    @discardableResult public mutating func goForward() -> Bool {
        guard let destination = forward.popLast() else { return false }
        back.append(current)
        current = destination
        return true
    }

    @discardableResult public mutating func goUp() -> Bool { goTo(depth: current.location.path.count - 1) }

    /// Path bar (D-03): a new navigation to the ancestor `depth` crumbs below the root (0 = the root).
    @discardableResult public mutating func goTo(depth: Int) -> Bool {
        let path = current.location.path
        guard (0..<path.count).contains(depth) else { return false }
        back.append(current)
        forward = []
        arrive(at: HistoryEntry(location: Location(storage: current.location.storage, path: Array(path.prefix(depth)))))
        return true
    }

    /// Saves what the list looks like now into the current entry; nil leaves that part alone.
    public mutating func record(selected: Set<UInt32>? = nil, expanded: Set<UInt32>? = nil, scrollY: Double? = nil) {
        if let selected { current.selected = selected }
        if let expanded { current.expanded = expanded }
        if let scrollY { current.scrollY = scrollY }
    }

    /// Disclosure triangles edit the current entry's expanded set in place, so a caller never reads the history
    /// inside its own mutating access to it (G-02-2: that was a Swift exclusivity crash).
    public mutating func expand(_ handle: UInt32) { current.expanded.insert(handle) }
    public mutating func collapse(_ handle: UInt32) { current.expanded.remove(handle) }

    /// A folder removed on the phone or deleted here: no history entry expands it any more (RESEARCH Pitfall 7),
    /// and Back/Forward entries inside it go, so neither lands on a dead folder (WR-04). Move `current` out first.
    /// ponytail: pruning can leave the same folder twice in a row (one Back that only restores selection); dedupe if it bothers.
    public mutating func forget(_ handle: UInt32) {
        func drop(_ e: inout HistoryEntry) { e.expanded.remove(handle) }
        func outside(_ e: HistoryEntry) -> Bool { !e.location.path.contains { $0.handle == handle } }
        back = back.filter(outside)
        forward = forward.filter(outside)
        drop(&current)
        for i in back.indices { drop(&back[i]) }
        for i in forward.indices { drop(&forward[i]) }
    }

    /// A folder renamed on the phone: every crumb naming it follows, so the title, path bar and D-36 reopen do (IN-03).
    public mutating func rename(_ handle: UInt32, to name: String) {
        func fix(_ e: inout HistoryEntry) {
            for i in e.location.path.indices where e.location.path[i].handle == handle { e.location.path[i].name = name }
        }
        fix(&current)
        for i in back.indices { fix(&back[i]) }
        for i in forward.indices { fix(&forward[i]) }
    }

    /// D-08: coming back up to an ancestor selects the folder you came from.
    private mutating func arrive(at destination: HistoryEntry) {
        var destination = destination
        let left = current.location.path, to = destination.location.path
        if to.count < left.count, Array(left.prefix(to.count)) == to {
            destination.selected = [left[to.count].handle]
        }
        current = destination
    }
}

/// The centred status row under the list (BRWS-05, D-30, D-11).
public enum StatusLine {
    /// "120 items, 12.4 GB available" / "3 of 120 selected, …"; "Loading… 1,200 items" while the folder fills.
    public static func text(itemCount: Int, selectedCount: Int, freeSpace: UInt64?, loadingCount: Int?) -> String {
        if let loadingCount { return "Loading… \(loadingCount.formatted()) items" }
        let counts = selectedCount > 0
            ? "\(selectedCount.formatted()) of \(itemCount.formatted()) selected"
            : "\(itemCount.formatted()) \(itemCount == 1 ? "item" : "items")"
        guard let freeSpace else { return counts }
        return "\(counts), \(EntryFormat.bytes(freeSpace)) available"
    }
}
