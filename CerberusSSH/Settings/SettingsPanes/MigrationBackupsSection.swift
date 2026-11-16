import CerberusModels
import CerberusSSHCore
import SwiftUI

/// The copies of the catalogue made before a migration (Settings ▸ Advanced): which there are, and putting one back
/// (the catalogue is migrated again from it) or removing it. See ``StoreBackups``.
struct MigrationBackupsSection: View {
    @Environment(AppModel.self) private var app

    @State private var backups: [StoreBackup] = []
    @State private var pending: String?
    @State private var restoring: StoreBackup?
    @State private var deleting: StoreBackup?
    @State private var isDeletingAll = false
    @State private var message: String?

    private var folder: URL { app.storeBackupFolder }

    var body: some View {
        Section("Migration backups") {
            Text(
                "When CerberusSSH opens a catalogue written by an older version, it first copies it here, named after that version, so a migration that goes wrong can be undone. Re-migrate puts a copy back as the catalogue and migrates it again the next time CerberusSSH starts; what you have now is kept as a backup first. A copy holds what the catalogue holds, saved passwords and keys sealed, so delete the ones you no longer need."
            )
            .font(.caption).foregroundStyle(.secondary)

            if backups.isEmpty {
                Text("No backups yet. One is made the next time a newer version of CerberusSSH migrates your catalogue.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("migration-backups-empty")
            } else {
                ForEach(backups) { backup in row(backup) }
            }

            if let pending {
                HStack {
                    Label("\(pending) will be put back when CerberusSSH next starts.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                    Spacer()
                    Button("Cancel Re-migrate") {
                        StoreBackups.cancelRestore(in: folder)
                        refresh()
                    }
                    .accessibilityIdentifier("migration-backups-cancel-pending")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("migration-backups-pending")
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Show in Finder", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Spacer()
                Button("Delete All…", systemImage: "trash", role: .destructive) { isDeletingAll = true }
                    .disabled(backups.isEmpty)
                    .accessibilityIdentifier("migration-backups-delete-all")
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Re-migrate from version \(restoring?.version ?? "")?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible,
            presenting: restoring
        ) { backup in
            Button("Re-migrate and Quit", role: .destructive) { restore(backup, thenQuit: true) }
                .accessibilityIdentifier("migration-backups-remigrate-quit")
            Button("Re-migrate at Next Launch") { restore(backup, thenQuit: false) }
                .accessibilityIdentifier("migration-backups-remigrate-later")
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("The catalogue is replaced by the copy from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) and migrated again when CerberusSSH starts, so what you changed since then is not in it. The catalogue as it is now is kept as a backup first. Open sessions are closed if you quit now.")
        }
        .confirmationDialog(
            "Delete this backup?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { backup in
            Button("Delete", role: .destructive) { remove(backup) }
                .accessibilityIdentifier("migration-backups-confirm-delete")
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("The copy from version \(backup.version), taken \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)), is deleted for good.")
        }
        .confirmationDialog(
            "Delete all \(backups.count) backups?",
            isPresented: $isDeletingAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                StoreBackups.deleteAll(in: folder)
                message = "All backups deleted."
                refresh()
            }
            .accessibilityIdentifier("migration-backups-confirm-delete-all")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are deleted for good, and a re-migrate that is waiting is cancelled.")
        }
    }

    private func row(_ backup: StoreBackup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: backup)).fontWeight(.medium)
                Text("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-migrate…") { restoring = backup }
                .disabled(pending != nil)
                .accessibilityIdentifier("migration-backup-remigrate-\(backup.version)")
            Button("Delete…", role: .destructive) { deleting = backup }
                .accessibilityIdentifier("migration-backup-delete-\(backup.version)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("migration-backup-\(backup.version)")
    }

    private func title(of backup: StoreBackup) -> String {
        switch backup.reason {
        case .migration: "From version \(backup.version)"
        case .beforeRestore: "Before a re-migrate (version \(backup.version))"
        }
    }

    private func refresh() {
        backups = StoreBackups.list(in: folder)
        pending = StoreBackups.pendingRestore(in: folder)
    }

    private func remove(_ backup: StoreBackup) {
        do {
            try StoreBackups.delete(backup)
            message = "Deleted the backup from version \(backup.version)."
        } catch {
            CerberusLog.caught(error)
            message = "Could not delete it: \(error.localizedDescription)"
        }
        refresh()
    }

    private func restore(_ backup: StoreBackup, thenQuit: Bool) {
        Task {
            // Replacing the whole catalogue is as weighty as erasing it, so it asks the same way.
            guard await app.gate(.replaceAll, reason: "Re-migrate CerberusSSH from an earlier backup", declined: $message) else { return }
            do {
                try StoreBackups.scheduleRestore(of: backup)
            } catch {
                CerberusLog.caught(error)
                message = "Could not schedule it: \(error.localizedDescription)"
                refresh()
                return
            }
            refresh()
            if thenQuit {
                // The catalogue is open now, so it is swapped at the next start: quit to start it over.
                NSApp.terminate(nil)
            } else {
                message = "Done when CerberusSSH next starts."
            }
        }
    }
}
