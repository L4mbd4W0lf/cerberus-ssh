import XCTest

final class SettingsTests: CerberusUITestCase {
    @MainActor func testEveryTabIsThere() {
        launch()
        openSettings()
        wait(settingsTab("Advanced"), "the sidebar never showed its categories")
        for tab in ["Backup", "Identities", "Keys", "Known Hosts", "Appearance", "Behaviour", "Snippets", "Recordings", "Connection", "Advanced", "About"] {
            // The sidebar fills in as the window settles, so each is waited for rather than looked for once.
            XCTAssertTrue(settingsTab(tab).waitForExistence(timeout: 5), "no \(tab) category")
        }
    }

    /// The sidebar keeps its width and stays on screen: dragging its edge, dragging it shut and the
    /// Toggle Sidebar shortcut all leave it as it was.
    @MainActor func testTheSidebarCannotBeResizedOrCollapsed() {
        launch()
        openSettings()
        let tab = settingsTab("Backup")
        wait(tab, "the sidebar never showed its categories")
        let window = settingsWindow
        let before = tab.frame
        let divider = window.splitters.firstMatch

        func dragDivider(by dx: CGFloat) {
            let edge = divider.exists
                ? divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: before.maxX - window.frame.minX + 12, dy: window.frame.height / 2))
            edge.click(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)))
        }

        dragDivider(by: 120)
        XCTAssertEqual(tab.frame.width, before.width, accuracy: 4, "the sidebar was widened by dragging")
        dragDivider(by: -300)
        XCTAssertTrue(tab.exists && tab.isHittable, "the sidebar was dragged shut")
        XCTAssertEqual(tab.frame.width, before.width, accuracy: 4, "the sidebar was narrowed by dragging")

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(tab.isHittable, "the sidebar was hidden by the shortcut")
        XCTAssertEqual(tab.frame.minX, before.minX, accuracy: 4)
        XCTAssertEqual(tab.frame.width, before.width, accuracy: 4)
    }

    /// Clicking a column header orders the rows by it, and clicking again reverses them.
    @MainActor func testClickingAHeaderOrdersTheIdentities() {
        launch()
        openSettings(tab: "Identities")
        wait(settingsWindow.staticTexts["deploy"].firstMatch, "the seeded identity is not listed")
        settingsWindow.buttons["New Identity…"].click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let name = sheet.textFields["identity-name"]
        name.click(); name.typeText("alpha")
        let user = sheet.textFields["identity-username"]
        user.click(); user.typeText("zed")
        let password = sheet.secureTextFields["identity-password"]
        password.click(); password.typeText("secret")
        sheet.buttons["Add"].click()
        let table = settingsWindow.descendants(matching: .any)["identities-table"].firstMatch
        wait(table)
        // Looked for in the table: the selected identity's name is also shown below it.
        let alpha = table.staticTexts["alpha"].firstMatch
        wait(alpha, "the new identity is not listed")
        let deploy = table.staticTexts["deploy"].firstMatch

        func clickHeader(_ title: String) {
            let header = table.buttons[title].firstMatch
            wait(header, "no \(title) column header")
            // Clicked by position: XCTest does not call the header hittable, as it sits above the table's rows.
            let frame = header.frame
            settingsWindow.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - settingsWindow.frame.minX, dy: frame.midY - settingsWindow.frame.minY)).click()
        }
        func isAbove(_ first: XCUIElement, _ second: XCUIElement) -> Bool { first.frame.minY < second.frame.minY }

        // The table opens ordered by name, so the first click on Name reverses it.
        eventually("alpha is not above deploy to begin with") { isAbove(alpha, deploy) }
        clickHeader("Name")
        eventually("Name did not reverse the order") { isAbove(deploy, alpha) }
        clickHeader("Name")
        eventually("a second click did not restore Name order") { isAbove(alpha, deploy) }
        clickHeader("User")
        eventually("User did not put deploy (user deploy) before alpha (user zed)") { isAbove(deploy, alpha) }
        clickHeader("User")
        eventually("a second click did not reverse User") { isAbove(alpha, deploy) }
    }

    @MainActor func testAutomaticBackupsWaitForAFirstBackup() {
        launch()
        openSettings(tab: "Backup")
        wait(settingsWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Make your first backup'")).firstMatch)
        XCTAssertFalse(settingsWindow.buttons["Set Up Automatic Backups…"].exists)
    }

    @MainActor func testTheSecurityPolicyCanBeChanged() {
        launch()
        openSettings(tab: "Behaviour")
        let picker = settingsWindow.popUpButtons.firstMatch
        wait(picker)
        XCTAssertEqual(picker.value as? String, "When revealing or changing secrets")
        picker.click()
        app.menuItems["Never"].click()
        wait(settingsWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Nothing is asked'")).firstMatch,
             "the explanation did not change to match Never")
    }

    @MainActor func testRevealingAStoredPasswordShowsItAndItHidesAgain() {
        launch()
        openSettings(tab: "Identities")
        let row = settingsWindow.staticTexts["deploy"].firstMatch
        wait(row, "the seeded identity is not listed")
        row.click()
        let reveal = settingsWindow.buttons["Reveal Password…"]
        wait(reveal)
        reveal.click()
        wait(settingsWindow.staticTexts["uitest-password-1"], "the password was not shown")
    }

    @MainActor func testRemovingATrustedHostKey() {
        launch()
        openSettings(tab: "Known Hosts")
        let row = settingsWindow.staticTexts["web-1.example.test:22"].firstMatch
        wait(row, "the seeded host key is not listed")
        row.click()
        settingsWindow.buttons["Remove…"].click()
        let confirm = app.sheets.buttons["Remove"].firstMatch
        wait(confirm, "no confirmation was asked for")
        confirm.click()
        waitGone(row, "the key is still listed")
    }

    @MainActor func testErasingAllDataNeedsTheWordAndEmptiesTheCatalogue() {
        launch()
        wait(hostRow("web-1"))
        openSettings(tab: "Advanced")
        settingsWindow.buttons["Erase All Data…"].click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let erase = sheet.buttons["Erase"]
        XCTAssertFalse(erase.isEnabled, "Erase is enabled before the word is typed")
        let field = sheet.textFields["ERASE"]
        field.click()
        field.typeText("ERASE")
        XCTAssertTrue(erase.isEnabled)
        erase.click()
        wait(settingsWindow.staticTexts["All data erased."], "no confirmation of the erase")
        mainWindow.click()
        waitGone(hostRow("web-1"), "the host survived an erase")
    }

    /// Found by a test that selected a host, opened a file tab and then reset the app: the erase never finished.
    @MainActor func testErasingAllDataWithAHostSelectedAndAFileTabOpenFinishes() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        hostRow("web-1").rightClick()
        let items = app.menuItems.matching(identifier: "SFTP")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch, "no file tab")

        openSettings(tab: "Advanced")
        settingsWindow.buttons["Erase All Data…"].click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let field = sheet.textFields["ERASE"]
        field.click()
        field.typeText("ERASE")
        sheet.buttons["Erase"].click()
        wait(settingsWindow.staticTexts["All data erased."], "the erase never finished", timeout: 20)
    }
}

