import AppKit
import MTPKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import os

/// An outline item. NSOutlineView tracks expansion by object identity, so nodes are reused by handle.
final class FileNode: NSObject {
    var entry: ObjectEntry
    init(_ entry: ObjectEntry) { self.entry = entry }
}

/// One dragged row: its provider's `userInfo` (strong), so it keeps its drag's `DragOut` alive. Captured by value at
/// drag start, since a snapshot can reload the outline mid-drag (RESEARCH Pitfall 9).
final class DragItem: NSObject {
    let entry: ObjectEntry
    /// The item's phone path from the storage root down to its own name, for a Retry after a replug (P4 D-14).
    let path: [String]
    var drag: DragOut?
    init(entry: ObjectEntry, path: [String]) {
        self.entry = entry
        self.path = path
    }
}

/// The promise writes of one drag out, gathered into one Copy-window job (D-01). AppKit issues every write of a drop
/// before any completion (RESEARCH S1); the completions are held until the job ends, however it ends (D-05), and get
/// its error when it didn't copy everything (G-05-1-2).
final class DragOut {
    private struct Promise {
        let item: DragItem
        let url: URL
        let done: ((any Error)?) -> Void
    }

    private var batch: PromiseBatch
    private var pending: [Promise] = []
    /// The browser's session at drag start; a drop after a reconnect is refused and its promises end at once.
    let session: DeviceSession
    weak var model: AppModel?
    private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "drag")

    init(expected: Int, session: DeviceSession, model: AppModel?) {
        batch = PromiseBatch(expected: expected)
        self.session = session
        self.model = model
    }

    /// After the drag ended (RESEARCH Pattern 1, Fallback flush): writes that never arrived can't hold the job back; a
    /// drag cancelled with Escape or dropped on the Trash has nothing pending, so nothing starts.
    func flush() {
        guard batch.flush() == .start else { return }
        start(pending)
        pending = []
    }

    func arrived(_ item: DragItem, url: URL, done: @escaping ((any Error)?) -> Void) {
        let promise = Promise(item: item, url: url, done: done)
        pending.append(promise)
        switch batch.arrive() {
        case .start:
            start(pending)
            pending = []
        case .startAlone:                                       // a straggler after the start gets its own job
            pending.removeLast()
            start([promise])
        case .wait:
            break
        }
    }

    /// Only each URL's folder is used: the system already uniquified a clashing name (RESEARCH S1b), and landing by
    /// own names lets the job's clash sheet ask (Pitfall 4); a receiver that reads the file (Mail) names a fresh folder,
    /// where the URL is the item's own name, and its temps stay out of that folder (G-05-1-2). A Finder drop names one
    /// folder for every item, so it stays one job (D-01); a receiver that names a folder per item gets one job per
    /// folder, so no item is written into another item's folder while its completion says done (D-04, D-05).
    private func start(_ group: [Promise]) {
        let parts = PromiseBatch.byFolder(group, url: \.url)
        log.info("\(group.count) promise write(s) name \(parts.count) folder(s)")
        guard let model else { return group.forEach { $0.done(CocoaError(.userCancelled)) } }
        for part in parts {
            model.download(part.map(\.item.entry), paths: part.map(\.item.path),
                           to: part[0].url.deletingLastPathComponent(), from: session, stageTemps: true,
                           onEnd: { report in
                               for (i, promise) in part.enumerated() { promise.done(report.error(top: i)) }
                           })
        }
    }
}

/// One promise drop in from Photos, Safari or Mail (FNDR-03, D-10): every pasteboard item is a slot, filled at once by
/// a file URL or by its receiver's files as they land in `staging/<slot>`. Its staging folder is held from the drop
/// until it is finished. Every way a drop ends:
/// - every announced file called back: one Upload… job (slots in drop order), then `finish()`;
/// - every slot heard from but a promiser announced more than it delivers: what arrived starts 30 s after the last
///   arrival, and the drop stays open for the rest;
/// - the 10-minute deadline (after the drop or the latest arrival): what arrived starts, an alert when announced files
///   never came (nothing arrived included, O-18), then `finish()`;
/// - each failed write: a log line when its callback comes; before `finish()` its name is collected into the drop's one
///   alert (O-16), after it the failure gets an alert of its own;
/// - a session replaced meanwhile (unplug, another phone): `AppModel.upload` beeps and records no job; the staging goes
///   when the drop finishes;
/// - a file after the start or after `finish()`: its own job from the same staging folder, which that job keeps.
final class IncomingDrop {
    private var batch: PromiseBatch
    /// Each pasteboard item's files, in arrival order.
    private var slots: [[URL]]
    /// Which slots have had a callback; a URL slot counts at once. A slot not heard from is still being exported.
    private var heard: [Bool]
    private var finished = false
    /// Promised files whose callback reported a failure before `finish()`, shown together by it.
    private var failedNames: [String] = []
    private var quiet: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    let staging: URL
    private let target: (key: FolderKey, name: String, path: [String])
    /// The browser's session at the drop; a replaced one is refused by `AppModel.upload` (CR-02).
    private let session: DeviceSession
    private weak var model: AppModel?
    private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "drag")

    /// `urls` has one entry per pasteboard item: its file URL, or nil for a promise whose `files` count is announced.
    init(urls: [URL?], files: [Int], staging: URL, target: (key: FolderKey, name: String, path: [String]),
         session: DeviceSession, model: AppModel) {
        slots = urls.map { $0.map { [$0] } ?? [] }
        heard = urls.map { $0 != nil }
        batch = PromiseBatch(expected: urls.count { $0 != nil } + files.reduce(0, +))
        self.staging = staging
        self.target = target
        self.session = session
        self.model = model
        for _ in urls.compactMap({ $0 }) { _ = batch.arrive() }   // a URL is there already
        restartTimers()
    }

    /// One reader callback: `url` is nil when the file `name` never reached staging.
    func arrived(slot: Int, url: URL?, name: String) {
        if finished {                                        // late: never dropped silently
            if let url { start([url]) } else { model?.transfers.show(TransferText.promiseFailed(names: [name])) }
            return
        }
        if url == nil { failedNames.append(name) }
        heard[slot] = true
        if let url { slots[slot].append(url) }
        switch batch.arrive() {
        case .start: start(slots.flatMap { $0 })
        case .startAlone: if let url { start([url]) }        // after the start: its own job, never dropped
        case .wait: break
        }
        if batch.arrived >= batch.expected { finish() } else { restartTimers() }
    }

    private func restartTimers() {
        quiet?.cancel()
        deadline?.cancel()
        // ponytail: a fixed wait for promisers that announce more files than they deliver (fileTypes isn't guaranteed
        // for legacy promisers, RESEARCH Pattern 3); one item whose files land > 30 s apart would split into two rows.
        quiet = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, !finished, !heard.contains(false), batch.flush() == .start else { return }
            start(slots.flatMap { $0 })
        }
        // ponytail: a fixed give-up for a promiser that never calls back, long enough for an iCloud-only video; a
        // waiting Copy-window row is the upgrade if it ever bites.
        deadline = Task {
            try? await Task.sleep(for: .minutes(10))
            guard !Task.isCancelled, !finished else { return }
            if batch.flush() == .start { start(slots.flatMap { $0 }) }
            if batch.arrived < batch.expected {
                model?.transfers.show(TransferText.promiseTimedOut(count: batch.expected - batch.arrived))
                log.error("\(self.batch.expected - self.batch.arrived) promised file(s) never arrived")
            }
            finish()
        }
    }

    /// Ordering, duplicate names and link refusal come from the upload path (P4 D-10, T-03-07).
    private func start(_ urls: [URL]) {
        guard !urls.isEmpty else { return }                  // every file failed: `finish()` shows the alert
        model?.upload(urls, into: target.key, name: target.name, path: target.path, from: session, staging: staging)
    }

    /// Nothing more is expected: the staging folder goes now, or with the last job of this drop.
    func finish() {
        guard !finished else { return }
        finished = true
        quiet?.cancel()
        deadline?.cancel()
        if !failedNames.isEmpty { model?.transfers.show(TransferText.promiseFailed(names: failedNames)) }
        model?.transfers.releaseStaging(staging)
    }
}

