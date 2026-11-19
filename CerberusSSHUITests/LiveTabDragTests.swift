import XCTest

/// Moving tabs about by dragging them: reorder, merge into another tab's panes, and
/// back into a window from one of its own. A connection must survive every one of them.
final class LiveTabDragTests: CerberusUITestCase {
    private func connectTwo() {
        wait(tab("live-1"))
        wait(tab("live-2"))
        eventually("expected two sessions on the server") { server!.liveSessions() == 2 }
    }

    @MainActor func testDroppingATabOnAnotherTabReordersThem() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        connectTwo()
        XCTAssertLessThan(tab("live-1").frame.minX, tab("live-2").frame.minX, "live-1 should start first")

        // The second tab, dropped on the first one's left half, goes before it.
        let target = tab("live-1").coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        drag(tab("live-2"), to: target)

        eventually("the tabs did not change order") { tab("live-2").frame.minX < tab("live-1").frame.minX }
        XCTAssertEqual(server!.liveSessions(), 2, "reordering tabs disturbed a connection")
        wait(connectedRow("live-1")); wait(connectedRow("live-2"))
    }

    @MainActor func testDroppingATabOnATerminalMergesItIntoThatTabAsAPane() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        connectTwo()
        app.typeKey("1", modifierFlags: .command)

        // On the right-hand side of the first tab's terminal: the other session becomes a pane beside it.
        drag(tab("live-2"), to: mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))

        // One tab holding both panes. (It is named for the pane that was just dropped in.)
        let merged = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'"))
        eventually("the dropped session did not become a pane beside the first") { merged.count == 1 }
        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        XCTAssertEqual(tabs.count, 1, "the merge left more than one tab")
        XCTAssertEqual(server!.liveSessions(), 2, "merging tabs dropped or reopened a connection")
        wait(connectedRow("live-1")); wait(connectedRow("live-2"))
    }

    @MainActor func testADetachedTabCanBeDraggedBackIntoTheWindow() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        connectTwo()

        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("dragging the tab out did not open a second window") { workspaceWindows.count == 2 }
        let detached = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        wait(detached)
        let original = workspaceWindows.containing(.button, identifier: "live-1, Close tab").firstMatch
        wait(original)

        // Back onto the first window's tab bar.
        drag(detached.buttons["live-2, Close tab"], to: original.buttons["live-1, Close tab"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))

        eventually("the tab did not rejoin the first window") { workspaceWindows.count == 1 }
        wait(tab("live-1")); wait(tab("live-2"))
        XCTAssertEqual(server!.liveSessions(), 2, "moving the tab back disturbed a connection")
    }
}