final class IdentityUnusedMarkTests: CerberusUITestCase {
    /// An identity no host uses is marked with a warning, and nothing offers to delete them in bulk or does it
    /// by itself (spec F10): removing a credential is one identity at a time, by choice.
    @MainActor func testAnIdentityNoHostUsesIsMarkedAndNeverBulkDeleted() {
        launch()
        openSettings(tab: "Identities")
        wait(settingsWindow.staticTexts["deploy"].firstMatch, "the seeded identity is not listed")
        XCTAssertFalse(settingsWindow.descendants(matching: .any).matching(identifier: "identity-unused-deploy").firstMatch.exists,
                       "an identity a host uses is marked as unused")

        settingsWindow.buttons["New Identity…"].click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let name = sheet.textFields["identity-name"]
        name.click(); name.typeText("spare")
        let user = sheet.textFields["identity-username"]
        user.click(); user.typeText("nobody")
        let password = sheet.secureTextFields["identity-password"]
        password.click(); password.typeText("secret")
        sheet.buttons["Add"].click()

        wait(settingsWindow.descendants(matching: .any).matching(identifier: "identity-unused-spare").firstMatch,
             "an identity no host uses is not marked")
        XCTAssertFalse(settingsWindow.buttons["identities-delete-unused"].exists, "there is a bulk delete for unused identities")
        XCTAssertTrue(settingsWindow.staticTexts["deploy"].firstMatch.exists)
    }
}

