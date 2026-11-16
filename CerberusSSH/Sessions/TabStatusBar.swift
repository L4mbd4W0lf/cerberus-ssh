import SwiftUI
import CerberusModels
import CerberusSSHCore

/// The one status bar under a tab's terminals (spec §4.4a). It describes the focused pane;
/// when the tab is split it also shows how many panes there are, and hovering that lists
/// every pane with its details.
struct TabStatusBar: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let tab: WorkspaceTab
    var onFocusPane: (SessionViewModel) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    // The list is drawn by this view rather than as a popover: a popover treats the first
    // click as "outside" and dismisses itself before the click can pin it.
    @State private var isOverBadge = false
    @State private var isOverList = false
    @State private var isPinned = false
    @State private var isShowingList = false
    @State private var hideTask: Task<Void, Never>?

    /// The most height the bar may take, however much it has to say.
    static let height: CGFloat = 24

    private var focused: SessionViewModel? { app.session(withID: tab.focusedSessionID) }
    private var panes: [SessionViewModel] { tab.layout.leaves.compactMap { app.session(withID: $0) } }

    var body: some View {
        HStack(spacing: 10) {
            if let session = focused { details(of: session) }
            Spacer(minLength: 4)
            if panes.count > 1 { paneCount }
            if let session = focused {
                trailing(of: session)
            }
        }
        .font(.caption)
        .lineLimit(1)   // everything in the bar stays on one line
        .padding(.horizontal, 10)
        // A fixed height: text is shortened (with …) rather than allowed to wrap and grow the
        // bar. The full text is in each item's tooltip.
        .frame(height: Self.height)
        .clipped()
        .background(.bar)
        .contentShape(Rectangle())
        // Drawn after the clip, so it can rise above the bar over the terminals.
        .overlay(alignment: .bottomTrailing) {
            if isShowingList && panes.count > 1 {
                paneList
                    .fixedSize()
                    .solidPanel(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 8, y: 2)
                    .padding(.trailing, 8)
                    .offset(y: -Self.height)
                    .onHover { isOverList = $0; refreshList() }
            }
        }
        .onChange(of: panes.count) { _, count in if count < 2 { isPinned = false; isShowingList = false } }
    }

    /// Shows the list while the pointer is on the badge or the list, or it has been pinned;
    /// hides it a moment after, so crossing the gap between them does not flicker it.
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

    // MARK: Pane count

    private var paneCount: some View {
        Label("\(panes.count) panes", systemImage: "rectangle.split.2x1")
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(isPinned ? AnyShapeStyle(Color.accentColor.fill(0.3, contrast)) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
            .onHover { isOverBadge = $0; refreshList() }
            // One click keeps the list open; another closes it.
            .onTapGesture { isPinned.toggle(); refreshList() }
            .accessibilityLabel("\(panes.count) panes. Show the list.")
            .accessibilityAddTraits(.isButton)
    }

    /// Every pane in the tab: its state, where it connects, and how long it has been up.
    private var paneList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panes) { session in
                let isFocused = session.id == tab.focusedSessionID
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: session.statusSymbol)
                        .foregroundStyle(session.statusColor)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(session.remoteTitle ?? session.title).fontWeight(isFocused ? .semibold : .regular)
                            if isFocused { Text("focused").font(.caption2).foregroundStyle(.secondary) }
                            if session.isRecording {
                                Image(systemName: "record.circle.fill").foregroundStyle(Color.statusBad).font(.caption2)
                            }
                        }
                        Text(session.endpointDescription).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(session.statusLabel)
                            if let detail = session.statusDetail { Text("— \(detail)").lineLimit(1) }
                            if let since = session.connectedSince {
                                Text("↑ \(Self.uptime(Date().timeIntervalSince(since)))").monospacedDigit()
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if app.isBroadcasting(tab: tab.id) {
                        Toggle("Broadcast", isOn: Binding(
                            get: { app.broadcastMembers(in: tab.id).contains(session.id) },
                            set: { _ in app.toggleBroadcastMembership(session, inTab: tab.id) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onFocusPane(session) }
            }
            Text(isPinned ? "Click the count again to close." : "Click the count to keep this open.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 300)
    }

    // MARK: The focused pane

    @ViewBuilder
    private func details(of session: SessionViewModel) -> some View {
        if let color = session.nodeColor { NodeColorMark(color: color, width: 3, height: 12) }
        // Shape and text as well as colour, so status never relies on colour alone.
        Image(systemName: session.statusSymbol)
            .foregroundStyle(session.statusColor)
        Text(session.statusLabel)
        if let detail = session.statusDetail {
            Text("— \(detail)")
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .help(detail)
        }
        if session.isRecording {
            Label(session.recordsInput ? "REC + input" : "REC", systemImage: "record.circle.fill")
                .foregroundStyle(Color.statusBad)
                .help(session.recordsInput
                      ? "This session is being recorded to an encrypted recording, including what you type (not at password prompts)"
                      : "This session is being recorded to an encrypted recording (what the server prints)")
        } else if let recordingError = session.recordingError {
            Label("Not recorded", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.statusWarning)
                .help(recordingError)
        }
        if let copyNotice = session.copyNotice {
            Label(copyNotice, systemImage: "doc.on.clipboard")
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
        if let forwardError = session.forwardError {
            Label(forwardError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.statusWarning)
                .help(forwardError)
        }
    }

    @ViewBuilder
    private func trailing(of session: SessionViewModel) -> some View {
        if !session.forwardPlans.isEmpty { forwardsMenu(session) }
        if let since = session.connectedSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("↑ \(Self.uptime(context.date.timeIntervalSince(since)))")
                    .monospacedDigit()
                    .help("Time connected")
            }
        }
        Text(session.endpointDescription)
            .foregroundStyle(.secondary)
            .truncationMode(.middle)
            .help("Who and where this session connects")
        if let fingerprint = session.hostKeyFingerprint {
            Label(String(fingerprint.prefix(18)) + "…", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
                .help("Host key \(fingerprint)")
        }
    }

    /// Start and stop this host's configured forwards, with live byte counts.
    private func forwardsMenu(_ session: SessionViewModel) -> some View {
        let enabled = session.forwardPlans.filter(\.isEnabled)
        return Menu {
            ForEach(session.forwardPlans) { plan in
                let running = session.isRunning(plan)
                Button {
                    Task { running ? await session.stopForward(plan) : await session.startForward(plan) }
                } label: {
                    Label(plan.title + (plan.isEnabled ? "" : "  (off)"), systemImage: running ? "checkmark.circle.fill" : (plan.isEnabled ? "circle" : "poweroff"))
                }
                .disabled(!session.isLive || !plan.isEnabled)
            }
            if !session.forwardStatuses.isEmpty {
                Divider()
                ForEach(session.forwardStatuses) { status in
                    Text("\(status.summary) — ↑\(Self.bytes(status.bytesSent)) ↓\(Self.bytes(status.bytesReceived)), \(status.activeConnections) open")
                }
            }
            Divider()
            Button("Manage Port Forwards…", systemImage: "slider.horizontal.3") { openWindow(id: ForwardsWindowID.id) }
        } label: {
            Label("\(session.forwardStatuses.count) of \(enabled.count) forwards", systemImage: "arrow.left.arrow.right")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private static func uptime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}
