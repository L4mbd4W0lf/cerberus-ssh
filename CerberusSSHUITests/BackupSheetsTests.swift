import XCTest
import CryptoKit

/// Exporting and importing a vault backup through the real save and open panels, with a
/// round trip through "Erase All Data" to prove what comes back, secrets included.
final class BackupSheetsTests: CerberusUITestCase {
    private let passphrase = "correct horse battery"
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = testHome.appendingPathComponent("backups-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private var sheet: XCUIElement { settingsWindow.sheets.firstMatch }

    private var importComplete: XCUIElement {
        sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Import complete' OR label BEGINSWITH 'Import complete'")).firstMatch
    }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// The numbers in the row of a grid whose first text is `label`, left to right.
    private func numbers(in row: String) -> [Int] {
        let label = sheet.staticTexts.matching(NSPredicate(format: "value == %@", row)).firstMatch
        guard label.exists else { return [] }
        let y = label.frame.midY
        return sheet.staticTexts.allElementsBoundByIndex
            .filter { abs($0.frame.midY - y) < 4 && $0.frame.minX > label.frame.maxX }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { Int("\($0.value ?? "")") }
    }

    private func openExport() {
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Export Backup…"].click()
        wait(sheet, "the export sheet did not open")
    }

    private func fillPassphrases(_ one: String, _ two: String? = nil) {
        let pass = sheet.secureTextFields["Passphrase"], confirm = sheet.secureTextFields["Confirm passphrase"]
        enter(one, in: pass)
        enter(two ?? one, in: confirm)
    }

    /// Exports to `name` in `directory` (the test's own folder unless told otherwise), leaving the
    /// result sheet showing.
    private func export(to name: String, in directory: URL? = nil) {
        fillPassphrases(passphrase)
        sheet.buttons["Export…"].click()
        savePanel(directory: directory ?? folder, name: name)
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Saved '")).firstMatch, "the export did not finish")
    }

    // MARK: Export

    @MainActor func testExportNeedsMatchingPassphrasesAndSaysHowStrongOneIs() throws {
        openExport()
        XCTAssertFalse(sheet.buttons["Export…"].isEnabled, "Export is enabled with no passphrase")
        wait(sheet.staticTexts["Enter a passphrase"])

        fillPassphrases("abc", "abd")
        wait(sheet.staticTexts["The passphrases don't match."])
        XCTAssertFalse(sheet.buttons["Export…"].isEnabled)

        let confirm = sheet.secureTextFields["Confirm passphrase"]
        replace(confirm, with: "abc")
        wait(sheet.staticTexts["Weak"])
        wait(sheet.staticTexts["This passphrase is easy to guess. You can still use it."], "a weak passphrase is not warned about")
        XCTAssertTrue(sheet.buttons["Export…"].isEnabled, "a weak passphrase must warn, never block")

        for field in ["Passphrase", "Confirm passphrase"] {
            let f = sheet.secureTextFields[field]
            replace(f, with: passphrase)
        }
        wait(sheet.staticTexts["Strong"])
    }

    @MainActor func testExportWritesASealedFileAndTheResultDescribesIt() throws {
        openExport()
        export(to: "one.cerberusvault")
        let url = file("one.cerberusvault")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 200)
        let asText = String(decoding: data, as: UTF8.self)
        for secret in ["web-1.example.test", "uitest-password-1", "deploy", "Production"] {
            XCTAssertFalse(asText.contains(secret), "'\(secret)' is readable in the backup: it is not sealed")
        }
        XCTAssertEqual(numbers(in: "Hosts"), [3]); XCTAssertEqual(numbers(in: "Folders"), [3])
        XCTAssertEqual(numbers(in: "Identities"), [1]); XCTAssertEqual(numbers(in: "Secrets"), [1])
        XCTAssertEqual(numbers(in: "Known host keys"), [1]); XCTAssertEqual(numbers(in: "Snippets"), [0])

        // The checksum shown is the file's, so it can be compared later.
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        wait(sheet.staticTexts[expected], "the SHA-256 shown is not the file's")
    }

    @MainActor func testLeavingOutSecretsMakesACatalogueOnlyFile() throws {
        openExport()
        sheet.checkBoxes["Vault secrets (passwords and keys)"].click()
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'A catalogue-only export'")).firstMatch, "no note that this file holds no secrets")
        export(to: "catalogue.cerberusvault")
        XCTAssertEqual(numbers(in: "Secrets"), [0], "a catalogue-only export still counted secrets")
        XCTAssertEqual(numbers(in: "Hosts"), [3])
    }

