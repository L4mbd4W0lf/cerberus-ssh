import CerberusModels
import CerberusSSHCore
import CerberusVault
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The SSH keys kept in the vault. An identity can sign in with one, so a key is added or
/// replaced in one place rather than once per host.
struct KeysSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Query(sort: \VaultKey.name) private var keys: [VaultKey]
    @Query private var identities: [Identity]

    @State private var selection: UUID?
    @State private var sortOrder = [
        KeyPathComparator(\KeyRow.name, comparator: .localizedStandard)
    ]
    @State private var isImporting = false
    @State private var isGenerating = false
    @State private var renaming: VaultKey?
    @State private var changingPassphrase: VaultKey?
    @State private var installing: VaultKey?
    @State private var showingIdentities: VaultKey?
    @State private var pendingDeletion: VaultKey?
    @State private var notice: String?

    private var selected: VaultKey? { keys.first { $0.id == selection } }

    /// The rows as the table sorts them: a key with how many identities use it, so that column can be ordered too.
    private var rows: [KeyRow] {
        keys.map {
            KeyRow(
                id: $0.id,
                name: $0.name,
                algorithm: $0.algorithm,
                originName: $0.origin.displayName,
                fingerprint: $0.fingerprintSHA256,
                usedBy: users(of: $0).count,
                isEncrypted: $0.isEncrypted
            )
        }.sorted(using: sortOrder)
    }

    private func users(of key: VaultKey) -> [Identity] {
        identities.filter { $0.vaultKeyID == key.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    "Keys kept in the vault, sealed like passwords. Identities choose one to sign in with."
                )
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Import…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                Button("Generate…", systemImage: "sparkles") {
                    isGenerating = true
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("", value: \.id) {
                    if $0.isEncrypted {
                        Image(systemName: "lock.fill")
                    }
                }
                .width(5)
                TableColumn(
                    "Name",
                    value: \.name,
                    comparator: .localizedStandard
                ) { Text($0.name) }
                TableColumn("Type", value: \.algorithm) {
                    Text(
                        $0.algorithm.replacingOccurrences(
                            of: "ecdsa-sha2-",
                            with: "ecdsa "
                        ).replacingOccurrences(of: "ssh-", with: "")
                    )
                }
                .width(90)
                TableColumn("Origin", value: \.originName) {
                    Text($0.originName)
                }.width(70)
                TableColumn("Fingerprint", value: \.fingerprint) {
                    Text($0.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Used by", value: \.usedBy) { row in
                    let count = row.usedBy
                    if count == 0 {
                        Label("0", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.statusWarning)
                            .help("No identity uses this key")
                            .accessibilityLabel("Not used by any identity")
                            .accessibilityIdentifier("key-unused-\(row.name)")
                    } else {
                        Text("\(count)")
                    }
                }.width(64)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityLabel("Keys in the vault")
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first,
                    let key = keys.first(where: { $0.id == id })
                {
                    Group {
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            copy(key)
                        }
                        Button("Rename…", systemImage: "pencil") {
                            renaming = key
                        }
                        Button(
                            "Install on a Server…",
                            systemImage: "externaldrive.badge.plus"
                        ) { installing = key }
                        Button("Change Passphrase…", systemImage: "key") {
                            changingPassphrase = key
                        }
                        Button(
                            "Export Private Key…",
                            systemImage: "square.and.arrow.up"
                        ) { export(key) }
                    }
                    .labelStyle(.titleAndIcon)
                }
            } primaryAction: { ids in
                if let id = ids.first { renaming = keys.first { $0.id == id } }
            }
            .overlay {
                if keys.isEmpty {
                    ContentUnavailableView(
                        "No keys",
                        systemImage: "key",
                        description: Text(
                            "Import an existing key, or generate a new one straight into the vault."
                        )
                    )
                }
            }

            Divider()
            detail
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .sheet(isPresented: $isImporting) {
            ImportKeySheet { selection = $0.id }
        }
        .sheet(isPresented: $isGenerating) {
            GenerateKeySheet { selection = $0.id }
        }
        .sheet(item: $renaming) { RenameKeySheet(key: $0) }
        .sheet(item: $changingPassphrase) { ChangePassphraseSheet(key: $0) }
        .sheet(item: $installing) { InstallKeySheet(key: $0) }
        .sheet(item: $showingIdentities) {
            KeyIdentitiesSheet(keyName: $0.name, identities: users(of: $0))
        }
        .onChange(of: selection) { _, _ in notice = nil }
        .confirmationDialog(
            "Delete this key?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { key in
            Button("Delete \(key.name)", role: .destructive) { delete(key) }
        } message: { _ in
            Text(
                "Its private key is removed from the vault. Servers that still list its public key keep it until you remove it there. This can't be undone, so keep a backup."
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let key = selected {
            let used = users(of: key).map(\.name).sorted()
            VStack(alignment: .leading, spacing: 8) {
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Rename…", systemImage: "pencil") { renaming = key }
                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                        copy(key)
                    }
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        export(key)
                    }
                    .accessibilityIdentifier("key-export")
                    .help("Export Private Key…")
                    if used.isEmpty {
                        Text("Not used by any identity.").font(.callout)
                            .foregroundStyle(.secondary)
                    } else {

                    }
                }
                HStack {
                    Button(
                        "Install on a Server…",
                        systemImage: "externaldrive.badge.plus"
                    ) { installing = key }
                    .accessibilityIdentifier("key-install")
                    .help(
                        "Add this key's public half to a server's authorized_keys"
                    )
                    Button("Passphrase…", systemImage: "key") {
                        changingPassphrase = key
                    }
                    .accessibilityIdentifier("key-change-passphrase")
                    .help("Change Passphrase…")
                    Button(
                        "Used by \(used.count) \(used.count == 1 ? "identity" : "identities")…",
                        systemImage: "person.badge.key"
                    ) { showingIdentities = key }
                    .accessibilityIdentifier("key-used-by")
                    Spacer()
                    Button("Delete…", systemImage: "trash", role: .destructive)
                    { pendingDeletion = key }
                    .disabled(!used.isEmpty)
                    .help(
                        used.isEmpty
                            ? "Delete this key"
                            : "In use by an identity; point it at another key first"
                    )
                }
            }
        } else {
            Text(
                "Select a key to see its public key, or double-click one to rename it."
            )
            .foregroundStyle(.secondary)
        }
    }

    private func copy(_ key: VaultKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKeyLine, forType: .string)
        notice =
            "Public key copied. Add it to the server's ~/.ssh/authorized_keys."
    }

    /// Writes the private key to a file the user chooses, after the biometric gate. The file is readable by this
    /// user only, like `ssh-keygen` makes it, and holds the key as the vault keeps it (with its passphrase, if any).
    private func export(_ key: VaultKey) {
        Task {
            guard
                await app.gate(
                    .export,
                    reason: "Export the private key “\(key.name)”",
                    declined: $notice
                )
            else { return }
            do {
                let pem = try await VaultKeyService.exportPrivateKey(
                    key,
                    context: modelContext,
                    vault: app.vault
                )
                let panel = NSSavePanel()
                panel.nameFieldStringValue =
                    "id_"
                    + key.name.replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: " ", with: "_")
                panel.message =
                    "This file holds the private key. Anyone who has it can sign in as you wherever the key is accepted."
                panel.prompt = "Export"
                guard panel.runModal() == .OK, let url = panel.url else {
                    return
                }
                try? FileManager.default.removeItem(at: url)
                guard
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: Data(pem.utf8),
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                notice = "Private key written to \(url.lastPathComponent)."
            } catch {
                CerberusLog.caught(error)
                notice =
                    (error as? VaultError)?.description
                    ?? error.localizedDescription
            }
        }
    }

    private func delete(_ key: VaultKey) {
        do {
            try VaultKeyService.delete(key, context: modelContext)
            selection = nil
        } catch {
            CerberusLog.caught(error)
            notice = error.localizedDescription
        }
    }
}

/// One row of the keys table.
nonisolated private struct KeyRow: Identifiable, Sendable {
    let id: UUID
    let name: String
    let algorithm: String
    let originName: String
    let fingerprint: String
    let usedBy: Int
    let isEncrypted: Bool
}
