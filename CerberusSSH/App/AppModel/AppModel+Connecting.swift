import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// Opening sessions: choosing where a pane goes, resolving a host's chain and its credentials.
extension AppModel {
    // MARK: Connecting

    /// Opens a session for `host`.
    /// `whenPlaced` runs as soon as the session has its place (before it starts connecting): a new window is opened
    /// then, so it never shows up empty.
    func connect(to host: SSHHost, placement: SessionPlacement = .focusExisting, whenPlaced: (@MainActor () -> Void)? = nil) async {
        guard hostKeyStore != nil, context != nil else {
            report("The trust store is not ready yet.")
            return
        }
        guard isVaultReady else {
            report("The vault is still unlocking.")
            return
        }
        guard host.hasLogin else {
            report("\(host.displayLabel) has no identity assigned.")
            return
        }

        if placement == .focusExisting,
           let existing = sessions.first(where: { $0.hostID == host.id && !$0.canReconnect }) {
            focus(existing)
            return
        }

        do {
            let session = try await makeSession(for: host)
            place(session, as: placement)
            whenPlaced?()
            lastError = nil
            await session.start()
        } catch {
            CerberusLog.caught(error)
            report(describe(error))
        }
    }

    /// Opens another session to the same host as `session`, in a split (⌘D, ⇧⌘D).
    func duplicate(_ session: SessionViewModel, placement: SessionPlacement) async {
        guard let context,
              let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.id == session.hostID })
        else {
            report("That host no longer exists.")
            return
        }
        await connect(to: host, placement: placement)
    }

    private func place(_ session: SessionViewModel, as placement: SessionPlacement) {
        sessions.append(session)

        let axis: PaneLayout.Axis? = switch placement {
        case .splitRight, .splitLeft: .horizontal
        case .splitDown, .splitUp: .vertical
        default: nil
        }
        let before = placement == .splitLeft || placement == .splitUp

        if case .newWindow(let window) = placement {
            terminalWindows.insert(window)
            let tab = WorkspaceTab(windowID: window, layout: PaneLayout(leaf: session.id), focusedSessionID: session.id)
            tabs.append(tab)
            selectedTabIDs[window] = tab.id
            return
        }

        if let axis, let tab = selectedTab,
           let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].layout = tab.layout.splitting(tab.focusedSessionID, axis: axis, with: session.id, before: before)
            tabs[index].focusedSessionID = session.id
        } else {
            // A new tab goes in the window the user is working in.
            let window = activeWindowID ?? tabs.last?.windowID ?? UUID()
            let tab = WorkspaceTab(windowID: window, layout: PaneLayout(leaf: session.id), focusedSessionID: session.id)
            tabs.append(tab)
            selectedTabIDs[tab.windowID] = tab.id
            if activeWindowID == nil { activeWindowID = window }
        }
    }

    /// Builds a session for `host`, resolving credentials for it and for every jump
    /// host in its chain. Each hop signs in with its own identity (spec §7.5).
    func makeSession(for host: SSHHost, tunnelOnly: Bool = false) async throws -> SessionViewModel {
        guard let context, let hostKeyStore, host.hasLogin else { throw SSHError.noCredentials }

        let (username, credentials) = try await login(for: host)

        let everyHost = try context.fetch(FetchDescriptor<SSHHost>())
        let byID = Dictionary(everyHost.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chain = try JumpChainResolver.resolve(for: host, lookup: { byID[$0] })

        var hops: [JumpHop] = []
        for hop in chain {
            guard hop.hasLogin else {
                throw SSHError.underlying("The jump host \(hop.displayLabel) has no identity assigned.")
            }
            let (hopUsername, hopCredentials) = try await login(for: hop)
            hops.append(JumpHop(
                target: ConnectionTarget(host: hop, username: hopUsername),
                credentials: hopCredentials
            ))
        }

        let forwards = Self.forwardPlans(for: host)

        // The person starts a recording from the toolbar; the key is fetched then, not at connect.
        var makeRecorder: (@Sendable () async throws -> SessionRecorder)?
        if !tunnelOnly {
            let vault = vault
            let store = RecordingStore()
            let hostID = host.id
            let meta = RecordingMeta(
                hostName: host.displayLabel, hostname: host.hostname, username: username,
                terminalType: host.terminalType, recordsInput: false
            )
            makeRecorder = {
                let key = try await vault.sessionRecordingKey()
                var stamped = meta
                stamped.startedAt = Date()
                return try SessionRecorder(url: store.newRecordingURL(hostID: hostID), key: key, meta: stamped)
            }
        }

        let session = SessionViewModel(
            target: ConnectionTarget(host: host, username: username),
            credentials: credentials,
            hostKeyStore: hostKeyStore,
            jumpHops: hops,
            forwards: forwards,
            autoReconnect: host.autoReconnect && !tunnelOnly,
            themeID: host.themeID,
            isTunnelOnly: tunnelOnly,
            makeRecorder: makeRecorder
        )
        // A forward that is already running on a connection made for forwards alone is not
        // started a second time by this terminal session (the port would be taken).
        if !tunnelOnly {
            let hostID = host.id
            session.isForwardRunningElsewhere = { [weak self] plan in
                self?.tunnels.contains { $0.hostID == hostID && $0.isRunning(plan) } ?? false
            }
        }
        session.nodeColor = host.effectiveColor
        session.shownEndpoint = UITesting.shownEndpoint(for: host)
        // Feeds ⌘K's ranking: most used and most recent first.
        session.onConnected = { [weak host, weak self] in
            guard let host else { return }
            host.lastConnectedAt = Date()
            host.connectionCount += 1
            self?.context?.saveLogged()
        }
        // A shell that ends cleanly (`exit`, Ctrl-D) takes its pane, or its tab, with it. Any other end stays
        // on screen with its message, so a failure can be read.
        session.onShellExitedCleanly = { [weak session, weak self] in
            guard let session else { return }
            Task { await self?.close(session) }
        }
        // The icon in the sidebar and the line in the inspector; only written when it changed.
        session.onSystemDetected = { [weak host, weak self] found in
            guard let host, host.detectedOS != found.os || host.detectedOSVersion != found.version else { return }
            host.detectedOS = found.os
            host.detectedOSVersion = found.version
            self?.context?.saveLogged()
        }
        return session
    }

    private func vaultItem(id: UUID) -> VaultItem? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<VaultItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return context.fetchLogged(descriptor).first
    }

    private func vaultKey(id: UUID) -> VaultKey? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<VaultKey>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return context.fetchLogged(descriptor).first
    }

    /// Who `host` signs in as and with what: its identity's credential, or for a public server that asks for
    /// nothing, just a user name.
    private func login(for host: SSHHost) async throws -> (username: String, credentials: SSHCredentials) {
        if host.usesNoAuthentication {
            return (host.noAuthenticationUsername ?? "", .noAuthentication)
        }
        guard let identity = host.liveIdentity else { throw SSHError.noCredentials }
        return (identity.username, try await resolveCredentials(for: identity))
    }

    private func resolveCredentials(for identity: Identity) async throws -> SSHCredentials {
        // An agent identity keeps nothing here: the agent holds the key and does the signing, so there is
        // no secret to unseal and nothing for the Touch ID policy to guard (the agent asks for what it needs).
        if identity.kind == .agent {
            guard let client = SSHAgentClient.fromEnvironment(override: AgentSettings.override) else {
                throw SSHError.underlying(SSHAgentError.noSocket.description)
            }
            return .agent(AgentSource(socketPath: client.socketPath, keyFingerprint: identity.publicKeyFingerprint))
        }

        // A private-key identity may sign in with a key kept in the vault; otherwise the
        // credential is the one sealed for the identity itself.
        var sealedID = identity.vaultItemID
        if identity.kind == .privateKey, let keyID = identity.vaultKeyID {
            guard let key = vaultKey(id: keyID) else {
                throw SSHError.underlying("The vault key for \(identity.name) has been deleted. Choose another key for this identity in Settings.")
            }
            sealedID = key.vaultItemID
        }
        guard let itemID = sealedID, let vaultItem = vaultItem(id: itemID) else {
            throw SSHError.noCredentials
        }
        // Only the strictest policy asks before signing in (spec §6.4).
        guard await gate(.useSecret, reason: "Sign in with the saved credentials for \(identity.name)") else {
            throw SSHError.underlying("Sign-in was cancelled: authentication is required before using stored credentials (Settings ▸ Behaviour).")
        }

        switch identity.kind {
        case .password:
            let payload = try await VaultItemBridge.reveal(vaultItem, using: vault)
            guard let password = payload.password, !password.isEmpty else {
                throw SSHError.noCredentials
            }
            return .password(password)

        case .privateKey:
            let key = try await VaultItemBridge.privateKey(from: vaultItem, using: vault)
            return .privateKey(key)

        case .agent:
            throw SSHError.noCredentials   // handled above; an agent identity never gets here
        }
    }
}

