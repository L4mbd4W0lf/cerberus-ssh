import XCTest

/// Looks at what the screen shows in the moments after a dragged tab is let go: it should settle at once, with
/// no copy of the tab left hanging where the mouse was released. Screenshots are attached to the result
/// so they can be looked at; the test itself only checks that the tabs end up in the new order.
final class LiveTabReorderGhostTests: CerberusUITestCase {
    @MainActor func testADroppedTabLeavesNoImageBehind() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))

        let first = tab("live-1")
        let target = first.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let released = Date()
        drag(tab("live-2"), to: target)   // holds for a second at the target, then lets go

        // What the screen shows, a few times after the button came up. (The drag helper returns just after.)
        let afterHold = Date().timeIntervalSince(released)
        for (index, delay) in [0.0, 0.15, 0.3, 0.5, 0.8, 1.2, 2.0].enumerated() {
            if delay > 0 { Thread.sleep(forTimeInterval: delay - (index > 0 ? [0.0, 0.15, 0.3, 0.5, 0.8, 1.2, 2.0][index - 1] : 0)) }
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(index)-after \(delay) s (drag took \(afterHold) s)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        eventually("the tabs did not change order") { tab("live-2").frame.minX < tab("live-1").frame.minX }
    }
}

/// How long a tab dragged out of the window takes to get a window of its own.
final class LiveTabDetachSpeedTests: CerberusUITestCase {
    @MainActor func testADraggedOutTabGetsItsWindowQuickly() throws {
        try startServer()
        launchConnected("live-1", "live-2")
        wait(tab("live-1")); wait(tab("live-2"))

        // The drag helper holds at the destination for a second before it lets go; time from the release on.
        drag(tab("live-2"), to: pointBesideMainWindow())
        let released = Date()
        var appeared: TimeInterval?
        while Date().timeIntervalSince(released) < 5 {
            if workspaceWindows.count == 2 { appeared = Date().timeIntervalSince(released); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let seconds = try XCTUnwrap(appeared, "no second window")
        add({ let a = XCTAttachment(string: "second window after \(seconds) s"); a.lifetime = .keepAlways; return a }())
        XCTAssertLessThan(seconds, 1.0, "the new window took \(seconds) s to appear")
    }
}
