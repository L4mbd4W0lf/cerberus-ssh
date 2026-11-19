import CerberusModels
import CerberusSSHCore
import CerberusVault
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Creates or edits an identity: its name, user and saved password or key. Every host
/// that uses the identity picks the change up the next time it connects, which is what
/// an identity is for.
struct IdentityEditorSheet: View {
    /// `nil` makes a new identity.
    let identity: Identity?
    var onSaved: (Identity) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query(sort: \VaultKey.name) private var vaultKeys: [VaultKey]

    @State private var name = ""
    @State private var username = ""
    @State private var kind: IdentityKind = .password
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var keyPassphrase = ""
    @State private var keyLabel: String?
    /// The vault key to sign in with; `nil` means a key file kept in this identity alone.
    @State private var keyChoice: UUID?
    /// For an agent identity: the agent key to sign in with (`SHA256:…`), or nil for any.
    @State private var agentFingerprint: String?
    @State private var agentKey: AgentKey?
    @State private var error: String?
    @State private var isSaving = false
    @State private var didLoad = false

    private var isNew: Bool { identity == nil }
    private var kindChanged: Bool { identity.map { $0.kind != kind } ?? true }

    private var nameProblem: IdentityName.Problem? {
        IdentityName.problem(
            with: name,
            among: identities.map { (id: $0.id, name: $0.name) },
            excluding: identity?.id
        )
    }

    private var chosenVaultKey: VaultKey? {
        kind == .privateKey
            ? keyChoice.flatMap { id in vaultKeys.first { $0.id == id } } : nil
    }

    /// A secret is needed for a new identity, or when the method is being changed, unless
    /// the key comes from the vault. Moving from a vault key to a key file needs the file.
    private var needsSecret: Bool {
        if chosenVaultKey != nil || kind == .agent { return false }
        return isNew || kindChanged
            || (kind == .privateKey && identity?.vaultKeyID != nil)
    }

    private var hasSecret: Bool {
        switch kind {
        case .password: !password.isEmpty
        case .privateKey: !privateKeyPEM.isEmpty || chosenVaultKey != nil
        case .agent: true
        }
    }

    /// Whether saving would replace what the identity stores, not just rename it.
    private var hasNewSecret: Bool {
        switch kind {
        case .password: !password.isEmpty
        case .privateKey:
            !privateKeyPEM.isEmpty
                || (chosenVaultKey != nil
                    && chosenVaultKey?.id != identity?.vaultKeyID)
        case .agent: false
        }
    }

