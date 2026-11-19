import SwiftUI
import CerberusModels

/// The sidebar's Port Forwards tab: every forward that is switched on,
/// each with what it is doing. Starting one needs no terminal: with no session to the host open,
/// a connection is made for the forward alone.
struct SidebarForwardRows: View {
    let entries: [(host: SSHHost, forward: PortForward)]
    var selection: Set<UUID> = []
    let onEditHost: (SSHHost) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(entries, id: \.forward.id) { entry in
            row(entry.host, entry.forward)
        }
    }

    private func row(_ host: SSHHost, _ forward: PortForward) -> some View {
        let plan = AppModel.forwardPlans(for: host).first { $0.id == forward.id }
        let activity = app.activity(of: forward)
        // On the selection's blue block the status colours (a green on blue) can barely be seen: white then.
        let onHighlight = selection.contains(forward.id) && activeState != .inactive

        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(forward.kind))
                .foregroundStyle(onHighlight ? Color.onHighlight : (activity.isActive ? Color.statusGood : Color.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                if let name = forward.name {
                    Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text((plan?.summary ?? "") + "  ·  " + Self.caption(host: host, activity: activity))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(plan?.summary ?? "").font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(Self.caption(host: host, activity: activity)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing(forward, activity, onHighlight: onHighlight)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        // Simultaneous, so a single click never waits to see whether a second one follows.
        .simultaneousGesture(TapGesture(count: 2).onEnded { Task { await app.toggleForward(forward) } })
        .help(Self.tooltip(host: host, activity: activity))
        .contextMenu {
            Group {
                switch activity {
                case .inTerminal, .inTunnel:
                    Button("Stop", systemImage: "stop.fill") { Task { await app.toggleForward(forward) } }
                case .starting:
                    EmptyView()
                case .stopped, .failed:
                    Button("Start", systemImage: "play.fill") { Task { await app.toggleForward(forward) } }
                }
                Divider()
                Button("Edit \(host.displayLabel)…", systemImage: "pencil") { onEditHost(host) }
                Button("Show Port Forwards", systemImage: "arrow.left.arrow.right") { openWindow(id: ForwardsWindowID.id) }
            }
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private func trailing(_ forward: PortForward, _ activity: ForwardActivity, onHighlight: Bool) -> some View {
        switch activity {
        case .stopped:
            Button { Task { await app.toggleForward(forward) } } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("Start. No terminal is opened.").accessibilityLabel("Start this forward")
        case .starting:
            ProgressView().controlSize(.small)
        case .inTerminal, .inTunnel:
            Button { Task { await app.toggleForward(forward) } } label: {
                Label("Active", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(onHighlight ? Color.onHighlight : Color.statusGood)
            }
            .buttonStyle(.borderless).help("Active. Click to stop it.")
        case .failed(let message):
            Button { Task { await app.toggleForward(forward) } } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(onHighlight ? Color.onHighlight : Color.statusWarning)
            }
            .buttonStyle(.borderless).help("\(message)\nClick to try again.")
            .accessibilityLabel("This forward could not start. Try again.")
            .accessibilityHint(message)
        }
    }

    private static func symbol(_ kind: ForwardKind) -> String {
        switch kind {
        case .local: "arrow.right.circle"
        case .remote: "arrow.left.circle"
        case .dynamic: "network"
        }
    }

    private static func caption(host: SSHHost, activity: ForwardActivity) -> String {
        switch activity {
        case .stopped: host.displayLabel
        case .starting: "\(host.displayLabel) · connecting…"
        case .inTerminal: "\(host.displayLabel) · active in a terminal session"
        case .inTunnel: "\(host.displayLabel) · active, no terminal"
        case .failed: "\(host.displayLabel) · could not start"
        }
    }

    private static func tooltip(host: SSHHost, activity: ForwardActivity) -> String {
        switch activity {
        case .stopped: "Double-click to start. If \(host.displayLabel) has no session open, a connection is made for this forward alone: no terminal."
        case .starting: "Connecting to \(host.displayLabel)…"
        case .inTerminal(let session): "Already active in the terminal session to \(session.title). Double-click to stop it."
        case .inTunnel: "Active, on a connection with no terminal. It closes when the last forward on it stops. Double-click to stop."
        case .failed(let message): message
        }
    }
}

/// Shows the host-key and one-time-code questions of connections that have no terminal pane (and so
/// no pane to ask in), in the window the user is working in.
struct TunnelPromptHost: View {
    @Bindable var session: SessionViewModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $session.pendingHostKeyPrompt) { prompt in
                HostKeyPromptSheet(hostName: session.title, prompt: prompt) { trust in
                    session.answerHostKey(trust: trust)
                }
            }
            .sheet(item: $session.pendingKeyboardPrompt) { prompt in
                KeyboardInteractiveSheet(sessionTitle: session.title, prompt: prompt) { answers in
                    session.answerKeyboardPrompt(answers)
                }
            }
    }
}
