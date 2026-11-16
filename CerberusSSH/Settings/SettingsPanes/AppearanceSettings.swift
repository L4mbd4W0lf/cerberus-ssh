import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

extension RGB {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }
}

/// A small terminal showing a theme's colours.
struct ThemePreview: View {
    let theme: TerminalTheme
    let appearance: TerminalAppearance

    var body: some View {
        let font = Font(appearance.font)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("deploy@prod-web").foregroundStyle(
                    theme.ansi[2].swiftUIColor
                )
                Text(":").foregroundStyle(theme.foreground.swiftUIColor)
                Text("~/app").foregroundStyle(theme.ansi[4].swiftUIColor)
                Text("$ ls -la").foregroundStyle(theme.foreground.swiftUIColor)
            }
            HStack(spacing: 0) {
                Text("drwxr-xr-x ").foregroundStyle(
                    theme.foreground.swiftUIColor
                )
                Text("bin  ").foregroundStyle(theme.ansi[4].swiftUIColor)
                Text("run.sh  ").foregroundStyle(theme.ansi[2].swiftUIColor)
                Text("error.log").foregroundStyle(theme.ansi[1].swiftUIColor)
            }
            HStack(spacing: 0) {
                Text("warning: ").foregroundStyle(theme.ansi[3].swiftUIColor)
                Text("disk 91% ").foregroundStyle(theme.foreground.swiftUIColor)
                Text(" selected ").background(theme.selection.swiftUIColor)
                    .foregroundStyle(theme.foreground.swiftUIColor)
                Text("█").foregroundStyle(theme.cursor.swiftUIColor)
            }
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(
                        theme.ansi[index].swiftUIColor
                    ).frame(width: 14, height: 14)
                }
            }
            .padding(.top, 4)
        }
        .font(font)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.background.swiftUIColor,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

/// The installed fonts, read once: there are hundreds and the list doesn't change while the
/// app runs.
enum FontCache { static let fonts = InstalledFonts.load() }

struct AppearanceSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Query private var allSettings: [AppSettings]
    @AppStorage(ThemeCatalog.followSystemKey) private var followsSystemTheme =
        false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fonts: InstalledFonts { FontCache.fonts }

    var body: some View {
        if let settings = allSettings.first {
            form(settings)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    _ = appSettings(in: modelContext)
                    modelContext.saveLogged()
                }
        }
    }

    private func form(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        let chosen = ThemeCatalog.theme(
            id: settings.defaultThemeID,
            custom: app.customThemes
        )
        let shown =
            followsSystemTheme
            ? ThemeCatalog.following(chosen, systemIsDark: colorScheme == .dark)
            : chosen
        let appearance = TerminalAppearance(
            theme: shown,
            fontName: settings.fontName,
            fontSize: settings.fontSize,
            cursorStyle: settings.cursorStyle,
            scrollbackLines: settings.scrollbackLines
        )

        return Form {
            Section("Theme") {
                Picker("Default theme", selection: $settings.defaultThemeID) {
                    ForEach(app.allThemes) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("default-theme")
                Toggle(
                    "Follow the system's light or dark appearance",
                    isOn: $followsSystemTheme
                )
                Text(
                    followsSystemTheme && !ThemeCatalog.hasCounterpart(chosen)
                        ? "\(chosen.name) has only one look, so it stays as it is."
                        : "A theme with a light and a dark version (Cerberus, Solarized) switches with macOS. A theme with only one (Nord, Dracula) stays as chosen."
                )
                .font(.caption).foregroundStyle(.secondary)
                ThemePreview(theme: appearance.theme, appearance: appearance)
                Text(
                    "A host can use a different theme from its Edit sheet; it follows the system the same way."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            CustomThemesSection(
                appearance: { theme in
                    TerminalAppearance(
                        theme: theme,
                        fontName: settings.fontName,
                        fontSize: settings.fontSize,
                        cursorStyle: settings.cursorStyle,
                        scrollbackLines: settings.scrollbackLines
                    )
                },
                chosen: chosen
            )

            Section("Text") {
                Picker("Font", selection: $settings.fontName) {
                    Section("Fixed-width") {
                        ForEach(fonts.monospaced) {
                            Text($0.label).tag($0.postScriptName)
                        }
                    }
                    Section("All other fonts") {
                        ForEach(fonts.other) {
                            Text($0.label).tag($0.postScriptName)
                        }
                    }
                    // Keep a font that is chosen but no longer installed visible rather than blank.
                    if !fonts.contains(settings.fontName) {
                        Text(settings.fontName + " (not installed)").tag(
                            settings.fontName
                        )
                    }
                }
                if let chosen = fonts.all.first(where: {
                    $0.postScriptName == settings.fontName
                }), !chosen.isFixedWidth {
                    Label(
                        "This font isn't fixed-width, so columns in the terminal won't line up.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(Color.statusWarning)
                }
                Stepper(value: $settings.fontSize, in: 9...32, step: 1) {
                    Text("Size: \(Int(settings.fontSize)) pt")
                }
                Picker("Cursor", selection: $settings.cursorStyle) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if reduceMotion
                    && settings.cursorStyle.steady != settings.cursorStyle
                {
                    Text(
                        "The cursor does not blink while Reduce Motion is on in macOS (System Settings ▸ Accessibility ▸ Display)."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Clipboard and paste") {
                Toggle(
                    "Ask before pasting multiple lines",
                    isOn: $settings.confirmMultilinePaste
                )
                Text(
                    "Each line of a multi-line paste can run as soon as it arrives. Text with hidden control characters always asks."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Let programs on the server change my clipboard",
                    isOn: $settings.allowRemoteClipboardWrite
                )
                Text(
                    "Off by default. A hostile or compromised server could otherwise silently replace what you copy (OSC 52)."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Scrollback") {
                Stepper(
                    value: $settings.scrollbackLines,
                    in: 1_000...200_000,
                    step: 1_000
                ) {
                    Text("\(settings.scrollbackLines.formatted()) lines")
                }
                Text("Kept in memory only, per session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
