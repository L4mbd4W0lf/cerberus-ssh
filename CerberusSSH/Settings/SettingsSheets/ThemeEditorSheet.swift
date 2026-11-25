import AppKit
import CerberusModels
import CerberusTerminal
import SwiftUI
import UniformTypeIdentifiers

extension RGB {
    /// From a SwiftUI colour, in sRGB; nil for one that cannot be expressed there.
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return nil
        }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, value)) * 255).rounded())
        }
        self.init(
            red: byte(rgb.redComponent),
            green: byte(rgb.greenComponent),
            blue: byte(rgb.blueComponent)
        )
    }
}

/// Settings ▸ Appearance ▸ Your themes: themes of the person's own, made here or imported from iTerm2.
struct CustomThemesSection: View {
    let appearance: (TerminalTheme) -> TerminalAppearance
    let chosen: TerminalTheme
    @Environment(AppModel.self) private var app
    @State private var editing: ThemeEdit?
    @State private var notice: String?

    struct ThemeEdit: Identifiable {
        let theme: TerminalTheme
        let isNew: Bool
        var id: String { theme.id }
    }

    var body: some View {
        Section("Your themes") {
            if app.customThemes.isEmpty {
                Text(
                    "None yet. Start from the theme above, or bring colours from iTerm2."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(
                app.customThemes.sorted {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
            ) { theme in
                HStack {
                    Swatches(theme: theme)
                    Text(theme.name).lineLimit(1)
                    Spacer()
                    Button("Edit…") {
                        editing = ThemeEdit(theme: theme, isNew: false)
                    }
                    .accessibilityIdentifier("theme-edit-\(theme.name)")
                    Button("Duplicate") {
                        let copy = CustomThemes.copy(of: theme)
                        app.saveCustomTheme(copy)
                    }
                    Button("Delete", role: .destructive) {
                        app.deleteCustomTheme(theme)
                    }
                    .accessibilityIdentifier("theme-delete-\(theme.name)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(theme.name)
            }
            HStack {
                Button("New Theme…", systemImage: "plus") {
                    editing = ThemeEdit(
                        theme: CustomThemes.copy(
                            of: chosen,
                            named: "My \(chosen.name)"
                        ),
                        isNew: true
                    )
                }
                .accessibilityIdentifier("themes-new")
                Button(
                    "Import from iTerm2…",
                    systemImage: "square.and.arrow.down"
                ) { importPresets() }
                .accessibilityIdentifier("themes-import")
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "A theme you make is kept in a file on this Mac, and goes into your backups. iTerm2 colour presets are .itermcolors files (iTerm2 ▸ Settings ▸ Profiles ▸ Colors ▸ Color Presets… ▸ Export)."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { edit in
            ThemeEditorSheet(
                theme: edit.theme,
                isNew: edit.isNew,
                appearance: appearance
            ) { app.saveCustomTheme($0) }
        }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "itermcolors") ?? .propertyList,
            .propertyList,
        ]
        panel.message = "Choose iTerm2 colour presets (.itermcolors)"
        guard panel.runModal() == .OK else { return }
        var imported = 0
        var problems: [String] = []
        for url in panel.urls {
            do {
                // A preset with separate light and dark colours brings in both.
                let themes = try ITermColors.themes(
                    from: Data(contentsOf: url),
                    name: url.deletingPathExtension().lastPathComponent
                )
                for theme in themes { app.saveCustomTheme(theme) }
                imported += themes.count
            } catch {
                problems.append(
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        notice =
            ([
                imported > 0
                    ? "Imported \(imported) theme\(imported == 1 ? "" : "s")."
                    : nil
            ] + problems).compactMap { $0 }.joined(separator: " ")
    }
}

/// The 16 colours of a theme as a row of small squares.
private struct Swatches: View {
    let theme: TerminalTheme
    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2).fill(
                theme.background.swiftUIColor
            ).frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 2).stroke(
                        .secondary.opacity(0.4)
                    )
                )
            ForEach(0..<8, id: \.self) {
                Rectangle().fill(theme.ansi[$0 + 8].swiftUIColor).frame(
                    width: 6,
                    height: 14
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Edits one theme: a name, light or dark, the four main colours and the sixteen, with a preview as it changes.
struct ThemeEditorSheet: View {
    @State var theme: TerminalTheme
    let isNew: Bool
    let appearance: (TerminalTheme) -> TerminalAppearance
    let onSave: (TerminalTheme) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    ]

    private func color(_ keyPath: WritableKeyPath<TerminalTheme, RGB>)
        -> Binding<Color>
    {
        Binding(
            get: { theme[keyPath: keyPath].swiftUIColor },
            set: { if let rgb = RGB($0) { theme[keyPath: keyPath] = rgb } }
        )
    }

    private func ansi(_ index: Int) -> Binding<Color> {
        Binding(
            get: { theme.ansi[index].swiftUIColor },
            set: { if let rgb = RGB($0) { theme.ansi[index] = rgb } }
        )
    }

    private var contrast: Double {
        theme.foreground.contrast(with: theme.background)
    }
    private var canSave: Bool {
        !theme.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $theme.name)
                        .accessibilityIdentifier("theme-name")
                    Toggle("A dark theme", isOn: $theme.isDark)
                        .help(
                            "Light or dark is only used to pair a theme with the system's appearance when that is on; a custom theme has no other version, so it stays as it is."
                        )
                }
                Section("Preview") {
                    ThemePreview(theme: theme, appearance: appearance(theme))
                }
                Section("Colours") {
                    ColorPicker("Background", selection: color(\.background))
                    ColorPicker("Text", selection: color(\.foreground))
                    ColorPicker("Cursor", selection: color(\.cursor))
                    ColorPicker("Selection", selection: color(\.selection))
                    if contrast < 4.5 {
                        Label(
                            "Text on the background has a contrast of \(contrast.formatted(.number.precision(.fractionLength(1)))) to 1; 4.5 or more reads comfortably.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption).foregroundStyle(Color.statusWarning)
                    }
                }
                Section("The 16 colours") {
                    ForEach([0, 8], id: \.self) { start in
                        HStack(spacing: 10) {
                            Text(start == 0 ? "Normal" : "Bright").font(
                                .caption
                            ).foregroundStyle(.secondary).frame(
                                width: 44,
                                alignment: .leading
                            )
                            ForEach(0..<8, id: \.self) { n in
                                ColorPicker(
                                    "\(start == 0 ? "" : "Bright ")\(Self.ansiNames[n])",
                                    selection: ansi(start + n)
                                )
                                .labelsHidden()
                                .accessibilityLabel(
                                    "\(start == 0 ? "" : "Bright ")\(Self.ansiNames[n])"
                                )
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button(isNew ? "Add" : "Save") {
                    theme.name = theme.name.trimmingCharacters(in: .whitespaces)
                    onSave(theme)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canSave)
                .accessibilityIdentifier("theme-save")
            }
            .padding(12)
        }
        .frame(width: 520, height: 700)
    }
}
