import XCTest

/// Not a test of behaviour: takes the pictures the README shows, in light and dark, of the demo catalogue (the
/// `readme` seed: demo hosts, folders and forwards, two hosts that really connect to the test `sshd` and show the
/// address they would have). Each picture is attached to the test result as `readme-<name>-<light|dark>`; a script
/// beside the other test scripts runs this class and copies them into `screenshots/`.
///
/// What the terminals show is typed into them here, in a temporary folder on the server, with a demo prompt, so
/// nothing of the Mac running the tests (its user, its files) is in a picture.
final class ReadmeScreenshotTests: CerberusUITestCase {
    @MainActor func testReadmePicturesLight() throws { try takePictures(appearance: "light") }

    @MainActor func testReadmePicturesDark() throws { try takePictures(appearance: "dark") }

    private var appearance = ""

    private func shot(_ name: String, of element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "readme-\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A host's row. In a coloured folder the row is labelled "web-1, idle, red folder", which `hostRow` (made for the
    /// basic seed, whose folders have no colour) does not match.
    private func row(_ name: String, state: String? = nil) -> XCUIElement {
        let prefix = state.map { "\(name), \($0)" } ?? "\(name),"
        return sidebar.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Lets a view finish animating (a sheet sliding in, a split settling) before its picture is taken.
    private func settle(_ seconds: TimeInterval = 0.6) { Thread.sleep(forTimeInterval: seconds) }

    @MainActor private func takePictures(appearance: String) throws {
        self.appearance = appearance
        try startServer()
        options.seed = "readme"
        options.appearance = appearance
        options.windowSize = (1280, 800)
        // The terminal takes the light or dark version of its theme with the rest of the window.
        options.defaults["terminalThemeFollowsSystem"] = true
        options.connect = ["web-1"]
        launch()
        wait(row("web-1", state: "connected"), "web-1 did not connect", timeout: 20)
        showSidebarTab(.hosts)

        terminals()
        shot("terminal", of: mainWindow)

        showSidebarTab(.forwards)
        settle()
        shot("port-forwards", of: mainWindow)
        showSidebarTab(.hosts)

        quickConnect()
        shot("quick-connect", of: mainWindow)
        app.typeKey(.escape, modifierFlags: [])

        hostEditor()
        shot("host-editor", of: mainWindow)
        app.sheets.firstMatch.buttons["Cancel"].click()
        waitGone(app.sheets.firstMatch)

        fileTab()
        shot("file-tab", of: mainWindow)

        openSettings(tab: "Appearance")
        settle()
        shot("settings-appearance", of: settingsWindow)
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    }

    /// web-1 split in two: a deploy script on the left, a web server's log on the right.
    private func terminals() {
        clickTerminal()
        run(#"cd "$(mktemp -d)" && mkdir app logs && touch docker-compose.yml README.md && printf '#!/bin/sh\nset -e\ngit pull --ff-only\ndocker compose up -d --build\n' > deploy.sh && PS1='deploy@web-1:~/site$ ' && clear"#)
        settle()
        run("ls -F")
        run("cat deploy.sh")

        app.typeKey("d", modifierFlags: .command)
        eventually("no second session") { server!.liveSessions() == 2 }
        settle(1.0)
        clickTerminal(across: 0.85)
        run(#"cd "$(mktemp -d)" && for i in 1 2 3 4 5 6 7 8; do echo "203.0.113.$i - - [17/Nov/2026:09:4$i:12 +0000] \"GET /api/health HTTP/1.1\" 200 17"; done > access.log && PS1='deploy@web-1:/var/log/nginx$ ' && clear"#)
        settle()
        run("tail access.log")
        settle(1.0)
    }

    /// ⌘K with "db" typed: the matches drop down.
    private func quickConnect() {
        app.typeKey("k", modifierFlags: .command)
        app.typeText("db")
        wait(app.descendants(matching: .any).matching(identifier: "quick-connect-row-db-1").firstMatch)
        settle()
    }

    private func hostEditor() {
        wait(row("db-1"))
        row("db-1").rightClick()
        let items = app.menuItems.matching(identifier: "Edit…")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(app.sheets.firstMatch, "the host editor did not open")
        settle()
    }

    /// A file tab on web-2: a website's folder on this Mac on one side, the server's on the other. The `readme` seed
    /// made both under a path that names nobody; This Mac's pane starts in the test home, so it is sent there.
    private func fileTab() {
        row("web-2").rightClick()
        let items = app.menuItems.matching(identifier: "SFTP")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        let local = app.descendants(matching: .any).matching(identifier: "files-pane-left").firstMatch
        wait(app.descendants(matching: .any).matching(identifier: "files-pane-right").firstMatch)
        let path = app.descendants(matching: .any).matching(identifier: "files-path-left").firstMatch
        wait(path)
        path.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("/tmp/cerberus-demo/Projects/website\n")
        wait(local.staticTexts["index.html"], "This Mac's pane did not go to the demo website")
        local.staticTexts["index.html"].click()   // the keyboard leaves the path field, as after real use
        settle(0.8)
    }
}
