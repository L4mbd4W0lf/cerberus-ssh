import AppKit

/// Light, dark, or whatever macOS is set to, for the whole app (Settings ▸ Appearance). Set on `NSApp`, so every
/// window, sheet, menu and the sidebar's glass take it, and SwiftUI's `colorScheme` follows, which is what a terminal
/// theme set to follow the light and dark switches with.
///
/// Kept in the user defaults as a number (0 system, 1 light, 2 dark) so a backup carries it with the other
/// preferences (`PreferencesRecord.numberKeys`).
enum AppAppearance: Int, CaseIterable, Identifiable {
    case system = 0, light = 1, dark = 2

    static let key = "appAppearance"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .system
    }

    /// Puts the saved choice on the app.
    @MainActor static func apply() {
        let wanted = current.nsAppearance
        if NSApp.appearance?.name != wanted?.name { NSApp.appearance = wanted }
    }

    /// Applies the saved choice now and again whenever the defaults change: the setting, a restored backup, or a
    /// UI test's reset all take effect at once, without each having to remember to.
    @MainActor static func follow() {
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }
}
