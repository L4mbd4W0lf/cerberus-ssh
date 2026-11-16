import XCTest

/// Tests that connect to a real `sshd` (started by the scheme): what the sidebar, tabs and
/// status bar show, that closing really ends the connection on the server, and that typing reaches
/// the remote shell. They skip themselves when there is no test server.
final class LiveSessionTests: CerberusUITestCase {
    @MainActor func testConnectingShowsConnectedInTheSidebarTabAndStatusBar() throws {
        try startServer()
        launch()
        connect("live-1")
        wait(tab("live-1"), "no tab for the session")
        wait(mainWindow.staticTexts["Connected"], "the status bar does not say Connected")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
    }

    @MainActor func testClosingATabEndsTheConnectionOnTheServer() throws {
        try startServer()
        launchConnected("live-1")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }

        app.typeKey("w", modifierFlags: .command)
        waitGone(tab("live-1"), "the tab is still there")
        wait(hostRow("live-1"), "the host row went missing")
        eventually("the server still holds the session after its tab was closed") { server!.liveSessions() == 0 }
        XCTAssertFalse(connectedRow("live-1").exists, "the sidebar still says connected")
    }

    @MainActor func testTypingReachesTheRemoteShell() throws {
        try startServer()
        launchConnected("live-1")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
        let marker = server!.scratchDirectory.appendingPathComponent("typed.txt")
        try? FileManager.default.removeItem(at: marker)

        // Click inside the terminal (clear of the sidebar and the status bar) so it has the keyboard.
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        app.typeText("echo uitest-$((6*7)) > \(marker.path)\n")
        eventually("the command typed into the terminal never ran on the server") {
            (try? String(contentsOf: marker, encoding: .utf8))?.contains("uitest-42") == true
        }
    }

    @MainActor func testTwoHostsMakeTwoTabsAndClosingOneLeavesTheOther() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1"))
        wait(tab("live-2"))
        eventually("expected two sessions on the server") { server!.liveSessions() == 2 }

        // The tab bar says which tab is selected (the toolbar no longer repeats its name as a title).
        eventually("the last tab to open was not the selected one") { self.isSelectedTab("live-2") && !self.isSelectedTab("live-1") }
        app.typeKey("1", modifierFlags: .command)
        eventually("⌘1 did not select the first tab") { self.isSelectedTab("live-1") && !self.isSelectedTab("live-2") }
        app.typeKey("2", modifierFlags: .command)
        eventually("⌘2 did not select the second tab") { self.isSelectedTab("live-2") && !self.isSelectedTab("live-1") }
        app.typeKey("1", modifierFlags: .command)
        eventually("⌘1 did not go back to the first tab") { self.isSelectedTab("live-1") }
        app.typeKey("9", modifierFlags: .command)
        eventually("⌘9 did not select the last tab") { self.isSelectedTab("live-2") && !self.isSelectedTab("live-1") }

        app.typeKey("w", modifierFlags: .command)
        waitGone(tab("live-2"))
        wait(tab("live-1"), "closing one tab closed the other")
        wait(connectedRow("live-1"), "the other session was disconnected")
        eventually("expected one session left on the server") { server!.liveSessions() == 1 }
    }

    @MainActor func testSplittingMakesASecondSessionAndClosingAPaneKeepsTheTab() throws {
        try startServer()
        launchConnected("live-1")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }

        app.typeKey("d", modifierFlags: .command)
        eventually("splitting did not open a second session") { server!.liveSessions() == 2 }
        wait(mainWindow.buttons["live-1, 2, Close tab"], "the tab does not show two panes")
        wait(mainWindow.buttons["2 panes. Show the list."].firstMatch, "the status bar does not offer the pane list")

        app.typeKey("w", modifierFlags: .command)
        eventually("closing a pane did not end its session") { server!.liveSessions() == 1 }
        wait(tab("live-1"), "closing one of two panes closed the tab")
    }

    @MainActor func testDraggingATabOutOpensAWindowOfItsOwnAndClosingItEndsItsSession() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        eventually("expected two sessions on the server") { server!.liveSessions() == 2 }

        // Drop the second tab on the desktop beside the window. (A click-drag: the long-press drag
        // that `press(forDuration:thenDragTo:)` makes does not start the tab's drag.)
        let outside = pointBesideMainWindow()
        drag(tab("live-2"), to: outside)

        let windows = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'SwiftUI.WindowGroup'"))
        eventually("dragging the tab out did not open a second window") { windows.count == 2 }
        XCTAssertEqual(server!.liveSessions(), 2, "moving a tab to a window dropped or reopened a connection")
        let detached = windows.containing(.button, identifier: "live-2, Close tab").firstMatch
        wait(detached, "the second window does not hold the dragged tab")
        XCTAssertFalse(detached.buttons["live-1, Close tab"].exists, "the new window also holds the other tab")

        // Closing that window closes the tab it holds, and with it the connection.
        detached.buttons[XCUIIdentifierCloseWindow].click()
        eventually("closing the window left its session open on the server") { server!.liveSessions() == 1 }
        eventually("the other window went away too") { windows.count == 1 }
    }
}
