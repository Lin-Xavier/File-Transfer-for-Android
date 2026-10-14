import MTPKit
import SwiftUI

/// The first-run welcome sheet (UI-SPEC S1, CONN-07). App icon and SF Symbols only (D-16); the Image Capture tip is
/// text only (D-03).
struct WelcomeView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(ConnectionText.welcomeTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ConnectionText.steps.enumerated()), id: \.offset) { index, step in
                    // Same hanging number as the no-device screen.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(index + 1).").monospacedDigit()
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                tip(ConnectionText.imageCaptureTip, symbol: "photo.on.rectangle")
                tip(ConnectionText.dragTip, symbol: "arrow.left.arrow.right")
            }
            HStack {
                Spacer()
                Button("Get started", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .presentationSizing(.fitted)
        .onExitCommand(perform: onDone)
    }

    private func tip(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