    /// A passphrase saved from the export sheet is what the next export uses, with nothing to type; another can be typed
    /// for one backup, and only replaces the saved one if that is ticked.
    @MainActor func testASavedPassphraseIsUsedNextTimeAndAnotherNeedsTickingToReplaceIt() throws {
        openExport()
        sheet.checkBoxes["Save this passphrase in the Keychain"].click()
        export(to: "saved.cerberusvault")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        // Next time: no fields, the saved one is used.
        settingsWindow.buttons["Export Backup…"].click()
        wait(sheet)
        wait(sheet.staticTexts["Using the saved passphrase"], "a saved passphrase is not used by default")
        XCTAssertFalse(sheet.secureTextFields["Passphrase"].exists, "passphrase fields are shown though one is saved")
        XCTAssertTrue(sheet.buttons["Export…"].isEnabled)

        // A different one for this backup: fields appear, with the choice to replace the saved one (off).
        sheet.buttons["Use a Different Passphrase…"].click()
        wait(sheet.secureTextFields["Passphrase"], "no way to type another passphrase")
        let replace = sheet.descendants(matching: .any).matching(identifier: "backup-replace-saved").firstMatch
        wait(replace, "no choice to replace the saved passphrase")
        XCTAssertEqual(replace.value as? Int, 0, "replacing the saved passphrase should be off by default")
        XCTAssertFalse(sheet.buttons["Export…"].isEnabled, "export is enabled with nothing typed")
        sheet.buttons["Use the Saved Passphrase Instead"].click()
        wait(sheet.staticTexts["Using the saved passphrase"])
    }

    /// The button beside Export and Import clears the saved passphrase, says why that can hurt, and asks first.
    @MainActor func testClearingTheSavedPassphraseAsksFirstAndIsOnlyThereWhenThereIsOne() throws {
        launch()
        openSettings(tab: "Backup")
        let clear = settingsWindow.buttons["backup-clear-passphrase"]
        wait(clear, "no Clear Saved Passphrase button beside Export and Import")
        XCTAssertFalse(clear.isEnabled, "the button is enabled with no passphrase saved")

        settingsWindow.buttons["Export Backup…"].click()
        wait(sheet)
        sheet.checkBoxes["Save this passphrase in the Keychain"].click()
        export(to: "to-clear.cerberusvault")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        eventually("the button did not become available once a passphrase was saved") { clear.isEnabled }
        let caption = settingsWindow.descendants(matching: .any).matching(identifier: "backup-clear-caption").firstMatch
        wait(caption)
        XCTAssertTrue((caption.value as? String ?? caption.label).contains("can never be opened"), "the caption does not say why deleting is dangerous")

        clear.click()
        let confirm = app.buttons["backup-confirm-clear-passphrase"]
        wait(confirm, "clearing did not ask first")
        confirm.click()
        eventually("the passphrase was not cleared") { !clear.isEnabled }
    }

    // MARK: Import

    /// A backup of the seeded catalogue, made once for the whole class through the real export sheet:
    /// the import tests need a file to import, not a new export each. (A file is not tied to this
    /// Mac's vault key, only to its passphrase, so it still opens after the catalogue is reset.)
    nonisolated(unsafe) private static var sharedBackup: URL?

    private func ensureBackup() -> URL {
        if let url = Self.sharedBackup, FileManager.default.fileExists(atPath: url.path) { return url }
        let directory = testHome.appendingPathComponent("shared-backup")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shared.cerberusvault")
        try? FileManager.default.removeItem(at: url)
        openExport()
        export(to: "shared.cerberusvault", in: directory)
        sheet.buttons["Done"].click()
        waitGone(sheet)
        Self.sharedBackup = url
        return url
    }

    /// An empty install with Settings ▸ Backup open: what is left after "Erase All Data", reached
    /// by the app's reset, which is what that does (the erase itself is tested in `SettingsTests`).
    private func startEmptyInstall() {
        options.seed = "empty"
        launch()
        openSettings(tab: "Backup")
    }

    private func chooseBackup(_ url: URL, passphrase typed: String) {
        settingsWindow.buttons["Import Backup…"].click()
        wait(sheet)
        sheet.buttons["Choose file…"].click()
        openPanel(choose: url)
        wait(sheet.staticTexts[url.lastPathComponent])
        enter(typed, in: sheet.secureTextFields["Passphrase"])
        sheet.buttons["Open"].click()
    }

