import SwiftUI
import AppKit
import CerberusSSHCore
import CerberusModels

/// What a key asks of a file pane. The pane's view acts on it (it owns the sheets and the confirmation), using the
/// rows that are selected at that moment.
enum PaneRequest: Equatable { case newFolder, rename, permissions, delete }

/// The Finder-style keys for a file tab, acting on the focused pane:
///
/// | key | action |
/// |---|---|
/// | ⌘C, ⌘V | copy the selected rows, paste them into the folder the pane shows (inside this app only) |
/// | ⌥⌘V | paste them as a move: the originals are removed once they have arrived |
/// | ⌘↓ | open the selected folder |
/// | ⇧⌘N | new folder |
/// | ⌥⌘R | rename the selected row |
/// | ⌘⌫ | delete the selected rows (asks first) |
/// | ⌘I | permissions (Finder's Get Info) |
/// | ⌘R | refresh |
///
/// (⌘↑, ⌃⌘← and ⌃⌘→ are menu items; Return opens a row, as the list does by itself.) Like the sidebar's
/// keys they are taken before the menu bar sees them, and only while a list in this window has the keyboard, so a
/// path being edited keeps ⌘⌫ and ⌘R keeps reconnecting an SSH tab.
@MainActor
final class FileTabKeyHandler {
    weak var window: NSWindow?
    /// The file tab shown in this window, if the selected tab is one.
    var currentTab: () -> FileTabModel? = { nil }
    nonisolated(unsafe) private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated { consumed = self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window === NSApp.keyWindow, window.attachedSheet == nil,
              let files = currentTab(), Self.listHasKeyboard(window) else { return false }
        let pane = files.focusedPane
        // Arrow keys carry the numeric-pad and function flags as well; they say nothing about the chord.
        if AppShortcut.filesCopy.matches(event) { files.copySelection(of: pane) }
        else if AppShortcut.filesPaste.matches(event) { files.paste(into: pane) }
        else if AppShortcut.filesMoveHere.matches(event) { files.paste(into: pane, moving: true) }
        else if AppShortcut.filesNewFolder.matches(event) { pane.request = .newFolder }
        else if AppShortcut.filesRename.matches(event) { pane.request = .rename }
        else if AppShortcut.filesPermissions.matches(event) { pane.request = .permissions }
        else if AppShortcut.filesRefresh.matches(event) { Task { await pane.reload() } }
        else if AppShortcut.filesDelete.matches(event) { pane.request = .delete }
        else if AppShortcut.filesOpen.matches(event) {
            if let folder = pane.selectedEntries.first(where: \.isDirectory), pane.selectedEntries.count == 1 {
                Task { await pane.activate(folder) }
            }
        } else { return false }
        return true
    }

    /// A list (not a text field) has the keyboard, and it is not the sidebar's.
    private static func listHasKeyboard(_ window: NSWindow) -> Bool {
        var view = window.firstResponder as? NSView
        var inList = false
        for _ in 0..<10 {
            guard let current = view else { break }
            if current.identifier == SidebarMarker.identifier { return false }
            if current is NSTableView { inList = true }
            view = current.superview
        }
        return inList && !(window.firstResponder is NSText)
    }
}

/// Hands over the window a view is in, once it has one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // Not when the view is taken out of its window: the sidebar is rebuilt on a tab switch, and the old probe leaving
        // after the new one arrived would otherwise set the window back to nil, and with it the handlers' window.
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { onWindow(window) } }
    }
}
