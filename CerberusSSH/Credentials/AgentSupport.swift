import SwiftUI
import CerberusSSHCore

/// Where the app finds the ssh-agent (spec §7.6): the socket set in Settings ▸ Advanced, else the
/// `SSH_AUTH_SOCK` this process was started with (which, for an app opened from Finder, is the system
/// agent that launchd runs).
enum AgentSettings {
    static let socketKey = "agentSocketPath"

    static var override: String? {
        UserDefaults.standard.string(forKey: socketKey).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static var client: SSHAgentClient? { SSHAgentClient.fromEnvironment(override: override, timeout: 5) }

    /// The keys the agent holds now, listed off the main thread (a stuck agent must not freeze the window).
    static func keys() async -> Result<[AgentKey], SSHAgentError> {
        guard let client else { return .failure(.noSocket) }
        return await Task.detached {
            do { return .success(try client.identities()) } catch { return .failure((error as? SSHAgentError) ?? .malformed("\(error)")) }
        }.value
    }
}

/// The agent's keys as a list to pick from, for an identity. `fingerprint` nil means "try each key".
struct AgentKeyPicker: View {
    @Binding var fingerprint: String?
    /// Told which key is chosen (its algorithm and comment), so the identity can remember them.
    var onChoose: (AgentKey?) -> Void = { _ in }

    @State private var keys: [AgentKey] = []
    @State private var problem: String?
    @State private var isLooking = false

    var body: some View {
        Picker("Key", selection: $fingerprint) {
            Text("Any key the agent holds").tag(String?.none)
            ForEach(keys.filter(\.isSupported), id: \.fingerprintSHA256) { key in
                Text("\(key.comment.isEmpty ? key.algorithm : key.comment) — \(key.algorithm)").tag(String?.some(key.fingerprintSHA256))
            }
            // A key chosen earlier that the agent does not hold now stays selectable, so saving does not drop it.
            if let fingerprint, !keys.contains(where: { $0.fingerprintSHA256 == fingerprint }) {
                Text("\(fingerprint) (not in the agent now)").tag(String?.some(fingerprint))
            }
        }
        .accessibilityIdentifier("agent-key-picker")
        .onChange(of: fingerprint) { _, new in onChoose(keys.first { $0.fingerprintSHA256 == new }) }

        HStack {
            if isLooking { ProgressView().controlSize(.small) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.statusWarning)
            } else {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Look Again", systemImage: "arrow.clockwise") { Task { await look() } }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .task { await look() }
        Text("The private key stays in the agent; this app only asks it to sign.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var summary: String {
        let usable = keys.filter(\.isSupported).count
        let skipped = keys.count - usable
        return "\(usable) key\(usable == 1 ? "" : "s") in the agent" + (skipped > 0 ? " (\(skipped) of a kind this app cannot use)" : "")
    }

    private func look() async {
        isLooking = true
        defer { isLooking = false }
        switch await AgentSettings.keys() {
        case .success(let found): keys = found; problem = nil
        case .failure(let error): keys = []; problem = error.description
        }
    }
}
