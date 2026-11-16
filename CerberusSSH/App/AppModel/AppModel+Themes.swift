import Foundation
import CerberusModels

extension AppModel {
    private static var customThemesURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CerberusSSH").appendingPathComponent("themes.json")
    }

    static func loadCustomThemes() -> [TerminalTheme] {
        guard let data = try? Data(contentsOf: customThemesURL) else { return [] }
        return CustomThemes.decode(data)
    }

    /// The themes a picker offers: the ones that ship, then the person's own by name.
    var allThemes: [TerminalTheme] {
        ThemeCatalog.all + customThemes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds a theme, or replaces the one with the same id, and writes the list at once (a file, not a default, so a
    /// killed app does not lose it).
    func saveCustomTheme(_ theme: TerminalTheme) {
        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) { customThemes[index] = theme } else { customThemes.append(theme) }
        writeCustomThemes()
    }

    func deleteCustomTheme(_ theme: TerminalTheme) {
        customThemes.removeAll { $0.id == theme.id }
        writeCustomThemes()
    }

    /// Makes `themes` the whole list (a backup brought in), and writes it.
    func replaceCustomThemes(_ themes: [TerminalTheme]) {
        customThemes = themes
        writeCustomThemes()
    }

    func resetCustomThemes() {
        customThemes = []
        try? FileManager.default.removeItem(at: Self.customThemesURL)
    }

    private func writeCustomThemes() {
        let url = Self.customThemesURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CustomThemes.encode(customThemes).write(to: url, options: .atomic)
        } catch {
            CerberusLog.caught(error, note: "saving custom themes")
        }
    }
}
