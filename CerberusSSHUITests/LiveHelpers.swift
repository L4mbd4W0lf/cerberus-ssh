import XCTest
import AppKit

/// What the live tests (those that use the throwaway `sshd`) share.
extension CerberusUITestCase {
    /// Pointer speed for drags, in points a second (the system's `.fast` is far slower than a person flicking a file).
    static var dragSpeed: XCUIGestureVelocity { 4000 }

    /// A sidebar row that says the host is connected ("live-1, connected").
    func connectedRow(_ host: String) -> XCUIElement {
        sidebar.staticTexts.matching(NSPredicate(format: "value == %@", "\(host), connected")).firstMatch
    }

    /// A tab's button, named after the host ("live-1, Close tab"; "live-1, 2, Close tab" with two panes).
    func tab(_ host: String, panes: Int = 1) -> XCUIElement {
        mainWindow.buttons[panes > 1 ? "\(host), \(panes), Close tab" : "\(host), Close tab"]
    }

    /// Has the app connect these hosts before the test starts (set before `launch()`), and, after it,
    /// waits until each says connected. For tests about what happens with a connection, not about
    /// making one: a double-click and the wait for it cost a few seconds each.
    func launchConnected(_ hosts: String...) {
        options.connect = hosts
        launch()
        for host in hosts { wait(connectedRow(host), "\(host) did not connect", timeout: 20) }
    }

    /// Double-clicks the host and waits until it says connected.
    func connect(_ host: String) {
        wait(hostRow(host), "no row for \(host)")
        hostRow(host).doubleClick()
        wait(connectedRow(host), "\(host) did not connect")
    }

    /// Polls until `condition` holds; the server's view of things lags the app's by a moment.
    func eventually(_ message: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail(message, file: file, line: line)
    }

    /// Clicks inside the terminal area (clear of the sidebar and the status bar) so a pane has the
    /// keyboard. `across` is how far along the window to click: 0.6 is one pane, 0.85 the right-hand
    /// pane of a split.
    func clickTerminal(across: CGFloat = 0.6) {
        mainWindow.coordinate(withNormalizedOffset: CGVector(dx: across, dy: 0.5)).click()
    }

    /// A click-drag from the middle of `source` to `destination`. (The long-press drag that
    /// `press(forDuration:thenDragTo:)` makes does not start a tab's drag; this does.)
    ///
    /// The pointer moves very fast and rests only briefly at the end: every drag in the suite goes through here, so
    /// how long a drag takes is set in one place. (It was `.slow` with a second's hold, which made each drag cost
    /// about five seconds.) The hold is what lets the destination see the pointer arrive before the button comes up.
    func drag(_ source: XCUIElement, to destination: XCUICoordinate) {
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: destination, withVelocity: Self.dragSpeed, thenHoldForDuration: 0.25)
    }

    /// A point on the desktop beside the main window, to let a dragged tab go outside every window: the middle of
    /// the wider gap between the window and the edge of the screen. Not past the edge: a drag held at or beyond
    /// the screen's edge makes macOS switch Spaces (Mission Control moves one desktop over).
    func pointBesideMainWindow() -> XCUICoordinate {
        let window = mainWindow.frame
        let screenWidth = NSScreen.screens.first?.frame.width ?? 1440
        let left = window.minX, right = screenWidth - window.maxX
        // The window is most of the screen, so a gap is narrow: it is still the one place to let go that is
        // outside the window and on the screen.
        let x = left >= right ? left / 2 : window.maxX + right / 2
        return mainWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - window.minX, dy: window.height / 2))
    }

    /// The app's windows that hold terminals and tabs (not Settings, Help or Port Forwards).
    var workspaceWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'SwiftUI.WindowGroup'"))
    }

    /// Types a command into the focused terminal, followed by Return.
    func run(_ command: String) { app.typeText(command + "\n") }

    /// A point inside the terminal area, as fractions of it (0, 0 is its top-left, 1, 1 its
    /// bottom-right). The area is what is left of the window once the sidebar, the title and tab bar
    /// and the status bar are taken away, so this holds for any window size.
    func terminalPoint(_ fx: CGFloat, _ fy: CGFloat) -> XCUICoordinate {
        let window = mainWindow.frame
        let left = sidebar.frame.maxX - window.minX + 4
        let top: CGFloat = 90, bottom: CGFloat = 40
        let width = window.width - left, height = window.height - top - bottom
        return mainWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left + fx * width, dy: top + fy * height))
    }

    /// Records the shell's process id in a file named for `host`, from whichever pane is clicked.
    func clickTerminal(at point: XCUICoordinate) { point.click() }
}
