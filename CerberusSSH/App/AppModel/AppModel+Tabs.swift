import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// Moving, merging, detaching, renaming and dragging tabs, and closing a window.
extension AppModel {
    // MARK: Moving tabs

    /// Drops `tabID` into `window` before `target` (or at the end), reordering within
    /// a window or moving between windows. The sessions keep running.
    func moveTab(_ tabID: UUID, toWindow window: UUID, before target: UUID?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sourceWindow = tabs[index].windowID
        tabs[index].windowID = window

        let order = TabOrder.moving(tabs.map(\.id), tabID, before: target)
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tabs = order.compactMap { byID[$0] }

        selectedTabIDs[window] = tabID
        if sourceWindow != window, selectedTabIDs[sourceWindow] == tabID {
            selectedTabIDs[sourceWindow] = tabs(in: sourceWindow).first?.id
        }
    }

    /// Moves every pane of `sourceID` into `targetID`, beside its pane `pane` or below it, splitting only that pane;
    /// a split tab keeps its own arrangement. The sessions keep running; the source tab disappears. The new panes are
    /// not added to a broadcast that is already on: joining one sends keystrokes to that server, so it is a choice.
    func mergeTab(_ sourceID: UUID, into targetID: UUID, beside pane: UUID, axis: PaneLayout.Axis, before: Bool = false) {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
              source.files == nil, tabs[targetIndex].files == nil,
              tabs[targetIndex].layout.contains(pane) else { return }
        let sourceWindow = source.windowID
        let targetWindow = tabs[targetIndex].windowID

        tabs[targetIndex].layout = tabs[targetIndex].layout.inserting(source.layout, beside: pane, axis: axis, before: before)
        tabs[targetIndex].focusedSessionID = source.focusedSessionID
        tabs.removeAll { $0.id == sourceID }
        pruneBroadcast(afterClosing: sourceID)

        selectedTabIDs[targetWindow] = targetID
        if sourceWindow != targetWindow, selectedTabIDs[sourceWindow] == sourceID {
            selectedTabIDs[sourceWindow] = tabs(in: sourceWindow).first?.id
        }
    }

    /// Moves a pane dragged by its grip beside `target`, a pane of `tabID`, which may be the tab it came from. It is
    /// taken out into a tab of its own and merged in from there. Moved within its own tab it stays in that tab's
    /// broadcast if it was in it; moved to another tab it does not join one, as with `mergeTab`.
    func movePane(_ sessionID: UUID, beside target: UUID, inTab tabID: UUID, axis: PaneLayout.Axis, before: Bool) {
        guard sessionID != target, let session = session(withID: sessionID),
              tabs.first(where: { $0.id == tabID })?.layout.contains(target) == true else { return }
        let staysInTab = tabs.first { $0.layout.contains(sessionID) }?.id == tabID
        let wasBroadcasting = broadcastMembers(in: tabID).contains(sessionID)
        guard let ownTab = movePaneToTab(session) else { return }
        mergeTab(ownTab, into: tabID, beside: target, axis: axis, before: before)
        if staysInTab, wasBroadcasting, broadcastSets[tabID] != nil { broadcastSets[tabID]?.insert(sessionID) }
    }

    /// Gives a tab a window of its own and returns that window's id, for the caller to
    /// open. The tab's sessions keep their connections.
    func detachTab(_ tabID: UUID, at origin: CGPoint? = nil) -> UUID {
        let newWindow = UUID()
        terminalWindows.insert(newWindow)
        if let origin { pendingWindowOrigins[newWindow] = origin }
        moveTab(tabID, toWindow: newWindow, before: nil)
        return newWindow
    }

