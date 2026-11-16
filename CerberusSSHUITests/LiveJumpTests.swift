import XCTest

/// A host reached through another (spec §7.5), here the test server through itself.
final class LiveJumpTests: CerberusUITestCase {
    @MainActor func testAHostWithAJumpHostConnectsThroughItAndTypingReachesIt() throws {
        try startServer()
        launch()
        connect("live-jump")
        // Only the final hop opens a shell, so the server sees exactly one session.
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
        wait(mainWindow.buttons["live-jump, Close tab"], "no tab for the host reached through a jump host")

        let marker = server!.scratchDirectory.appendingPathComponent("jump.txt")
        try? FileManager.default.removeItem(at: marker)
        clickTerminal()
        run("echo through-the-jump > \(marker.path)")
        eventually("a command typed into the host behind the jump host never ran") {
            (try? String(contentsOf: marker, encoding: .utf8))?.contains("through-the-jump") == true
        }
    }

    @MainActor func testClosingTheTabClosesTheWholeChain() throws {
        try startServer()
        launchConnected("live-jump")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
        app.typeKey("w", modifierFlags: .command)
        waitGone(mainWindow.buttons["live-jump, Close tab"])
        eventually("the session is still open after its tab was closed") { server!.liveSessions() == 0 }
        wait(hostRow("live-jump"))
        XCTAssertFalse(connectedRow("live-jump").exists)
    }

    @MainActor func testTheJumpHostItselfIsNotLeftConnectedInTheSidebar() throws {
        try startServer()
        launchConnected("live-jump")
        // The hop is part of the connection, not a session of its own.
        XCTAssertFalse(connectedRow("live-1").exists, "the jump host shows as connected as if it had a session")
        XCTAssertEqual(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'")).count, 1, "the hop opened a tab of its own")
    }

    @MainActor func testAHostBehindTwoJumpHostsConnects() throws {
        try startServer()
        launch()
        connect("live-chain")
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
        XCTAssertEqual(mainWindow.buttons.matching(NSPredicate(format: "label ENDSWITH 'Close tab'")).count, 1, "a hop opened a tab of its own")
    }

    /// A host key that has changed on the way to the host, not at the host: the connection is refused, the warning says
    /// whose key it was, and replacing the stored key replaces *that* one (the host asked for was never at fault).
    @MainActor func testAChangedKeyPartwayAlongAChainIsRefusedAndNamesTheHop() throws {
        try startServer()
        options.seed = "live-mismatch-partway"
        launch()
        wait(hostRow("live-chain"))
        hostRow("live-chain").doubleClick()

        wait(mainWindow.staticTexts["Host key mismatch"], "the changed key on the second hop was not reported", timeout: 20)
        let detail = mainWindow.staticTexts["host-key-mismatch-detail"]
        wait(detail, "the warning does not say whose key changed")
        let text = (detail.value as? String) ?? detail.label
        XCTAssertTrue(text.contains("a jump host on the way to live-chain"), "the warning does not say it was a jump host: \(text)")
        XCTAssertEqual(server!.liveSessions(), 0, "a session opened although a hop's key had changed")

        // Replace the stored key: the hop's, then trust the new one, and the chain goes through.
        mainWindow.buttons["Replace stored key…"].click()
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet, "replacing the key was not confirmed")
        sheet.buttons["Replace Key"].click()
        wait(mainWindow.sheets.firstMatch.staticTexts["Trust this host?"], "the new key of the hop was not put to the person", timeout: 20)
        mainWindow.sheets.firstMatch.buttons["Trust and Connect"].click()
        wait(connectedRow("live-chain"), "the chain did not connect once the hop's key was replaced", timeout: 20)
        eventually("the server never saw the session") { server!.liveSessions() == 1 }
    }
}
