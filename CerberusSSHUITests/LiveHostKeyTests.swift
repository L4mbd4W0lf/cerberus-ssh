import XCTest

/// The first-connection host-key question, against a server the app has not seen.
final class LiveHostKeyTests: CerberusUITestCase {
    private var sheet: XCUIElement { mainWindow.sheets.firstMatch }

    private func startConnecting() throws {
        try startServer(trusted: false)
        launch()
        wait(hostRow("live-1"))
        hostRow("live-1").doubleClick()
        wait(sheet, "no host-key question was asked")
    }

    @MainActor func testAnUnknownServerAsksAndShowsItsFingerprint() throws {
        try startConnecting()
        wait(sheet.staticTexts["Trust this host?"])
        wait(sheet.staticTexts["ssh-ed25519"])
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'SHA256:'")).firstMatch.exists, "no fingerprint shown")
        XCTAssertEqual(server!.liveSessions(), 0, "a session opened before the key was trusted")
    }

    @MainActor func testCancellingDoesNotConnect() throws {
        try startConnecting()
        sheet.buttons["Cancel"].click()
        waitGone(sheet)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(server!.liveSessions(), 0, "cancelling the question still opened a session")
        XCTAssertFalse(sidebar.staticTexts.matching(NSPredicate(format: "value == 'live-1, connected'")).firstMatch.exists)
    }

    @MainActor func testTrustingConnectsAndTheKeyIsKnownNextTime() throws {
        try startConnecting()
        sheet.buttons["Trust and Connect"].click()
        wait(sidebar.staticTexts.matching(NSPredicate(format: "value == 'live-1, connected'")).firstMatch, "did not connect after trusting")

        // The same server again, in another session: no question this time.
        app.typeKey("w", modifierFlags: .command)
        waitGone(mainWindow.buttons["live-1, Close tab"])
        hostRow("live-1").doubleClick()
        wait(sidebar.staticTexts.matching(NSPredicate(format: "value == 'live-1, connected'")).firstMatch, "did not reconnect")
        XCTAssertFalse(mainWindow.sheets.firstMatch.exists, "the question was asked again for a key it had just trusted")
    }

    // MARK: A key that has changed

    private func startWithAChangedKey() throws {
        try startServer(hostKey: .mismatched)
        launch()
        wait(hostRow("live-1"))
        hostRow("live-1").doubleClick()
    }

    @MainActor func testAChangedKeyBlocksTheConnectionAndShowsBothFingerprints() throws {
        try startWithAChangedKey()
        wait(mainWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Host key has changed'")).firstMatch, "no warning that the host key changed")
        wait(mainWindow.staticTexts["Host key mismatch"], "the status bar does not say so")
        wait(sidebar.staticTexts.matching(NSPredicate(format: "value == 'live-1, failed'")).firstMatch, "the sidebar row does not say failed")

        let fingerprints = mainWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'SHA256:'"))
        XCTAssertGreaterThanOrEqual(fingerprints.count, 2, "the stored and presented fingerprints are not both shown")
        XCTAssertNotEqual(fingerprints.element(boundBy: 0).value as? String, fingerprints.element(boundBy: 1).value as? String)
        XCTAssertFalse(mainWindow.sheets.firstMatch.exists, "a mismatch must not offer to trust the new key")
        XCTAssertEqual(server!.liveSessions(), 0, "a session opened despite the changed key")
    }

    @MainActor func testReconnectingCannotGetPastAChangedKey() throws {
        try startWithAChangedKey()
        wait(mainWindow.staticTexts["Host key mismatch"])
        let reconnect = mainWindow.buttons["Reconnect"]
        wait(reconnect)
        reconnect.click()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(server!.liveSessions(), 0, "Reconnect got past a changed host key")
        wait(mainWindow.staticTexts["Host key mismatch"], "the block went away")
    }

    @MainActor func testCancellingTheReplacementLeavesTheBlockInPlace() throws {
        try startWithAChangedKey()
        let replace = mainWindow.buttons["Replace stored key…"]
        wait(replace)
        replace.click()
        wait(sheet)
        sheet.buttons["Cancel"].click()
        waitGone(sheet)
        wait(mainWindow.staticTexts["Host key mismatch"], "the block went away without the key being replaced")
        wait(mainWindow.buttons["Replace stored key…"])
        XCTAssertEqual(server!.liveSessions(), 0)
    }

    @MainActor func testReplacingTheStoredKeyThenTrustingTheNewOneConnects() throws {
        try startWithAChangedKey()
        let replace = mainWindow.buttons["Replace stored key…"]
        wait(replace, "no way to replace the stored key")
        replace.click()

        // Forgetting a pinned key is confirmed first, in words that say when it is safe.
        wait(sheet, "replacing the key was not confirmed")
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Replace the stored'")).firstMatch)
        sheet.buttons["Replace Key"].click()

        // The old key is forgotten, so the new one is met as a first connection.
        wait(sheet.staticTexts["Trust this host?"], "after replacing the key the new one was not put to the person")
        sheet.buttons["Trust and Connect"].click()
        wait(connectedRow("live-1"), "did not connect after replacing the key")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
    }
}
