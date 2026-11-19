import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault

extension UTType {
    /// `.cerberusvault`, a passphrase-sealed backup.
    static let cerberusVault = UTType(filenameExtension: "cerberusvault") ?? .data
}

/// Fetches the singleton settings record, creating it on first use.
@MainActor
func appSettings(in context: ModelContext) -> AppSettings {
    if let existing = context.fetchLogged(FetchDescriptor<AppSettings>()).first { return existing }
    let settings = AppSettings()
    context.insert(settings)
    return settings
}

// MARK: - Passphrase strength

/// A deliberately simple estimate. A weak passphrase warns but never blocks (§6.6).
enum PassphraseStrength {
    case empty, weak, fair, strong

    init(_ passphrase: String) {
        if passphrase.isEmpty { self = .empty; return }
        let classes = [
            passphrase.contains { $0.isLowercase },
            passphrase.contains { $0.isUppercase },
            passphrase.contains { $0.isNumber },
            passphrase.contains { !$0.isLetter && !$0.isNumber },
        ].filter { $0 }.count
        let words = passphrase.split(whereSeparator: \.isWhitespace).count
        let score = passphrase.count + classes * 3 + (words >= 4 ? 8 : 0)
        self = score < 14 ? .weak : score < 22 ? .fair : .strong
    }

    var label: String {
        switch self {
        case .empty: "Enter a passphrase"
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        }
    }

    var fraction: Double {
        switch self {
        case .empty: 0
        case .weak: 0.25
        case .fair: 0.6
        case .strong: 1
        }
    }

    var color: Color {
        switch self {
        case .empty, .weak: Color.statusBad
        case .fair: Color.statusWarning
        case .strong: Color.statusGood
        }
    }
}

// MARK: - Export