    private var canSave: Bool {
        !isSaving && nameProblem == nil
            && !IdentityName.trimmed(username).isEmpty
            && (!needsSecret || hasSecret)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField(
                        "Name",
                        text: $name,
                        prompt: Text("Production servers")
                    )
                    .accessibilityIdentifier("identity-name")
                    if let problem = nameProblem, !name.isEmpty || !isNew {
                        Text(message(for: problem)).font(.caption)
                            .foregroundStyle(Color.statusBad)
                    }
                    TextField("Username", text: $username, prompt: Text("root"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("identity-username")
                }

                Section("Sign-in") {
                    do {
                        Picker("Method", selection: $kind) {
                            Text("Password").tag(IdentityKind.password)
                            Text("Private key").tag(IdentityKind.privateKey)
                            Text("SSH agent").tag(IdentityKind.agent)
                        }
                        .pickerStyle(.segmented)

                        switch kind {
                        case .password:
                            SecureField(
                                "Password",
                                text: $password,
                                prompt: Text(
                                    needsSecret
                                        ? "Required"
                                        : "Leave blank to keep the saved password"
                                )
                            )
                            .accessibilityIdentifier("identity-password")
                        case .privateKey:
                            Picker("Key", selection: $keyChoice) {
                                Text("A key file, kept in this identity").tag(
                                    UUID?.none
                                )
                                ForEach(vaultKeys) { key in
                                    Text("\(key.name) — \(key.algorithm)").tag(
                                        UUID?.some(key.id)
                                    )
                                }
                            }
                            if let key = chosenVaultKey {
                                Text(
                                    "Signs in with the vault key “\(key.name)”. Manage keys in Settings ▸ Keys."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            } else {
                                if keyLabel == nil, !needsSecret {
                                    Text(keyDescription).foregroundStyle(
                                        .secondary
                                    ).lineLimit(1).truncationMode(.middle)
                                }
                                KeyInputField(
                                    kind: .privateKey,
                                    text: $privateKeyPEM,
                                    label: $keyLabel,
                                    error: $error,
                                    chooseTitle: needsSecret
                                        ? "Choose file…" : "Replace with file…"
                                )
                                SecureField(
                                    "Key passphrase",
                                    text: $keyPassphrase,
                                    prompt: Text("If encrypted")
                                )
                                if !needsSecret {
                                    Text(
                                        "To change the passphrase, choose the key again."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                if vaultKeys.isEmpty {
                                    Text(
                                        "Tip: keep keys in the vault (Settings ▸ Keys) to share one between identities."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        case .agent:
                            AgentKeyPicker(fingerprint: $agentFingerprint) {
                                agentKey = $0
                            }
                        }
                    }
                }

                if let error {
                    Text(error).foregroundStyle(Color.statusBad).font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 540, height: 620)
        .onAppear(perform: load)
    }

    private var keyDescription: String {
        if let keyLabel { return keyLabel }
        if let identity, !kindChanged, let algorithm = identity.keyAlgorithm {
            return
                "Current: \(algorithm) \(identity.publicKeyFingerprint ?? "")"
        }
        return "No key selected"
    }

    private func message(for problem: IdentityName.Problem) -> String {
        switch problem {
        case .empty: "Give the identity a name."
        case .taken(let other):
            "Another identity is already called “\(other)”. Names must be unique."
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let identity {
            name = identity.name
            username = identity.username
            kind = identity.kind
            keyChoice = identity.vaultKeyID
            if identity.kind == .agent {
                agentFingerprint = identity.publicKeyFingerprint
            }
        } else {
            name = ""
            kind = .password
            keyChoice = vaultKeys.first?.id
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            // Replacing a stored secret is as sensitive as showing it.
            if !isNew, hasNewSecret,
                !(await app.gate(
                    .editSecret,
                    reason:
                        "Change the saved credentials for \(identity?.name ?? "this identity")",
                    declined: $error
                ))
            {
                isSaving = false
                return
            }
            do {
                let saved = try await apply()
                onSaved(saved)
                dismiss()
            } catch let vaultError as VaultError {
                CerberusLog.caught(vaultError)
                error = vaultError.description
            } catch {
                CerberusLog.caught(error)
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func apply() async throws -> Identity {
        let target = identity ?? Identity()
        let vaultKey = chosenVaultKey
        var payload: VaultPayload?
        switch kind {
        case .password where !password.isEmpty: payload = .password(password)
        case .privateKey where vaultKey == nil && !privateKeyPEM.isEmpty:
            payload = .privateKey(
                privateKeyPEM,
                passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
        default: break
        }

        // Seal first, so a failure leaves the identity as it was.
        var metadata: OpenSSHKeyMetadata?
        if payload != nil, kind == .privateKey {
            metadata = try await app.vault.keyMetadata(
                pem: privateKeyPEM,
                passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
        }
        if let payload {
            if let itemID = target.vaultItemID,
                let existing = try fetchVaultItem(itemID)
            {
                try await VaultItemBridge.update(
                    existing,
                    to: payload,
                    using: app.vault
                )
            } else {
                let item = try await VaultItemBridge.makeItem(
                    for: payload,
                    using: app.vault
                )
                modelContext.insert(item)
                target.vaultItemID = item.id
            }
        }

        target.name = IdentityName.trimmed(name)
        target.username = IdentityName.trimmed(username)
        target.kind = kind
        if isNew { modelContext.insert(target) }
        if let vaultKey {
            // Signing in with a vault key replaces any key this identity carried itself.
            try VaultKeyService.assign(
                vaultKey,
                to: target,
                context: modelContext
            )
        } else {
            target.vaultKeyID = nil
        }
        if let metadata {
            target.keyAlgorithm = metadata.algorithm
            target.keyIsEncrypted = metadata.isEncrypted
            target.publicKeyFingerprint = metadata.fingerprintSHA256
        } else if kind == .password {
            target.keyAlgorithm = nil
            target.keyIsEncrypted = false
            target.publicKeyFingerprint = nil
            target.agentKeyComment = nil
        } else if kind == .agent {
            // The agent holds the key: the identity only remembers which one to ask for, if it was told.
            target.publicKeyFingerprint = agentFingerprint
            target.agentKeyComment =
                agentKey?.comment
                ?? (agentFingerprint == nil ? nil : target.agentKeyComment)
            target.keyAlgorithm =
                agentKey?.algorithm
                ?? (agentFingerprint == nil ? nil : target.keyAlgorithm)
            target.keyIsEncrypted = false
        }
        try modelContext.save()
        return target
    }

    private func fetchVaultItem(_ id: UUID) throws -> VaultItem? {
        var descriptor = FetchDescriptor<VaultItem>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