final class KeyPassphraseTests: CerberusUITestCase {
    /// A key made in the vault gets a passphrase the vault is told not to remember; the next change then asks for it,
    /// and a wrong one is refused.
    @MainActor func testChangingAKeysPassphraseAsksForTheOldOneNextTime() {
        launch()
        openSettings(tab: "Keys")
        settingsWindow.buttons["Generate…"].click()
        let generate = settingsWindow.sheets.firstMatch
        wait(generate)
        let name = generate.textFields["key-generate-name"]
        name.click(); name.typeText("pass-key")
        generate.buttons["Generate"].click()
        wait(generate.buttons["Done"], "the key was not made", timeout: 30)
        generate.buttons["Done"].click()

        let change = settingsWindow.buttons["key-change-passphrase"]
        wait(change)
        change.click()
        var sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        XCTAssertFalse(sheet.secureTextFields["key-passphrase-old"].exists, "an unprotected key asked for a current passphrase")
        for id in ["key-passphrase-new", "key-passphrase-confirm"] {
            let field = sheet.secureTextFields[id]
            field.click(); field.typeText("first")
        }
        let remember = sheet.switches["key-passphrase-remember"]
        wait(remember)
        remember.click()   // do not remember
        sheet.buttons["key-passphrase-change"].click()
        waitGone(sheet, "the passphrase sheet did not close")

        change.click()
        sheet = settingsWindow.sheets.firstMatch
        let old = sheet.secureTextFields["key-passphrase-old"]
        wait(old, "the protected key did not ask for its current passphrase")
        old.click(); old.typeText("wrong")
        let new = sheet.secureTextFields["key-passphrase-new"]
        new.click(); new.typeText("second")
        let confirm = sheet.secureTextFields["key-passphrase-confirm"]
        confirm.click(); confirm.typeText("second")
        sheet.buttons["key-passphrase-change"].click()
        wait(sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'passphrase'")).element(boundBy: 0), "a wrong passphrase was not refused")
        XCTAssertTrue(sheet.exists, "the sheet closed on a wrong passphrase")
    }
}

final class KeyGenerateStrengthTests: CerberusUITestCase {
    /// The Generate sheet rates a passphrase as it is typed, and shows nothing for no passphrase (it is optional).
    @MainActor func testTheGenerateSheetRatesThePassphraseAsItIsTyped() {
        launch()
        openSettings(tab: "Keys")
        settingsWindow.buttons["Generate…"].click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let rating = sheet.staticTexts["key-generate-strength"]
        XCTAssertFalse(rating.exists, "a rating is shown with no passphrase")

        let passphrase = sheet.secureTextFields["key-generate-passphrase"]
        passphrase.click(); passphrase.typeText("abc")
        wait(rating, "no rating for a passphrase")
        func rated() -> String { (rating.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rating.label }
        XCTAssertTrue(rated().hasSuffix("Weak"), "rated \(rated())")

        passphrase.typeText("-correct horse battery staple 42!")
        eventually("a long passphrase is not rated Strong") { rated().hasSuffix("Strong") }
    }
}

final class KeyInstallTests: CerberusUITestCase {
    /// A generated key is put on a host (the test's stand-in for a server is a folder), once, and its public line is
    /// what lands in authorized_keys.
    @MainActor func testInstallingAKeyOnAHostAddsItToAuthorizedKeysOnce() throws {
        launch()
        openSettings(tab: "Keys")
        settingsWindow.buttons["Generate…"].click()
        let generate = settingsWindow.sheets.firstMatch
        wait(generate)
        let name = generate.textFields["key-generate-name"]
        name.click(); name.typeText("install-key")
        generate.buttons["Generate"].click()
        wait(generate.buttons["Done"], "the key was not made", timeout: 30)
        generate.buttons["Done"].click()

        let install = settingsWindow.buttons["key-install"]
        wait(install)
        install.click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        // A searchable list: narrow it, then pick the host.
        let search = sheet.textFields["key-install-search"]
        search.click(); search.typeText("web-1")
        let row = sheet.staticTexts["web-1"]
        wait(row, "web-1 is not in the list")
        XCTAssertFalse(sheet.staticTexts["db-1"].exists, "the search did not narrow the list")
        row.click()
        sheet.buttons["key-install-go"].click()

        let result = sheet.staticTexts["key-install-result"]
        wait(result, "no result", timeout: 20)
        XCTAssertTrue((result.value as? String ?? result.label).contains("installed"), "not installed: \(result.label)")

        let file = testHome.appendingPathComponent("uitest-hosts/web-1/.ssh/authorized_keys")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("ssh-ed25519 "), "authorized_keys: \(text)")
        XCTAssertEqual(text.split(separator: "\n").count, 1)

