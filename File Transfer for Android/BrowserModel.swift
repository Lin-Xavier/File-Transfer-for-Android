import AppKit
import Foundation
import MTPKit
import Observation
import os

/// Navigation and listing for one connected session. The folder cache lives here on the MainActor, not in
/// DeviceSession, so listing batches (and later events) merge into one place in order (RESEARCH structure note).
@Observable
final class BrowserModel {
    /// What the file list renders. Equatable, so the representable skips identical re-renders. `generation`
    /// changes on every navigation; `restore` is the destination's saved selection and scroll, applied once.
    /// `children` holds the listed contents of every expanded folder (BRWS-04).
    struct ListSnapshot: Equatable {
        var key: FolderKey
        var entries: [ObjectEntry]
        var generation: Int
        var restore: HistoryEntry
        var expanded: Set<UInt32>
        var children: [UInt32: [ObjectEntry]]
        var isComplete: Bool
        var renameRequest: RenameRequest?
        var listRequest: ListRequest?
    }

    /// Asks the list to act on its selected rows: `.open` fetches the selected files and opens them (D-19);
    /// `.quickLook` toggles the Quick Look panel on them (PREV-01). The list does it because it owns the row order, the
    /// window for the big-file sheet and the panel; `id` makes each request happen once.
    struct ListRequest: Equatable {
        enum Kind: Equatable { case open, quickLook }
        var id: Int
        var kind: Kind
    }

    /// Asks the list to open a row's name field: File > Rename, the context menu, or a name the phone refused
    /// (`selectAll`, D-21). `id` makes each request happen once.
    struct RenameRequest: Equatable {
        var id: Int
        var handle: UInt32
        var text: String
        var selectAll: Bool
    }

    /// Asks the view to show a picker (Download to…'s folder, Upload…'s items); `id` makes each request happen once.
    struct PickerRequest: Equatable {
        /// `.download`: the items and each one's folder names from the storage root down to its own name; `.upload`:
        /// the phone folder to copy into, its name (nil at a storage root) and its path. The paths let a Retry find
        /// them again after a replug (D-14).
        enum Kind: Equatable {
            case download([ObjectEntry], paths: [[String]])
            case upload(FolderKey, name: String?, path: [String])
        }
        var id: Int
        var kind: Kind
    }

    /// The storage being browsed. Every storage keeps its own history for the session (D-06, D-31).
    private(set) var storage: UInt32
    private var histories: [UInt32: NavigationHistory]
    private(set) var cache = FolderCache()
    /// A listing the phone refused (an MTP error response); the session is still usable, so Retry re-lists.
    private(set) var failure: MTPError?
    /// Selected rows by handle, as the list reports them.
    private(set) var selection: Set<UInt32> = []
    private(set) var generation = 0
    private var restore: HistoryEntry
    /// A change to the phone (rename, new folder) is in flight; another can't start until it is done.
    private(set) var isBusy = false
    /// The change whose phone commands are running, as the unplug alert names it ("Deleting 3 items", D-35). Left set
    /// when the phone goes away mid-change, so AppModel's `disconnect()` can report it; listings never set it.
    private(set) var pendingOperation: String?
    /// The list's rename field is open (set by the list's field editor). Menu shortcuts are off meanwhile (Pitfall 2).
    var isRenaming = false
    private(set) var renameRequest: RenameRequest?
    private(set) var listRequest: ListRequest?
    /// A Finder-style alert for a rejected name or a change the phone refused (D-21, D-25..D-27); the view clears it.
    var alert: AlertText?

