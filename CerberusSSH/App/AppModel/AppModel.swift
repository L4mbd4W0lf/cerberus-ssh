import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// One tab: a layout of panes, each showing a session.
struct WorkspaceTab: Identifiable, Equatable {
    let id = UUID()
    /// The window this tab is shown in. Tabs can be dragged between windows.
    var windowID: UUID
    var layout: PaneLayout
    var focusedSessionID: UUID
    /// A name the user gave the tab; `nil` shows the focused session's title.
    var name: String?
    /// Set for a file tab (spec §9.6): two file panes instead of terminals. Its `layout` is a single
    /// leaf with the model's id, which no session has, so every terminal-only path skips it.
    var files: FileTabModel?
}

/// A close that asks first.
enum CloseRequest: Equatable {
    case tab(UUID)
    case pane(UUID)
}

/// Where a new session should appear.
enum SessionPlacement: Equatable {
    /// Always a new tab.
    case newTab
    /// Select an existing live session for the host if there is one, else a new tab.
    case focusExisting
    /// Beside / below the focused pane in the current tab.
    case splitRight, splitDown, splitLeft, splitUp
    /// A tab of its own in a new terminal window with this id (the caller opens the window, once the tab is there).
    case newWindow(UUID)
}

/// Owns the live sessions, how they are arranged in tabs and splits, and the
/// services they depend on.
///
/// The behaviour is split by topic into `AppModel+Tabs`, `+Broadcast`, `+Connecting`, `+Closing`,
/// `+Forwards`, `+Security` and `+Settings`. Swift cannot share `private` state between files, so
/// the stored properties below are internal: views read them and change them only through methods.
@MainActor
@Observable
final class AppModel {
    let vault: Vault
    var sessions: [SessionViewModel] = []
    /// Connections that only carry port forwards, by host: no terminal and no tab.
    var tunnels: [SessionViewModel] = []
    /// Connections that file tabs own (spec §9.6): one per host pane, with no terminal and no tab of their own.
    var fileConnections: [SessionViewModel] = []
    /// Forwards that are being started on a tunnel that is still connecting.
    var startingForwards: Set<UUID> = []
    /// Why the last attempt to start a forward without a shell failed, by forward.
    var forwardFailures: [UUID: String] = [:]
    var tabs: [WorkspaceTab] = []
    /// The window the user is working in, which new sessions and menu commands target.
    var activeWindowID: UUID?
    /// Windows whose inspector panel is open.
    var inspectorWindows: Set<UUID> = []
    /// Windows made by pulling a tab out. They show only terminals: no sidebar, no inspector.
    var terminalWindows: Set<UUID> = []
    /// Where a new terminal window should appear, by window id, until it has.
    var pendingWindowOrigins: [UUID: CGPoint] = [:]
    /// Where each window is (kept up to date by the windows), and where a window being brought back should go.
    var windowFrames: [UUID: CGRect] = [:]
    var pendingWindowFrames: [UUID: CGRect] = [:]
    /// The tab whose name is being edited, if any (set by the Rename Tab command and the tab's
    /// menu; the tab bar shows the field).
    var renamingTabID: UUID?
    /// The tab being dragged, for drop targets to read (the drag itself carries no data
    /// other apps can see, so nothing can be pasted or dropped on the desktop).
    var draggingTabID: UUID?
    /// The session of a pane being dragged out of its tab by its grip (see ``beginPaneDrag``).
    var draggingPaneID: UUID?
    var tabDropWasHandled = false
    var dragTracker: Task<Void, Never>?
    /// Each window's selected tab.
    var selectedTabIDs: [UUID: UUID] = [:]
    var lastError: String?

