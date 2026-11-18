import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CerberusModels

// Drag and drop in the Hosts sidebar, for Custom Order only (HostSortOrder.custom). Rows are dragged onto
// the top, middle or bottom of another row, or onto the empty space below the list; see NodeReordering for the
// rules that move and renumber the nodes.

extension UTType {
    /// A sidebar row being dragged. Declared in Info.plist.
    nonisolated static let sidebarNode = UTType(exportedAs: "com.cerberusssh.sidebar-node", conformingTo: .data)
}

/// What a drag carries: the ids of the rows being dragged (``TreeNode/rowID``). A model object cannot be
/// encoded, and the drop looks the nodes up again.
struct DraggedRows: Codable, Transferable {
    let ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sidebarNode)
    }
}

/// Where the drop indicator is drawn, and what a drop there does. One for the whole sidebar, so that "above
/// this row" and "below the row before it", which are the same place, draw the same line: it is always the
/// bottom edge of the row before the gap, or the top edge of the first row.
///
/// The rows' drop areas sit inside the list's own, for the space below the rows. macOS 26 can tell both of
/// them about the same drag, deliver the drop to either, and leave out the exits, so neither drop area
/// trusts its own callbacks: whichever drew last says what the drop does, any drop clears everything, and so
/// does the first click, key or mouse move after a drag that ended without one.
@MainActor @Observable
final class SidebarDropIndicator {
    enum Mark: Equatable {
        /// A line along the bottom edge of this row.
        case lineBelow(UUID)
        /// A line along the top edge of this row, which has nothing above it.
        case lineAbove(UUID)
        /// A box around this folder's row: a drop goes inside it.
        case box(UUID)
    }

    typealias Drop = @MainActor (_ draggedIDs: [UUID]) -> Void

    private(set) var mark: Mark?
    /// The line in the empty space below the rows: a drop goes to the end of the top level.
    private(set) var isAtEnd = false
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var drop: Drop?
    @ObservationIgnored private var lastRowUpdate: ContinuousClock.Instant?
    @ObservationIgnored private var monitor: Any?

    /// `row` is the one the pointer is over; `drop` is what a drop now does.
    func show(_ mark: Mark, for row: UUID, drop: @escaping Drop) {
        owner = row
        self.drop = drop
        lastRowUpdate = .now
        if self.mark != mark { self.mark = mark }
        if isAtEnd { isAtEnd = false }
        watchForDragEnd()
    }

    /// The pointer is over the space below the rows. Over a row the list hears the drag too, so the row,
    /// while it is still hearing it, wins.
    func showAtEnd(drop: @escaping Drop) {
        if let lastRowUpdate, ContinuousClock.now - lastRowUpdate < .milliseconds(150) { return }
        owner = nil
        self.drop = drop
        if mark != nil { mark = nil }
        if !isAtEnd { isAtEnd = true }
        watchForDragEnd()
    }

    /// The pointer left `row`. Only clears what `row` drew: the row it moved to may already have drawn its own.
    func clear(for row: UUID) {
        guard owner == row else { return }
        reset()
    }

    /// The pointer left the space below the rows.
    func clearAtEnd() {
        guard isAtEnd else { return }
        reset()
    }

    /// What the drop does, for the last place drawn, and clears everything. Nil when nothing was drawn, or
    /// when another drop area already took it.
    func takeDrop() -> Drop? {
        let drop = drop
        reset()
        return drop
    }

    func reset() {
        owner = nil
        drop = nil
        lastRowUpdate = nil
        if mark != nil { mark = nil }
        if isAtEnd { isAtEnd = false }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A drag that ends anywhere but a drop area tells no one. The window sees none of these events while
    /// the drag goes on, so the first one means it is over.
    private func watchForDragEnd() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.reset() }
            return event
        }
    }
}

/// What the sidebar does with a drop. Nil where dragging is off: any other order, the other tabs, or while
/// the filter is in use (the rows shown are then not the level they sit in).
struct SidebarReordering {
    /// `targetIsOpen`: the target is a folder shown open, so a drop just below its row is above its first child.
    let move: @MainActor (_ draggedIDs: [UUID], _ target: TreeNode, _ position: DropPosition, _ targetIsOpen: Bool) -> Void
    let moveToTopLevel: @MainActor (_ draggedIDs: [UUID]) -> Void
    /// The row shown just above the one with this id (``TreeNode/rowID``), nil for the first.
    let rowAbove: @MainActor (_ rowID: UUID) -> UUID?
    let indicator: SidebarDropIndicator
}

/// Opens a collapsed folder after a dragged row has hovered over it for a moment, as Finder does.
@MainActor
final class HoverExpandController {
    private var hoverTask: Task<Void, Never>?

    func scheduleExpansion(_ expand: @escaping @MainActor () -> Void) {
        guard hoverTask == nil else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            expand()
            hoverTask = nil
        }
    }

    func cancel() {
        hoverTask?.cancel()
        hoverTask = nil
    }
}

/// Reads the dragged rows' ids out of a drop and hands it to `then`, on the main actor.
@MainActor
private func loadDraggedID(from info: DropInfo, then: @escaping @MainActor ([UUID]) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [.sidebarNode]).first else { return false }
    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.sidebarNode.identifier) { data, _ in
        guard let data, let dragged = try? JSONDecoder().decode(DraggedRows.self, from: data) else { return }
        DispatchQueue.main.async { then(dragged.ids) }
    }
    return true
}