    private var history: NavigationHistory { histories[storage] ?? NavigationHistory(storage: storage) }
    var location: Location { history.current.location }
    /// The open folder's entries as every view reads them (the list, the status count, the empty-folder text). The
    /// app's own upload temps are hidden here and in `snapshot` (D-23) but kept in the cache, so a temp the phone
    /// reports when it closes the file (ObjectInfoChanged, RESEARCH Pitfall 10) never shows. Only that exact pattern:
    /// ".nomedia" and every other dotfile still show.
    var currentEntries: [ObjectEntry] { (cache[location.key] ?? []).filter { !Transfer.isUploadTemp($0.name) } }
    var isLoading: Bool { !cache.isComplete(location.key) && failure == nil }
    /// Entries received so far while the opened folder fills; nil once it is complete (D-11).
    var loadingCount: Int? { isLoading ? currentEntries.count : nil }
    /// Expanded folders in the current folder, at any depth (D-07).
    var expanded: Set<UInt32> { history.current.expanded }
    var snapshot: ListSnapshot {
        var children: [UInt32: [ObjectEntry]] = [:]
        for handle in expanded {
            children[handle] = cache[FolderKey(storage: storage, folder: handle)]?.filter { !Transfer.isUploadTemp($0.name) }
        }
        return ListSnapshot(key: location.key, entries: currentEntries, generation: generation, restore: restore,
                            expanded: expanded, children: children, isComplete: cache.isComplete(location.key),
                            renameRequest: renameRequest, listRequest: listRequest)
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { history.canGoUp }
    /// File > Open (⌘↓): exactly one selected folder (P2 D-01), or selected rows that are all files (D-19).
    var canOpenSelection: Bool {
        if selectedFolder != nil { return true }
        let all = visibleEntries
        return !selection.isEmpty && selection.allSatisfy { all[$0].map { !$0.isFolder } ?? false }
    }
    /// A copy is queued or running. New Folder, Rename and Delete wait for it so no job's folder changes under it;
    /// browsing and ⌘R stay open, which is why this is not folded into `isBusy` (D-22). Reads the observable queue.
    var isCopying: Bool { transfersActive() }
    /// File > Rename: exactly one selected row at any depth (D-09), and no change or edit already running.
    var canRename: Bool { selectedEntry != nil && !isBusy && !isRenaming && !isCopying }
    /// File > New Folder: only once the opened folder is fully listed, so the generated name is checked against every
    /// sibling on the phone (FMGT-01), and never while a change or edit is running (T-02-15).
    var canNewFolder: Bool { cache.isComplete(location.key) && failure == nil && !isBusy && !isRenaming && !isCopying }
    /// File > Delete (⌘⌫): any selected rows at any depth (D-09), and no change or edit already running.
    var canDelete: Bool { !selection.isEmpty && !isBusy && !isRenaming && !isCopying }
    /// An in-app drag that moves rows on the phone (FMGT-04): never while a change, an edit or any copy job runs, so no
    /// job's folder moves under it (D-14). Drags to and from Finder don't ask this.
    var canMove: Bool { !isBusy && !isRenaming && !isCopying }
    /// Download to…: any selected rows at any depth, not while a name is being edited (D-20) or a change runs, so a copy
    /// never starts on items a delete is removing (D-22 both ways, IN-05).
    var canDownload: Bool { !selection.isEmpty && !isRenaming && !isBusy }
    /// Upload…: into the opened folder whatever is selected (D-18), unless its listing failed, a name is being edited
    /// or a change runs (IN-05).
    var canUpload: Bool { failure == nil && !isRenaming && !isBusy }
    /// A folder picker waiting for the view to present it (the model holds no AppKit).
    private(set) var pickerRequest: PickerRequest?
    /// Finder's permanent-delete question, waiting for the view to ask it as a sheet (D-22). The model holds no AppKit.
    private(set) var deleteConfirmation: AlertText?
    @ObservationIgnored private var deleteTargets: [ObjectEntry] = []

    /// A running delete, shown as a blocking sheet (D-23). Stop is honoured between items, never mid-command.
    struct DeleteProgress: Equatable {
        var currentName: String
        var verb = "Deleting"
        var stopRequested = false
        /// A whole line that replaces verb + name (P-01).
        var title: String? = nil
    }
    private(set) var deleteProgress: DeleteProgress?
    /// The move whose plan is being checked; its 0.5 s timer shows the sheet only while this still matches (T-06-17).
    @ObservationIgnored private var checkingMove: Int?
    @ObservationIgnored private var moveCount = 0

    /// A move's name clash, waiting for the view to ask it with `ClashSheet` on the main window (D-12); `id` makes each
    /// question happen once.
    struct MoveQuestion: Equatable {
        var id: Int
        var clash: Clash
    }
    private(set) var moveQuestion: MoveQuestion?
    /// The move being asked about: its items, destination, the answers so far and the clashes still to ask.
    @ObservationIgnored private var pendingMove: (targets: [ObjectEntry], key: FolderKey, answers: ClashAnswers, clashes: [Clash])?
    @ObservationIgnored private var moveQuestionCount = 0

    /// The session every handle here belongs to; a picker checks it is still current before copying (CR-02).
    @ObservationIgnored let session: DeviceSession
    @ObservationIgnored private let onSessionLost: (any Error) -> Void
    /// Re-reads every storage's free space (D-17).
    @ObservationIgnored private let refreshStorages: () -> Void
    /// Whether the transfer queue has jobs (D-22).
    @ObservationIgnored private let transfersActive: () -> Bool
    /// One running listing per folder: the current one and any expanded ones still filling.
    @ObservationIgnored private var listTasks: [FolderKey: Task<Void, Never>] = [:]
    /// The pending coalesced free-space read after events (D-17).
    @ObservationIgnored private var freeSpaceTask: Task<Void, Never>?
    /// Kept out of observation: it changes on every scroll tick and is only saved into history on navigation.
    @ObservationIgnored private var scrollY: Double = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "browser")

    /// `onSessionLost`: any non-response error. The session already dropped its transport (CR-01).
    init(session: DeviceSession, storage: UInt32, onSessionLost: @escaping (any Error) -> Void,
         refreshStorages: @escaping () -> Void, transfersActive: @escaping () -> Bool) {
        self.session = session
        self.transfersActive = transfersActive
        self.onSessionLost = onSessionLost
        self.refreshStorages = refreshStorages
        self.storage = storage
        let history = NavigationHistory(storage: storage)
        histories = [storage: history]
        restore = history.current
        load(location.key)
    }

    /// Returns to that storage's remembered folder, with its selection and scroll (D-06, D-31).
    func show(storage: UInt32) {
        guard storage != self.storage else { return }
        saveCurrent()
        self.storage = storage
        if histories[storage] == nil { histories[storage] = NavigationHistory(storage: storage) }
        arrive()
    }

