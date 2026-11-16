import XCTest

/// ⌘K: where Return, and Return with a modifier, open the chosen host.
final class LiveQuickConnectTests: CerberusUITestCase {
    private func quickConnect(_ text: String) {
        app.typeKey("k", modifierFlags: .command)
        let field = app.searchFields["quick-connect-field"]
        wait(field, "Quick Connect did not open")
        field.typeText(text)
    }

    @MainActor func testReturnOpensTheHostInANewTabOfThisWindow() throws {
        try startServer()
        launch()
        wait(hostRow("live-1"))
        quickConnect("live-1")
        app.typeKey(.return, modifierFlags: [])
        wait(tab("live-1"), "Return did not open a tab", timeout: 20)
        XCTAssertEqual(workspaceWindows.count, 1, "Return opened a window")
    }

    @MainActor func testShiftReturnOpensTheHostInAWindowOfItsOwn() throws {
        try startServer()
        launch()
        wait(hostRow("live-1"))
        quickConnect("live-1")
        app.typeKey(.return, modifierFlags: .shift)

        eventually("⇧Return did not open a second window", timeout: 20) { workspaceWindows.count == 2 }
        let holding = workspaceWindows.containing(.button, identifier: "live-1, Close tab")
        eventually("no window holds the host's tab") { holding.count == 1 }
        eventually("the host did not connect") { server!.liveSessions() == 1 }
        // The first window did not get the tab as well.
        XCTAssertFalse(workspaceWindows.element(boundBy: 0).buttons["live-1, Close tab"].exists && workspaceWindows.element(boundBy: 1).buttons["live-1, Close tab"].exists,
                       "the host is in both windows")
    }
}
