import XCTest

/// What happens when a connection is lost rather than closed (spec §7.1): the server's connection
/// process is killed from inside the session (`kill -9 $SESSION_SSHD_PID`, which the test server's
/// session wrapper exports), which looks to the app like a network failure, not a clean exit.
final class LiveReconnectTests: CerberusUITestCase {
    private func dropTheConnection() {
        clickTerminal()
        run("kill -9 $SESSION_SSHD_PID")
    }

    @MainActor func testAHostSetToReconnectComesBackOnItsOwnWithANewSession() throws {
        try startServer()
        launchConnected("live-auto")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
        let before = server!.sessionIDs()

        dropTheConnection()
        eventually("the old session is still on the server after the drop") { server!.sessionIDs().isDisjoint(with: before) }

        // It reconnects without being asked, and the server has a new session.
        wait(connectedRow("live-auto"), "the host did not reconnect by itself", timeout: 45)
        eventually("the server has no new session after the reconnect", timeout: 20) {
            server!.liveSessions() == 1 && server!.sessionIDs().isDisjoint(with: before)
        }
    }

    @MainActor func testAHostNotSetToReconnectStaysDownUntilAskedAndThenConnects() throws {
        try startServer()
        launchConnected("live-1")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }

        dropTheConnection()
        waitGone(connectedRow("live-1"), "the row still says connected after the connection was lost", timeout: 20)
        Thread.sleep(forTimeInterval: 5)   // longer than the first backoff
        XCTAssertEqual(server!.liveSessions(), 0, "a host not set to reconnect reconnected anyway")
        XCTAssertFalse(connectedRow("live-1").exists)

        // The one in the pane; the toolbar has a Reconnect button of its own.
        let reconnect = mainWindow.groups.buttons["Reconnect"]
        wait(reconnect, "no Reconnect button for a lost connection")
        reconnect.click()
        wait(connectedRow("live-1"), "Reconnect did not bring the session back", timeout: 20)
        eventually("the server never saw the new session") { server!.liveSessions() == 1 }
    }

    /// A shell that ends by itself (the person types `exit`) is not a lost connection: even a host set to reconnect
    /// stays closed, because nobody wants a session they just ended to come back.
    @MainActor func testACleanExitDoesNotReconnect() throws {
        try startServer()
        launchConnected("live-auto")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }

        clickTerminal()
        run("exit")
        waitGone(connectedRow("live-auto"), "the row still says connected after the shell ended", timeout: 20)
        eventually("the session is still on the server after exit") { server!.liveSessions() == 0 }
        Thread.sleep(forTimeInterval: 8)   // longer than the first backoff of a host that does reconnect
        XCTAssertEqual(server!.liveSessions(), 0, "a host reconnected after the shell exited cleanly")
        XCTAssertFalse(connectedRow("live-auto").exists)
        XCTAssertFalse(mainWindow.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'reconnecting'")).firstMatch.exists, "a countdown to reconnect was shown after a clean exit")
    }

    @MainActor func testAHostThatCannotBeReachedCountsDownAndTriesAgainWithALongerWait() throws {
        try startServer()
        launch()
        wait(hostRow("live-down"))
        hostRow("live-down").doubleClick()

        // Nothing listens on its port, so each attempt fails and the next waits longer.
        func countdown() -> (seconds: Int, attempt: Int)? {
            let text = mainWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Reconnecting in'")).firstMatch
            guard text.exists, let value = text.value as? String else { return nil }
            // "Reconnecting in 4s (attempt 2 of 10)…"
            let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return numbers.count >= 3 ? (numbers[0], numbers[1]) : nil
        }
        var firstSeen: (seconds: Int, attempt: Int)?
        var laterSeen: (seconds: Int, attempt: Int)?
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let now = countdown() {
                if firstSeen == nil { firstSeen = now }
                else if now.attempt > firstSeen!.attempt { laterSeen = now; break }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let first = try XCTUnwrap(firstSeen, "no reconnect countdown was ever shown")
        XCTAssertEqual(first.attempt, 1, "the first countdown should be for attempt 1")
        let later = try XCTUnwrap(laterSeen, "it never tried a second time")
        XCTAssertGreaterThan(later.attempt, first.attempt)
        XCTAssertTrue(sidebar.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'live-down'")).firstMatch.exists)

        // Closing the tab stops it trying.
        app.typeKey("w", modifierFlags: .command)
        waitGone(mainWindow.buttons["live-down, Close tab"])
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(mainWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Reconnecting in'")).firstMatch.exists,
                       "it was still counting down after the tab was closed")
    }
}