    /// Opens a folder row (D-01), including one inside expanded folders. Files open through the list (`listRequest`).
    func open(_ entry: ObjectEntry) {
        guard entry.isFolder, let crumbs = crumbs(to: entry) else { return }
        navigate { $0.open(crumbs); return true }
    }

    /// Where a drag's first spring-load left from (D-07), put back unless the drag drops here.
    @ObservationIgnored private var springSaved: (storage: UInt32, history: NavigationHistory)?

    /// A drag hovered a folder row: a normal, Back-able navigation into it (D-07). The first one of a drag saves where
    /// the list was, with its selection and scroll.
    func springOpen(_ entry: ObjectEntry) {
        if springSaved == nil {
            saveCurrent()
            springSaved = (storage, history)
        }
        open(entry)
    }

    /// A drag ended or left the list. Dropped here: the list stays in the folder dropped into. Otherwise it springs back
    /// to where the drag started. Idempotent, so every drag ending may call it.
    func endSpring(dropped: Bool) {
        guard let saved = springSaved else { return }
        springSaved = nil
        guard !dropped else { return }
        histories[saved.storage] = saved.history
        if saved.storage == storage { arrive() }
    }

    /// The selected files at any depth; folders never preview.
    private var selectedFiles: [ObjectEntry] {
        let all = visibleEntries
        return selection.compactMap { all[$0] }.filter { !$0.isFolder }
    }
    /// File > Quick Look (⌘Y): at least one selected file.
    var canQuickLook: Bool { !selectedFiles.isEmpty }
    /// Finder's title: “Quick Look “X”” for one file, “Quick Look N Items” for several.
    var quickLookTitle: String {
        let files = selectedFiles
        switch files.count {
        case 0: return "Quick Look"
        case 1: return "Quick Look “\(files[0].name)”"
        default: return "Quick Look \(files.count.formatted()) Items"
        }
    }

    /// File > Quick Look: the list toggles the panel on the selected files.
    func quickLook() {
        guard canQuickLook else { return }
        listRequest = ListRequest(id: (listRequest?.id ?? 0) + 1, kind: .quickLook)
    }

    /// File > Open: one folder navigates into it; files go to the list, which fetches and opens them (D-19).
    func openSelection() {
        if let folder = selectedFolder {
            open(folder)
        } else if canOpenSelection {
            listRequest = ListRequest(id: (listRequest?.id ?? 0) + 1, kind: .open)
        }
    }

    func back() { navigate { $0.goBack() } }
    func forward() { navigate { $0.goForward() } }
    func up() { navigate { $0.goUp() } }
    /// Path bar click (D-03): 0 is the storage root.
    func goTo(depth: Int) { navigate { $0.goTo(depth: depth) } }

    /// Sidebar Go to Root (D-32): switches storage when needed, then a normal navigation to its root.
    func goToRoot(storage: UInt32) {
        show(storage: storage)
        goTo(depth: 0)
    }

    /// A disclosure triangle opened: remember it and list the folder through the same batched loader (BRWS-04).
    func expand(_ handle: UInt32) {
        histories[storage]?.expand(handle)
        load(FolderKey(storage: storage, folder: handle))
    }

    /// Folders expanded inside it stay recorded, so expanding it again restores them, as in Finder.
    func collapse(_ handle: UInt32) {
        histories[storage]?.collapse(handle)
        cancelListings()
    }

    func selectionChanged(_ handles: Set<UInt32>) {
        if handles != selection { selection = handles }
    }

    /// The list's scroll offset from its top; saved into history when you navigate away (D-07).
    func scrollChanged(_ y: Double) { scrollY = y }

    /// View > Refresh (⌘R, D-16): re-reads the opened folder and every expanded folder from the phone, keeping
    /// selection and expansion, then free space (D-17). A listed folder keeps showing until its fresh listing replaces
    /// it; one still listing is already reading the phone. Nothing runs on a timer (D-14).
    func refresh() {
        if failure != nil { reload() } else { refetch(location.key) }
        for handle in expanded { refetch(FolderKey(storage: storage, folder: handle)) }
        refreshStorages()
    }

    /// A storage that left the list came back (D-09): its handles may have changed, so its listings and history are
    /// dropped and it opens at its root.
    func storageReturned(_ storage: UInt32) {
        for key in Array(cache.folders.keys) where key.storage == storage { cancel(key); cache.remove(key) }
        histories[storage] = NavigationHistory(storage: storage)
        if storage == self.storage { arrive() } else { show(storage: storage) }
    }

    /// The storage row's Refresh (D-32): this storage as ⌘R; another one forgets its listings, re-read when shown.
    func refresh(storage: UInt32) {
        guard storage != self.storage else { return refresh() }
        for key in Array(cache.folders.keys) where key.storage == storage { cancel(key); cache.remove(key) }
        refreshStorages()
    }

    private func refetch(_ key: FolderKey) {
        guard cache.isComplete(key) else { return load(key) }      // running or dropped: a normal listing
        listTasks.removeValue(forKey: key)?.cancel()
        load(key, replacing: true)
    }

