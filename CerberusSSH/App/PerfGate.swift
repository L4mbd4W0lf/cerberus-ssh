#if PERFGATE
import Foundation
import SwiftData
import Darwin
import CerberusModels
import CerberusSSHCore

/// The performance gate's side inside the app, compiled into the "Perf" build
/// configuration only: an optimised build with the test hooks, because a debug build measures the
/// wrong thing. The performance-gate script starts it with a scenario naming a host, a number of sessions
/// and a command; this opens that many sessions (each in its own tab), types the command into all of
/// them so each floods its terminal, and then, every ten seconds, writes one line to the log with what
/// the script judges: sessions still live, bytes received, memory, and the longest the main thread has
/// been unresponsive.
@MainActor
enum PerfGate {
    static func run(_ plan: UITesting.Scenario.PerfPlan, app: AppModel) async {
        guard UITesting.isActive, let context = app.context,
              let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.name == plan.host }) else {
            CerberusLog.error("perf", "no host called \(plan.host) to open sessions to")
            return
        }
        if plan.fileTab {
            CerberusLog.info("perf", "opening a file tab on \(plan.host)")
            app.openFiles(for: [host])
        }
        CerberusLog.info("perf", "opening \(plan.sessions) sessions to \(plan.host)")
        for _ in 0..<plan.sessions { await app.connect(to: host, placement: .newTab) }
        // `connect` returns when the handshake has finished, but a session learns it is live a moment later.
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline, app.sessions.filter(\.isLive).count < plan.sessions {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let live = app.sessions.filter(\.isLive)
        CerberusLog.info("perf", "connected: \(live.count) of \(plan.sessions) sessions are live (\(app.sessions.count) exist)")
        for session in app.sessions where !session.isLive { CerberusLog.warning("perf", "not live: \(session.title): \(session.statusLabel) \(session.statusDetail ?? "")") }
        for session in live { try? await session.connection.send(Array((plan.command + "\n").utf8)) }
        CerberusLog.info("perf", "flood started in \(live.count) sessions")

        let started = ContinuousClock.now
        var tick = 0
        while true {
            try? await Task.sleep(for: .seconds(10))
            tick += 1
            let elapsed = Int((ContinuousClock.now - started).components.seconds)
            let sessions = app.sessions
            let bytes = sessions.reduce(0) { $0 + $1.connection.output.totalBytes }
            CerberusLog.info("perf", String(
                format: "sample t=%d live=%d total=%d bytes=%ld footprintMB=%.1f maxStallMS=%.0f",
                elapsed, sessions.filter(\.isLive).count, sessions.count, bytes, footprintMB(), HangWatchdog.maxLatency * 1000
            ))
            if elapsed >= plan.seconds + 15 { CerberusLog.info("perf", "done"); return }
        }
    }

    /// The app's memory footprint, as Activity Monitor's "Memory" column counts it.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
#endif
