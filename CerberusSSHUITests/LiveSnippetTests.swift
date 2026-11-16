import XCTest

/// The snippet palette (⇧⌘K, spec §9.4), checked by what each remote shell does with what it is sent.
final class LiveSnippetTests: CerberusUITestCase {
    /// Each test writes to files of its own. The scratch folder outlives a test, and the test cannot remove what the
    /// remote shell wrote there (the runner is sandboxed), so a name shared with an earlier test would still hold its lines.
    private let runID = UUID().uuidString
    private var log: URL { server!.scratchDirectory.appendingPathComponent("snippet-\(runID).txt") }

    private func lines(of url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private var palette: XCUIElement { mainWindow.sheets.firstMatch }

    private func openPalette() {
        app.typeKey("k", modifierFlags: [.command, .shift])
        wait(palette.textFields.firstMatch, "the snippet palette did not open")
    }

    @MainActor func testASnippetIsTypedIntoTheFocusedPaneAndAPlaceholderIsAskedFor() throws {
        try startServer()
        try? FileManager.default.removeItem(at: log)
        options.snippets = [
            (title: "Mark pid", body: "echo $$ >> \(log.path)"),
            (title: "Say word", body: "echo word-{{word}} >> \(log.path)"),
        ]
        launchConnected("live-1")
        clickTerminal()

        openPalette()
        palette.textFields.firstMatch.typeText("Mark")
        palette.textFields.firstMatch.typeText("\n")
        eventually("the snippet was never run in the shell") { lines(of: log).count == 1 }
        XCTAssertFalse(palette.exists, "the palette stayed open after sending")

        // A snippet with a placeholder asks first, and sends nothing until it is answered.
        openPalette()
        palette.textFields.firstMatch.typeText("Say")
        palette.textFields.firstMatch.typeText("\n")
        let answer = palette.textFields.element(boundBy: 0)
        wait(answer, "the placeholder form did not appear")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(lines(of: log).count, 1, "the snippet was sent before the placeholder was filled in")
        answer.click()
        answer.typeText("hello\n")
        eventually("the filled-in snippet was not run") { lines(of: log).contains("word-hello") }
    }

    @MainActor func testChoosingPanesSendsOnlyToThosePanes() throws {
        try startServer()
        let left = server!.scratchDirectory.appendingPathComponent("snippet-left-\(runID).pid")
        let right = server!.scratchDirectory.appendingPathComponent("snippet-right-\(runID).pid")
        for url in [log, left, right] { try? FileManager.default.removeItem(at: url) }
        options.snippets = [(title: "Mark pid", body: "echo $$ >> \(log.path)")]
        launchConnected("live-1")

        app.typeKey("d", modifierFlags: .command)
        eventually("the split did not open a second session") { server!.liveSessions() == 2 }
        wait(tab("live-1", panes: 2))

        // Learn which shell is which, then leave the right-hand pane focused.
        terminalPoint(0.2, 0.5).click()
        run("echo $$ > \(left.path)")
        terminalPoint(0.8, 0.5).click()
        run("echo $$ > \(right.path)")
        eventually("the shells did not write their ids") { lines(of: left).count == 1 && lines(of: right).count == 1 }

        // The palette says it sends to the focused pane, until a pane is picked by hand.
        openPalette()
        let target = palette.descendants(matching: .any).matching(identifier: "snippet-target").firstMatch
        wait(target, "the palette does not say where it sends")
        XCTAssertTrue((target.value as? String ?? target.label).contains("focused pane"))
        palette.descendants(matching: .any).matching(identifier: "snippet-choose-panes").firstMatch.click()
        let boxes = app.descendants(matching: .any).matching(identifier: "snippet-pane-live-1")
        eventually("the pane chooser does not list both panes") { boxes.count == 2 }
        boxes.element(boundBy: 0).click()   // the left pane: the list is in layout order
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue((target.value as? String ?? target.label).contains("1 chosen pane"),
                      "the footer did not change to say one pane is chosen")

        palette.textFields.firstMatch.typeText("Mark\n")
        eventually("the chosen pane did not run the snippet") { lines(of: log).count == 1 }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(lines(of: log), lines(of: left), "the snippet went to a pane that was not chosen (or not to the one that was)")
        XCTAssertNotEqual(lines(of: log), lines(of: right))
    }
}
