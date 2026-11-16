import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

// MARK: - What is remembered

/// The tabs and windows to bring back at the next launch: which hosts, how the panes are split, tab names, file
/// tabs and which tab was in front. Hosts are remembered by id; the sessions are made again.
struct WorkspaceSnapshot: Codable, Equatable {
    var windows: [WindowSnapshot] = []
}

struct WindowSnapshot: Codable, Equatable {
    /// A window made by pulling a tab out (no sidebar), as opposed to a main window.
    var isTerminalWindow: Bool
    var tabs: [TabSnapshot]
    var selected: Int?
    /// Where the window was on the screen (absent in a snapshot from before this was kept).
    var frame: CGRect?
}

struct TabSnapshot: Codable, Equatable {
    var name: String?
    /// A terminal tab: its panes. Nil for a file tab.
    var layout: LayoutSnapshot?
    /// Which pane (by position, left to right and top to bottom) had the focus.
    var focused = 0
    /// A file tab: what each pane showed.
    var files: FilesSnapshot?
}

struct FilesSnapshot: Codable, Equatable {
    /// A host's id, or nil for This Mac.
    var left: UUID?
    var right: UUID?
    /// The folder each pane was in (absent in a snapshot from before this was kept).
    var leftFolder: String?
    var rightFolder: String?
}

indirect enum LayoutSnapshot: Codable, Equatable {
    case leaf(hostID: UUID)
    case split(horizontal: Bool, ratio: Double, first: LayoutSnapshot, second: LayoutSnapshot)

    var hostIDs: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let first, let second): first.hostIDs + second.hostIDs
        }
    }
}

