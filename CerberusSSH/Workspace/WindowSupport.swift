import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault
import CerberusSSHCore


/// Which window a view belongs to, so tabs and menu commands know where they are.
struct WindowIDKey: EnvironmentKey { static let defaultValue = UUID() }
extension EnvironmentValues {
    var windowID: UUID {
        get { self[WindowIDKey.self] }
        set { self[WindowIDKey.self] = newValue }
    }
}

/// Tells the model when its window becomes the active one and when it closes.
struct WindowObserver: NSViewRepresentable {
    let onKey: (NSWindow) -> Void
    let onClose: () -> Void
    /// Where to put the window's top-left corner the first time it appears (a tab pulled
    /// out of another window lands under the pointer), and what to call once it has.
    var origin: CGPoint?
    var onPlaced: () -> Void = {}
    /// Asked when the red button is pressed: a question to put to the person first, or nil to just close.
    var closeQuestion: () -> (title: String, message: String)? = { nil }
    /// Told where the window is whenever it moves or is resized, and asked where to put it when it is being brought back.
    var onFrame: (CGRect) -> Void = { _ in }
    var requestedFrame: CGRect?
    var onFramePlaced: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let anchor = Anchor(onKey: onKey, onClose: onClose, origin: origin, onPlaced: onPlaced, closeQuestion: closeQuestion)
        anchor.onFrame = onFrame; anchor.onFramePlaced = onFramePlaced; anchor.requestedFrame = requestedFrame
        return anchor
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let anchor = view as? Anchor else { return }
        anchor.closeQuestion = closeQuestion
        anchor.onFrame = onFrame
        anchor.onFramePlaced = onFramePlaced
        anchor.requestedFrame = requestedFrame
        anchor.applyRequestedFrame()
    }

    private final class Anchor: NSView {
        let onKey: (NSWindow) -> Void
        let onClose: () -> Void
        private var origin: CGPoint?
        private let onPlaced: () -> Void
        private var tokens: [NSObjectProtocol] = []
        var closeQuestion: () -> (title: String, message: String)?
        var onFrame: (CGRect) -> Void = { _ in }
        var onFramePlaced: () -> Void = {}
        var requestedFrame: CGRect?
        private var originalTarget: AnyObject?
        private var originalAction: Selector?

        init(onKey: @escaping (NSWindow) -> Void, onClose: @escaping () -> Void, origin: CGPoint?, onPlaced: @escaping () -> Void,
             closeQuestion: @escaping () -> (title: String, message: String)?) {
            self.closeQuestion = closeQuestion
            self.onKey = onKey
            self.onClose = onClose
            self.origin = origin
            self.onPlaced = onPlaced
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            if let point = origin {
                origin = nil
                // SwiftUI places the window after this, so wait a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [onPlaced] in
                    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
                    var topLeft = CGPoint(x: point.x - 80, y: point.y + 16)
                    if let area = screen?.visibleFrame {
                        topLeft.x = min(max(topLeft.x, area.minX), area.maxX - window.frame.width)
                        topLeft.y = min(max(topLeft.y, area.minY + window.frame.height), area.maxY)
                    }
                    window.setFrameTopLeftPoint(topLeft)
                    onPlaced()
                }
            }
            applyRequestedFrame()
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // Delivered on the main queue, so this is on the main actor.
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window, !self.isApplyingFrame else { return }
                        self.onFrame(window.frame)
                    }
                })
            }
            // The red button asks first when closing the window would end something live.
            if let button = window.standardWindowButton(.closeButton), button.target !== self {
                originalTarget = button.target as AnyObject?
                originalAction = button.action
                button.target = self
                button.action = #selector(closePressed(_:))
            }
            if window.isKeyWindow { onKey(window) }
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { if let window = self?.window { self?.onKey(window) } } })
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onClose() } })
        }

        private var isApplyingFrame = false

        /// Puts the window where it was when the app was last quit, if that place is still on a screen.
        func applyRequestedFrame() {
            guard let frame = requestedFrame, let window else { return }
            requestedFrame = nil
            isApplyingFrame = true
            // SwiftUI sizes and places a new window just after it appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
                if onScreen {
                    var target = frame
                    target.size.width = max(target.width, window.minSize.width)
                    target.size.height = max(target.height, window.minSize.height)
                    window.setFrame(target, display: true)
                }
                self.isApplyingFrame = false
                self.onFramePlaced()
                self.onFrame(window.frame)
            }
        }

        @objc private func closePressed(_ sender: Any?) {
            let proceed = { [weak self] in
                guard let self, let action = self.originalAction else { self?.window?.close(); return }
                NSApp.sendAction(action, to: self.originalTarget, from: sender)
            }
            guard let window, let question = closeQuestion() else { proceed(); return }
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        }
    }
}

/// Asks for the new-host sheet, optionally starting in a folder.
struct NewHostRequest: Identifiable {
    let id = UUID()
    var folderID: UUID?
}
