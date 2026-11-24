import SwiftUI
import CerberusSSHCore

/// The bar under a file tab, like the one under a terminal tab: how each pane's connection is doing, and what is
/// selected. The transfers are in the window's toolbar (``TransfersButton``).
struct FileTabStatusBar: View {
    let tab: FileTabModel

    var body: some View {
        // Each pane's status under its own side, the right one mirrored, with what is selected between them.
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                paneStatus(tab.left)
                Spacer(minLength: 4)
                if let summary = selectionSummary { Text(summary).foregroundStyle(.secondary).accessibilityIdentifier("files-selection-summary") }
            }
            .frame(maxWidth: .infinity)
            paneStatus(tab.right, mirrored: true).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: TabStatusBar.height)
        .clipped()
        .background(.bar)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-status-bar")
    }

    // MARK: Selection

    /// What is selected in the pane that has focus: how many items and, for the files among them, how big.
    /// A folder has no size of its own here, so it counts as an item but adds nothing to the total.
    private var selectionSummary: String? {
        let chosen = tab.focusedPane.selectedEntries
        guard !chosen.isEmpty else { return nil }
        let count = chosen.count == 1 ? "1 item selected" : "\(chosen.count) items selected"
        let bytes = chosen.filter { !$0.isDirectory }.compactMap(\.size).reduce(0, +)
        return bytes > 0 ? "\(count) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))" : count
    }

    // MARK: Panes

    /// Shape and text as well as colour, so status never relies on colour alone. Only the place, not the folder: the
    /// pane shows that above. `mirrored` (the right pane) lays the parts out from the right edge in, icon outermost.
    private func paneStatus(_ pane: FilePaneModel, mirrored: Bool = false) -> some View {
        HStack(spacing: 5) {
            // The stack takes the mirrored direction for its order; each part keeps left to right for its text, or
            // "connecting…" would read "…connecting".
            Group { paneStatusParts(pane) }.environment(\.layoutDirection, .leftToRight)
        }
        .environment(\.layoutDirection, mirrored ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paneStatusParts(_ pane: FilePaneModel) -> some View {
        switch pane.phase {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
        case .ready:
            Image(systemName: pane.source == .local ? "laptopcomputer" : "checkmark.circle.fill")
                .foregroundStyle(pane.source == .local ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.statusGood))
        }
        Text(pane.source.title).fontWeight(.medium)
        switch pane.phase {
        case .connecting:
            Text("connecting…").foregroundStyle(.secondary)
        case .failed(let message):
            Text("not connected").foregroundStyle(Color.statusWarning).help(message)
        case .ready:
            if let info = pane.info {
                Text("connected").foregroundStyle(.secondary)
                Text(info.endpoint).foregroundStyle(.secondary).truncationMode(.middle).help("Who and where this connection goes")
                if let note = info.note {
                    Text(note).foregroundStyle(Color.statusWarning)
                        .help("This server has no SFTP, so its files are listed and copied through its shell: it works, but slowly, one thing at a time.")
                }
                if let since = info.connectedSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("↑ \(Self.uptime(context.date.timeIntervalSince(since)))").monospacedDigit().help("Time connected")
                    }
                }
                if let fingerprint = info.hostKeyFingerprint {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Host key \(fingerprint)")
                }
            }
        }
    }

    private static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
