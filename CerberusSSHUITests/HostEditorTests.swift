import XCTest

final class HostEditorTests: CerberusUITestCase {
    private var sheet: XCUIElement { mainWindow.sheets.firstMatch }

    private func openNewHost() {
        launch()
        mainWindow.buttons["New Host…"].click()
        wait(sheet, "the host editor did not open")
    }

    private func field(_ placeholder: String) -> XCUIElement {
        sheet.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    @MainActor func testAddStaysDisabledUntilTheHostIsComplete() {
        openNewHost()
        XCTAssertFalse(sheet.buttons["Add"].isEnabled, "Add is enabled on an empty form")

        field("example.com").click()
        field("example.com").typeText("box.example.test")
        XCTAssertFalse(sheet.buttons["Add"].isEnabled, "Add is enabled with no sign-in")
    }

    @MainActor func testAddingAHostPutsItInTheSidebar() {
        openNewHost()
        field("Optional").click()
        field("Optional").typeText("uitest-box")
        field("example.com").click()
        field("example.com").typeText("box.example.test")
        field("root").click()
        field("root").typeText("root")
        let password = sheet.secureTextFields.matching(NSPredicate(format: "placeholderValue == 'Required'")).firstMatch
        password.click()
        password.typeText("not-a-real-password")

        XCTAssertTrue(sheet.buttons["Add"].isEnabled, "Add is still disabled on a complete form")
        sheet.buttons["Add"].click()
        waitGone(sheet, "the editor did not close")
        wait(hostRow("uitest-box"), "the new host is not in the sidebar")
    }

    @MainActor func testCancelAddsNothing() {
        openNewHost()
        field("Optional").click()
        field("Optional").typeText("never-saved")
        sheet.buttons["Cancel"].click()
        waitGone(sheet)
        XCTAssertFalse(hostRow("never-saved").exists)
    }

    // MARK: Tags

    private func tagButton(_ id: String) -> XCUIElement { sheet.buttons[id] }

    private func editHost(_ name: String) {
        wait(hostRow(name))
        hostRow(name).rightClick()
        let items = app.menuItems.matching(identifier: "Edit…")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(sheet, "the host editor did not open")
    }

    private func addTag(_ tag: String) {
        let tags = sheet.textFields["tag-field"]
        wait(tags)
        tags.click()
        tags.typeText(tag + "\n")
    }

    @MainActor func testATagIsAddedByTypingAndRemovedWithItsX() {
        launch()
        editHost("web-1")
        addTag("prod")
        wait(tagButton("tag-remove-prod"), "the typed tag did not become a chip")
        tagButton("tag-remove-prod").click()
        waitGone(tagButton("tag-remove-prod"), "the chip's x did not remove the tag")
    }

    @MainActor func testAnExistingTagIsSuggestedAndKeepsItsSpelling() {
        launch()
        editHost("web-1")
        addTag("Prod")
        sheet.buttons["Save"].click()
        waitGone(sheet)

        editHost("web-2")
        let tags = sheet.textFields["tag-field"]
        wait(tags)
        tags.click()
        tags.typeText("pro")
        wait(sheet.buttons["tag-suggestion-Prod"], "no suggestion for a tag already in use")
        tags.typeText("d\n")
        wait(tagButton("tag-remove-Prod"), "typing a tag in another case did not reuse the existing spelling")
        XCTAssertFalse(tagButton("tag-remove-prod").exists)
    }

    @MainActor func testBulkEditRemovesATagByClickingIt() {
        launch()
        editHost("web-1")
        addTag("alpha")
        sheet.buttons["Save"].click()
        waitGone(sheet)

        hostRow("web-1").click()
        XCUIElement.perform(withKeyModifiers: .command) { self.hostRow("web-2").click() }
        hostRow("web-2").rightClick()
        let items = app.menuItems.matching(identifier: "Edit 2 Hosts…")
        wait(items.firstMatch)
        (items.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? items.firstMatch).click()
        wait(sheet, "the bulk editor did not open")
        wait(sheet.buttons["bulk-remove-tag-alpha"], "the selected hosts' tag is not offered for removal")
        sheet.buttons["bulk-remove-tag-alpha"].click()
        sheet.buttons["Apply to 2 Hosts"].click()
        waitGone(sheet)

        editHost("web-1")
        XCTAssertFalse(tagButton("tag-remove-alpha").exists, "the tag is still on web-1")
    }
}
