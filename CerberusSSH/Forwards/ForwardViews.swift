import SwiftUI
import SwiftData
import CerberusModels
import CerberusSSHCore

// MARK: - A forward being edited

/// A port forward as it is being typed in, before it is saved.
struct ForwardDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: ForwardKind = .local
    var bindAddress = "127.0.0.1"
    var bindPort = 8080
    var destinationHost = "localhost"
    var destinationPort = 80
    var autoStart = false
    var isEnabled = true
    /// Empty means no name.
    var name = ""

    init() {}

    init(_ forward: PortForward) {
        id = forward.id
        kind = forward.kind
        bindAddress = forward.bindAddress
        bindPort = forward.bindPort
        destinationHost = forward.destinationHost ?? ""
        destinationPort = forward.destinationPort ?? 0
        autoStart = forward.autoStart
        isEnabled = forward.isEnabled
        name = forward.name ?? ""
    }

    var problem: String? {
        ForwardCheck.problem(
            kind: kind, bindAddress: bindAddress, bindPort: bindPort,
            destinationHost: destinationHost, destinationPort: destinationPort
        )
    }

    func apply(to forward: PortForward) {
        forward.kind = kind
        forward.bindAddress = bindAddress.trimmingCharacters(in: .whitespaces)
        forward.bindPort = bindPort
        forward.destinationHost = kind == .dynamic ? nil : destinationHost.trimmingCharacters(in: .whitespaces)
        forward.destinationPort = kind == .dynamic ? nil : destinationPort
        forward.autoStart = autoStart
        forward.isEnabled = isEnabled
        forward.name = TabName.normalised(name)
    }
}

/// The fields of one forward: on or off, type, where it listens, where it goes.
struct ForwardFields: View {
    @Binding var forward: ForwardDraft
    var onRemove: (() -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var listenLabel: String { forward.kind == .remote ? "Server listens on" : "Listen on (this Mac)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Controls inside a Form take its label column, which is what mangled this layout:
                // their own titles are hidden and the words are drawn here.
                Toggle("On", isOn: $forward.isEnabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help("Switch off to keep this forward without using it")
                Picker("Type", selection: $forward.kind) {
                    Text("Local (-L)").tag(ForwardKind.local)
                    Text("Remote (-R)").tag(ForwardKind.remote)
                    Text("Dynamic SOCKS5 (-D)").tag(ForwardKind.dynamic)
                }
                .labelsHidden().fixedSize()
                .help("Local (-L): a port on this Mac leads through the server.\nRemote (-R): a port on the server leads back here.\nDynamic (-D): a SOCKS5 proxy on this Mac.")
                Spacer()
                Toggle("Start automatically", isOn: $forward.autoStart).toggleStyle(.checkbox).fixedSize()
                    .help("Starts this forward by itself every time you connect to this host. Leave it off to start it yourself, from the status bar or the Port Forwards window.")
                Button { app.helpPage = .forwarding; openWindow(id: HelpWindow.id) } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless).help("Explain port forwarding").accessibilityLabel("Explain port forwarding")
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Delete this forward")
                }
            }
            // One grid, so the labels, the two text fields and the ports line up in both rows.
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                GridRow {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional, to tell it apart (e.g. Staging database)", text: $forward.name).labelsHidden()
                        .gridCellColumns(3)
                }
                GridRow {
                    Text(listenLabel).font(.caption).foregroundStyle(.secondary)
                    TextField("Address", text: $forward.bindAddress).labelsHidden()
                    Text(":").foregroundStyle(.secondary)
                    TextField("Port", value: $forward.bindPort, format: .number.grouping(.never)).labelsHidden()
                        .frame(width: 80)
                }
                if forward.kind != .dynamic {
                    GridRow {
                        Text(forward.kind == .remote ? "Connect to (from here)" : "Go to (via server)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Host", text: $forward.destinationHost).labelsHidden()
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", value: $forward.destinationPort, format: .number.grouping(.never)).labelsHidden()
                            .frame(width: 80)
                    }
                }
            }
            Text(ForwardCheck.explanation(
                kind: forward.kind, bindAddress: forward.bindAddress, bindPort: forward.bindPort,
                destinationHost: forward.destinationHost, destinationPort: forward.destinationPort
            ))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = forward.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.statusBad)
            } else if let caution = ForwardCheck.caution(kind: forward.kind, bindAddress: forward.bindAddress) {
                Label(caution, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.statusWarning)
            }
        }
        .textFieldStyle(.roundedBorder)
        .opacity(forward.isEnabled ? 1 : 0.6)
    }
}

// MARK: - Adding or editing one forward

