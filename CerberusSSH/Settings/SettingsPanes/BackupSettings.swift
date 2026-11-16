import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

struct BackupSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query private var vaultItems: [VaultItem]
    @Query private var hosts: [SSHHost]

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isImportingKnownHosts = false
    @State private var isImportingConfig = false
    @State private var isImportingSSHFolder = false
    @State private var hasSavedPassphrase = false
    @State private var isConfirmingClear = false
    @State private var clearProblem: String?
    @Environment(AppModel.self) private var app

    private var lastExport: Date? { settings.first?.lastExportAt }

    private func refreshSaved() {
        hasSavedPassphrase = ((try? app.exportPassphrases.load()) ?? nil) != nil
    }

    private func clearSaved() async {
        clearProblem = nil
        guard
            await app.gate(
                .editSecret,
                reason: "Clear the saved backup passphrase",
                declined: $clearProblem
            )
        else { return }
        do { try app.exportPassphrases.forget() } catch {
            CerberusLog.caught(error)
            clearProblem = "Could not clear it: \(error.localizedDescription)"
        }
        refreshSaved()
    }

    var body: some View {
        Form {

            Section("Encrypted backup") {
                LabeledContent("Last export") {
                    if let lastExport {
                        Text(
                            lastExport.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                if BackupReminder.isDue(
                    lastExportAt: lastExport,
                    hasSecrets: !vaultItems.isEmpty
                ) {
                    Label(
                        "Your vault has secrets and hasn't been backed up in over 90 days.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Color.statusWarning)
                }
                HStack {
                    Button("Export Backup…", systemImage: "square.and.arrow.up")
                    { isExporting = true }
                    Button(
                        "Import Backup…",
                        systemImage: "square.and.arrow.down"
                    ) { isImporting = true }
                    Button(
                        "Clear Saved Passphrase…",
                        systemImage: "key.slash",
                        role: .destructive
                    ) { isConfirmingClear = true }
                    .disabled(!hasSavedPassphrase)
                    .accessibilityIdentifier("backup-clear-passphrase")
                }
                Text(
                    "A .cerberusvault file is sealed with a passphrase you choose. It restores on any Mac, so keep a copy somewhere other than this Mac."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    hasSavedPassphrase
                        ? "Clear Saved Passphrase removes the backup passphrase from the Keychain, and from your other Macs if it is shared. It cannot be shown to you again, so if you do not remember it, every backup made with it can never be opened. Automatic backups stop until you save a passphrase again, and importing will ask you to type it."
                        : "No backup passphrase is saved in the Keychain. Save one from the export sheet and importing will try it first."
                )
                .font(.caption).foregroundStyle(
                    hasSavedPassphrase ? Color.statusWarning : .secondary
                )
                .accessibilityIdentifier("backup-clear-caption")
                if let clearProblem {
                    Text(clearProblem).font(.caption).foregroundStyle(
                        Color.statusBad
                    )
                }
            }

            AutoBackupSection(hasFirstBackup: lastExport != nil)

            Section("In this vault") {
                LabeledContent("Hosts", value: "\(hosts.count)")
                LabeledContent("Stored secrets", value: "\(vaultItems.count)")
            }
        }
        .formStyle(.grouped)
        .task { refreshSaved() }
        .onChange(of: isExporting) { refreshSaved() }
        .onChange(of: isImporting) { refreshSaved() }
        .confirmationDialog(
            "Clear the saved backup passphrase?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear It", role: .destructive) {
                Task { await clearSaved() }
            }
            .accessibilityIdentifier("backup-confirm-clear-passphrase")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This cannot be undone and the passphrase cannot be read back to you. Backups made with it can be opened only by typing it. If it is shared through iCloud Keychain it is removed from your other Macs too."
            )
        }
        .sheet(isPresented: $isExporting) { ExportBackupSheet() }
        .sheet(isPresented: $isImporting) { ImportBackupSheet() }
    }
}
