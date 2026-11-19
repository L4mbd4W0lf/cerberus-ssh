import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI
import SwiftUIIntrospect

/// The Settings window (⌘,): a sidebar of categories beside the one chosen. Backup and import,
/// the identity list, the trust store, connection logging, and a reset. Everything
/// that weakens trust or reveals a secret sits behind the biometric gate.
/// The Settings categories, so the app can open the window on a particular one.
enum SettingsTab: String, CaseIterable, Identifiable, Equatable {
    case backup, identities, keys, knownHosts, appearance, behaviour, snippets,
        recordings, connection, advanced, about

    var id: Self { self }

    var title: String {
        switch self {
        case .backup: "Backup"
        case .identities: "Identities"
        case .keys: "Keys"
        case .knownHosts: "Known Hosts"
        case .appearance: "Appearance"
        case .behaviour: "Behaviour"
        case .snippets: "Snippets"
        case .recordings: "Recordings"
        case .connection: "Connection"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .backup: "externaldrive"
        case .identities: "person.badge.key"
        case .keys: "key"
        case .knownHosts: "checkmark.shield"
        case .appearance: "paintpalette"
        case .behaviour: "switch.2"
        case .snippets: "text.badge.plus"
        case .recordings: "record.circle"
        case .connection: "network"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}

/// Keeps the Settings sidebar from being collapsed. SwiftUI sets the sidebar item's `canCollapse` back to `true` when
/// the chosen category changes (after a one-time lock has been made), so the lock is watched and put back each time.
@MainActor
private final class SidebarLock {
    private var observations: [NSKeyValueObservation] = []

    private static func forbidCollapsing(_ item: NSSplitViewItem) {
        if item.canCollapse { item.canCollapse = false }
        if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
    }

    func lock(_ item: NSSplitViewItem, width: CGFloat) {
        Self.forbidCollapsing(item)
        item.minimumThickness = width
        item.maximumThickness = width
        // AppKit changes these on the main thread, which is where the item lives.
        nonisolated(unsafe) let target = item
        let watch: @Sendable (NSSplitViewItem, NSKeyValueObservedChange<Bool>) -> Void = { _, _ in
            MainActor.assumeIsolated { SidebarLock.forbidCollapsing(target) }
        }
        observations = [
            item.observe(\.canCollapse, changeHandler: watch),
            item.observe(\.canCollapseFromWindowResize, changeHandler: watch),
        ]
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var sidebarLock = SidebarLock()
    /// The window opens with the keyboard in the sidebar, as System Settings does. Left to itself it went to the first
    /// control of the pane, which for About is a link, shown with a focus ring.
    @FocusState private var sidebarFocused: Bool

    private var sidebarWidth: CGFloat = 160
    /// The list wants an optional selection; there is always one category chosen.
    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { app.settingsTab },
            set: { if let tab = $0 { app.settingsTab = tab } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: selection) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
                    .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
            }
            .listStyle(.sidebar)
            .focused($sidebarFocused)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(sidebarWidth)
        } detail: {
            pane(app.settingsTab)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .introspect(.navigationSplitView, on: .macOS(.v26, .v27)) { splitView in
            lockSidebar(in: splitView)
        }
        .onChange(of: app.settingsTab) {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow,
                    let splitView = findSplitView(in: window.contentView)
                {
                    lockSidebar(in: splitView)
                }
            }
        }
        .frame(minWidth: 880, idealWidth: 880, minHeight: 600, idealHeight: 600)
        // After the window has given the pane the keyboard, which it does once it is shown.
        .task { await Task.yield(); sidebarFocused = true }
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .backup: BackupSettings()
        case .identities: IdentitiesSettings()
        case .keys: KeysSettings()
        case .knownHosts: KnownHostsSettings()
        case .appearance: AppearanceSettings()
        case .behaviour: BehaviourSettingsView()
        case .snippets: SnippetsSettings()
        case .recordings: RecordingsSettings()
        case .connection: ConnectionSettings()
        case .advanced: AdvancedSettings()
        case .about: AboutSettings()
        }
    }

    private func lockSidebar(in splitView: NSSplitView) {
        guard let delegate = splitView.delegate as? NSSplitViewController,
            let sidebarItem = delegate.splitViewItems.first
        else { return }
        sidebarLock.lock(sidebarItem, width: sidebarWidth)
    }

    private func findSplitView(in view: NSView?) -> NSSplitView? {
        if let splitView = view as? NSSplitView {
            return splitView
        }
        for subview in view?.subviews ?? [] {
            if let found = findSplitView(in: subview) {
                return found
            }
        }
        return nil
    }
}
