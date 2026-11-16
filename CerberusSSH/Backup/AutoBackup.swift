import SwiftUI
import SwiftData
import AppKit
import CerberusModels
import CerberusVault

/// Where automatic backups are configured. Kept in the user defaults rather than in the
/// catalogue on purpose: a folder and a schedule belong to this Mac, and must not travel
/// to another one with the hosts.
enum AutoBackupSettings {
    static let enabledKey = "autoBackupEnabled"
    static let folderKey = "autoBackupFolder"
    static let frequencyKey = "autoBackupFrequency"
    static let keepKey = "autoBackupKeep"
    static let lastAtKey = "autoBackupLastAt"
    static let lastErrorKey = "autoBackupLastError"
    static let lastFileKey = "autoBackupLastFile"

    static var defaults: UserDefaults { .standard }

    static var isEnabled: Bool { defaults.bool(forKey: enabledKey) }
    static var folderURL: URL? {
        defaults.string(forKey: folderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var frequency: BackupFrequency { BackupFrequency(stored: defaults.string(forKey: frequencyKey) ?? "") }
    static var keep: Int {
        let stored = defaults.integer(forKey: keepKey)
        return stored > 0 ? stored : BackupSchedule.defaultKeep
    }
    static var lastBackupAt: Date? {
        let value = defaults.double(forKey: lastAtKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}

enum AutoBackupError: LocalizedError {
    case folderMissing(String)
    case noPassphrase

    var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            "The backup folder isn't available: \(path). If it is on an external drive, connect it; the backup will be retried."
        case .noPassphrase:
            "No backup passphrase is saved in the Keychain, so a backup can't be made without you. Open Settings ▸ Backup and set up automatic backups again."
        }
    }
}

extension AppModel {
    /// Takes a backup into the chosen folder if one is due (or `force`), then removes the oldest
    /// automatic ones beyond the number to keep. Never asks anything: the passphrase comes from
    /// the Keychain, where the person put it when they set this up. A failure is remembered and
    /// shown in Settings ▸ Backup, and the next check tries again.
    func runAutoBackup(force: Bool = false) async {
        let defaults = AutoBackupSettings.defaults
        guard AutoBackupSettings.isEnabled, !isAutoBackupRunning, let context, isVaultReady else { return }
        guard force || BackupSchedule.isDue(lastBackupAt: AutoBackupSettings.lastBackupAt, frequency: AutoBackupSettings.frequency) else { return }

        isAutoBackupRunning = true
        defer { isAutoBackupRunning = false }
        do {
            guard let folder = AutoBackupSettings.folderURL else { throw AutoBackupError.folderMissing("none chosen") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AutoBackupError.folderMissing(folder.path)
            }
            guard let passphrase = try exportPassphrases.load(), !passphrase.isEmpty else { throw AutoBackupError.noPassphrase }

            let (data, summary) = try await BackupService.export(
                context: context, vault: vault, options: BackupOptions(), passphrase: passphrase,
                themes: customThemes
            )
            let now = Date()
            let name = BackupSchedule.fileName(for: now)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)

            // Old ones go only after the new one is safely written.
            let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for old in BackupSchedule.namesToDelete(among: present, keep: AutoBackupSettings.keep) {
                do { try FileManager.default.removeItem(at: folder.appendingPathComponent(old)) } catch {
                    CerberusLog.caught(error, note: "removing old backup \(old)")
                }
            }

            defaults.set(now.timeIntervalSince1970, forKey: AutoBackupSettings.lastAtKey)
            defaults.set(name, forKey: AutoBackupSettings.lastFileKey)
            defaults.removeObject(forKey: AutoBackupSettings.lastErrorKey)
            appSettings(in: context).lastExportAt = now
            context.saveLogged()
            CerberusLog.info("backup", "Automatic backup written: \(name) (\(summary.hosts) hosts, \(summary.secrets) secrets)")
        } catch {
            CerberusLog.caught(error, note: "automatic backup")
            defaults.set((error as? LocalizedError)?.errorDescription ?? (error as? VaultError)?.description ?? error.localizedDescription,
                         forKey: AutoBackupSettings.lastErrorKey)
        }
    }

    /// Checks soon after launch and then every quarter of an hour while the app is open, which
    /// is how a backup comes due on a Mac that is never restarted.
    func startAutoBackupSchedule() {
        autoBackupTask?.cancel()
        autoBackupTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutoBackup()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }
}

// MARK: - Settings section

struct AutoBackupSection: View {
    let hasFirstBackup: Bool

    @Environment(AppModel.self) private var app
    @AppStorage(AutoBackupSettings.enabledKey) private var enabled = false
    @AppStorage(AutoBackupSettings.folderKey) private var folder = ""
    @AppStorage(AutoBackupSettings.frequencyKey) private var frequencyRaw = BackupFrequency.weekly.rawValue
    @AppStorage(AutoBackupSettings.keepKey) private var keep = BackupSchedule.defaultKeep
    @AppStorage(AutoBackupSettings.lastAtKey) private var lastAt = 0.0
    @AppStorage(AutoBackupSettings.lastErrorKey) private var lastError = ""
    @State private var isSettingUp = false

    private var frequency: BackupFrequency { BackupFrequency(stored: frequencyRaw) }
    private var last: Date? { lastAt > 0 ? Date(timeIntervalSince1970: lastAt) : nil }