    /// Presented from menu commands, so the commands need somewhere to flip a flag.
    var isExportingBackup = false
    var isImportingBackup = false
    var isImportingKnownHosts = false
    var isImportingSSHFolder = false
    var isImportingSSHConfig = false
    /// An automatic backup is being written (spec §6.6).
    var isAutoBackupRunning = false
    @ObservationIgnored var autoBackupTask: Task<Void, Never>?
    /// Bumped by a UI test's reset so every view starts afresh (always 0 in a real run).
    var uiTestEpoch = 0
    /// The first-launch import offer is considered once per run of the app, not each time a view starts.
    var didCheckFirstLaunchOffer = false
    /// The tabs of the last run have been brought back (or there was nothing to bring), so what is open may be saved.
    @ObservationIgnored var workspaceSaveTask: Task<Void, Never>?
    var didRestoreWorkspace = false
    /// The last connection log of each host whose session has been closed (kept for this run only).
    var lastConnectionLogs: [UUID: SavedConnectionLog] = [:]
    /// The app is on its way out: what closes now is not something the person closed, so it is not forgotten.
    var isQuitting = false
    /// Themes the person made or imported (see ``CustomThemes``), kept in a file of this Mac.
    var customThemes = AppModel.loadCustomThemes()
    var restoreInProgress = false
    /// Counts of asks to put the keyboard in the toolbar's quick connect field (⌘K, ⌘T, the Welcome page, the tab bar's +):
    /// the window the user is working in answers each one.
    var quickConnectRequests = 0
    /// Counts of File ▸ New Host (⌘N) and New Folder (⇧⌘N); the window the user is working in answers each one
    /// (a counter rather than a flag, so a request made while no window is active is not left waiting).
    var newHostRequests = 0
    var newFolderRequests = 0
    /// A close that is waiting for the person to say yes (see `requestClose`), and the window to ask in.
    var closeRequest: CloseRequest?
    var closeRequestWindow: UUID?
    var isShowingConnectionLog = false
    var isShowingReplayLog = false
    /// A sidebar tab chosen in the View menu, for that window to show (and then clear).
    var sidebarTabRequest: SidebarTabRequest?
    /// Shows an error to the user and puts it in the log.
    func report(_ message: String) {
        lastError = message
        CerberusLog.error("app", message)
    }

    /// Which page the Help window shows; set before opening it to land on one.
    var helpPage = HelpPage.shortcuts
    /// Which Settings tab is showing; set before opening Settings to land on one.
    var settingsTab = SettingsTab.backup
    var isShowingSnippets = false

    /// Tabs that are broadcasting, and which of their panes take part. A tab with no entry
    /// is not broadcasting (spec §8.5).
    var broadcastSets: [UUID: Set<UUID>] = [:]

    var hostKeyStore: (any HostKeyStore)?
    var context: ModelContext?
    var isVaultReady = false

    init(vault: Vault) {
        self.vault = vault
    }

    /// The most recent approval, so a jump chain asks once rather than once per hop.
    var lastGateApproval: Date?

    /// Where a backup passphrase is kept, if the user chose to remember one (spec §6.6).
    let exportPassphrases: any ExportPassphraseStore = UITesting.isActive ? InMemoryExportPassphraseStore() : KeychainExportPassphraseStore()

    /// Binds the model to the window's store. Called once, from the root view.
    func configure(context: ModelContext) {
        guard hostKeyStore == nil else { return }
        self.context = context
        hostKeyStore = SwiftDataHostKeyStore(context: context)
        let mended = TreeNode.repairMissingNodes(in: context)
        if mended > 0 { CerberusLog.info("store", "gave \(mended) host(s) with no place in the tree a node at the top level") }
        repairIdentityNames()
        applyRecordingRetention()

        Task {
            do {
                try await vault.prepare()
                isVaultReady = true
                if UITesting.isActive {
                    let scenario = UITesting.launchScenario
                    await UITesting.populate(context: context, vault: vault, scenario: scenario)
                    // A test can hand the remembered backup passphrase over, and the schedule runs
                    // as it would for a person (it does nothing unless the test enabled it).
                    if let passphrase = scenario.backupPassphrase { try? exportPassphrases.save(passphrase) }
                    await uiTestConnect(scenario.connect)
                    #if PERFGATE
                    if let plan = scenario.perf { Task { await PerfGate.run(plan, app: self) } }
                    #endif
                    startAutoBackupSchedule()
                    UITestControl.start(app: self)
                    return
                }
                startAutoBackupSchedule()
                // What this particular build may do with the Keychain depends on how it was signed.
                let keychain = KeychainCheck.run()
                CerberusLog.info("vault", "Keychain: device-only \(keychain.deviceOnly.detail); synchronizable \(keychain.synchronizable.detail); data key present: \(keychain.dataKeyPresent)")
            } catch {
                CerberusLog.caught(error)
                report(describe(error))
            }
        }
    }

    // MARK: Windows and selection

