import SwiftUI
import CerberusSSHCore

/// The bar under a file tab, like the one under a terminal tab: how each pane's connection is doing,
/// and a transfers badge whose list rises above the bar while the pointer is on it, or stays once
/// clicked. The badge carries a radial progress, so a transfer in progress is seen at a glance.
struct FileTabStatusBar: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let tab: FileTabModel

    // Drawn by this view rather than as a popover: a popover treats the first click as "outside" and
    // dismisses itself before the click can pin it (the terminal tab's bar does the same).
    @State private var isOverBadge = false
    @State private var isOverList = false
    @State private var isPinned = false
    @State private var isShowingList = false
    @State private var hideTask: Task<Void, Never>?

    private var queue: TransferQueue { tab.queue }

    var body: some View {
        // Each pane's status under its own side, the right one mirrored, and the transfers in the middle, with what is
        // selected just before them. The sides take equal shares of what is left, so the middle stays centred.
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                paneStatus(tab.left)
                Spacer(minLength: 4)
                if let summary = selectionSummary { Text(summary).foregroundStyle(.secondary).accessibilityIdentifier("files-selection-summary") }
            }
            .frame(maxWidth: .infinity)
            if !queue.jobs.isEmpty { transfersBadge.fixedSize() }
            paneStatus(tab.right, mirrored: true).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: TabStatusBar.height)
        .clipped()
        .background(.bar)
        .contentShape(Rectangle())
        // Above the badge, in the middle.
        .overlay(alignment: .bottom) {
            if isShowingList && !queue.jobs.isEmpty {
                TransferPanel(queue: queue)
                    .frame(width: 620)
                    .solidPanel(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 8, y: 2)
                    .offset(y: -TabStatusBar.height)
                    .onHover { isOverList = $0; refreshList() }
            }
        }
        .onChange(of: queue.jobs.isEmpty) { _, empty in if empty { isPinned = false; isShowingList = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-status-bar")
    }

    /// Shows the list while the pointer is on the badge or the list, or it has been pinned; hides it a
    /// moment after, so crossing the gap between them does not flicker it.
    private func refreshList() {
        hideTask?.cancel()
        if isOverBadge || isOverList || isPinned {
            isShowingList = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                if !Task.isCancelled { isShowingList = false }
            }
        }
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
                .foregroundStyle(pane.source == .local ? Color.secondary : Color.statusGood)
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

    // MARK: Transfers

    private var transfersBadge: some View {
        let active = queue.activeCount
        return HStack(spacing: 5) {
            if active > 0 {
                RadialProgress(fraction: queue.overallFraction)
                Text(active == 1 ? "1 transfer" : "\(active) transfers")
                if let fraction = queue.overallFraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
            } else if queue.problemCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
                Text("\(queue.problemCount) with problems")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusGood)
                Text("Transfers done")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(isPinned ? AnyShapeStyle(Color.accentColor.fill(0.3, contrast)) : AnyShapeStyle(.quaternary), in: Capsule())
        .contentShape(Capsule())
        .onHover { isOverBadge = $0; refreshList() }
        // One click keeps the list open; another closes it.
        .onTapGesture { isPinned.toggle(); refreshList() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active > 0 ? "\(active) transfers in progress. Show the list." : "Transfers finished. Show the list.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("files-transfers-badge")
    }

    private static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A small ring that fills as a transfer goes; a spinner while the amount is not yet known.
struct RadialProgress: View {
    let fraction: Double?

    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The transfers: what is running, what is waiting and what finished, each with progress and a cancel button.
private struct TransferPanel: View {
    let queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.jobs.contains { $0.isFinished })
                    .accessibilityIdentifier("files-clear-finished")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(queue.jobs) { job in
                        TransferRow(job: job) { queue.cancel(job) }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-transfers")
    }
}
