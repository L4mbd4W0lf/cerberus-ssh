import AppKit
import UniformTypeIdentifiers

/// The app that files from a file tab are edited in, chosen in Settings ▸ Behaviour. A file is always handed to this
/// app by name, never to whatever the Mac opens its kind of file with: that is Terminal for a `.sh`, which would run it.
enum TextEditorChoice {
    /// The chosen app's bundle identifier; blank for the Mac's default editor for plain text.
    static let key = "textEditorBundleID"

    struct App: Hashable {
        let bundleID: String
        let url: URL
        var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// The Mac's default app for plain text; with none set, TextEdit, macOS's own editor (looked up, else where macOS
    /// keeps it).
    static var systemDefault: App? {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: .plainText), let app = app(at: url) { return app }
        let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        return app(at: textEdit)
    }

    /// The app chosen in Settings; the default editor while none is chosen, or the chosen one is no longer installed.
    static var current: App? {
        let id = UserDefaults.standard.string(forKey: key) ?? ""
        if !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return App(bundleID: id, url: url) }
        return systemDefault
    }

    /// The apps that say they can edit plain text, by name.
    static var candidates: [App] {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: .plainText).compactMap(app(at:))
        return Array(Set(apps)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func app(at url: URL) -> App? {
        Bundle(url: url)?.bundleIdentifier.map { App(bundleID: $0, url: url) }
    }

    /// Opens the file in the chosen app.
    static func open(_ file: URL) async throws {
        guard let app = current else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No text editor was found."]) }
        try await NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
