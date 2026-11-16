import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

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