    @MainActor func testImportBringsEverythingBackIncludingTheStoredPassword() throws {
        let backup = ensureBackup()
        startEmptyInstall()
        chooseBackup(backup, passphrase: passphrase)
        wait(sheet.staticTexts["In this backup"], "no preview of what the file holds")
        XCTAssertEqual(numbers(in: "Hosts"), [3, 0, 0], "into an empty install every host should be new")
        XCTAssertEqual(numbers(in: "Identities"), [1, 0, 0])
        XCTAssertEqual(sheet.radioButtons["Merge"].value as? Int, 1, "Merge should be the default")
        sheet.buttons["Import"].click()
        wait(importComplete, "no result after importing")
        wait(sheet.staticTexts.matching(NSPredicate(format: "value ENDSWITH ' added, 0 updated, 0 left as they were.'")).firstMatch,
             "importing into an empty install should add everything and change nothing else")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        mainWindow.click()
        wait(hostRow("web-1"), "the hosts did not come back")
        wait(hostRow("db-1"))
        openSettings(tab: "Known Hosts")
        wait(settingsWindow.staticTexts["web-1.example.test:22"], "the trusted host key did not come back")
        // The secret was sealed again under this Mac's (new) vault key, and still opens.
        openSettings(tab: "Identities")
        settingsWindow.staticTexts["deploy"].firstMatch.click()
        settingsWindow.buttons["Reveal Password…"].click()
        wait(settingsWindow.staticTexts["uitest-password-1"], "the stored password did not survive the round trip")
    }

    /// Preferences travel by default, can be left out, and are offered (not forced) when a file that has them is opened.
    @MainActor func testPreferencesCanBeLeftOutOfAnExportAndAreOfferedOnImport() throws {
        openExport()
        let include = sheet.descendants(matching: .any).matching(identifier: "backup-include-preferences").firstMatch
        wait(include, "no switch for preferences in the export sheet")
        XCTAssertEqual(include.value as? Int, 1, "preferences should be included by default")
        include.click()
        export(to: "no-prefs.cerberusvault")
        wait(sheet.staticTexts["not included"], "the result does not say the preferences were left out")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        // A file that has them: the import sheet offers them, on, and says security settings are not among them.
        let backup = ensureBackup()
        startEmptyInstall()
        chooseBackup(backup, passphrase: passphrase)
        wait(sheet.staticTexts["In this backup"], "no preview of what the file holds")
        let restore = sheet.descendants(matching: .any).matching(identifier: "import-restore-preferences").firstMatch
        wait(restore, "a file with preferences does not offer them")
        XCTAssertEqual(restore.value as? Int, 1)
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Security settings are never part of a backup'")).firstMatch.exists)
        sheet.buttons["Import"].click()
        wait(importComplete, "no result after importing")
    }

    /// With a passphrase saved, choosing a file tries it first and goes straight to the preview.
    @MainActor func testImportTriesTheSavedPassphraseFirst() throws {
        openExport()
        sheet.checkBoxes["Save this passphrase in the Keychain"].click()
        export(to: "first.cerberusvault")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        settingsWindow.buttons["Import Backup…"].click()
        wait(sheet)
        sheet.buttons["Choose file…"].click()
        openPanel(choose: file("first.cerberusvault"))
        wait(sheet.staticTexts["In this backup"], "the saved passphrase was not tried: no preview")
        XCTAssertFalse(sheet.secureTextFields["Passphrase"].exists)
    }

