import XCTest

/// The keys that act on the host or group selected in the sidebar (the Host menu): they work while the sidebar has
/// the keyboard, and ⌘D, ⌘N and ⌘S keep their usual jobs in a terminal.
final class SidebarShortcutsTests: CerberusUITestCase {
    @MainActor func testShiftCommandDDuplicatesTheSelectedHostWhileTheSidebarHasTheKeyboard() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        app.typeKey("d", modifierFlags: [.command, .shift])
        wait(hostRow("web-1 copy"), "⇧⌘D did not duplicate the selected host")
        XCTAssertEqual(workspaceWindows.count, 1)
    }

    @MainActor func testCommandNOnASelectedFolderOpensTheNewHostSheet() {
        launch()
        wait(folderRow("Production"))
        folderRow("Production").click()
        app.typeKey("n", modifierFlags: .command)
        wait(app.sheets.firstMatch, "⌘N on a selected folder did not open the New Host sheet")
        XCTAssertEqual(workspaceWindows.count, 1, "⌘N opened a window instead")
    }

    @MainActor func testCommandNOpensTheNewHostSheetWhateverHasTheKeyboardAndNeverAWindow() {
        launch()
        wait(folderRow("Production"))
        // Nothing selected, and the keyboard is not in the sidebar: the title bar has it.
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).click()
        app.typeKey("n", modifierFlags: .command)
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet, "⌘N did not open the New Host sheet")
        XCTAssertEqual(workspaceWindows.count, 1, "⌘N opened a window instead")
    }

    @MainActor func testShiftCommandNOpensTheNewFolderSheetInsideTheSelectedFolder() {
        launch()
        wait(folderRow("Production"))
        folderRow("Production").click()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet, "⇧⌘N did not open the New Folder sheet")
        wait(sheet.staticTexts["New Folder in Production"], "the new folder did not start inside the selected folder")
        XCTAssertEqual(workspaceWindows.count, 1, "⇧⌘N opened a window instead")
    }

    @MainActor func testCommandEOnASelectedFolderOpensTheRenameSheet() {
        launch()
        wait(folderRow("Production"))
        folderRow("Production").click()
        app.typeKey("e", modifierFlags: .command)
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet, "⌘E on a selected folder did not open the rename sheet")
        wait(sheet.staticTexts["Edit Folder"])
        XCTAssertEqual(workspaceWindows.count, 1, "⌘E opened a window instead")
    }

    @MainActor func testCommandSConnectsTheSelectedHostInANewTabEachTime() throws {
        try startServer()
        launch()
        wait(hostRow("live-1"))
        hostRow("live-1").click()
        app.typeKey("s", modifierFlags: .command)
        wait(tab("live-1"), "⌘S did not open the host in a tab", timeout: 20)

        // Again: a second tab, not a jump to the first.
        hostRow("live-1").click()
        app.typeKey("s", modifierFlags: .command)
        let tabs = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'"))
        eventually("a second ⌘S did not open a second tab") { tabs.count == 2 }
    }

    @MainActor func testShiftCommandSOpensSFTPForTheSelectedHost() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        app.typeKey("s", modifierFlags: [.command, .shift])
        wait(app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch, "⇧⌘S did not open a file tab")

        // Close the tab again before the test ends. Left open with the host still selected, it made the next test's
        // reset of the app never finish; the app's own "Erase All Data" does not show it.
        app.typeKey("w", modifierFlags: .command)
        eventually("the file tab did not close") { !self.app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch.exists }
    }
}
