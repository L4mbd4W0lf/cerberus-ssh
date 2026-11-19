import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// How the app acts, as opposed to how it looks (Appearance) or what it stores. Settings that
/// do not belong anywhere else go here. They are kept in the user defaults.
enum BehaviourSettings {
    static let collapseSubfoldersKey = "collapseSubgroupsOnDoubleClick"
    static let hostOrderKey = "sidebarHostOrder"
    static let confirmClosingKey = "confirmClosingLiveTab"
    static let reopenWorkspaceKey = "reopenTabsAtLaunch"
    static let copyOnSelectKey = "copyTerminalSelection"

    static var defaultsOn: Bool { !UITesting.isActive }
    static var confirmsClosing: Bool {
        UserDefaults.standard.object(forKey: confirmClosingKey) as? Bool ?? defaultsOn
    }
    static var copiesOnSelect: Bool {
        UserDefaults.standard.object(forKey: copyOnSelectKey) as? Bool ?? true
    }
    static var reopensWorkspace: Bool {
        UserDefaults.standard.object(forKey: reopenWorkspaceKey) as? Bool ?? defaultsOn
    }
}

struct BehaviourSettingsView: View {
    @AppStorage(BehaviourSettings.collapseSubfoldersKey)
    private var collapsesSubfolders = true

    @AppStorage(BehaviourSettings.hostOrderKey)
    private var hostOrder = HostSortOrder.default

    @AppStorage(BehaviourSettings.confirmClosingKey)
    private var confirmsClosing = BehaviourSettings.defaultsOn

    @AppStorage(BehaviourSettings.reopenWorkspaceKey)
    private var reopensWorkspace = BehaviourSettings.defaultsOn

    @AppStorage(BehaviourSettings.copyOnSelectKey)
    private var copiesOnSelect = true

    @Environment(AppModel.self)
    private var app

    @Environment(\.modelContext)
    private var modelContext

    @Query private var allSettings: [AppSettings]
    /// Why a policy change did not happen, shown beside the control that snapped back.
    @State private var securityNote: String?

    /// Changing the policy is itself gated when the current one is protecting something, so
    /// that "Never" can't be reached by someone who couldn't have revealed a secret.
    private var policy: Binding<GatePolicy> {
        Binding(
            get: { allSettings.first?.gatePolicy ?? .default },
            set: { newValue in
                let old = allSettings.first?.gatePolicy ?? .default
                guard newValue != old else { return }
                Task {
                    if old.requiresGate(for: .editSecret),
                        !(await app.gate(
                            .editSecret,
                            reason:
                                "Change when CerberusSSH asks for authentication",
                            declined: $securityNote
                        ))
                    {
                        return
                    }
                    appSettings(in: modelContext).gatePolicy = newValue
                    modelContext.saveLogged()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Security") {
                Picker("Ask for Touch ID or password", selection: policy) {
                    ForEach(GatePolicy.allCases) { Text($0.title).tag($0) }
                }
                Text((allSettings.first?.gatePolicy ?? .default).explanation)
                    .font(.caption).foregroundStyle(.secondary)
                if let securityNote {
                    Text("\(securityNote) The setting was not changed.").font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
            }

            Section("Tabs and windows") {
                Toggle(
                    "Reopen tabs and windows when CerberusSSH starts",
                    isOn: $reopensWorkspace
                )
                .accessibilityIdentifier("behaviour-reopen")
                // Turned on, what is open now is remembered at once; turned off, what was remembered is forgotten.
                .onChange(of: reopensWorkspace) { app.saveWorkspace() }
                Text(
                    "The tabs, their names and splits, and the file tabs that were open when you quit come back, each connecting again. Closing a tab yourself takes it out of what is remembered."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Ask before closing a tab or window, or quitting, with live connections",
                    isOn: $confirmsClosing
                )
                .accessibilityIdentifier("behaviour-confirm-close")
                Text(
                    "Also asks when a file tab still has transfers running. Closing a tab is asked about when you close it; closing a window or quitting says how many connections will end."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Toggle("Copy text to the clipboard when it is selected", isOn: $copiesOnSelect)
                    .accessibilityIdentifier("behaviour-copy-on-select")
                Text(
                    "Selecting text with the mouse copies it, as in most terminals. Turn this off to copy only with ⌘C or the right-click menu."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Files") {
                TextEditorPicker()
                Text(
                    "A file tab's Edit opens files in this app, whatever kind of file they are, so a script is opened to be edited and never run."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Picker("Sort hosts and folders by", selection: $hostOrder) {
                    HostSortOrderChoices()
                }
                .accessibilityIdentifier("behaviour-host-order")
                Text(
                    hostOrder.explanation
                        + " Also in Host ▸ Sort Hosts By, and the ↑↓ button in the sidebar's filter."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Collapse subfolders too when double-clicking a folder",
                    isOn: $collapsesSubfolders
                )
                Text(
                    "Double-click a folder to close it. With this on, the folders inside it are closed as well, so opening it again shows them closed. With it off they stay as they were."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The app a file tab edits files in: the Mac's default for plain text, an app that says it edits text, or any app
/// picked with Other….
private struct TextEditorPicker: View {
    @AppStorage(TextEditorChoice.key) private var bundleID = ""
    @State private var candidates: [TextEditorChoice.App] = []
    private static let otherTag = "other…"

    /// Blank (the default) when the chosen app is no longer installed, so the picker always has a row to show.
    private var selection: Binding<String> {
        Binding(
            get: { bundleID.isEmpty || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil ? "" : bundleID },
            set: { if $0 == Self.otherTag { chooseOther() } else { bundleID = $0 } }
        )
    }

    /// The candidates, and the chosen app too when it was picked with Other… and is not one of them.
    private var shown: [TextEditorChoice.App] {
        guard !bundleID.isEmpty, !candidates.contains(where: { $0.bundleID == bundleID }), let current = TextEditorChoice.current,
              current.bundleID == bundleID else { return candidates }
        return candidates + [current]
    }

    var body: some View {
        Picker("Edit files with", selection: selection) {
            if let fallback = TextEditorChoice.systemDefault {
                row(fallback, title: "Default (\(fallback.name))").tag("")
            }
            Divider()
            ForEach(shown, id: \.bundleID) { row($0, title: $0.name).tag($0.bundleID) }
            Divider()
            Text("Other…").tag(Self.otherTag)
        }
        .accessibilityIdentifier("behaviour-text-editor")
        .onAppear { candidates = TextEditorChoice.candidates }
    }

    private func row(_ app: TextEditorChoice.App, title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: {
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                icon.size = NSSize(width: 16, height: 16)
                return icon
            }())
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app to edit files in."
        panel.begin { response in
            guard response == .OK, let url = panel.url, let app = TextEditorChoice.app(at: url) else { return }
            bundleID = app.bundleID
        }
    }
}
