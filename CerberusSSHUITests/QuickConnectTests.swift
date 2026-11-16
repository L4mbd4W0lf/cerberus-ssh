import XCTest

/// Quick connect is a field in the middle of the toolbar (⌘K puts the keyboard in it), with its matches in a dropdown
/// beneath it. (What opening a host then does on a live connection is in `LiveQuickConnectTests`.)
final class QuickConnectTests: CerberusUITestCase {
    private var field: XCUIElement { app.searchFields["quick-connect-field"] }

    private func element(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func row(_ host: String) -> XCUIElement { element("quick-connect-row-\(host)") }

    @MainActor func testTheFieldIsInTheToolbarWithNoDropdownUntilItHasTheKeyboard() {
        launch()
        wait(field, "no quick connect field in the toolbar")
        XCTAssertFalse(element("quick-connect-dropdown").exists, "the dropdown is open before the field is used")
    }

    @MainActor func testTheShortcutIsShownInTheFieldWhileItIsEmptyAndIdle() {
        launch()
        wait(field)
        let hint = element("quick-connect-shortcut-hint")
        wait(hint, "the field does not show its shortcut")
        XCTAssertEqual(hint.label.isEmpty ? hint.value as? String : hint.label, "⌘K")
        // Once it has the keyboard the hint steps aside, and it is back when the field is let go.
        app.typeKey("k", modifierFlags: .command)
        waitGone(hint, "the hint is still there with the keyboard in the field")
        app.typeKey(.escape, modifierFlags: [])
        wait(hint, "the hint did not come back")
    }

    @MainActor func testCommandKPutsTheKeyboardInTheFieldAndOpensTheDropdown() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(element("quick-connect-dropdown"), "⌘K did not open the dropdown")
        // Before anything is typed every host is offered, and what is typed narrows them.
        wait(row("web-1")); wait(row("db-1"))
        app.typeText("web")
        wait(row("web-1")); wait(row("web-2"))
        waitGone(row("db-1"), "a host that does not match is still listed")
    }

    @MainActor func testClickingTheFieldOpensTheDropdownLikeTheShortcut() {
        launch()
        wait(hostRow("web-1"))
        wait(field)
        field.click()
        wait(element("quick-connect-dropdown"), "clicking the field did not open the dropdown")
        wait(row("web-1")); wait(row("db-1"))
        app.typeText("web")
        wait(row("web-2"))
        waitGone(row("db-1"), "a host that does not match is still listed")
        // Escape lets the field go, as after ⌘K.
        app.typeKey(.escape, modifierFlags: [])
        waitGone(element("quick-connect-dropdown"), "Escape did not close the dropdown")
    }

    @MainActor func testEscapeClosesTheDropdownAndClearsTheField() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(element("quick-connect-dropdown"))
        app.typeText("web")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(element("quick-connect-dropdown"), "Escape did not close the dropdown")
        XCTAssertEqual(field.value as? String ?? "", "", "Escape left what was typed in the field")
    }

    @MainActor func testReturnOpensTheChosenMatchInANewTab() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(element("quick-connect-dropdown"))
        app.typeText("web")
        wait(row("web-2"))
        // Down moves to the second match; Return opens it.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        wait(mainWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'web-2'")).firstMatch, "Return did not open the chosen host in a tab")
        waitGone(element("quick-connect-dropdown"), "the dropdown stayed open after choosing")
        XCTAssertEqual(workspaceWindows.count, 1, "Return opened a window")
    }

    @MainActor func testOptionReturnSplitsTheChosenHostBesideThePaneInsteadOfBeeping() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(row("web-1"))
        app.typeText("web-1")
        app.typeKey(.return, modifierFlags: [])
        wait(mainWindow.buttons["web-1, Close tab"], "the first host did not open")

        app.typeKey("k", modifierFlags: .command)
        wait(row("db-1"))
        app.typeText("db-1")
        app.typeKey(.return, modifierFlags: .option)
        // One tab, now with two panes: the second host was split in beside the first, not opened as a tab of its own.
        // One tab, now with two panes (it is named for the pane that has the focus, the new one): the second host was
        // split in beside the first, not opened as a tab of its own.
        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        wait(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'")).firstMatch, "⌥Return did not split the host into the tab")
        XCTAssertEqual(tabs.count, 1, "⌥Return opened a tab instead of splitting")
        waitGone(element("quick-connect-dropdown"), "the dropdown stayed open after ⌥Return")
    }

    @MainActor func testClickingAMatchOpensIt() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(row("db-1"))
        row("db-1").click()
        wait(mainWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'db-1'")).firstMatch, "clicking a match did not open the host")
    }

    @MainActor func testTheWindowShowsNoHostNameAsATitle() {
        launch()
        wait(hostRow("web-1"))
        app.typeKey("k", modifierFlags: .command)
        wait(row("web-1"))
        app.typeText("web-1")
        app.typeKey(.return, modifierFlags: [])
        wait(mainWindow.buttons.matching(NSPredicate(format: "label BEGINSWITH 'web-1'")).firstMatch)
        // The tab says which host it is; the toolbar has no second copy of the name as a title.
        XCTAssertFalse(mainWindow.toolbars.firstMatch.staticTexts["web-1"].exists, "the host name is still in the toolbar as a title")
    }
}
