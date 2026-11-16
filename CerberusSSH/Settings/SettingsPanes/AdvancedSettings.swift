import CerberusModels
import CerberusSSHCore
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

struct AdvancedSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app

    @State private var confirmation = ""
    @State private var isConfirming = false
    @State private var message: String?
    @State private var isWorking = false
    @State private var keychain: KeychainCheck.Report?
    @AppStorage(AgentSettings.socketKey) private var agentSocket = ""
    @State private var agentReport: String?

    var body: some View {
        Form {
            Section("Keychain") {
                Button("Check Keychain Access", systemImage: "key.viewfinder") {
                    keychain = KeychainCheck.run()
                }
                if let keychain {
                    keychainRow(
                        keychain.deviceOnly,
                        note:
                            "Where the vault key and a saved backup passphrase are kept."
                    )
                    keychainRow(
                        keychain.synchronizable,
                        note:
                            "Lets the vault key and the saved backup passphrase follow you to your other Macs (the iCloud Keychain section below)."
                    )
                    LabeledContent("Vault key") {
                        Text(keychain.dataKeyPresent ? "present" : "missing")
                            .foregroundStyle(
                                keychain.dataKeyPresent
                                    ? Color.secondary : Color.statusBad
                            )
                    }
                }
                Text(
                    "Tests, with throwaway items, what this build is allowed to do with the Keychain. It depends on how the app was signed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            ICloudKeychainSection()

            Section("SSH agent") {
                TextField(
                    "Agent socket",
                    text: $agentSocket,
                    prompt: Text("Blank: use SSH_AUTH_SOCK")
                )
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .accessibilityIdentifier("agent-socket-field")
                LabeledContent("In use") {
                    Text(
                        AgentSettings.client?.socketPath
                            ?? "none: SSH_AUTH_SOCK is not set"
                    )
                    .font(.system(.caption, design: .monospaced)).textSelection(
                        .enabled
                    )
                }
                Button("Check Agent", systemImage: "key.viewfinder") {
                    Task { await checkAgent() }
                }
                if let agentReport {
                    Text(agentReport).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(
                    "An identity with the SSH agent method signs in with a key the agent holds; the private key never reaches this app. Agent forwarding to the server is not supported."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Where your data lives") {
                LabeledContent("Catalogue") {
                    Text(CerberusSchema.localStoreFiles().first?.path ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Vault key") {
                    Text("Keychain · com.cerberusssh.vault")
                        .font(.system(.caption, design: .monospaced))
                }
                Text(
                    "The vault file is the catalogue above: it holds your saved passwords and keys sealed, and is opened with the vault key kept in the Keychain (on this Mac, or in iCloud Keychain if you chose that in the section above)."
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder", systemImage: "folder") {
                    if let url = CerberusSchema.localStoreFiles().first {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }

            MigrationBackupsSection()

            Section("Reset") {
                Text(
                    "Erases every host, identity, saved secret, snippet, trusted host key and setting, and the migration backups, and creates a new vault key, as on a fresh install. Backups you exported earlier still work. If the old vault key was in iCloud Keychain it is removed from your other Macs too."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button(
                    "Erase All Data…",
                    systemImage: "exclamationmark.triangle",
                    role: .destructive
                ) { isConfirming = true }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isConfirming) {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Erase all data?",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.title3.bold()).foregroundStyle(Color.statusBad)
                Text(
                    "Open sessions are closed and everything is deleted from this Mac. Type ERASE to confirm."
                )
                TextField("ERASE", text: $confirmation).textFieldStyle(
                    .roundedBorder
                )
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        confirmation = ""
                        isConfirming = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Erase", role: .destructive) {
                        Task { await erase() }
                    }
                    .disabled(confirmation != "ERASE" || isWorking)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
    }

    private func keychainRow(_ probe: KeychainCheck.Probe, note: String)
        -> some View
    {
        LabeledContent(probe.name) {
            VStack(alignment: .trailing, spacing: 1) {
                Label(
                    probe.detail,
                    systemImage: probe.isWorking
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    probe.isWorking ? Color.statusGood : Color.statusWarning
                )
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func erase() async {
        guard
            await app.gate(
                .replaceAll,
                reason: "Erase all CerberusSSH data",
                declined: $message
            )
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.eraseAllData(context: modelContext)
            message = "All data erased."
        } catch {
            CerberusLog.caught(error)
            message = "Could not erase: \(error.localizedDescription)"
        }
        confirmation = ""
        isConfirming = false
    }

    private func checkAgent() async {
        switch await AgentSettings.keys() {
        case .success(let keys) where keys.isEmpty:
            agentReport =
                "The agent is running and holds no keys. Add one with ssh-add."
        case .success(let keys):
            agentReport = keys.map {
                "\($0.comment.isEmpty ? "(no comment)" : $0.comment) · \($0.algorithm) · \($0.fingerprintSHA256)\($0.isSupported ? "" : " · not usable here")"
            }.joined(separator: "\n")
        case .failure(let error):
            agentReport = error.description
        }
    }
}

/// What follows the person to their other Macs through iCloud Keychain (spec §6.3, §6.6): the saved backup passphrase and
/// the vault's own key, each by its own switch. Neither uploads the vault file or a backup: only keys.
struct ICloudKeychainSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @AppStorage(KeychainExportPassphraseStore.shareKey) private
        var wantsPassphraseShared = false
    @State private var canShare = false
    @State private var hasSaved = false
    @State private var passphraseShared = false
    @State private var keyShared = false
    @State private var confirming: Item?
    @State private var problem: String?
    /// Turning the key off found two different keys, and the person is asked whether to merge them.
    @State private var offersMerge = false
    @State private var isMerging = false

    private enum Item: Identifiable {
        case passphrase, vaultKey
        var id: Self { self }
    }

    private var passphraseSwitch: Binding<Bool> {
        Binding(
            get: { wantsPassphraseShared },
            set: { on in
                if on { confirming = .passphrase } else { turnOffPassphrase() }
            }
        )
    }
    private var keySwitch: Binding<Bool> {
        Binding(
            get: { keyShared },
            set: { on in
                if on {
                    confirming = .vaultKey
                } else {
                    Task { await setKey(false) }
                }
            }
        )
    }

    var body: some View {
        Section("iCloud Keychain") {
            Toggle(
                "Share the saved backup passphrase with my other Macs",
                isOn: passphraseSwitch
            )
            .disabled(!canShare)
            .accessibilityIdentifier("backup-share-passphrase")
            Text(passphraseStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-share-status")

            Toggle("Keep the vault key in iCloud Keychain", isOn: keySwitch)
                .disabled(!canShare)
                .accessibilityIdentifier("vault-key-icloud")
            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vault-key-status")

            if !canShare {
                Text(
                    "This build can't use iCloud Keychain: it needs to be signed with a keychain access group (the notarised release will be). Both stay in the Keychain on this Mac only."
                )
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-share-unavailable")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color.statusBad)
            }
            Text(
                "iCloud Keychain is end-to-end encrypted and carries only these keys to Macs signed into the same Apple Account. It never carries a backup file or the vault file: you put those where your other Mac can reach them, such as iCloud Drive. To move your vault to another Mac, copy the vault file (below, under Where your data lives) before CerberusSSH is first opened there, and let iCloud Keychain finish syncing."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .confirmationDialog(
            confirming == .vaultKey
                ? "Keep the vault key in iCloud Keychain?"
                : "Share the backup passphrase through iCloud Keychain?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirming == .vaultKey ? "Keep It There" : "Share It") {
                let item = confirming
                Task {
                    if item == .vaultKey {
                        await setKey(true)
                    } else {
                        await turnOnPassphrase()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                confirming == .vaultKey
                    ? "The vault key opens every saved password and key in the vault file. iCloud Keychain is end-to-end encrypted, but anyone who can sign in to your Apple Account on a Mac and knows that Mac's password could read the key, and open a copy of your vault file with it. Turning this off later moves the key back to this Mac only."
                    : "The passphrase opens every backup you make, secrets included. Anyone who can sign in to your Apple Account on a Mac and knows that Mac's password could read it there. Turning this off later removes it from iCloud Keychain on all your Macs."
            )
        }
        .confirmationDialog(
            "Use this Mac's own vault key?",
            isPresented: $offersMerge,
            titleVisibility: .visible
        ) {
            Button("Use This Mac's Key") { Task { await mergeKeys() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This Mac and iCloud Keychain hold two different vault keys, so the key can't simply be moved. CerberusSSH can seal your saved passwords, keys and session recordings under this Mac's key, then remove the iCloud one. Another Mac that relies on the iCloud key will no longer be able to open what was sealed with it. Nothing is removed until everything has been re-sealed."
            )
        }
    }

    private var passphraseStatus: String {
        if !hasSaved {
            return wantsPassphraseShared
                ? "No passphrase is saved yet. The next one you save will be shared."
                : "No passphrase is saved yet."
        }
        return passphraseShared
            ? "The saved passphrase is in iCloud Keychain."
            : "The saved passphrase is in the Keychain on this Mac."
    }

    private var keyStatus: String {
        keyShared
            ? "The vault key is in iCloud Keychain, so it is on your other Macs too."
            : "The vault key is in the Keychain on this Mac."
    }

    private func refresh() async {
        canShare =
            !UITesting.isActive && KeychainCheck.run().synchronizable.isWorking
        hasSaved = ((try? app.exportPassphrases.load()) ?? nil) != nil
        passphraseShared = (try? app.exportPassphrases.isShared()) ?? false
        keyShared = (try? await app.vault.keyIsSynchronized()) ?? false
    }

    private func turnOnPassphrase() async {
        problem = nil
        guard
            await app.gate(
                .editSecret,
                reason:
                    "Share the saved backup passphrase through iCloud Keychain",
                declined: $problem
            )
        else { return }
        wantsPassphraseShared = true
        do { try app.exportPassphrases.setShared(true) } catch {
            CerberusLog.caught(error)
            problem = "Could not share it: \(error.localizedDescription)"
        }
        await refresh()
    }

    private func turnOffPassphrase() {
        problem = nil
        wantsPassphraseShared = false
        do { try app.exportPassphrases.setShared(false) } catch {
            CerberusLog.caught(error)
            problem =
                "Could not move it back to this Mac: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    private func setKey(_ shared: Bool) async {
        problem = nil
        guard
            await app.gate(
                .editSecret,
                reason: shared
                    ? "Keep the vault key in iCloud Keychain"
                    : "Keep the vault key on this Mac only",
                declined: $problem
            )
        else { return }
        do { try await app.vault.setKeySynchronized(shared) } catch VaultError.dataKeyConflict where !shared {
            // Not a failure: there are two keys, and the person decides whether to merge them.
            offersMerge = true
        } catch {
            CerberusLog.caught(error)
            problem =
                "Could not change where the vault key is kept: \(error.localizedDescription)"
        }
        await refresh()
    }

    private func mergeKeys() async {
        problem = nil
        guard !isMerging else { return }
        isMerging = true
        defer { isMerging = false }
        do {
            let report = try await VaultKeyMerge.mergeKeepingThisMacsKey(
                vault: app.vault, context: modelContext, recordings: RecordingStore())
            CerberusLog.info("vault", "keys merged: \(report.itemsResealed) credentials and \(report.recordingsResealed) recordings re-sealed")
            if report.recordingsLeftAlone > 0 {
                problem = "\(report.recordingsLeftAlone) session recording(s) could not be opened with either key, so they were left as they were."
            }
        } catch {
            CerberusLog.caught(error)
            problem = "The keys were not merged, and nothing was removed: \(error.localizedDescription)"
        }
        await refresh()
    }
}