extension AppModel {
    /// A file beside the catalogue rather than a user default: a default is written out a moment later by another
    /// process and is lost if the app is killed, and this is written at once.
    private static var snapshotURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("CerberusSSH").appendingPathComponent("workspace.json")
    }

    // MARK: Taking the snapshot

    /// What is open now, in a form that can be compared (so a change can be noticed) and saved.
    func workspaceSnapshot() -> WorkspaceSnapshot {
        var windowOrder: [UUID] = []
        for tab in tabs where !windowOrder.contains(tab.windowID) { windowOrder.append(tab.windowID) }
        let windows = windowOrder.compactMap { id -> WindowSnapshot? in
            let mine = tabs(in: id)
            let snapshots = mine.compactMap(snapshot(of:))
            guard !snapshots.isEmpty else { return nil }
            let selected = selectedTabIDs[id].flatMap { chosen in mine.firstIndex { $0.id == chosen } }
            return WindowSnapshot(isTerminalWindow: isTerminalWindow(id), tabs: snapshots, selected: selected.map { min($0, snapshots.count - 1) },
                                  frame: windowFrames[id])
        }
        return WorkspaceSnapshot(windows: windows)
    }

    private func snapshot(of tab: WorkspaceTab) -> TabSnapshot? {
        if let files = tab.files {
            func host(_ source: FilePaneModel.Source) -> UUID? { if case .host(let id, _) = source { id } else { nil } }
            return TabSnapshot(name: tab.name, files: FilesSnapshot(
                left: host(files.left.source), right: host(files.right.source),
                leftFolder: files.left.path.isEmpty ? nil : files.left.path, rightFolder: files.right.path.isEmpty ? nil : files.right.path
            ))
        }
        func layout(_ node: PaneLayout.Node) -> LayoutSnapshot? {
            switch node {
            case .leaf(let id):
                return session(withID: id).map { .leaf(hostID: $0.hostID) }
            case .split(_, let axis, let ratio, let first, let second):
                switch (layout(first), layout(second)) {
                case (let a?, let b?): return .split(horizontal: axis == .horizontal, ratio: ratio, first: a, second: b)
                case (let only?, nil), (nil, let only?): return only
                default: return nil
                }
            }
        }
        guard let root = layout(tab.layout.root) else { return nil }
        let focused = tab.layout.leaves.firstIndex(of: tab.focusedSessionID) ?? 0
        return TabSnapshot(name: tab.name, layout: root, focused: focused)
    }

    /// Saves a moment from now, once changes have stopped (a window being dragged changes its frame all the time).
    func scheduleWorkspaceSave() {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveWorkspace()
        }
    }

    /// Writes the snapshot, or forgets it when the setting is off. Not before the last one has been used, so the
    /// empty window of a launch cannot overwrite what is waiting to be reopened.
    func saveWorkspace() {
        guard didRestoreWorkspace, !isQuitting else { return }
        guard BehaviourSettings.reopensWorkspace else {
            try? FileManager.default.removeItem(at: Self.snapshotURL)
            return
        }
        guard let data = try? JSONEncoder().encode(workspaceSnapshot()) else { return }
        try? FileManager.default.createDirectory(at: Self.snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.snapshotURL, options: .atomic)
    }

    // MARK: Bringing it back

    /// Reopens what was open when the app was last quit, once per launch, in the window that asks (the first main
    /// window) and in windows of their own for the rest. Each session connects in the background.
    func restoreWorkspace(into mainWindow: UUID, openWindow: @escaping (UUID) -> Void) async {
        guard !didRestoreWorkspace, !restoreInProgress else { return }
        restoreInProgress = true
        defer { didRestoreWorkspace = true; restoreInProgress = false }

        guard BehaviourSettings.reopensWorkspace, tabs.isEmpty,
              let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data), !snapshot.windows.isEmpty
        else { return }

        // The trust store and the vault come up a moment after the window does.
        for _ in 0..<100 where !(context != nil && hostKeyStore != nil && isVaultReady) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let context, hostKeyStore != nil, isVaultReady else { return }
        func fetchHosts() -> [UUID: SSHHost] {
            Dictionary(context.fetchLogged(FetchDescriptor<SSHHost>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var hosts = fetchHosts()
        // A test fills the catalogue a moment after the window opens: wait for the hosts that are remembered.
        if UITesting.isActive {
            let wanted = Set(snapshot.windows.flatMap(\.tabs).flatMap { $0.layout?.hostIDs ?? [] })
            for _ in 0..<50 where !wanted.isSubset(of: hosts.keys) {
                try? await Task.sleep(for: .milliseconds(100))
                hosts = fetchHosts()
            }
        }

        var usedMain = false
        for window in snapshot.windows {
            let target: UUID
            if !window.isTerminalWindow, !usedMain {
                target = mainWindow; usedMain = true
                if let frame = window.frame { pendingWindowFrames[target] = frame }
            } else {
                target = UUID()
                if window.isTerminalWindow { terminalWindows.insert(target) }
                if let frame = window.frame { pendingWindowFrames[target] = frame }
                openWindow(target)
            }
            var restored: [UUID] = []
            for tabSnapshot in window.tabs {
                if let id = await restoreTab(tabSnapshot, in: target, hosts: hosts) { restored.append(id) }
            }
            if let chosen = window.selected.flatMap({ restored.indices.contains($0) ? restored[$0] : nil }) ?? restored.last {
                selectedTabIDs[target] = chosen
            }
        }
        if activeWindowID == nil { activeWindowID = mainWindow }
    }

    /// One tab; its sessions are started in the background so they connect side by side.
    private func restoreTab(_ snapshot: TabSnapshot, in window: UUID, hosts: [UUID: SSHHost]) async -> UUID? {
        if let files = snapshot.files {
            func source(_ id: UUID?) -> FilePaneModel.Source? {
                guard let id else { return .local }
                return hosts[id].map { .host(id: $0.id, name: $0.displayLabel) }
            }
            guard let left = source(files.left), let right = source(files.right) else { return nil }
            let model = FileTabModel(left: left, right: right) { [weak self] id in
                guard let self else { throw CancellationError() }
                return try await self.makeFileSession(for: id)
            }
            var tab = WorkspaceTab(windowID: window, layout: PaneLayout(leaf: model.id), focusedSessionID: model.id, files: model)
            tab.name = snapshot.name
            tabs.append(tab)
            Task { await model.start(leftFolder: files.leftFolder, rightFolder: files.rightFolder) }
            return tab.id
        }

        guard let layout = snapshot.layout else { return nil }
        var made: [SessionViewModel] = []
        func build(_ node: LayoutSnapshot) async -> PaneLayout.Node? {
            switch node {
            case .leaf(let hostID):
                guard let host = hosts[hostID], host.hasLogin, let session = try? await makeSession(for: host) else { return nil }
                made.append(session)
                return .leaf(session.id)
            case .split(let horizontal, let ratio, let first, let second):
                let a = await build(first), b = await build(second)
                switch (a, b) {
                case (let a?, let b?):
                    return .split(id: UUID(), axis: horizontal ? .horizontal : .vertical, ratio: ratio, first: a, second: b)
                case (let only?, nil), (nil, let only?): return only
                default: return nil
                }
            }
        }
        guard let root = await build(layout), !made.isEmpty else { return nil }
        let arrangement = PaneLayout(root: root)
        let leaves = arrangement.leaves
        var tab = WorkspaceTab(windowID: window, layout: arrangement, focusedSessionID: leaves[min(snapshot.focused, leaves.count - 1)])
        tab.name = snapshot.name
        sessions.append(contentsOf: made)
        tabs.append(tab)
        for session in made { Task { await session.start() } }
        return tab.id
    }
}

/// Keeps what is open for the next launch, and brings the last run's tabs back when the first main window opens.
struct WorkspaceMemory: ViewModifier {
    let windowID: UUID
    let isTerminalWindow: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear { QuitTimer.app = app }
            .onChange(of: app.workspaceSnapshot()) { app.scheduleWorkspaceSave() }
            .task {
                guard !isTerminalWindow else { return }
                await app.restoreWorkspace(into: windowID) { openWindow(value: $0) }
            }
    }
}
