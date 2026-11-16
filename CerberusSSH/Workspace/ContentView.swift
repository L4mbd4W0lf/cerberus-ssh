import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault
import CerberusSSHCore


struct ContentView: View {
    let windowID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]
    @Query private var nodes: [TreeNode]

    @State private var sidebarSelections: [SidebarTab: Set<UUID>] = [:]
    @State private var sidebarKeys = SidebarKeyHandler()
    @State private var fileKeys = FileTabKeyHandler()
    @State private var isBulkEditing = false
    @State private var editingHost: SSHHost?
    /// A new host being added. Carries the folder it starts in (from a folder's menu), so
    /// the choice arrives with the sheet rather than through separate state.
    @State private var newHost: NewHostRequest?
    @State private var searchText = ""
    @State private var sidebarTab: SidebarTab = .hosts
    @State private var sidebarTabPicked = false
    @State private var sidebarRestoresFocus = false
    @State private var hostPendingDeletion: SSHHost?
    @State private var logSession: SessionViewModel?
    @State private var savedLog: SavedConnectionLog?

    /// Which folders are collapsed, kept in the user defaults so the sidebar opens as it was
    /// left, and shared by every window.
    @AppStorage("sidebarCollapsedGroups") private var collapsedStorage = ""
    @AppStorage(BehaviourSettings.hostOrderKey) private var hostOrder = HostSortOrder.default
    private var collapsedFolders: Binding<Set<UUID>> {
        Binding(
            get: { CollapsedFolders.decode(collapsedStorage) },
            set: { collapsedStorage = CollapsedFolders.encode($0) }
        )
    }
    /// The toolbar's quick connect field: what is typed, which match is chosen, and whether the keyboard is in it.
    @State private var quickQuery = ""
    @State private var quickSelection = 0
    @State private var isOverQuickDropdown = false
    @State private var quickConnectFocused = false
    @State private var quickFocusToken = 0
    @State private var quickBlurToken = 0
    @State private var folderEditor: FolderEditorRequest?
    @State private var folderPendingDeletion: TreeNode?
    /// A dragged row is over the empty space below the tree (Custom Order).
    @State private var isTargetedAtRoot = false
    @State private var dropIndicator = SidebarDropIndicator()

    var body: some View {
        @Bindable var app = app

        Group {
            if isTerminalWindow {
                // A window made by pulling a tab out: just terminals, with split panes.
                detail
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
                } detail: {
                    detail
                }
            }
        }
        .environment(\.windowID, windowID)
        .background(WindowObserver(
            onKey: { app.windowBecameActive(windowID, in: $0) },
            onClose: { Task { await app.closeWindow(windowID) } },
            origin: app.pendingWindowOrigins[windowID],
            onPlaced: { app.pendingWindowOrigins[windowID] = nil },
            closeQuestion: { app.windowCloseQuestion(windowID) },
            onFrame: { app.windowFrames[windowID] = $0 },
            requestedFrame: app.pendingWindowFrames[windowID],
            onFramePlaced: { app.pendingWindowFrames[windowID] = nil }
        ))
        // A terminal window with nothing left in it has no reason to stay.
        .onChange(of: windowTabs.isEmpty) { _, isEmpty in
            if isEmpty && isTerminalWindow { dismissWindow(value: windowID) }
        }
        .inspector(isPresented: inspectorBinding) {
            HostInspector(
                hosts: selectedHosts,
                onEdit: { editingHost = $0 },
                onConnect: { connect($0) },
                onBulkEdit: { isBulkEditing = true }
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .modifier(WorkspaceMemory(windowID: windowID, isTerminalWindow: isTerminalWindow))
        .task {
            app.configure(context: modelContext)
            // A fresh install with an existing ~/.ssh: offer to bring it in, once.
            let offer = !app.didCheckFirstLaunchOffer && FirstLaunchImport.shouldOffer(context: modelContext)
            app.didCheckFirstLaunchOffer = true
            let found = SSHDirectoryScan.scan(SSHDirectoryScan.defaultDirectory)
            CerberusLog.info("import", "first-launch import offer: \(offer) (\(SSHDirectoryScan.defaultDirectory.path): \(found.keys.count) keys, known_hosts \(found.knownHostsURL != nil))")
            if offer {
                FirstLaunchImport.markOffered()
                app.isImportingSSHFolder = true
            }
        }
        // Questions from connections that have no terminal pane to ask in.
        .background {
            if app.activeWindowID == windowID {
                ForEach(app.tunnels + app.fileConnections) { TunnelPromptHost(session: $0) }
            }
        }
        // Forget folders that were deleted, so the saved list does not grow for ever.
        .onChange(of: folders.map(\.id)) { _, ids in
            let current = CollapsedFolders.decode(collapsedStorage)
            let kept = CollapsedFolders.pruned(current, keeping: Set(ids))
            if kept != current { collapsedStorage = CollapsedFolders.encode(kept) }
        }
        // File ▸ New Host (⌘N) and New Folder (⇧⌘N), from whichever window the user is in and wherever the keyboard is.
        .onChange(of: app.newHostRequests) {
            guard app.activeWindowID == windowID else { return }
            newHost = NewHostRequest(folderID: selectedFolder?.id)
        }
        .onChange(of: app.quickConnectRequests) {
            guard app.activeWindowID == windowID else { return }
            quickQuery = ""
            quickSelection = 0
            quickFocusToken += 1
        }
        .onChange(of: app.newFolderRequests) {
            guard app.activeWindowID == windowID else { return }
            folderEditor = .init(folder: nil, parent: selectedFolder)
        }
        .sheet(item: $logSession) { ConnectionLogSheet(session: $0) }
        .sheet(item: $savedLog) { SavedConnectionLogSheet(log: $0) }
        // App-level sheets belong to the window the user is in, not to every window.
        .sheet(isPresented: activeOnly($app.isExportingBackup)) { ExportBackupSheet() }
        .sheet(isPresented: activeOnly($app.isImportingBackup)) { ImportBackupSheet() }
        .sheet(isPresented: activeOnly($app.isImportingKnownHosts)) { KnownHostsSheet() }
        .sheet(isPresented: activeOnly($app.isImportingSSHFolder)) { ImportFromSSHFolderSheet() }
        .sheet(isPresented: activeOnly($app.isImportingSSHConfig)) { ImportSSHConfigSheet() }
        .sheet(isPresented: activeOnly($app.isShowingSnippets)) { SnippetPalette() }
        // Replay Log opens the focused host's latest recording in its own window, or the list when it has none.
        .onChange(of: app.isShowingReplayLog) { _, shown in
            guard shown, app.activeWindowID == windowID else { return }
            app.isShowingReplayLog = false
            if let session = windowSession, let latest = RecordingViewerWindow.latest(for: session.hostID) {
                openWindow(id: RecordingViewerWindow.id, value: latest.url)
            } else {
                openWindow(id: RecordingsWindow.id)
            }
        }
        .sheet(isPresented: activeOnly($app.isShowingConnectionLog)) {
            if let session = windowSession { ConnectionLogSheet(session: session) }
        }
        .sheet(isPresented: $isBulkEditing) { BulkEditSheet(hosts: selectedHosts) }
        .sheet(item: $newHost) { HostEditorView(host: nil, initialFolderID: $0.folderID) }
        .sheet(item: $editingHost) { HostEditorView(host: $0) }
        .sheet(item: $folderEditor) { FolderEditorSheet(request: $0) }
        .confirmationDialog(
            "Delete this host?",
            isPresented: Binding(get: { hostPendingDeletion != nil }, set: { if !$0 { hostPendingDeletion = nil } }),
            presenting: hostPendingDeletion
        ) { host in
            Button("Delete \(host.displayLabel)", role: .destructive) { delete(host) }
        } message: { _ in
            Text("Its saved login stays in Settings ▸ Identities, marked if no other host uses it.")
        }
        // Closing a tab or pane with a live connection asks first (Settings ▸ Behaviour); the window it is in asks.
        .confirmationDialog(
            app.closeQuestion()?.title ?? "Close?",
            isPresented: Binding(
                get: { app.closeRequest != nil && app.closeRequestWindow == windowID },
                set: { if !$0 { app.closeRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) { app.confirmClose() }
                .accessibilityIdentifier("confirm-close-yes")
            Button("Cancel", role: .cancel) { app.closeRequest = nil }
        } message: {
            Text(app.closeQuestion()?.message ?? "")
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(get: { folderPendingDeletion != nil }, set: { if !$0 { folderPendingDeletion = nil } }),
            presenting: folderPendingDeletion
        ) { folder in
            Button("Delete \(folder.name)", role: .destructive) { delete(folder) }
        } message: { _ in
            Text("Hosts inside move up one level. Subfolders are deleted, and their hosts move up as well.")
        }
        .alert(
            "Could not connect",
            isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }

    /// `flag`, but only true in the window the user is working in.
    private func activeOnly(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { flag.wrappedValue && app.activeWindowID == windowID },
            set: { flag.wrappedValue = $0 }
        )
    }

    private var isTerminalWindow: Bool { app.isTerminalWindow(windowID) }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { !isTerminalWindow && app.inspectorWindows.contains(windowID) },
            set: { shown in
                if shown != app.inspectorWindows.contains(windowID) { app.toggleInspector(in: windowID) }
            }
        )
    }

    private var selectedHostIDs: Set<UUID> {
        get { sidebarSelections[sidebarTab, default: []] }
        nonmutating set { sidebarSelections[sidebarTab] = newValue }
    }

    /// The selected hosts that are still in the store. The query can lag behind a delete (Erase All Data, say),
    /// and reading a host that is gone crashes, so what the store no longer holds is left out first.
    private var selectedHosts: [SSHHost] {
        let live = Set((try? modelContext.fetchIdentifiers(FetchDescriptor<SSHHost>())) ?? [])
        return hosts.filter { live.contains($0.persistentModelID) && selectedHostIDs.contains($0.id) }
    }

    // MARK: Sidebar

    private func sidebarSelection(for tab: SidebarTab) -> Binding<Set<UUID>> {
        Binding(
            get: { sidebarSelections[tab, default: []] },
            set: { ids in
                // A retiring outline must not clear the selection saved for its tab.
                guard sidebarTab == tab else { return }
                sidebarSelections[tab] = ids
            }
        )
    }

    /// The folders: the nodes with no host.
    private var folders: [TreeNode] { nodes.filter(\.isFolder) }

    /// The folder selected in the Hosts tab, if any: where a new host or folder goes. None means the top level.
    private var selectedFolder: TreeNode? {
        let ids = sidebarSelections[.hosts, default: []]
        return folders.first { ids.contains($0.id) }
    }

    private var searchQuery: SidebarSearch.Query { SidebarSearch.parse(searchText) }

    private func matchesHost(_ host: SSHHost, query: SidebarSearch.Query) -> Bool {
        SidebarSearch.matches(query, .init(
            name: host.displayLabel, hostname: host.hostname, username: host.loginUsername ?? "",
            folderPath: host.folderPath, tags: host.tags, notes: host.notes ?? ""
        ))
    }

    private var tree: [NodeTree.Row] {
        let query = searchQuery
        return NodeTree.build(
            nodes: nodes,
            showsHost: { query.isEmpty || matchesHost($0, query: query) },
            hidesEmptyFolders: !query.isEmpty, order: hostOrder
        )
    }

    private var favouriteHosts: [SSHHost] {
        hosts
            .filter(\.isFavourite)
            .sorted {
                let comparison = $0.displayLabel.localizedStandardCompare($1.displayLabel)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }
    }

    private var catalogueIDs: Set<UUID> {
        Set(hosts.map(\.id)).union(folders.map(\.id))
    }

    private var favouriteIDs: Set<UUID> {
        Set(hosts.filter(\.isFavourite).map(\.id))
    }

    private var forwardIDs: Set<UUID> {
        Set(forwardEntries.map(\.forward.id))
    }

    /// Every forward that is switched on, by host name, kind and port. A host or forward the store no longer
    /// holds is left out: the query can lag behind a delete, and reading a deleted model crashes. Its identifier
    /// is checked against the store, because that is safe to read where its properties are not.
    private var forwardEntries: [(host: SSHHost, forward: PortForward)] {
        let liveHosts = Set((try? modelContext.fetchIdentifiers(FetchDescriptor<SSHHost>())) ?? [])
        let liveForwards = Set((try? modelContext.fetchIdentifiers(FetchDescriptor<PortForward>())) ?? [])
        return hosts
            .filter { liveHosts.contains($0.persistentModelID) }
            .flatMap { host -> [(host: SSHHost, forward: PortForward)] in
                (host.portForwards ?? [])
                    .filter { liveForwards.contains($0.persistentModelID) }
                    .map { (host: host, forward: $0) }
            }
            .filter { $0.forward.isEnabled }
            .sorted { ($0.host.displayLabel, $0.forward.kindRawValue, $0.forward.bindPort) < ($1.host.displayLabel, $1.forward.kindRawValue, $1.forward.bindPort) }
    }

    private var sidebar: some View {
        sidebarList
            .safeAreaInset(edge: .top, spacing: 0) {
                SidebarTabBar(selection: Binding(get: { sidebarTab }, set: { pickSidebarTab($0) }))
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if sidebarTab == .hosts {
                    SidebarBottomBar(
                        filter: $searchText,
                        order: $hostOrder,
                        onNewHost: { newHost = NewHostRequest(folderID: nil) },
                        onNewFolder: { folderEditor = .init(folder: nil, parent: nil) }
                    )
                }
            }
            .onChange(of: catalogueIDs, initial: true) { old, new in
                sidebarSelections[.hosts, default: []].formIntersection(new)
                // Folders can arrive before hosts. Choose the initial tab before treating later
                // additions as newly created items, regardless of @Query delivery order.
                guard sidebarTab != .hosts, app.activeWindowID == windowID else { return }
                let added = new.subtracting(old)
                if !added.isEmpty { revealCreatedItems(added) }
            }
            // Reordering rebuilds the rows; a host kept selected across it stops answering edits.
            .onChange(of: hostOrder) { sidebarSelections.removeAll() }
            .onChange(of: favouriteIDs) { _, ids in
                sidebarSelections[.favourites, default: []].formIntersection(ids)
            }
            .onChange(of: forwardIDs) { _, ids in
                sidebarSelections[.forwards, default: []].formIntersection(ids)
            }
            .onChange(of: app.sidebarTabRequest, initial: true) { _, request in
                guard let request, request.window == windowID else { return }
                app.sidebarTabRequest = nil
                pickSidebarTab(request.tab)
            }
    }

    private var sidebarList: some View {
        List(selection: sidebarSelection(for: sidebarTab)) {
            sidebarRows
        }
        .listStyle(.sidebar)
        // Compact rows, so the list reads like a file browser.
        .environment(\.sidebarRowSize, .small)
        // The empty space below the rows takes a dragged row to the end of the top level.
        .onDrop(of: [.sidebarNode], delegate: RootDropDelegate(reordering: reordering, isTargeted: $isTargetedAtRoot))
        .overlay { sidebarEmptyState }
        .focusedValue(\.sidebarActions, sidebarActions)
        .background(SidebarMarker(restoreKeyboardFocus: $sidebarRestoresFocus))
        .onChange(of: selectedHostIDs, initial: true) { sidebarKeys.actions = sidebarActions }
        .onAppear {
            sidebarKeys.install()
            fileKeys.currentTab = { [app, windowID] in app.selectedTab(in: windowID)?.files }
            fileKeys.install()
        }
        .background(WindowAccessor { sidebarKeys.window = $0; fileKeys.window = $0 })
        .onChange(of: hosts.count) { sidebarKeys.actions = sidebarActions }
        .contextMenu(forSelectionType: UUID.self) { ids in
            sidebarContextMenu(ids)
        } primaryAction: { ids in
            for host in hosts where ids.contains(host.id) { connect(host) }
        }
        // Reusing the outline across tree/flat content can leave old disclosure rows drawn after
        // a multi-selection tab switch. Recreate it and its marker, not the shared controls or state.
        .id(sidebarTab)
    }

    @ViewBuilder
    private var sidebarRows: some View {
        switch sidebarTab {
        case .favourites:
            FavouriteRows(hosts: favouriteHosts, selection: selectedHostIDs, sessions: app.sessions)
        case .hosts:
            NodeRows(
                rows: tree,
                selection: selectedHostIDs,
                // While searching, every folder with a match is open.
                collapsed: searchQuery.isEmpty ? collapsedFolders : .constant([]),
                sessions: app.sessions,
                reordering: reordering
            )
            if isTargetedAtRoot && reordering != nil {
                DropIndicatorLine()
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
            }
        case .forwards:
            SidebarForwardRows(entries: forwardEntries, selection: selectedHostIDs) { editingHost = $0 }
        }
    }

    private func sidebarContextMenu(_ ids: Set<UUID>) -> some View {
        let chosen = hosts.filter { ids.contains($0.id) }
        let chosenFolders = folders.filter { ids.contains($0.id) }
        return Group {
            if ids.isEmpty {
                Button("New Host…", systemImage: "plus") { newHost = NewHostRequest(folderID: nil) }
                Button("New Folder…", systemImage: "folder.badge.plus") { folderEditor = .init(folder: nil, parent: nil) }
            } else if chosen.isEmpty, chosenFolders.count == 1, let folder = chosenFolders.first {
                Button("New Host", systemImage: "plus") { newHost = NewHostRequest(folderID: folder.id) }
                    .keyboardShortcut(.newHost)
                Button("New Subfolder…", systemImage: "folder.badge.plus") { folderEditor = .init(folder: nil, parent: folder) }
                    .keyboardShortcut(.newFolder)
                Button("Rename…", systemImage: "pencil") { folderEditor = .init(folder: folder, parent: nil) }
                    .keyboardShortcut(.sidebarRename)
                moveMenu(hosts: [], folders: [folder])
                Menu("Colour", systemImage: "paintpalette") {
                    Button("None") { setColor(nil, of: folder) }
                    Divider()
                    ForEach(NodeColor.allCases, id: \.self) { color in
                        Button(color.displayName) { setColor(color, of: folder) }
                    }
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { folderPendingDeletion = folder }
                    .keyboardShortcut(.sidebarDelete)
            } else if !chosenFolders.isEmpty {
                // Several folders, or folders and hosts together: all that applies to the lot is moving them.
                moveMenu(hosts: chosen, folders: chosenFolders)
            } else if chosen.count > 1 {
                Button("Connect \(chosen.count) Hosts", systemImage: "bolt.fill") { chosen.forEach(connect) }
                    .keyboardShortcut(.sidebarConnect)
                if chosen.count == 2 {
                    Button("SFTP \(chosen.count)", systemImage: "folder.badge.gearshape") { app.openFiles(for: chosen) }
                        .keyboardShortcut(.sidebarSFTP)
                }
                Button("Edit \(chosen.count) Hosts…", systemImage: "pencil") { selectedHostIDs = ids; isBulkEditing = true }
                    .keyboardShortcut(.sidebarEdit)
                Button("Duplicate \(chosen.count) Hosts", systemImage: "plus.square.on.square") { duplicate(chosen) }
                    .keyboardShortcut(.sidebarDuplicate)
                moveMenu(hosts: chosen, folders: [])
                favouriteButton(chosen)
            } else if let host = chosen.first {
                Button("Connect", systemImage: "bolt.fill") { connect(host) }
                    .keyboardShortcut(.sidebarConnect)
                Button("SFTP", systemImage: "folder") { app.openFiles(for: [host]) }
                    .keyboardShortcut(.sidebarSFTP)
                Button("Edit…", systemImage: "pencil") { editingHost = host }
                    .keyboardShortcut(.sidebarEdit)
                // A host with no open session can still say how its last connection went.
                if let log = app.lastConnectionLogs[host.id], !app.sessions.contains(where: { $0.hostID == host.id }) {
                    Button("Show Last Connection Log", systemImage: "list.bullet.rectangle") { savedLog = log }
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate([host]) }
                    .keyboardShortcut(.sidebarDuplicate)
                moveMenu(hosts: [host], folders: [])
                favouriteButton([host])
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { hostPendingDeletion = host }
                    .keyboardShortcut(.sidebarDelete)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var sidebarEmptyState: some View {
        switch sidebarTab {
        case .favourites:
            if favouriteHosts.isEmpty {
                ContentUnavailableView(
                    "No Favourites", systemImage: "star",
                    description: Text("Right-click a host and choose Add to Favourites.")
                )
            }
        case .hosts:
            if hosts.isEmpty && folders.isEmpty {
                ContentUnavailableView(
                    "No hosts", systemImage: "server.rack",
                    description: Text("Add a host to open an SSH session.")
                )
            } else if tree.isEmpty && !searchQuery.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        case .forwards:
            if forwardEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Port Forwards", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Add forwards in a host's settings. Forwards that are switched off are in the Port Forwards window.")
                } actions: {
                    Button("Show Port Forwards", systemImage: "arrow.left.arrow.right") { openWindow(id: ForwardsWindowID.id) }
                }
            }
        }
    }

    private func pickSidebarTab(_ tab: SidebarTab) {
        sidebarTabPicked = true
        showSidebarTab(tab)
    }

    private func showSidebarTab(_ tab: SidebarTab) {
        guard tab != sidebarTab else { return }
        sidebarRestoresFocus = sidebarKeys.hasKeyboard
        sidebarTab = tab
    }

    private func revealCreatedItems(_ ids: Set<UUID>) {
        // A filter or a collapsed ancestor must not hide a new item after leaving a flat tab.
        searchText = ""
        var collapsed = collapsedFolders.wrappedValue
        var visited = Set<UUID>()
        let parents = hosts.filter { ids.contains($0.id) }.compactMap(\.folder)
            + folders.filter { ids.contains($0.id) }.compactMap(\.parent)
        for parent in parents {
            var ancestor: TreeNode? = parent
            while let folder = ancestor, visited.insert(folder.id).inserted {
                collapsed.remove(folder.id)
                ancestor = folder.parent
            }
        }
        collapsedFolders.wrappedValue = collapsed
        showSidebarTab(.hosts)
        selectedHostIDs = ids
    }

    private func favouriteButton(_ chosen: [SSHHost]) -> some View {
        let adds = SidebarActions.favouriteAdds(chosen)
        return Button(SidebarActions.favouriteTitle(count: chosen.count, adds: adds), systemImage: adds ? "star" : "star.slash") {
            setFavourite(chosen, adds)
        }
    }

    private func moveMenu(hosts moving: [SSHHost], folders movingFolders: [TreeNode]) -> some View {
        MoveToMenu(folders: folders, moving: movingFolders) { move(hosts: moving, folders: movingFolders, to: $0) }
    }

    private func move(hosts moving: [SSHHost], folders movingFolders: [TreeNode], to destination: TreeNode?) {
        for host in moving { host.move(to: destination) }
        // A folder that travels with its parent is already moved.
        let roots = movingFolders.filter { folder in
            !movingFolders.contains { $0.id != folder.id && folder.isInside($0) }
        }
        for folder in roots where folder.canMove(under: destination) { folder.move(under: destination) }
        modelContext.saveLogged()
        app.refreshNodeColors()
        // Show where it went.
        if let destination { collapsedFolders.wrappedValue.remove(destination.id) }
    }

    /// Dragging rows to rearrange them: only in Custom Order, and not while the filter hides rows, since a
    /// filtered row's place among the rows shown is not its place in its folder.
    private var reordering: SidebarReordering? {
        guard hostOrder.allowsReordering, searchQuery.isEmpty, sidebarTab == .hosts else { return nil }
        return SidebarReordering(
            move: { draggedIDs, target, position, targetIsOpen in
                let dragged = draggedNodes(draggedIDs)
                guard NodeReordering.move(dragged, to: target, position: position, targetIsOpen: targetIsOpen, in: nodes)
                else { return }
                didReorder()
                // Show where they went.
                if position == .inside { collapsedFolders.wrappedValue.remove(target.id) }
            },
            moveToTopLevel: { draggedIDs in
                guard NodeReordering.moveToTopLevel(draggedNodes(draggedIDs), in: nodes) else { return }
                didReorder()
            },
            rowAbove: { rowID in
                let shown = visibleRowIDs(tree)
                guard let index = shown.firstIndex(of: rowID), index > 0 else { return nil }
                return shown[index - 1]
            },
            indicator: dropIndicator
        )
    }

    /// The nodes of dragged rows, in the order the rows are shown (a row not shown, inside a closed folder, last).
    private func draggedNodes(_ rowIDs: [UUID]) -> [TreeNode] {
        let shown = visibleRowIDs(tree)
        let wanted = Set(rowIDs)
        let order = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1, $0) })
        return nodes.filter { wanted.contains($0.rowID) }
            .sorted { (order[$0.rowID] ?? .max, $0.id.uuidString) < (order[$1.rowID] ?? .max, $1.id.uuidString) }
    }

    /// The ids of the rows the Hosts tab shows, top to bottom: the rows of folders that are open.
    private func visibleRowIDs(_ rows: [NodeTree.Row]) -> [UUID] {
        rows.flatMap { row -> [UUID] in
            guard row.node.isFolder, !collapsedFolders.wrappedValue.contains(row.node.id) else { return [row.id] }
            return [row.id] + visibleRowIDs(row.children)
        }
    }

    private func didReorder() {
        modelContext.saveLogged()
        app.refreshNodeColors()
    }

    private func setColor(_ color: NodeColor?, of folder: TreeNode) {
        folder.colorTag = color?.rawValue
        modelContext.saveLogged()
        app.refreshNodeColors()
    }

    private func setFavourite(_ chosen: [SSHHost], _ isFavourite: Bool) {
        for host in chosen { host.isFavourite = isFavourite }
        modelContext.saveLogged()
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if !windowTabs.isEmpty { TabBar() }

            ZStack {
                placeholder
                // Every tab stays alive and only the selected one is shown, so switching
                // tabs never tears a terminal down.
                ForEach(windowTabs) { tab in
                    let isSelected = tab.id == app.selectedTabID(in: windowID)
                    TabContent(tab: tab)
                        .opacity(isSelected ? 1 : 0)
                        // Out of the way as well as invisible: a terminal behind the shown tab is an AppKit view,
                        // and AppKit hands it a drag that is let go over it, ahead of the file tab drawn there, so
                        // nothing could be dropped in a file tab opened after a terminal.
                        .offset(x: isSelected ? 0 : -50_000)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .zIndex(isSelected ? 1 : 0)
                }
            }
        }
        // The window keeps its title (the Window menu and Mission Control use it), but the toolbar does not show it:
        // the tab already says which host it is.
        .navigationTitle(windowTitle)
        .toolbar(removing: .title)
        .toolbar { workspaceToolbar }
        // The quick connect matches, under the field.
        .overlay(alignment: .top) {
            if quickConnectFocused || isOverQuickDropdown {
                QuickConnectDropdown(
                    results: quickResults, hasHosts: !hosts.isEmpty, selection: $quickSelection,
                    isHovering: $isOverQuickDropdown, onChoose: { index in quickSelection = index; openQuickResult() }
                )
                .padding(.top, 6)
            }
        }
    }

    /// A renamed tab keeps its name; otherwise the host, or both sides of a file tab.
    private var windowTitle: String {
        guard let tab = app.selectedTab(in: windowID) else { return "CerberusSSH" }
        return tab.name ?? app.windowTitle(for: tab)
    }

    private var windowTabs: [WorkspaceTab] { app.tabs(in: windowID) }

    /// The focused pane of this window's selected tab.
    private var windowSession: SessionViewModel? {
        app.selectedTab(in: windowID).flatMap { app.session(withID: $0.focusedSessionID) }
    }

    // MARK: Quick connect

    private var quickResults: [SSHHost] { QuickConnect.results(quickQuery, in: hosts) }

    /// The field in the middle of the toolbar (⌘K puts the keyboard in it).
    private var quickConnectField: some View {
        QuickConnectTextField(
            text: $quickQuery, isEditing: $quickConnectFocused, focusToken: quickFocusToken, blurToken: quickBlurToken,
            onMove: { step in quickSelection = min(max(quickSelection + step, 0), max(0, quickResults.count - 1)) },
            onSubmit: openQuickResult, onEscape: closeQuickConnect
        )
        .onChange(of: quickQuery) { quickSelection = 0 }
        .frame(width: 380)
        // The key that gets here, in the field itself while it is empty and idle, so it can be found without the menu.
        .overlay(alignment: .trailing) {
            if quickQuery.isEmpty && !quickConnectFocused {
                Text(AppShortcut.quickConnect.display)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("quick-connect-shortcut-hint")
            }
        }
    }

    private func closeQuickConnect() {
        quickQuery = ""
        quickSelection = 0
        isOverQuickDropdown = false
        quickConnectFocused = false
        quickBlurToken += 1
    }

    private func openQuickResult() {
        let shown = quickResults
        guard shown.indices.contains(quickSelection) else { return }
        let host = shown[quickSelection]
        // ⇧ opens a window of its own, ⌥ splits beside the focused pane, and Return alone is a new tab.
        let flags = NSEvent.modifierFlags
        let window = UUID()
        let placement: SessionPlacement
        var whenPlaced: (@MainActor () -> Void)?
        if flags.contains(.shift) {
            placement = .newWindow(window)
            let opens = openWindow
            whenPlaced = { opens(value: window) }
        } else if flags.contains(.option) && app.selectedSession != nil {
            placement = .splitRight
        } else {
            placement = .newTab
        }
        closeQuickConnect()
        Task { await app.connect(to: host, placement: placement, whenPlaced: whenPlaced) }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { quickConnectField }
        if !isTerminalWindow {
            ToolbarItem {
                Button { app.toggleInspector(in: windowID) } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the host inspector (⌥⌘I)")
            }
        }
        if let session = windowSession {
            if session.canReconnect {
                ToolbarItem {
                    Button {
                        Task { await session.reconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut(.reconnect)
                    .help("Reconnect (⌘R)")
                }
            }
            ToolbarItem {
                Button { app.isShowingSnippets = true } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
                .help("Insert a snippet (⇧⌘K)")
            }
            // Only a tab with more than one pane has anything to broadcast to, or a pane to take out.
            if let tab = app.selectedTab(in: windowID), tab.files == nil, tab.layout.count > 1 {
                ToolbarItem {
                    let isOn = app.isBroadcasting(tab: tab.id)
                    Button { app.toggleBroadcast(inTab: tab.id) } label: {
                        Label(isOn ? "Stop Broadcasting Input" : "Broadcast Input", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .foregroundStyle(isOn ? Color.broadcastIndicator : Color.primary)
                    .help(isOn ? "Stop copying typing to the checked panes (⇧⌘B)" : "Copy typing to several panes at once (⇧⌘B)")
                    .accessibilityIdentifier("toolbar-broadcast")
                }
                ToolbarItem {
                    Button { app.movePaneToTab(session) } label: {
                        Label("Move Pane to New Tab", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .help("Give this pane a tab of its own (⌥⌘T)")
                    .accessibilityIdentifier("toolbar-move-pane")
                }
            }
            ToolbarItem {
                Button {
                    Task { session.isRecording ? await session.stopRecording() : await session.startRecording() }
                } label: {
                    Label(session.isRecording ? "Stop Recording" : "Record Session", systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .foregroundStyle(session.isRecording ? Color.statusBad : Color.primary)
                .disabled(!session.isRecording && !session.canRecord)
                .help(session.isRecording ? "Stop recording this session" : "Record this session to an encrypted recording, from now on")
                .accessibilityIdentifier("toolbar-record")
            }
            ToolbarItem {
                Button { logSession = session } label: {
                    Label("Connection Log", systemImage: "list.bullet.rectangle")
                }
                .help("Show the connection log")
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if windowTabs.isEmpty && !isTerminalWindow {
            WelcomeView(hosts: hosts, onNewHost: { newHost = NewHostRequest(folderID: nil) }, onConnect: { connect($0) })
                // A window with nothing open takes a dragged tab as its first tab.
                .onDrop(of: [TabDrag.type], isTargeted: nil) { _, _ in
                    guard let moved = app.draggingTabID else { return false }
                    app.tabDropHandled()
                    app.moveTab(moved, toWindow: windowID, before: nil)
                    return true
                }
        }
    }

    /// Copies hosts: everything about how to reach and set up the host, under a name that says
    /// it is a copy. The copy shares the original's identity (so changing the login still
    /// changes both) and starts with no connection history. The copies become the selection.
    private func duplicate(_ originals: [SSHHost]) {
        var names = hosts.map(\.displayLabel) + hosts.map(\.name)
        var created: [SSHHost] = []
        for original in originals {
            let copy = SSHHost(
                name: CopyName.of(original.displayLabel, among: names),
                hostname: original.hostname, port: original.port,
                identity: original.identity, folder: original.folder, tags: original.tags,
                jumpHostIDs: original.jumpHostIDs, terminalType: original.terminalType,
                keepAliveInterval: original.keepAliveInterval, autoReconnect: original.autoReconnect
            )
            copy.environment = original.environment
            copy.initialCommand = original.initialCommand
            copy.themeID = original.themeID
            copy.agentForwarding = original.agentForwarding
            copy.compression = original.compression
            copy.notes = original.notes
            copy.usesNoAuthentication = original.usesNoAuthentication
            copy.noAuthenticationUsername = original.noAuthenticationUsername
            modelContext.insert(copy)
            for forward in original.portForwards ?? [] {
                modelContext.insert(PortForward(
                    kind: forward.kind, bindAddress: forward.bindAddress, bindPort: forward.bindPort,
                    destinationHost: forward.destinationHost, destinationPort: forward.destinationPort,
                    autoStart: forward.autoStart, name: forward.name, host: copy
                ))
            }
            names.append(copy.name)
            created.append(copy)
        }
        modelContext.saveLogged()
        sidebarSelections[.hosts] = Set(created.map(\.id))
    }

    /// Always a tab of its own, even when the host is already open (so two sessions to one host are easy).
    private func connect(_ host: SSHHost) {
        selectedHostIDs = [host.id]
        Task { await app.connect(to: host, placement: .newTab) }
    }

    /// What the menu bar's Host menu does with the selection while the sidebar has the keyboard.
    private var sidebarActions: SidebarActions {
        let ids = selectedHostIDs
        let chosen = hosts.filter { ids.contains($0.id) }
        let folder = chosen.isEmpty ? ids.compactMap { id in folders.first { $0.id == id } }.first : nil
        var actions = SidebarActions(hostCount: chosen.count, hasFolder: folder != nil)
        actions.connect = { chosen.forEach(connect) }
        actions.openSFTP = { if chosen.count == 1 || chosen.count == 2 { app.openFiles(for: chosen) } }
        actions.edit = {
            if chosen.count == 1, let host = chosen.first { editingHost = host }
            else if chosen.count > 1 { isBulkEditing = true }
        }
        actions.duplicate = { if !chosen.isEmpty { duplicate(chosen) } }
        actions.addsFavourite = SidebarActions.favouriteAdds(chosen)
        actions.toggleFavourite = { if !chosen.isEmpty { setFavourite(chosen, SidebarActions.favouriteAdds(chosen)) } }
        actions.rename = { if let folder { folderEditor = .init(folder: folder, parent: nil) } }
        actions.delete = {
            if let folder { folderPendingDeletion = folder }
            else if chosen.count == 1, let host = chosen.first { hostPendingDeletion = host }
        }
        return actions
    }

    // MARK: Deleting

    private func delete(_ host: SSHHost) {
        for session in app.sessions where session.hostID == host.id {
            Task { await app.close(session) }
        }
        selectedHostIDs.remove(host.id)

        // The host's identity stays, used or not: credentials are only ever deleted by a person
        // choosing to (Settings ▸ Identities), and an identity no host uses is marked there.
        // Hosts that jump through this one lose that hop rather than keep a dangling id.
        for other in hosts where other.jumpHostIDs.contains(host.id) {
            other.jumpHostIDs.removeAll { $0 == host.id }
        }
        modelContext.delete(host)
        modelContext.saveLogged()
    }

    private func delete(_ folder: TreeNode) {
        // Rescue the hosts in this folder and every folder beneath it before the cascade.
        for node in folder.descendants where node.isHost {
            node.move(under: folder.parent)
        }
        selectedHostIDs.remove(folder.id)
        modelContext.delete(folder)
        modelContext.saveLogged()
    }
}
