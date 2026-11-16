import XCTest

/// A session keeps what its terminal has shown when the pane is shown somewhere else (a split, a tab of its own,
/// another window, another tab's panes). The terminal's own accessibility value is the text on its screen, so
/// a marker typed before the move has to still be there after it. A terminal that had been started over would
/// show none of it, and the server would have seen a second login if the move had reconnected.
final class LiveTerminalHistoryTests: CerberusUITestCase {
    /// Every terminal in `scope` (the window, by default) with its screen text.
    private func terminalTexts(in scope: XCUIElement? = nil) -> [String] {
        let terminals = (scope ?? mainWindow).textViews.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'"))
        return terminals.allElementsBoundByIndex.compactMap { $0.value as? String }
    }

    private func showsMarker(_ marker: String, in scope: XCUIElement? = nil) -> Bool {
        terminalTexts(in: scope).contains { $0.contains(marker) }
    }

    /// Types `echo marker` into the focused terminal and waits until the screen has shown it.
    private func leaveMarker(_ marker: String) {
        run("echo \(marker)")
        eventually("the terminal never showed \(marker)") { showsMarker(marker) }
    }

    @MainActor func testAPaneMovedToATabOfItsOwnKeepsItsHistory() throws {
        try startServer()
        launchConnected("live-1")
        leaveMarker("HISTORY_PANE_TO_TAB")

        // Split: the new pane is on the right, and has the focus. Go back to the left pane, which has the history.
        app.typeKey("d", modifierFlags: .command)
        eventually("the split did not open a second session") { server!.liveSessions() == 2 }
        wait(tab("live-1", panes: 2))
        terminalPoint(0.2, 0.5).click()

        // Take that pane out into a tab of its own (Session ▸ Move Pane to New Tab).
        app.typeKey("t", modifierFlags: [.command, .option])
        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        eventually("the pane did not get a tab of its own") { tabs.count == 2 }
        XCTAssertFalse(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'")).firstMatch.exists,
                       "a tab still holds two panes")

        eventually("the moved pane lost its history") { showsMarker("HISTORY_PANE_TO_TAB") }
        XCTAssertEqual(server!.liveSessions(), 2, "moving a pane opened or closed a connection")
    }

    /// The grip strip above a pane in a split tab is dragged out onto the tab bar and the pane becomes a tab of its own,
    /// with its history and with no connection opened or closed.
    @MainActor func testAPaneDraggedByItsGripOntoTheTabBarBecomesATab() throws {
        try startServer()
        launchConnected("live-1")
        leaveMarker("HISTORY_GRIP_DRAG")

        app.typeKey("d", modifierFlags: .command)
        eventually("the split did not open a second session") { server!.liveSessions() == 2 }
        wait(tab("live-1", panes: 2))
        let grips = app.descendants(matching: .any).matching(identifier: "pane-grip")
        eventually("a split tab has no pane grips") { grips.count == 2 }

        // The left pane is the one with the history; drag its grip onto the end of the tab.
        let left = grips.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
        drag(left, to: tab("live-1", panes: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))

        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        eventually("the dragged pane did not get a tab of its own") { tabs.count == 2 }
        XCTAssertFalse(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'")).firstMatch.exists, "a tab still holds two panes")
        eventually("the dragged pane lost its history") { showsMarker("HISTORY_GRIP_DRAG") }
        XCTAssertEqual(server!.liveSessions(), 2, "dragging a pane opened or closed a connection")
    }

    @MainActor func testATabDroppedOntoATerminalAsAPaneKeepsItsHistory() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        eventually("expected two sessions on the server") { server!.liveSessions() == 2 }

        // live-2 is the tab in front; give its terminal something to remember.
        clickTerminal()
        leaveMarker("HISTORY_TAB_TO_PANE")

        app.typeKey("1", modifierFlags: .command)
        drag(tab("live-2"), to: mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let merged = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'"))
        eventually("the dropped session did not become a pane") { merged.count == 1 }

        eventually("the session lost its history when it became a pane") { showsMarker("HISTORY_TAB_TO_PANE") }
        XCTAssertEqual(server!.liveSessions(), 2, "merging tabs opened or closed a connection")
    }

    @MainActor func testATabMovedToAnotherWindowKeepsItsHistory() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        eventually("expected two sessions on the server") { server!.liveSessions() == 2 }

        clickTerminal()
        leaveMarker("HISTORY_TAB_TO_WINDOW")

        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("dragging the tab out did not open a second window") { workspaceWindows.count == 2 }
        let detached = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        wait(detached)

        eventually("the tab lost its history in the new window") { showsMarker("HISTORY_TAB_TO_WINDOW", in: detached) }
        XCTAssertEqual(server!.liveSessions(), 2, "moving the tab to a window opened or closed a connection")
    }

    /// A tab that has just opened has the keyboard in its terminal: typing works with no click first.
    @MainActor func testANewTabsTerminalHasTheKeyboardWithoutAClick() throws {
        try startServer()
        launchConnected("live-1")
        run("echo FOCUS_WITHOUT_CLICK")
        eventually("what was typed into a new tab never reached its terminal") { showsMarker("FOCUS_WITHOUT_CLICK") }

        // A second tab, opened from the sidebar, takes the keyboard too.
        connect("live-2")
        run("echo FOCUS_SECOND_TAB")
        eventually("what was typed into a second new tab never reached its terminal") { showsMarker("FOCUS_SECOND_TAB") }
    }
}