struct ForwardEditorSheet: View {
    let host: SSHHost
    /// `nil` adds a new forward.
    let forward: PortForward?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var draft = ForwardDraft()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(forward == nil ? "New forward for \(host.displayLabel)" : "Forward for \(host.displayLabel)") {
                    ForwardFields(forward: $draft)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(forward == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(draft.problem != nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 360)
        .onAppear { if let forward { draft = ForwardDraft(forward) } }
    }

    private func save() {
        let target = forward ?? PortForward(host: host)
        if forward == nil { modelContext.insert(target) }
        draft.apply(to: target)
        modelContext.saveLogged()
        app.refreshForwards(for: host)
        dismiss()
    }
}

// MARK: - The Forwards window

/// Every port forward of every host, with a switch on each, so a forward can be kept without
/// being used and turned on when it is wanted.
struct ForwardsWindow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]

    private struct EditRequest: Identifiable { let id = UUID(); let host: SSHHost; let forward: PortForward? }
    @State private var editing: EditRequest?

    private var hostsWithForwards: [SSHHost] { hosts.filter { !($0.portForwards ?? []).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forwards stay saved when switched off, and are started or stopped with the switch.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Add Forward", systemImage: "plus") {
                    ForEach(hosts) { host in
                        Button(host.displayLabel) { editing = EditRequest(host: host, forward: nil) }
                    }
                }
                .disabled(hosts.isEmpty)
                Button { app.helpPage = .forwarding; openWindow(id: HelpWindow.id) } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless).help("Explain port forwarding").accessibilityLabel("Explain port forwarding")
            }
            .padding(12)
            Divider()

            if hostsWithForwards.isEmpty {
                ContentUnavailableView(
                    "No port forwards", systemImage: "arrow.left.arrow.right",
                    description: Text("Add one here, or in a host's settings. A forward is a tunnel: a port on this Mac that leads through the server (-L, -D), or a port on the server that leads back here (-R).")
                )
            } else {
                List {
                    ForEach(hostsWithForwards) { host in
                        Section {
                            ForEach(forwards(of: host)) { forward in row(forward, host: host) }
                        } header: {
                            hostHeader(host)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .sheet(item: $editing) { ForwardEditorSheet(host: $0.host, forward: $0.forward) }
    }

    private func forwards(of host: SSHHost) -> [PortForward] {
        (host.portForwards ?? []).sorted { ($0.kindRawValue, $0.bindPort) < ($1.kindRawValue, $1.bindPort) }
    }

    /// A session or tunnel to this host that is up, if there is one; forwards run on it.
    private func liveSession(for host: SSHHost) -> SessionViewModel? {
        (app.sessions + app.tunnels).first { $0.hostID == host.id && $0.isLive }
    }

    private func hostHeader(_ host: SSHHost) -> some View {
        HStack {
            HStack(spacing: 6) {
                HostOSIcon(os: host.detectedOS).frame(width: 16, height: 16)
                Text(host.displayLabel)
            }
            Spacer()
            if liveSession(for: host) != nil {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.statusGood).font(.caption)
            } else {
                Text("No session open: Start connects for the forward alone").font(.caption).foregroundStyle(.secondary)
            }
            Button("Add", systemImage: "plus") { editing = EditRequest(host: host, forward: nil) }
                .buttonStyle(.borderless).help("Add a forward to \(host.displayLabel)")
        }
    }

    private func row(_ forward: PortForward, host: SSHHost) -> some View {
        let plan = AppModel.forwardPlans(for: host).first { $0.id == forward.id }
        let activity = app.activity(of: forward)
        var owner: SessionViewModel?
        var whereText = ""
        switch activity {
        case .inTerminal(let session): owner = session; whereText = "in a terminal session"
        case .inTunnel(let tunnel): owner = tunnel; whereText = "no terminal"
        default: break
        }
        let status = plan.flatMap { owner?.status(for: $0) }

        return HStack(spacing: 12) {
            Toggle("On", isOn: Binding(get: { forward.isEnabled }, set: { app.setForward(forward, enabled: $0) }))
                .toggleStyle(.switch).labelsHidden()
                .help(forward.isEnabled ? "Switch off to stop it and keep it for later" : "Switch on to use it")
            Image(systemName: Self.symbol(forward.kind)).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let name = forward.name { Text(name).font(.body.weight(.medium)) }
                Text(plan?.summary ?? "").font(.system(forward.name == nil ? .body : .callout, design: .monospaced))
                    .foregroundStyle(forward.name == nil ? .primary : .secondary)
                Text(Self.kindName(forward.kind) + (forward.autoStart ? " · starts automatically" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !forward.isEnabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            } else {
                switch activity {
                case .inTerminal, .inTunnel:
                    VStack(alignment: .trailing, spacing: 1) {
                        Label("Active · \(whereText)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.statusGood).font(.caption)
                        if let status {
                            Text("↑\(Self.bytes(status.bytesSent)) ↓\(Self.bytes(status.bytesReceived)) · \(status.activeConnections) open")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                case .starting:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…").font(.caption).foregroundStyle(.secondary) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning).font(.caption).lineLimit(2)
                        .frame(maxWidth: 240, alignment: .trailing)
                case .stopped:
                    EmptyView()
                }
            }
            if forward.isEnabled {
                switch activity {
                case .starting:
                    EmptyView()
                case .inTerminal, .inTunnel:
                    Button("Stop", systemImage: "stop.fill") { Task { await app.toggleForward(forward) } }.controlSize(.small)
                case .stopped, .failed:
                    Button("Start", systemImage: "play.fill") { Task { await app.toggleForward(forward) } }.controlSize(.small)
                }
            }
            Button("Edit…", systemImage: "pencil") { editing = EditRequest(host: host, forward: forward) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .opacity(forward.isEnabled ? 1 : 0.6)
        .contextMenu {
            Group {
                Button("Edit…", systemImage: "pencil") { editing = EditRequest(host: host, forward: forward) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(forward, from: host) }
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func delete(_ forward: PortForward, from host: SSHHost) {
        modelContext.delete(forward)
        modelContext.saveLogged()
        app.refreshForwards(for: host)
    }

    private static func symbol(_ kind: ForwardKind) -> String {
        switch kind {
        case .local: "arrow.right.circle"
        case .remote: "arrow.left.circle"
        case .dynamic: "network"
        }
    }

    private static func kindName(_ kind: ForwardKind) -> String {
        switch kind {
        case .local: "Local (-L): a port here leads through the server"
        case .remote: "Remote (-R): a port on the server leads back here"
        case .dynamic: "Dynamic (-D): a SOCKS5 proxy here"
        }
    }

    private static func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary) }
}
