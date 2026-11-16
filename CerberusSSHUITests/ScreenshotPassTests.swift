import XCTest

/// Not a test of behaviour: saves a picture of each main screen into a folder, so that a person (or I) can look for
/// clipped text and cramped layouts, which a test of structure cannot see (N10). Run by name when wanted:
/// -only-testing:CerberusSSHUITests/ScreenshotPassTests
final class ScreenshotPassTests: CerberusUITestCase {
    /// Attached to the test result, which is where a sandboxed runner can put a picture (a folder it cannot write to
    /// takes it silently): `xcrun xcresulttool export attachments --path <result>.xcresult --output-path <folder>`.
    private func shot(_ name: String, of element: XCUIElement? = nil) {
        let attachment = XCTAttachment(screenshot: (element ?? app.windows.firstMatch).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testPicturesOfTheMainScreens() throws {
        launch()
        wait(hostRow("web-1"))
        shot("01-welcome-and-sidebar", of: mainWindow)

        // The host editor.
        mainWindow.buttons["New Host…"].click()
        wait(app.sheets.firstMatch)
        shot("02-host-editor", of: app.sheets.firstMatch)
        app.sheets.firstMatch.buttons["Cancel"].click()
        waitGone(app.sheets.firstMatch)

        // Every settings tab.
        openSettings()
        for tab in ["Backup", "Identities", "Keys", "Known Hosts", "Appearance", "Behaviour", "Snippets", "Recordings", "Connection", "Advanced"] {
            let button = settingsTab(tab)
            guard button.exists else { continue }
            button.click()
            Thread.sleep(forTimeInterval: 0.4)
            shot("03-settings-" + tab.replacingOccurrences(of: " ", with: "-").lowercased(), of: settingsWindow)
        }

        // The theme editor and the key sheets.
        settingsTab("Appearance").click()
        settingsWindow.buttons["themes-new"].click()
        wait(settingsWindow.sheets.firstMatch)
        Thread.sleep(forTimeInterval: 0.4)
        shot("04-theme-editor", of: settingsWindow.sheets.firstMatch)
        settingsWindow.sheets.firstMatch.buttons["Cancel"].click()
        waitGone(settingsWindow.sheets.firstMatch)

        settingsTab("Keys").click()
        settingsWindow.buttons["Generate…"].click()
        wait(settingsWindow.sheets.firstMatch)
        shot("05-generate-key", of: settingsWindow.sheets.firstMatch)
        let name = settingsWindow.sheets.firstMatch.textFields["key-generate-name"]
        name.click(); name.typeText("screen-key")
        settingsWindow.sheets.firstMatch.buttons["Generate"].click()
        wait(settingsWindow.sheets.firstMatch.buttons["Done"], timeout: 30)
        settingsWindow.sheets.firstMatch.buttons["Done"].click()
        waitGone(settingsWindow.sheets.firstMatch)
        shot("06-keys-with-a-key", of: settingsWindow)
        settingsWindow.buttons["key-install"].click()
        wait(settingsWindow.sheets.firstMatch)
        Thread.sleep(forTimeInterval: 0.4)
        shot("07-install-key", of: settingsWindow.sheets.firstMatch)
        settingsWindow.sheets.firstMatch.buttons["Cancel"].click()
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

        // A file tab.
        hostRow("web-1").rightClick()
        let items = app.menuItems.matching(identifier: "SFTP")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch)
        Thread.sleep(forTimeInterval: 0.8)
        shot("08-file-tab", of: mainWindow)
    }

    @MainActor func testPicturesOfASplitTerminal() throws {
        try startServer()
        launchConnected("live-1")
        app.typeKey("d", modifierFlags: .command)
        eventually("no second session") { server!.liveSessions() == 2 }
        Thread.sleep(forTimeInterval: 1.0)
        shot("09-split-terminal", of: mainWindow)
    }
}
