import SwiftUI
import SwiftData
import AppKit
import CerberusModels

// MARK: - Folder editor

/// Asks the folder editor to create a folder (under `parent`) or rename `folder`.
struct FolderEditorRequest: Identifiable {
    let id = UUID()
    var folder: TreeNode?
    var parent: TreeNode?
}

struct FolderEditorSheet: View {
    let request: FolderEditorRequest

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var name = ""
    /// The colour tag being chosen (nil: none of its own).
    @State private var colorTag: String?

    private var isRenaming: Bool { request.folder != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRenaming ? "Edit Folder" : (request.parent.map { "New Folder in \($0.name)" } ?? "New Folder"))
                .font(.title3.bold())
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Colour").font(.subheadline.weight(.medium))
            NodeColorPicker(tag: $colorTag, inherited: (request.folder?.parent ?? request.parent)?.effectiveColor)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRenaming ? "Save" : "Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = request.folder?.name ?? ""; colorTag = request.folder?.colorTag }
    }

    private func save() {
        guard canSave else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let folder = request.folder {
            folder.name = trimmed
            folder.colorTag = colorTag
        } else {
            modelContext.insert(TreeNode(name: trimmed, colorTag: colorTag, parent: request.parent))
        }
        modelContext.saveLogged()
        app.refreshNodeColors()
        dismiss()
    }
}

// MARK: - Menu commands

