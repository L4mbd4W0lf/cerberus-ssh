import SwiftUI
import AppKit
import CerberusModels

/// What the sidebar can do with what is selected in it, offered to the menu bar while the sidebar has the
/// keyboard, so the Host menu's shortcuts (⌘S connect, ⇧⌘D duplicate, ⇧⌘S SFTP, …) mean something only then.
/// When a terminal has the keyboard these are off and ⌘D, ⌘N and the rest keep their usual jobs.
struct SidebarActions {
    /// How many hosts are selected (0 when a folder or nothing is).
    var hostCount = 0
    /// A folder is the selection.
    var hasFolder = false

    var connect: () -> Void = {}
    var openSFTP: () -> Void = {}
    var edit: () -> Void = {}
    var duplicate: () -> Void = {}
    var addsFavourite = true
    var toggleFavourite: () -> Void = {}
    var rename: () -> Void = {}
    var delete: () -> Void = {}

    var hasHosts: Bool { hostCount > 0 }
    /// One host opens its files; two copy between each other (the same rule as the context menu).
    var canSFTP: Bool { hostCount == 1 || hostCount == 2 }

    static func favouriteAdds(_ hosts: [SSHHost]) -> Bool {
        hosts.isEmpty || hosts.contains { !$0.isFavourite }
    }

    static func favouriteTitle(count: Int, adds: Bool) -> String {
        let subject = count > 1 ? "\(count) " : ""
        return adds ? "Add \(subject)to Favourites" : "Remove \(subject)from Favourites"
    }
}

extension FocusedValues {
    @Entry var sidebarActions: SidebarActions?
}

/// The keys that act on the sidebar's selection (⌘S connect, ⇧⌘S SFTP, ⌘E edit or rename a
/// folder, ⇧⌘D duplicate, ⌘⌫ delete). They are taken from the keyboard before the menu bar sees them,
/// and only while the sidebar is the first responder, so in a terminal ⌘D still splits.
/// (A menu-bar key that changed meaning with focus did not work: SwiftUI does not notice an AppKit terminal taking
/// the keyboard, so the sidebar's focus outlived its use and ⇧⌘D duplicated a host from a terminal.)
@MainActor
final class SidebarKeyHandler {
    var actions = SidebarActions()
    /// The window whose sidebar this is: with several windows each has a handler, and only its own may act.
    weak var window: NSWindow?
    nonisolated(unsafe) private var monitor: Any?

    var hasKeyboard: Bool {
        guard let window, window === NSApp.keyWindow else { return false }
        return Self.sidebarHasKeyboard(window)
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated { consumed = self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// Returns whether the key was used (and so must not go on to the menu bar).
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === self.window, window === NSApp.keyWindow,
              Self.sidebarHasKeyboard(window) else { return false }
        func run(_ allowed: Bool, _ action: () -> Void) -> Bool {
            guard allowed else { return false }
            action()
            return true
        }
        if AppShortcut.sidebarConnect.matches(event) { return run(actions.hasHosts, actions.connect) }
        if AppShortcut.sidebarSFTP.matches(event) { return run(actions.canSFTP, actions.openSFTP) }
        // Edit and Rename share ⌘E: hosts are edited, a folder is renamed.
        if AppShortcut.sidebarEdit.matches(event) { return run(actions.hasHosts, actions.edit) || run(actions.hasFolder, actions.rename) }
        if AppShortcut.sidebarDuplicate.matches(event) { return run(actions.hasHosts, actions.duplicate) }
        if AppShortcut.sidebarRename.matches(event) { return run(actions.hasFolder, actions.rename) }
        if AppShortcut.sidebarDelete.matches(event) { return run(actions.hasFolder || actions.hostCount == 1, actions.delete) }
        return false
    }

    /// Is the keyboard in the sidebar's list? Its outline view carries an identifier put there by
    /// ``SidebarMarker``. (Its accessibility label "Sidebar" was tried first: it is there while a test drives the
    /// app and absent in normal use, when nothing asks for accessibility, so no key worked for a person.)
    private static func sidebarHasKeyboard(_ window: NSWindow) -> Bool {
        var view = window.firstResponder as? NSView
        for _ in 0..<10 {
            guard let current = view else { return false }
            if current.identifier == SidebarMarker.identifier { return true }
            view = current.superview
        }
        return false
    }
}

/// Put behind the sidebar's list, it finds the list's outline view (the AppKit view that has the keyboard) and
/// labels it, so ``SidebarKeyHandler`` can tell the sidebar from a terminal or another list.
struct SidebarMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("cerberus-sidebar-outline")
    @Binding var restoreKeyboardFocus: Bool

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.restoreKeyboardFocus = $restoreKeyboardFocus
        return view
    }
    func updateNSView(_ view: MarkerView, context: Context) {
        view.restoreKeyboardFocus = $restoreKeyboardFocus
    }

    final class MarkerView: NSView {
        var restoreKeyboardFocus: Binding<Bool> = .constant(false)

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleTagging() }
        override func layout() { super.layout(); scheduleTagging() }

        private func scheduleTagging() {
            // After the list has been built and laid out.
            DispatchQueue.main.async { [weak self] in self?.tagOutline() }
        }

        /// Labels the outline view that lies over this view (the list draws in the same place).
        private func tagOutline() {
            guard let root = window?.contentView, bounds.width > 0 else { return }
            let mine = convert(bounds, to: nil)
            var queue: [NSView] = [root]
            while let view = queue.popLast() {
                if let outline = view as? NSOutlineView, outline.identifier != Self.identifierValue,
                   outline.convert(outline.bounds, to: nil).intersects(mine) {
                    outline.identifier = SidebarMarker.identifier
                    if restoreKeyboardFocus.wrappedValue {
                        restoreKeyboardFocus.wrappedValue = false
                        if let window, window === NSApp.keyWindow { window.makeFirstResponder(outline) }
                    }
                }
                queue.append(contentsOf: view.subviews)
            }
        }
        private static let identifierValue = SidebarMarker.identifier
    }
}
