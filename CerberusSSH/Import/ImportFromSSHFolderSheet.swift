import SwiftUI
import SwiftData
import CerberusModels
import CerberusVault

/// Offers to bring keys and trusted hosts in from `~/.ssh` (spec §6.5). Shown once on a fresh
/// install that has something there, and on request from the Welcome screen. It only reads
/// the folder; nothing is changed or removed from it.
struct ImportFromSSHFolderSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var scan = SSHDirectoryScan()
    @State private var knownHosts: KnownHostsParser.Result?
    @State private var includeKnownHosts = true
    @State private var chosen = Set<String>()
    @State private var passphrases: [String: String] = [:]
    @State private var isWorking = false
    @State private var didScan = false
    @State private var outcome: Outcome?

    struct Outcome {
        var keysImported = 0
        var hostKeysAdded = 0
        var problems: [String] = []
    }

    private var selectedKeys: [SSHDirectoryScan.KeyFile] { scan.keys.filter { chosen.contains($0.id) } }

    private var canImport: Bool {
        guard !isWorking else { return false }
        let hasHosts = includeKnownHosts && (knownHosts?.records.isEmpty == false)
        return hasHosts || !selectedKeys.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import from ~/.ssh", systemImage: "square.and.arrow.down.on.square")
                .font(.title2.bold())

            if let outcome {
                done(outcome)
            } else if !didScan {
                ProgressView().frame(maxWidth: .infinity)
            } else if scan.isEmpty {
                Text("Nothing to import was found in ~/.ssh. You can add keys in Settings ▸ Keys and import a known_hosts file from Settings ▸ Backup.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                chooser
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to copy into CerberusSSH. Keys are sealed in the vault; your ~/.ssh folder is left exactly as it is.")
                .font(.callout).foregroundStyle(.secondary)

            if let knownHosts, !knownHosts.records.isEmpty {
                GroupBox("Trusted hosts") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("known_hosts: \(knownHosts.records.count) host key\(knownHosts.records.count == 1 ? "" : "s")", isOn: $includeKnownHosts)
                        if knownHosts.skippedTotal > 0 {
                            Text("\(knownHosts.skippedTotal) other entr\(knownHosts.skippedTotal == 1 ? "y" : "ies") can't be used (hashed names, wildcards, or key types the app doesn't support).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !scan.keys.isEmpty {
                GroupBox("Keys") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scan.keys) { key in
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle(isOn: Binding(
                                    get: { chosen.contains(key.id) },
                                    set: { if $0 { chosen.insert(key.id) } else { chosen.remove(key.id) } }
                                )) {
                                    HStack {
                                        Text(key.fileName)
                                        Text(key.algorithm).font(.caption).foregroundStyle(.secondary)
                                        if key.isEncrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                                    }
                                }
                                if key.isEncrypted, chosen.contains(key.id) {
                                    SecureField("Passphrase", text: Binding(
                                        get: { passphrases[key.id] ?? "" }, set: { passphrases[key.id] = $0 }
                                    ))
                                    .padding(.leading, 20)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Not Now", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import", systemImage: "square.and.arrow.down") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    private func done(_ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Imported \(outcome.keysImported) key\(outcome.keysImported == 1 ? "" : "s") and \(outcome.hostKeysAdded) host key\(outcome.hostKeysAdded == 1 ? "" : "s").",
                  systemImage: "checkmark.circle.fill").foregroundStyle(Color.statusGood)
            ForEach(outcome.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning).font(.callout)
            }
            if outcome.keysImported > 0 {
                Text("To sign in with an imported key, choose it in an identity (Settings ▸ Identities).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func load() async {
        guard !didScan else { return }
        let found = await Task.detached { SSHDirectoryScan.scan(SSHDirectoryScan.defaultDirectory) }.value
        scan = found
        chosen = Set(found.keys.map(\.id))
        if let url = found.knownHostsURL {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                knownHosts = KnownHostsParser.parse(text)
            } else {
                CerberusLog.warning("import", "Could not read \(url.path)")
            }
        }
        didScan = true
    }

    private func run() async {
        isWorking = true
        defer { isWorking = false }
        var outcome = Outcome()

        for key in selectedKeys {
            do {
                let pem = try String(contentsOf: key.url, encoding: .utf8)
                let publicText = key.publicKeyURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                try await VaultKeyService.importKey(
                    name: availableName(for: key.fileName), privateKeyPEM: pem,
                    passphrase: key.isEncrypted ? passphrases[key.id] : nil,
                    publicKeyText: publicText, context: modelContext, vault: app.vault
                )
                outcome.keysImported += 1
            } catch {
                CerberusLog.caught(error)
                outcome.problems.append("\(key.fileName): \((error as? LocalizedError)?.errorDescription ?? (error as? VaultError)?.description ?? error.localizedDescription)")
            }
        }

        if includeKnownHosts, let knownHosts, !knownHosts.records.isEmpty {
            do {
                let result = try await BackupService.apply(
                    BackupService.archive(from: knownHosts), mode: .merge, context: modelContext, vault: app.vault
                )
                outcome.hostKeysAdded = result.added
            } catch {
                CerberusLog.caught(error)
                outcome.problems.append("known_hosts: \(error.localizedDescription)")
            }
        }
        self.outcome = outcome
    }

    /// The file name, or the file name with a number if a key already has it.
    private func availableName(for base: String) -> String {
        var candidate = base
        var n = 2
        while VaultKeyService.nameProblem(candidate, in: modelContext) != nil {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }
}

/// Decides when the import offer appears by itself: once, on an install with nothing in it.
enum FirstLaunchImport {
    static let offeredKey = "firstLaunchImportOffered"

    /// `true` when the offer should be made now.
    @MainActor
    static func shouldOffer(context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
        guard !UITesting.isActive || UITesting.allowsFirstLaunchOffer, !defaults.bool(forKey: offeredKey) else { return false }
        var host = FetchDescriptor<SSHHost>(); host.fetchLimit = 1
        var key = FetchDescriptor<VaultKey>(); key.fetchLimit = 1
        var trusted = FetchDescriptor<KnownHostKey>(); trusted.fetchLimit = 1
        let empty = context.fetchLogged(host).isEmpty && context.fetchLogged(key).isEmpty && context.fetchLogged(trusted).isEmpty
        return empty && !SSHDirectoryScan.scan(SSHDirectoryScan.defaultDirectory).isEmpty
    }

    static func markOffered(defaults: UserDefaults = .standard) { defaults.set(true, forKey: offeredKey) }
}