    /// Names a tab; an empty name goes back to the automatic title.
    func renameTab(_ id: UUID, to text: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].name = TabName.normalised(text)
    }

    /// What a tab is called: the name it was given, else the host of its focused pane (never the title the remote
    /// shell sets), or both sides of a file tab.
    func title(of tab: WorkspaceTab) -> String {
        if let name = tab.name { return name }
        if let files = tab.files { return files.title }
        return session(withID: tab.focusedSessionID)?.title ?? "Tab"
    }

    /// What a window is called: a file tab shows the places of its left and right panes, any other tab its host.
    func windowTitle(for tab: WorkspaceTab?) -> String {
        guard let tab else { return "CerberusSSH" }
        if let files = tab.files { return [files.left, files.right].map(\.source.title).joined(separator: " ⇄ ") }
        return title(of: tab)
    }

    /// Starts renaming the active window's selected tab (the Rename Tab command).
    func beginRenamingSelectedTab() {
        if let tab = selectedTab { selectTab(tab.id); renamingTabID = tab.id }
    }

    func isTerminalWindow(_ id: UUID) -> Bool { terminalWindows.contains(id) }

    // MARK: Dragging a tab

    /// A tab drag has started. When the mouse button comes up, a drop on one of our views
    /// has been handled by it (`tabDropHandled`); otherwise, if it was let go outside every
    /// window of the app and the window has other tabs, `detach` is called with where.
    func beginTabDrag(_ tabID: UUID, title: String, detach: @escaping @MainActor (CGPoint) -> Void) {
        draggingTabID = tabID
        draggingPaneID = nil
        trackDrag(title: title) { [self] point, overOurWindow in
            defer { draggingTabID = nil }
            let sourceWindow = tabs.first { $0.id == tabID }?.windowID
            let sourceCount = sourceWindow.map { tabs(in: $0).count } ?? 0
            let outcome = TabDragOutcome.decide(
                dropWasHandled: tabDropWasHandled, releasedOverAppWindow: overOurWindow,
                tabsInSourceWindow: sourceCount,
                sourceIsTerminalWindow: sourceWindow.map { isTerminalWindow($0) } ?? false
            )
            if outcome == .openInNewWindow { detach(point) }
        }
    }

    /// A pane is being dragged out of its tab (by its grip). Like a tab, it lands on a tab or on the tab bar and becomes
    /// a tab there; let go outside every window of the app it gets a window of its own. Where it came from keeps its
    /// other panes the whole time: it only leaves when it is dropped.
    func beginPaneDrag(_ sessionID: UUID, title: String, detach: @escaping @MainActor (CGPoint) -> Void) {
        draggingPaneID = sessionID
        draggingTabID = nil
        trackDrag(title: title) { [self] point, overOurWindow in
            defer { draggingPaneID = nil }
            if !tabDropWasHandled, !overOurWindow { detach(point) }
        }
    }

    /// Gives the pane a tab of its own in `window`, before `target` (or last).
    func placePane(_ sessionID: UUID, inWindow window: UUID, before target: UUID?) {
        guard let session = session(withID: sessionID), let tabID = movePaneToTab(session) else { return }
        moveTab(tabID, toWindow: window, before: target)
    }

    /// Follows the pointer with a small picture until the button comes up, then says where and whether a drop was taken.
    private func trackDrag(title: String, finish: @escaping @MainActor (_ point: CGPoint, _ overOurWindow: Bool) -> Void) {
        tabDropWasHandled = false
        dragTracker?.cancel()
        dragTracker = Task { @MainActor [weak self] in
            // AppKit gives no "drag ended" to SwiftUI, so watch the button.
            let preview = TabDragPreview()
            preview.show(title: title)
            defer { preview.hide() }
            var waited = 0
            while NSEvent.pressedMouseButtons & 1 != 0, waited < 6_000 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 1
                preview.move()
                if Task.isCancelled { return }
            }
            preview.hide()
            let point = NSEvent.mouseLocation
            let overOurWindow = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain && $0.frame.contains(point)
            }
            // A drop on one of our views reports itself within a few milliseconds of the button coming up, so
            // that is all the wait there is, and only when it was let go over one of our windows. Let go
            // outside them, nothing can have taken it: the new window opens at once.
            if overOurWindow { try? await Task.sleep(for: .milliseconds(80)) }
            guard let self, !Task.isCancelled else { return }
            finish(point, overOurWindow)
        }
    }

    /// A drop target took the dragged tab.
    func tabDropHandled() { tabDropWasHandled = true }

    /// A window is closing: close what it was showing.
    func closeWindow(_ id: UUID) async {
        for tab in tabs(in: id) { await closeTab(tab.id) }
        selectedTabIDs[id] = nil
        terminalWindows.remove(id)
        pendingWindowOrigins[id] = nil
        if activeWindowID == id { activeWindowID = tabs.last?.windowID }
    }
}
