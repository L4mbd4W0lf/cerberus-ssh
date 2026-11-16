import XCTest

/// A port forward started from the sidebar, with no terminal open (spec §7.7), carrying real traffic.
final class LiveForwardTests: CerberusUITestCase {
    @MainActor func testStartingAForwardOpensItsPortAndStoppingClosesIt() throws {
        try startServer()
        launch()
        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Live forward"], "the forward is not listed")
        let port = server!.forwardPort
        XCTAssertNil(UITestSSHD.banner(port: port), "the port was already open")

        let play = sidebar.buttons.matching(NSPredicate(format: "label == 'Start this forward'")).element(boundBy: 1)
        wait(play)
        play.click()

        // The forward leads to the server itself, so connecting to it yields the server's SSH banner.
        let deadline = Date().addingTimeInterval(15)
        var banner: String?
        while Date() < deadline, banner?.hasPrefix("SSH-") != true {
            banner = UITestSSHD.banner(port: port)
            if banner?.hasPrefix("SSH-") != true { Thread.sleep(forTimeInterval: 0.3) }
        }
        XCTAssertEqual(banner?.hasPrefix("SSH-"), true, "the forward did not carry traffic to the server (got \(String(describing: banner)))")
        XCTAssertEqual(server!.liveSessions(), 0, "a forward started without a terminal opened a shell")
        XCTAssertFalse(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'")).firstMatch.exists, "a tab opened")

        // While active the row's button reads "Active", and clicking it stops the forward.
        let active = sidebar.buttons.matching(NSPredicate(format: "label == 'Active'")).firstMatch
        wait(active, "the row does not say Active while the forward runs")
        active.click()
        let closed = Date().addingTimeInterval(15)
        while Date() < closed, UITestSSHD.banner(port: port) != nil { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertNil(UITestSSHD.banner(port: port), "the port stayed open after the forward was stopped")
    }
}
