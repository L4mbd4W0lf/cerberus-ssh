import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

struct IdentitiesSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Query(sort: \Identity.name) private var identities: [Identity]
    @Query private var vaultItems: [VaultItem]
    @Query private var vaultKeys: [VaultKey]

    @State private var selection: UUID?
    @State private var sortOrder = [
        KeyPathComparator(\Identity.name, comparator: .localizedStandard)
    ]
    @State private var revealed: String?
    @State private var notice: String?
    @State private var pendingDeletion: Identity?
    @State private var hideTask: Task<Void, Never>?
    @State private var editing: Identity?
    @State private var isAdding = false
    @State private var showingHosts: Identity?

    private var selected: Identity? { identities.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    "An identity is a saved login. Edit one and every host that uses it is updated."
                )
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("New Identity…", systemImage: "person.badge.plus") {
                    isAdding = true
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(
                identities.sorted(using: sortOrder),
                selection: $selection,
                sortOrder: $sortOrder
            ) {
                TableColumn(
                    "Name",
                    value: \.name,
                    comparator: .localizedStandard
                ) { Text($0.name) }
                TableColumn("User", value: \.username)
                TableColumn("Type", value: \.kindSortKey) {
                    if $0.keyIsEncrypted {
                        Label($0.kind.displayName, systemImage: "lock.fill")
                    } else {
                        Text($0.kind.displayName)
                    }
                }
                TableColumn("Key", value: \.keySortKey) {
                    Text($0.keyAlgorithm ?? "—").foregroundStyle(.secondary)
                }
                TableColumn("Fingerprint", value: \.fingerprintSortKey) {
                    Text($0.publicKeyFingerprint ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Hosts", value: \.hostCount) { identity in
                    let count = (identity.hosts ?? []).count
                    if count == 0 {
                        Label("0", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusWarning)
                            .help("No host uses this identity")
                            .accessibilityLabel("Not used by any host")
                            .accessibilityIdentifier(
                                "identity-unused-\(identity.name)"
                            )
                    } else {
                        Text("\(count)")
                    }
                }.width(52)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityIdentifier("identities-table")
            .accessibilityLabel("Saved logins")
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first,
                    let identity = identities.first(where: { $0.id == id })
                {
                    Button("Edit…", systemImage: "pencil") {
                        editing = identity
                    }
                    .labelStyle(.titleAndIcon)
                }
            } primaryAction: { ids in
                if let id = ids.first {
                    editing = identities.first { $0.id == id }
                }
            }
            .overlay {
                if identities.isEmpty {
                    ContentUnavailableView(
                        "No identities",
                        systemImage: "person.badge.key",
                        description: Text(
                            "Add one here, or create one when you add a host."
                        )
                    )
                }
            }

            Divider()
            detail
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .onChange(of: selection) { _, _ in hide() }
        .sheet(item: $editing) { IdentityEditorSheet(identity: $0) }
        .sheet(item: $showingHosts) { IdentityHostsSheet(identity: $0) }
        .sheet(isPresented: $isAdding) {
            IdentityEditorSheet(identity: nil) { selection = $0.id }
        }
        .confirmationDialog(
            "Delete this identity?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { identity in
            Button("Delete \(identity.name)", role: .destructive) {
                delete(identity)
            }
        } message: { _ in
            Text(
                "Its saved password or key is removed from the vault. This can't be undone."
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let identity = selected {
            let hosts = (identity.hosts ?? []).map(\.displayLabel).sorted()
            VStack(alignment: .leading, spacing: 8) {
                if let revealed {
                    HStack {
                        Text(revealed)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Hides in 15 s").font(.caption).foregroundStyle(
                            .secondary
                        )
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Edit…", systemImage: "pencil") {
                        editing = identity
                    }
                    if identity.kind == .password {
                        Button("Reveal Password…", systemImage: "eye") {
                            Task { await reveal(identity) }
                        }
                    }
                    if identity.kind == .privateKey {
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            Task { await copyPublicKey(identity) }
                        }
                    }
                    if !hosts.isEmpty {
                        Button(
                            "Used by \(hosts.count) \(hosts.count == 1 ? "host" : "hosts")…",
                            systemImage: "server.rack"
                        ) { showingHosts = identity }
                        .accessibilityIdentifier("identity-used-by")
                    }
                    Spacer()
                    Button("Delete…", systemImage: "trash", role: .destructive)
                    { pendingDeletion = identity }
                    .disabled(!hosts.isEmpty)
                    .help(
                        hosts.isEmpty
                            ? "Delete this identity"
                            : "In use by a host; remove the host first"
                    )
                }
            }
        } else {
            HStack {
                Text(
                    "Select an identity to see its details, or double-click one to edit it."
                )
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func item(for identity: Identity) -> VaultItem? {
        identity.vaultItemID.flatMap { id in vaultItems.first { $0.id == id } }
    }

    private func reveal(_ identity: Identity) async {
        hide()
        guard let item = item(for: identity) else {
            notice = "No secret is stored for this identity."
            return
        }
        guard
            await app.gate(
                .reveal,
                reason: "Reveal the password for \(identity.name)",
                declined: $notice
            )
        else { return }
        do {
            let payload = try await VaultItemBridge.reveal(
                item,
                using: app.vault
            )
            revealed = payload.password ?? "(no password stored)"
            notice = nil
            hideTask = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { revealed = nil }
            }
        } catch {
            CerberusLog.caught(error)
            notice =
                (error as? VaultError)?.description
                ?? error.localizedDescription
        }
    }

    private func copyPublicKey(_ identity: Identity) async {
        if let keyID = identity.vaultKeyID,
            let key = vaultKeys.first(where: { $0.id == keyID })
        {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key.publicKeyLine, forType: .string)
            notice =
                "Public key copied. Add it to the server's authorized_keys."
            return
        }
        guard let item = item(for: identity) else {
            notice = "No key is stored for this identity."
            return
        }
        do {
            let payload = try await VaultItemBridge.reveal(
                item,
                using: app.vault
            )
            guard let pem = payload.privateKeyPEM else {
                notice = "No private key is stored."
                return
            }
            let metadata = try await app.vault.keyMetadata(
                pem: pem,
                passphrase: payload.keyPassphrase
            )
            let line =
                "\(metadata.algorithm) \(metadata.publicKeyBlob.base64EncodedString())"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            notice =
                "Public key copied. Add it to the server's authorized_keys."
        } catch {
            CerberusLog.caught(error)
            notice =
                (error as? VaultError)?.description
                ?? error.localizedDescription
        }
    }

    private func delete(_ identity: Identity) {
        if let id = identity.vaultItemID,
            let item = vaultItems.first(where: { $0.id == id })
        {
            modelContext.delete(item)
        }
        identity.releaseHosts()
        modelContext.delete(identity)
        modelContext.saveLogged()
        selection = nil
    }

    private func hide() {
        hideTask?.cancel()
        revealed = nil
    }
}

/// What each column of the table sorts by, where it is not the displayed text itself.
extension Identity {
    fileprivate var kindSortKey: String { kind.displayName }
    fileprivate var keySortKey: String { keyAlgorithm ?? "" }
    fileprivate var fingerprintSortKey: String { publicKeyFingerprint ?? "" }
    fileprivate var hostCount: Int { (hosts ?? []).count }
}