private extension Duration {
    static func minutes(_ count: Int64) -> Duration { .seconds(count * 60) }
}

/// The outline with Finder's rename entry points (D-20): Return on the one selected row, and the slow second
/// click on an already-selected name (NSTableView's own first-responder rule, RESEARCH Pattern 5). It is also the
/// Quick Look panel's controller (the panel follows the responder chain), data source and delegate (PREV-01).
final class FileOutlineView: NSOutlineView, NSSpringLoadingDestination, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var browser: BrowserModel?
    weak var previews: PreviewStore?
    private var indexObservation: NSKeyValueObservation?
    /// The folder row under a drag and the pointer in outline coordinates, both from validateDrop (Pitfall 8: the
    /// spring callbacks' own location is unreliable, S4).
    var springTarget: FileNode? {
        didSet { if springTarget !== oldValue { sprung = nil } }   // the next folder (L2) may spring
    }
    var dragPoint = NSPoint.zero
    /// Handles of an in-app drag, never sprung into or dropped into (filled when the drag begins).
    var draggedHandles: Set<UInt32> = []
    /// A drag is over the list: the outline's own hover-expand only follows `springCandidate` (S4b).
    var isDragInside = false
    /// The row that just sprang: no second spring, and no in-place expand while its listing comes.
    private var sprung: FileNode?

    /// The folder under the drag that may spring or expand: never a dragged one, nor the one that just sprang.
    var springCandidate: FileNode? {
        guard let target = springTarget, target !== sprung, !draggedHandles.contains(target.entry.id) else { return nil }
        return target
    }

    // MARK: Spring-loading (D-07)

    /// The drag and whether the window was key at its last spring update.
    private var keySeen: (drag: Int, key: Bool)?

    /// Enabled over the triangle too: the outline's hover-expand shares this gate, and .disabled shuts it (S4b).
    /// An inactive window's first hover only brings the window forward (AppKit's window spring-loading), and the row's
    /// own hover then waits for a fresh move, so the row under the pointer springs with the window (G-05-9).
    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        let drag = draggingInfo.draggingSequenceNumber, key = window?.isKeyWindow == true
        if let seen = keySeen, seen.drag == drag, !seen.key, key { springLoadingActivated(true, draggingInfo: draggingInfo) }
        keySeen = (drag, key)
        return springCandidate == nil ? .disabled : .enabled
    }

    /// A folder row springs; over its disclosure triangle it expands in place instead.
    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        guard activated, let target = springCandidate else { return }
        let row = row(forItem: target)
        guard row >= 0, !frameOfOutlineCell(atRow: row).contains(dragPoint) else { return expandItem(target) }
        sprung = target
        browser?.springOpen(target.entry)
    }

    /// The drop highlight already shows the target.
    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}

    /// Leaving the list springs back, as Finder closes a spring-loaded window the pointer leaves.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if NSOutlineView.instancesRespond(to: #selector(NSDraggingDestination.draggingExited(_:))) {
            super.draggingExited(sender)
        }
        springTarget = nil
        isDragInside = false
        browser?.endSpring(dropped: false)
    }

    /// No call up: NSOutlineView doesn't implement this, and the call would raise (RESEARCH anti-pattern). Arrives only
    /// on some paths, so acceptDrop and the source's end clear the drag state too.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        springTarget = nil
        isDragInside = false
        browser?.endSpring(dropped: false)
    }

    private var canEdit: Bool { selectedRowIndexes.count == 1 && browser?.isBusy == false && browser?.isCopying == false }

    /// The name field refuses focus until this uptime: armed by a click on the selected row, which may be a
    /// double-click's first (G-05-5-2), and extended by the double-click (G-05-5).
    var editHeldUntil: TimeInterval = 0
    var mayEdit: Bool { canEdit && ProcessInfo.processInfo.systemUptime >= editHeldUntil }

    /// NSTableView's tap path would open the name field on this click's mouse-up, before a second click could make it
    /// a double-click; held until just before AppKit's delayed edit, which then opens a slow click's rename.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, selectedRowIndexes.count == 1,
           row(at: convert(event.locationInWindow, from: nil)) == selectedRow {
            editHeldUntil = event.timestamp + NSEvent.doubleClickInterval - 0.05
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, canEdit {      // Return, keypad Enter
            beginRename(row: selectedRow, selectAll: false, text: nil)
        } else if event.keyCode == 53, previews?.status != nil {     // Escape stops an Open fetch (Pattern 7)
            previews?.cancel()
        } else if event.keyCode == 49 {                              // Space
            toggleQuickLook()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Quick Look (PREV-01, D-15)

    /// The selected rows that are files, in row order; folders are never previewed.
    var previewEntries: [ObjectEntry] {
        selectedRowIndexes.compactMap { (item(atRow: $0) as? FileNode)?.entry }.filter { !$0.isFolder }
    }

    /// Space, ⌘Y and the context menu: closes an open panel; otherwise opens it on the selected files, or beeps when
    /// only folders are selected. A first file over `PreviewText.bigFile` asks first as a sheet (D-16 list path):
    /// Preview is first, so Return; Cancel takes Escape. Nothing is fetched until Preview.
    func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard let first = previewEntries.first else { return NSSound.beep() }
        guard let previews, previews.needsQuestion(first), let window, let session = browser?.session else {
            return QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
        let alert = NSAlert()
        alert.messageText = PreviewText.question(names: [first.name], size: first.size)
        alert.addButton(withTitle: "Preview")
        alert.addButton(withTitle: "Cancel")
        Task {
            // A reconnect while the sheet was up makes the handle stale (CR-02).
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                  browser?.session === session else { return }
            previews.confirm(first.id)
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            // The item that becomes current starts its fetch, whether or not the panel asks for it again.
            indexObservation = panel.observe(\.currentPreviewItemIndex) { [weak self] panel, _ in
                MainActor.assumeIsolated { self?.fetchCurrent(panel) }
            }
        }
    }

    /// Space or Escape closed the panel: its fetch stops (D-15). Data source and delegate are assign (Pitfall 17).
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            indexObservation = nil
            previews?.endPreview()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewEntries.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let entries = previewEntries
        guard let previews, entries.indices.contains(index) else { return nil }
        if index == panel.currentPreviewItemIndex { fetchCurrent(panel) }
        return previews.previewItem(for: entries[index])
    }

    /// ↑/↓ move the list's selection and the panel follows. Return never reaches the outline, where it would open the
    /// rename field (Pitfall 16).
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126:
            keyDown(with: event)
            return true
        case 36, 76:                                            // Return = Preview on a big file (D-16, S5c)
            let entries = previewEntries
            let index = panel.currentPreviewItemIndex
            if let previews, entries.indices.contains(index), previews.needsQuestion(entries[index]) {
                previews.confirm(entries[index].id)
                fetchCurrent(panel)
                panel.refreshCurrentPreviewItem()
            }
            return true
        default:
            return false
        }
    }

    /// Starts the current item's fetch, replacing the previous item's (moving away cancels, D-15).
    private func fetchCurrent(_ panel: QLPreviewPanel) {
        let entries = previewEntries
        let index = panel.currentPreviewItemIndex
        guard let previews, let session = browser?.session, entries.indices.contains(index) else { return }
        let item = previews.previewItem(for: entries[index])
        previews.startFetch(entries[index], session: session) { [weak self, weak item] landed in
            guard let self, let item, QLPreviewPanel.sharedPreviewPanelExists() else { return }
            let panel = QLPreviewPanel.shared()!
            guard panel.isVisible, panel.dataSource === self, panel.currentPreviewItem === item else { return }
            // A landed file is a new item, which only reloadData() picks up (G-05-6-2); ticks redraw the same one.
            if landed { panel.reloadData() } else { panel.refreshCurrentPreviewItem() }
        }
    }

    /// The name field may take focus only on the one selected row while nothing else is changing the phone.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable {
            guard canEdit, row(for: field) == selectedRow else { return false }
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// Opens the name field; NameField.becomeFirstResponder selects the basename (D-20). Here only the overrides:
    /// all of it when asked (New Folder, a rejected name), and `text` replacing the shown name, e.g. the name the
    /// phone just refused (D-21).
    func beginRename(row: Int, selectAll: Bool, text: String?) {
        editHeldUntil = 0               // an explicit rename is never the double-click's leftover delayed edit (G-05-5)
        let column = column(withIdentifier: FileListView.Column.name)
        guard row >= 0, column >= 0 else { return }
        scrollRowToVisible(row)
        editColumn(column, row: row, with: nil, select: false)
        guard let field = (view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField,
              let editor = field.currentEditor() else { return }
        if let text { editor.string = text }
        selectName(in: field, all: selectAll)
    }

    /// Finder's rename selection (D-20): the basename of a file, the whole name of a folder, or all of it when asked.
    func selectName(in field: NSTextField, all: Bool) {
        guard let editor = field.currentEditor() else { return }
        let name = editor.string as NSString
        let isFolder = (item(atRow: row(for: field)) as? FileNode)?.entry.isFolder ?? false
        let length = all || isFolder ? name.length : (name.deletingPathExtension as NSString).length
        editor.selectedRange = NSRange(location: 0, length: length)
    }
}

