import SwiftUI
import Observation
import CerberusModels
import CerberusSSHCore
import CerberusTerminal

/// The user-facing switch for `ssh -v`-style connection logging. Stored in
/// `UserDefaults`, not the synced catalogue: it is a per-Mac debugging preference.
enum ConnectionLogSettings {
    static let key = "connectionLogLevel"

    /// 0 = off, 1…3 = `-v`, `-vv`, `-vvv`.
    static var level: Int { max(0, min(3, UserDefaults.standard.integer(forKey: key))) }

    /// What a connection *records*. The Connection Log button is always available, so
    /// the basic level is captured even when the setting is Off; the setting then only
    /// controls what is printed in the terminal and whether extra detail is recorded.
    static var captureLevel: Int { max(1, level) }
}

/// A port forward configured for a host (spec §5.5, §7.7), ready to start on a session.
struct ForwardPlan: Identifiable, Equatable {
    var id: UUID
    var kind: ForwardKind
    var bindAddress: String
    var bindPort: Int
    var destinationHost: String?
    var destinationPort: Int?
    var autoStart: Bool
    var name: String?
    /// A forward that is switched off is never started, and a running one is stopped.
    var isEnabled: Bool = true

    /// What to call it: the name if it has one, else what it does.
    var title: String { name ?? summary }

    var summary: String {
        switch kind {
        case .local: "\(bindAddress):\(bindPort) → \(destinationHost ?? "?"):\(destinationPort ?? 0)"
        case .remote: "remote \(bindAddress):\(bindPort) → \(destinationHost ?? "?"):\(destinationPort ?? 0)"
        case .dynamic: "\(bindAddress):\(bindPort) (SOCKS5)"
        }
    }
}

/// One terminal session: a connection plus the UI state that describes it.
///
/// The view model owns the session, not the terminal view: hiding or replacing the
/// view leaves the connection running. A connection is single-use, so reconnecting
/// builds a new ``SSHConnection`` and the terminal rebinds to it (spec §7.8).
@MainActor
@Observable
final class SessionViewModel: Identifiable {
    let id = UUID()
    /// The terminal this session shows: its emulator and scrollback live as long as the session does, whichever
    /// pane, tab or window it is shown in.
    let terminalHost = TerminalHost()

    /// The session has left the app: lets go of its terminal. The terminal's callbacks hold this session, and this
    /// session holds the terminal, so without this neither would ever be freed.
    func releaseTerminal() { terminalHost.tearDown() }
    let hostID: UUID
    let title: String
    /// A connection that only carries port forwards: no terminal, no tab. It ends when its last
    /// forward is stopped.
    let isTunnelOnly: Bool
    /// This host's own theme, overriding the app-wide default when set.
    let themeID: String?

    private(set) var state: ConnectionState = .idle
    private(set) var statusDetail: String?
    private(set) var hostKeyFingerprint: String?

    /// Connection log lines (`debug1`…`debug3`) for the current attempt, when logging
    /// is on in Settings. Capped so a chatty `-vvv` session can't grow without bound.
    private(set) var diagnostics: [DiagnosticEntry] = []
    private static let diagnosticsLimit = 5_000

    /// Window title the remote shell set through an escape sequence.
    var remoteTitle: String?

    /// When the current attempt became active, for the uptime display.
    private(set) var connectedSince: Date?

    /// Forwards configured for this host, whether or not they are running or switched on.
    private(set) var forwardPlans: [ForwardPlan]
    /// Live status of the running forwards, refreshed once a second while connected.
    private(set) var forwardStatuses: [ForwardStatus] = []
    /// A plan id → the connection's id for it, for the plans currently running.
    private(set) var runningForwards: [UUID: UUID] = [:]
    /// The most recent problem starting a forward (a port in use, say). Non-fatal.
    var forwardError: String?

    /// What the status bar says about the last copy-on-select; cleared a couple of seconds later.
    private(set) var copyNotice: String?
    @ObservationIgnored private var copyNoticeTask: Task<Void, Never>?