    /// If the saved passphrase does not open the file, the person is asked for the one it was made with.
    @MainActor func testImportAsksForThePassphraseWhenTheSavedOneDoesNotOpenTheFile() throws {
        openExport()
        sheet.checkBoxes["Save this passphrase in the Keychain"].click()
        export(to: "saved-one.cerberusvault")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        // A second backup with a different passphrase, the saved one left alone.
        settingsWindow.buttons["Export Backup…"].click()
        wait(sheet)
        sheet.buttons["Use a Different Passphrase…"].click()
        let other = "another passphrase entirely"
        enter(other, in: sheet.secureTextFields["Passphrase"])
        enter(other, in: sheet.secureTextFields["Confirm passphrase"])
        sheet.buttons["Export…"].click()
        savePanel(directory: folder, name: "other-one.cerberusvault")
        wait(sheet.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Saved '")).firstMatch, "the export did not finish")
        sheet.buttons["Done"].click()
        waitGone(sheet)

        settingsWindow.buttons["Import Backup…"].click()
        wait(sheet)
        sheet.buttons["Choose file…"].click()
        openPanel(choose: file("other-one.cerberusvault"))
        wait(sheet.descendants(matching: .any).matching(identifier: "import-saved-failed").firstMatch,
             "no message that the saved passphrase did not open the file")
        XCTAssertFalse(sheet.staticTexts["In this backup"].exists, "a file the saved passphrase cannot open was previewed")
        enter(other, in: sheet.secureTextFields["Passphrase"])
        sheet.buttons["Open"].click()
        wait(sheet.staticTexts["In this backup"], "typing the right passphrase did not open the file")
    }

    @MainActor func testImportingTheSameFileAgainFindsEverythingAlreadyThere() throws {
        let backup = ensureBackup()
        startEmptyInstall()
        chooseBackup(backup, passphrase: passphrase)
        wait(sheet.staticTexts["In this backup"])
        sheet.buttons["Import"].click()
        wait(importComplete)
        sheet.buttons["Done"].click()
        waitGone(sheet)

        chooseBackup(backup, passphrase: passphrase)
        wait(sheet.staticTexts["In this backup"])
        XCTAssertEqual(numbers(in: "Hosts"), [0, 3, 0], "a second import should find every host already here")
    }

    @MainActor func testAWrongPassphraseIsRefusedWithNoPreview() throws {
        let backup = ensureBackup()
        startEmptyInstall()
        chooseBackup(backup, passphrase: "not the passphrase")
        let problem = sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'passphrase' AND NOT (value BEGINSWITH 'The file is verified')")).firstMatch
        wait(problem, "a wrong passphrase was not reported", timeout: 15)
        XCTAssertFalse(sheet.staticTexts["In this backup"].exists, "a preview was shown for a wrong passphrase")
    }

    @MainActor func testAFileThatIsNotABackupIsRefused() throws {
        try Data("this is not a backup".utf8).write(to: file("fake.cerberusvault"))
        launch()
        openSettings(tab: "Backup")
        chooseBackup(file("fake.cerberusvault"), passphrase: passphrase)
        let open = sheet.buttons["Open"]
        // Something above the buttons explains it (the sheet's own hint is the only other text there).
        eventually("no explanation for a file that is not a backup", timeout: 15) {
            sheet.staticTexts.allElementsBoundByIndex.contains {
                guard let text = $0.value as? String, !text.isEmpty else { return false }
                return $0.frame.minY > open.frame.minY - 80 && $0.frame.minY < open.frame.minY && !text.hasPrefix("The file is verified")
            }
        }
        XCTAssertFalse(sheet.staticTexts["In this backup"].exists, "a preview was shown for a file that is not a backup")
    }

    @MainActor func testReplaceNeedsTheWordBeforeItCanRun() throws {
        let backup = ensureBackup()
        startEmptyInstall()
        chooseBackup(backup, passphrase: passphrase)
        wait(sheet.staticTexts["In this backup"])
        sheet.radioButtons["Replace everything"].click()
        let word = sheet.textFields.matching(NSPredicate(format: "placeholderValue == 'Type REPLACE to confirm'")).firstMatch
        wait(word, "Replace everything does not ask to be confirmed")
        XCTAssertFalse(sheet.buttons["Import"].isEnabled, "Replace can run without the word")
        word.click(); word.typeText("REPLACE")
        XCTAssertTrue(sheet.buttons["Import"].isEnabled)
        sheet.buttons["Import"].click()
        wait(importComplete)
        sheet.buttons["Done"].click()
        mainWindow.click()
        wait(hostRow("web-1"), "replacing did not bring the hosts back")
    }
}

/// Sharing the saved backup passphrase through iCloud Keychain. A test build has no keychain access group,
/// so the switch is there and off-limits, and says why; the real thing is covered by package tests and by the signed build.
final class SharedPassphraseTests: CerberusUITestCase {
    @MainActor func testTheShareSwitchIsUnavailableInABuildThatCannotUseICloudKeychain() {
        launch()
        openSettings(tab: "Advanced")
        let toggle = settingsWindow.descendants(matching: .any).matching(identifier: "backup-share-passphrase").firstMatch
        wait(toggle, "no switch to share the saved passphrase")
        XCTAssertFalse(toggle.isEnabled, "the switch is usable in a build that cannot use iCloud Keychain")
        wait(settingsWindow.descendants(matching: .any).matching(identifier: "backup-share-unavailable").firstMatch,
             "the switch is disabled without saying why")
        // The vault key has its own switch, unavailable for the same reason.
        let keySwitch = settingsWindow.descendants(matching: .any).matching(identifier: "vault-key-icloud").firstMatch
        wait(keySwitch, "no switch to keep the vault key in iCloud Keychain")
        XCTAssertFalse(keySwitch.isEnabled)
        let keyStatus = settingsWindow.descendants(matching: .any).matching(identifier: "vault-key-status").firstMatch
        wait(keyStatus)
        let text = keyStatus.value as? String ?? keyStatus.label
        XCTAssertTrue(text.contains("Keychain on this Mac"), "the vault key's status does not say where it is: \(text)")
    }
}