    var body: some View {
        Section("Automatic backups") {
            if !hasFirstBackup && !enabled {
                Text("Make your first backup above. Once you have, CerberusSSH can keep making them for you into a folder you choose.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !enabled {
                Button("Set Up Automatic Backups…", systemImage: "clock.arrow.2.circlepath") { isSettingUp = true }
                Text("Saves a fresh encrypted backup to a folder on a schedule, and removes the oldest ones, so a recent copy is always there.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Folder") {
                    Text(folder).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("Schedule", value: "\(frequency.title), keeping the last \(keep)")
                LabeledContent("Last automatic backup") {
                    if let last { Text(last.formatted(date: .abbreviated, time: .shortened)) }
                    else { Text("None yet").foregroundStyle(.secondary) }
                }
                if lastError.isEmpty, app.isAutoBackupRunning == false {
                    LabeledContent("Next") {
                        Text(BackupSchedule.nextDue(lastBackupAt: last, frequency: frequency)
                            .formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                }
                if !lastError.isEmpty {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusWarning).font(.callout)
                }
                HStack {
                    Button("Back Up Now", systemImage: "arrow.clockwise") { Task { await app.runAutoBackup(force: true) } }
                        .disabled(app.isAutoBackupRunning)
                    Button("Change…", systemImage: "slider.horizontal.3") { isSettingUp = true }
                    Button("Turn Off", systemImage: "xmark.circle") { enabled = false }
                    if app.isAutoBackupRunning { ProgressView().controlSize(.small) }
                }
                Text("The passphrase is kept in the Keychain (on this Mac, and on your others if you share it in Settings ▸ Advanced) so backups can be made without you. Backups made this way include your secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isSettingUp) { AutoBackupSetupSheet() }
    }
}

// MARK: - Setup

struct AutoBackupSetupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var folder = AutoBackupSettings.folderURL?.path ?? ""
    @State private var frequency = AutoBackupSettings.frequency
    @State private var keep = AutoBackupSettings.keep
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var hasSaved = false
    @State private var useSaved = true
    @State private var isWorking = false
    @State private var error: String?

    private var strength: PassphraseStrength { PassphraseStrength(passphrase) }
    private var passphraseReady: Bool {
        (hasSaved && useSaved) || (!passphrase.isEmpty && passphrase == confirmation)
    }
    private var canSave: Bool { !folder.isEmpty && passphraseReady && !isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Automatic Backups", systemImage: "clock.arrow.2.circlepath").font(.title2.bold())

            GroupBox("Where and how often") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(folder.isEmpty ? "No folder chosen" : folder)
                            .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                    Picker("Frequency", selection: $frequency) {
                        ForEach(BackupFrequency.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Keep", selection: $keep) {
                        ForEach(BackupSchedule.keepChoices, id: \.self) { Text("the last \($0) backups").tag($0) }
                    }
                    Text("Older automatic backups are removed. Files you export yourself are never touched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Passphrase") {
                VStack(alignment: .leading, spacing: 6) {
                    if hasSaved {
                        Toggle("Use the passphrase already saved in the Keychain", isOn: $useSaved)
                    }
                    if !(hasSaved && useSaved) {
                        SecureField("Passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirmation)
                        HStack {
                            ProgressView(value: strength.fraction).tint(strength.color).frame(width: 120)
                            Text(strength.label).font(.caption).foregroundStyle(strength.color)
                        }
                        if !confirmation.isEmpty && confirmation != passphrase {
                            Text("The passphrases don't match.").font(.caption).foregroundStyle(Color.statusBad)
                        }
                    }
                    Text("It is saved in the Keychain so backups can run without you. You need it to restore, so keep a copy somewhere else too: it will not help if this Mac is lost, unless you share it with your other Macs (Settings ▸ Advanced).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Label("These backups include your passwords and keys, sealed with that passphrase.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)

            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(Color.statusBad) }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Turn On") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            hasSaved = ((try? app.exportPassphrases.load()) ?? nil) != nil
            useSaved = hasSaved
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for automatic backups"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        // Unattended backups include every secret, so turning them on is an export (spec §6.4).
        guard await app.gate(.export, reason: "Turn on automatic backups of your vault", declined: $error) else { return }
        // The folder has to be writable now, not at the first backup.
        let probe = URL(fileURLWithPath: folder).appendingPathComponent(".cerberus-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            CerberusLog.caught(error, note: "checking the backup folder")
            self.error = "CerberusSSH can't write to that folder: \(error.localizedDescription)"
            return
        }
        do {
            if !(hasSaved && useSaved) { try app.exportPassphrases.save(passphrase) }
        } catch {
            CerberusLog.caught(error)
            self.error = "Could not save the passphrase in the Keychain: \(error.localizedDescription)"
            return
        }
        let defaults = AutoBackupSettings.defaults
        defaults.set(folder, forKey: AutoBackupSettings.folderKey)
        defaults.set(frequency.rawValue, forKey: AutoBackupSettings.frequencyKey)
        defaults.set(keep, forKey: AutoBackupSettings.keepKey)
        defaults.removeObject(forKey: AutoBackupSettings.lastErrorKey)
        defaults.set(true, forKey: AutoBackupSettings.enabledKey)
        passphrase = ""
        confirmation = ""
        dismiss()
        // The first automatic backup is taken now, so a problem shows while the person is here.
        await app.runAutoBackup(force: true)
    }
}
