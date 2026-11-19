import SwiftUI
import SwiftData
import AppKit
import Darwin
import CerberusModels
import CerberusVault

/// Brings hosts in from an OpenSSH `config` file: a preview of what is in it and what
/// is already here, then an import that never overwrites. The file is only read.
struct ImportSSHConfigSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var existingHosts: [SSHHost]

    @State private var fileURL = SSHDirectoryScan.defaultDirectory.appendingPathComponent("config")
    @State private var parsed: SSHConfigParser.Result?
    @State private var loadError: String?
    @State private var chosen = Set<String>()
    @State private var folderName = "SSH config"
    @State private var passphrases: [String: String] = [:]
    @State private var isWorking = false
    @State private var outcome: SSHConfigImporter.Outcome?

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var chosenHosts: [SSHConfigParser.Host] {
        guard let parsed else { return [] }
        return SSHConfigImporter.withJumpDependencies(of: chosen, in: parsed)
    }
    private var keyNeeds: [SSHConfigImporter.KeyNeed] { SSHConfigImporter.keyNeeds(for: chosenHosts, home: home) }

    private func status(_ host: SSHConfigParser.Host) -> SSHConfigImporter.Status {
        SSHConfigImporter.status(of: host, among: existingHosts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import SSH Config", systemImage: "doc.text").font(.title2.bold())

            if let outcome {
                done(outcome)
            } else if let loadError {
                Label(loadError, systemImage: "xmark.octagon").foregroundStyle(Color.statusBad)
                actions(canImport: false)
            } else if let parsed {
                if parsed.hosts.isEmpty {
                    Text("There are no named hosts in this file to import.").foregroundStyle(.secondary)
                    actions(canImport: false)
                } else {
                    preview(parsed)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { load() }
    }

    // MARK: Preview

    private func preview(_ parsed: SSHConfigParser.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(fileURL.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose File…", action: chooseFile).controlSize(.small)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("All") { chosen = Set(parsed.hosts.filter { status($0) == .new }.map(\.alias)) }
                        Button("None") { chosen = [] }
                        Spacer()
                        Text("\(chosen.count) of \(parsed.hosts.count) chosen").font(.caption).foregroundStyle(.secondary)
                    }
                    .controlSize(.small).padding(.bottom, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(parsed.hosts, id: \.alias) { host in row(host) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 190)
                }
            }

            if !keyNeeds.isEmpty {
                GroupBox("Keys these hosts sign in with") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(keyNeeds) { need in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: need.isEncrypted ? "lock.fill" : "key").foregroundStyle(.secondary)
                                    Text(need.fileName)
                                    Text(need.algorithm).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("used by \(need.usedBy.count)").font(.caption).foregroundStyle(.secondary)
                                }
                                if need.isEncrypted {
                                    SecureField("Passphrase", text: Binding(
                                        get: { passphrases[need.path] ?? "" }, set: { passphrases[need.path] = $0 }
                                    ))
                                }
                            }
                        }
                        Text("Keys are copied into the vault and sealed; the files are left where they are.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Text("Put them in the folder")
                TextField("Folder", text: $folderName).textFieldStyle(.roundedBorder).frame(width: 200)
                Text("(leave empty for none)").font(.caption).foregroundStyle(.secondary)
            }

            notes(parsed)
            actions(canImport: !chosen.isEmpty && !isWorking)
        }
    }

    private func row(_ host: SSHConfigParser.Host) -> some View {
        let state = status(host)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { chosen.contains(host.alias) },
                set: { if $0 { chosen.insert(host.alias) } else { chosen.remove(host.alias) } }
            ))
            .labelsHidden().disabled(state != .new)
            VStack(alignment: .leading, spacing: 0) {
                Text(host.alias)
                Text("\(host.user.map { "\($0)@" } ?? "")\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .new: EmptyView()
            case .same: Text("already here").font(.caption).foregroundStyle(.secondary)
            case .differs(let address): Text("a different host is called this (\(address))").font(.caption).foregroundStyle(Color.statusWarning)
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private func notes(_ parsed: SSHConfigParser.Result) -> some View {
        let lines = noteLines(parsed)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func noteLines(_ parsed: SSHConfigParser.Result) -> [String] {
        var lines: [String] = []
        if parsed.patternBlocks > 0 { lines.append("\(parsed.patternBlocks) wildcard block\(parsed.patternBlocks == 1 ? "" : "s") (Host *) supply defaults to the hosts, and aren't imported themselves.") }
        if parsed.matchBlocks > 0 { lines.append("\(parsed.matchBlocks) Match block\(parsed.matchBlocks == 1 ? "" : "s") skipped.") }
        if parsed.unresolvedIncludes > 0 { lines.append("\(parsed.unresolvedIncludes) Include line\(parsed.unresolvedIncludes == 1 ? "" : "s") found no file.") }
        let converted = parsed.hosts.filter(\.proxyCommandBecameJump).count
        if converted > 0 { lines.append("\(converted) host\(converted == 1 ? "'s" : "s'") ProxyCommand (ssh -W %h:%p …) will become a jump host.") }
        let withProxyCommand = parsed.hosts.filter { $0.proxyCommand != nil }.count
        if withProxyCommand > 0 { lines.append("\(withProxyCommand) host\(withProxyCommand == 1 ? " uses" : "s use") ProxyCommand that is not a plain ssh -W jump, which isn't supported; they'll connect directly.") }
        if !parsed.ignoredOptions.isEmpty {
            let top = parsed.ignoredOptions.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(4).map(\.key).joined(separator: ", ")
            lines.append("Options with no equivalent here are ignored (\(top)\(parsed.ignoredOptions.count > 4 ? ", …" : "")).")
        }
        return lines
    }

    private func actions(canImport: Bool) -> some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Import", systemImage: "square.and.arrow.down") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
        }
    }

    // MARK: Result

    private func done(_ o: SSHConfigImporter.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Imported \(o.hostsAdded) host\(o.hostsAdded == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.statusGood)
            Group {
                if o.jumpHostsAdded > 0 { Text("\(o.jumpHostsAdded) more added because other hosts jump through them.") }
                if o.keysImported + o.keysReused > 0 { Text("\(o.keysImported) key\(o.keysImported == 1 ? "" : "s") added to the vault\(o.keysReused > 0 ? ", \(o.keysReused) already there" : "").") }
                if o.forwardsAdded > 0 { Text("\(o.forwardsAdded) port forward\(o.forwardsAdded == 1 ? "" : "s") added (off until started).") }
                if !o.skippedExisting.isEmpty { Text("Left alone, because they already exist: \(o.skippedExisting.joined(separator: ", ")).") }
            }
            .font(.callout).foregroundStyle(.secondary)
            if !o.needSignIn.isEmpty {
                Label("No key was found for \(o.needSignIn.joined(separator: ", ")). Open each host's settings and choose an identity.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(Color.statusWarning)
            }
            ForEach(o.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Color.statusWarning) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    // MARK: Loading and running

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHDirectoryScan.defaultDirectory
        panel.message = "Choose an OpenSSH config file"
        if panel.runModal() == .OK, let url = panel.url { fileURL = url; load() }
    }

    private func load() {
        parsed = nil
        loadError = nil
        chosen = []
        let ssh = SSHDirectoryScan.defaultDirectory
        let text: String
        do { text = try String(contentsOf: fileURL, encoding: .utf8) } catch {
            let missing = (error as NSError).code == NSFileReadNoSuchFileError
            loadError = missing ? "There is no config file at \(fileURL.path)." : "Could not read \(fileURL.path): \(error.localizedDescription)"
            CerberusLog.caught(error, note: "reading ssh config")
            return
        }
        let result = SSHConfigParser.parse(text) { pattern in Self.readIncludes(pattern, relativeTo: ssh, home: home) }
        parsed = result
        chosen = Set(result.hosts.filter { status($0) == .new }.map(\.alias))
    }

    /// The files an `Include` names: `~` and relative paths (relative to ~/.ssh) are understood, and so are wildcards.
    private static func readIncludes(_ pattern: String, relativeTo ssh: URL, home: URL) -> [String]? {
        let expanded = SSHConfigImporter.expand(pattern, home: home)?.path ?? ssh.appendingPathComponent(pattern).path
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(expanded, 0, nil, &matches) == 0 else { return nil }
        var texts: [String] = []
        for i in 0..<Int(matches.gl_pathc) {
            if let c = matches.gl_pathv[i], let text = try? String(contentsOfFile: String(cString: c), encoding: .utf8) { texts.append(text) }
        }
        return texts
    }

    private func run() async {
        guard let parsed else { return }
        isWorking = true
        defer { isWorking = false }
        outcome = await SSHConfigImporter.apply(
            parsed: parsed, selected: chosen, folderName: folderName, passphrases: passphrases,
            home: home, context: modelContext, vault: app.vault
        )
    }
}