struct ExportBackupSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var options = BackupOptions()
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var summary: BackupSummary?
    @State private var savedName: String?
    /// With no passphrase saved: save the one typed here in the Keychain.
    @State private var remember = false
    @State private var hasRemembered = false
    /// With one saved: type another for this backup instead of using the saved one.
    @State private var useDifferent = false
    /// With one saved and another typed: make the typed one the saved one.
    @State private var replaceSaved = false

    private var strength: PassphraseStrength { PassphraseStrength(passphrase) }
    /// The saved passphrase will be used, with nothing to type.
    private var usingSaved: Bool { hasRemembered && !useDifferent }
    private var canExport: Bool {
        guard !isWorking else { return false }
        return usingSaved || (!passphrase.isEmpty && passphrase == confirmation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export Vault Backup", systemImage: "square.and.arrow.up")
                .font(.title2.bold())

            if let summary {
                result(summary)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { hasRemembered = ((try? app.exportPassphrases.load()) ?? nil) != nil }
    }

    @ViewBuilder
    private var passphraseSection: some View {
        if usingSaved {
            VStack(alignment: .leading, spacing: 6) {
                Label("Using the saved passphrase", systemImage: "key.fill")
                    .accessibilityIdentifier("backup-using-saved")
                Text("This backup will open with the passphrase saved in the Keychain, which importing tries first. Touch ID or your password is asked for when it is used, if that is your setting.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use a Different Passphrase…", systemImage: "pencil") { useDifferent = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("backup-use-different")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Passphrase", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                HStack {
                    ProgressView(value: strength.fraction).tint(strength.color).frame(width: 120)
                    Text(strength.label).font(.caption).foregroundStyle(strength.color)
                }
                if strength == .weak {
                    Text("This passphrase is easy to guess. You can still use it.")
                        .font(.caption).foregroundStyle(Color.statusWarning)
                }
                if !confirmation.isEmpty && confirmation != passphrase {
                    Text("The passphrases don't match.").font(.caption).foregroundStyle(Color.statusBad)
                }
                if hasRemembered {
                    Toggle("Replace the saved passphrase with this one", isOn: $replaceSaved)
                        .accessibilityIdentifier("backup-replace-saved")
                    Text(replaceSaved
                         ? "Automatic backups and later imports will use this passphrase. A backup made with the old one can then be opened only by typing the old one, so keep it."
                         : "This passphrase is used for this backup only. The saved one stays, and importing this backup will ask you to type this one.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use the Saved Passphrase Instead", systemImage: "key") { useDifferent = false; replaceSaved = false }
                        .controlSize(.small)
                } else {
                    Toggle("Save this passphrase in the Keychain", isOn: $remember)
                        .accessibilityIdentifier("backup-save-passphrase")
                    Text("Saves typing it next time, and importing tries it first. It is shown again only after Touch ID or your password. You can share it with your other Macs through iCloud Keychain in Settings ▸ Advanced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Include") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Hosts, folders, tags and identities", isOn: .constant(true)).disabled(true)
                    Toggle("Vault secrets (passwords and keys)", isOn: $options.includeSecrets)
                    Toggle("Known host keys", isOn: $options.includeKnownHosts)
                    Toggle("Snippets", isOn: $options.includeSnippets)
                    Toggle("Preferences (appearance and behaviour)", isOn: $options.includePreferences)
                        .accessibilityIdentifier("backup-include-preferences")
                    Text("Your own terminal themes are always included. Security settings (the Touch ID gate, the idle lock) and this Mac's own settings never are.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !options.includeSecrets {
                        Text("A catalogue-only export contains no passwords or keys, so it is safe to share.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            passphraseSection

            Label {
                Text(usingSaved
                     ? "The saved passphrase is the only thing that opens this backup. If it is cleared from the Keychain and you do not remember it, the backup is permanently unreadable."
                     : (remember || replaceSaved
                        ? "If you lose the passphrase, the backup is permanently unreadable. The copy in the Keychain will not help if you lose this Mac, unless you share it with your other Macs (Settings ▸ Advanced)."
                        : "The passphrase is not stored anywhere and cannot be recovered. If you lose it, the backup is permanently unreadable."))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
            }
            .font(.callout)

            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(Color.statusBad)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…", systemImage: "square.and.arrow.up") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
    }

    private func result(_ summary: BackupSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved \(savedName ?? "backup")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.statusGood)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text("Hosts"); Text("\(summary.hosts)") }
                GridRow { Text("Folders"); Text("\(summary.groups)") }
                GridRow { Text("Identities"); Text("\(summary.identities)") }
                GridRow { Text("Secrets"); Text("\(summary.secrets)") }
                GridRow { Text("Known host keys"); Text("\(summary.knownHostKeys)") }
                GridRow { Text("Snippets"); Text("\(summary.snippets)") }
                GridRow { Text("Themes"); Text("\(summary.themes)") }
                GridRow { Text("Preferences"); Text(summary.includesPreferences ? "included" : "not included") }
            }
            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
            Text(summary.fileSHA256)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func export() async {
        error = nil
        isWorking = true
        defer { isWorking = false }

        // Exporting is a bulk secret reveal.
        if options.includeSecrets {
            guard await app.gate(.export, reason: "Export your vault secrets", declined: $error) else { return }
        }
        // The saved passphrase is read now, behind the gate, rather than shown on screen.
        var usable = passphrase
        if usingSaved {
            // With secrets the gate has just been passed, so it is not asked a second time.
            let saved = options.includeSecrets ? ((try? app.exportPassphrases.load()) ?? nil) : await app.rememberedBackupPassphrase()
            guard let saved else { error = "The saved passphrase could not be read."; return }
            usable = saved
        }

        do {
            let (data, summary) = try await BackupService.export(
                context: modelContext, vault: app.vault, options: options, passphrase: usable,
                themes: app.customThemes
            )

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.cerberusVault]
            panel.nameFieldStringValue = "CerberusSSH \(Date.now.formatted(.iso8601.year().month().day())).cerberusvault"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            // Atomic: a partial write is discarded, never left behind.
            try data.write(to: url, options: .atomic)

            appSettings(in: modelContext).lastExportAt = Date()
            modelContext.saveLogged()
            if !hasRemembered && remember {
                do { try app.exportPassphrases.save(usable) } catch { CerberusLog.caught(error) }
            } else if hasRemembered && useDifferent && replaceSaved,
                      await app.gate(.editSecret, reason: "Replace the saved backup passphrase") {
                do { try app.exportPassphrases.save(usable) } catch { CerberusLog.caught(error) }
            }
            hasRemembered = ((try? app.exportPassphrases.load()) ?? nil) != nil
            savedName = url.lastPathComponent
            self.summary = summary
            passphrase = ""
            confirmation = ""
            usable = ""
        } catch let archiveError as VaultArchiveError {
            CerberusLog.caught(archiveError)
            error = archiveError.description
        } catch let vaultError as VaultError {
            CerberusLog.caught(vaultError)
            error = vaultError.description
        } catch {
            CerberusLog.caught(error)
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Import

struct ImportBackupSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var fileURL: URL?
    @State private var passphrase = ""
    @State private var archive: BackupArchive?
    @State private var preview: ImportPreview?
    @State private var mode: ModeChoice = .merge
    @State private var restorePreferences = true
    @State private var replaceConfirmation = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: ImportResult?
    @State private var hasRemembered = false
    /// Said above the passphrase field when the saved passphrase was tried first and did not open the file.
    @State private var note: String?

    enum ModeChoice: String, CaseIterable, Identifiable {
        case merge = "Merge"
        case prefer = "Merge, preferring the file"
        case replace = "Replace everything"
        var id: String { rawValue }
        var importMode: ImportMode {
            switch self {
            case .merge: .merge
            case .prefer: .mergePreferringImport
            case .replace: .replace
            }
        }
    }

    private var canApply: Bool {
        guard archive != nil, !isWorking else { return false }
        return mode != .replace || replaceConfirmation == "REPLACE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Vault Backup", systemImage: "square.and.arrow.down")
                .font(.title2.bold())

            if let result {
                done(result)
            } else if let preview {
                previewView(preview)
            } else {
                unlock
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { hasRemembered = ((try? app.exportPassphrases.load()) ?? nil) != nil }
    }

    private var unlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose file…", systemImage: "doc", action: chooseFile)
                Text(fileURL?.lastPathComponent ?? "No file chosen")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .accessibilityIdentifier("import-saved-failed")
            }
            SecureField("Passphrase", text: $passphrase)
            Text(hasRemembered && note == nil
                 ? "The saved passphrase is tried first when you choose a file; if it does not open it you are asked for the passphrase. The file is verified before anything on this Mac is changed."
                 : "The file is verified before anything on this Mac is changed.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(Color.statusBad) }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", systemImage: "play.rectangle") { Task { await open() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileURL == nil || passphrase.isEmpty || isWorking)
            }
        }
    }

    private func previewView(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("In this backup") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("").frame(width: 120)
                        Text("New").bold(); Text("Same").bold(); Text("Differs").bold()
                    }
                    row("Hosts", preview.hosts)
                    row("Folders", preview.groups)
                    row("Identities", preview.identities)
                    row("Snippets", preview.snippets)
                    row("Host keys", preview.knownHostKeys)
                    GridRow { Text("Themes"); Text("\(preview.themes)"); Text(""); Text("") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if preview.includesPreferences {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Also restore its preferences (appearance and behaviour)", isOn: $restorePreferences)
                        .accessibilityIdentifier("import-restore-preferences")
                    Text("Security settings are never part of a backup, so the Touch ID gate and the idle lock stay as they are here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !preview.includesSecrets {
                Label("This backup has no secrets. Hosts will ask for a password or key when you connect.", systemImage: "info.circle")
                    .font(.callout)
            }
            if !preview.hostKeyConflicts.isEmpty {
                conflicts(preview.hostKeyConflicts)
            }

            Picker("Mode", selection: $mode) {
                ForEach(ModeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if mode == .replace {
                VStack(alignment: .leading, spacing: 4) {
                    Label("This deletes every host, identity, secret and snippet on this Mac first.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusBad)
                    TextField("Type REPLACE to confirm", text: $replaceConfirmation)
                }
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(Color.statusBad) }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
    }

    private func row(_ title: String, _ counts: ImportPreview.Counts) -> some View {
        GridRow {
            Text(title)
            Text("\(counts.new)"); Text("\(counts.identical)"); Text("\(counts.different)")
        }
    }

    private func conflicts(_ conflicts: [HostKeyConflict]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Different host keys for hosts you already trust", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(Color.statusWarning)
            Text("These are never overwritten. Resolve them by connecting and using “Replace stored key” if you trust the new one.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(conflicts, id: \.hostPattern) { conflict in
                Text("\(conflict.hostPattern): \(conflict.storedFingerprint) ≠ \(conflict.importedFingerprint)")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func done(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import complete", systemImage: "checkmark.circle.fill").foregroundStyle(Color.statusGood)
            Text("\(result.added) added, \(result.updated) updated, \(result.skipped) left as they were.")
            if result.identitiesWithoutSecrets > 0 {
                Text("\(result.identitiesWithoutSecrets) identities have no saved secret and will prompt on connect.")
                    .foregroundStyle(.secondary)
            }
            if !result.hostKeyConflicts.isEmpty {
                conflicts(result.hostKeyConflicts)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.cerberusVault, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            fileURL = panel.url
            error = nil
            note = nil
            // The passphrase saved in the Keychain is the likeliest, so it goes first; the field is the way out.
            if hasRemembered { Task { await openWithSaved() } }
        }
    }

    private func openWithSaved() async {
        guard let saved = await app.rememberedBackupPassphrase() else { return }   // refused or gone: the field is there
        await open(with: saved, savedOne: true)
    }

    private func open() async { await open(with: passphrase, savedOne: false) }

    private func open(with attempt: String, savedOne: Bool) async {
        guard let fileURL else { return }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try Data(contentsOf: fileURL)
            let opened = try await BackupService.open(file: data, passphrase: attempt)
            preview = try BackupService.preview(opened, context: modelContext)
            archive = opened
            passphrase = ""
            note = nil
        } catch VaultArchiveError.wrongPassphraseOrCorrupt where savedOne {
            // Not an error: this backup was made with another passphrase. Ask for it.
            note = "The saved passphrase does not open this backup. Type the passphrase it was made with."
        } catch let archiveError as VaultArchiveError {
            CerberusLog.caught(archiveError)
            error = archiveError.description
        } catch {
            CerberusLog.caught(error)
            self.error = error.localizedDescription
        }
    }

    private func apply() async {
        guard let archive else { return }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            // Replacing wipes the catalogue, which is as sensitive as revealing it.
            if mode == .replace {
                guard await app.gate(.replaceAll, reason: "Replace all hosts and secrets from a backup", declined: $error) else { return }
                // Live sessions would be left pointing at deleted hosts.
                await app.closeAll()
            }
            let applied = try await BackupService.apply(
                archive, mode: mode.importMode, context: modelContext, vault: app.vault,
                currentThemes: app.customThemes,
                restorePreferences: restorePreferences && (preview?.includesPreferences ?? false)
            )
            // The person's own themes live in a file of this Mac: save the merged list.
            if let themes = applied.themes { app.replaceCustomThemes(themes) }
            result = applied
        } catch let vaultError as VaultError {
            CerberusLog.caught(vaultError)
            error = vaultError.description
        } catch {
            CerberusLog.caught(error)
            self.error = error.localizedDescription
        }
    }
}
