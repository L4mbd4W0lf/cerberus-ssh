import XCTest

/// Importing hosts from an OpenSSH config file, against a throwaway `~/.ssh`.
final class ImportSSHConfigTests: CerberusUITestCase {
    private var sheet: XCUIElement { mainWindow.sheets.firstMatch }

    /// `bastion`, `app-1` (via the bastion, with a key and a forward) and `web-1`, which the seeded
    /// catalogue already has but at a different address. `Host *` gives them all a user.
    private let config = """
    Host bastion
        HostName bastion.example.test
        User ops
    Host app-1
        HostName 10.0.0.5
        Port 2200
        ProxyJump bastion
        IdentityFile ~/.ssh/id_ed25519
        LocalForward 9000 localhost:9000
    Host web-1
        HostName other.example.test
    Host *
        User deploy
    """

    private func openSheet(config: String? = nil, keys: [String] = ["id_ed25519"], protected: [String: String] = [:]) throws {
        try makeSSHFolder(keys: keys, protected: protected, config: config ?? self.config)
        launch()
        wait(hostRow("web-1"))
        chooseVaultMenu("Import Hosts from ssh config…")
        wait(sheet, "the import sheet did not open")
        wait(sheet.staticTexts["Import SSH Config"])
    }

    private func text(_ prefix: String) -> XCUIElement {
        sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor func testTheSheetListsHostsWithWhatIsAlreadyHereAndTheKeysTheyUse() throws {
        try openSheet()
        for host in ["bastion", "app-1", "web-1"] { wait(sheet.staticTexts[host], "\(host) is not listed") }
        // `Host *` supplied the user and `Port` was read.
        wait(sheet.staticTexts["deploy@10.0.0.5:2200"], "the wildcard block's user, or the port, was not applied")
        wait(sheet.staticTexts["ops@bastion.example.test"], "an explicit User did not win over Host *")

        // web-1 exists already with another address: shown, and cannot be chosen.
        wait(text("a different host is called this"), "no note on the clashing host")
        XCTAssertFalse(sheet.checkBoxes.element(boundBy: 2).isEnabled, "a host that clashes can be ticked")
        wait(text("2 of 3 chosen"))
        wait(sheet.staticTexts["id_ed25519"], "the key the host signs in with is not listed")
        wait(text("used by 1"))
        XCTAssertEqual(sheet.textFields["Folder"].value as? String, "SSH config")
        wait(text("• 1 wildcard block"), "the wildcard block is not mentioned")
    }

    @MainActor func testImportingAddsHostsAKeyAndAForwardAndLeavesTheClashingHostAlone() throws {
        try openSheet()
        sheet.buttons["Import"].click()
        wait(text("Imported 2 hosts"), "no result")
        wait(text("1 key added"))
        wait(text("1 port forward added"))
        wait(text("No key was found for bastion"), "a host with no key was not flagged as needing an identity")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        wait(folderRow("SSH config"), "the folder was not made")
        wait(hostRow("app-1")); wait(hostRow("bastion"))
        XCTAssertEqual(sidebar.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'web-1'")).count, 1, "the clashing host was duplicated or replaced")
        showSidebarTab(.forwards)
        wait(sidebar.staticTexts.matching(NSPredicate(format: "value CONTAINS ':9000'")).firstMatch, "the forward is not in the Port Forwards tab")

        // The key and an identity for it exist.
        openSettings(tab: "Keys")
        wait(settingsWindow.staticTexts["id_ed25519"], "the key is not in the vault")
        openSettings(tab: "Identities")
        wait(settingsWindow.staticTexts["deploy (id_ed25519)"], "no identity was made for the user and key")
    }

    @MainActor func testImportingTwiceChangesNothing() throws {
        try openSheet()
        sheet.buttons["Import"].click()
        wait(text("Imported 2 hosts"))
        sheet.buttons["Done"].click()
        waitGone(sheet)

        chooseVaultMenu("Import Hosts from ssh config…")
        wait(sheet)
        wait(text("0 of 3 chosen"), "hosts that were imported can be imported again")
        XCTAssertEqual(sheet.staticTexts.matching(NSPredicate(format: "value == 'already here'")).count, 2)
        XCTAssertFalse(sheet.buttons["Import"].isEnabled, "Import is enabled with nothing to import")
    }

    @MainActor func testChoosingOnlyAHostThatJumpsBringsItsJumpHostToo() throws {
        try openSheet()
        sheet.checkBoxes.element(boundBy: 0).click()   // untick bastion
        wait(text("1 of 3 chosen"))
        sheet.buttons["Import"].click()
        wait(text("Imported 1 host"))
        wait(text("1 more added because other hosts jump through them"), "the jump host was not brought along")
        sheet.buttons["Done"].click()
        wait(hostRow("app-1")); wait(hostRow("bastion"))
    }

    @MainActor func testNoneDisablesImportAndAllChoosesTheNewOnes() throws {
        try openSheet()
        sheet.buttons["None"].click()
        wait(text("0 of 3 chosen"))
        XCTAssertFalse(sheet.buttons["Import"].isEnabled)
        sheet.buttons["All"].click()
        wait(text("2 of 3 chosen"), "All should choose only the hosts that are new")
        XCTAssertTrue(sheet.buttons["Import"].isEnabled)
    }

    @MainActor func testAnEncryptedKeyAsksForItsPassphrase() throws {
        try openSheet(config: "Host box\n  HostName box.example.test\n  User root\n  IdentityFile ~/.ssh/id_locked\n", keys: [], protected: ["id_locked": "secret"])
        wait(sheet.staticTexts["id_locked"])
        let field = sheet.secureTextFields["Passphrase"]
        wait(field, "no passphrase field for an encrypted key")
        field.click()
        field.typeText("secret")
        sheet.buttons["Import"].click()
        wait(text("1 key added"), "the right passphrase did not import the key")
        XCTAssertFalse(text("No key was found").exists, "a host with its key was flagged as needing one")
    }

    @MainActor func testAWrongPassphraseIsReportedAndTheHostIsStillImported() throws {
        try openSheet(config: "Host box\n  HostName box.example.test\n  User root\n  IdentityFile ~/.ssh/id_locked\n", keys: [], protected: ["id_locked": "secret"])
        let field = sheet.secureTextFields["Passphrase"]
        wait(field)
        field.click()
        field.typeText("not-the-passphrase")
        sheet.buttons["Import"].click()
        wait(text("Imported 1 host"))
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'id_locked'")).firstMatch, "the failure on the key is not reported")
        wait(text("No key was found for box"), "the host was not flagged as needing an identity")
    }

    @MainActor func testAMissingConfigFileIsExplained() throws {
        try makeSSHFolder(keys: ["id_ed25519"])   // no config
        launch()
        chooseVaultMenu("Import Hosts from ssh config…")
        wait(sheet)
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'There is no config file'")).firstMatch)
        XCTAssertFalse(sheet.buttons["Import"].isEnabled)
    }
}