/// The name cell's field. Taking focus is the one choke point every rename entry path crosses, AppKit's slow
/// second click included, so it reports the rename as open and applies the basename selection here (G-02-3).
/// NSControlTextDidBeginEditing waits for the first keystroke, and until then menu shortcuts and list rebuilds
/// would act on the open field (WR-03). AppKit calls this twice on the slow click (the second ~0.5 s later, with
/// its own select-all), so the selection is applied on every call, not once. A click on the selected row reaches it
/// two ways, the table's tap gesture at mouse-up and a delayed edit a double-click interval after mouse-down, and both
/// consult only acceptsFirstResponder, so the click and double-click hold, canEdit and the selected row are enforced
/// there (G-05-5, G-05-5-2).
final class NameField: NSTextField {
    override var acceptsFirstResponder: Bool {
        if let outline = enclosingScrollView?.documentView as? FileOutlineView,
           !outline.mayEdit || outline.row(for: self) != outline.selectedRow { return false }
        return super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let outline = enclosingScrollView?.documentView as? FileOutlineView {
            outline.browser?.isRenaming = true
            outline.selectName(in: self, all: false)
        }
        return accepted
    }
}

/// The file list: an NSOutlineView (D-12) whose folders expand in place, listed on expand (BRWS-04).
/// Double-clicking a folder opens it (D-01); double-clicking a file opens it in its default Mac app from a temp copy (D-19).
/// Default outline keys stay: → / ← expand and collapse, ⌥-click expands all, type-select.
struct FileListView: NSViewRepresentable {
    let snapshot: BrowserModel.ListSnapshot
    let browser: BrowserModel
    let model: AppModel

