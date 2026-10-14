import MTPKit
import SwiftUI

/// Every non-connected detail-pane state (D-09). Copy follows UI-SPEC C-01..C-16.
struct DetailStateView: View {
    enum Kind: Equatable {
        case noDevice, opening, busy(BusyScreen, owner: String?, app: String?), locked, failed(detail: String), listingFailed(detail: String)
        case selectStorage
        /// D-09: the selected storage is refused (0x2008/0x2013) or left the list; `detail` is nil when it left.
        case storageUnavailable(name: String, detail: String?)
    }

    let kind: Kind
    var retry: () -> Void = {}

    var body: some View {
        switch kind {
        case .noDevice:
            ContentUnavailableView {
                Label("No Android device found", systemImage: "smartphone")
            } description: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ConnectionText.steps.enumerated()), id: \.offset) { index, step in
                        // Number in its own column so a wrapped line hangs under the text, not the number.
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(index + 1).").monospacedDigit()
                            Text(step)
                        }
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 360)
            }
        case .opening:
            ContentUnavailableView {
                Label { Text("Connecting to your phone…") } icon: { ProgressView() }
            }
        case .busy(.otherOwner, let owner, _):                                                // C-07 / C-08 (D-04)
            state(title: owner.map { "Your phone is in use by \($0)" } ?? "Your phone is in use by another app",
                  icon: "hand.raised",
                  body: owner.map { "Quit \($0), and your phone connects on its own." }
                      ?? "Quit other apps that connect to phones, such as OpenMTP or Smart Switch, and your phone connects on its own.")
        case .busy(.cameraDaemonCanRelease, _, let app), .busy(.cameraDaemonReclaimed, _, let app),
             .busy(.cameraDaemonReleaseUnavailable, _, let app):
            // C-04 + C-06b. This build has no Release (spike decision guidance-only, AppModel.releaseSupported),
            // so BusyPolicy only yields cameraDaemonReleaseUnavailable; C-05/C-06 come back with a Release button.
            state(title: "Your phone is in use by the macOS camera service", icon: "hand.raised",
                  body: app.map { "\($0) may be using it. Quit \($0), and your phone connects on its own." }
                      ?? "Photos, Image Capture or Preview may be using it. Quit that app, and your phone connects on its own.")
        case .locked:
            state(title: "Can’t access device storage", icon: "lock",
                  body: "Unlock your phone and choose File Transfer. It connects on its own once unlocked.")
        case .failed(let detail):
            state(title: ConnectionText.connectFailedTitle, icon: "exclamationmark.triangle",
                  body: ConnectionText.retryBody, detail: detail)
        case .listingFailed(let detail):
            state(title: ConnectionText.lostContactTitle, icon: "exclamationmark.triangle",
                  body: ConnectionText.retryBody, detail: detail)
        case .storageUnavailable(let name, let detail):                                       // E-12 / E-13
            state(title: ConnectionText.storageUnavailableTitle, icon: "externaldrive.badge.exclamationmark",
                  body: ConnectionText.storageUnavailableBody(name), detail: detail)
        case .selectStorage:
            ContentUnavailableView("Select a storage", systemImage: "internaldrive")
        }
    }

    /// An error/busy state with one prominent, default-action Retry button (a manual nudge on the self-recovering
    /// locked and busy screens, D-33/D-34).
    private func state(title: String, icon: String, body: String, detail: String? = nil) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            VStack(spacing: 8) {
                Text(body)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 360)
        } actions: {
            HStack(spacing: 8) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