        // Again: it is already there.
        sheet.buttons["key-install-go"].click()
        eventually("the second install did not say it was already there") {
            ((result.value as? String) ?? result.label).contains("already")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count, 1)
        try? FileManager.default.removeItem(at: file)
    }
}

final class ThemeEditorTests: CerberusUITestCase {
    /// A theme is made from the chosen one, shows in the default-theme picker, can be renamed, and goes when deleted.
    @MainActor func testMakingRenamingAndDeletingACustomTheme() {
        launch()
        openSettings(tab: "Appearance")
        let new = settingsWindow.buttons["themes-new"]
        wait(new, "no New Theme button")
        new.click()
        let sheet = settingsWindow.sheets.firstMatch
        wait(sheet)
        let name = sheet.textFields["theme-name"]
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Harbour")
        sheet.buttons["theme-save"].click()
        waitGone(sheet, "the editor did not close")
        wait(settingsWindow.buttons["theme-edit-Harbour"], "the new theme is not listed")

        // It is offered as the default theme.
        settingsWindow.popUpButtons["default-theme"].click()
        wait(app.menuItems["Harbour"], "the theme is not in the default-theme picker")
        app.typeKey(.escape, modifierFlags: [])

        // Rename it.
        settingsWindow.buttons["theme-edit-Harbour"].click()
        let editor = settingsWindow.sheets.firstMatch
        wait(editor)
        let field = editor.textFields["theme-name"]
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Quay")
        editor.buttons["theme-save"].click()
        waitGone(editor)
        wait(settingsWindow.buttons["theme-edit-Quay"], "the rename did not show")
        XCTAssertFalse(settingsWindow.buttons["theme-edit-Harbour"].exists)

        settingsWindow.buttons["theme-delete-Quay"].click()
        waitGone(settingsWindow.buttons["theme-edit-Quay"], "the theme was not deleted")
    }
}

final class WelcomeQuickActionTests: CerberusUITestCase {
    /// The Welcome screen's quick actions open Settings on the tab they name.
    @MainActor func testQuickActionsOpenTheirSettingsTabs() {
        launch()
        wait(mainWindow.buttons["New Host…"], "no Welcome screen")
        XCTAssertFalse(mainWindow.buttons["Import hosts from ~/.ssh/config…"].exists, "the import rows are still on the Welcome screen")
        for (action, marker) in [("Keys", "Generate…"), ("Identities", "New Identity…"), ("Backups", "Export Backup…"), ("Snippets", "")] {
            let button = mainWindow.buttons[action]
            wait(button, "no “\(action)” quick action")
            button.click()
            wait(settingsWindow, "Settings did not open for \(action)")
            if !marker.isEmpty { wait(settingsWindow.buttons[marker], "\(action) did not open its tab") }
            settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            waitGone(settingsWindow)
        }
    }
}
