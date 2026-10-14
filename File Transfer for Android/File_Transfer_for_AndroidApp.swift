//
//  File_Transfer_for_AndroidApp.swift
//  File Transfer for Android
//
//  Created by Xiang Lin on 9/28/26.
//

import MTPKit
import SwiftUI

@main
struct File_Transfer_for_AndroidApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The public repo's README, where the troubleshooting lives (D-04, D-25).
    static let helpURL = URL(string: "https://github.com/Lin-Xavier/File-Transfer-for-Android#readme")!

    private var isRenaming: Bool { model.browser?.isRenaming ?? false }

    var body: some Scene {
        // Closing the main window quits through RootView's close guard, which asks first while a copy runs
        // (D-11, P1 D-18); the Copy window would otherwise turn SwiftUI's close-to-quit off.
        Window("File Transfer for Android", id: "main") {
            RootView(model: model)
                // SwiftUI's own delegate proxies ours, so NSApp.delegate can't be cast to AppDelegate.
                .onAppear { appDelegate.transfers = model.transfers }
        }
        .defaultSize(width: 960, height: 600)
        .commands {
            // Every navigation shortcut has a menu item (D-05); each greys out when it can't act. While the rename
            // field is open they all do: menu shortcuts are matched before the field editor sees ⌘↑ / ⌘↓ (Pitfall 2).
            CommandGroup(after: .newItem) {
                Button("New Folder") { model.browser?.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!(model.browser?.canNewFolder ?? false))  // false while renaming or busy (D-18)
                // Same pickers as the toolbar (D-16); both are off while renaming, so they never fire in the name field.
                Button("Download to Mac") { model.browser?.requestDownload() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!(model.browser?.canDownload ?? false))   // needs a selection (D-20)
                Button("Upload to Android") { model.browser?.requestUpload() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!(model.browser?.canUpload ?? false))
                Button("Open") { model.browser?.openSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!(model.browser?.canOpenSelection ?? false) || isRenaming)
                Button(model.browser?.quickLookTitle ?? "Quick Look") { model.browser?.quickLook() }
                    .keyboardShortcut("y")
                    .disabled(!(model.browser?.canQuickLook ?? false) || isRenaming)
                Button("Rename") { model.browser?.beginRename() }
                    .disabled(!(model.browser?.canRename ?? false))       // false while renaming
                Button("Delete") { model.browser?.confirmDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!(model.browser?.canDelete ?? false))       // false while renaming or busy (D-18)
            }
            CommandGroup(after: .toolbar) {                 // View menu (D-05, D-16)
                Button("Refresh") { model.browser?.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.browser == nil || isRenaming || (model.browser?.isBusy ?? false))
            }
            // The Copy window hides on close and comes back only with the next job; this brings it back while any
            // row exists, failed rows included, so every copy can always be watched and stopped (D-01, D-05, D-12).
            CommandGroup(before: .windowList) {
                Button("Show Copy Window") { model.transfers.showWindow() }
                    .disabled(model.transfers.jobs.isEmpty)
            }
            CommandMenu("Go") {
                Button("Back") { model.browser?.back() }
                    .keyboardShortcut("[")
                    .disabled(!(model.browser?.canGoBack ?? false) || isRenaming)
                Button("Forward") { model.browser?.forward() }
                    .keyboardShortcut("]")
                    .disabled(!(model.browser?.canGoForward ?? false) || isRenaming)
                Button("Enclosing Folder") { model.browser?.up() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!(model.browser?.canGoUp ?? false) || isRenaming)
            }
            // D-04, UI-SPEC S2: replaces the system's "Help isn't available"; the search field stays.
            CommandGroup(replacing: .help) {
                Button("File Transfer for Android Help") {
                    if !NSWorkspace.shared.open(Self.helpURL) { NSSound.beep() }   // U2: no alert
                }
                // ponytail: on macOS 27 this registers no key equivalent and ⇧⌘/ opens the system Help search instead
                // (measured in 06-02); kept per UI-SPEC S2 in case a later SwiftUI honours it.
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Welcome to File Transfer for Android") { model.showWelcome = true }   // leaves WelcomeShown
            }
        }
    }
}
