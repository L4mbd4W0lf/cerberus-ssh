import XCTest

/// Typing into several panes at once (spec §8.5), checked by what each remote shell does.
final class LiveBroadcastTests: CerberusUITestCase {
    @MainActor func testBroadcastSendsWhatIsTypedToEveryPaneAndStopsWhenSwitchedOff() throws {
        try startServer()
        launchConnected("live-1")
        app.typeKey("d", modifierFlags: .command)
        eventually("the split did not open a second session") { server!.liveSessions() == 2 }
        wait(tab("live-1", panes: 2))

        let log = server!.scratchDirectory.appendingPathComponent("broadcast.txt")
        try? FileManager.default.removeItem(at: log)
        func pids() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        // Without broadcast, a command reaches only the pane it is typed in.
        clickTerminal(across: 0.85)
        run("echo $$ >> \(log.path)")
        eventually("the command never ran") { pids().count == 1 }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(pids().count, 1, "a command typed in one pane ran in both without broadcast")

        // With it, every pane runs it: two more lines, from two different shells.
        app.typeKey("b", modifierFlags: [.command, .shift])
        run("echo $$ >> \(log.path)")
        eventually("broadcast did not reach both panes") { pids().count == 3 }
        XCTAssertEqual(Set(pids()).count, 2, "the two panes should be two different shells")

        // Switched off again, back to one pane.
        app.typeKey("b", modifierFlags: [.command, .shift])
        run("echo $$ >> \(log.path)")
        eventually("typing after switching broadcast off did not run") { pids().count == 4 }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(pids().count, 4, "broadcast was still on after it was switched off")
    }
}
