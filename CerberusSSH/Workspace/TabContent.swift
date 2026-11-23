import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault
import CerberusSSHCore


/// A tab's panes. Frames come from ``PaneLayout`` and every pane is placed by its
/// session id, so splitting or closing a pane never rebuilds its neighbours.
struct TabContent: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let tab: WorkspaceTab
    @Environment(AppModel.self) private var app

    @Environment(\.windowID) private var windowID
    /// The pane and side a dragged tab or pane would join if let go now, while one is over these terminals.
    @State private var dropTarget: PaneDropTarget?
    private var isSelectedTab: Bool { tab.id == app.selectedTabID(in: windowID) }

    var body: some View {
        if let files = tab.files {
            FileTabView(tab: files)
        } else {
            VStack(spacing: 0) {
                panes
                Divider()
                TabStatusBar(tab: tab) { session in app.focusWithinSelectedTab(session, in: windowID) }
                    .zIndex(1)
            }
        }
    }

    private var panes: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = tab.layout.geometry(in: bounds)

            ZStack(alignment: .topLeading) {
                ForEach(tab.layout.leaves, id: \.self) { id in
                    if let session = app.session(withID: id), let frame = layout.panes[id] {
                        SessionPane(
                            session: session,
                            // Only the selected tab's pane holds the keyboard. Otherwise
                            // switching tabs would leave typing going to a hidden terminal.
                            isFocused: isSelectedTab && tab.focusedSessionID == id,
                            showsFocusRing: tab.layout.count > 1,
                            isBroadcasting: app.isBroadcasting(tab: tab.id),
                            inBroadcastGroup: app.broadcastMembers(in: tab.id).contains(id),
                            onToggleBroadcastMembership: { app.toggleBroadcastMembership(session, inTab: tab.id) },
                            onInput: { bytes in app.mirrorInput(bytes, from: session) },
                            onPaste: { text in app.mirrorPaste(text, from: session) },
                            broadcastPaneCount: app.groupSize(for: session),
                            // A click can only move focus within the tab being shown; it
                            // must never switch tabs (hidden tabs can't steal it back).
                            onFocus: { app.focusWithinSelectedTab(session, in: windowID) }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }

                ForEach(layout.dividers, id: \.splitID) { divider in
                    DividerHandle(divider: divider, tabID: tab.id)
                }
            }
            // The whole tab. `offset` moves where a pane is drawn but not the stack's own frame, which would
            // otherwise be one pane's size at the top left, and a drop on any pane outside it would never arrive.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: "tab-\(tab.id.uuidString)")
            .overlay {
                if let target = dropTarget {
                    let zone = target.zone, area = target.highlight
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.fill(0.22, contrast))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3))
                        .overlay { Label(zone.title, systemImage: "rectangle.split.2x1")
                            .padding(10).solidPanel(Capsule()) }
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .allowsHitTesting(false)
                }
            }
            // A tab (or a pane, by its grip) dragged here joins the pane it is let go on, on the side of that pane's
            // middle it is let go on.
            .onDrop(of: [TabDrag.type], delegate: PaneDropDelegate(
                panes: layout.panes, tabID: tab.id, app: app, target: $dropTarget
            ))
        }
    }
}

/// Follows a dragged tab, or a pane dragged by its grip, over a tab's terminals, working out which pane it would join
/// and on which side.
struct PaneDropDelegate: DropDelegate {
    let panes: [UUID: CGRect]
    let tabID: UUID
    let app: AppModel
    @Binding var target: PaneDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        let isFiles = { (id: UUID) in app.tabs.first { $0.id == id }?.files != nil }
        if isFiles(tabID) { return false }
        if let dragged = app.draggingTabID { return dragged != tabID && !isFiles(dragged) }
        return app.draggingPaneID != nil
    }

    /// Over the pane being dragged there is nothing to join.
    private func target(at info: DropInfo) -> PaneDropTarget? {
        PaneDropTarget.find(at: info.location, in: panes, excluding: app.draggingPaneID)
    }

    func dropEntered(info: DropInfo) { target = target(at: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = target(at: info)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { target = nil }
        guard let goal = target(at: info) else { return false }
        if let moved = app.draggingTabID, moved != tabID {
            app.tabDropHandled()
            app.mergeTab(moved, into: tabID, beside: goal.pane, axis: goal.zone.axis, before: goal.zone.isBefore)
            return true
        }
        if let pane = app.draggingPaneID {
            app.tabDropHandled()
            app.movePane(pane, beside: goal.pane, inTab: tabID, axis: goal.zone.axis, before: goal.zone.isBefore)
            return true
        }
        return false
    }
}

struct DividerHandle: View {
    let divider: PaneLayout.Divider
    let tabID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: divider.frame.width, height: divider.frame.height)
            .contentShape(Rectangle())
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .gesture(
                DragGesture(coordinateSpace: .named("tab-\(tabID.uuidString)"))
                    .onChanged { value in
                        app.setSplitRatio(
                            PaneLayout.ratio(forDragTo: value.location, divider: divider),
                            split: divider.splitID, in: tabID
                        )
                    }
            )
            .onHover { inside in
                if inside {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Pane divider")
    }
}
