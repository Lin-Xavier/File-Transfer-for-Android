import MTPKit
import SwiftUI

/// Finder's bottom bar under the file list (D-28): a clickable path bar above a centred status row, on Liquid
/// Glass (D-29, the user's chosen exception to "glass only on floating controls").
struct BottomBar: View {
    var storage: StorageInfo
    var path: [Crumb]
    var status: String
    /// 0 is the storage root, n the n-th crumb; never called for the folder you're in.
    var onSelectDepth: (Int) -> Void
    /// Stop for the transient Open status line (D-11); nil hides the button.
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            pathRow
            HStack(spacing: 4) {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
                    .accessibilityAddTraits(.updatesFrequently)
                if let onStop {
                    Button(action: onStop) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop")
                        .accessibilityLabel("Stop Opening")
                        .layoutPriority(1)   // the text truncates first; the button is never pushed out
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)   // a long Opening line kept its Stop in the window's rounded corner, where clicks missed
            .padding(.vertical, 3)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)   // S7: .secondary over glass measured 2.87:1 in light
        .glassEffect(.regular, in: .rect)
    }

    /// D-03: starts at the storage name; names are shown verbatim and truncated in the middle (T-02-07).
    private var pathRow: some View {
        HStack(spacing: 2) {
            crumb(depth: 0) {
                Label { Text(storage.displayName) } icon: { Image(systemName: storage.symbolName) }
            }
            .accessibilityLabel(storage.displayName)
            ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)   // S7: .tertiary chevrons measured 2.14:1
                    .accessibilityHidden(true)
                crumb(depth: index + 1) { Text(item.name) }
                    .accessibilityLabel(item.name)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 3)
    }

    private func crumb(depth: Int, @ViewBuilder label: () -> some View) -> some View {
        let isLast = depth == path.count
        return Button { if !isLast { onSelectDepth(depth) } } label: {
            label()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .layoutPriority(isLast ? 1 : 0)
    }
}

extension StorageInfo {
    /// The sidebar's and path bar's storage icon.
    var symbolName: String { isRemovable ? "sdcard" : "internaldrive" }
}
