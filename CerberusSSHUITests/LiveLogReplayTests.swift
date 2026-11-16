import XCTest

/// A recorded session, opened in the replay viewer (spec §10) and searched.
final class LiveLogReplayTests: CerberusUITestCase {
    /// The recording opens in a window of its own.
    private var viewer: XCUIElement { app.windows["Recording"] }
    private var searchField: XCUIElement { viewer.textFields["log-search-field"] }
    private var count: XCUIElement { viewer.staticTexts["log-search-count"] }

    private func search(_ text: String) {
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText(text)
    }

    @MainActor func testALogCanBeSearched() throws {
        try startServer()
        launchConnected("live-1")
        mainWindow.buttons["toolbar-record"].click()
        clickTerminal()

        run("echo LOGMARK_$((0+1))")
        eventually("the terminal never showed the first marker") {
            (mainWindow.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch.value as? String)?
                .contains("LOGMARK_1") == true
        }
        run("echo LOGMARK_$((0+2))")
        eventually("the terminal never showed the second marker") {
            (mainWindow.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Terminal'")).firstMatch.value as? String)?
                .contains("LOGMARK_2") == true
        }
        Thread.sleep(forTimeInterval: 5)   // the log is written in the background

        app.typeKey("l", modifierFlags: [.command, .option])
        wait(searchField, "the replay viewer did not open with a search field", timeout: 15)

        search("LOGMARK_1")
        eventually("the first marker was not found in the log") { (count.value as? String ?? count.label) == "1 of 1" }

        search("LOGMARK_2")
        eventually("the second marker was not found in the log") { (count.value as? String ?? count.label) == "1 of 1" }

        search("no-such-text-anywhere")
        eventually("a search for nothing did not say so") { (count.value as? String ?? count.label) == "No matches" }
    }
}
