import Foundation
import Testing
@testable import MTPKit

@Suite struct BrowsingTests {
    static let key = FolderKey(storage: 0x0001_0001, folder: 1)

    static func entry(_ id: UInt32, _ name: String) -> ObjectEntry {
        ObjectEntry(id: id, storageID: key.storage, parent: key.folder, format: 0x3000, name: name, size: 1, modified: nil)
    }

    /// BRWS-06 adjacency edge: a handle delivered in two batches appears once, with its latest data.
    @Test func batchesMergeByHandle() {
        let a = Self.entry(1, "a"), b = Self.entry(2, "b"), b2 = Self.entry(2, "b renamed"), c = Self.entry(3, "c")
        var cache = FolderCache()
        cache.begin(Self.key)
        cache.append([a, b], to: Self.key)
        cache.append([b2, c], to: Self.key)
        #expect(cache[Self.key] == [a, b2, c])
        #expect(cache[Self.key]?.filter { $0.id == 2 }.count == 1)
    }

    @Test func lifecycle() {
        var cache = FolderCache()
        #expect(cache[Self.key] == nil)                                   // never listed
        cache.begin(Self.key)
        #expect(cache[Self.key] == [])
        #expect(!cache.isComplete(Self.key))
        cache.append([Self.entry(1, "a")], to: Self.key)
        cache.finish(Self.key)
        #expect(cache.isComplete(Self.key))
        cache.begin(Self.key)                                             // a re-list empties and reopens it
        #expect(cache[Self.key] == [])
        #expect(!cache.isComplete(Self.key))
        cache.finish(Self.key)
        cache.remove(Self.key)
        #expect(cache[Self.key] == nil)
        #expect(!cache.isComplete(Self.key))
        #expect(cache[FolderKey(storage: Self.key.storage, folder: 0xFFFF_FFFF)] == nil)
    }

    /// BRWS-06 ordering edge: the shown order doesn't depend on the order batches arrived in.
    @Test func orderIgnoresBatchOrder() {
        let a = Self.entry(1, "a"), b = Self.entry(2, "b"), c = Self.entry(3, "c")
        var split = FolderCache(), whole = FolderCache()
        split.append([c], to: Self.key)
        split.append([a, b], to: Self.key)
        whole.append([a, b, c], to: Self.key)
        let shown = split[Self.key]?.sorted(by: .name, ascending: true)
        #expect(shown == whole[Self.key]?.sorted(by: .name, ascending: true))
        #expect(shown?.map(\.name) == ["a", "b", "c"])
    }

    @Test func location() {
        let root = Location(storage: 0x0001_0001)
        #expect(root.key.folder == 0xFFFF_FFFF)
        #expect(root.key.storage == 0x0001_0001)
        let dcim = root.opening(Crumb(handle: 1, name: "DCIM"))
        #expect(dcim.key.folder == 1)
        #expect(dcim.path.map(\.name) == ["DCIM"])
        #expect(dcim.opening(Crumb(handle: 9, name: "Camera")).path.map(\.name) == ["DCIM", "Camera"])
    }

    // MARK: - NavigationHistory (BRWS-03; D-06..D-08)

    /// Mutating calls can't sit inside `#expect`, so step first, then check the result.
    static func moved(_ h: inout NavigationHistory, _ step: Step) -> Bool {
        switch step {
        case .goBack: h.goBack()
        case .goForward: h.goForward()
        case .goUp: h.goUp()
        }
    }

    enum Step { case goBack, goForward, goUp }

    static let dcim = Crumb(handle: 1, name: "DCIM"), camera = Crumb(handle: 9, name: "Camera"),
               music = Crumb(handle: 2, name: "Music")

    @Test func newHistoryGoesNowhere() {
        var h = NavigationHistory(storage: Self.key.storage)
        let start = h
        #expect(!h.canGoBack && !h.canGoForward && !h.canGoUp)
        let back = h.goBack(), forward = h.goForward(), up = h.goUp()
        #expect(!back && !forward && !up)
        #expect(h == start)
        #expect(h.current.location == Location(storage: Self.key.storage))
    }

