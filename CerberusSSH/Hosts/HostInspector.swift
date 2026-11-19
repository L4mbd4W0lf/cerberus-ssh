import SwiftUI
import SwiftData
import CerberusModels

/// The right-hand inspector (⌥⌘I): details of the selected host, with connect and
/// edit buttons. With several hosts selected it offers bulk edit instead.
struct HostInspector: View {
    let hosts: [SSHHost]
    let onEdit: (SSHHost) -> Void
    let onConnect: (SSHHost) -> Void
    let onBulkEdit: () -> Void

    @Query private var allHosts: [SSHHost]
    @Query private var knownKeys: [KnownHostKey]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// What is known about the key of `host`: trusted, not yet trusted, or revoked.
    private func trust(of host: SSHHost) -> HostTrust.Status {
        HostTrust.status(of: knownKeys.filter { $0.hostPattern == host.hostKeyPattern }.map {
            HostTrust.Key(keyType: $0.keyType, fingerprintSHA256: $0.fingerprintSHA256, addedAt: $0.addedAt,
                          source: $0.source, revoked: $0.revoked)
        })
    }

    var body: some View {
        Group {
            if hosts.isEmpty {
                ContentUnavailableView(
                    "No host selected",
                    systemImage: "sidebar.right",
                    description: Text("Select a host in the sidebar to see its details.")
                )
            } else if hosts.count > 1 {
                multiple
            } else if let host = hosts.first {
                single(host)
            }
        }
    }

    // MARK: Several hosts

