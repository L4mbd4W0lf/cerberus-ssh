import SwiftUI
import AppKit
import CerberusModels
import CerberusTerminal

/// The app's shortcuts (``AppShortcut``, defined once in `CerberusModels`) as SwiftUI and AppKit want them.
extension AppShortcut {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): KeyEquivalent(c)
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        case .delete: .delete
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Whether a key-down event is this shortcut. The numeric-pad and function flags that every arrow key carries
    /// say nothing about the chord and are ignored.
    func matches(_ event: NSEvent) -> Bool {
        var flags = ShortcutModifiers()
        let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if raw.contains(.command) { flags.insert(.command) }
        if raw.contains(.shift) { flags.insert(.shift) }
        if raw.contains(.option) { flags.insert(.option) }
        if raw.contains(.control) { flags.insert(.control) }
        guard flags == modifiers else { return false }
        switch key {
        case .left: return event.keyCode == 123
        case .right: return event.keyCode == 124
        case .down: return event.keyCode == 125
        case .up: return event.keyCode == 126
        case .delete: return event.keyCode == 51
        case .character(let c): return event.charactersIgnoringModifiers?.lowercased() == String(c).lowercased()
        }
    }
}

extension View {
    /// Gives a menu item or button the key of one of the app's shortcuts.
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
    }
}

extension MenuShortcut {
    /// For the terminal's right-click menu, which is an AppKit menu.
    init(_ shortcut: AppShortcut) {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        self.init(shortcut.key.label.lowercased(), flags)
    }
}