/// A drop on a row: the part of the row the pointer is over says where the dragged row goes.
struct TreeDropDelegate: DropDelegate {
    let target: TreeNode
    let rowHeight: CGFloat
    let isCollapsed: Bool
    let reordering: SidebarReordering?
    let expand: @MainActor () -> Void
    let hoverController: HoverExpandController

    private func position(at info: DropInfo) -> DropPosition {
        DropPosition(y: info.location.y, height: rowHeight, isFolder: target.isFolder)
    }

    func validateDrop(info: DropInfo) -> Bool {
        reordering != nil && info.hasItemsConforming(to: [.sidebarNode])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let reordering else { return nil }
        let position = position(at: info)
        let row = target.rowID
        let mark: SidebarDropIndicator.Mark = switch position {
        case .inside: .box(row)
        case .below: .lineBelow(row)
        // The gap above this row is the gap below the one before it.
        case .above: reordering.rowAbove(row).map { .lineBelow($0) } ?? .lineAbove(row)
        }
        let target = target
        let isOpen = !isCollapsed
        reordering.indicator.show(mark, for: row) { reordering.move($0, target, position, isOpen) }
        if position == .inside && isCollapsed {
            hoverController.scheduleExpansion(expand)
        } else {
            hoverController.cancel()
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        reordering?.indicator.clear(for: target.rowID)
        hoverController.cancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        hoverController.cancel()
        // The place drawn last, which may be the space below the rows (see SidebarDropIndicator).
        guard let drop = reordering?.indicator.takeDrop() else { return false }
        return loadDraggedID(from: info, then: drop)
    }
}

/// A drop in the empty space below the last row: the row goes to the end of the top level.
struct RootDropDelegate: DropDelegate {
    let reordering: SidebarReordering?

    func validateDrop(info: DropInfo) -> Bool {
        reordering != nil && info.hasItemsConforming(to: [.sidebarNode])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let reordering else { return nil }
        reordering.indicator.showAtEnd { reordering.moveToTopLevel($0) }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { reordering?.indicator.clearAtEnd() }

    func performDrop(info: DropInfo) -> Bool {
        // The place drawn last, which may be a row (see SidebarDropIndicator).
        guard let drop = reordering?.indicator.takeDrop() else { return false }
        return loadDraggedID(from: info, then: drop)
    }
}

/// Makes a row draggable, and a drop target over the whole of its row (the label alone is shorter than the
/// row, which left strips between rows that took no drop).
private struct ReorderableRow: ViewModifier {
    let node: TreeNode
    /// The rows a drag of this one takes: just it, or the whole selection when it is part of one.
    let dragIDs: [UUID]
    let isCollapsed: Bool
    let reordering: SidebarReordering?
    let expand: @MainActor () -> Void

    func body(content: Content) -> some View {
        if let reordering {
            content
                .draggable(DraggedRows(ids: dragIDs)) {
                    DragCount(count: dragIDs.count, title: node.title)
                }
                .listRowBackground(RowDropArea(node: node, isCollapsed: isCollapsed, reordering: reordering, expand: expand))
        } else {
            content
        }
    }
}

/// The row's background: it fills the whole row, so it takes the drop and draws the indicator.
private struct RowDropArea: View {
    let node: TreeNode
    let isCollapsed: Bool
    let reordering: SidebarReordering
    let expand: @MainActor () -> Void

    @State private var rowHeight: CGFloat = 24
    @State private var hoverController = HoverExpandController()

    var body: some View {
        let mark = reordering.indicator.mark
        let row = node.rowID
        Color.clear
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
            // Inside a folder: the row is boxed.
            .overlay(DropTargetBox().opacity(mark == .box(row) ? 1 : 0))
            // Between two rows: the line along the bottom edge of the upper one (or the top of the first).
            .overlay(alignment: mark == .lineAbove(row) ? .top : .bottom) {
                if mark == .lineBelow(row) || mark == .lineAbove(row) {
                    DropIndicatorLine()
                        .padding(.horizontal, 8)
                }
            }
            .onDrop(of: [.sidebarNode], delegate: TreeDropDelegate(
                target: node, rowHeight: rowHeight, isCollapsed: isCollapsed, reordering: reordering,
                expand: expand, hoverController: hoverController
            ))
    }
}

/// The box round a row that a drop would go into: a folder in the sidebar, or a folder in a file pane.
struct DropTargetBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 5)))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Dragging and dropping for a sidebar row; does nothing while `reordering` is nil.
    ///
    /// `selection` is what is selected in the sidebar: dragging a selected row drags all of it.
    func reorderable(
        _ node: TreeNode, selection: Set<UUID>, isCollapsed: Bool, reordering: SidebarReordering?,
        expand: @escaping @MainActor () -> Void
    ) -> some View {
        let dragIDs = selection.contains(node.rowID) && selection.count > 1 ? Array(selection) : [node.rowID]
        return modifier(ReorderableRow(
            node: node, dragIDs: dragIDs, isCollapsed: isCollapsed, reordering: reordering, expand: expand
        ))
    }
}

/// What is shown under the pointer while dragging: the row's name, or how many rows.
private struct DragCount: View {
    let count: Int
    let title: String

    var body: some View {
        Text(count > 1 ? "\(count) items" : title)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The line that shows where a drop will land.
struct DropIndicatorLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        // Without this the line takes the pointer's events and the row under it flickers in and out of the drag.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