    private var multiple: some View {
        Form {
            Section("\(hosts.count) hosts selected") {
                ForEach(hosts.sorted { $0.displayLabel < $1.displayLabel }) { host in
                    Text(host.displayLabel)
                }
            }
            Section {
                Button("Edit \(hosts.count) Hosts…", systemImage: "pencil", action: onBulkEdit)
                Text("Change their folder, tags or identity together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: One host

    private func favouriteButton(_ host: SSHHost) -> some View {
        let title = SidebarActions.favouriteTitle(count: 1, adds: !host.isFavourite)
        return Button {
            host.isFavourite.toggle()
            modelContext.saveLogged()
        } label: {
            Image(systemName: host.isFavourite ? "star.fill" : "star")
                .foregroundStyle(host.isFavourite ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("inspector-favourite")
        .accessibilityAddTraits(host.isFavourite ? .isSelected : [])
    }

    private func single(_ host: SSHHost) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    HostOSIcon(os: host.detectedOS).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.displayLabel).font(.title3.bold())
                        Text("\(host.hostname):\(host.port)").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    favouriteButton(host)
                }
                HStack {
                    Button("Connect", systemImage: "bolt.fill") { onConnect(host) }
                        .disabled(!host.hasLogin)
                    Button("Edit…", systemImage: "pencil") { onEdit(host) }
                }
            }

            Section("Sign-in") {
                if let identity = host.liveIdentity {
                    LabeledContent("User", value: identity.username)
                    LabeledContent("Method", value: identity.kind.displayName)
                    if let algorithm = identity.keyAlgorithm { LabeledContent("Key", value: algorithm) }
                    if let fingerprint = identity.publicKeyFingerprint {
                        LabeledContent("Fingerprint") {
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                } else if host.usesNoAuthentication {
                    LabeledContent("User", value: host.noAuthenticationUsername ?? "")
                    LabeledContent("Method", value: "None (no authentication)")
                } else {
                    Label("No identity assigned", systemImage: "exclamationmark.triangle").foregroundStyle(Color.statusWarning)
                }
            }

            hostKeySection(host)

            Section("Organisation") {
                LabeledContent("Tags") {
                    if host.tags.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        Text(host.tags.map { "#\($0)" }.joined(separator: " "))
                    }
                }
            }

            Section("Route") {
                let names = host.jumpHostIDs.map { id in allHosts.first { $0.id == id }?.displayLabel ?? "Missing host" }
                if names.isEmpty {
                    Text("Direct connection").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        LabeledContent("Hop \(index + 1)", value: name)
                    }
                    LabeledContent("Target", value: host.displayLabel)
                }
            }

            let forwards = host.portForwards ?? []
            if !forwards.isEmpty {
                Section("Port forwarding") {
                    ForEach(forwards.sorted { ($0.kindRawValue, $0.bindPort) < ($1.kindRawValue, $1.bindPort) }) { forward in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                if let name = forward.name { Text(name) }
                                Text(summary(forward)).font(forward.name == nil ? .body : .caption)
                                Text(forward.isEnabled
                                     ? (forward.autoStart ? "Starts automatically" : "Start from the status bar")
                                     : "Switched off")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("On", isOn: Binding(get: { forward.isEnabled }, set: { app.setForward(forward, enabled: $0) }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                        .opacity(forward.isEnabled ? 1 : 0.6)
                    }
                    Button("Manage Port Forwards…", systemImage: "arrow.left.arrow.right") { openWindow(id: ForwardsWindowID.id) }
                }
            }

            Section("System") {
                if let os = host.detectedOS {
                    LabeledContent("Operating system", value: os.displayName)
                    if let version = host.detectedOSVersion, version != os.displayName { LabeledContent("Version", value: version) }
                } else {
                    Text("Found out the next time you connect").foregroundStyle(.secondary)
                }
            }

            Section("Session") {
                LabeledContent("Terminal", value: host.terminalType)
                LabeledContent("Keepalive", value: host.keepAliveInterval == 0 ? "Off" : "\(host.keepAliveInterval) s")
                LabeledContent("Reconnect", value: host.autoReconnect ? "Automatic" : "Manual")
                if let command = host.initialCommand { LabeledContent("Runs", value: command) }
                if !host.environment.isEmpty { LabeledContent("Environment", value: "\(host.environment.count) variables") }
            }

            Section("Usage") {
                LabeledContent("Connections", value: "\(host.connectionCount)")
                LabeledContent("Last connected") {
                    if let last = host.lastConnectedAt {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
            }

            if let notes = host.notes, !notes.isEmpty {
                Section("Notes") { Text(notes).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Host key

    @ViewBuilder
    private func hostKeySection(_ host: SSHHost) -> some View {
        Section("Host key") {
            switch trust(of: host) {
            case .trusted(let keys):
                Label("In your known hosts, and trusted", systemImage: "checkmark.seal.fill").foregroundStyle(Color.statusGood)
                ForEach(keys.indices, id: \.self) { index in
                    let key = keys[index]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.keyType).font(.callout)
                        Text(key.fingerprintSHA256)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                        Text("\(Self.sourceName(key.source)) · \(key.addedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .unknown:
                Label("Not in your known hosts yet", systemImage: "exclamationmark.shield").foregroundStyle(Color.statusWarning)
                Text("The first time you connect you are shown the server's key to check before it is trusted.")
                    .font(.caption).foregroundStyle(.secondary)
            case .revoked:
                Label("Revoked: connections are refused", systemImage: "xmark.octagon.fill").foregroundStyle(Color.statusBad)
                Text("Restore the key in Settings, or remove it to be asked again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Each jump host has a key of its own, checked as the chain is opened.
            let hops = host.jumpHostIDs.compactMap { id in allHosts.first { $0.id == id } }
            ForEach(hops) { hop in
                let status = trust(of: hop)
                LabeledContent("via \(hop.displayLabel)") {
                    switch status {
                    case .trusted: Label("Trusted", systemImage: "checkmark.seal.fill").foregroundStyle(Color.statusGood)
                    case .unknown: Label("Not yet trusted", systemImage: "exclamationmark.shield").foregroundStyle(Color.statusWarning)
                    case .revoked: Label("Revoked", systemImage: "xmark.octagon.fill").foregroundStyle(Color.statusBad)
                    }
                }
                .font(.callout)
            }

            Button("Show Known Hosts", systemImage: "checkmark.shield") {
                app.settingsTab = .knownHosts
                openSettings()
            }
        }
    }

    private static func sourceName(_ source: HostKeySource) -> String {
        switch source {
        case .tofu: "Trusted on first use"
        case .imported: "Imported"
        case .manual: "Added by hand"
        }
    }

    private func summary(_ forward: PortForward) -> String {
        switch forward.kind {
        case .local:
            "\(forward.bindAddress):\(forward.bindPort) → \(forward.destinationHost ?? "?"):\(forward.destinationPort ?? 0)"
        case .remote:
            "remote \(forward.bindAddress):\(forward.bindPort) → \(forward.destinationHost ?? "?"):\(forward.destinationPort ?? 0)"
        case .dynamic:
            "\(forward.bindAddress):\(forward.bindPort) (SOCKS5)"
        }
    }
}

// MARK: - Bulk edit

/// Change the folder, tags and identity of several hosts at once.
struct BulkEditSheet: View {
    let hosts: [SSHHost]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var nodes: [TreeNode]
    @Query(sort: \Identity.name) private var identities: [Identity]

    private enum FolderChoice: Hashable { case unchanged, none, folder(UUID) }

    @State private var folderChoice = FolderChoice.unchanged
    @Query private var allHosts: [SSHHost]
    @State private var tagsToAdd: [String] = []
    @State private var tagsToRemove: Set<String> = []
    /// `nil` leaves identities alone.
    @State private var identityChoice: UUID?

    private var hasChanges: Bool {
        folderChoice != .unchanged
            || !tagsToAdd.isEmpty || !tagsToRemove.isEmpty
            || identityChoice != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Editing \(hosts.count) hosts") {
                    Text(hosts.sorted { $0.displayLabel < $1.displayLabel }.map(\.displayLabel).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }

                Section("Folder") {
                    Picker("Move to", selection: $folderChoice) {
                        Text("Don't change").tag(FolderChoice.unchanged)
                        Text("No folder").tag(FolderChoice.none)
                        ForEach(folders) { folder in
                            Text(folder.pathComponents.joined(separator: " / ")).tag(FolderChoice.folder(folder.id))
                        }
                    }
                }

                Section("Tags") {
                    LabeledContent("Add") {
                        TagEditor(tags: $tagsToAdd, known: NodeTree.tagCounts(hosts: allHosts))
                    }
                    if !tagsOnSelection.isEmpty {
                        LabeledContent("Remove") {
                            TagFlow(spacing: 6) {
                                ForEach(tagsOnSelection, id: \.tag) { entry in
                                    removalToggle(entry)
                                }
                            }
                        }
                        Text("Click a tag to take it off every selected host that has it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Identity") {
                    Picker("Sign in as", selection: $identityChoice) {
                        Text("Don't change").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text("\(identity.name) — \(identity.username)").tag(UUID?.some(identity.id))
                        }
                    }
                    if identityChoice != nil {
                        Label("Their current credentials are replaced by this identity's.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Color.statusWarning)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to \(hosts.count) Hosts") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
            .padding(12)
        }
        .frame(width: 480, height: 520)
    }

    /// The folders to choose from, by path.
    private var folders: [TreeNode] {
        nodes.filter(\.isFolder).sorted {
            $0.pathComponents.joined(separator: " / ").localizedStandardCompare($1.pathComponents.joined(separator: " / ")) == .orderedAscending
        }
    }

    /// The tags the selected hosts carry, with how many of them have each.
    private var tagsOnSelection: [(tag: String, count: Int)] { NodeTree.tagCounts(hosts: hosts) }

    private func removalToggle(_ entry: (tag: String, count: Int)) -> some View {
        let isOn = tagsToRemove.contains(entry.tag)
        return Button {
            if isOn { tagsToRemove.remove(entry.tag) } else { tagsToRemove.insert(entry.tag) }
        } label: {
            Text("#\(entry.tag)" + (hosts.count > 1 ? " (\(entry.count) of \(hosts.count))" : ""))
                .font(.caption)
                .strikethrough(isOn)
                .foregroundStyle(isOn ? Color.statusBad : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Keep tag \(entry.tag)" : "Remove tag \(entry.tag)")
        .accessibilityIdentifier("bulk-remove-tag-\(entry.tag)")
    }

    private func apply() {
        let add = tagsToAdd
        let remove = Array(tagsToRemove)
        let identity = identityChoice.flatMap { id in identities.first { $0.id == id } }

        for host in hosts {
            switch folderChoice {
            case .unchanged: break
            case .none: host.move(to: nil)
            case .folder(let id): host.move(to: nodes.first { $0.id == id })
            }
            if !add.isEmpty || !remove.isEmpty {
                host.tags = TagEdit.apply(to: host.tags, add: add, remove: remove)
            }
            if let identity { host.identity = identity; host.usesNoAuthentication = false }
        }
        modelContext.saveLogged()
        dismiss()
    }
}
