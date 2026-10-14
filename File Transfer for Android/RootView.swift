import AppKit
import MTPKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    /// A move's clash sheet while it is up, taken down if its browser goes away (a cable pull, D-35).
    @State private var moveAlert: NSAlert?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $model.selectedStorageID) {
                if model.phase == .connected {
                    Section(model.deviceName) {
                        ForEach(model.storages) { storage in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(storage.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(EntryFormat.bytes(storage.freeSpace)) available")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: storage.symbolName)
                            }
                            .tag(storage.id)
                            .accessibilityElement(children: .combine)
                            // D-32. The storage stays selected while browsing it (D-31).
                            .contextMenu {
                                Button("Refresh") { model.browser?.refresh(storage: storage.id) }
                                Button("Go to Root") {
                                    model.selectedStorageID = storage.id
                                    model.browser?.goToRoot(storage: storage.id)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .listItemTint(.monochrome)                    // only the spec'd accents are tinted (UI-REVIEW #3)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            // The system toggle hid in the overflow menu once the sidebar was collapsed; ours stays left of Back/Forward.
            .toolbar(removing: .sidebarToggle)
            .background(SidebarNarrowsList())
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation { columns = columns == .detailOnly ? .all : .detailOnly } } label: {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help(columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
            }
            // D-04: Finder's leading back/forward pair; no Up button (⌘↑ and the Go menu cover it).
            if model.phase == .connected, let browser = model.browser {
                ToolbarItem(placement: .navigation) {
                    ControlGroup("Back/Forward") {
                        Button { browser.back() } label: { Label("Back", systemImage: "chevron.backward") }
                            .disabled(!browser.canGoBack)
                            .help("Go back")
                        Button { browser.forward() } label: { Label("Forward", systemImage: "chevron.forward") }
                            .disabled(!browser.canGoForward)
                            .help("Go forward")
                    }
                    .controlGroupStyle(.navigation)     // one joined pill, and the only style SwiftUI keeps leading
                }
                // D-18, D-16: the action buttons, trailing as in Finder; the toolbar draws their glass.
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        .disabled(!browser.canNewFolder)
                        .help("New Folder")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.confirmDelete() } label: { Label("Delete", systemImage: "trash") }
                        .disabled(!browser.canDelete)
                        .help("Delete")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.requestDownload() } label: { Label("Download", systemImage: "iphone.and.arrow.right.outward") }
                        .disabled(!browser.canDownload)
                        .help("Download to Mac")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { browser.requestUpload() } label: { Label("Upload", systemImage: "iphone.and.arrow.right.inward") }
                        .disabled(!browser.canUpload)
                        .help("Upload to Android")
                }
            }
        }
        // D-25/D-26: Finder's plain sentence, then the small detail line (e.g. "MTP error 0x200F (Access Denied)").
        .alert(Text(verbatim: model.browser?.alert?.message ?? ""), isPresented: alertShown,
               presenting: model.browser?.alert) { _ in
            Button("OK") { model.browser?.alert = nil }
        } message: { alert in
            if let detail = alert.detail { Text(verbatim: detail) }
        }
        // D-35: a change cut short by an unplug, shown over the no-device screen.
        .alert(Text(verbatim: model.interruptedAlert ?? ""), isPresented: Binding(
            get: { model.interruptedAlert != nil },
            set: { if !$0 { model.dismissInterruptedAlert() } })) {
            Button("OK") {}
        }
        // End-of-job alerts naming every skipped or failed item, one at a time. OK only closes it: the binding's
        // setter pops the alert, so a second pop in the button would drop the next one.
        .alert(Text(verbatim: model.transfers.alerts.first?.message ?? ""), isPresented: Binding(
            get: { !model.transfers.alerts.isEmpty },
            set: { if !$0 { model.transfers.dismissAlert() } }),
               presenting: model.transfers.alerts.first) { _ in
            Button("OK") {}
        } message: { alert in
            if let detail = alert.detail { Text(verbatim: detail) }
        }
        // An Open fetch that failed (D-19): the plain sentence and the MTP code line; the other files carry on.
        .alert(Text(verbatim: model.previews.alert?.message ?? ""), isPresented: Binding(
            get: { model.previews.alert != nil },
            set: { if !$0 { model.previews.alert = nil } }),
               presenting: model.previews.alert) { _ in
            Button("OK") { model.previews.alert = nil }
        } message: { alert in
            if let detail = alert.detail { Text(verbatim: detail) }
        }
        .onChange(of: model.browser?.pickerRequest) { _, request in
            if let request { presentPicker(request) }
        }
        // D-23: blocking while a delete runs; single-item deletes use it too.
        .sheet(isPresented: deleteSheetShown) { deleteProgressSheet }
        // S1: one onDismiss covers Get started, Return and Escape.
        .sheet(isPresented: $model.showWelcome, onDismiss: { UserDefaults.standard.set(true, forKey: "WelcomeShown") }) {
            WelcomeView { model.showWelcome = false }
        }
        .onChange(of: model.browser?.deleteConfirmation) { _, text in
            if let text, let browser = model.browser { askDelete(text, browser) }
        }
        // D-12: a move has no Copy-window row, so its clash sheet drops from the main window.
        .onChange(of: model.browser?.moveQuestion) { _, question in
            guard let question else {
                if let alert = moveAlert { alert.window.sheetParent?.endSheet(alert.window) }
                return
            }
            guard let browser = model.browser else { return }
            // mainWindow is nil while the app is inactive (the plan can outlast a switch to Finder); CopyWindow can't
            // become main, so the fallback is always the browser window.
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.canBecomeMain) else {
                return browser.answerMove(.stop)
            }
            Task {                                  // ClashSheet raises an inactive app's window (G-05-14)
                let reply = await ClashSheet.present(question.clash, verb: "moving", on: window) { moveAlert = $0 }
                moveAlert = nil
                browser.answerMove(reply)
            }
        }
        .onChange(of: model.selectedStorageID) { model.storageChanged() }
        .task { await model.start() }
        // D-02: the open folder's name; at a storage root, the storage name.
        .navigationTitle(titledStorage.map { model.browser?.location.path.last?.name ?? $0.displayName }
                         ?? "File Transfer for Android")
        .navigationSubtitle(titledStorage != nil ? model.deviceName : "")
        .frame(minWidth: 780, minHeight: 440)       // 320 pt sidebar + three columns' minimums fit
        .background(CloseGuardInstaller(queue: model.transfers))   // D-11: ⌘W and the red button ask first
    }

    /// The storage the title names: none while the storage-unavailable state shows, refused or gone (UI-SPEC S3).
    private var titledStorage: StorageInfo? {
        model.browser?.failure?.isStorageUnavailable == true ? nil : model.selectedStorage
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.browser?.alert != nil }, set: { if !$0 { model.browser?.alert = nil } })
    }

    private var deleteSheetShown: Binding<Bool> {
        Binding(get: { model.browser?.deleteProgress != nil }, set: { _ in })   // only the model ends it
    }

    private var deleteProgressSheet: some View {
        let progress = model.browser?.deleteProgress
        return VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: progress?.title ?? "\(progress?.verb ?? "Deleting") “\(progress?.currentName ?? "")”…")
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView()
                .progressViewStyle(.linear)
            HStack {
                Spacer()
                Button("Stop") { model.browser?.stopDelete() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress?.stopRequested ?? true)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled()
    }

    /// Finder's permanent-delete sheet (D-22): Cancel is the default, Delete is red and only a click deletes.
    /// NSAlert gives a button titled Cancel the Escape key and no button Return, so Cancel takes Return explicitly
    /// and Escape is kept by a key monitor scoped to the sheet (G-02-5). SwiftUI's alert can't pick the default
    /// button, hence NSAlert (RESEARCH Alternatives).
    private func askDelete(_ text: AlertText, _ browser: BrowserModel) {
        // The main window, not the key one: an About panel can be key (IN-06).
        guard let window = NSApp.mainWindow else { browser.cancelDelete(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.detail ?? ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if let escape { NSEvent.removeMonitor(escape) }
            if response == .alertSecondButtonReturn {
                browser.performDelete()
            } else {
                browser.cancelDelete()
            }
        }
    }

    /// The pickers, as sheets on the browser window (RESEARCH Pattern 6). Download to…'s folder picker opens in the last
    /// folder used while that still exists, else ~/Downloads (D-17); a path string is enough with the sandbox off.
    /// Upload…'s takes files and folders together, packages as single items (D-14, D-19).
    /// The request's handles belong to the browser's session now, which may be replaced while the panel is open (CR-02).
    private func presentPicker(_ request: BrowserModel.PickerRequest) {
        guard let window = NSApp.mainWindow, let origin = model.browser?.session else { return }
        switch request.kind {
        case let .download(entries, paths):
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Download"
            var isFolder: ObjCBool = false
            if let saved = UserDefaults.standard.string(forKey: "DownloadFolder"),
               FileManager.default.fileExists(atPath: saved, isDirectory: &isFolder), isFolder.boolValue {
                panel.directoryURL = URL(filePath: saved)
            } else {
                panel.directoryURL = .downloadsDirectory
            }
            Task {
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(url.path, forKey: "DownloadFolder")
                model.download(entries, paths: paths, to: url, from: origin)
            }
        case let .upload(key, name, path):
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.treatsFilePackagesAsDirectories = false
            panel.prompt = "Upload"
            let label = name ?? model.selectedStorage?.displayName ?? ""
            Task {
                guard await panel.beginSheetModal(for: window) == .OK, !panel.urls.isEmpty else { return }
                model.upload(panel.urls, into: key, name: label, path: path, from: origin)
            }
        }
    }

    /// Centred over the list so the column headers stay visible.
    @ViewBuilder private func listOverlay(_ browser: BrowserModel) -> some View {
        if browser.currentEntries.isEmpty {
            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading files")
            } else {
                Text(browser.location.path.isEmpty ? "This storage is empty" : "This folder is empty")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .noDevice:
            DetailStateView(kind: .noDevice)
        case .opening:
            DetailStateView(kind: .opening)
        case .claimed(let screen):
            DetailStateView(kind: .busy(screen, owner: model.ownerDisplayName(screen), app: model.photoAppName),
                            retry: model.retry)
        case .locked:
            DetailStateView(kind: .locked, retry: model.retry)
        case .failed(let detail):
            DetailStateView(kind: .failed(detail: detail), retry: model.retry)
        case .connected:
            if let gone = model.unavailableStorage {                                         // D-09, E-12/E-13
                DetailStateView(kind: .storageUnavailable(name: gone.displayName, detail: nil), retry: model.refreshStorages)
            } else if model.selectedStorage == nil {
                DetailStateView(kind: .selectStorage)
            } else if let storage = model.selectedStorage, let browser = model.browser {
                if let failure = browser.failure {
                    if failure.isStorageUnavailable {
                        DetailStateView(kind: .storageUnavailable(name: storage.displayName, detail: failure.detail),
                                        retry: { model.refreshStorages(); browser.reload() })
                    } else {
                        DetailStateView(kind: .listingFailed(detail: failure.detail), retry: browser.reload)
                    }
                } else {
                    FileListView(snapshot: browser.snapshot, browser: browser, model: model)
                        // The empty-folder text must not catch a drag into an empty folder (Pitfall 6).
                        .overlay { listOverlay(browser).allowsHitTesting(false) }
                        // D-30: total = the opened folder's direct items; selected = every selected visible row.
                        .safeAreaBar(edge: .bottom, spacing: 0) {
                            BottomBar(storage: storage, path: browser.location.path,
                                      // The transient “Opening …” line replaces the counts while it runs.
                                      status: model.previews.status ?? StatusLine.text(itemCount: browser.currentEntries.count,
                                                              selectedCount: browser.selection.count,
                                                              freeSpace: storage.freeSpace,
                                                              loadingCount: browser.loadingCount),
                                      onSelectDepth: browser.goTo(depth:),
                                      onStop: model.previews.status == nil ? nil : { model.previews.cancel() })
                        }
                }
            }
        }
    }
}

/// Showing the sidebar narrows the list, as hiding it widens it. By default AppKit pins the list's width while the sidebar
/// slides in and grows the split view past the window, so the list slid sideways, then snapped into place. SwiftUI has
/// no setting for the split view item's collapse behavior.
private struct SidebarNarrowsList: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let split = sequence(first: self as NSView, next: \.superview).lazy.compactMap { $0 as? NSSplitView }.first
            (split?.delegate as? NSSplitViewController)?.splitViewItems.first?.collapseBehavior = .useConstraints
        }
    }
}
