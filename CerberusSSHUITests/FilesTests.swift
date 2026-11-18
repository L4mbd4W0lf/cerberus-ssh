import XCTest

/// The file tab (spec §9.6): two panes, copies between them, and the clashes a copy meets.
///
/// The SFTP channel is not wired to SSH yet, so in test mode a host's pane shows a folder of its
/// own under the test home (`UITesting.fileHostRoot`). These tests therefore cover the browser and
/// the copy engine through the real window; they do not cover SFTP itself.
final class FilesTests: CerberusUITestCase {
    private let fm = FileManager.default

    /// The folder standing in for host `name`: it is also where that host's pane starts.
    private func hostFolder(_ name: String) -> String {
        let path = testHome.appendingPathComponent("uitest-hosts/\(name)").path
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Names are unique per test, because This Mac's pane starts in the test home, which is shared.
    private func unique(_ stem: String) -> String { "\(stem)-\(UUID().uuidString.prefix(6))" }

    private func put(_ text: String, at path: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func pane(_ side: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "files-pane-\(side)").firstMatch
    }

    private func row(_ name: String, in side: String) -> XCUIElement { pane(side).staticTexts[name] }

    /// The item of the open (context) menu with this title. The menu bar has items of the same names (the Host and
    /// Tab menus), so a plain lookup by title finds several.
    private func openMenuItem(_ title: String) -> XCUIElement {
        let items = app.menuItems.matching(identifier: title)
        wait(items.firstMatch, "no “\(title)” in the open menu")
        return items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch
    }

    /// ⌘↓ as a keyboard makes it. `typeKey` leaves out the numeric-pad and function flags that every real arrow key
    /// carries, which hid a bug: a chord compared as exactly ⌘ never matched.
    private func pressCommandDown() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 125, keyDown: isDown)
            event?.flags = [.maskCommand, .maskNumericPad, .maskSecondaryFn]
            if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cerberusssh.uitest").first?.processIdentifier {
                event?.postToPid(pid)
            } else {
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func openFiles(for host: String) {
        hostRow(host).rightClick()
        // The menu bar's Session and Host menus have an SFTP item too: the one to click is the one that is open.
        let items = app.menuItems.matching(identifier: "SFTP")
        wait(items.firstMatch, "no SFTP in the host's menu")
        let item = items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch
        item.click()
        wait(pane("right"), "the file tab did not open")
    }

    /// Copies the row to the other pane through its context menu (a drag is tested once, by itself:
    /// it costs far more time and is the less reliable way to drive a window).
    private func copy(_ name: String, from side: String) {
        row(name, in: side).rightClick()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Copy to'")).firstMatch
        wait(item, "no Copy to… in the row's menu")
        item.click()
    }

    private func waitForTransfer(_ title: String, _ outcome: String = "copied") {
        let transfer = app.descendants(matching: .any).matching(identifier: "files-transfer-\(title)").firstMatch
        // The list is in a panel that rises from the status bar's badge: clicking the badge keeps it open.
        let badge = app.descendants(matching: .any).matching(identifier: "files-transfers-badge").firstMatch
        wait(badge, "no transfers badge in the status bar")
        if !transfer.exists { badge.click() }
        wait(transfer, "no transfer called \(title) appeared")
        let done = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", outcome, outcome)
        let expectation = XCTNSPredicateExpectation(predicate: done, object: transfer)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 15), .completed, "the transfer of \(title) never reported “\(outcome)”")
    }

    @MainActor func testOneHostPutsThisMacOnTheLeftAndTheHostOnTheRight() {
        let name = unique("here")
        let theirs = unique("there")
        put("a", at: testHome.appendingPathComponent(name).path)
        put("b", at: hostFolder("web-1") + "/\(theirs)")
        launch()
        openFiles(for: "web-1")

        wait(row(name, in: "left"), "This Mac's pane does not list its file")
        wait(row(theirs, in: "right"), "the host's pane does not list its file")
        // Each pane starts in its own place: This Mac in the test home, the host in its own folder.
        eventually("the right pane did not open the host's folder") { (self.app.textFields["files-path-right"].value as? String) == self.hostFolder("web-1") }
        XCTAssertTrue((app.textFields["files-path-left"].value as? String)?.contains("cerberus-uitest") == true, "the left pane is not This Mac's test home")
        XCTAssertFalse(row(theirs, in: "left").exists, "a file of the host showed in This Mac's pane")
    }

    /// A click on the path field leaves the keyboard there, in the focused pane and in the other one: a click in a pane
    /// gives its list the keyboard, which used to take it straight back from the field, so a typed path went to the list.
    @MainActor func testATypedPathIsGoneTo() {
        let mine = unique("typed-here")
        let theirs = unique("typed-there")
        put("a", at: testHome.appendingPathComponent("\(mine)/inside-mine").path)
        put("b", at: hostFolder("web-1") + "/\(theirs)/inside-theirs")
        launch()
        openFiles(for: "web-1")

        for (side, folder, file) in [("left", testHome.appendingPathComponent(mine).path, "inside-mine"),
                                     ("right", hostFolder("web-1") + "/\(theirs)", "inside-theirs")] {
            let field = app.textFields["files-path-\(side)"]
            wait(field)
            field.click()
            XCTAssertTrue((field.value(forKey: "hasKeyboardFocus") as? Bool) == true, "the \(side) path field lost the keyboard after a click")
            app.typeKey("a", modifierFlags: .command)
            app.typeText(folder + "\n")
            wait(row(file, in: side), "the \(side) pane did not go to the typed path")
        }
    }

    @MainActor func testCopyToTheHostAndBack() {
        let up = unique("up") + ".txt"
        let down = unique("down") + ".txt"
        put("going up", at: testHome.appendingPathComponent(up).path)
        put("coming down", at: hostFolder("web-1") + "/\(down)")
        launch()
        openFiles(for: "web-1")

        wait(row(up, in: "left"))
        copy(up, from: "left")
        waitForTransfer(up)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(up)", encoding: .utf8), "going up")
        wait(row(up, in: "right"), "the host's pane was not refreshed after the copy")

        copy(down, from: "right")
        waitForTransfer(down)
        XCTAssertEqual(try? String(contentsOfFile: testHome.appendingPathComponent(down).path, encoding: .utf8), "coming down")
    }

    @MainActor func testAFolderIsCopiedWithEverythingInIt() {
        let folder = unique("tree")
        put("1", at: testHome.appendingPathComponent("\(folder)/a.txt").path)
        put("2", at: testHome.appendingPathComponent("\(folder)/inner/b.txt").path)
        launch()
        openFiles(for: "web-1")

        copy(folder, from: "left")
        waitForTransfer(folder)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(folder)/a.txt", encoding: .utf8), "1")
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(folder)/inner/b.txt", encoding: .utf8), "2")
    }

    @MainActor func testANameClashAsksAndKeepBothKeepsTheOldFile() {
        let name = unique("clash") + ".txt"
        put("new", at: testHome.appendingPathComponent(name).path)
        put("old", at: hostFolder("web-1") + "/\(name)")
        launch()
        openFiles(for: "web-1")

        copy(name, from: "left")
        let keep = app.buttons["files-conflict-keep"]
        wait(keep, "no question about the name that is already there")
        keep.click()
        waitForTransfer(name)

        let copyName = (name as NSString).deletingPathExtension + " (copy).txt"
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "old", "the old file was changed")
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(copyName)", encoding: .utf8), "new", "no copy was kept")
    }

    @MainActor func testReplaceOverwritesAndCancelLeavesTheFileAlone() {
        let name = unique("rep") + ".txt"
        put("new", at: testHome.appendingPathComponent(name).path)
        put("old", at: hostFolder("web-1") + "/\(name)")
        launch()
        openFiles(for: "web-1")

        copy(name, from: "left")
        wait(app.buttons["files-conflict-cancel"])
        app.buttons["files-conflict-cancel"].click()
        waitForTransfer(name, "cancelled")
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "old")

        copy(name, from: "left")
        wait(app.buttons["files-conflict-replace"])
        app.buttons["files-conflict-replace"].click()
        eventually("the file was not replaced") { (try? String(contentsOfFile: self.hostFolder("web-1") + "/\(name)", encoding: .utf8)) == "new" }
    }

    @MainActor func testTwoHostsCopyFromOneToTheOther() {
        let name = unique("between") + ".txt"
        put("hop", at: hostFolder("web-1") + "/\(name)")
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        XCUIElement.perform(withKeyModifiers: .command) { self.hostRow("web-2").click() }
        hostRow("web-2").rightClick()
        let item = app.menuItems["SFTP 2"]
        wait(item, "no SFTP 2 item with two hosts selected")
        item.click()
        wait(pane("left"))

        copy(name, from: "left")
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-2") + "/\(name)", encoding: .utf8), "hop")
        XCTAssertTrue(fm.fileExists(atPath: hostFolder("web-1") + "/\(name)"), "a copy removed the original")
    }

    @MainActor func testNewFolderRenameAndDelete() {
        let made = unique("made")
        let renamed = unique("renamed")
        launch()
        openFiles(for: "web-1")
        wait(pane("right"))

        pane("right").rightClick()
        // The list's context menu; the File menu has a New Folder… item of its own (for the sidebar).
        let new = pane("right").menuItems["New Folder…"]
        wait(new); new.click()
        let field = app.textFields["files-name-field"]
        wait(field); field.click(); field.typeText(made); app.buttons["files-name-confirm"].click()
        wait(row(made, in: "right"), "the new folder is not listed")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: hostFolder("web-1") + "/\(made)", isDirectory: &isDir) && isDir.boolValue)

        row(made, in: "right").rightClick()
        openMenuItem("Rename…").click()
        let rename = app.textFields["files-name-field"]
        wait(rename); rename.click(); rename.typeKey("a", modifierFlags: .command); rename.typeText(renamed)
        app.buttons["files-name-confirm"].click()
        wait(row(renamed, in: "right"), "the folder was not renamed")
        XCTAssertFalse(fm.fileExists(atPath: hostFolder("web-1") + "/\(made)"))

        row(renamed, in: "right").rightClick()
        openMenuItem("Delete…").click()
        let confirm = app.buttons["files-confirm-delete"]
        wait(confirm); confirm.click()
        waitGone(row(renamed, in: "right"), "the deleted folder is still listed")
        XCTAssertFalse(fm.fileExists(atPath: hostFolder("web-1") + "/\(renamed)"))
    }

    @MainActor func testAStoppedCopyIsOfferedForResuming() {
        let name = unique("resume") + ".bin"
        let bytes = [UInt8](repeating: 0x41, count: 400_000)
        try? Data(bytes).write(to: testHome.appendingPathComponent(name))
        // What an earlier, interrupted copy left behind: the first 300,000 bytes, with one in the middle marked 0xEE (the
        // engine compares only the two ends of what is there, so the mark shows whether it carried on or copied again).
        var partial = [UInt8](repeating: 0x41, count: 300_000); partial[150_000] = 0xEE
        try? Data(partial).write(to: URL(fileURLWithPath: hostFolder("web-1") + "/\(name).cerberus-part"))
        launch()
        openFiles(for: "web-1")

        copy(name, from: "left")
        let resume = app.buttons["files-conflict-resume"]
        wait(resume, "no offer to resume the partial copy")
        XCTAssertTrue(app.buttons["files-conflict-restart"].exists)
        resume.click()
        waitForTransfer(name)

        let result = fm.contents(atPath: hostFolder("web-1") + "/\(name)") ?? Data()
        XCTAssertEqual(result.count, 400_000)
        XCTAssertEqual(result[150_000], 0xEE, "the part already there was copied again")
        XCTAssertFalse(fm.fileExists(atPath: hostFolder("web-1") + "/\(name).cerberus-part"), "the partial file was left behind")
    }

    @MainActor func testDraggingAFileFromOnePaneToTheOtherCopiesIt() {
        let name = unique("dragged") + ".txt"
        put("dragged", at: testHome.appendingPathComponent(name).path)
        launch()
        openFiles(for: "web-1")

        wait(row(name, in: "left"))
        let target = pane("right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        drag(row(name, in: "left"), to: target)
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "dragged")
    }

    @MainActor func testDraggingStillWorksWhenATerminalTabWasOpenedFirst() throws {
        // Launch, open a host (a terminal tab stays alive behind the file tab), open SFTP: dragging must work.
        let name = unique("after-terminal") + ".txt"
        put("dragged", at: testHome.appendingPathComponent(name).path)
        try startServer()
        launchConnected("live-1")
        openFiles(for: "web-1")

        wait(row(name, in: "left"))
        let target = pane("right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        drag(row(name, in: "left"), to: target)
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "dragged")
    }

    @MainActor func testCopyAndPasteInThePaneAndAcrossPanesWithTheFocusMovedByKeys() {
        let name = unique("clip") + ".txt"
        put("clip", at: testHome.appendingPathComponent(name).path)
        launch()
        openFiles(for: "web-1")

        // Copy in the left pane, paste in the same pane: Finder-style, the new file is "… (copy)".
        wait(row(name, in: "left"))
        row(name, in: "left").click()
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        let stem = (name as NSString).deletingPathExtension
        wait(pane("left").staticTexts["\(stem) (copy).txt"], "pasting in the same pane did not make a copy")

        // Move the focus to the other pane with the pane keys and paste there: it lands in the host's folder.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        app.typeKey("v", modifierFlags: .command)
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "clip")
    }

    @MainActor func testMovingFromTheMenuAndWithOptionCommandVTakesTheFileAway() {
        let viaMenu = unique("mv-menu") + ".txt", viaKeys = unique("mv-keys") + ".txt"
        put("one", at: testHome.appendingPathComponent(viaMenu).path)
        put("two", at: testHome.appendingPathComponent(viaKeys).path)
        launch()
        openFiles(for: "web-1")

        // Move to the other pane, from the row's menu.
        wait(row(viaMenu, in: "left"))
        row(viaMenu, in: "left").rightClick()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Move to'")).firstMatch
        wait(item, "no Move to… in the row's menu")
        item.click()
        waitForTransfer(viaMenu, "moved")
        wait(row(viaMenu, in: "right"), "the moved file is not in the other pane")
        waitGone(row(viaMenu, in: "left"), "the file is still in the pane it was moved from")
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(viaMenu)", encoding: .utf8), "one")
        XCTAssertFalse(fm.fileExists(atPath: testHome.appendingPathComponent(viaMenu).path))

        // Copy, then paste as a move in the other pane (⌥⌘V).
        row(viaKeys, in: "left").click()
        app.typeKey("c", modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        app.typeKey("v", modifierFlags: [.command, .option])
        waitForTransfer(viaKeys, "moved")
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(viaKeys)", encoding: .utf8), "two")
        XCTAssertFalse(fm.fileExists(atPath: testHome.appendingPathComponent(viaKeys).path), "⌥⌘V copied instead of moving")
    }

    /// A server file opened for editing: the edit shows above the status bar, a save of the local copy is sent back,
    /// and stopping removes the copy. (Under UI testing no app is opened; the test is the editor.)
    @MainActor func testEditingAServerFileSendsEachSaveBack() throws {
        let name = unique("edit") + ".txt"
        let remote = hostFolder("web-1") + "/\(name)"
        put("before", at: remote)
        launch()
        openFiles(for: "web-1")
        wait(row(name, in: "right"))
        row(name, in: "right").rightClick()
        openMenuItem("Edit in Default App").click()

        let strip = app.descendants(matching: .any).matching(identifier: "files-edit-\(name)").firstMatch
        wait(strip, "no edit appeared above the status bar")

        // The editor's copy is in the temporary folder.
        let temp = testHome
        var local: URL?
        eventually("the local copy was not made") {
            let folders = (try? self.fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
            local = folders.filter { $0.lastPathComponent.hasPrefix("cerberus-edit-") }
                .map { $0.appendingPathComponent(name) }.first { self.fm.fileExists(atPath: $0.path) }
            return local != nil
        }
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(local), encoding: .utf8), "before")
        try "after".write(to: try XCTUnwrap(local), atomically: true, encoding: .utf8)
        eventually("the save was not sent back") { (try? String(contentsOfFile: remote, encoding: .utf8)) == "after" }

        app.buttons["files-edit-stop"].click()
        waitGone(strip, "the edit is still listed after Stop Editing")
        eventually("the local copy was not removed") { !self.fm.fileExists(atPath: try! XCTUnwrap(local).path) }
    }

    @MainActor func testALinkIsCopiedAsALink() throws {
        let target = unique("lnk-target") + ".txt", link = unique("lnk")
        put("t", at: testHome.appendingPathComponent(target).path)
        try fm.createSymbolicLink(atPath: testHome.appendingPathComponent(link).path, withDestinationPath: target)
        launch()
        openFiles(for: "web-1")
        wait(row(link, in: "left"))
        copy(link, from: "left")
        waitForTransfer(link, "link")
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: hostFolder("web-1") + "/\(link)"), target)
    }

    @MainActor func testFinderStyleKeysNewFolderRenameDeleteRefreshAndOpen() throws {
        // ⌘↓ is sent as a real keyboard event (see `pressCommandDown`), which macOS drops unless the test runner may post
        // events (System Settings ▸ Privacy & Security ▸ Accessibility). Without that, the key never reaches the app.
        try XCTSkipUnless(CGPreflightPostEventAccess(), "the test runner is not allowed to post keyboard events")
        let made = unique("keys")
        let renamed = unique("keyed")
        let inside = unique("inside") + ".txt"
        launch()
        openFiles(for: "web-1")
        wait(pane("right"))
        pane("right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()   // focus the right pane

        // ⇧⌘N: a new folder.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields["files-name-field"]
        wait(field, "⇧⌘N did not ask for a folder name")
        field.typeText(made); app.buttons["files-name-confirm"].click()
        wait(row(made, in: "right"), "the new folder is not listed")

        // ⌥⌘R: rename the selected row.
        row(made, in: "right").click()
        app.typeKey("r", modifierFlags: [.command, .option])
        let rename = app.textFields["files-name-field"]
        wait(rename, "⌥⌘R did not offer a new name")
        rename.typeKey("a", modifierFlags: .command); rename.typeText(renamed)
        app.buttons["files-name-confirm"].click()
        wait(row(renamed, in: "right"), "the folder was not renamed")

        // ⌘R: refresh picks up a file made behind the app's back; ⌘↓ opens the folder and shows it.
        put("x", at: hostFolder("web-1") + "/\(renamed)/\(inside)")
        row(renamed, in: "right").click()
        app.typeKey("r", modifierFlags: .command)
        pressCommandDown()
        wait(row(inside, in: "right"), "⌘↓ did not open the folder")

        // ⌘⌫ on the file: asks first, then deletes it.
        row(inside, in: "right").click()
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = app.buttons["files-confirm-delete"]
        wait(confirm, "⌘⌫ did not ask before deleting"); confirm.click()
        waitGone(row(inside, in: "right"), "the deleted file is still listed")
    }

    @MainActor func testDraggingOntoAFolderThatAlreadyHasFilesCopiesIt() {
        // A table swallowed drops when it had rows, so this is the case that matters: files on both sides.
        let name = unique("dragged-onto") + ".txt"
        put("dragged", at: testHome.appendingPathComponent(name).path)
        for n in 1...4 { put("there", at: hostFolder("web-1") + "/" + unique("already-\(n)")) }
        launch()
        openFiles(for: "web-1")

        wait(row(name, in: "left"))
        let target = pane("right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag(row(name, in: "left"), to: target)
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(name)", encoding: .utf8), "dragged")
    }

    @MainActor func testDraggingSeveralSelectedFilesCopiesThemAll() {
        let names = (1...3).map { unique("multi-\($0)") + ".txt" }
        for name in names { put("body", at: testHome.appendingPathComponent(name).path) }
        launch()
        openFiles(for: "web-1")

        for name in names { wait(row(name, in: "left")) }
        row(names[0], in: "left").click()
        XCUIElement.perform(withKeyModifiers: .command) {
            self.row(names[1], in: "left").click()
            self.row(names[2], in: "left").click()
        }
        let target = pane("right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag(row(names[2], in: "left"), to: target)
        eventually("not every file arrived on the host") {
            names.allSatisfy { self.fm.fileExists(atPath: self.hostFolder("web-1") + "/\($0)") }
        }
    }

    @MainActor func testDraggingOntoAFolderInTheSamePaneMovesItThereAndDotDotMovesItBack() {
        let name = unique("into-folder") + ".txt", folder = unique("target")
        put("moved", at: testHome.appendingPathComponent(name).path)
        try? fm.createDirectory(atPath: testHome.appendingPathComponent(folder).path, withIntermediateDirectories: true)
        launch()
        openFiles(for: "web-1")

        // Within one place a drop on a folder is a move, done by renaming.
        wait(row(name, in: "left")); wait(row(folder, in: "left"))
        drag(row(name, in: "left"), to: row(folder, in: "left").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        waitForTransfer(name, "moved")
        waitGone(row(name, in: "left"), "the file is still in the folder it was moved from")
        XCTAssertEqual(try? String(contentsOfFile: testHome.appendingPathComponent("\(folder)/\(name)").path, encoding: .utf8), "moved")

        // Into the folder, then onto "..": back where it started.
        row(folder, in: "left").doubleClick()
        wait(row(name, in: "left"), "the folder did not open")
        drag(row(name, in: "left"), to: row("..", in: "left").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        eventually("the file was not moved up onto ..") {
            self.fm.fileExists(atPath: self.testHome.appendingPathComponent(name).path)
                && !self.fm.fileExists(atPath: self.testHome.appendingPathComponent("\(folder)/\(name)").path)
        }
    }

    @MainActor func testDraggingOntoAFolderInTheOtherPaneCopiesItIntoThatFolder() {
        let name = unique("onto-remote-folder") + ".txt", folder = unique("remote-target")
        put("copied", at: testHome.appendingPathComponent(name).path)
        try? fm.createDirectory(atPath: hostFolder("web-1") + "/\(folder)", withIntermediateDirectories: true)
        launch()
        openFiles(for: "web-1")

        wait(row(name, in: "left")); wait(row(folder, in: "right"))
        drag(row(name, in: "left"), to: row(folder, in: "right").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        waitForTransfer(name)
        XCTAssertEqual(try? String(contentsOfFile: hostFolder("web-1") + "/\(folder)/\(name)", encoding: .utf8), "copied")
        XCTAssertFalse(fm.fileExists(atPath: hostFolder("web-1") + "/\(name)"), "it went to the pane's folder, not the one it was let go on")
        XCTAssertTrue(fm.fileExists(atPath: testHome.appendingPathComponent(name).path), "a drop between places moved instead of copying")
    }

    /// A large copy reports progress many times a second; the app must stay responsive through it. The
    /// check is by the app's own main-thread stall log (`HangWatchdog`), read after the run.
    @MainActor func testALargeCopyKeepsTheAppResponsive() {
        let name = unique("large") + ".bin"
        let path = testHome.appendingPathComponent(name).path
        fm.createFile(atPath: path, contents: nil)
        if let handle = FileHandle(forWritingAtPath: path) {
            let block = Data(repeating: 0x5A, count: 1024 * 1024)
            for _ in 0..<400 { handle.write(block) }
            try? handle.close()
        }
        launch()
        openFiles(for: "web-1")
        wait(row(name, in: "left"))
        copy(name, from: "left")
        waitForTransfer(name)
        // The window must still answer a click straight after.
        XCTAssertTrue(row(name, in: "right").waitForExistence(timeout: 10))
        try? fm.removeItem(atPath: path)
    }

    @MainActor func testTheDotDotRowGoesUpAFolderInAListingAndInAnEmptyFolder() {
        // The host's folder holds one file, so its listing is a table; the folder inside it is empty.
        let inner = hostFolder("web-1") + "/inner-" + UUID().uuidString.prefix(6)
        try? fm.createDirectory(atPath: inner, withIntermediateDirectories: true)
        put("x", at: hostFolder("web-1") + "/" + unique("file"))
        launch()
        openFiles(for: "web-1")

        let path = app.textFields["files-path-right"]
        wait(path)
        wait(row("..", in: "right"), "no .. row at the top of the listing")
        row((inner as NSString).lastPathComponent, in: "right").doubleClick()
        eventually("the folder did not open") { (path.value as? String) == inner }

        wait(row("..", in: "right"), "no .. row in an empty folder")
        row("..", in: "right").doubleClick()
        eventually("the .. row did not go up") { (path.value as? String) == self.hostFolder("web-1") }
        row("..", in: "right").doubleClick()
        eventually("the .. row in a listing did not go up") { (path.value as? String) == (self.hostFolder("web-1") as NSString).deletingLastPathComponent }
    }

    @MainActor func testThePaneSourcePickerSearchesHostsAndOffersThisMac() {
        launch()
        openFiles(for: "web-1")
        let right = app.descendants(matching: .any).matching(identifier: "files-source-right").firstMatch
        wait(right)
        right.click()
        let search = app.textFields["Search by name, address, folder or #tag"]
        wait(search, "the host picker did not open")
        XCTAssertTrue(app.buttons["files-source-this-mac"].exists, "no This Mac choice in the picker")
        search.typeText("web-2")
        search.typeKey(.return, modifierFlags: [])
        eventually("the pane did not switch to web-2") { (self.app.textFields["files-path-right"].value as? String) == self.hostFolder("web-2") }

        let left = app.descendants(matching: .any).matching(identifier: "files-source-left").firstMatch
        left.click()
        wait(app.buttons["files-source-this-mac"])
        app.buttons["files-source-this-mac"].click()
        eventually("the pane did not return to This Mac") { (self.app.textFields["files-path-left"].value as? String)?.contains("cerberus-uitest") == true }
    }

    @MainActor func testTheStatusBarShowsEachPaneAndTheTransfersBadge() {
        let name = unique("bar") + ".txt"
        put("x", at: testHome.appendingPathComponent(name).path)
        launch()
        openFiles(for: "web-1")
        let bar = app.descendants(matching: .any).matching(identifier: "files-status-bar").firstMatch
        wait(bar, "no status bar under the file tab")
        // Each pane's status is one combined element, so look for the host's name in any element's text.
        let named = bar.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'web-1' OR value CONTAINS 'web-1'")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 5), "the status bar does not name the host pane")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "files-transfers-badge").firstMatch.exists, "a transfers badge before any transfer")
        copy(name, from: "left")
        waitForTransfer(name)
    }

    @MainActor func testClosingTheTabClosesIt() {
        launch()
        openFiles(for: "web-1")
        // The tab's close button is folded into the tab's own accessibility element, so use its menu.
        let tab = mainWindow.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Files:' OR value BEGINSWITH 'Files:'")).firstMatch
        wait(tab, "no file tab in the tab bar")
        tab.rightClick()
        let close = app.menuItems["Close Tab"]
        wait(close)
        close.click()
        waitGone(pane("right"), "the file tab did not close")
    }
}
