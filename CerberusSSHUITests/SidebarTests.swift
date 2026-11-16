import XCTest
import AppKit

final class SidebarTests: CerberusUITestCase {
    private var filter: XCUIElement { mainWindow.textFields["sidebar-filter"] }
    private var addMenu: XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "sidebar-add").firstMatch
    }

    private func outlineRow(containing text: XCUIElement) -> XCUIElement {
        // By `value`: that is where a row's text is (its `label` is empty), and what `hostRow` matches on.
        let shown = text.value as? String ?? ""
        return sidebar.descendants(matching: .outlineRow).containing(NSPredicate(format: "value == %@", shown)).firstMatch
    }

    private func chooseContextItem(_ title: String) {
        let items = app.menuItems.matching(identifier: title)
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
    }

    @MainActor func testNavigatorTabSpacing() {
        launch()
        wait(folderRow("Production"))
        let bar = mainWindow.descendants(matching: .any).matching(identifier: "sidebar-tab-bar").firstMatch
        wait(bar)
        let tabs = ["hosts", "forwards", "favourites"].map { mainWindow.buttons["sidebar-tab-\($0)"] }
        for tab in tabs { wait(tab) }
        let frames = tabs.map(\.frame)

        XCTAssertEqual(bar.frame.height, 28, accuracy: 0.5)
        for frame in frames {
            XCTAssertEqual(frame.width, 32, accuracy: 0.5)
            XCTAssertEqual(frame.height, 26, accuracy: 0.5)
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 0.5)
            XCTAssertEqual(frame.minY - bar.frame.minY, 1, accuracy: 0.5)
            XCTAssertEqual(bar.frame.maxY - frame.maxY, 1, accuracy: 0.5)
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(next.minX - previous.maxX, 2, accuracy: 0.5)
        }
        XCTAssertEqual(bar.frame.minX - mainWindow.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(frames[0].minX - bar.frame.minX, 1, accuracy: 0.5)
        XCTAssertEqual(sidebar.frame.maxX - bar.frame.maxX, 8, accuracy: 1)
        XCTAssertGreaterThanOrEqual(folderRow("Production").frame.minY - frames[0].maxY, 11)

        let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
        attachment.name = "sidebar-navigator-spacing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testNavigatorIconsDimWhenTheAppIsInactive() throws {
        launch()
        let selected = mainWindow.buttons["sidebar-tab-hosts"]
        wait(selected)
        // Both pictures are of the screen at this spot, not of the element: once the app is in the background its
        // window can drop out of the accessibility tree between a check and a screenshot ("Window does not exist").
        XCTAssertTrue(selected.isEnabled)
        XCTAssertTrue(selected.isSelected)
        let iconFrame = selected.frame
        let activeContrast = try iconContrast(onScreenAt: iconFrame)

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        defer { app.activate() }
        eventually("the app did not become inactive") { self.app.state == .runningBackground }
        Thread.sleep(forTimeInterval: 0.5)  // let the window finish redrawing as inactive

        XCTAssertLessThan(try iconContrast(onScreenAt: iconFrame), activeContrast * 0.8)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "sidebar-navigator-inactive"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Sample the icon and its flat highlight, excluding the glass rim, in the part of the screen the icon is at.
    private func iconContrast(onScreenAt frame: CGRect) throws -> CGFloat {
        let screenshot = XCUIScreen.main.screenshot()
        let whole = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let scale = CGFloat(whole.pixelsWide) / screenshot.image.size.width
        let area = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        let image = try XCTUnwrap(whole.cgImage?.cropping(to: area).map(NSBitmapImageRep.init(cgImage:)))
        var darkest: CGFloat = 1
        var lightest: CGFloat = 0
        for y in (image.pixelsHigh / 4)..<(image.pixelsHigh * 3 / 4) {
            for x in (image.pixelsWide / 4)..<(image.pixelsWide * 3 / 4) {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                darkest = min(darkest, brightness)
                lightest = max(lightest, brightness)
            }
        }
        return lightest - darkest
    }

    @MainActor func testSeededHostsFoldersAndForwardsAreListed() {
        launch()
        for host in ["web-1", "web-2", "db-1"] { wait(hostRow(host), "no row for \(host)") }
        for group in ["Production", "EU", "Staging"] { wait(folderRow(group), "no row for \(group)") }
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-hosts"].isSelected, "with no favourites, Hosts should be the default")
        XCTAssertFalse(sidebar.staticTexts["Staging database"].exists)
        XCTAssertFalse(mainWindow.toolbars.descendants(matching: .any).matching(identifier: "Add").firstMatch.exists)
        wait(addMenu)
        wait(filter)

        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Staging database"], "the port forward is not listed")
        XCTAssertFalse(hostRow("db-1").exists)
        XCTAssertFalse(folderRow("Production").exists)
        waitGone(filter)
        waitGone(addMenu)

        showSidebarTab(.favourites)
        wait(mainWindow.staticTexts["No Favourites"])
        waitGone(filter)
        waitGone(addMenu)

        showSidebarTab(.hosts)
        wait(filter)
        wait(addMenu)
    }

    @MainActor func testWelcomeIsShownWhileNothingIsOpen() {
        launch()
        wait(mainWindow.buttons["New Host…"])
        XCTAssertTrue(mainWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Welcome'")).firstMatch.exists)
    }

    @MainActor func testSearchNarrowsTheListAndClearingRestoresIt() {
        launch()
        wait(hostRow("db-1"))
        let search = filter
        wait(search)
        search.click()
        search.typeText("web")
        wait(hostRow("web-1"))
        wait(hostRow("web-2"))
        waitGone(hostRow("db-1"), "a search for 'web' still shows db-1")

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        wait(hostRow("db-1"), "clearing the search did not bring db-1 back")
    }

    @MainActor func testACollapsedFolderHidesItsHostsAndExpandingShowsThemAgain() {
        launch()
        wait(hostRow("web-1"))
        let production = sidebar.disclosureTriangles.element(boundBy: 0)
        production.click()
        waitGone(hostRow("web-1"), "collapsing Production left web-1 showing")
        waitGone(hostRow("web-2"), "collapsing Production left the EU folder's host showing")
        wait(hostRow("db-1"), "collapsing Production hid an unrelated host")

        production.click()
        wait(hostRow("web-1"), "expanding Production did not show web-1")
    }

    @MainActor func testDuplicateMakesACopyNamedAsSuch() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").rightClick()
        // (The Host menu in the menu bar has a Duplicate too: the one to press is the open context menu's.)
        chooseContextItem("Duplicate")
        wait(hostRow("web-1 copy"), "no copy appeared")
        wait(hostRow("web-1"), "the original went missing")
    }

    @MainActor func testAddingAndRemovingAFavouriteKeepsTheTabAndShowsNoFolder() {
        launch()
        wait(hostRow("web-2"))
        hostRow("web-2").rightClick()
        chooseContextItem("Add to Favourites")

        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        XCTAssertFalse(sidebar.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Production")).firstMatch.exists, "the flat row shows its folder")
        XCTAssertFalse(hostRow("web-1").exists)
        hostRow("web-2").rightClick()
        chooseContextItem("Remove from Favourites")
        waitGone(hostRow("web-2"))
        wait(mainWindow.staticTexts["No Favourites"])
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-favourites"].isSelected, "removing the last favourite switched tabs")
    }

    @MainActor func testAFreshWindowOpensOnHostsEvenWhenTheSeedHasFavourites() {
        options.favourites = ["web-2"]
        options.freshLaunch = true
        launch()
        wait(hostRow("web-2"))
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-hosts"].isSelected)
        wait(hostRow("web-1"))
        wait(folderRow("Production"))
    }

    @MainActor func testSwitchingTabsWithThreeSelectedFavouritesDoesNotRetainFolderRows() {
        launch()
        let names = ["web-1", "web-2", "db-1"]
        let folderNames = ["Production", "EU", "Staging"]
        for name in names { wait(hostRow(name)) }
        hostRow("web-1").click()
        XCUIElement.perform(withKeyModifiers: .command) {
            self.hostRow("web-2").click()
            self.hostRow("db-1").click()
        }
        hostRow("db-1").rightClick()
        chooseContextItem("Add 3 to Favourites")

        showSidebarTab(.favourites)
        for name in names {
            wait(hostRow(name))
            XCTAssertFalse(outlineRow(containing: hostRow(name)).isSelected, "Hosts selection leaked into Favourites")
        }
        // A flat list: no folder rows, and no folder names on the host rows.
        eventually("Favourites showed folder rows") { self.sidebar.disclosureTriangles.count == 0 }

        showSidebarTab(.hosts)
        for group in folderNames {
            wait(folderRow(group))
            XCTAssertEqual(mainWindow.staticTexts.matching(identifier: group).count, 1, "a stale copy of \(group) remains")
        }
        // Hosts keeps its own three-host selection and keyboard routing after recreating the outline.
        app.typeKey("e", modifierFlags: .command)
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet, "the rebuilt outline lost keyboard focus or its shortcut marker")
        wait(sheet.staticTexts["Editing 3 hosts"], "the multi-selection was lost")
        sheet.buttons["Cancel"].click()
        waitGone(sheet)

        showSidebarTab(.favourites)
        // A flat list: no folder rows, and no folder names on the host rows.
        eventually("Favourites showed folder rows") { self.sidebar.disclosureTriangles.count == 0 }
        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Staging database"])
        for group in folderNames { waitGone(mainWindow.staticTexts[group]) }
        showSidebarTab(.hosts)
        for group in folderNames {
            wait(folderRow(group))
            XCTAssertEqual(mainWindow.staticTexts.matching(identifier: group).count, 1)
        }
    }

    @MainActor func testEachTabRemembersItsOwnSelection() {
        options.favourites = ["web-1", "web-2"]
        launch()
        showSidebarTab(.favourites)
        wait(hostRow("web-1"))
        hostRow("web-1").click()

        showSidebarTab(.hosts)
        wait(hostRow("web-1"))
        XCTAssertFalse(outlineRow(containing: hostRow("web-1")).isSelected, "Favourites selection leaked into Hosts")
        hostRow("web-2").click()
        XCUIElement.perform(withKeyModifiers: .command) { self.hostRow("db-1").click() }

        showSidebarTab(.favourites)
        wait(hostRow("web-1"))
        eventually("Favourites lost its saved selection") {
            self.outlineRow(containing: self.hostRow("web-1")).isSelected
        }
        XCTAssertFalse(outlineRow(containing: hostRow("web-2")).isSelected, "Hosts selection leaked into Favourites")
        hostRow("web-2").click()

        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Staging database"])
        sidebar.staticTexts["Staging database"].click()
        eventually("the forward row was not selected") {
            self.outlineRow(containing: self.sidebar.staticTexts["Staging database"]).isSelected
        }

        showSidebarTab(.hosts)
        for name in ["web-2", "db-1"] {
            wait(hostRow(name))
            eventually("Hosts lost its saved multi-selection") {
                self.outlineRow(containing: self.hostRow(name)).isSelected
            }
        }
        XCTAssertFalse(outlineRow(containing: hostRow("web-1")).isSelected)

        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        eventually("Favourites lost its changed selection") {
            self.outlineRow(containing: self.hostRow("web-2")).isSelected
        }
        XCTAssertFalse(outlineRow(containing: hostRow("web-1")).isSelected)

        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Staging database"])
        eventually("Port Forwards lost its saved selection") {
            self.outlineRow(containing: self.sidebar.staticTexts["Staging database"]).isSelected
        }
    }

    @MainActor func testRemovingAFavouriteClearsItsInactiveSelectionOnly() {
        options.favourites = ["web-1"]
        launch()
        showSidebarTab(.favourites)
        wait(hostRow("web-1"))
        hostRow("web-1").click()

        showSidebarTab(.hosts)
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        hostRow("web-1").rightClick()
        chooseContextItem("Remove from Favourites")
        hostRow("web-1").rightClick()
        chooseContextItem("Add to Favourites")

        showSidebarTab(.favourites)
        wait(hostRow("web-1"))
        XCTAssertFalse(outlineRow(containing: hostRow("web-1")).isSelected, "re-adding a favourite restored its removed selection")

        showSidebarTab(.hosts)
        wait(hostRow("web-1"))
        eventually("unmarking a favourite changed the Hosts selection") {
            self.outlineRow(containing: self.hostRow("web-1")).isSelected
        }
    }

    @MainActor func testCreatingFromFavouritesRevealsANewHostAndClearsAFilterThatWouldHideIt() {
        options.favourites = ["web-1"]
        launch()
        showSidebarTab(.hosts)
        wait(hostRow("web-1"))
        filter.click()
        filter.typeText("web")
        showSidebarTab(.favourites)
        wait(hostRow("web-1"))
        let newHost = mainWindow.buttons["New Host…"]
        wait(newHost)
        newHost.click()
        let sheet = mainWindow.sheets.firstMatch
        wait(sheet)
        let name = sheet.textFields.matching(NSPredicate(format: "placeholderValue == 'Optional'")).firstMatch
        name.click()
        name.typeText("sidebar-created")
        let address = sheet.textFields.matching(NSPredicate(format: "placeholderValue == 'example.com'")).firstMatch
        address.click()
        address.typeText("sidebar-created.example.test")
        let user = sheet.textFields.matching(NSPredicate(format: "placeholderValue == 'root'")).firstMatch
        user.click()
        user.typeText("root")
        let password = sheet.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Required'")).firstMatch
        password.click()
        password.typeText("not-a-real-password")
        sheet.buttons["Add"].click()
        waitGone(sheet)

        wait(hostRow("sidebar-created"))
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-hosts"].isSelected)
        XCTAssertEqual(filter.value as? String, "")
        let row = outlineRow(containing: hostRow("sidebar-created"))
        eventually("the new host was not selected") { row.isSelected }
    }

    @MainActor func testFilterIsShownAndAppliedOnlyInHostsAndKeepsItsText() {
        options.favourites = ["web-2", "db-1"]
        launch()
        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        wait(hostRow("db-1"))
        XCTAssertFalse(filter.exists)
        XCTAssertFalse(addMenu.exists)

        showSidebarTab(.hosts)
        wait(filter)
        wait(addMenu)
        filter.click()
        filter.typeText("web")
        wait(hostRow("web-1"))
        waitGone(hostRow("db-1"))

        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        wait(hostRow("db-1"))
        XCTAssertFalse(filter.exists)
        XCTAssertFalse(addMenu.exists)

        showSidebarTab(.forwards)
        wait(sidebar.staticTexts["Staging database"])
        XCTAssertFalse(filter.exists)
        XCTAssertFalse(addMenu.exists)

        showSidebarTab(.hosts)
        wait(filter)
        wait(addMenu)
        XCTAssertEqual(filter.value as? String, "web")
        wait(hostRow("web-1"))
        XCTAssertFalse(hostRow("db-1").exists)
        mainWindow.buttons["sidebar-filter-clear"].click()
        wait(hostRow("db-1"))
    }

    @MainActor func testDuplicatingAFavouriteRevealsItsNonFavouriteCopyInACollapsedFolder() {
        options.favourites = ["web-2"]
        launch()
        showSidebarTab(.hosts)
        wait(hostRow("web-2"))
        sidebar.disclosureTriangles.element(boundBy: 0).click()
        waitGone(hostRow("web-2"))
        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        hostRow("web-2").click()
        hostRow("web-2").rightClick()
        chooseContextItem("Duplicate")
        wait(hostRow("web-2 copy"), "the copy was hidden by its collapsed ancestors")
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-hosts"].isSelected)

        showSidebarTab(.favourites)
        wait(hostRow("web-2"))
        XCTAssertFalse(hostRow("web-2 copy").exists, "Duplicate copied the personal favourite marker")
        eventually("Duplicate overwrote the Favourites selection with the new copy") {
            self.outlineRow(containing: self.hostRow("web-2")).isSelected
        }
    }

    @MainActor func testHostAndViewMenusAndInspectorCanManageFavourites() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        app.menuBars.menuBarItems["Host"].click()
        let add = app.menuBars.menuItems["Add to Favourites"]
        wait(add)
        XCTAssertTrue(add.isEnabled)
        add.click()
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Favourites"].click()
        wait(hostRow("web-1"))
        waitGone(hostRow("web-2"))
        XCTAssertTrue(mainWindow.buttons["sidebar-tab-favourites"].isSelected)

        app.typeKey("i", modifierFlags: [.command, .option])
        wait(mainWindow.staticTexts["No host selected"], "Hosts selection leaked into the Favourites inspector")
        hostRow("web-1").click()
        let star = mainWindow.buttons["inspector-favourite"]
        wait(star)
        star.click()
        wait(mainWindow.staticTexts["No Favourites"])
        wait(mainWindow.staticTexts["No host selected"], "the removed favourite stayed selected")

        showSidebarTab(.hosts)
        wait(star, "removing a favourite cleared the separate Hosts selection")
        XCTAssertEqual(star.label, "Add to Favourites")
    }

    // MARK: Move To…
    //
    // The seed is Production { web-1, EU { web-2 } } and Staging { db-1 }. A folder's disclosure triangle is the
    // way to see what is in it: collapsing it hides everything that moved there.

    private func moveTo(_ path: String...) {
        chooseContextItem("Move To…")
        for title in path { chooseContextItem(title) }
    }

    @MainActor func testAHostMovesToAnotherFolder() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").rightClick()
        moveTo("Staging")

        // Triangles: Production, EU, Staging. Collapsing Staging now hides web-1 as well as db-1.
        sidebar.disclosureTriangles.element(boundBy: 2).click()
        waitGone(hostRow("db-1"))
        waitGone(hostRow("web-1"), "web-1 did not move into Staging")
        wait(hostRow("web-2"))
    }

    private func chooseSortOrder(_ title: String) {
        let sort = mainWindow.descendants(matching: .any).matching(identifier: "sidebar-sort").firstMatch
        wait(sort)
        sort.click()
        // The menu bar has a Sort Hosts By menu with the same titles; this is the one that opened from the button.
        let item = sort.menuItems[title]
        wait(item)
        item.click()
        XCTAssertEqual(sort.value as? String, title, "the sort order did not change")
    }

    @MainActor func testDraggingRowsDoesNothingOutsideCustomOrder() {
        launch()
        wait(hostRow("web-1")); wait(folderRow("Staging"))
        let before = hostRow("web-1").frame
        drag(hostRow("web-1"), to: folderRow("Staging").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        // Nothing moved: web-1 is still where it was, under Production.
        XCTAssertEqual(hostRow("web-1").frame, before, "a row was dragged although the order is not Custom Order")
    }

    @MainActor func testDraggingAHostOntoAFolderInCustomOrderFilesItThere() {
        launch()
        chooseSortOrder("Custom Order")
        wait(hostRow("web-1")); wait(folderRow("Staging"))
        drag(hostRow("web-1"), to: folderRow("Staging").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        // web-1 was above Staging, in Production; filed in Staging it is listed below Staging's row.
        let deadline = Date().addingTimeInterval(8)
        while hostRow("web-1").frame.minY < folderRow("Staging").frame.minY, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(hostRow("web-1").frame.minY, folderRow("Staging").frame.minY, "web-1 did not move into Staging")
        XCTAssertGreaterThan(hostRow("db-1").frame.minY, folderRow("Staging").frame.minY)
        wait(hostRow("web-2"))
    }

    @MainActor func testDroppingOnTheBottomEdgeOfARowPlacesTheHostBelowIt() {
        launch()
        chooseSortOrder("Custom Order")
        wait(hostRow("web-2")); wait(hostRow("db-1"))
        let inEU = hostRow("web-2").frame.minX
        // 1.2 of the label's height down from its top is the strip at the bottom of the row, below the label.
        drag(hostRow("web-2"), to: hostRow("db-1").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2)))

        // Now a sibling of db-1 in Staging (the same indent), listed below it.
        let deadline = Date().addingTimeInterval(8)
        while hostRow("web-2").frame.minX == inEU, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(hostRow("web-2").frame.minX, hostRow("db-1").frame.minX, "web-2 did not leave EU for Staging")
        XCTAssertGreaterThan(hostRow("web-2").frame.minY, hostRow("db-1").frame.minY, "web-2 is not below db-1")
    }

    @MainActor func testDraggingOneSelectedHostMovesAllTheSelectedHosts() {
        launch()
        chooseSortOrder("Custom Order")
        wait(hostRow("web-1")); wait(hostRow("web-2")); wait(hostRow("db-1")); wait(folderRow("Production"))
        // web-1 is directly in Production; web-2 (in EU) and db-1 (in Staging) are one level deeper or elsewhere.
        let inProduction = hostRow("web-1").frame.minX
        hostRow("web-2").click()
        XCUIElement.perform(withKeyModifiers: .command) { hostRow("db-1").click() }
        drag(hostRow("web-2"), to: folderRow("Production").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        let deadline = Date().addingTimeInterval(8)
        while hostRow("web-2").frame.minX != inProduction, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(hostRow("web-2").frame.minX, inProduction, "web-2 did not move into Production")
        XCTAssertEqual(hostRow("db-1").frame.minX, inProduction, "db-1, selected with it, did not follow")
        let production = folderRow("Production").frame.minY
        for name in ["web-1", "web-2", "db-1"] {
            XCTAssertGreaterThan(hostRow(name).frame.minY, production, "\(name) is not listed under Production")
        }
    }

    @MainActor func testAHostMovesToTheTopLevel() {
        launch()
        wait(hostRow("web-2"))
        hostRow("web-2").rightClick()
        moveTo("None (Top Level)")

        sidebar.disclosureTriangles.element(boundBy: 0).click()
        waitGone(hostRow("web-1"))
        wait(hostRow("web-2"), "web-2 stayed inside Production")
    }

    @MainActor func testFoldersAreNestedSubmenusAndAFolderCannotMoveIntoItself() {
        launch()
        wait(hostRow("db-1"))
        hostRow("db-1").rightClick()
        // Production has a subfolder, so it is a submenu of its own.
        moveTo("Production", "EU")

        // Triangles: Production, EU, Staging (now empty). Collapsing EU hides web-2 and db-1 but not web-1.
        sidebar.disclosureTriangles.element(boundBy: 1).click()
        waitGone(hostRow("web-2"))
        waitGone(hostRow("db-1"), "db-1 did not move into Production ▸ EU")
        wait(hostRow("web-1"))

        folderRow("Production").rightClick()
        chooseContextItem("Move To…")
        chooseContextItem("Production")
        let here = app.menuItems.matching(identifier: "This Folder").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertEqual(here?.isEnabled, false, "a folder can be moved into itself")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSeveralFoldersGetOnlyMoveTo() {
        launch()
        wait(folderRow("EU"))
        folderRow("Staging").click()
        XCUIElement.perform(withKeyModifiers: .command) { self.folderRow("EU").click() }
        folderRow("EU").rightClick()
        wait(app.menuItems["Move To…"])
        XCTAssertFalse(app.menuItems["Rename…"].exists, "a menu for several folders offers Rename")
        moveTo("None (Top Level)")

        // EU left Production and sorts first, so the triangles are EU, Production, Staging:
        // collapsing Production hides web-1 but no longer web-2.
        sidebar.disclosureTriangles.element(boundBy: 1).click()
        waitGone(hostRow("web-1"))
        wait(hostRow("web-2"), "EU did not move to the top level")
    }

    @MainActor func testAHostAndAFolderMoveTogether() {
        launch()
        wait(hostRow("web-1"))
        hostRow("web-1").click()
        XCUIElement.perform(withKeyModifiers: .command) { self.folderRow("Staging").click() }
        folderRow("Staging").rightClick()
        moveTo("Production", "EU")

        // Triangles: Production, EU, Staging (inside EU). Collapsing EU hides web-2, web-1 and Staging's db-1.
        sidebar.disclosureTriangles.element(boundBy: 1).click()
        waitGone(hostRow("web-2"))
        waitGone(hostRow("web-1"), "web-1 did not move into EU")
        waitGone(hostRow("db-1"), "Staging did not move into EU")
    }
}
