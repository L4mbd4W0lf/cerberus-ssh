import XCTest

final class WindowsTests: CerberusUITestCase {
    @MainActor func testPortForwardsWindowListsTheForwardWithASwitch() {
        launch()
        app.typeKey("p", modifierFlags: [.command, .option])
        let window = app.windows["Port Forwards"]
        wait(window, "the Port Forwards window did not open")
        wait(window.staticTexts["Staging database"], "the forward is not listed")
        let toggle = window.checkBoxes["On"]
        wait(toggle)
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        let switchedOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 0"), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [switchedOff], timeout: 6), .completed, "the switch did not turn off")
    }

    @MainActor func testHelpOpensWithItsPagesInAPaneOnTheLeft() {
        launch()
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuItems["CerberusSSH Help"].click()
        // The window's title follows the page shown; its identifier is fixed.
        let help = app.windows["help"]
        wait(help, "the Help window did not open")
        func page(_ name: String) -> XCUIElement {
            help.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
        }
        for name in ["Getting Started", "Keyboard Shortcuts", "Port Forwarding", "Tips"] {
            wait(page(name), "no \(name) page in the list")
        }
        page("Tips").click()
        wait(help.staticTexts["Duplicate a host"], "the Tips page did not show its content")
        XCTAssertEqual(help.title, "Tips", "the window title did not follow the page")
    }
}
