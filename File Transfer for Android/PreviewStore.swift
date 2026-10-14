import AppKit
import MTPKit
import Observation
import QuickLookUI
import os

/// One phone file in the Quick Look panel (D-15). Its URL is the copy's final path, absent until the file lands, so the
/// panel shows the type icon and `title` meanwhile (RESEARCH S5b); only the title changes while it is fetched, and
/// `refreshCurrentPreviewItem()` re-reads this same object (S5d). The landed file gets a new item (G-05-6-2).
/// QuickLookUI reads the two getters on a background queue (G-05-6), so they are nonisolated over the lock.
final class PreviewItem: NSObject, QLPreviewItem {
    nonisolated private let state: OSAllocatedUnfairLock<(url: URL, title: String)>
    var url: URL {
        get { state.withLock { $0.url } }
        set { state.withLock { $0.url = newValue } }
    }
    var title: String {
        get { state.withLock { $0.title } }
        set { state.withLock { $0.title = newValue } }
    }
    /// The fetch failed or there is no room: the item isn't fetched again until the panel is reopened.
    var gaveUp = false
    init(url: URL, title: String) {
        state = OSAllocatedUnfairLock(initialState: (url, title))
    }
    nonisolated var previewItemURL: URL! { state.withLock { $0.url } }
    nonisolated var previewItemTitle: String! { state.withLock { $0.title } }
}

/// Open's temp store (PREV-02, D-17, D-19): phone files fetched into a per-launch folder the app owns, then handed to
/// their default Mac app. A fetch is not a Copy-window job and never waits in the queue: its chunks interleave with a
/// running job's on the same session actor (D-17). Every copy is read-only once it lands (D-18) and is reused while
/// the session lasts; copies go when the session does, at quit, and (after a crash) at the next launch (D-20, PREV-03),
/// whether or not an app still has them open. Nothing is written back to the phone.
@Observable
final class PreviewStore {
    /// `$TMPDIR/com.xianglin.File-Transfer-for-Android/<pid>`: the per-user `$TMPDIR` is 0700 (RESEARCH Pattern 8), and
    /// the pid keeps a second running instance's copies apart.
    @ObservationIgnored let root = FileManager.default.temporaryDirectory
        .appending(component: "com.xianglin.File-Transfer-for-Android").appending(component: String(getpid()))
    /// `root/Previews/<UUID>`: this session's copies, one new `<UUID>` folder per fetch.
    @ObservationIgnored private var sessionFolder: URL
    /// This session's landed copies by handle, with the size and date they were fetched at.
    @ObservationIgnored private var copies: [UInt32: (size: UInt64, modified: Date?, url: URL)] = [:]
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    /// The status line while a fetch runs ("Opening “VID.mp4”… 45%"); nil otherwise.
    private(set) var status: String?
    /// A file that couldn't be fetched or opened.
    var alert: AlertText?
    /// The one fetch in flight. Only `stopFetch()` stops or replaces it.
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bytes of the current file so far, written only by the fetch that isn't cancelled.
    @ObservationIgnored private var done: UInt64 = 0
    /// The Quick Look panel's items by handle while it is open.
    @ObservationIgnored private var items: [UInt32: PreviewItem] = [:]
    /// The panel item whose fetch is running; nil while an Open fetch runs or nothing does.
    @ObservationIgnored private var panelFetch: (item: PreviewItem, onChange: (_ landed: Bool) -> Void)?
    /// Files over `PreviewText.bigFile` the user said Preview to (D-16), for the session.
    @ObservationIgnored private var confirmed: Set<UInt32> = []
    /// The fetch's session dropped its transport (any non-response error); never called for a stop or a refusal.
    @ObservationIgnored var onSessionLost: (any Error, DeviceSession) -> Void = { _, _ in }
    @ObservationIgnored private let log = Logger(subsystem: "com.xianglin.File-Transfer-for-Android", category: "preview")

