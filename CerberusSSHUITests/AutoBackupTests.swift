import XCTest

/// Automatic backups (spec §6.6): setting them up after a first backup, what they write and where,
/// keeping only the last few, and saying so when they cannot run.
final class AutoBackupTests: CerberusUITestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = testHome.appendingPathComponent("backups-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        options.lastExport = true
    }

    private var sheet: XCUIElement { settingsWindow.sheets.firstMatch }

    /// Preferences in place from the start.
    private func preset(_ values: [String: Any]) { options.defaults = values }

    /// The preferences a person's would be after setting this up.
    private func configured(keep: Int = 10, lastAt: TimeInterval? = nil, folder path: String? = nil, passphrase: String? = "correct horse battery") {
        preset([
            "autoBackupEnabled": true, "autoBackupFolder": path ?? folder.path, "autoBackupFrequency": "weekly",
            "autoBackupKeep": keep, "autoBackupLastAt": lastAt ?? Date().timeIntervalSince1970,
        ])
        options.backupPassphrase = passphrase
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("CerberusSSH auto ") && $0.hasSuffix(".cerberusvault") }.sorted()
    }

    private func text(_ prefix: String) -> XCUIElement {
        settingsWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
    }

    // MARK: Setting up

    @MainActor func testTheSectionOffersSetupOnceAFirstBackupExists() throws {
        launch()
        openSettings(tab: "Backup")
        wait(settingsWindow.buttons["Set Up Automatic Backups…"], "no way to set up automatic backups after a first backup")
        XCTAssertFalse(text("Make your first backup").exists, "it still asks for a first backup")
    }

    @MainActor func testSetupNeedsAFolderAndMatchingPassphrases() throws {
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Set Up Automatic Backups…"].click()
        wait(sheet)
        let turnOn = sheet.buttons["Turn On"]
        XCTAssertFalse(turnOn.isEnabled, "Turn On is enabled with no folder and no passphrase")
        wait(sheet.staticTexts["No folder chosen"])
        XCTAssertEqual(sheet.popUpButtons.element(boundBy: 0).value as? String, "Every week")
        XCTAssertEqual(sheet.popUpButtons.element(boundBy: 1).value as? String, "the last 10 backups")

        let pass = sheet.secureTextFields["Passphrase"], confirm = sheet.secureTextFields["Confirm passphrase"]
        enter("one passphrase", in: pass)
        enter("another passphrase", in: confirm)
        wait(sheet.staticTexts["The passphrases don't match."], "a mismatch is not pointed out")
        XCTAssertFalse(turnOn.isEnabled)
    }

    @MainActor func testTurningOnWritesTheFirstBackupAtOnceAndItIsSealed() throws {
        preset(["autoBackupFolder": folder.path])   // what choosing the folder in the panel sets
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Set Up Automatic Backups…"].click()
        wait(sheet)
        wait(sheet.staticTexts.matching(NSPredicate(format: "value == %@", folder.path)).firstMatch, "the chosen folder is not shown")
        let pass = sheet.secureTextFields["Passphrase"], confirm = sheet.secureTextFields["Confirm passphrase"]
        enter("correct horse battery", in: pass)
        enter("correct horse battery", in: confirm)
        XCTAssertTrue(sheet.buttons["Turn On"].isEnabled)
        sheet.buttons["Turn On"].click()
        waitGone(sheet)

        eventually("the first automatic backup was not written", timeout: 40) { backups().count == 1 }
        let file = folder.appendingPathComponent(backups()[0])
        let data = try Data(contentsOf: file)
        XCTAssertGreaterThan(data.count, 200, "the backup is empty")
        let asText = String(decoding: data, as: UTF8.self)
        for secret in ["web-1.example.test", "uitest-password-1", "deploy"] {
            XCTAssertFalse(asText.contains(secret), "'\(secret)' is readable in the backup file: it is not sealed")
        }

        // The section now describes the schedule and the last backup.
        wait(settingsWindow.staticTexts["Last automatic backup"])
        wait(settingsWindow.buttons["Back Up Now"])
        wait(text("Every week, keeping the last 10"))
        XCTAssertFalse(settingsWindow.staticTexts["None yet"].exists, "the last backup still says none")
    }

    // MARK: Running

    @MainActor func testBackUpNowAddsOneAndOnlyTheLastFewAreKept() throws {
        try Data("mine".utf8).write(to: folder.appendingPathComponent("my-own-export.cerberusvault"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        configured(keep: 3, lastAt: Date().timeIntervalSince1970)
        launch()
        openSettings(tab: "Backup")
        let now = settingsWindow.buttons["Back Up Now"]
        wait(now)

        var seen: [String] = []
        for round in 1...5 {
            now.click()
            eventually("backup \(round) was not written", timeout: 40) { backups().count == min(round, 3) && backups().last != seen.last }
            seen = backups()
            Thread.sleep(forTimeInterval: 1.2)   // file names have a resolution of a second
        }
        XCTAssertEqual(backups().count, 3, "more than the last three were kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("my-own-export.cerberusvault").path), "a person's own export was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path), "an unrelated file was removed")
    }

    @MainActor func testABackupThatIsDueIsTakenWithoutAnyoneAsking() throws {
        configured(lastAt: 1)   // the 1970s: long overdue
        launch()
        eventually("a backup that was overdue was not taken by itself", timeout: 40) { backups().count == 1 }
    }

    @MainActor func testABackupThatIsNotYetDueIsNotTaken() throws {
        configured(lastAt: Date().timeIntervalSince1970 - 3600)   // an hour ago, weekly schedule
        launch()
        openSettings(tab: "Backup")
        wait(settingsWindow.buttons["Back Up Now"])
        Thread.sleep(forTimeInterval: 4)   // the schedule checks within a moment of launch
        XCTAssertTrue(backups().isEmpty, "a backup was taken before it was due")
    }

    // MARK: Failing in the open

    @MainActor func testAnUnavailableFolderIsReportedAndNothingIsWritten() throws {
        configured(folder: folder.appendingPathComponent("unplugged-drive").path)
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Back Up Now"].click()
        wait(text("The backup folder isn't available"), "an unavailable folder was not reported")
        XCTAssertTrue(backups().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unplugged-drive").path), "the missing folder was created behind the person's back")
    }

    @MainActor func testAMissingPassphraseIsReported() throws {
        configured(passphrase: nil)
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Back Up Now"].click()
        wait(text("No backup passphrase is saved"), "a missing passphrase was not reported")
        XCTAssertTrue(backups().isEmpty)
    }

    @MainActor func testTurningOffReturnsTheSectionToSetup() throws {
        configured(lastAt: Date().timeIntervalSince1970)
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Turn Off"].click()
        wait(settingsWindow.buttons["Set Up Automatic Backups…"], "Turn Off did not return the section to setup")
        XCTAssertFalse(settingsWindow.buttons["Back Up Now"].exists)
    }

    @MainActor func testTheFolderIsChosenInThePanelAndShownInTheSheet() throws {
        launch()
        openSettings(tab: "Backup")
        settingsWindow.buttons["Set Up Automatic Backups…"].click()
        wait(sheet)
        wait(sheet.staticTexts["No folder chosen"])
        sheet.buttons["Choose…"].click()
        let panel = app.dialogs["open-panel"].exists ? app.dialogs["open-panel"] : app.dialogs.firstMatch
        wait(panel, "the folder panel did not open")
        goToFolder(folder.path)
        panel.buttons["OKButton"].click()
        waitGone(panel)
        wait(sheet.staticTexts.matching(NSPredicate(format: "value == %@", folder.path)).firstMatch, "the chosen folder is not shown")
        XCTAssertFalse(sheet.staticTexts["No folder chosen"].exists)
    }
}
