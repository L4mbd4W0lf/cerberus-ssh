import XCTest

/// The import offered on a fresh install that has a `~/.ssh` (spec §6.5), and the same sheet opened
/// from the Welcome screen.
final class FirstLaunchImportTests: CerberusUITestCase {
    override var seed: String { "empty" }

    private var sheet: XCUIElement { mainWindow.sheets.firstMatch }

    private func text(_ prefix: String) -> XCUIElement {
        sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
    }

    private func launchFresh(file: StaticString = #filePath, line: UInt = #line) {
        options.freshLaunch = true
        options.firstLaunchOffer = true
        launch()
    }

    @MainActor func testAppearsByItselfOnAnEmptyInstallAndListsWhatIsThere() throws {
        try makeSSHFolder(keys: ["id_ed25519"], protected: ["id_locked": "secret"], knownHost: "example.test")
        launchFresh()
        wait(sheet, "the offer did not appear on an empty install that has a ~/.ssh")
        wait(sheet.staticTexts["Import from ~/.ssh"])
        wait(sheet.checkBoxes["known_hosts: 1 host key"], "known_hosts is not offered")
        wait(sheet.checkBoxes["id_ed25519, ssh-ed25519"], "the plain key is not offered")
        wait(sheet.checkBoxes["id_locked, ssh-ed25519"], "the protected key is not offered")
        wait(sheet.secureTextFields["Passphrase"], "the protected key does not ask for its passphrase")
        for box in ["known_hosts: 1 host key", "id_ed25519, ssh-ed25519"] {
            XCTAssertEqual(sheet.checkBoxes[box].value as? Int, 1, "\(box) should start ticked")
        }
    }

    @MainActor func testImportingBringsInTheKeysAndTheTrustedHost() throws {
        try makeSSHFolder(keys: ["id_ed25519"], protected: ["id_locked": "secret"], knownHost: "example.test")
        launchFresh()
        wait(sheet)
        let passphrase = sheet.secureTextFields["Passphrase"]
        wait(passphrase)
        passphrase.click()
        passphrase.typeText("secret")
        sheet.buttons["Import"].click()
        wait(text("Imported 2 keys and 1 host key"), "the result is wrong or missing")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        openSettings(tab: "Keys")
        wait(settingsWindow.staticTexts["id_ed25519"], "the plain key is not in the vault")
        wait(settingsWindow.staticTexts["id_locked"], "the protected key is not in the vault")
        openSettings(tab: "Known Hosts")
        wait(settingsWindow.staticTexts.matching(NSPredicate(format: "value CONTAINS 'example.test'")).firstMatch, "the host key was not trusted")
    }

    @MainActor func testAWrongPassphraseIsReportedAndTheOtherKeyIsStillImported() throws {
        try makeSSHFolder(keys: ["id_ed25519"], protected: ["id_locked": "secret"])
        launchFresh()
        wait(sheet)
        let passphrase = sheet.secureTextFields["Passphrase"]
        wait(passphrase)
        passphrase.click()
        passphrase.typeText("wrong")
        sheet.buttons["Import"].click()
        wait(text("Imported 1 key"), "the key that could be imported was not")
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'id_locked'")).firstMatch, "the failure on the protected key is not reported")
    }

    @MainActor func testUntickingAKeyLeavesItOut() throws {
        try makeSSHFolder(keys: ["id_ed25519", "id_other"])
        launchFresh()
        wait(sheet)
        sheet.checkBoxes["id_other, ssh-ed25519"].click()
        sheet.buttons["Import"].click()
        wait(text("Imported 1 key and 0 host keys"))
        sheet.buttons["Done"].click()
        openSettings(tab: "Keys")
        wait(settingsWindow.staticTexts["id_ed25519"])
        XCTAssertFalse(settingsWindow.staticTexts["id_other"].exists, "a key that was unticked was imported")
    }

    @MainActor func testIsOfferedOnlyOnceAndStillAvailableFromTheVaultMenu() throws {
        try makeSSHFolder(keys: ["id_ed25519"], knownHost: "example.test")
        launchFresh()
        wait(sheet)
        sheet.buttons["Not Now"].click()
        waitGone(sheet)

        // The next launch of the same install (preferences kept) does not offer it again...
        relaunchKeepingPreferences()
        wait(mainWindow.buttons["New Host…"], "the Welcome screen did not come back")
        Thread.sleep(forTimeInterval: 2.5)   // the offer, when made, comes within a moment of the window
        XCTAssertFalse(sheet.exists, "the offer was made a second time")

        // ...but it can always be opened by hand.
        chooseVaultMenu("Import Keys from ~/.ssh…")
        wait(sheet, "the Vault menu item did not open it")
        wait(sheet.checkBoxes["id_ed25519, ssh-ed25519"])
    }

    @MainActor func testNothingIsOfferedWhenThereIsNothingToImport() throws {
        // An empty ~/.ssh: nothing but a config file, which is not what this sheet imports.
        try makeSSHFolder(config: "Host a\n  HostName a.example.test\n")
        launchFresh()
        wait(mainWindow.buttons["New Host…"])
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(sheet.exists, "an offer was made with nothing to import")

        chooseVaultMenu("Import Keys from ~/.ssh…")
        wait(sheet)
        wait(text("Nothing to import was found"), "opening it by hand did not say there is nothing to import")
    }
}