    init() {
        sessionFolder = Self.newSessionFolder(in: root)
        // A crash's leftovers; a second running instance keeps its own folder (EPERM: alive, another user's).
        for stale in PreviewFiles.staleLaunchFolders(in: root.deletingLastPathComponent(),
                                                     isAlive: { kill($0, 0) == 0 || errno == EPERM }) {
            PreviewFiles.removeAll(at: stale)
        }
        // D-20: the whole per-launch root goes at quit, so later staging folders under it go too.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [root] _ in
            PreviewFiles.removeAll(at: root)
        }
    }

    /// A new `root/Incoming/<UUID>` for one promise drop's staged files (05-08), or a drag out's download temps
    /// (G-05-1-2): under the per-launch root, so quit removes it and a dead instance's is swept at launch (D-10).
    func stagingFolder() -> URL {
        let folder = root.appending(component: "Incoming").appending(component: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error("staging folder not created: \(error.localizedDescription, privacy: .public)")
        }
        return folder
    }

    private static func newSessionFolder(in root: URL) -> URL {
        root.appending(component: "Previews").appending(component: UUID().uuidString)
    }

    /// Fetches each file of `entries` in order and opens it in its default app (D-19); folders are skipped.
    /// A failed file gets the alert and the next one carries on; a lost session ends the fetch and reconnects as the
    /// browser does.
    func open(_ entries: [ObjectEntry], session: DeviceSession) {
        stopFetch()      // ponytail: one fetch at a time; any new request replaces the one in flight
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        task = Task {
            // After a replacement the newer fetch owns the status line, so a cancelled one never writes it.
            defer { if !Task.isCancelled { status = nil } }
            for entry in files {
                guard !Task.isCancelled else { return }
                do {
                    let url: URL
                    if let cached = cachedCopy(entry) {
                        url = cached
                    } else {
                        // Like XFER-13: refused before anything is written. `root` may not exist yet, and a missing
                        // folder reads as unknown space, so the temp folder above it (same volume) is read.
                        let free = Transfer.macFreeSpace(at: FileManager.default.temporaryDirectory)
                        guard entry.size <= free else {
                            alert = PreviewText.noSpace(entry.name, needed: entry.size, available: free)
                            continue
                        }
                        url = try await fetch(entry, session: session)
                        try PreviewFiles.makeReadOnly(url)          // never writable once landed, even if stopped
                        guard !Task.isCancelled else { return }
                        copies[entry.id] = (entry.size, entry.modified, url)
                    }
                    // Checked first: with no app, open(_:) also raises macOS's own dialog, which stacked on this alert.
                    if NSWorkspace.shared.urlForApplication(toOpen: url) == nil || !NSWorkspace.shared.open(url) {
                        alert = PreviewText.noApp(entry.name)
                    }
                } catch {
                    switch TransferEnd(error) {
                    case .stopped:
                        return
                    case let .failed(detail):
                        log.error("fetch failed: \(detail, privacy: .public)")
                        if !Task.isCancelled { alert = PreviewText.failed(entry.name, detail: detail) }
                    case .lost:
                        if !Task.isCancelled { status = nil }
                        onSessionLost(error, session)
                        return
                    }
                }
            }
        }
    }

    /// This session's copy of `entry` when it is still on disk and the phone item's size and date haven't changed.
    func cachedCopy(_ entry: ObjectEntry) -> URL? {
        guard let copy = copies[entry.id], copy.size == entry.size, copy.modified == entry.modified,
              FileManager.default.fileExists(atPath: copy.url.path) else { return nil }
        return copy.url
    }

    /// Every disconnect and reconnect (AppModel.resetDeviceState): handles die with their session, so every copy
    /// goes (PREV-03), open in another app or not; they're read-only, so no edit is lost (D-18).
    func clear() {
        // Pitfall 17: the panel goes before the list, its data source, does.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        stopFetch()
        confirmed = []
        items = [:]
        copies = [:]
        PreviewFiles.removeAll(at: sessionFolder)
        sessionFolder = Self.newSessionFolder(in: root)
    }

    /// Stops the fetch in flight, if any (Escape, 05-05).
    func cancel() {
        stopFetch()
    }

    /// The only way a running fetch is stopped or replaced: whichever fetch replaces another, the replaced one's
    /// visible state is reset at once, so no stale “Opening … N%” or “Getting … N%” is left behind. A reset panel item
    /// shows its name again and fetches the next time it becomes current.
    private func stopFetch() {
        task?.cancel()
        task = nil
        status = nil
        if let (item, onChange) = panelFetch {
            panelFetch = nil
            if !FileManager.default.fileExists(atPath: item.url.path) {
                item.title = item.url.lastPathComponent
                onChange(false)
            }
        }
    }

    // MARK: Quick Look (PREV-01, D-15)

    /// The panel's item for `entry`: its valid copy, the item it already has, or a new one at an absent path in a new
    /// folder. Nothing is fetched here.
    func previewItem(for entry: ObjectEntry) -> PreviewItem {
        if let cached = cachedCopy(entry) {
            if let item = items[entry.id], item.url == cached { return item }
            let item = PreviewItem(url: cached, title: entry.name)
            items[entry.id] = item
            return item
        }
        if let item = items[entry.id] { return item }
        // The listing name is untrusted and startFetch makes this path's folder before Transfer.fetch checks it (T-05-18).
        let url = sessionFolder.appending(component: UUID().uuidString)
            .appending(component: Transfer.isSafeName(entry.name) ? entry.name : "item")
        let title = needsQuestion(entry)
            ? PreviewText.question(names: [entry.name], size: entry.size) + " " + PreviewText.pressReturn
            : PreviewText.fetching(entry.name, percent: 0)
        let item = PreviewItem(url: url, title: title)
        items[entry.id] = item
        return item
    }

    /// Fetches the panel's current item into its path, replacing any running fetch, Open's included (one at a time,
    /// D-17). Nothing when the file is already there or already coming. `onChange` redraws the panel after each title
    /// change made later, or reloads it when the file landed; the title set here is read by the caller's own refresh.
    func startFetch(_ entry: ObjectEntry, session: DeviceSession, onChange: @escaping (_ landed: Bool) -> Void) {
        let item = previewItem(for: entry)
        // A big file waits for Return or Preview, so arrowing past it costs nothing (D-16).
        guard !item.gaveUp, !needsQuestion(entry), panelFetch?.item !== item,
              !FileManager.default.fileExists(atPath: item.url.path) else { return }
        stopFetch()
        let free = Transfer.macFreeSpace(at: FileManager.default.temporaryDirectory)
        guard entry.size <= free else {
            item.title = PreviewText.previewNoSpace(entry.name, needed: entry.size, available: free)
            item.gaveUp = true
            return
        }
        panelFetch = (item, onChange)
        done = 0
        item.title = PreviewText.fetching(entry.name, percent: 0)
        let folder = item.url.deletingLastPathComponent()
        task = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try await Transfer.fetch(entry.id, into: folder, session: session) { [self] n in
                    guard !Task.isCancelled else { return }
                    done += n
                    item.title = PreviewText.fetching(entry.name, percent: TransferText.percent(done: done, total: entry.size))
                    onChange(false)
                }
                try PreviewFiles.makeReadOnly(url)
                guard !Task.isCancelled else { return }
                copies[entry.id] = (entry.size, entry.modified, url)
                panelFetch = nil
                // Quick Look keeps the icon view it chose for the old object, so the real preview needs a new one.
                items[entry.id] = PreviewItem(url: url, title: entry.name)
                onChange(true)
            } catch {
                switch TransferEnd(error) {
                case .stopped:
                    return
                case let .failed(detail):
                    guard !Task.isCancelled else { return }     // a replaced fetch was already reset by stopFetch()
                    log.error("preview fetch failed: \(detail, privacy: .public)")
                    panelFetch = nil
                    item.gaveUp = true
                    item.title = PreviewText.previewFailed(entry.name, detail: detail)
                    onChange(false)
                case .lost:
                    if !Task.isCancelled { panelFetch = nil }
                    onSessionLost(error, session)
                }
            }
        }
    }

    /// Uncached and over `PreviewText.bigFile` with no Preview yet: the file asks before it's fetched (D-16).
    func needsQuestion(_ entry: ObjectEntry) -> Bool {
        entry.size > PreviewText.bigFile && !confirmed.contains(entry.id) && cachedCopy(entry) == nil
    }

    /// Preview in the list's alert, or Return in the panel (D-16).
    func confirm(_ handle: UInt32) {
        confirmed.insert(handle)
    }

    /// The panel closed (Space, Escape, D-15): its fetch stops, an Open's keeps running, and the next Space starts
    /// with fresh items.
    func endPreview() {
        if panelFetch != nil { stopFetch() }
        items = [:]
    }

    /// One file into its own new folder under the session folder; the status line follows its chunks.
    private func fetch(_ entry: ObjectEntry, session: DeviceSession) async throws -> URL {
        let folder = sessionFolder.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        done = 0
        status = PreviewText.opening(entry.name, percent: 0)
        return try await Transfer.fetch(entry.id, into: folder, session: session) { [self] n in
            guard !Task.isCancelled else { return }
            done += n
            status = PreviewText.opening(entry.name, percent: TransferText.percent(done: done, total: entry.size))
        }
    }
}