    /// D-36: the same phone came back, so reopen the folder it was in, found by name (handles change across sessions)
    /// through the walk Retry uses (`Transfer.find`); nothing opens until the whole path is found. A missing folder
    /// leaves the list at the storage root. The folder opens with fresh history (no Back) and a fresh cache. The user
    /// navigating meanwhile wins.
    func restore(names: [String]) async {
        guard !names.isEmpty else { return }
        let storage = storage
        let crumbs: [Crumb]
        do {
            guard let path = try await Transfer.find(names, storage: storage, session: session),
                  path.allSatisfy(\.isFolder) else { return }          // gone: stay at the root
            crumbs = path.map { Crumb(handle: $0.id, name: $0.name) }
        } catch is CancellationError {
            return
        } catch let error as MTPError where error.isResponse {
            log.error("reopen failed: \(error.detail, privacy: .public)")
            return
        } catch {
            return onSessionLost(error)
        }
        guard !Task.isCancelled, storage == self.storage, location.path.isEmpty, !canGoBack else { return }
        histories[storage] = NavigationHistory(storage: storage, path: crumbs)
        arrive()
    }

    func reload() {
        cancel(location.key)
        cache.remove(location.key)
        failure = nil
        load(location.key)
    }

    func close() {
        pendingMove = nil
        moveQuestion = nil                              // RootView takes a move's clash sheet down
        for key in Array(listTasks.keys) { cancel(key) }
        freeSpaceTask?.cancel()
    }

    // MARK: - Changes on the phone (BRWS-08)

    /// One event from the session, forwarded by AppModel, which owns the stream (the browser never iterates it).
    /// Events run one at a time on the MainActor, so cache changes never race listings.
    func handle(_ event: MTPEvent) async {
        do {
            switch event {
            case .objectAdded(let h):
                // D-13: no highlight; selection and scroll stay, as rows are reused by handle.
                if let entry = try await session.entry(h) { cache.upsert(entry) }
            case .objectInfoChanged(let h):
                // A rename or a move on the phone; gone by now counts as removed.
                if let entry = try await session.entry(h) {
                    cache.upsert(entry)
                    if entry.isFolder { for s in Array(histories.keys) { histories[s]?.rename(h, to: entry.name) } }
                } else {
                    removed(h)
                }
            case .objectRemoved(let h):
                removed(h)
            case .storeAdded, .storeRemoved:
                refreshStorages()
                return
            case .storageInfoChanged:
                break
            case .other:
                return
            }
            scheduleFreeSpaceRefresh()
        } catch let error as MTPError where error.isResponse {
            log.error("event read-back failed: \(error.detail, privacy: .public)")
        } catch {
            onSessionLost(error)
        }
    }

