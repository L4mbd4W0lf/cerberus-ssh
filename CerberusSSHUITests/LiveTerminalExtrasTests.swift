import XCTest

/// What a person does with a terminal besides typing: ⌘-clicking a link, searching its scrollback, and pasting
/// something that runs more than one line.
final class LiveTerminalExtrasTests: CerberusUITestCase {
    private var terminal: XCUIElement {
        mainWindow.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch
    }
    private var screen: String { terminal.value as? String ?? "" }

    @MainActor func testACommandClickedLinkOpensAndAnotherSchemeDoesNot() throws {
        try startServer()
        launchConnected("live-1")
        clickTerminal()
        let opened = SharedApp.home.appendingPathComponent("command.json.link")
        try? FileManager.default.removeItem(at: opened)

        // Typed, not run: the line stays at the top of the screen after `clear`. It is long, so a click a
        // few dozen cells in is on it whatever the prompt is.
        let url = "https://example.invalid/" + String(repeating: "a", count: 90)
        run("clear")
        eventually("the screen did not clear") { !screen.contains("clear\n") }
        app.typeText(url)
        eventually("the link never reached the screen") { screen.contains("example.invalid") }

        let frame = terminal.frame
        let spot = mainWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX - mainWindow.frame.minX + 8 + 45 * 8, dy: frame.minY - mainWindow.frame.minY + 10))

        // Without ⌘ a click only places the cursor: nothing opens.
        spot.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path), "a plain click opened a link")

        XCUIElement.perform(withKeyModifiers: .command) { spot.click() }
        eventually("⌘-click did not open the link") { FileManager.default.fileExists(atPath: opened.path) }
        let text = (try? String(contentsOf: opened, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.hasPrefix("https://example.invalid/aaaa"), "opened \(text)")
    }

    @MainActor func testAMultiLinePasteAsksFirstAndCancelTypesNothing() throws {
        try startServer()
        launchConnected("live-1")
        clickTerminal()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo PASTE_ONE\necho PASTE_TWO\n", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        let question = app.staticTexts["Paste 2 lines?"]
        wait(question, "a two-line paste did not ask first")
        app.buttons["Cancel"].firstMatch.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(screen.contains("PASTE_ONE"), "cancelling the paste still typed it")

        app.typeKey("v", modifierFlags: .command)
        wait(question, "the second paste did not ask")
        app.buttons["Paste"].firstMatch.click()
        eventually("the confirmed paste never ran") { screen.contains("PASTE_TWO") }
    }

    @MainActor func testTheFindBarSearchesTheScrollbackAndEscapeClosesIt() throws {
        try startServer()
        launchConnected("live-1")
        clickTerminal()
        run("echo SCROLLBACK_NEEDLE")
        run("seq 1 200")   // pushes the needle off the screen
        eventually("the output never finished") { screen.contains("200") }
        XCTAssertFalse(screen.contains("SCROLLBACK_NEEDLE"), "the needle is still on the screen, so this does not test scrollback")

        app.typeKey("f", modifierFlags: .command)
        // Not the toolbar's quick-connect field, which is a search field too.
        let field = mainWindow.searchFields.matching(NSPredicate(format: "identifier != 'quick-connect-field'")).firstMatch
        wait(field, "⌘F did not open a find field")
        field.typeText("SCROLLBACK_NEEDLE\n")
        eventually("the search did not bring the needle into view") { screen.contains("SCROLLBACK_NEEDLE") }

        app.typeKey(.escape, modifierFlags: [])
        eventually("Escape did not close the find field") { !field.exists }
    }
}
