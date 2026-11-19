import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault

/// Create or edit a host: connection, organisation, credentials, jump chain, forwards
/// and session options.
///
/// Secrets are handed straight to the vault and sealed; only the ciphertext is
/// written to the store.
struct HostEditorView: View {
    let host: SSHHost?
    /// For a new host: the folder to start in.
    let initialFolderID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @Query private var nodes: [TreeNode]
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: \VaultKey.name) private var vaultKeys: [VaultKey]
    @Query(sort: \SSHHost.name) private var allHosts: [SSHHost]

    // Connection
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = 22

    // Organisation
    @State private var folderID: UUID?

    init(host: SSHHost?, initialFolderID: UUID? = nil) {
        self.host = host
        self.initialFolderID = initialFolderID
        // Starts with the folder already chosen, rather than setting it once on screen.
        _folderID = State(initialValue: host?.folder?.id ?? initialFolderID)
    }

    /// The folders to choose from, by path.
    private var folders: [TreeNode] {
        nodes.filter(\.isFolder).sorted {
            $0.pathComponents.joined(separator: " / ").localizedStandardCompare($1.pathComponents.joined(separator: " / ")) == .orderedAscending
        }
    }

    @State private var tags: [String] = []

    // Credentials
    /// `nil` creates a new identity for this host; otherwise an existing one is shared.
    @State private var identityChoice: UUID?
    /// A public server that asks for no login: only a user name is sent.
    @State private var noAuthentication = false
    @State private var changingCredential = false
    @State private var identityName = ""
    /// A key kept in the vault to sign in with; `nil` means a key file chosen here.
    @State private var vaultKeyChoice: UUID?
    @State private var username = ""
    @State private var kind: IdentityKind = .password
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var keyPassphrase = ""
    @State private var keyLabel: String?

    // Jump chain, forwards, session
    @State private var jumpIDs: [UUID] = []
    @State private var chainTest: ConnectionTestReport?
    @State private var isTestingChain = false
    @State private var forwards: [ForwardDraft] = []
    @State private var environment: [EnvDraft] = []
    @State private var initialCommand = ""
    @State private var terminalType = "xterm-256color"
    @State private var themeID: String?
    @State private var keepAlive = 60
    @State private var autoReconnect = false
    @State private var notes = ""

    @State private var error: String?
    @State private var isSaving = false

    struct EnvDraft: Identifiable, Equatable {
        var id = UUID()
        var key = ""
        var value = ""
    }

    private var isEditing: Bool { host != nil }
    private var usesExistingIdentity: Bool { identityChoice != nil }
    private var chosenIdentity: Identity? { identityChoice.flatMap { id in identities.first { $0.id == id } } }
    private var entersCredential: Bool { !usesExistingIdentity || changingCredential }

    /// A new credential's name, if one was typed; blank takes a generated one.
    private var newIdentityNameProblem: IdentityName.Problem? {
        guard !identityName.trimmed.isEmpty else { return nil }
        return IdentityName.problem(with: identityName, among: identities.map { (id: $0.id, name: $0.name) })
    }

    private var chosenVaultKey: VaultKey? {
        kind == .privateKey ? vaultKeyChoice.flatMap { id in vaultKeys.first { $0.id == id } } : nil
    }

    /// The first thing still missing before Save works, in the order the form asks for it; `nil` when it can be saved.
    private var saveBlocker: String? {
        if hostname.trimmed.isEmpty { return "Enter the host's address." }
        if let forward = forwards.first(where: { $0.problem != nil }), let problem = forward.problem { return "Port forward: \(problem)" }
        if noAuthentication { return nil }   // a blank user name becomes "guest"
        if usesExistingIdentity { return nil }
        if username.trimmed.isEmpty { return "Enter the user name." }
        if newIdentityNameProblem != nil { return "Choose a different credential name." }
        switch kind {
        case .password: return password.isEmpty ? "Enter the password." : nil
        case .privateKey: return privateKeyPEM.isEmpty && chosenVaultKey == nil ? "Choose or paste a private key." : nil
        case .agent: return nil
        }
    }

    private var canSave: Bool { !isSaving && saveBlocker == nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                connectionSection
                authenticationSection
                jumpSection
                forwardsSection
                organisationSection
                sessionSection

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.statusBad)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                // Beside the disabled button, so it is never left unexplained.
                if let blocker = saveBlocker {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).accessibilityIdentifier("host-editor-blocker")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 580, height: 680)
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $name, prompt: Text(hostname.isEmpty ? "Optional" : hostname))
            TextField("Host", text: $hostname, prompt: Text("example.com"))
                .autocorrectionDisabled()
            TextField("Port", value: $port, format: .number.grouping(.never))
        }
    }

    private var organisationSection: some View {
        Section("Organisation") {
            Picker("Folder", selection: $folderID) {
                Text("None").tag(UUID?.none)
                ForEach(folders) { folder in
                    Text(folder.pathComponents.joined(separator: " / ")).tag(UUID?.some(folder.id))
                }
            }
            LabeledContent("Tags") {
                TagEditor(tags: $tags, known: NodeTree.tagCounts(hosts: allHosts))
            }
            Text("Pick a tag already in use or type a new one. Use them to filter the sidebar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var authenticationSection: some View {
        Section {
            if noAuthentication {
                TextField("Username", text: $username, prompt: Text("guest"))
                    .autocorrectionDisabled()
                Text("Signs in without a password or key, for public servers that let anyone in. Only the user name is sent; left blank, it is “guest”.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                credentialRows
            }
        } header: {
            HStack {
                Text("Authentication")
                Spacer()
                Toggle("No authentication", isOn: $noAuthentication)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("host-no-authentication")
            }
        }
    }

    @ViewBuilder
    private var credentialRows: some View {
        Group {
            Picker("Identity", selection: $identityChoice) {
                Text("New credential…").tag(UUID?.none)
                ForEach(identities) { identity in
                    Text("\(identity.name) — \(identity.username)").tag(UUID?.some(identity.id))
                }
            }

            if let identity = chosenIdentity {
                LabeledContent("User", value: identity.username)
                LabeledContent("Type", value: identity.kind.displayName)
                let sharedBy = (identity.hosts ?? []).count
                if sharedBy > 1 {
                    Text("Shared by \(sharedBy) hosts. Changing its credential changes it for all of them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Rename it or change its login for every host in Settings ▸ Identities.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Change the saved credential", isOn: $changingCredential)
            }

            if entersCredential {
                if !usesExistingIdentity {
                    TextField("Identity name", text: $identityName,
                              prompt: Text(IdentityName.unique("\(username.trimmed)@\(hostname.trimmed)", among: identities.map(\.name))))
                    if case .taken(let other)? = newIdentityNameProblem {
                        Text("Another identity is already called “\(other)”. Names must be unique.")
                            .font(.caption).foregroundStyle(Color.statusBad)
                    }
                }
                TextField("Username", text: $username, prompt: Text("root"))
                    .autocorrectionDisabled()

                Picker("Method", selection: $kind) {
                    Text("Password").tag(IdentityKind.password)
                    Text("Private key").tag(IdentityKind.privateKey)
                    Text("SSH agent").tag(IdentityKind.agent)
                }
                .pickerStyle(.segmented)

                switch kind {
                case .password:
                    SecureField("Password", text: $password, prompt: Text(usesExistingIdentity ? "New password" : "Required"))
                case .privateKey:
                    if !vaultKeys.isEmpty {
                        Picker("Key", selection: $vaultKeyChoice) {
                            Text("A key file…").tag(UUID?.none)
                            ForEach(vaultKeys) { Text("\($0.name) — \($0.algorithm)").tag(UUID?.some($0.id)) }
                        }
                    }
                    if chosenVaultKey == nil {
                        KeyInputField(kind: .privateKey, text: $privateKeyPEM, label: $keyLabel, error: $error)
                        SecureField("Key passphrase", text: $keyPassphrase, prompt: Text("If encrypted"))
                    } else {
                        Text("Signs in with a key kept in the vault (Settings ▸ Keys).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .agent:
                    Text("Signs in with a key from your ssh-agent; each key it holds is tried. To use one particular key, choose it in Settings ▸ Identities after saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var jumpSection: some View {
        Section("Jump hosts") {
            if jumpIDs.isEmpty {
                Text("Connects directly. Add hosts to connect through them, in order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(jumpIDs.enumerated()), id: \.element) { index, id in
                let hop = allHosts.first { $0.id == id }
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    HostOSIcon(os: hop?.detectedOS).frame(width: 18, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hop?.displayLabel ?? "Missing host")
                        if let hop {
                            Text(JumpHostList.detail(hop)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Move this jump host earlier")
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Move this jump host later")
                        .disabled(index == jumpIDs.count - 1)
                    Button { jumpIDs.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove this jump host")
                }
                .buttonStyle(.borderless)
            }

            JumpHostPicker(candidates: allHosts.filter { $0.id != host?.id && !jumpIDs.contains($0.id) }) { jumpIDs.append($0.id) }

            // Dials the chain as saved and says where it stops, if it does.
            if let host, !host.jumpHostIDs.isEmpty {
                HStack {
                    Button(isTestingChain ? "Testing…" : "Test Chain", systemImage: "point.3.connected.trianglepath.dotted") {
                        isTestingChain = true; chainTest = nil
                        Task {
                            chainTest = await app.testConnection(to: host)
                            isTestingChain = false
                        }
                    }
                    .disabled(isTestingChain)
                    .accessibilityIdentifier("host-test-chain")
                    if isTestingChain { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if jumpIDs != host.jumpHostIDs {
                    Text("This tests the jump hosts as last saved, not the changes above.").font(.caption).foregroundStyle(.secondary)
                }
                if let report = chainTest {
                    Label(report.summary, systemImage: report.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(report.succeeded ? Color.statusGood : Color.statusBad)
                        .font(.callout)
                        .accessibilityIdentifier("host-test-chain-result")
                    if let detail = report.detail, !report.succeeded {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var forwardsSection: some View {
        Section("Port forwarding") {
            if forwards.isEmpty {
                Text("None. A forward can start automatically, or from the status bar or the Forwards window, and can be switched off without deleting it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($forwards) { $forward in
                ForwardFields(forward: $forward) { forwards.removeAll { $0.id == forward.id } }
                    .padding(.vertical, 2)
            }
            Button("Add forward", systemImage: "plus.circle") { forwards.append(ForwardDraft()) }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            Picker("Theme", selection: $themeID) {
                Text("Default").tag(String?.none)
                ForEach(app.allThemes) { theme in Text(theme.name).tag(String?.some(theme.id)) }
            }
            TextField("Terminal type", text: $terminalType)
            TextField("Initial command", text: $initialCommand, prompt: Text("Run after connecting"))
            Stepper(value: $keepAlive, in: 0...600, step: 15) {
                Text(keepAlive == 0 ? "Keepalive: off" : "Keepalive every \(keepAlive) s")
            }
            Toggle("Reconnect automatically if the connection drops", isOn: $autoReconnect)

            DisclosureGroup("Environment variables") {
                ForEach($environment) { $variable in
                    HStack {
                        TextField("NAME", text: $variable.key).frame(maxWidth: 150)
                        TextField("value", text: $variable.value)
                        Button { environment.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove this environment variable")
                    }
                    .textFieldStyle(.roundedBorder)
                }
                Button("Add variable", systemImage: "plus.circle") { environment.append(EnvDraft()) }
                Text("Sent as SSH environment requests. Many servers accept only a short list (AcceptEnv).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
        }
    }

    // MARK: Loading

    private func load() {
        guard let host else {
            folderID = initialFolderID
            return
        }
        name = host.name
        hostname = host.hostname
        port = host.port
        folderID = host.folder?.id
        tags = host.tags
        identityChoice = host.liveIdentity?.id
        noAuthentication = host.usesNoAuthentication
        username = host.loginUsername ?? ""
        kind = host.liveIdentity?.kind ?? .password
        jumpIDs = host.jumpHostIDs
        initialCommand = host.initialCommand ?? ""
        terminalType = host.terminalType
        themeID = host.themeID
        keepAlive = host.keepAliveInterval
        autoReconnect = host.autoReconnect
        notes = host.notes ?? ""
        environment = host.environment.sorted { $0.key < $1.key }.map { EnvDraft(key: $0.key, value: $0.value) }
        forwards = (host.portForwards ?? []).map { ForwardDraft($0) }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard jumpIDs.indices.contains(target) else { return }
        jumpIDs.swapAt(index, target)
    }

    // MARK: Saving

    private func save() {
        isSaving = true
        error = nil
        Task {
            do {
                try await persist()
                dismiss()
            } catch let vaultError as VaultError {
                CerberusLog.caught(vaultError)
                error = vaultError.description
            } catch let chainError as JumpChainResolver.ChainError {
                CerberusLog.caught(chainError)
                error = chainError.description
            } catch {
                CerberusLog.caught(error)
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func validate() throws {
        for forward in forwards {
            guard (0...65535).contains(forward.bindPort) else {
                throw EditorError("Port \(forward.bindPort) is not a valid listening port.")
            }
            if forward.kind == .local {
                guard !forward.destinationHost.trimmed.isEmpty, (1...65535).contains(forward.destinationPort) else {
                    throw EditorError("A local forward needs a destination host and port.")
                }
            }
        }
        for variable in environment where !variable.key.isEmpty {
            let valid = variable.key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            guard valid else { throw EditorError("“\(variable.key)” is not a valid variable name.") }
        }
    }

    private func persist() async throws {
        try validate()

        // Prove a newly entered key works before anything is stored.
        if !noAuthentication, entersCredential, kind == .privateKey, !privateKeyPEM.isEmpty {
            try await app.vault.validatePrivateKey(
                pem: privateKeyPEM, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
        }

        let target = host ?? SSHHost()

        // Reject cycles and over-long chains before saving.
        let byID = Dictionary(allHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let problem = JumpChainResolver.validate(proposedChain: jumpIDs, for: target, lookup: { byID[$0] }) {
            throw problem
        }

        target.name = name.trimmed
        target.hostname = hostname.trimmed
        target.port = max(1, min(65535, port))
        target.move(to: folderID.flatMap { id in nodes.first { $0.id == id } })
        target.tags = tags
        target.jumpHostIDs = jumpIDs
        target.initialCommand = initialCommand.trimmed.isEmpty ? nil : initialCommand.trimmed
        target.terminalType = terminalType.trimmed.isEmpty ? "xterm-256color" : terminalType.trimmed
        target.themeID = themeID
        target.keepAliveInterval = keepAlive
        target.autoReconnect = autoReconnect
        target.notes = notes.trimmed.isEmpty ? nil : notes.trimmed
        target.environment = Dictionary(
            environment.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        target.usesNoAuthentication = noAuthentication
        target.noAuthenticationUsername = noAuthentication ? (username.trimmed.isEmpty ? "guest" : username.trimmed) : nil
        if noAuthentication {
            // No identity, so nothing is created in the vault for this host.
            target.identity = nil
            if host == nil { modelContext.insert(target) }
            syncForwards(on: target)
            try modelContext.save()
            app.refreshForwards(for: target)
            return
        }

        // Identity: share an existing one, or create a new one for this host.
        let identity: Identity
        if let existing = chosenIdentity {
            identity = existing
            if changingCredential {
                if !username.trimmed.isEmpty { identity.username = username.trimmed }
                identity.kind = kind
            }
        } else {
            identity = Identity()
            identity.username = username.trimmed
            identity.kind = kind
            identity.name = identityName.trimmed.isEmpty
                ? IdentityName.unique("\(identity.username)@\(hostname.trimmed)", among: identities.map(\.name))
                : identityName.trimmed
            modelContext.insert(identity)
        }

        if entersCredential, let vaultKey = chosenVaultKey {
            try VaultKeyService.assign(vaultKey, to: identity, context: modelContext)
        } else if entersCredential, let payload = newPayload() {
            identity.vaultKeyID = nil
            if let existingID = identity.vaultItemID, let existing = try fetchVaultItem(existingID) {
                try await VaultItemBridge.update(existing, to: payload, using: app.vault)
            } else {
                let item = try await VaultItemBridge.makeItem(for: payload, using: app.vault)
                modelContext.insert(item)
                identity.vaultItemID = item.id
            }

            if kind == .privateKey, !privateKeyPEM.isEmpty {
                let metadata = try await app.vault.keyMetadata(pem: privateKeyPEM, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
                identity.keyAlgorithm = metadata.algorithm
                identity.keyIsEncrypted = metadata.isEncrypted
                identity.publicKeyFingerprint = metadata.fingerprintSHA256
            }
        }
        target.identity = identity

        if host == nil { modelContext.insert(target) }
        syncForwards(on: target)
        try modelContext.save()
        // Sessions already open to this host take up the forwards as edited.
        app.refreshForwards(for: target)
    }

    /// Updates forwards in place by id, adds new ones, and removes deleted ones.
    private func syncForwards(on target: SSHHost) {
        let existing = target.portForwards ?? []
        let keep = Set(forwards.map(\.id))
        for old in existing where !keep.contains(old.id) { modelContext.delete(old) }

        for draft in forwards {
            if let current = existing.first(where: { $0.id == draft.id }) {
                draft.apply(to: current)
            } else {
                let created = PortForward(id: draft.id, host: target)
                modelContext.insert(created)
                draft.apply(to: created)
            }
        }
    }

    /// `nil` means "no secret was entered", which keeps the stored one.
    private func newPayload() -> VaultPayload? {
        switch kind {
        case .password:
            password.isEmpty ? nil : .password(password)
        case .privateKey:
            privateKeyPEM.isEmpty
                ? nil
                : .privateKey(privateKeyPEM, passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
        case .agent:
            nil
        }
    }

    private func fetchVaultItem(_ id: UUID) throws -> VaultItem? {
        var descriptor = FetchDescriptor<VaultItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

private struct EditorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
