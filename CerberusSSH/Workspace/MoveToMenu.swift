import SwiftUI
import CerberusModels

/// "Move To…": the top level, then the folders as submenus that follow the tree. A folder with subfolders
/// opens a submenu of its own, whose first item moves into that folder itself.
struct MoveToMenu: View {
    let folders: [TreeNode]
    /// The folders being moved: none of them may go into itself or one of its own subfolders.
    let moving: [TreeNode]
    let onMove: (TreeNode?) -> Void

    var body: some View {
        let roots = folders.filter { $0.parent == nil }
        Menu("Move To…", systemImage: "folder") {
            Button("None (Top Level)") { onMove(nil) }
            if !roots.isEmpty { Divider() }
            MoveToItems(nodes: roots, moving: moving, onMove: onMove)
        }
    }
}

private struct MoveToItems: View {
    let nodes: [TreeNode]
    let moving: [TreeNode]
    let onMove: (TreeNode?) -> Void

    var body: some View {
        ForEach(nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.id) { folder in
            let subfolders = (folder.children ?? []).filter(\.isFolder)
            let allowed = moving.allSatisfy { $0.canMove(under: folder) }
            if subfolders.isEmpty {
                Button(folder.name) { onMove(folder) }
                    .disabled(!allowed)
            } else {
                Menu(folder.name) {
                    Button("This Folder") { onMove(folder) }
                        .disabled(!allowed)
                    Divider()
                    MoveToItems(nodes: subfolders, moving: moving, onMove: onMove)
                }
            }
        }
    }
}
