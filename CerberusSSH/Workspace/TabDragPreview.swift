import SwiftUI
import AppKit

/// A small tab-shaped label that follows the pointer while a tab is dragged. The system's own picture of a dragged
/// tab is blank (it hung about over the dropped tab for a moment after the drop, see `TabButton`), so without
/// this the drag would look like nothing was being carried. It is a window of its own, so it also shows once
/// the pointer leaves the app's windows, and it goes the instant the button comes up.
@MainActor
final class TabDragPreview {
    private var panel: NSPanel?

    func show(title: String) {
        hide()
        let hosting = NSHostingView(rootView: TabDragPill(title: title))
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        self.panel = panel
        move()
        panel.orderFrontRegardless()
    }

    /// Puts it under the pointer.
    func move() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: point.x - panel.frame.width / 2, y: point.y - panel.frame.height - 6))
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct TabDragPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(maxWidth: 220)
            .foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .padding(6)   // room for the shadow
    }
}
