import XCTest

/// Where a dragged tab lands when dropped on a tab's terminals: the side nearest the
/// pointer. The terminal's text is not in the accessibility tree, so each test finds out which pane
/// is where by clicking into it and asking its shell for its process id.
final class LiveDropZoneTests: CerberusUITestCase {
    // Fresh names for every test: the test cannot delete what the (unsandboxed) shell wrote in the
    // server's folder, so a name reused by the next test would still hold the last one's lines.
    private let tag = UUID().uuidString.prefix(8)
    private func pidFile(_ host: String) -> URL { server!.scratchDirectory.appendingPathComponent("pid-\(tag)-\(host).txt") }
    private var orderFile: URL { server!.scratchDirectory.appendingPathComponent("order-\(tag).txt") }

    private func read(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Connects both hosts and records each shell's process id, ending with the first tab selected.
    private func setUp2() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))
        for (n, host) in ["live-1", "live-2"].enumerated() {
            try? FileManager.default.removeItem(at: pidFile(host))
            app.typeKey("\(n + 1)", modifierFlags: .command)
            clickTerminal(at: terminalPoint(0.5, 0.5))
            run("echo $$ > \(pidFile(host).path)")
            eventually("could not learn \(host)'s shell") { !read(pidFile(host)).isEmpty }
        }
        try? FileManager.default.removeItem(at: orderFile)
        app.typeKey("1", modifierFlags: .command)
    }

    /// Drops live-2's tab at `drop`, then asks the panes at `first` and `second` who they are.
    private func dropAndAsk(drop: (CGFloat, CGFloat), first: (CGFloat, CGFloat), second: (CGFloat, CGFloat)) -> [String] {
        drag(tab("live-2"), to: terminalPoint(drop.0, drop.1))
        let merged = mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH ', 2, Close tab'"))
        eventually("the tab did not merge as a pane") { merged.count == 1 }
        Thread.sleep(forTimeInterval: 1)
        for point in [first, second] {
            clickTerminal(at: terminalPoint(point.0, point.1))
            run("echo $$ >> \(orderFile.path)")
            Thread.sleep(forTimeInterval: 0.7)
        }
        eventually("the panes did not answer") { read(orderFile).split(separator: "\n").count == 2 }
        let answered = read(orderFile).split(separator: "\n").map(String.init)
        return answered.map { pid in read(pidFile("live-1")) == pid ? "live-1" : read(pidFile("live-2")) == pid ? "live-2" : "?" }
    }

    @MainActor func testDroppingOnTheRightPutsTheTabOnTheRight() throws {
        try setUp2()
        XCTAssertEqual(dropAndAsk(drop: (0.9, 0.5), first: (0.2, 0.5), second: (0.8, 0.5)), ["live-1", "live-2"])
    }

    @MainActor func testDroppingOnTheLeftPutsTheTabOnTheLeft() throws {
        try setUp2()
        XCTAssertEqual(dropAndAsk(drop: (0.1, 0.5), first: (0.2, 0.5), second: (0.8, 0.5)), ["live-2", "live-1"])
    }

    @MainActor func testDroppingAtTheTopPutsTheTabAbove() throws {
        try setUp2()
        XCTAssertEqual(dropAndAsk(drop: (0.5, 0.08), first: (0.5, 0.2), second: (0.5, 0.8)), ["live-2", "live-1"])
    }

    @MainActor func testDroppingAtTheBottomPutsTheTabBelow() throws {
        try setUp2()
        XCTAssertEqual(dropAndAsk(drop: (0.5, 0.92), first: (0.5, 0.2), second: (0.5, 0.8)), ["live-1", "live-2"])
    }

    @MainActor func testClosingAWindowWithSeveralTabsEndsAllTheirSessions() throws {
        try startServer()
        launchConnected("live-1", "live-2", "live-auto")
        eventually("expected three sessions") { server!.liveSessions() == 3 }

        // Move live-2 out into a window of its own, then bring live-auto into that window as well.
        drag(tab("live-2"), to: pointBesideMainWindow())
        eventually("no second window") { workspaceWindows.count == 2 }
        let secondWindow = workspaceWindows.containing(.button, identifier: "live-2, Close tab").firstMatch
        let firstWindow = workspaceWindows.containing(.button, identifier: "live-1, Close tab").firstMatch
        wait(secondWindow); wait(firstWindow)
        drag(firstWindow.buttons["live-auto, Close tab"], to: secondWindow.buttons["live-2, Close tab"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        eventually("the second window does not hold two tabs") {
            secondWindow.buttons["live-2, Close tab"].exists && secondWindow.buttons["live-auto, Close tab"].exists
        }
        XCTAssertEqual(server!.liveSessions(), 3, "moving tabs disturbed a connection")

        secondWindow.buttons[XCUIIdentifierCloseWindow].click()
        eventually("closing the window left some of its sessions open") { server!.liveSessions() == 1 }
        eventually("the window did not close") { workspaceWindows.count == 1 }
        wait(firstWindow.buttons["live-1, Close tab"], "the other window's tab was affected")
    }
}