extension AppModel {
    /// After a group's colour changed: gives every open session its host's current colour.
    func refreshNodeColors() {
        guard let context else { return }
        let hosts = Dictionary(context.fetchLogged(FetchDescriptor<SSHHost>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in sessions + tunnels { session.nodeColor = hosts[session.hostID]?.effectiveColor }
    }
}

/// How a test of a host's connection went (the host editor's "Test Chain").
struct ConnectionTestReport: Equatable {
    var succeeded: Bool
    var summary: String
    var detail: String?
}

extension AppModel {
    /// Connects to `host` the way a tunnel does (no terminal), through every jump host in its chain, and says
    /// whether it worked and, if not, at which hop and why. Host-key and one-time-code questions are asked as for
    /// any connection. The connection is closed again at once.
    func testConnection(to host: SSHHost) async -> ConnectionTestReport {
        guard context != nil, hostKeyStore != nil else { return .init(succeeded: false, summary: "The trust store is not ready yet.") }
        guard isVaultReady else { return .init(succeeded: false, summary: "The vault is still unlocking.") }
        guard host.hasLogin else { return .init(succeeded: false, summary: "\(host.displayLabel) has no identity assigned.") }

        let hops = host.jumpHostIDs.count + 1
        do {
            let session = try await makeSession(for: host, tunnelOnly: true)
            fileConnections.append(session)
            await session.start()
            await waitUntilSettled(session)
            let live = session.isLive
            let failedAt = session.diagnostics.map(\.message).last { $0.hasPrefix("Failed at hop") }
            let why = session.statusDetail
            await session.disconnect()
            keepLog(of: session)
            fileConnections.removeAll { $0.id == session.id }
            if live {
                return .init(succeeded: true, summary: hops > 1
                             ? "Connected to \(host.displayLabel) through \(hops - 1) jump host\(hops == 2 ? "" : "s")."
                             : "Connected to \(host.displayLabel).")
            }
            return .init(succeeded: false, summary: failedAt ?? "Could not connect to \(host.displayLabel).", detail: why)
        } catch {
            return .init(succeeded: false, summary: describe(error))
        }
    }
}