    /// Free space after events, at most one GetStorageInfo round per 500 ms however many arrive (D-17, T-02-21).
    func scheduleFreeSpaceRefresh() {
        guard freeSpaceTask == nil else { return }
        freeSpaceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            freeSpaceTask = nil
            refreshStorages()
        }
    }

    /// An object removed on the phone or deleted here. A folder takes its listings, expansion and the history entries
    /// inside it with it; if it is the opened folder or one of its ancestors, the list first moves to the nearest
    /// surviving ancestor, as Finder does (Pitfall 7, WR-04).
    private func removed(_ h: UInt32) {
        if let depth = location.path.firstIndex(where: { $0.handle == h }) { goTo(depth: depth) }
        for key in cache.folders.keys where key.folder == h { forget(h, storage: key.storage) }
        cache.removeObject(h)
        for s in Array(histories.keys) { histories[s]?.forget(h) }
        if selection.contains(h) { selection.remove(h) }
    }

    // MARK: - Changes to the phone

    /// File > Rename and the context menu: opens the selected row's name field with the basename selected (D-20).
    func beginRename() {
        guard canRename, let entry = selectedEntry else { return }
        requestRename(entry.id, text: entry.name, selectAll: false)
    }

    /// The name field is ending with `text`. Returns false to keep it open: a name NameRules rejects never reaches
    /// the phone (D-21, T-02-09, T-02-10). An accepted name is sent and the field closes.
    func commitRename(handle: UInt32, in key: FolderKey, text: String) -> Bool {
        guard let siblings = cache[key], let entry = siblings.first(where: { $0.id == handle }) else { return true }
        let verdict = NameRules.validate(text, current: entry.name, siblings: siblings.map(\.name))
        switch verdict {
        case .unchanged:
            return true
        case .ok:
            rename(handle, in: key, to: text)
            return true
        default:
            alert = NameRules.alert(for: verdict, name: text)
            return false
        }
    }

    /// Renames `handle` in folder `key`, then re-reads that folder from the phone whether the phone accepted the
    /// name or not, so the list always shows the phone's real name (D-15), and re-reads free space (D-17).
    /// A refusal shows Finder's alert and reopens the field with the typed name selected (D-21, D-25..D-27).
    private func rename(_ handle: UInt32, in key: FolderKey, to name: String) {
        isBusy = true
        pendingOperation = "Renaming “\(cache[key]?.first { $0.id == handle }?.name ?? name)”"
        let session = session
        Task {
            var refusal: MTPError?
            do {
                try await session.rename(handle, to: name)
                pendingOperation = nil
            } catch let error as MTPError where error.isResponse {
                pendingOperation = nil
                log.error("rename refused: \(error.detail, privacy: .public) name \(name, privacy: .private)")
                refusal = error
            } catch {
                isBusy = false
                onSessionLost(error)
                return
            }
            await relist(key, touched: [handle])
            refreshStorages()
            isBusy = false                              // before the reopen: the field won't open while busy
            if let refusal {
                alert = OperationAlert.text(for: refusal, name: name)
                requestRename(handle, text: name, selectAll: true)
            }
        }
    }

    /// Creates the first free "untitled folder" in the opened folder, whatever is selected (D-19), reads its real
    /// name back from the phone (D-15), then selects it and opens its name field with all of it selected.
    func newFolder() {
        guard canNewFolder else { return }
        let key = location.key
        let name = NameRules.uniqueName(among: currentEntries.map(\.name))
        isBusy = true
        pendingOperation = "Creating a new folder"
        let session = session
        Task {
            let handle: UInt32
            do {
                handle = try await session.makeFolder(storage: key.storage, parent: key.folder, name: name)
                pendingOperation = nil
            } catch let error as MTPError where error.isResponse {
                pendingOperation = nil
                log.error("new folder refused: \(error.detail, privacy: .public)")
                await relist(key, touched: [])          // a clash means the list missed a sibling
                isBusy = false
                alert = OperationAlert.text(for: error, name: name)
                return
            } catch {
                isBusy = false
                onSessionLost(error)
                return
            }
            await relist(key, touched: [handle])
            refreshStorages()
            isBusy = false                              // before the request: the field won't open while busy
            if key == location.key, let made = cache[key]?.first(where: { $0.id == handle }) {
                requestRename(handle, text: made.name, selectAll: true)
            }
        }
    }

    /// File > Delete and the context menu: asks Finder's question about the selected rows (D-22). Busy from here on,
    /// so nothing else changes the phone while the question or the progress sheet is up.
    func confirmDelete() {
        guard canDelete else { return }
        let all = visibleEntries
        let selected = selection.compactMap { all[$0] }.sorted(by: .name, ascending: true)
        guard !selected.isEmpty else { return }
        // An item inside a selected folder goes with the folder; sending it too would only fail (0x2009).
        deleteTargets = DeletePlan.topLevel(selected, parentOf: cache.parent(of:))
        isBusy = true
        deleteConfirmation = DeleteText.confirmation(names: selected.map(\.name))
    }

    /// Download to…: the selected rows, an item inside a selected folder dropped (the folder brings it, D-21).
    func requestDownload() {
        guard canDownload else { return }
        let all = visibleEntries
        let selected = selection.compactMap { all[$0] }.sorted(by: .name, ascending: true)
        guard !selected.isEmpty else { return }
        let targets = DeletePlan.topLevel(selected, parentOf: cache.parent(of:))
        let here = location.path.map(\.name)
        let paths = targets.map { here + (crumbs(to: $0)?.map(\.name) ?? [$0.name]) }
        pickerRequest = PickerRequest(id: (pickerRequest?.id ?? 0) + 1, kind: .download(targets, paths: paths))
    }

    /// Upload…: the opened folder, captured now, is the destination whatever is selected (D-18).
    func requestUpload() {
        guard canUpload else { return }
        pickerRequest = PickerRequest(id: (pickerRequest?.id ?? 0) + 1,
                                      kind: .upload(location.key, name: location.path.last?.name,
                                                    path: location.path.map(\.name)))
    }

    /// Where a drop of Mac items lands (D-06): nil is the opened folder, a folder row at any depth is that folder. The
    /// name labels the job (nil at a storage root); the path lets a Retry find it after a replug (P4 D-14).
    func dropTarget(_ folder: ObjectEntry?) -> (key: FolderKey, name: String?, path: [String]) {
        let here = location.path.map(\.name)
        guard let folder else { return (location.key, location.path.last?.name, here) }
        return (FolderKey(storage: storage, folder: folder.id), folder.name,
                here + (crumbs(to: folder)?.map(\.name) ?? [folder.name]))
    }

    /// An upload job ended: every phone folder it added to is read back from the phone, then free space (D-03, D-17).
    /// `relist` skips folders that aren't listed. The objects it `created` are re-read even if cached: a listing during
    /// the copy may hold a big upload at 0 bytes or part-way (WR-02).
    func uploaded(into keys: Set<FolderKey>, created: Set<UInt32>) {
        Task {
            for key in keys { await relist(key, touched: created) }
            refreshStorages()
        }
    }

    func cancelDelete() {
        deleteConfirmation = nil
        deleteTargets = []
        isBusy = false
    }

    /// The progress sheet's Stop: the item being deleted finishes first (a folder is one command) (D-23).
    func stopDelete() {
        deleteProgress?.stopRequested = true
    }

    /// The user confirmed: one DeleteObject per top-level item, by handle only (a folder goes with everything in it).
    /// Refusals don't stop the rest (D-24); afterwards every affected folder is re-read from the phone (D-15, D-24),
    /// free space too (D-17), and one alert lists what failed.
    func performDelete() {
        let targets = deleteTargets
        deleteConfirmation = nil
        deleteTargets = []
        guard !targets.isEmpty else { isBusy = false; return }
        let storage = storage
        let session = session
        deleteProgress = DeleteProgress(currentName: targets[0].name)
        pendingOperation = targets.count == 1 ? "Deleting “\(targets[0].name)”" : "Deleting \(targets.count) items"
        Task {
            var failed: [(entry: ObjectEntry, error: MTPError)] = []
            var deleted: [ObjectEntry] = []
            for entry in targets {
                deleteProgress?.currentName = entry.name
                do {
                    try await session.delete(entry.id)
                    deleted.append(entry)
                } catch let error as MTPError where error.isInvalidObjectHandle {
                    deleted.append(entry)               // already gone on the phone: done, never retried by name
                } catch let error as MTPError where error.isResponse {
                    log.error("delete refused: \(error.detail, privacy: .public)")
                    failed.append((entry, error))
                } catch {
                    deleteProgress = nil
                    isBusy = false
                    onSessionLost(error)
                    return
                }
                if deleteProgress?.stopRequested == true { break }
            }
            pendingOperation = nil
            deleteProgress = nil
            for entry in deleted where entry.isFolder { removed(entry.id) }
            // The parents, plus any folder that failed part-way (0x2012 Partial Deletion) if it is listed.
            var affected = Set(targets.map { FolderKey(storage: storage, folder: $0.parent) })
            for (entry, _) in failed where entry.isFolder { affected.insert(FolderKey(storage: storage, folder: entry.id)) }
            for key in affected { await relist(key, touched: []) }
            refreshStorages()
            isBusy = false
            if !failed.isEmpty { alert = DeleteText.failures(failed.map { ($0.entry.name, $0.error) }) }
        }
    }

    /// An in-app drop of `entries` (by value, taken when the drag began) onto folder `key`: one MoveObject per top-level
    /// item in drop order, with no confirmation and no undo (D-11). Items already there are left alone; a folder dropped
    /// into itself is refused before anything is sent (05-MOVE-PROBE) and listed in the end alert; a name clash asks
    /// Finder's sheet first (D-12). Busy from here until the move ends, questions included.
    func move(_ entries: [ObjectEntry], into key: FolderKey) {
        guard canMove, !entries.isEmpty else { return }
        let targets = DeletePlan.topLevel(entries, parentOf: cache.parent(of:))
        isBusy = true
        pendingOperation = targets.count == 1 ? "Moving “\(targets[0].name)”" : "Moving \(targets.count) items"
        moveCount += 1
        let token = moveCount
        checkingMove = token
        // D-11: a check still running after 0.5 s gets the sheet; a fast move never flashes it.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard checkingMove == token else { return }
            deleteProgress = DeleteProgress(currentName: targets[0].name, verb: "Moving",
                                            title: TransferText.preparingMove(names: targets.map(\.name)))
        }
        Task { await planMove(targets, into: key, answers: ClashAnswers(), unanswered: .ask) }
    }

    /// The clash sheet's reply. Stop (Escape) or a sheet taken down moves nothing. An answer is recorded, with Apply to
    /// All for the clashes it covers; after the last question the move is planned again against a fresh listing, a
    /// clash nobody was asked about (the destination changed meanwhile) kept both, as the copy queue's attempt does.
    func answerMove(_ reply: ClashSheet.Reply) {
        guard var pending = pendingMove, let question = moveQuestion else { return }
        moveQuestion = nil
        guard case .answer(let answer, let applyToAll) = reply else {
            pendingMove = nil
            pendingOperation = nil
            isBusy = false
            return
        }
        pending.answers.byItem[question.clash.id] = answer
        if applyToAll { pending.answers.all = answer }
        pending.clashes.removeAll { $0.id == question.clash.id || pending.answers.answer(for: $0) != nil }
        if let next = pending.clashes.first {
            pendingMove = pending
            ask(next)
            return
        }
        pendingMove = nil
        Task { await planMove(pending.targets, into: pending.key, answers: pending.answers, unanswered: .keepBoth) }
    }

    private func ask(_ clash: Clash) {
        moveQuestionCount += 1
        moveQuestion = MoveQuestion(id: moveQuestionCount, clash: clash)
    }

    private func planMove(_ targets: [ObjectEntry], into key: FolderKey, answers: ClashAnswers, unanswered: Unanswered) async {
        let plan: MovePlan
        do {
            plan = try await Move.plan(targets, storage: key.storage, into: key.folder, answers: answers,
                                       unanswered: unanswered, session: session)
        } catch let error as MTPError where error.isResponse {
            _ = endMoveCheck()
            log.error("move plan failed: \(error.detail, privacy: .public)")
            pendingOperation = nil
            isBusy = false
            alert = OperationAlert.text(for: error, name: targets[0].name)
            return
        } catch {
            _ = endMoveCheck()
            isBusy = false
            onSessionLost(error)
            return
        }
        // T-06-16: Stop while checking sends nothing; the sheet comes down so a clash question can't stack on it,
        // and `run` puts it back with no suspension in between.
        if endMoveCheck() {
            pendingOperation = nil
            isBusy = false
            return
        }
        if let first = plan.clashes.first {
            pendingMove = (targets, key, answers, plan.clashes)
            ask(first)
            return
        }
        await run(plan.steps, into: key, refused: plan.refused.map { ($0.name, MovePlan.ownSubtreeReason) })
    }

    /// Ends a move's check: takes its sheet down and says whether Stop was pressed during it.
    private func endMoveCheck() -> Bool {
        let stopped = deleteProgress?.stopRequested == true
        checkingMove = nil
        deleteProgress = nil
        return stopped
    }

    /// Runs a move's steps under the delete-style progress sheet, Stop honoured between items (P2 D-23). Afterwards the
    /// source folders and the destination are read back from the phone, the moved handles re-read with their new
    /// parent (D-15), and one alert lists what wasn't moved (D-24..D-27).
    private func run(_ steps: [MovePlan.Step], into key: FolderKey, refused: [(name: String, reason: String)]) async {
        let session = session
        var failed: [(name: String, error: MTPError)] = []
        var moved: [ObjectEntry] = []
        if let first = steps.first { deleteProgress = DeleteProgress(currentName: first.entry.name, verb: "Moving") }
        for step in steps {
            deleteProgress?.currentName = step.entry.name
            do {
                try await Move.perform(step, storage: key.storage, into: key.folder, session: session)
                moved.append(step.entry)
            } catch let error as MTPError where error.isResponse {
                log.error("move refused: \(error.detail, privacy: .public)")
                failed.append((step.entry.name, error))
            } catch {
                deleteProgress = nil
                isBusy = false
                onSessionLost(error)
                return
            }
            if deleteProgress?.stopRequested == true { break }
        }
        pendingOperation = nil
        deleteProgress = nil
        for entry in moved where entry.isFolder { self.moved(entry.id) }
        // Sources first, so a moved handle has left its old folder before the destination reads it back.
        let sources = Set(steps.map { FolderKey(storage: key.storage, folder: $0.entry.parent) }).subtracting([key])
        for source in sources { await relist(source, touched: []) }
        await relist(key, touched: Set(moved.map(\.id)))
        isBusy = false
        if !failed.isEmpty || !refused.isEmpty { alert = DeleteText.failures(failed, refused: refused, verb: "moved") }
    }

    /// A folder moved here keeps its handle (Pitfall 13), so unlike `removed(_:)` nothing is tombstoned: only its
    /// listings and the history entries through its old place go; the re-lists show it in its new one.
    private func moved(_ h: UInt32) {
        for key in cache.folders.keys where key.folder == h { forget(h, storage: key.storage) }
        for s in Array(histories.keys) { histories[s]?.forget(h) }
        if selection.contains(h) { selection.remove(h) }
    }

    /// A deleted folder: drops its listing and expansion, and those of every folder listed inside it.
    private func forget(_ folder: UInt32, storage: UInt32) {
        let key = FolderKey(storage: storage, folder: folder)
        for child in cache[key] ?? [] where child.isFolder { forget(child.id, storage: storage) }
        cancel(key)
        cache.remove(key)
        histories[storage]?.collapse(folder)
    }

    private func requestRename(_ handle: UInt32, text: String, selectAll: Bool) {
        renameRequest = RenameRequest(id: (renameRequest?.id ?? 0) + 1, handle: handle, text: text, selectAll: selectAll)
    }

    /// Re-reads a folder after a change (RESEARCH Pattern 4): one GetObjectHandles, then entries only for handles
    /// not cached yet plus the ones the change touched; gone handles drop. Every value comes from the phone, at a
    /// cost of O(changes). A folder still listing is listed again instead, which reads everything back anyway.
    private func relist(_ key: FolderKey, touched: Set<UInt32>) async {
        guard cache.isComplete(key) else {
            if isLive(key) { cancel(key); load(key) }     // a non-live, incomplete folder was already dropped
            return
        }
        do {
            let before = Set((cache[key] ?? []).map(\.id))
            let hs = try await session.handles(storage: key.storage, parent: key.folder)
            let cached = Set((cache[key] ?? []).map(\.id))
            let need = hs.filter { !cached.contains($0) || touched.contains($0) }
            var fresh: [ObjectEntry] = []
            for i in stride(from: 0, to: need.count, by: Listing.batchSize) {
                fresh += try await session.entries(Array(need[i..<min(i + Listing.batchSize, need.count)]), parent: key.folder)
            }
            // Dropped or re-listing meanwhile (reload, navigation): that listing reads it all back instead.
            guard cache.isComplete(key) else { return }
            cache.reconcile(key, handles: hs, fresh: fresh, cachedBefore: before)
        } catch let error as MTPError where error.isResponse {
            log.error("re-list failed: \(error.detail, privacy: .public)")
        } catch {
            onSessionLost(error)
        }
    }

    // MARK: - Navigation

    private var selectedFolder: ObjectEntry? { selectedEntry.flatMap { $0.isFolder ? $0 : nil } }

    /// The one selected row, at any depth.
    private var selectedEntry: ObjectEntry? {
        guard selection.count == 1, let handle = selection.first else { return nil }
        return visibleEntries[handle]
    }

    /// Every row the list can show: the current folder plus the contents of its expanded folders.
    private var visibleEntries: [UInt32: ObjectEntry] {
        var all: [UInt32: ObjectEntry] = [:]
        for entry in currentEntries { all[entry.id] = entry }
        for list in snapshot.children.values { for entry in list { all[entry.id] = entry } }
        return all
    }

    /// The path from the current folder down to `entry`, through the expanded folders that contain it.
    private func crumbs(to entry: ObjectEntry) -> [Crumb]? {
        let all = visibleEntries
        var parentOf: [UInt32: UInt32] = [:]
        for (folder, list) in snapshot.children { for child in list { parentOf[child.id] = folder } }
        let top = Set(currentEntries.map(\.id))
        var path = [Crumb(handle: entry.id, name: entry.name)]
        var handle = entry.id
        while !top.contains(handle) {
            guard let parent = parentOf[handle], let folder = all[parent], path.count <= all.count else { return nil }
            path.insert(Crumb(handle: folder.id, name: folder.name), at: 0)
            handle = parent
        }
        return path
    }

    /// Records the folder being left, applies `change` to this storage's history, then shows the destination.
    private func navigate(_ change: (inout NavigationHistory) -> Bool) {
        saveCurrent()
        var history = history
        guard change(&history) else { return }
        histories[storage] = history
        arrive()
    }

    private func saveCurrent() {
        histories[storage]?.record(selected: selection, scrollY: scrollY)
    }

    /// Shows the current history entry: its saved selection and scroll go to the list once. Listings no longer
    /// shown are cancelled (BRWS-06); the folder and every expanded folder not yet complete are listed, so a
    /// restored expansion whose listing was cancelled fills in again (D-07). Cached folders are instant (D-15).
    private func arrive() {
        let entry = history.current
        restore = entry
        selection = entry.selected
        scrollY = entry.scrollY
        failure = nil
        generation += 1
        cancelListings()
        load(location.key)
        for handle in entry.expanded {
            let key = FolderKey(storage: storage, folder: handle)
            if !cache.isComplete(key) { load(key) }
        }
    }

    // MARK: - Listing

    /// A listing still worth finishing: the current folder, or a folder expanded in it.
    private func isLive(_ key: FolderKey) -> Bool {
        key == location.key || (key.storage == storage && expanded.contains(key.folder))
    }

    /// Stops every listing that is no longer shown (T-02-05: no unbounded MTP traffic after you leave).
    private func cancelListings() {
        for key in Array(listTasks.keys) where !isLive(key) { cancel(key) }
    }

    /// Stops a listing between batches. Its half-filled folder is dropped so it re-lists next time (BRWS-06).
    private func cancel(_ key: FolderKey) {
        listTasks.removeValue(forKey: key)?.cancel()
        if !cache.isComplete(key) { cache.remove(key) }
    }

    /// Lists `key` in `Listing.batchSize` batches; rows show as each batch lands (D-10). A complete or already
    /// running folder is left alone (D-15). `replacing` (⌘R): the cached rows stay until the whole fresh listing
    /// replaces them in one step (D-16).
    private func load(_ key: FolderKey, replacing: Bool = false) {
        guard listTasks[key] == nil, replacing || !cache.isComplete(key) else { return }
        if !replacing { cache.begin(key) }
        let before = Set((cache[key] ?? []).map(\.id))
        let session = session
        listTasks[key] = Task {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let hs = try await session.handles(storage: key.storage, parent: key.folder)
                try checkLive(key)
                var fresh: [ObjectEntry] = []
                for i in stride(from: 0, to: hs.count, by: Listing.batchSize) {
                    try checkLive(key)
                    let batch = try await session.entries(Array(hs[i..<min(i + Listing.batchSize, hs.count)]),
                                                          parent: key.folder)
                    try checkLive(key)
                    if replacing { fresh += batch } else { cache.append(batch, to: key) }
                }
                try checkLive(key)
                if replacing {
                    // Rows an event added while this read ran (after its GetObjectHandles) stay.
                    let listed = Set(hs)
                    let arrived = (cache[key] ?? []).filter { !before.contains($0.id) && !listed.contains($0.id) }
                    cache.replace(key, entries: fresh + arrived)
                } else {
                    cache.finish(key)
                }
                listTasks[key] = nil
                log.info("listed \(hs.count, privacy: .public) items in \(Int((clock.now - start) / .milliseconds(1)), privacy: .public) ms")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, isLive(key) else { return }
                listTasks[key] = nil
                if let error = error as? MTPError, case .response = error {
                    log.error("listing failed: \(error.detail, privacy: .public)")   // op name and code only
                    cache.remove(key)
                    if key == location.key {
                        failure = error
                    } else {                                      // an expanded folder: fold it back up and say why (U6)
                        collapse(key.folder)
                        alert = AlertText(message: OperationAlert.unexpectedError, detail: error.codeLine ?? error.detail)
                    }
                } else {
                    onSessionLost(error)
                }
            }
        }
    }

    /// The stale-result guard after every await: cancelled, or the folder is no longer shown.
    private func checkLive(_ key: FolderKey) throws {
        try Task.checkCancellation()
        guard isLive(key) else { throw CancellationError() }
    }
}