    func noteCopied(characters: Int) {
        copyNotice = characters == 1 ? "Copied 1 character" : "Copied \(characters) characters"
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.copyNotice = nil }
        }
    }
    /// Asked before an automatic forward starts: `true` when it is already running on another
    /// connection (one made for forwards alone), so it is left there.
    var isForwardRunningElsewhere: ((ForwardPlan) -> Bool)?

    /// Seconds until the next automatic reconnect attempt, while one is pending.
    private(set) var reconnectIn: Int?
    private(set) var reconnectAttempt = 0

    /// Called each time the session becomes active, so usage can be recorded.
    var onConnected: (() -> Void)?
    /// Called when the remote shell ended by itself with exit status 0, so its pane can be closed.
    var onShellExitedCleanly: (() -> Void)?

    /// Called with what the server turned out to run, a moment after each connect.
    var onSystemDetected: ((DetectedSystem) -> Void)?

    /// A first-seen host key awaiting the user's decision. While set, the
    /// connection is suspended.
    var pendingHostKeyPrompt: HostKeyPrompt?

    /// A one-time-code (keyboard-interactive) question awaiting the user's answer.
    /// While set, the sign-in is suspended.
    var pendingKeyboardPrompt: KeyboardInteractivePrompt?

    /// The current attempt. Replaced on reconnect.
    private(set) var connection: SSHConnection

    /// Whether this attempt is being logged, and whether typed input is included.
    private(set) var isRecording = false
    private(set) var recordsInput = false
    /// Set when a log was asked for but could not be started.
    private(set) var recordingError: String?

    private let makeRecorder: (@Sendable () async throws -> SessionRecorder)?
    private let target: ConnectionTarget
    private let credentials: SSHCredentials
    private let jumpHops: [JumpHop]
    private let hostKeyStore: any HostKeyStore
    private let approvals: ApprovalRelay
    private let autoReconnect: Bool
    private let policy = ReconnectPolicy()
    private var observer: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var closedByUser = false
    /// The status the shell ended with, when this connection's shell has ended by itself (the person typed `exit`, or
    /// the program was the whole session). A lost connection reports none. Such a session is over and is not brought back.
    private var shellExitStatus: Int?
    private var promptContinuation: CheckedContinuation<Bool, Never>?
    private var keyboardContinuation: CheckedContinuation<[String]?, Never>?

    /// The colour of the host's folder when the session was opened (and kept up to date by
    /// `AppModel.refreshNodeColors()`), shown on the tab, the pane's top edge and the status bar.
    var nodeColor: NodeColor?

    init(
        target: ConnectionTarget,
        credentials: SSHCredentials,
        hostKeyStore: any HostKeyStore,
        jumpHops: [JumpHop] = [],
        forwards: [ForwardPlan] = [],
        autoReconnect: Bool = false,
        themeID: String? = nil,
        isTunnelOnly: Bool = false,
        makeRecorder: (@Sendable () async throws -> SessionRecorder)? = nil
    ) {
        self.isTunnelOnly = isTunnelOnly
        self.makeRecorder = makeRecorder
        self.themeID = themeID
        self.hostID = target.hostID
        self.title = target.displayName
        self.target = target
        self.credentials = credentials
        self.jumpHops = jumpHops
        self.hostKeyStore = hostKeyStore
        self.forwardPlans = forwards
        self.autoReconnect = autoReconnect
        let relay = ApprovalRelay()
        self.approvals = relay
        self.connection = Self.makeConnection(
            target: target, credentials: credentials, jumpHops: jumpHops,
            hostKeyStore: hostKeyStore, relay: relay
        )
        relay.owner = self
    }

    /// Whether the person can start a recording: a terminal session that is up, with a recording file to write to.
    var canRecord: Bool { makeRecorder != nil && state.isLive }

    /// Starts recording from now on, when the person asks. A failure is reported, never silent.
    func startRecording() async {
        guard let makeRecorder, !isRecording, state.isLive else { return }
        recordingError = nil
        do {
            let recorder = try await makeRecorder()
            await connection.startRecording(recorder)
            isRecording = true
            recordsInput = recorder.recordsInput
        } catch {
            CerberusLog.error("recordings", "could not start a recording", error)
            recordingError = "Could not start the recording: \(error.localizedDescription)"
        }
    }

    /// Stops the recording and seals the recording file. The session carries on.
    func stopRecording() async {
        guard isRecording else { return }
        await connection.stopRecording()
        isRecording = false
        recordsInput = false
    }

    /// Lets the connection ask this view model for a decision without a retain cycle.
    private final class ApprovalRelay: @unchecked Sendable {
        weak var owner: SessionViewModel?

        func ask(_ prompt: HostKeyPrompt) async -> Bool {
            guard let owner else { return false }
            return await owner.requestApproval(prompt)
        }

        func answer(_ prompt: KeyboardInteractivePrompt) async -> [String]? {
            guard let owner else { return nil }
            return await owner.requestAnswers(prompt)
        }
    }

    private static func makeConnection(
        target: ConnectionTarget,
        credentials: SSHCredentials,
        jumpHops: [JumpHop],
        hostKeyStore: any HostKeyStore,
        relay: ApprovalRelay
    ) -> SSHConnection {
        SSHConnection(
            target: target,
            credentials: credentials,
            hostKeyStore: hostKeyStore,
            hostKeyApprover: { prompt in await relay.ask(prompt) },
            keyboardInteractive: { prompt in await relay.answer(prompt) },
            jumpHops: jumpHops,
            verbosity: ConnectionLogSettings.captureLevel
        )
    }

    /// `user@host:port`, plus the jump chain, for the status bar and ⌘K.
    var endpointDescription: String {
        let base = "\(target.username)@\(target.hostname)" + (target.port == 22 ? "" : ":\(target.port)")
        guard !jumpHops.isEmpty else { return base }
        return base + " via " + jumpHops.map(\.target.hostname).joined(separator: " → ")
    }

    var isLive: Bool { state.isLive }

    /// The whole log as text, timestamped, for copying or saving.
    var diagnosticsText: String { diagnostics.map(\.logLine).joined(separator: "\n") }

    /// The connection ended and a new attempt may be made.
    var canReconnect: Bool {
        if case .disconnected = state { return true }
        return false
    }

    /// The server presented a key that differs from the pinned one.
    var hostKeyMismatch: (pattern: String, expected: String, actual: String)? {
        if case .disconnected(.hostKeyMismatch(let pattern, let expected, let actual)) = state {
            return (pattern, expected, actual)
        }
        return nil
    }

    /// Why the server can't be used at all (no shared algorithms), if that is the cause.
    var incompatibility: String? {
        if case .disconnected(.incompatibleServer(let detail)) = state { return detail }
        return nil
    }

    /// `host:port`, the trust-store key to clear when replacing a pinned host key.
    var hostKeyPattern: String { target.hostKeyPattern }

    // MARK: Host key prompt

    private func requestApproval(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingHostKeyPrompt = prompt
            promptContinuation = continuation
        }
    }

    // MARK: One-time codes

    private func requestAnswers(_ prompt: KeyboardInteractivePrompt) async -> [String]? {
        await withCheckedContinuation { continuation in
            pendingKeyboardPrompt = prompt
            keyboardContinuation = continuation
        }
    }

    /// Resolves the pending question: the answers, or `nil` if the user cancelled.
    func answerKeyboardPrompt(_ answers: [String]?) {
        pendingKeyboardPrompt = nil
        keyboardContinuation?.resume(returning: answers)
        keyboardContinuation = nil
    }

    /// Resolves the pending host-key prompt.
    func answerHostKey(trust: Bool) {
        pendingHostKeyPrompt = nil
        promptContinuation?.resume(returning: trust)
        promptContinuation = nil
    }

    // MARK: Lifecycle

    /// Starts the handshake and mirrors connection events into view state.
    ///
    /// The terminal view consumes the same `events` stream and the output buffer;
    /// this observer only tracks status, so both can read without contention.
    func start() async {
        let connection = connection
        observer?.cancel()
        // Subscribe now, not inside the task: a connection that fails at once (a refused port
        // answers in a millisecond) would otherwise have said so before the task had started
        // listening, and the session would sit at "connecting" for good, with no Reconnect.
        let events = connection.events
        observer = Task {
            for await event in events {
                switch event {
                case .stateChanged(let newState):
                    self.state = newState
                    if case .active = newState { self.didBecomeActive() }
                    if case .disconnected(let reason) = newState {
                        // The connection seals its log as it closes.
                        self.isRecording = false
                        self.recordsInput = false
                        self.statusDetail = self.shellExitStatus.map { "The shell ended (exit status \($0))." } ?? self.disconnectDetail(reason)
                        self.didDisconnect(reason)
                        if self.shellExitStatus == 0, !self.closedByUser, !self.isTunnelOnly { self.onShellExitedCleanly?() }
                    }
                case .hostKeyDecision(let decision):
                    self.apply(decision)
                case .authenticationAttempt(let attempt):
                    self.statusDetail = "Trying \(attempt)…"
                case .failed(let message):
                    self.statusDetail = message
                    CerberusLog.error("session", "\(self.title): \(message)")
                case .diagnostic(let entry):
                    if self.diagnostics.count < Self.diagnosticsLimit { self.diagnostics.append(entry) }
                case .exit(let status):
                    self.shellExitStatus = status
                case .outputAvailable, .banner:
                    break
                }
            }
        }

        do {
            try await connection.connect(openShell: !isTunnelOnly)
        } catch {
            CerberusLog.caught(error)
            statusDetail = (error as? SSHError)?.description ?? error.localizedDescription
        }
    }

    /// Dials again with a fresh connection. The terminal keeps its scrollback.
    ///
    /// - Parameter automatic: true for the backoff-driven retry; a user-initiated
    ///   reconnect starts the attempt count over.
    func reconnect(automatic: Bool = false) async {
        guard canReconnect else { return }
        if !automatic { reconnectAttempt = 0 }
        closedByUser = false
        shellExitStatus = nil
        reconnectTask?.cancel()
        reconnectIn = nil
        observer?.cancel()
        statusDetail = nil
        diagnostics = []
        // A recording ends with its connection; the new attempt is not recorded until asked.
        isRecording = false
        recordsInput = false
        recordingError = nil
        connection = Self.makeConnection(
            target: target, credentials: credentials, jumpHops: jumpHops,
            hostKeyStore: hostKeyStore, relay: approvals
        )
        state = .idle
        await start()
    }

    // MARK: Connection events

    private func didBecomeActive() {
        connectedSince = Date()
        reconnectAttempt = 0
        reconnectIn = nil
        onConnected?()
        let connection = connection
        Task { [weak self] in
            if let found = await connection.executor.detectSystem() { self?.onSystemDetected?(found) }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            // Auto-start forwards first, then keep their counters fresh.
            if let plans = self?.forwardPlans.filter({ $0.isEnabled && $0.autoStart }) {
                for plan in plans where self?.isForwardRunningElsewhere?(plan) != true { await self?.startForward(plan) }
            }
            while !Task.isCancelled {
                await self?.refreshForwards()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func didDisconnect(_ reason: DisconnectReason) {
        connectedSince = nil
        statusTask?.cancel()
        statusTask = nil
        runningForwards = [:]
        forwardStatuses = []
        scheduleAutoReconnect(after: reason)
    }

    /// Spec §7.8: exponential backoff, jittered, ten attempts, and never after an
    /// authentication or host-key failure.
    private func scheduleAutoReconnect(after reason: DisconnectReason) {
        // A shell that ended by itself is not a lost connection: nobody wants the session they just ended to come back.
        guard autoReconnect, !closedByUser, shellExitStatus == nil else { return }
        guard policy.shouldRetry(after: reason, attemptsMade: reconnectAttempt) else {
            if reason.isRecoverable { statusDetail = "Gave up reconnecting after \(reconnectAttempt) attempts." }
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let seconds = Int(policy.delay(forAttempt: attempt).rounded(.up))

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var remaining = max(1, seconds)
            while remaining > 0 {
                self?.reconnectIn = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            self?.reconnectIn = nil
            await self?.reconnect(automatic: true)
        }
    }

    // MARK: Forwards

    /// Takes the host's current forwards (they were edited, or one was switched on or off). A
    /// running forward that has gone, or been switched off, is stopped; one that has just been
    /// switched on or added starts if it is set to start by itself and the session is up.
    func updateForwardPlans(_ plans: [ForwardPlan]) async {
        let old = forwardPlans
        forwardPlans = plans
        func items(_ list: [ForwardPlan]) -> [ForwardSync.Item] {
            list.map { ForwardSync.Item(id: $0.id, isEnabled: $0.isEnabled, autoStart: $0.autoStart) }
        }
        let changes = ForwardSync.changes(
            old: items(old), new: items(plans), running: Set(runningForwards.keys), isSessionLive: isLive
        )
        for id in changes.stop {
            if let plan = old.first(where: { $0.id == id }) { await stopForward(plan) }
        }
        for id in changes.start {
            if let plan = plans.first(where: { $0.id == id }) { await startForward(plan) }
        }
    }

    func startForward(_ plan: ForwardPlan) async {
        guard runningForwards[plan.id] == nil else { return }
        guard plan.isEnabled else {
            forwardError = "The forward \(plan.summary) is switched off."
            CerberusLog.warning("forwarding", "\(title): \(forwardError ?? "")")
            return
        }
        do {
            let id: UUID
            switch plan.kind {
            case .local:
                guard let host = plan.destinationHost, let port = plan.destinationPort else {
                    throw SSHError.underlying("The forward \(plan.summary) has no destination.")
                }
                id = try await connection.startLocalForward(
                    bindAddress: plan.bindAddress, bindPort: plan.bindPort,
                    destinationHost: host, destinationPort: port
                )
            case .dynamic:
                id = try await connection.startDynamicForward(bindAddress: plan.bindAddress, bindPort: plan.bindPort)
            case .remote:
                guard let host = plan.destinationHost, let port = plan.destinationPort else {
                    throw SSHError.underlying("The forward \(plan.summary) has no destination.")
                }
                id = try await connection.startRemoteForward(
                    bindAddress: plan.bindAddress, bindPort: plan.bindPort,
                    destinationHost: host, destinationPort: port
                )
            }
            runningForwards[plan.id] = id
            forwardError = nil
            await refreshForwards()
        } catch {
            CerberusLog.caught(error)
            forwardError = (error as? SSHError)?.description ?? error.localizedDescription
            CerberusLog.error("forwarding", "\(title): could not start \(plan.summary)", error)
        }
    }

    func stopForward(_ plan: ForwardPlan) async {
        guard let id = runningForwards.removeValue(forKey: plan.id) else { return }
        await connection.stopForward(id)
        await refreshForwards()
    }

    func isRunning(_ plan: ForwardPlan) -> Bool { runningForwards[plan.id] != nil }

    /// Live counters for a running forward.
    func status(for plan: ForwardPlan) -> ForwardStatus? {
        runningForwards[plan.id].flatMap { id in forwardStatuses.first { $0.id == id } }
    }

    private func refreshForwards() async {
        forwardStatuses = await connection.forwardStatuses()
    }

    private func apply(_ decision: TOFUHostKeyVerifier.HostKeyDecision) {
        switch decision {
        case .trustedOnFirstUse(let fingerprint):
            hostKeyFingerprint = fingerprint
            statusDetail = "New host key recorded: \(fingerprint)"
        case .matchedPinnedKey(let fingerprint):
            hostKeyFingerprint = fingerprint
            statusDetail = nil
        case .rejectedMismatch(let expected, let actual):
            statusDetail = "Host key changed. Expected \(expected), got \(actual)."
        case .declinedByUser:
            statusDetail = "The host key was not trusted."
        case .rejectedRevoked(let fingerprint):
            statusDetail = "Host key \(fingerprint) is revoked."
        }
    }

    func disconnect() async {
        closedByUser = true
        reconnectTask?.cancel()
        reconnectIn = nil
        statusTask?.cancel()
        answerHostKey(trust: false)
        answerKeyboardPrompt(nil)
        let began = ContinuousClock.now
        await connection.disconnect()
        let took = ContinuousClock.now - began
        if took > .milliseconds(500) {
            CerberusLog.warning("session", "closing \(title) took \(took.components.seconds) s")
        }
        observer?.cancel()
        observer = nil
    }

    var statusLabel: String {
        switch state {
        case .idle: "Idle"
        case .resolving: "Resolving…"
        case .connecting: "Connecting…"
        case .verifyingHostKey: "Verifying host key…"
        case .authenticating: "Authenticating…"
        case .authenticated: "Authenticated"
        case .channelOpen: "Opening shell…"
        case .active: "Connected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))…"
        case .disconnected(let reason):
            if let reconnectIn {
                "Reconnecting in \(reconnectIn)s (attempt \(reconnectAttempt) of \(policy.maximumAttempts))…"
            } else {
                disconnectLabel(reason)
            }
        }
    }

    private func disconnectLabel(_ reason: DisconnectReason) -> String {
        switch reason {
        case .userInitiated: "Disconnected"
        case .remoteClosed: "Closed by remote host"
        case .timedOut: "Timed out"
        case .keepAliveFailed: "Connection lost"
        case .authenticationFailed: "Authentication failed"
        case .hostKeyMismatch: "Host key mismatch"
        case .hostKeyRejected: "Host key rejected"
        case .incompatibleServer: "Incompatible server"
        case .transportError: "Connection error"
        }
    }

    /// Longer explanation for the status bar, when the reason carries one.
    private func disconnectDetail(_ reason: DisconnectReason) -> String? {
        switch reason {
        case .authenticationFailed(let detail): detail
        case .transportError(let detail): detail
        case .hostKeyMismatch(let pattern, let expected, let actual):
            "The key of \(pattern) changed. Expected \(expected), got \(actual)."
        default: nil
        }
    }

    /// A shape for each state, so the dot never carries meaning by colour alone (§13.2).
    var statusSymbol: String {
        switch state {
        case .active: "checkmark.circle.fill"
        case .idle: "circle"
        case .disconnected(let reason):
            reconnectIn != nil ? "arrow.triangle.2.circlepath" : (reason.isFatal ? "xmark.octagon.fill" : "minus.circle.fill")
        default: "circle.dotted"
        }
    }

    var statusColor: Color {
        switch state {
        case .active, .channelOpen: Color.statusGood
        case .disconnected(let reason): reconnectIn != nil ? Color.statusWarning : (reason.isFatal ? Color.statusBad : .secondary)
        default: Color.statusWarning
        }
    }
}
