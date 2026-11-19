import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// File tabs: two panes side by side, copying between this Mac and hosts, or between two hosts
/// with the bytes passing through this Mac.
extension AppModel {
    /// Opens a file tab for the hosts picked in the sidebar. One host gives this Mac on the left and
    /// the host on the right (so a copy goes to or from the Mac); two hosts give one on each side,
    /// for a copy from one server to the other. Anything else is not a file tab.
    @discardableResult
    func openFiles(for hosts: [SSHHost]) -> FileTabModel? {
        let sources: (FilePaneModel.Source, FilePaneModel.Source)
        switch hosts.count {
        case 1: sources = (.local, .host(id: hosts[0].id, name: hosts[0].displayLabel))
        case 2: sources = (.host(id: hosts[0].id, name: hosts[0].displayLabel), .host(id: hosts[1].id, name: hosts[1].displayLabel))
        default: return nil
        }
        let model = FileTabModel(left: sources.0, right: sources.1) { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.makeFileSession(for: id)
        }
        let window = activeWindowID ?? tabs.last?.windowID ?? UUID()
        let tab = WorkspaceTab(windowID: window, layout: PaneLayout(leaf: model.id), focusedSessionID: model.id, files: model)
        tabs.append(tab)
        selectedTabIDs[window] = tab.id
        if activeWindowID == nil { activeWindowID = window }
        Task { await model.start() }
        return model
    }

    /// Opens a file tab for the host the focused terminal is connected to (⇧⌘S).
    func openFilesForSelectedSession() {
        guard let session = selectedSession, let context,
              let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.id == session.hostID }) else { return }
        openFiles(for: [host])
    }

    /// A connection of its own to `hostID` for a file pane to browse and copy over: it signs
    /// in the same way a terminal does, asks the same host-key and one-time-code questions, and ends
    /// when the pane lets it go.
    func makeFileSession(for hostID: UUID) async throws -> FileSession {
        #if DEBUG || PERFGATE
        if UITesting.isActive, let stand = UITesting.fileHostRoot(for: hostID, context: context) {
            return FileSession(backend: LocalFileBackend(home: stand.path, name: stand.name), close: {},
                               info: FileSessionInfo(endpoint: "test@\(stand.name)", hostKeyFingerprint: nil, connectedSince: Date()))
        }
        #endif
        guard let context, hostKeyStore != nil else { throw FileSessionError.notReady("The trust store is not ready yet.") }
        guard isVaultReady else { throw FileSessionError.notReady("The vault is still unlocking.") }
        guard let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.id == hostID }) else {
            throw FileSessionError.notReady("That host no longer exists.")
        }
        guard host.hasLogin else { throw FileSessionError.notReady("\(host.displayLabel) has no identity assigned.") }

        let session = try await makeSession(for: host, tunnelOnly: true)
        fileConnections.append(session)
        func drop() { fileConnections.removeAll { $0.id == session.id } }

        await session.start()
        await waitUntilSettled(session)
        guard session.isLive else {
            let why = session.statusDetail ?? "Could not connect to \(host.displayLabel)."
            await session.disconnect()
            drop()
            throw FileSessionError.notReady(why)
        }
        do {
            let client = try await session.connection.openSFTP()
            return FileSession(
                backend: SFTPFileBackend(client: client, displayName: host.displayLabel),
                close: { [weak self] in
                    await client.close()
                    await session.disconnect()
                    await MainActor.run { self?.fileConnections.removeAll { $0.id == session.id } }
                },
                info: FileSessionInfo(endpoint: session.endpointDescription, hostKeyFingerprint: session.hostKeyFingerprint, connectedSince: session.connectedSince ?? Date())
            )
        } catch {
            // No SFTP (switched off in sshd_config, say): if the account has a shell, use that, slowly.
            let executor = session.connection.executor
            if let probe = try? await executor.run("echo cerberus-shell-ok"), String(decoding: probe.output, as: UTF8.self).contains("cerberus-shell-ok") {
                CerberusLog.info("files", "\(host.displayLabel) has no SFTP; its files are reached through its shell")
                return FileSession(
                    backend: ShellFileBackend(executor: executor, displayName: host.displayLabel),
                    close: { [weak self] in
                        await session.disconnect()
                        await MainActor.run { self?.fileConnections.removeAll { $0.id == session.id } }
                    },
                    info: FileSessionInfo(endpoint: session.endpointDescription, hostKeyFingerprint: session.hostKeyFingerprint,
                                          connectedSince: session.connectedSince ?? Date(), note: "shell, no SFTP")
                )
            }
            await session.disconnect()
            drop()
            throw error
        }
    }
}

enum FileSessionError: LocalizedError {
    case notReady(String)

    var errorDescription: String? {
        switch self { case .notReady(let why): why }
    }
}