    /// D-08: Back lands on the parent with the folder you came from selected.
    @Test func backSelectsTheFolderYouCameFrom() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        #expect(h.canGoBack && h.canGoUp && !h.canGoForward)
        #expect(Self.moved(&h, .goBack))
        #expect(h.current.location.path.isEmpty)
        #expect(h.current.selected == [Self.dcim.handle])
        #expect(Self.moved(&h, .goForward))
        #expect(h.current.location.path == [Self.dcim])
        #expect(!h.canGoForward)
    }

    @Test func openingClearsForward() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        #expect(Self.moved(&h, .goBack))
        #expect(h.canGoForward)
        h.open(Self.music)
        #expect(h.forward.isEmpty && !h.canGoForward)
        #expect(h.current.location.path == [Self.music])
        #expect(h.current.selected.isEmpty && h.current.scrollY == 0)
    }

    /// Enclosing Folder is a new navigation: Back undoes it, Forward is cleared (Finder).
    @Test func upIsANewNavigation() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        h.open(Self.camera)
        #expect(Self.moved(&h, .goUp))
        #expect(h.current.location.path == [Self.dcim])
        #expect(h.current.selected == [Self.camera.handle])
        #expect(!h.canGoForward)
        #expect(Self.moved(&h, .goBack))
        #expect(h.current.location.path == [Self.dcim, Self.camera])
    }

    /// D-07: each entry keeps its own expansion and scroll; D-08 overrides the selection coming back up.
    @Test func backAndForwardRestoreRecordedState() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        h.record(selected: [5], expanded: [1], scrollY: 120)
        h.open(Self.camera)
        h.record(selected: [7], expanded: [3], scrollY: 40)
        #expect(Self.moved(&h, .goBack))
        #expect(h.current.location.path == [Self.dcim])
        #expect(h.current.expanded == [1])
        #expect(h.current.scrollY == 120)
        #expect(h.current.selected == [Self.camera.handle])
        #expect(Self.moved(&h, .goForward))
        #expect(h.current.location.path == [Self.dcim, Self.camera])
        #expect(h.current.selected == [7] && h.current.expanded == [3] && h.current.scrollY == 40)
    }

    /// G-02-2: disclosure triangles edit the current entry's expanded set in place; Back/Forward keep it (D-07).
    @Test func expandAndCollapseEditTheCurrentEntry() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.expand(1)
        h.expand(9)
        #expect(h.current.expanded == [1, 9])
        h.collapse(1)
        #expect(h.current.expanded == [9])
        h.collapse(42)
        #expect(h.current.expanded == [9])
        h.open(Self.music)
        #expect(h.current.expanded.isEmpty)
        #expect(Self.moved(&h, .goBack))
        #expect(h.current.expanded == [9])
        #expect(Self.moved(&h, .goForward))
        #expect(h.current.expanded.isEmpty)
    }

    /// D-06: storages don't share history.
    @Test func historiesArePerStorage() {
        var phone = NavigationHistory(storage: 0x0001_0001)
        let sd = NavigationHistory(storage: 0x0002_0001)
        phone.open(Self.dcim)
        #expect(phone.canGoBack)
        #expect(!sd.canGoBack && sd.current.location.path.isEmpty)
        #expect(sd.current.location.storage == 0x0002_0001)
    }


    /// D-03 path bar: an ancestor is a new navigation with the folder you came from selected.
    @Test func goToAncestor() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        h.open(Self.camera)
        let backBefore = h.back.count
        let toDCIM = h.goTo(depth: 1)
        #expect(toDCIM)
        #expect(h.current.location.path == [Self.dcim])
        #expect(h.current.selected == [Self.camera.handle])
        #expect(h.back.count == backBefore + 1 && !h.canGoForward)

        h.open(Self.camera)
        #expect(Self.moved(&h, .goBack))
        #expect(h.canGoForward)
        let toRoot = h.goTo(depth: 0)
        #expect(toRoot)
        #expect(h.current.location.path.isEmpty)
        #expect(h.current.selected == [Self.dcim.handle])
        #expect(!h.canGoForward)
        #expect(Self.moved(&h, .goBack))
        #expect(h.current.location.path == [Self.dcim])
    }

    /// The current depth and out-of-range depths change nothing.
    @Test func goToInvalidDepthDoesNothing() {
        var h = NavigationHistory(storage: Self.key.storage)
        h.open(Self.dcim)
        h.open(Self.camera)
        let before = h
        let here = h.goTo(depth: 2), beyond = h.goTo(depth: 3), negative = h.goTo(depth: -1)
        #expect(!here && !beyond && !negative)
        #expect(h == before)
    }

    // MARK: - StatusLine (BRWS-05; D-11, D-30)

    static let free: UInt64 = 12_400_000_000
    static var available: String { ", \(EntryFormat.bytes(free)) available" }

    static func status(_ items: Int, _ selected: Int = 0, free: UInt64? = Self.free, loading: Int? = nil) -> String {
        StatusLine.text(itemCount: items, selectedCount: selected, freeSpace: free, loadingCount: loading)
    }

    /// Boundary and empty edges: singular only for 1; counts grouped like Finder.
    @Test func itemCounts() {
        #expect(Self.status(0) == "0 items" + Self.available)
        #expect(Self.status(1) == "1 item" + Self.available)
        #expect(Self.status(2) == "2 items" + Self.available)
        #expect(Self.status(1000) == "\(1000.formatted()) items" + Self.available)
    }

    /// Adjacency edge: selecting every row still reads "n of n".
    @Test func selectionCounts() {
        #expect(Self.status(120, 3) == "3 of 120 selected" + Self.available)
        #expect(Self.status(120, 120) == "120 of 120 selected" + Self.available)
    }

    /// D-11: the running count wins over everything while the folder loads.
    @Test func loadingShowsRunningCount() {
        #expect(Self.status(1200, loading: 1200) == "Loading… \(1200.formatted()) items")
        #expect(Self.status(5, 2, loading: 5) == "Loading… 5 items")
    }

    @Test func unknownFreeSpaceOmitsSuffix() {
        #expect(Self.status(120, free: nil) == "120 items")
        #expect(Self.status(120, 3, free: nil) == "3 of 120 selected")
    }

    /// Precision edge: the same string as the sidebar's free space.
    @Test func freeSpaceMatchesSidebar() {
        #expect(Self.status(0).hasSuffix("\(EntryFormat.bytes(12_400_000_000)) available"))
        #expect(EntryFormat.bytes(12_400_000_000).contains("12.4") || Locale.current.decimalSeparator != ".")
    }

    // MARK: Delete (FMGT-03, D-22, D-24)

    @Test func deleteConfirmationWording() {
        #expect(DeleteText.confirmation(names: ["a.jpg"])
                == AlertText(message: "Are you sure you want to delete “a.jpg”?",
                             detail: "This item will be deleted immediately. You can’t undo this action."))
        #expect(DeleteText.confirmation(names: ["a", "b", "c"])
                == AlertText(message: "Are you sure you want to delete the 3 selected items?",
                             detail: "These items will be deleted immediately. You can’t undo this action."))
    }

    @Test func deleteFailureWording() {
        let denied = MTPError.response(code: 0x200F, op: 0x100B)
        #expect(DeleteText.failures([("a.jpg", denied)])
                == AlertText(message: "“a.jpg” couldn’t be deleted.", detail: "MTP error 0x200F (Access Denied)"))
        #expect(DeleteText.failures([("a", denied), ("b", .response(code: 0x2002, op: 0x100B))])
                == AlertText(message: "2 items couldn’t be deleted.", detail: "a, b\nMTP error 0x200F (Access Denied)"))
    }

    static func item(_ id: UInt32, parent: UInt32) -> ObjectEntry {
        ObjectEntry(id: id, storageID: key.storage, parent: parent, format: 0x3000, name: "\(id)", size: 1, modified: nil)
    }

    /// A selected item inside a selected folder goes with the folder, at any depth; input order is kept.
    @Test func onlyTopLevelItemsAreDeleted() {
        let root: UInt32 = 0xFFFF_FFFF
        let dcim = Self.item(1, parent: root), inside = Self.item(9, parent: 1), img = Self.item(5, parent: root)
        let parents: [UInt32: UInt32] = [1: root, 9: 1, 5: root, 20: 1, 21: 20]
        #expect(DeletePlan.topLevel([dcim, inside, img], parentOf: { parents[$0] }).map(\.id) == [1, 5])
        let deep = Self.item(21, parent: 20)
        #expect(DeletePlan.topLevel([deep, img, dcim], parentOf: { parents[$0] }).map(\.id) == [5, 1])
        #expect(DeletePlan.topLevel([inside, img], parentOf: { parents[$0] }).map(\.id) == [9, 5])
    }

    @Test func parentComesFromTheCachedListing() {
        var cache = FolderCache()
        let dcim = FolderKey(storage: Self.key.storage, folder: 1)
        cache.begin(dcim)
        cache.append([Self.item(9, parent: 1)], to: dcim)
        #expect(cache.parent(of: 9) == 1)
        #expect(cache.parent(of: 42) == nil)
    }

    // MARK: - Events (BRWS-08)

    static let dcimKey = FolderKey(storage: key.storage, folder: 1)
    static let root = FolderKey(storage: key.storage, folder: 0xFFFF_FFFF)

    static func listed(_ entries: [ObjectEntry], in key: FolderKey, _ cache: inout FolderCache) {
        cache.begin(key)
        cache.append(entries, to: key)
        cache.finish(key)
    }

    @Test func removeObjectTombstonesAndIsIdempotent() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1), Self.item(10, parent: 1)], in: Self.dcimKey, &cache)
        let r1 = cache.removeObject(9)
        #expect(r1 == Self.dcimKey)
        #expect(cache[Self.dcimKey]?.map(\.id) == [10])
        #expect(cache.tombstones.contains(9))
        let after = cache
        let r2 = cache.removeObject(9)
        #expect(r2 == nil)
        #expect(cache == after)
    }

    /// BRWS-08 ordering edge: a batch read before the removal was handled can't bring the handle back.
    @Test func staleBatchCannotResurrect() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        cache.removeObject(9)
        cache.begin(Self.dcimKey)                                            // tombstones survive a re-list
        cache.append([Self.item(9, parent: 1), Self.item(11, parent: 1)], to: Self.dcimKey)
        #expect(cache[Self.dcimKey]?.map(\.id) == [11])
        let r3 = cache.upsert(Self.item(9, parent: 1))
        #expect(!r3)
        cache.reconcile(Self.dcimKey, handles: [9, 11], fresh: [Self.item(9, parent: 1)])
        #expect(cache[Self.dcimKey]?.map(\.id) == [11])
    }

    /// BRWS-08 adjacency edge: announced and listed leaves one row.
    @Test func upsertReplacesByHandle() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        let r4 = cache.upsert(Self.item(9, parent: 1))
        #expect(r4)
        let r5 = cache.upsert(Self.item(12, parent: 1))
        #expect(r5)
        #expect(cache[Self.dcimKey]?.map(\.id) == [9, 12])
    }

    @Test func upsertIntoUnlistedFolderChangesNothing() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        let before = cache
        let r6 = cache.upsert(Self.item(13, parent: 4))
        #expect(!r6)
        #expect(cache == before)
    }

    /// A move on the phone: out of the old folder, into the new one only when it is listed.
    @Test func upsertMovesBetweenFolders() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        Self.listed([Self.item(5, parent: 0xFFFF_FFFF)], in: Self.root, &cache)
        let r7 = cache.upsert(Self.item(9, parent: 0xFFFF_FFFF))
        #expect(r7)
        #expect(cache[Self.dcimKey]?.isEmpty == true)
        #expect(cache[Self.root]?.map(\.id) == [5, 9])
        let r9 = cache.upsert(Self.item(5, parent: 4))                    // to a folder never listed
        #expect(!r9)
        #expect(cache[Self.root]?.map(\.id) == [9])
    }

    @Test func removingAFolderDropsItsListing() {
        var cache = FolderCache()
        var folder = Self.item(1, parent: 0xFFFF_FFFF)
        folder.format = 0x3001
        Self.listed([folder], in: Self.root, &cache)
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        let r8 = cache.removeObject(1)
        #expect(r8 == Self.root)
        #expect(cache[Self.dcimKey] == nil && !cache.isComplete(Self.dcimKey))
    }

    @Test func forgetDropsExpansionEverywhere() {
        var history = NavigationHistory(storage: Self.key.storage)
        history.record(expanded: [1, 2])
        history.open(Crumb(handle: 3, name: "Music"))
        history.record(expanded: [1])
        history.forget(1)
        #expect(history.current.expanded.isEmpty)
        history.goBack()
        #expect(history.current.expanded == [2])
    }

    /// IN-03: a folder renamed on the phone renames its crumbs everywhere.
    @Test func renameUpdatesEveryCrumb() {
        var history = NavigationHistory(storage: Self.key.storage)
        history.open(Crumb(handle: 1, name: "DCIM"))
        history.open(Crumb(handle: 2, name: "Camera"))
        history.goBack()
        history.rename(2, to: "Photos")
        history.goForward()
        #expect(history.current.location.path.map(\.name) == ["DCIM", "Photos"])
    }

    /// WR-04: Back and Forward skip entries inside a removed folder.
    @Test func forgetDropsEntriesInsideTheFolder() {
        var history = NavigationHistory(storage: Self.key.storage)
        history.open(Crumb(handle: 1, name: "DCIM"))
        history.open(Crumb(handle: 2, name: "Camera"))
        history.goTo(depth: 0)                                            // back: root, DCIM, DCIM/Camera
        history.open(Crumb(handle: 3, name: "Music"))
        history.goBack()                                                  // forward: Music
        history.forget(1)
        #expect(history.back.map(\.location.path.count) == [0])
        #expect(history.forward.map { $0.location.path.map(\.handle) } == [[3]])
    }

    /// ⌘R: the fresh listing lands whole and complete; a handle removed meanwhile stays out.
    @Test func replaceIsCompleteAndHonoursTombstones() {
        var cache = FolderCache()
        Self.listed([Self.item(9, parent: 1)], in: Self.dcimKey, &cache)
        cache.removeObject(9)
        cache.replace(Self.dcimKey, entries: [Self.item(9, parent: 1), Self.item(14, parent: 1)])
        #expect(cache[Self.dcimKey]?.map(\.id) == [14])
        #expect(cache.isComplete(Self.dcimKey))
    }
}