    /// Every workspace window that has been key. ⌘W uses it to tell a workspace from Settings, Help and the like.
    @ObservationIgnored private let workspaceWindows = NSHashTable<NSWindow>.weakObjects()

    func windowBecameActive(_ id: UUID, in window: NSWindow) {
        activeWindowID = id
        workspaceWindows.add(window)
        installCloseKeyMonitor()
    }

    @ObservationIgnored private var closeKeyMonitor: Any?

    /// ⌘W is taken before the menu sees it. The system's own Close item (⌘W) would close the workspace window
    /// whichever way the commands are arranged, so in a workspace window the key goes to Close Pane instead.
    private func installCloseKeyMonitor() {
        guard closeKeyMonitor == nil else { return }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window, AppShortcut.closePane.matches(event),
                  self.isWorkspaceWindow(window) else { return event }
            Task { await self.closeFocusedPane() }
            return nil
        }
    }

    func isWorkspaceWindow(_ window: NSWindow) -> Bool { workspaceWindows.contains(window) }

    func toggleInspector(in window: UUID) {
        if inspectorWindows.contains(window) { inspectorWindows.remove(window) } else { inspectorWindows.insert(window) }
    }

    func tabs(in window: UUID) -> [WorkspaceTab] { tabs.filter { $0.windowID == window } }

    /// The window's selected tab, falling back to its first when the recorded one is gone.
    func selectedTabID(in window: UUID) -> UUID? {
        let mine = tabs(in: window)
        if let id = selectedTabIDs[window], mine.contains(where: { $0.id == id }) { return id }
        return mine.first?.id
    }

    func selectedTab(in window: UUID) -> WorkspaceTab? {
        selectedTabID(in: window).flatMap { id in tabs.first { $0.id == id } }
    }

    /// The selected tab of the active window.
    var selectedTab: WorkspaceTab? { activeWindowID.flatMap { selectedTab(in: $0) } }

    /// The focused pane of the active window's selected tab.
    var selectedSession: SessionViewModel? {
        selectedTab.flatMap { tab in sessions.first { $0.id == tab.focusedSessionID } }
    }

    func session(withID id: UUID) -> SessionViewModel? { sessions.first { $0.id == id } }

    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabIDs[tab.windowID] = id
    }

    /// ⌘1…⌘9 in the active window.
    func selectTab(shortcutDigit digit: Int) {
        guard let window = activeWindowID else { return }
        let mine = tabs(in: window)
        if let index = TabShortcut.index(forDigit: digit, tabCount: mine.count) { selectTab(mine[index].id) }
    }

    /// Focuses `session`, switching to the tab that holds it. Used when the user asks
    /// for a session explicitly (the sidebar, a new connection); terminal clicks go
    /// through ``focusWithinSelectedTab(_:in:)`` instead.
    func focus(_ session: SessionViewModel) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(session.id) }) else { return }
        tabs[index].focusedSessionID = session.id
        selectedTabIDs[tabs[index].windowID] = tabs[index].id
    }

    /// Focuses a pane in response to a click, without ever changing tabs.
    func focusWithinSelectedTab(_ session: SessionViewModel, in window: UUID) {
        guard let selected = selectedTabID(in: window),
              let index = tabs.firstIndex(where: { $0.id == selected }),
              tabs[index].layout.contains(session.id) else { return }
        tabs[index].focusedSessionID = session.id
    }

    /// Moves focus through the panes of the active window's selected tab (⌘⌥←/→).
    func moveFocus(by offset: Int) {
        if let files = selectedTab?.files { files.cycleFocus(); return }
        guard let tab = selectedTab,
              let next = tab.layout.neighbor(of: tab.focusedSessionID, offset: offset),
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].focusedSessionID = next
    }

    /// Moves the focus to the pane that lies in `direction` from the focused one, if there is one.
    func moveFocus(toward direction: PaneLayout.Direction) {
        if let files = selectedTab?.files { files.moveFocus(toward: direction); return }
        guard let tab = selectedTab,
              let next = tab.layout.neighbor(of: tab.focusedSessionID, toward: direction),
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].focusedSessionID = next
    }

    func setSplitRatio(_ ratio: Double, split: UUID, in tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].layout = tabs[index].layout.settingRatio(ratio, forSplit: split)
    }

    /// The tab holding `session`.
    func tab(containing session: SessionViewModel) -> WorkspaceTab? {
        tabs.first { $0.layout.contains(session.id) }
    }
}
