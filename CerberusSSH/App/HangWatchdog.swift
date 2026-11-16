import AppKit
import Foundation
import CerberusModels

/// Tells the log when the app froze, and for how long, and what the user had just done.
///
/// A background thread asks the main thread, ten times a second, to answer a trivial request.
/// When the answer takes long, the main thread was busy or blocked, which is what a "lag" is.
/// The line is written once the main thread is free again (a blocked thread cannot be
/// inspected from outside), with the last click or key, so the lag can be matched to an action.
/// Debug builds only.
///
/// **To find the cause of a lag, press Pause (⌃⌘Y) in Xcode while it is happening and read the
/// main thread's stack.**
@MainActor
enum HangWatchdog {
    private static var lastInput = "nothing yet"
    /// The longest the main thread has taken to answer since start (the performance gate reports it).
    nonisolated(unsafe) static var maxLatency = 0.0
    private nonisolated static let latencyLock = NSLock()
    private static var monitor: Any?

    static func start() {
        #if DEBUG || PERFGATE
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { describe(event) }
            return event
        }
        let thread = Thread {
            let threshold = 0.25
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                let sent = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let parts = (ContinuousClock.now - sent).components
                let latency = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                latencyLock.withLock { maxLatency = max(maxLatency, latency) }
                if latency > threshold {
                    DispatchQueue.main.async {
                        CerberusLog.warning(
                            "hang",
                            String(format: "the main thread was unresponsive for %.2f s. Last input: ", latency) + lastInput
                        )
                    }
                }
            }
        }
        thread.name = "CerberusSSH hang watchdog"
        thread.qualityOfService = .utility
        thread.start()
        CerberusLog.info("hang", "watching for main-thread stalls over 0.25 s (debug builds)")
        #endif
    }

    private static func describe(_ event: NSEvent) {
        var what = "\(event.type)"
        if let window = event.window, let content = window.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            let view = content.hitTest(point)
            what += " on \(view.map { String(describing: type(of: $0)) } ?? "nothing")"
            what += " in \"\(window.title)\""
        }
        if event.type == .keyDown { what += " (key code \(event.keyCode))" }
        lastInput = what
    }
}
