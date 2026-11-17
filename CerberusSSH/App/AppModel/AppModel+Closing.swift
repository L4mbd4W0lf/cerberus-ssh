import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// Closing panes, tabs and everything, and describing an error for the person.
extension AppModel {
    // MARK: Closing, asking first

    /// Closes a tab from the interface: straight away, or after a question when it holds a live connection (or
    /// a file tab with transfers running) and Settings ▸ Behaviour says to ask.
    func requestClose(tab id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if BehaviourSettings.confirmsClosing, liveWork(in: tab) > 0 {
            closeRequest = .tab(id); closeRequestWindow = tab.windowID
        } else {
            Task { await closeTab(id) }
        }
    }

    /// Closes one pane from the interface (⌘W, the pane's menu), asking first when it is live.
    func requestClose(pane session: SessionViewModel) {
        if BehaviourSettings.confirmsClosing, session.isLive {
            closeRequest = .pane(session.id)
            closeRequestWindow = tabs.first(where: { $0.layout.contains(session.id) })?.windowID
        } else {
            Task { await close(session) }
        }
    }

    /// What to ask before closing a window, or nil when nothing live would end (or the setting says not to ask).
    func windowCloseQuestion(_ windowID: UUID) -> (title: String, message: String)? {
        guard BehaviourSettings.confirmsClosing else { return nil }
        let (connections, transfers) = liveTotals(in: tabs(in: windowID))
        return Self.endingMessage(title: "Close this window?", connections: connections, transfers: transfers)
    }

    /// What to ask before quitting.
    func quitQuestion() -> (title: String, message: String)? {
        guard BehaviourSettings.confirmsClosing else { return nil }
        let (connections, transfers) = liveTotals(in: tabs)
        return Self.endingMessage(title: "Quit CerberusSSH?", connections: connections, transfers: transfers)
    }

    private func liveTotals(in tabs: [WorkspaceTab]) -> (connections: Int, transfers: Int) {
        var connections = 0, transfers = 0
        for tab in tabs {
            if let files = tab.files { transfers += files.queue.activeCount }
            else { connections += tab.layout.leaves.filter { session(withID: $0)?.isLive == true }.count }
        }
        return (connections, transfers)
    }

    private static func endingMessage(title: String, connections: Int, transfers: Int) -> (title: String, message: String)? {
        guard connections + transfers > 0 else { return nil }
        var parts: [String] = []
        if connections > 0 { parts.append(connections == 1 ? "1 connection will end" : "\(connections) connections will end") }
        if transfers > 0 { parts.append(transfers == 1 ? "1 transfer will be cancelled" : "\(transfers) transfers will be cancelled") }
        return (title, parts.joined(separator: " and ").capitalizedFirst + ".")
    }

    /// The person said yes.
    func confirmClose() {
        guard let request = closeRequest else { return }
        closeRequest = nil
        switch request {
        case .tab(let id): Task { await closeTab(id) }
        case .pane(let id): if let session = session(withID: id) { Task { await close(session) } }
        }
    }

    /// Live connections in a terminal tab, or transfers still running in a file tab.
    func liveWork(in tab: WorkspaceTab) -> Int {
        if let files = tab.files { return files.queue.activeCount }
        return tab.layout.leaves.filter { session(withID: $0)?.isLive == true }.count
    }

    /// What the question says.
    func closeQuestion() -> (title: String, message: String)? {
        switch closeRequest {
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
            let n = liveWork(in: tab)
            if tab.files != nil { return ("Close this file tab?", "\(n) transfer\(n == 1 ? " is" : "s are") still running and will be cancelled.") }
            return ("Close this tab?", n == 1 ? "Its connection will end." : "Its \(n) connections will end.")
        case .pane(let id):
            guard let session = session(withID: id) else { return nil }
            return ("Close this pane?", "Its connection to \(session.title) will end.")
        case nil: return nil
        }
    }

