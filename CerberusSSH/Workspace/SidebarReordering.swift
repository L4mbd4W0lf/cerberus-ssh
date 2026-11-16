import SwiftUI
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

/// Where the drop indicator is drawn. One for the whole sidebar, so that "above this row" and "below the row
/// before it", which are the same place, draw the same line: it is always the bottom edge of the row before the
/// gap, or the top edge of the first row.
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

    private(set) var mark: Mark?
    private var owner: UUID?

    /// `row` is the one the pointer is over.
    func show(_ mark: Mark?, for row: UUID) {
        owner = row
        if self.mark != mark { self.mark = mark }
    }

    /// The pointer left `row`. Only clears what `row` drew: the row it moved to may already have drawn its own.
    func clear(for row: UUID) {
        guard owner == row else { return }
        owner = nil
        mark = nil
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
        switch position {
        case .inside:
            reordering.indicator.show(.box(row), for: row)
        case .below:
            reordering.indicator.show(.lineBelow(row), for: row)
        case .above:
            // The gap above this row is the gap below the one before it.
            let mark = reordering.rowAbove(row).map { SidebarDropIndicator.Mark.lineBelow($0) } ?? .lineAbove(row)
            reordering.indicator.show(mark, for: row)
        }
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
        let position = position(at: info)
        hoverController.cancel()
        guard let reordering else { return false }
        reordering.indicator.clear(for: target.rowID)
        let target = target
        let isOpen = !isCollapsed
        return loadDraggedID(from: info) { reordering.move($0, target, position, isOpen) }
    }
}

/// A drop in the empty space below the last row: the row goes to the end of the top level.
struct RootDropDelegate: DropDelegate {
    let reordering: SidebarReordering?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        reordering != nil && info.hasItemsConforming(to: [.sidebarNode])
    }

    func dropEntered(info: DropInfo) { isTargeted = true }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isTargeted = true
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let reordering else { return false }
        return loadDraggedID(from: info) { reordering.moveToTopLevel($0) }
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
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 5)))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .opacity(mark == .box(row) ? 1 : 0)
                    .allowsHitTesting(false)
            )
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
