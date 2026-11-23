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

    @MainActor func testDroppingOnAPaneOfASplitTabSplitsOnlyThatPane() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        connectTwo()
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)
        eventually("the split did not open a third session") { server!.liveSessions() == 3 }
        wait(tab("live-1", panes: 2))

        // Each pane's grip runs along its top, so where a pane is can be read from its grip.
        let grips = app.descendants(matching: .any).matching(identifier: "pane-grip")
        func gripFrames(_ host: String) -> [CGRect] {
            grips.matching(NSPredicate(format: "label == %@", "Pane handle, \(host)")).allElementsBoundByIndex
                .map(\.frame).sorted { $0.minX < $1.minX }
        }
        eventually("a split tab has no pane grips") { gripFrames("live-1").count == 2 }
        let left = gripFrames("live-1")[0], right = gripFrames("live-1")[1]

        // The second tab, on the bottom of the right-hand pane: it goes under that pane, not under the whole tab.
        drag(tab("live-2"), to: terminalPoint(0.75, 0.9))
        wait(tab("live-2", panes: 3), "the dropped tab did not become a third pane")
        eventually("the dropped pane is not under the right-hand pane") {
            guard let dropped = gripFrames("live-2").first else { return false }
            return abs(dropped.minX - right.minX) < 4 && dropped.minY > right.maxY
        }
        XCTAssertEqual(gripFrames("live-1").first.map { abs($0.minX - left.minX) < 4 }, true, "the left-hand pane moved")
        XCTAssertLessThan(gripFrames("live-2")[0].width, left.width + 10, "the dropped pane is wider than one half")

        // That pane, dragged by its grip onto the bottom of the left-hand pane, moves under it, in the same tab.
        let moving = grips.matching(NSPredicate(format: "label == 'Pane handle, live-2'")).firstMatch
        drag(moving, to: terminalPoint(0.25, 0.9))
        eventually("the dragged pane is not under the left-hand pane") {
            guard let moved = gripFrames("live-2").first else { return false }
            return abs(moved.minX - left.minX) < 4 && moved.minY > left.maxY
        }
        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        XCTAssertEqual(tabs.count, 1, "moving a pane within its tab made another tab")
        wait(tab("live-2", panes: 3))
        XCTAssertEqual(server!.liveSessions(), 3, "dropping onto a pane dropped or reopened a connection")
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