/// File and Session menu items with their shortcuts.
struct WorkspaceCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(ConnectionLogSettings.key) private var logLevel = 0
    @AppStorage(FileTabModel.copyOwnershipKey) private var copyOwnership = false
    @AppStorage(BehaviourSettings.hostOrderKey) private var hostOrder = HostSortOrder.default
    /// Set while the sidebar has the keyboard: what it can do with its selection (see ``SidebarActions``).
    @FocusedValue(\.sidebarActions) private var sidebar

    var body: some Commands {
        // Without this the Help menu offers only a search box and "Help isn't available".
        CommandGroup(replacing: .help) {
            Button("CerberusSSH Help", systemImage: "questionmark.circle") { openWindow(id: HelpWindow.id) }
                .keyboardShortcut(.help)
        }

        // The app menu's "About CerberusSSH": Settings ▸ About, with the libraries and the licences.
        CommandGroup(replacing: .appInfo) {
            Button("About CerberusSSH") { app.settingsTab = .about; openSettings() }
        }

        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Host…", systemImage: "plus") { app.newHostRequests += 1 }
                    .keyboardShortcut(.newHost)
                Button("New Folder…", systemImage: "folder.badge.plus") { app.newFolderRequests += 1 }
                    .keyboardShortcut(.newFolder)
                Button("Quick Connect…", systemImage: "magnifyingglass") { app.quickConnectRequests += 1 }
                    .keyboardShortcut(.quickConnect)
                Button("New Tab", systemImage: "plus.rectangle.on.rectangle") { app.quickConnectRequests += 1 }
                    .keyboardShortcut(.newTab)
            }
            .labelStyle(.titleAndIcon)
        }

        // The standard "Close" (⌘W) would close the window; here it closes a pane, and
        // a tab when that was its last pane.
        CommandGroup(replacing: .saveItem) {
            Group {
                Button("Close Pane", systemImage: "xmark") { Task { await app.closeFocusedPane() } }
                    .keyboardShortcut(.closePane)
            }
            .labelStyle(.titleAndIcon)
        }

        // What the sidebar does with the host or folder selected in it. The keys work only while the sidebar has
        // the keyboard; in a terminal ⌘D splits, as always.
        // What the sidebar does with the host or folder selected in it. The keys (⌘S ⇧⌘S ⌘E ⇧⌘D …) are handled by
        // ``SidebarKeyHandler`` while the sidebar has the keyboard, so these items carry no key of their own: one
        // would also fire from a terminal.
        CommandMenu("Host") {
            Group {
                Button("Connect", systemImage: "bolt.fill") { sidebar?.connect() }
                    .disabled(sidebar?.hasHosts != true)
                Button("SFTP", systemImage: "folder") { sidebar?.openSFTP() }
                    .disabled(sidebar?.canSFTP != true)
                Button("Edit…", systemImage: "pencil") { sidebar?.edit() }
                    .disabled(sidebar?.hasHosts != true)
                Button("Duplicate", systemImage: "plus.square.on.square") { sidebar?.duplicate() }
                    .disabled(sidebar?.hasHosts != true)
                Button(
                    SidebarActions.favouriteTitle(count: sidebar?.hostCount ?? 0, adds: sidebar?.addsFavourite ?? true),
                    systemImage: sidebar?.addsFavourite == false ? "star.slash" : "star"
                ) { sidebar?.toggleFavourite() }
                    .disabled(sidebar?.hasHosts != true)
                Button("Rename Folder…", systemImage: "pencil") { sidebar?.rename() }
                    .disabled(sidebar?.hasFolder != true)
                Divider()
                Button("Delete…", systemImage: "trash") { sidebar?.delete() }
                    .disabled(sidebar?.hasFolder != true && sidebar?.hostCount != 1)
                Divider()
                Picker("Sort Hosts By", systemImage: "arrow.up.arrow.down", selection: $hostOrder) {
                    HostSortOrderChoices()
                }
                .pickerStyle(.menu)
            }
            .labelStyle(.titleAndIcon)
        }

        // ⌘1…⌘9 switch tabs; ⌘9 is always the last one, as in browsers.
        CommandMenu("Tab") {
            Group {
                ForEach(1...9, id: \.self) { digit in
                    Button(digit == 9 ? "Last Tab" : "Tab \(digit)", systemImage: digit == 9 ? "arrow.right.to.line" : "\(digit).square") { app.selectTab(shortcutDigit: digit) }
                        .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command)
                }
                Divider()
                Button("Rename Tab…", systemImage: "pencil") { app.beginRenamingSelectedTab() }
                    .disabled(app.selectedTab == nil)
                Button("Move Tab to New Window", systemImage: "macwindow.on.rectangle") {
                    if let tab = app.selectedTab, let window = app.activeWindowID,
                       !(app.isTerminalWindow(window) && app.tabs(in: window).count < 2) {
                        openWindow(value: app.detachTab(tab.id))
                    }
                }
            }
            .labelStyle(.titleAndIcon)
        }

        CommandGroup(after: .sidebar) {
            Group {
                Button("Toggle Inspector", systemImage: "sidebar.right") {
                    if let window = app.activeWindowID { app.toggleInspector(in: window) }
                }
                .keyboardShortcut(.inspector)
                Divider()
                ForEach(SidebarTab.allCases) { tab in
                    Button(tab.title, systemImage: tab.symbol) {
                        if let window = app.activeWindowID {
                            app.sidebarTabRequest = SidebarTabRequest(tab: tab, window: window)
                        }
                    }
                    .disabled(app.activeWindowID.map { app.isTerminalWindow($0) } ?? true)
                }
            }
            .labelStyle(.titleAndIcon)
        }

        CommandMenu("Vault") {
            Group {
                Button("Export Vault Backup…", systemImage: "square.and.arrow.up") { app.isExportingBackup = true }
                    .keyboardShortcut(.exportBackup)
                Button("Import Vault Backup…", systemImage: "square.and.arrow.down") { app.isImportingBackup = true }
                Divider()
                Button("Import known_hosts…", systemImage: "checkmark.shield") { app.isImportingKnownHosts = true }
                Button("Import Hosts from ssh config…", systemImage: "doc.text") { app.isImportingSSHConfig = true }
                Button("Import Keys from ~/.ssh…", systemImage: "square.and.arrow.down.on.square") { app.isImportingSSHFolder = true }
                Divider()
                Button("Show Identities", systemImage: "person.badge.key") {
                    app.settingsTab = .identities
                    openSettings()
                }
                Button("Show Known Hosts", systemImage: "checkmark.shield") {
                    app.settingsTab = .knownHosts
                    openSettings()
                }
            }
            .labelStyle(.titleAndIcon)
        }

        // The same setting as Settings ▸ Connection. It applies to the next connection.
        CommandMenu("Debug") {
            Group {
                Picker("Connection Log Verbosity", systemImage: "list.bullet.rectangle", selection: $logLevel) {
                    Text("Off").tag(0)
                    Text("Basic (ssh -v)").tag(1)
                    Text("Detailed (ssh -vv)").tag(2)
                    Text("Debug (ssh -vvv)").tag(3)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Show Connection Log", systemImage: "list.bullet.rectangle") { app.isShowingConnectionLog = true }
                    .keyboardShortcut(.connectionLog)
                    .disabled(app.selectedSession == nil)
                Divider()
                Text("Verbosity applies to the next connection").disabled(true)
            }
            .labelStyle(.titleAndIcon)
        }

        // The settings people change on the fly; the rest stay in Settings (⌘,).
        CommandMenu("Terminal") {
            Group {
                Button("Increase Font Size", systemImage: "textformat.size.larger") { changeFont(by: 1) }
                    .keyboardShortcut(.biggerText)
                Button("Decrease Font Size", systemImage: "textformat.size.smaller") { changeFont(by: -1) }
                    .keyboardShortcut(.smallerText)
                Button("Reset Font Size", systemImage: "textformat.size") { app.changeSettings { $0.fontSize = 13 } }
                    .keyboardShortcut(.resetText)
                Divider()
                Picker("Theme", systemImage: "paintpalette", selection: Binding(
                    get: { app.settingsRecord?.defaultThemeID ?? ThemeCatalog.defaultID },
                    set: { id in app.changeSettings { $0.defaultThemeID = id } }
                )) {
                    ForEach(app.allThemes) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Picker("Cursor", systemImage: "character.cursor.ibeam", selection: Binding(
                    get: { app.settingsRecord?.cursorStyle ?? .blinkBlock },
                    set: { style in app.changeSettings { $0.cursorStyle = style } }
                )) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                Divider()
                Toggle("Confirm Multi-line Pastes", systemImage: "doc.on.clipboard", isOn: Binding(
                    get: { app.settingsRecord?.confirmMultilinePaste ?? true },
                    set: { value in app.changeSettings { $0.confirmMultilinePaste = value } }
                ))
                Toggle("Allow Remote Clipboard Writes", systemImage: "clipboard", isOn: Binding(
                    get: { app.settingsRecord?.allowRemoteClipboardWrite ?? false },
                    set: { value in app.changeSettings { $0.allowRemoteClipboardWrite = value } }
                ))
            }
            .labelStyle(.titleAndIcon)
        }

        // Find in the terminal's scrollback uses SwiftTerm's own find bar, reached through
        // the responder chain so it acts on whichever terminal has the keyboard.
        CommandGroup(after: .textEditing) {
            Group {
                Button("Find…", systemImage: "magnifyingglass") { Self.sendFindAction(.showFindPanel) }
                    .keyboardShortcut(.find)
                Button("Find Next", systemImage: "chevron.down") { Self.sendFindAction(.next) }
                    .keyboardShortcut(.findNext)
                Button("Find Previous", systemImage: "chevron.up") { Self.sendFindAction(.previous) }
                    .keyboardShortcut(.findPrevious)
            }
            .labelStyle(.titleAndIcon)
        }

        // Copying between a file tab's panes without dragging: the selection on one side goes to the other.
        CommandMenu("Files") {
            Group {
                Button("Copy Selection to the Right Pane", systemImage: "arrow.right.circle") {
                    if let files = app.selectedTab?.files { files.copy(files.left.selectedEntries, from: files.left, to: files.right) }
                }
                .keyboardShortcut(.copyToRightPane)
                .disabled(app.selectedTab?.files == nil)
                Button("Copy Selection to the Left Pane", systemImage: "arrow.left.circle") {
                    if let files = app.selectedTab?.files { files.copy(files.right.selectedEntries, from: files.right, to: files.left) }
                }
                .keyboardShortcut(.copyToLeftPane)
                .disabled(app.selectedTab?.files == nil)
                Button("Move Selection to the Right Pane", systemImage: "arrow.right.to.line") {
                    if let files = app.selectedTab?.files { files.copy(files.left.selectedEntries, from: files.left, to: files.right, moving: true) }
                }
                .keyboardShortcut(.moveToRightPane)
                .disabled(app.selectedTab?.files == nil)
                Button("Move Selection to the Left Pane", systemImage: "arrow.left.to.line") {
                    if let files = app.selectedTab?.files { files.copy(files.right.selectedEntries, from: files.right, to: files.left, moving: true) }
                }
                .keyboardShortcut(.moveToLeftPane)
                .disabled(app.selectedTab?.files == nil)
                Button("Go Up a Folder", systemImage: "arrow.up") {
                    // The focused pane is the one being worked in.
                    if let files = app.selectedTab?.files {
                        let pane = files.focusedPane
                        Task { await pane.goUp() }
                    }
                }
                .keyboardShortcut(.goUpFolder)
                .disabled(app.selectedTab?.files == nil)
                Divider()
                Toggle("Copy Ownership", isOn: $copyOwnership)
                    .help("Give copied files the owner and group they had. Only means something between places that share their users, and usually needs root at the destination.")
            }
            .labelStyle(.titleAndIcon)
        }

        CommandGroup(after: .newItem) {
            Button("Browse Files…", systemImage: "folder") { app.openFilesForSelectedSession() }
                .keyboardShortcut(.browseFiles)
                .disabled(app.selectedSession == nil)
                .labelStyle(.titleAndIcon)
        }

        CommandMenu("Session") {
            Group {
                Button("Split Right", systemImage: "rectangle.split.2x1") { split(.splitRight) }
                    .keyboardShortcut(.splitRight)
                Button("Split Left", systemImage: "rectangle.lefthalf.inset.filled.arrow.left") { split(.splitLeft) }
                Button("Split Down", systemImage: "rectangle.split.1x2") { split(.splitDown) }
                    .keyboardShortcut(.splitDown)
                Button("Split Up", systemImage: "rectangle.tophalf.inset.filled") { split(.splitUp) }
                Divider()
                Button("Move Pane to New Tab", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                    if let session = app.selectedSession { app.movePaneToTab(session) }
                }
                .keyboardShortcut(.movePaneToTab)
                .disabled(app.selectedSession.map { !app.canMovePaneToTab($0) } ?? true)
                // Same as File ▸ Browse Files… (⇧⌘S): the host of the pane that has the focus.
                Button("SFTP", systemImage: "folder") { app.openFilesForSelectedSession() }
                    .disabled(app.selectedSession == nil)
                Divider()
                Button("Rename Tab…", systemImage: "pencil") { app.beginRenamingSelectedTab() }
                    .disabled(app.selectedTab == nil)
                Button("Toggle Broadcast Input", systemImage: "dot.radiowaves.left.and.right") { app.toggleBroadcastForSelectedTab() }
                    .keyboardShortcut(.broadcast)
                Button("Insert Snippet…", systemImage: "text.badge.plus") { app.isShowingSnippets = true }
                    .keyboardShortcut(.snippets)
                Button("Manage Snippets…", systemImage: "slider.horizontal.3") {
                    app.settingsTab = .snippets
                    openSettings()
                }
                Divider()
                Button("Show Port Forwards", systemImage: "arrow.left.arrow.right") { openWindow(id: ForwardsWindowID.id) }
                    .keyboardShortcut(.portForwards)
                Button("Show Replay Log", systemImage: "play.rectangle") { app.isShowingReplayLog = true }
                    .keyboardShortcut(.replayLog)
                    .disabled(app.selectedSession == nil)
                Button("Show Recordings", systemImage: "record.circle") { openWindow(id: RecordingsWindow.id) }
                .keyboardShortcut(.sessionRecordings)
                Divider()
                Button("Select Pane on the Left", systemImage: "arrow.left.square") { app.moveFocus(toward: .left) }
                    .keyboardShortcut(.selectPaneLeft)
                Button("Select Pane on the Right", systemImage: "arrow.right.square") { app.moveFocus(toward: .right) }
                    .keyboardShortcut(.selectPaneRight)
                Button("Select Pane Above", systemImage: "arrow.up.square") { app.moveFocus(toward: .up) }
                    .keyboardShortcut(.selectPaneAbove)
                Button("Select Pane Below", systemImage: "arrow.down.square") { app.moveFocus(toward: .down) }
                    .keyboardShortcut(.selectPaneBelow)
                Button("Next Pane", systemImage: "chevron.right.square") { app.moveFocus(by: 1) }
                    .keyboardShortcut(.nextPane)
                Button("Previous Pane", systemImage: "chevron.left.square") { app.moveFocus(by: -1) }
                    .keyboardShortcut(.previousPane)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func changeFont(by delta: Double) {
        app.changeSettings { $0.fontSize = min(max($0.fontSize + delta, 9), 32) }
    }

    @MainActor
    private static func sendFindAction(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
    }

    private func split(_ placement: SessionPlacement) {
        guard let session = app.selectedSession else { return }
        Task { await app.duplicate(session, placement: placement) }
    }
}
