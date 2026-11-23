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
    /// Where a dragged tab would go if let go now, while one is over these terminals.
    @State private var dropZone: PaneDropZone?
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
            .coordinateSpace(name: "tab-\(tab.id.uuidString)")
            .overlay {
                if let zone = dropZone {
                    let area = zone.highlight(in: geometry.size)
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
            // A tab dragged here joins the side of the middle it is let go on.
            .onDrop(of: [TabDrag.type], delegate: PaneDropDelegate(
                size: geometry.size, tabID: tab.id, app: app, zone: $dropZone
            ))
        }
    }
}

/// Follows a dragged tab over a tab's terminals, working out which side it would join.
struct PaneDropDelegate: DropDelegate {
    let size: CGSize
    let tabID: UUID
    let app: AppModel
    @Binding var zone: PaneDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged = app.draggingTabID else { return false }
        let isFiles = { (id: UUID) in app.tabs.first { $0.id == id }?.files != nil }
        return dragged != tabID && !isFiles(dragged) && !isFiles(tabID)
    }

    func dropEntered(info: DropInfo) { zone = PaneDropZone.zone(at: info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = PaneDropZone.zone(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { zone = nil }
        guard let moved = app.draggingTabID, moved != tabID,
              let side = PaneDropZone.zone(at: info.location, in: size) else { return false }
        app.tabDropHandled()
        app.mergeTab(moved, into: tabID, axis: side.axis, before: side.isBefore)
        return true
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
