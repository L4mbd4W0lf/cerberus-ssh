import XCTest

/// What happens to tabs when they are closed, and what comes back after a restart (Settings ▸ Behaviour).
final class LiveWorkspaceTests: CerberusUITestCase {
    @MainActor func testClosingATabWithALiveConnectionAsksFirst() throws {
        try startServer()
        launchConnected("live-1")
        setBehaviour("behaviour-confirm-close", on: true)
        wait(mainWindow); mainWindow.click()

        // ⌘W on a live pane asks; Cancel keeps it.
        clickTerminal()
        app.typeKey("w", modifierFlags: .command)
        let yes = app.buttons["confirm-close-yes"]
        wait(yes, "closing a live tab did not ask")
        app.typeKey(.escape, modifierFlags: [])   // Escape is Cancel
        eventually("the question did not go") { !yes.exists }
        XCTAssertTrue(tab("live-1").exists, "Cancel closed the tab")
        XCTAssertEqual(server!.liveSessions(), 1)

        // The × asks too; Close closes it and ends the connection.
        tab("live-1").rightClick()   // Close Tab, from the tab's own menu
        let items = app.menuItems.matching(identifier: "Close Tab")
        wait(items.firstMatch, "no Close Tab in the tab's menu")
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(yes, "Close Tab from the tab's menu did not ask")
        yes.click()
        eventually("the tab did not close") { !tab("live-1").exists }
        eventually("the connection did not end") { server!.liveSessions() == 0 }
    }

    @MainActor func testCommandWClosesTheActiveTabAndNeverTheWindow() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        setBehaviour("behaviour-confirm-close", on: false)
        wait(mainWindow); mainWindow.click()
        clickTerminal()

        // The second tab is the active one: ⌘W takes it, and the other tab and the window stay.
        app.typeKey("w", modifierFlags: .command)
        eventually("the active tab did not close") { !tab("live-2").exists }
        XCTAssertTrue(tab("live-1").exists, "⌘W closed the wrong tab")
        XCTAssertTrue(mainWindow.exists, "⌘W closed the window while a tab was left")