    /// A new coordinator never replays a rename or list request made before it existed.
    func makeCoordinator() -> Coordinator {
        Coordinator(handledRequest: snapshot.renameRequest?.id, handledListRequest: snapshot.listRequest?.id)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowSizeStyle = .default
        outline.selectionHighlightStyle = .regular
        // The non-local default is none, and Finder would never call the provider (Pitfall 1). Copy only, never
        // delete or generic (D-03).
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Within the list a drag moves rows on the phone (FMGT-04, D-11).
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Mac items (FNDR-02) and file promises from Photos, Safari, Mail (FNDR-03); path bar and sidebar take none (D-08)
        outline.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })

        let name = NSTableColumn(identifier: Column.name)
        name.title = "Name"
        name.minWidth = 200
        name.resizingMask = .autoresizingMask
        let size = NSTableColumn(identifier: Column.size)
        size.title = "Size"
        size.width = 88
        size.minWidth = 72
        size.headerCell.alignment = .right
        let date = NSTableColumn(identifier: Column.date)
        date.title = "Last Modified"
        date.width = 180
        date.minWidth = 140
        for column in [name, size, date] {
            // The key only identifies the column; sorting itself uses MTPKit's comparators, never KVC.
            column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = name
        outline.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.update(snapshot, browser: browser, model: model, in: outline)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        context.coordinator.update(snapshot, browser: browser, model: model, in: outline)
    }

    enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let date = NSUserInterfaceItemIdentifier("date")
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate,
                             NSFilePromiseProviderDelegate {
        private var snapshot: BrowserModel.ListSnapshot?
        private var entries: [ObjectEntry] { snapshot?.entries ?? [] }
        private weak var browser: BrowserModel?
        private var nodes: [UInt32: FileNode] = [:]
        private var rows: [FileNode] = []
        /// Sorted child nodes of each expanded folder, rebuilt with the rows.
        private var sortedChildren: [UInt32: [FileNode]] = [:]
        private var sortKey = ObjectSortKey.name                // lives only for the session
        private var ascending = true
        /// True while the coordinator changes the outline itself, so its own changes aren't reported back.
        private var isSyncing = false
        /// A navigation's saved selection and scroll, kept until its rows have arrived (D-07, D-08).
        private var pendingRestore: HistoryEntry?
        private weak var outline: FileOutlineView?
        /// The newest snapshot that arrived while the rename field was open: reloadData would tear the edit down.
        private var queued: BrowserModel.ListSnapshot?
        private var handledRequest: Int?
        private var handledListRequest: Int?
        private weak var model: AppModel?
        /// The promise writes run here one at a time; each only hops to the MainActor.
        private let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        /// Promise drops in are written here one at a time; each reader callback only hops to the MainActor.
        private let incomingQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        /// The rows AppKit asked a provider for, until the drag begins.
        private var outgoing: [UInt32: DragItem] = [:]
        private var currentDrag: DragOut?
        /// The rows of a drag that began here, by value: a spring-load re-renders the list under it (Pitfall 9).
        private var localDrag: [ObjectEntry] = []

        init(handledRequest: Int?, handledListRequest: Int?) {
            self.handledRequest = handledRequest
            self.handledListRequest = handledListRequest
        }

        func update(_ snapshot: BrowserModel.ListSnapshot, browser: BrowserModel, model: AppModel, in outline: NSOutlineView) {
            self.browser = browser
            self.model = model
            self.outline = outline as? FileOutlineView
            self.outline?.browser = browser
            self.outline?.previews = model.previews
            if browser.isRenaming { queued = snapshot; return }
            queued = nil
            guard snapshot != self.snapshot else { return }     // SwiftUI re-renders must not drop the selection
            let moved = snapshot.generation != self.snapshot?.generation
            self.snapshot = snapshot
            let shown = self.outline?.previewEntries.map(\.id)
            syncing {
                if moved {                                      // another folder: its own selection, not this one's
                    outline.deselectAll(nil)
                    pendingRestore = snapshot.restore
                }
                rebuild(outline)
            }
            if pendingRestore != nil { applyRestore(outline) } else { reportSelection(outline) }
            if self.outline?.previewEntries.map(\.id) != shown { reloadPreviewPanel(outline) }
            if let request = snapshot.renameRequest, request.id != handledRequest {
                handledRequest = request.id
                // After this SwiftUI update: opening the field sets observed model state.
                Task { self.startRename(request) }
            }
            if let request = snapshot.listRequest, request.id != handledListRequest {
                handledListRequest = request.id
                Task {
                    switch request.kind {
                    case .open:
                        self.openSelectedFiles()
                    case .quickLook:
                        guard let outline = self.outline else { return }
                        outline.window?.makeFirstResponder(outline)
                        outline.toggleQuickLook()
                    }
                }
            }
        }

        // MARK: Open (D-19)

        /// The selected rows that are files, in row order, fetched and opened one after another.
        private func openSelectedFiles() {
            guard let outline else { return }
            openFiles(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.entry }
                .filter { !$0.isFolder })
        }

        /// Uncached files over `PreviewText.bigFile` together ask first, as a sheet on the list's window (D-16 list
        /// path): Open is first, so Return; Cancel takes Escape. Nothing is fetched until Open.
        private func openFiles(_ entries: [ObjectEntry]) {
            guard let model, let browser, !entries.isEmpty else { return }
            let session = browser.session
            let uncached = entries.filter { model.previews.cachedCopy($0) == nil }
            let size = uncached.reduce(UInt64(0)) { $0 + $1.size }
            guard size > PreviewText.bigFile else { return model.previews.open(entries, session: session) }
            guard let window = outline?.window else { return }
            let alert = NSAlert()
            alert.messageText = PreviewText.question(names: uncached.map(\.name), size: size)
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            Task {
                // A reconnect while the sheet was up makes these handles stale (CR-02).
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                      model.browser?.session === session else { return }
                model.previews.open(entries, session: session)
            }
        }

        /// Selects the requested row (any depth, D-09) and opens its name field.
        private func startRename(_ request: BrowserModel.RenameRequest) {
            guard let outline, let node = nodes[request.handle] else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.window?.makeFirstResponder(outline)
            outline.beginRename(row: row, selectAll: request.selectAll, text: request.text)
        }

        /// Selects the saved rows and scrolls to the saved offset, then the folder you came from into view (D-08).
        /// Kept pending while a re-listed folder fills, until every saved row is there or the listing is done.
        private func applyRestore(_ outline: NSOutlineView) {
            guard let restore = pendingRestore, let clip = outline.enclosingScrollView?.contentView else { return }
            let rows = IndexSet(restore.selected.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            syncing {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: restore.scrollY - clip.contentInsets.top))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
                if let first = rows.first { outline.scrollRowToVisible(first) }
            }
            if snapshot?.isComplete == true || (outline.numberOfRows > 0 && rows.count == restore.selected.count) {
                pendingRestore = nil
                reportSelection(outline)
            }
        }

        private func syncing(_ body: () -> Void) {
            let was = isSyncing
            isSyncing = true
            body()
            isSyncing = was
        }

        private func reportSelection(_ outline: NSOutlineView) {
            browser?.selectionChanged(Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.entry.id }))
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline = notification.object as? NSOutlineView else { return }
            pendingRestore = nil                                // the user picked something; stop restoring
            reportSelection(outline)
            reloadPreviewPanel(outline)
        }

        /// The open panel follows the selection; the new current item's fetch replaces the old one's (D-15). A rebuild
        /// under `syncing` gets no selection callback, so its callers reload here too, or Return could fetch another row.
        private func reloadPreviewPanel(_ outline: NSOutlineView) {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
               panel.dataSource === outline {
                panel.reloadData()
            }
        }

        /// Scroll offset measured from the top of the content, so the toolbar inset doesn't skew it.
        @objc func scrolled(_ notification: Notification) {
            guard !isSyncing, let clip = notification.object as? NSClipView else { return }
            browser?.scrollChanged(Double(clip.bounds.origin.y + clip.contentInsets.top))
        }

        // MARK: Inline rename

        /// The entry whose name field `control` is, and the folder it sits in (any depth, D-09).
        private func renamed(_ control: NSControl) -> (entry: ObjectEntry, key: FolderKey)? {
            guard let outline, let snapshot else { return nil }
            let row = outline.row(for: control)
            guard row >= 0, let entry = (outline.item(atRow: row) as? FileNode)?.entry else { return nil }
            return (entry, FolderKey(storage: snapshot.key.storage, folder: entry.parent))
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            browser?.isRenaming = true
        }

        /// Return, Tab or a click elsewhere: a name the rules reject keeps the field open with all of it selected,
        /// under Finder's alert (D-21); an accepted one goes to the phone.
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let browser, let (entry, key) = renamed(control) else { return true }
            if browser.commitRename(handle: entry.id, in: key, text: fieldEditor.string) { return true }
            fieldEditor.selectAll(nil)
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let browser else { return }
            browser.isRenaming = false
            if let outline {
                // Return goes back to the list, as in Finder; Tab or a click elsewhere keeps its own target.
                if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
                    outline.window?.makeFirstResponder(outline)
                }
                if let queued, let model { update(queued, browser: browser, model: model, in: outline) }
            }
        }

        /// Escape puts the name back and ends editing without renaming.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let (entry, _) = renamed(control) else { return false }
            textView.string = entry.name
            outline.map { _ = $0.window?.makeFirstResponder($0) }
            return true
        }

        // MARK: Drag out (FNDR-01)

        /// A promise per row, typed as its icon is (a folder promise is `public.folder`, RESEARCH S1c). No drag while
        /// a name is being edited or a rename, new folder or delete is running. A selected row inside a selected folder
        /// gets none: the folder already brings it (D-01, P3 D-21, `DeletePlan.topLevel` on the outline's own tree). A
        /// drag that starts on an unselected row drags that row alone, as in Finder, so it is never deduped away.
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? FileNode, let browser, !browser.isRenaming, !browser.isBusy else { return nil }
            let selected = outlineView.isRowSelected(outlineView.row(forItem: node))
            var names = [node.entry.name]
            var up = outlineView.parent(forItem: node)
            while let parent = up as? FileNode {
                if selected && outlineView.isRowSelected(outlineView.row(forItem: parent)) { return nil }
                names.insert(parent.entry.name, at: 0)
                up = outlineView.parent(forItem: parent)
            }
            let provider = NSFilePromiseProvider(fileType: Self.type(of: node.entry).identifier, delegate: self)
            let dragItem = DragItem(entry: node.entry, path: browser.location.path.map(\.name) + names)
            provider.userInfo = dragItem
            outgoing[node.entry.id] = dragItem
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            let items = draggedItems.compactMap { ($0 as? FileNode).flatMap { outgoing[$0.entry.id] } }
            outgoing = [:]
            localDrag = items.map(\.entry)
            (outlineView as? FileOutlineView)?.draggedHandles = Set(localDrag.map(\.id))
            guard let browser, !items.isEmpty else { return }
            let drag = DragOut(expected: items.count, session: browser.session, model: model)
            for item in items { item.drag = drag }
            currentDrag = drag
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            (outlineView as? FileOutlineView)?.isDragInside = false   // every in-app drag ends here
            (outlineView as? FileOutlineView)?.draggedHandles = []
            localDrag = []
            browser?.endSpring(dropped: false)
            // The Dock Trash accepts a copy-only drag and reports delete; no promise was asked for and nothing is
            // deleted (D-03, RESEARCH S3).
            if operation.contains(.delete) { NSSound.beep() }
            guard let drag = currentDrag else { return }
            currentDrag = nil
            // endedAt can fire between the writes (S1), so the flush waits a second.
            Task {
                try? await Task.sleep(for: .seconds(1))
                drag.flush()
            }
        }

        /// Finder calls it on main (RESEARCH S1d), but a coordinated read by Mail or Messages may not (G-05-1), so it is
        /// nonisolated.
        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? DragItem)?.entry.name ?? "Untitled"
        }

        /// D-05: a write with no batch copies nothing: told the silent `userCancelled` at once, never left waiting.
        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping ((any Error)?) -> Void) {
            let item = filePromiseProvider.userInfo as? DragItem
            // AppKit accepts the completion from any thread (RESEARCH S1); it is only ever called once, on main.
            nonisolated(unsafe) let done = completionHandler
            Task { @MainActor in
                guard let item, let drag = item.drag else { return done(CocoaError(.userCancelled)) }
                drag.arrived(item, url: url, done: done)
            }
        }

        // The SDK marks it UI-actor, but file coordination calls it off main when Mail or Messages read the promise (G-05-1).
        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

        // MARK: Drop in (FNDR-02)

        /// Finder's targets (D-06): the background is the opened folder, a folder row that folder, a file row the folder
        /// holding it. Always a copy, so ⌘ never moves the Mac originals (D-09). Refused while Upload… is (renaming, a
        /// change running, the listing failed). A drag from this list is a move on the phone instead (FMGT-04), never
        /// read as Mac items (Pitfall 7).
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let outline = outlineView as? FileOutlineView else { return [] }
            if (info.draggingSource as? NSOutlineView) === outlineView { return validateMove(item as? FileNode, info, outline) }
            let node = item as? FileNode
            let accepted = browser?.canUpload == true
            // The proposal, not the retarget, is the row under the pointer: the folder that springs (Pitfall 8).
            outline.isDragInside = true
            outline.dragPoint = outline.convert(info.draggingLocation, from: nil)
            let spring = accepted && node?.entry.isFolder == true ? node : nil
            if spring !== outline.springTarget {
                outline.springTarget = spring
                info.resetSpringLoading()
            }
            guard accepted else { return [] }
            let target = node?.entry.isFolder == false ? outlineView.parent(forItem: node) : node as Any?
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }

        /// An in-app drag, with the same targets and spring-loading as a drop from Finder (D-06, D-07). Refused (no
        /// highlight) while `canMove` is false (D-14), onto a dragged item, into a dragged folder or anything inside
        /// it (05-MOVE-PROBE: the phone must never see that move), or onto the folder every dragged item is already in.
        private func validateMove(_ node: FileNode?, _ info: any NSDraggingInfo, _ outline: FileOutlineView) -> NSDragOperation {
            guard let browser else { return [] }
            let accepted = browser.canMove
            outline.isDragInside = true
            outline.dragPoint = outline.convert(info.draggingLocation, from: nil)
            let spring = accepted && node?.entry.isFolder == true ? node : nil   // dragged folders: `draggedHandles`
            if spring !== outline.springTarget {
                outline.springTarget = spring
                info.resetSpringLoading()
            }
            guard accepted else { return [] }
            let target = node?.entry.isFolder == false ? outline.parent(forItem: node) as? FileNode : node
            // The destination and every folder above it: its outline parents, then the opened folder's path.
            var chain = browser.location.path.map(\.handle)
            var up: FileNode? = target
            while let folder = up {
                chain.append(folder.entry.id)
                up = outline.parent(forItem: folder) as? FileNode
            }
            let destination = target?.entry.id ?? browser.location.key.folder
            guard !chain.contains(where: outline.draggedHandles.contains),
                  !localDrag.allSatisfy({ $0.parent == destination }) else { return [] }
            outline.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        /// One Upload… job per drop, items in the pasteboard's order (D-10). AppModel refuses a replaced session (CR-02);
        /// the queue does the rest: clash sheet, Mac metadata and links skipped, packages as folders, hidden temps.
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            // Before any branch: whatever was dropped, the list stays where it was dropped (D-07).
            (outlineView as? FileOutlineView)?.isDragInside = false
            browser?.endSpring(dropped: true)
            // A drag from this list moves its rows on the phone (FMGT-04); the targets were checked by validateMove.
            if (info.draggingSource as? NSOutlineView) === outlineView {
                guard let browser, !localDrag.isEmpty else { return false }
                browser.move(localDrag, into: browser.dropTarget((item as? FileNode)?.entry).key)
                return true
            }
            // Our own rows are never read as a drop in, promises included.
            guard let browser, let model,
                  let items = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self, NSURL.self],
                                                                  options: [.urlReadingFileURLsOnly: true]),
                  !items.isEmpty else { return false }
            let target = browser.dropTarget((item as? FileNode)?.entry)
            let name = target.name ?? model.selectedStorage?.displayName ?? ""
            let receivers = items.map { $0 as? NSFilePromiseReceiver }
            guard receivers.contains(where: { $0 != nil }) else {
                model.upload(items.compactMap { $0 as? URL }, into: target.key, name: name, path: target.path,
                             from: browser.session)
                return true
            }
            // FNDR-03: one staging folder per drop under the per-launch root, held until the drop is finished (D-10).
            let staging = model.previews.stagingFolder()
            model.transfers.holdStaging(staging)
            let drop = IncomingDrop(urls: items.map { $0 as? URL },
                                    files: receivers.compactMap { $0.map { max($0.fileTypes.count, 1) } },
                                    staging: staging, target: (target.key, name, target.path), session: browser.session,
                                    model: model)
            let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "drag")
            for (slot, receiver) in receivers.enumerated() {
                guard let receiver else { continue }
                // Its own subfolder, so two promised files with one name both arrive (P4 D-10).
                let folder = staging.appending(component: String(slot))
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                receiver.receivePromisedFiles(atDestination: folder, options: [:],
                                              operationQueue: incomingQueue) { @Sendable url, error in
                    let file = url.lastPathComponent, detail = error?.localizedDescription
                    Task { @MainActor in
                        if let detail {
                            log.error("promised file \(file, privacy: .private) not received: \(detail, privacy: .public)")
                        }
                        drop.arrived(slot: slot, url: detail == nil ? url : nil, name: file)
                    }
                }
            }
            return true
        }

        // MARK: Context menu

        /// Built each time it opens. New Folder and Upload… always act on the opened folder, whatever was clicked
        /// (D-18, D-19), so they show on rows and on the empty area. Download to…, Rename and Delete act on the
        /// clicked row, selecting it first when it is outside the selection, as Finder does (D-16); so does Open, first.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let browser else { return }
            let newFolder = NSMenuItem(title: "New Folder", action: #selector(newFolderClicked(_:)), keyEquivalent: "")
            newFolder.target = self
            newFolder.isEnabled = browser.canNewFolder
            menu.addItem(newFolder)
            let upload = NSMenuItem(title: "Upload to Android", action: #selector(uploadClicked(_:)), keyEquivalent: "")
            upload.target = self
            upload.isEnabled = browser.canUpload
            menu.addItem(upload)
            guard outline.clickedRow >= 0 else { return }
            // Finder's first row item, acting like File > Open on the selection (D-19).
            let open = NSMenuItem(title: "Open", action: #selector(openClicked(_:)), keyEquivalent: "")
            open.target = self
            open.isEnabled = !browser.isRenaming
            menu.insertItem(open, at: 0)
            let quickLook = NSMenuItem(title: "Quick Look", action: #selector(quickLookClicked(_:)), keyEquivalent: "")
            quickLook.target = self
            let clicked = (outline.item(atRow: outline.clickedRow) as? FileNode)?.entry
            quickLook.isEnabled = !browser.isRenaming && (outline.selectedRowIndexes.contains(outline.clickedRow)
                ? browser.canQuickLook : clicked?.isFolder == false)
            menu.insertItem(quickLook, at: 1)
            menu.insertItem(.separator(), at: 2)
            menu.addItem(.separator())
            let download = NSMenuItem(title: "Download to Mac", action: #selector(downloadClicked(_:)), keyEquivalent: "")
            download.target = self
            download.isEnabled = !browser.isRenaming
            menu.addItem(download)
            let item = NSMenuItem(title: "Rename", action: #selector(renameClicked(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = outline.selectedRowIndexes.contains(outline.clickedRow)
                ? browser.canRename
                : !browser.isBusy && !browser.isRenaming && !browser.isCopying
            menu.addItem(item)
            let delete = NSMenuItem(title: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = outline.selectedRowIndexes.contains(outline.clickedRow)
                ? browser.canDelete
                : !browser.isBusy && !browser.isRenaming && !browser.isCopying
            menu.addItem(delete)
        }

        /// Opens the selection, or just the clicked row when it is outside the selection: one folder navigates into
        /// it, otherwise the selected files open.
        @objc private func openClicked(_ sender: NSMenuItem) {
            guard let outline, let browser, outline.clickedRow >= 0 else { return }
            if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)   // reported to the model
            }
            if outline.selectedRowIndexes.count == 1, let entry = (outline.item(atRow: outline.selectedRow) as? FileNode)?.entry,
               entry.isFolder {
                browser.open(entry)
            } else {
                openSelectedFiles()
            }
        }

        /// Quick Looks the selection, or just the clicked row when it is outside the selection, like Space.
        @objc private func quickLookClicked(_ sender: NSMenuItem) {
            guard let outline, outline.clickedRow >= 0 else { return }
            if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)   // reported to the model
            }
            outline.toggleQuickLook()
        }

        @objc private func newFolderClicked(_ sender: NSMenuItem) {
            browser?.newFolder()
        }

        @objc private func uploadClicked(_ sender: NSMenuItem) {
            browser?.requestUpload()
        }

        /// Downloads the selection, or just the clicked row when it is outside the selection, as Finder does.
        @objc private func downloadClicked(_ sender: NSMenuItem) {
            guard let outline, let browser, outline.clickedRow >= 0 else { return }
            if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)   // reported to the model
            }
            browser.requestDownload()
        }

        @objc private func renameClicked(_ sender: NSMenuItem) {
            guard let outline, let browser, outline.clickedRow >= 0 else { return }
            if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)   // reported to the model
            }
            browser.beginRename()
        }

        /// Deletes the selection, or just the clicked row when it is outside the selection, as Finder does.
        @objc private func deleteClicked(_ sender: NSMenuItem) {
            guard let outline, let browser, outline.clickedRow >= 0 else { return }
            if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false)   // reported to the model
            }
            browser.confirmDelete()
        }

        @objc func doubleClicked(_ outline: NSOutlineView) {
            (outline as? FileOutlineView)?.editHeldUntil = ProcessInfo.processInfo.systemUptime + NSEvent.doubleClickInterval
            guard outline.clickedRow >= 0, let entry = (outline.item(atRow: outline.clickedRow) as? FileNode)?.entry,
                  let browser else { return }
            if entry.isFolder { browser.open(entry) } else { openFiles([entry]) }
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let first = outlineView.sortDescriptors.first,
                  let key = first.key.flatMap(ObjectSortKey.init(rawValue:)) else { return }
            sortKey = key
            ascending = first.ascending
            let shown = (outlineView as? FileOutlineView)?.previewEntries.map(\.id)
            syncing { rebuild(outlineView) }
            if (outlineView as? FileOutlineView)?.previewEntries.map(\.id) != shown { reloadPreviewPanel(outlineView) }
        }

        /// Re-sorts the folder and every expanded folder into nodes, reusing nodes by handle at every level,
        /// then re-expands from the model and keeps the selected handles selected. Call inside `syncing`.
        private func rebuild(_ outline: NSOutlineView) {
            let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.entry.id })
            var next: [UInt32: FileNode] = [:]
            func nodes(for list: [ObjectEntry]) -> [FileNode] {
                list.sorted(by: sortKey, ascending: ascending).map { entry in
                    let node = self.nodes[entry.id] ?? FileNode(entry)
                    node.entry = entry
                    next[entry.id] = node
                    return node
                }
            }
            rows = nodes(for: entries)
            sortedChildren = (snapshot?.children ?? [:]).mapValues(nodes(for:))
            self.nodes = next
            outline.reloadData()
            syncExpansion(rows, in: outline)
            let keep = IndexSet(selected.compactMap { next[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            outline.selectRowIndexes(keep, byExtendingSelection: false)
        }

        /// Parents before children: expands what the model has expanded and folds up what it doesn't.
        private func syncExpansion(_ level: [FileNode], in outline: NSOutlineView) {
            let expanded = snapshot?.expanded ?? []
            for node in level where node.entry.isFolder {
                if expanded.contains(node.entry.id) {
                    outline.expandItem(node)
                    syncExpansion(sortedChildren[node.entry.id] ?? [], in: outline)
                } else if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                }
            }
        }

        /// During a drag AppKit asks this on every update to open the spring gate (S4b): yes for the spring candidate,
        /// whose triangle then expands in place and whose row springs; no for the row that just sprang, so the
        /// outline's follow-up expand is vetoed (D-07). Programmatic restores always go through (A6).
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard !isSyncing, let outline = outlineView as? FileOutlineView, outline.isDragInside else { return true }
            return item as? FileNode === outline.springCandidate
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard !isSyncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            browser?.expand(node.entry.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            browser?.collapse(node.entry.id)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FileNode else { return rows.count }
            return sortedChildren[node.entry.id]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FileNode else { return rows[index] }
            return sortedChildren[node.entry.id]![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.entry.isFolder == true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let entry = (item as? FileNode)?.entry, let id = tableColumn?.identifier else { return nil }
            let cell = Self.cell(in: outlineView, id: id, delegate: self)
            switch id {
            case Column.size:
                cell.textField?.stringValue = EntryFormat.size(entry)
            case Column.date:
                cell.textField?.stringValue = EntryFormat.date(entry.modified)
            default:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = NSWorkspace.shared.icon(for: Self.type(of: entry))
            }
            return cell
        }

        /// The row's type: its icon and its drag promise's file type.
        private static func type(of entry: ObjectEntry) -> UTType {
            let ext = (entry.name as NSString).pathExtension
            return entry.isFolder ? .folder : (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
        }

        /// A reusable one-line cell that never widens its column. Name: 16×16 decorative icon, labelColor,
        /// middle truncation. Size (trailing) and Last Modified: secondaryLabelColor, tail truncation.
        private static func cell(in outline: NSOutlineView, id: NSUserInterfaceItemIdentifier,
                                 delegate: NSTextFieldDelegate) -> NSTableCellView {
            if let reused = outline.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
            let cell = NSTableCellView()
            cell.identifier = id
            let isName = id == Column.name

            let text = isName ? NameField(labelWithString: "") : NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.textColor = isName ? .labelColor : .secondaryLabelColor
            text.lineBreakMode = isName ? .byTruncatingMiddle : .byTruncatingTail
            text.alignment = id == Column.size ? .right : .natural
            text.maximumNumberOfLines = 1
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if isName {                                         // inline rename (D-20); size and date stay labels
                text.isEditable = true
                text.delegate = delegate
            }
            cell.addSubview(text)
            cell.textField = text

            var constraints = [
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ]
            if isName {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.setAccessibilityElement(false)
                cell.addSubview(icon)
                cell.imageView = icon
                constraints += [
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                ]
            } else {
                constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
            }
            NSLayoutConstraint.activate(constraints)
            return cell
        }
    }
}

/// QuickLookUI and file coordination call these five off the main thread (G-05-6, G-05-1); this never runs and only
/// fails to compile if one of them becomes main-actor again.
nonisolated func offMainWitnessGuard(_ item: PreviewItem, _ coordinator: FileListView.Coordinator,
                                     _ provider: NSFilePromiseProvider) {
    _ = item.previewItemURL
    _ = item.previewItemTitle
    _ = coordinator.operationQueue(for: provider)
    _ = coordinator.filePromiseProvider(provider, fileNameForType: "public.data")
    coordinator.filePromiseProvider(provider, writePromiseTo: URL(filePath: "/"), completionHandler: { _ in })
}
