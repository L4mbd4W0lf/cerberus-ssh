import XCTest

/// Sign-in that wants a one-time code as well as the key (spec §7.4), against a real OpenSSH with PAM
/// and Google Authenticator in a container. Skipped when Docker or its image is not there.
final class LiveTwoFactorTests: CerberusUITestCase {
    private var totp: UITestSSHD.TOTPServer!
    private var sheet: XCUIElement { mainWindow.sheets.firstMatch }

    private func start() throws {
        try startServer()
        guard let found = server?.totp else { throw XCTSkip("no one-time-code server: Docker or the cerberus-test-sshd-totp image is not available") }
        totp = found
        launch()
    }

    private var codeField: XCUIElement { sheet.secureTextFields.firstMatch }

    private func askForTheCode(of host: String) {
        wait(hostRow(host))
        hostRow(host).doubleClick()
        wait(sheet, "no verification-code question was asked")
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Verification required'")).firstMatch)
    }

    @MainActor func testAServerThatWantsACodeAsksForItAndTheRightOneSignsIn() throws {
        try start()
        askForTheCode(of: "live-2fa")
        XCTAssertFalse(sheet.buttons["Continue"].isEnabled, "Continue is enabled before a code is typed")
        wait(codeField)
        codeField.typeText(TOTP.code(secret: totp.secret))
        XCTAssertTrue(sheet.buttons["Continue"].isEnabled)
        sheet.buttons["Continue"].click()
        wait(connectedRow("live-2fa"), "the right code did not sign in", timeout: 20)
        waitGone(sheet)
        XCTAssertTrue(mainWindow.buttons["live-2fa, Close tab"].exists)
    }

    @MainActor func testAWrongCodeIsRefusedAndTheHostStaysDown() throws {
        try start()
        askForTheCode(of: "live-2fa")
        // The server asks again after a wrong code; answer wrong each time until it gives up.
        for _ in 0..<4 {
            guard sheet.exists else { break }
            codeField.typeText("000000")
            sheet.buttons["Continue"].click()
            Thread.sleep(forTimeInterval: 1.5)
        }
        wait(sidebar.staticTexts.matching(NSPredicate(format: "value == 'live-2fa, failed'")).firstMatch, "a refused sign-in does not show as failed", timeout: 20)
        waitGone(sheet)
        // And it does not keep trying behind the person's back (no automatic reconnect after an authentication failure).
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(connectedRow("live-2fa").exists)
        XCTAssertFalse(sheet.exists, "the question came back by itself")
    }

    @MainActor func testCancellingTheQuestionDoesNotConnect() throws {
        try start()
        askForTheCode(of: "live-2fa")
        sheet.buttons["Cancel"].click()
        waitGone(sheet)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(connectedRow("live-2fa").exists, "cancelling still connected")
    }

    @MainActor func testAHostBehindTheServerAsksOnceForTheCodeThenIsReached() throws {
        try start()
        askForTheCode(of: "live-behind-2fa")
        codeField.typeText(TOTP.code(secret: totp.secret))
        sheet.buttons["Continue"].click()
        wait(connectedRow("live-behind-2fa"), "the host behind the one-time-code server was not reached", timeout: 25)
        // One question for the jump host, none for the target, which wants only the key.
        XCTAssertFalse(sheet.exists, "a second question was asked")
    }

    @MainActor func testTheCodeIsNotLeftOnScreenAfterSigningIn() throws {
        try start()
        askForTheCode(of: "live-2fa")
        let code = TOTP.code(secret: totp.secret)
        codeField.typeText(code)
        sheet.buttons["Continue"].click()
        wait(connectedRow("live-2fa"), timeout: 20)
        XCTAssertFalse(mainWindow.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", code)).firstMatch.exists,
                       "the code is visible in the window after sign-in")
    }
}