    /// Closes one pane. Closing a tab's last pane closes the tab.
    func close(_ session: SessionViewModel) async {
        await session.disconnect()
        keepLog(of: session)
        sessions.removeAll { $0.id == session.id }
        session.releaseTerminal()

        guard let index = tabs.firstIndex(where: { $0.layout.contains(session.id) }) else { return }
        let tabID = tabs[index].id
        defer { pruneBroadcast(afterClosing: tabID) }
        if let remaining = tabs[index].layout.removing(session.id) {
            tabs[index].layout = remaining
            if tabs[index].focusedSessionID == session.id, let next = remaining.leaves.first {
                tabs[index].focusedSessionID = next
            }
        } else {
            removeTab(tabID)
        }
    }

    /// Keeps a closed session's connection log under its host, to be read later (Show Last Connection Log).
    func keepLog(of session: SessionViewModel) {
        guard !session.diagnostics.isEmpty else { return }
        lastConnectionLogs[session.hostID] = SavedConnectionLog(
            title: session.title, text: session.diagnosticsText, lineCount: session.diagnostics.count, date: Date()
        )
    }

    /// A pane can leave its tab only while it has company in it.
    func canMovePaneToTab(_ session: SessionViewModel) -> Bool {
        tabs.first { $0.layout.contains(session.id) && $0.files == nil }.map { $0.layout.count > 1 } ?? false
    }

    /// Takes a pane out of a split and gives it a tab of its own, next to the one it left. The connection
    /// is untouched: only where it is shown changes.
    @discardableResult
    func movePaneToTab(_ session: SessionViewModel) -> UUID? {
        guard canMovePaneToTab(session),
              let index = tabs.firstIndex(where: { $0.layout.contains(session.id) }),
              let remaining = tabs[index].layout.removing(session.id) else { return nil }
        let old = tabs[index]
        tabs[index].layout = remaining
        if old.focusedSessionID == session.id, let next = remaining.leaves.first { tabs[index].focusedSessionID = next }
        let tab = WorkspaceTab(windowID: old.windowID, layout: PaneLayout(leaf: session.id), focusedSessionID: session.id)
        tabs.insert(tab, at: index + 1)
        selectedTabIDs[tab.windowID] = tab.id
        pruneBroadcast(afterClosing: nil)
        return tab.id
    }

    /// Takes a tab out and selects the one that slid into its place, within its window.
    func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs[index]
        tabs.remove(at: index)
        if selectedTabIDs[closed.windowID] == closed.id {
            let mine = tabs(in: closed.windowID)
            let successor = mine.first { tab in
                (tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) >= index
            }
            selectedTabIDs[closed.windowID] = (successor ?? mine.last)?.id
        }
    }

    /// ⌘W. It never closes a workspace window (the red button does that, and asks when something is live): it closes the
    /// focused pane of the selected tab, asking first when that is live, and does nothing when there is no such pane.
    /// In any other window (Settings, Help, a log) it closes that window, as ⌘W does everywhere else; and while a
    /// question or sheet is open over the workspace it does nothing.
    func closeFocusedPane() async {
        if let key = NSApp.keyWindow {
            if !isWorkspaceWindow(key), key.sheetParent == nil { key.performClose(nil); return }
            if !key.sheets.isEmpty || key.sheetParent != nil { return }
        }
        if let tab = selectedTab, tab.files != nil { requestClose(tab: tab.id); return }
        if let session = selectedSession { requestClose(pane: session) }
    }

    /// Closes every pane in a tab.
    func closeTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if let files = tab.files {
            await files.shutdown()
            removeTab(id)
            return
        }
        for sessionID in tab.layout.leaves {
            if let session = session(withID: sessionID) { await close(session) }
        }
    }

    func closeAll() async {
        for tab in tabs { await tab.files?.shutdown() }
        for session in sessions + tunnels {
            await session.disconnect()
            session.releaseTerminal()
        }
        sessions.removeAll()
        tunnels.removeAll()
        tabs.removeAll()
        selectedTabIDs = [:]
        broadcastSets = [:]
    }

    func describe(_ error: Error) -> String {
        if let sshError = error as? SSHError { return sshError.description }
        if let chainError = error as? JumpChainResolver.ChainError { return chainError.description }
        if let vaultError = error as? VaultError { return vaultError.description }
        return error.localizedDescription
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