        // The last tab goes the same way, and still the window stays.
        clickTerminal()
        app.typeKey("w", modifierFlags: .command)
        eventually("the last tab did not close") { !tab("live-1").exists }
        XCTAssertTrue(mainWindow.exists, "⌘W closed the window")
    }

    @MainActor func testWithTheQuestionOffAClosedTabGoesAtOnce() throws {
        try startServer()
        launchConnected("live-1")
        setBehaviour("behaviour-confirm-close", on: false)
        wait(mainWindow); mainWindow.click()
        clickTerminal()
        app.typeKey("w", modifierFlags: .command)
        eventually("the tab did not close") { !tab("live-1").exists }
    }

    @MainActor func testTabsAndSplitsComeBackAfterARestart() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        eventually("expected two sessions") { server!.liveSessions() == 2 }
        // A split in the second tab, so a layout has to come back and not only a list of tabs.
        app.typeKey("d", modifierFlags: .command)
        wait(tab("live-2", panes: 2))
        setBehaviour("behaviour-reopen", on: true)
        Thread.sleep(forTimeInterval: 1.5)   // the snapshot is saved a moment after a change
        let file = testHome.appendingPathComponent("Library/Application Support/CerberusSSH/workspace.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "nothing was remembered")

        options.connect = []
        relaunchKeepingPreferences()
        wait(tab("live-1"), "the first tab did not come back", timeout: 30)
        wait(tab("live-2", panes: 2), "the split tab did not come back with its two panes", timeout: 30)
        wait(connectedRow("live-1"), "live-1 did not reconnect", timeout: 30)
        wait(connectedRow("live-2"), "live-2 did not reconnect", timeout: 30)
    }

    @MainActor func testATabClosedByHandIsNotBroughtBack() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        setBehaviour("behaviour-reopen", on: true)
        setBehaviour("behaviour-confirm-close", on: false)
        wait(mainWindow); mainWindow.click()
        app.typeKey("2", modifierFlags: .command)
        clickTerminal()
        app.typeKey("w", modifierFlags: .command)
        eventually("the tab did not close") { !tab("live-2").exists }
        Thread.sleep(forTimeInterval: 1.5)

        options.connect = []
        relaunchKeepingPreferences()
        wait(tab("live-1"), "the open tab did not come back", timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(tab("live-2").exists, "a tab that had been closed came back")
    }

    @MainActor func testAFileTabComesBackAfterARestart() {
        let inner = testHome.appendingPathComponent("uitest-hosts/web-1/inner-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        launch()
        wait(hostRow("web-1"))
        setBehaviour("behaviour-reopen", on: true)
        wait(mainWindow); mainWindow.click()
        hostRow("web-1").rightClick()
        let items = app.menuItems.matching(identifier: "SFTP")
        wait(items.firstMatch, "no SFTP in the host's menu")
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        let panes = app.descendants(matching: .any).matching(identifier: "files-pane-right")
        wait(panes.firstMatch, "the file tab did not open")

        // Go into a folder on the right, so it is the folder that has to come back and not the home folder.
        let right = app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch
        let row = right.staticTexts[inner.lastPathComponent]
        wait(row, "the folder is not listed")
        row.doubleClick()
        let path = app.textFields["files-path-right"]
        eventually("the pane did not go into the folder") { (path.value as? String)?.hasSuffix(inner.lastPathComponent) == true }
        Thread.sleep(forTimeInterval: 1.5)

        relaunchKeepingPreferences()
        wait(app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch, "the file tab did not come back", timeout: 30)
        eventually("the pane did not come back in its folder", timeout: 30) {
            (self.app.textFields["files-path-right"].value as? String)?.hasSuffix(inner.lastPathComponent) == true
        }
    }

    @MainActor func testATabInAWindowOfItsOwnComesBackInAWindowOfItsOwn() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("the tab did not get a window") { workspaceWindows.count == 2 }
        setBehaviour("behaviour-reopen", on: true)
        Thread.sleep(forTimeInterval: 1.5)

        options.connect = []
        relaunchKeepingPreferences()
        eventually("the second window did not come back", timeout: 30) { workspaceWindows.count == 2 }
        // (Either window may be the first one now, so look in the whole app.)
        wait(app.buttons["live-1, Close tab"], "the first tab did not come back", timeout: 30)
        wait(app.buttons["live-2, Close tab"], "the tab that had a window did not come back", timeout: 30)
        let second = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        XCTAssertFalse(second.buttons["live-1, Close tab"].exists, "both tabs came back into one window")
    }

    @MainActor func testAWindowComesBackWhereItWas() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("the tab did not get a window") { workspaceWindows.count == 2 }
        let before = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        wait(before)
        let frame = before.frame
        setBehaviour("behaviour-reopen", on: true)
        Thread.sleep(forTimeInterval: 1.5)

        options.connect = []
        relaunchKeepingPreferences()
        eventually("the second window did not come back", timeout: 30) { workspaceWindows.count == 2 }
        wait(app.buttons["live-2, Close tab"], "the tab did not come back", timeout: 30)
        let after = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        eventually("the window did not come back where it was", timeout: 15) {
            abs(after.frame.minX - frame.minX) < 3 && abs(after.frame.minY - frame.minY) < 3
                && abs(after.frame.width - frame.width) < 3 && abs(after.frame.height - frame.height) < 3
        }
    }

    @MainActor func testClosingAWindowWithALiveConnectionAsksFirst() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("the tab did not get a window") { workspaceWindows.count == 2 }
        setBehaviour("behaviour-confirm-close", on: true)
        let detached = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        wait(detached)

        // The red button asks; Cancel (Escape) leaves the window and its connection alone.
        detached.buttons[XCUIIdentifierCloseWindow].click()
        wait(detached.sheets.firstMatch, "closing the window did not ask")
        app.typeKey(.escape, modifierFlags: [])
        eventually("the question did not go") { !detached.sheets.firstMatch.exists }
        XCTAssertEqual(workspaceWindows.count, 2, "Cancel closed the window")
        XCTAssertEqual(server!.liveSessions(), 2)

        // Close ends it.
        detached.buttons[XCUIIdentifierCloseWindow].click()
        wait(detached.sheets.firstMatch)
        detached.sheets.firstMatch.buttons["Close"].click()
        eventually("the window did not close") { workspaceWindows.count == 1 }
        eventually("its connection did not end") { server!.liveSessions() == 1 }
    }

    @MainActor func testQuittingWithALiveConnectionAsksFirst() throws {
        try startServer()
        launchConnected("live-1")
        setBehaviour("behaviour-confirm-close", on: true)
        wait(mainWindow); mainWindow.click()

        app.typeKey("q", modifierFlags: .command)
        let quit = app.dialogs.firstMatch
        wait(quit, "quitting did not ask")
        XCTAssertTrue(quit.staticTexts["Quit CerberusSSH?"].exists, "the question is not the quit one")
        app.typeKey(.escape, modifierFlags: [])   // Cancel
        eventually("the question did not go") { !quit.exists }
        XCTAssertTrue(app.state == .runningForeground, "Cancel quit the app")

        app.typeKey("q", modifierFlags: .command)
        wait(app.dialogs.firstMatch)
        app.dialogs.firstMatch.buttons["Quit"].click()
        // (The process is the better witness: the test's own view of the app's state can lag behind a quit.)
        eventually("the app did not quit", timeout: 20) {
            app.state == .notRunning || NSRunningApplication.runningApplications(withBundleIdentifier: "com.cerberusssh.uitest").isEmpty
        }
    }
}

/// Reading about a connection after the fact, and testing a jump chain.
final class LiveConnectionInfoTests: CerberusUITestCase {
    @MainActor func testAHostWhoseSessionWasClosedStillShowsItsLastConnectionLog() throws {
        try startServer()
        launchConnected("live-1")
        wait(mainWindow); mainWindow.click()
        clickTerminal()
        app.typeKey("w", modifierFlags: .command)
        eventually("the tab did not close") { !tab("live-1").exists }

        hostRow("live-1").rightClick()
        let items = app.menuItems.matching(identifier: "Show Last Connection Log")
        wait(items.firstMatch, "no Show Last Connection Log in the host's menu")
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(app.staticTexts["Last connection log — live-1"], "the saved log did not open")
    }

    @MainActor func testTestChainSaysTheChainWorks() throws {
        try startServer()
        launch()
        wait(hostRow("live-jump"))
        hostRow("live-jump").rightClick()
        let edit = app.menuItems.matching(identifier: "Edit…")
        wait(edit.firstMatch)
        (edit.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? edit.firstMatch).click()
        let test = app.buttons["host-test-chain"]
        wait(test, "no Test Chain button on a host with a jump host")
        test.click()
        let result = app.staticTexts["host-test-chain-result"]
        wait(result, "the test gave no answer", timeout: 30)
        XCTAssertTrue((result.value as? String ?? result.label).hasPrefix("Connected"), "the chain test did not say Connected: \(result.label)")
        eventually("the test left a connection open") { server!.liveSessions() == 0 }
    }
}
