import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

// MARK: - Forwards without a shell (spec §7.7)

/// Whether a forward is running, and where.
enum ForwardActivity {
    case stopped
    /// Being set up: the tunnel is connecting (or waiting for a host-key or one-time-code answer).
    case starting
    /// Running on a terminal session the user has open.
    case inTerminal(SessionViewModel)
    /// Running on a connection that exists only for forwards.
    case inTunnel(SessionViewModel)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .inTerminal, .inTunnel: true
        default: false
        }
    }
}

extension AppModel {
    private func plan(for forward: PortForward) -> ForwardPlan? {
        forward.host.flatMap { host in Self.forwardPlans(for: host).first { $0.id == forward.id } }
    }

    /// Where this forward is running, if it is.
    func activity(of forward: PortForward) -> ForwardActivity {
        guard let plan = plan(for: forward), let hostID = forward.host?.id else { return .stopped }
        // A terminal session counts first: the forward is already there, so there is nothing to open.
        if let terminal = sessions.first(where: { $0.hostID == hostID && $0.isRunning(plan) }) { return .inTerminal(terminal) }
        if let tunnel = tunnels.first(where: { $0.hostID == hostID && $0.isRunning(plan) }) { return .inTunnel(tunnel) }
        if startingForwards.contains(forward.id) { return .starting }
        if let failure = forwardFailures[forward.id] { return .failed(failure) }
        return .stopped
    }

    /// Starts the forward if it is stopped, stops it if it is running. With no terminal session
    /// to the host, starting makes a connection for it alone, with no shell; that connection is
    /// closed again when its last forward stops.
    func toggleForward(_ forward: PortForward) async {
        guard let host = forward.host, let plan = plan(for: forward) else { return }
        switch activity(of: forward) {
        case .inTerminal(let session):
            await session.stopForward(plan)
        case .inTunnel(let tunnel):
            await tunnel.stopForward(plan)
            await closeTunnelIfIdle(tunnel)
        case .starting:
            return
        case .stopped, .failed:
            await startForward(forward, on: host, plan: plan)
        }
    }

    private func startForward(_ forward: PortForward, on host: SSHHost, plan: ForwardPlan) async {
        guard plan.isEnabled else { forwardFailures[forward.id] = "This forward is switched off."; return }
        forwardFailures[forward.id] = nil

        // Prefer a terminal session that is up, then a tunnel that is.
        if let live = sessions.first(where: { $0.hostID == host.id && $0.isLive }) ?? tunnels.first(where: { $0.hostID == host.id && $0.isLive }) {
            await live.startForward(plan)
            if let error = live.forwardError, !live.isRunning(plan) { forwardFailures[forward.id] = error }
            return
        }
        guard hostKeyStore != nil, isVaultReady, host.hasLogin else {
            forwardFailures[forward.id] = !host.hasLogin ? "\(host.displayLabel) has no identity assigned." : "The vault is still unlocking."
            return
        }

        startingForwards.insert(forward.id)
        defer { startingForwards.remove(forward.id) }
        tunnels.removeAll { $0.canReconnect }   // connections that have ended
        do {
            let tunnel: SessionViewModel
            if let existing = tunnels.first(where: { $0.hostID == host.id }) {
                tunnel = existing   // another forward of this host is already bringing it up
                await waitUntilSettled(tunnel)
            } else {
                tunnel = try await makeSession(for: host, tunnelOnly: true)
                tunnels.append(tunnel)
                await tunnel.start()
                // `start` returns when the connection has signed in, but the session learns its new
                // state from the event stream a moment later. Without this wait the forward could be
                // judged against a tunnel that still looked like it was connecting, and fail with
                // "Trying publickey…" although the sign-in had succeeded.
                await waitUntilSettled(tunnel)
            }
            guard tunnel.isLive else {
                forwardFailures[forward.id] = tunnel.statusDetail ?? "Could not connect to \(host.displayLabel)."
                await closeTunnelIfIdle(tunnel, finishing: forward.id)
                return
            }
            await tunnel.startForward(plan)
            if let error = tunnel.forwardError, !tunnel.isRunning(plan) { forwardFailures[forward.id] = error }
            await closeTunnelIfIdle(tunnel, finishing: forward.id)
        } catch {
            CerberusLog.caught(error)
            forwardFailures[forward.id] = describe(error)
        }
    }

    /// Waits while a tunnel that another forward started is still signing in.
    func waitUntilSettled(_ tunnel: SessionViewModel) async {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline, !tunnel.isLive, !tunnel.canReconnect {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A connection that exists only for forwards has no reason to stay once none is running or
    /// being set up. `finishing` is the forward whose set-up has just ended.
    private func closeTunnelIfIdle(_ tunnel: SessionViewModel, finishing: UUID? = nil) async {
        guard tunnel.isTunnelOnly, tunnel.runningForwards.isEmpty else { return }
        let pending = startingForwards.subtracting(finishing.map { [$0] } ?? [])
        let hostPlans = Set(tunnel.forwardPlans.map(\.id))
        guard pending.isDisjoint(with: hostPlans) else { return }
        await tunnel.disconnect()
        tunnels.removeAll { $0.id == tunnel.id }
    }

    /// Dismisses a failure message.
    func clearForwardFailure(_ forward: PortForward) { forwardFailures[forward.id] = nil }
}

/// Forward plans and switches (spec §7.7).
extension AppModel {
    // MARK: Forwards (spec §7.7)

    /// The host's forwards as plans a session can run, in a steady order.
    static func forwardPlans(for host: SSHHost) -> [ForwardPlan] {
        (host.portForwards ?? [])
            .map {
                ForwardPlan(
                    id: $0.id, kind: $0.kind, bindAddress: $0.bindAddress, bindPort: $0.bindPort,
                    destinationHost: $0.destinationHost, destinationPort: $0.destinationPort,
                    autoStart: $0.autoStart, name: $0.name, isEnabled: $0.isEnabled
                )
            }
            .sorted { ($0.kind.rawValue, $0.bindPort, $0.id.uuidString) < ($1.kind.rawValue, $1.bindPort, $1.id.uuidString) }
    }

    /// After a forward was added, edited, switched on or off, or deleted: gives the host's open
    /// sessions its current forwards.
    func refreshForwards(for host: SSHHost) {
        let plans = Self.forwardPlans(for: host)
        for session in sessions + tunnels where session.hostID == host.id {
            Task {
                await session.updateForwardPlans(plans)
                // A forward-only connection whose last forward was switched off or deleted goes away.
                await closeTunnelIfIdle(session)
            }
        }
    }

    /// Switches a forward on or off, and applies it to the host's open sessions.
    func setForward(_ forward: PortForward, enabled: Bool) {
        forward.isEnabled = enabled
        context?.saveLogged()
        if let host = forward.host { refreshForwards(for: host) }
    }
}
