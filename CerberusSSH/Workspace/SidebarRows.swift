import SwiftUI
import SwiftData
import AppKit
import CerberusModels
import CerberusVault
import CerberusSSHCore


/// The recursive tree of folders and hosts. A struct of its own, so it can contain itself.
struct NodeRows: View {
    let rows: [NodeTree.Row]
    let selection: Set<UUID>
    @Environment(\.controlActiveState) private var activeState
    @Binding var collapsed: Set<UUID>
    let sessions: [SessionViewModel]
    /// What a drop does; nil unless the sidebar is in Custom Order and shows the whole tree.
    var reordering: SidebarReordering? = nil

    var body: some View {
        ForEach(rows) { row in
            rowView(row)
        }
    }

    @ViewBuilder
    private func rowView(_ row: NodeTree.Row) -> some View {
        let node = row.node
        if let host = node.host {
            HostRow(host: host, sessions: sessions.filter { $0.hostID == host.id }, isSelected: selection.contains(host.id))
                .reorderable(node, selection: selection, isCollapsed: false, reordering: reordering, expand: {})
                .tag(host.id)
        } else {
            let id = node.id
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsed.contains(id) },
                set: { expanded in
                    if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                }
            )) {
                NodeRows(rows: row.children, selection: selection, collapsed: $collapsed, sessions: sessions, reordering: reordering)
            } label: {
                Label {
                    Text(node.name).lineLimit(1)
                } icon: {
                    // The same blue as the selection behind it would vanish, so a
                    // selected folder is white (grey highlight: stays blue).
                    Image(systemName: "folder.fill")
                        .foregroundStyle(selection.contains(id) && activeState != .inactive ? Color.onHighlight : (node.effectiveColor?.color ?? Color.accentColor))
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // A double click opens or closes the folder through the list's primary action, not a
                    // tap gesture here: on macOS 26 one takes the mouse down, and the row cannot be dragged.
                    // Open for a dragged row that waits over it.
                    .reorderable(node, selection: selection, isCollapsed: collapsed.contains(id), reordering: reordering) {
                        collapsed.remove(id)
                    }
            }
            // Selectable, so the row knows when it is selected.
            .tag(id)
        }
    }
}

struct HostRow: View {
    let host: SSHHost
    let sessions: [SessionViewModel]
    var isSelected = false
    /// Secondary text after the name: the folder's path, in the Favourites tab.
    var detail: String? = nil
    @Environment(\.controlActiveState) private var activeState

    /// White on the accent-coloured highlight; normal text on the grey one of an inactive window.
    private var onHighlight: Bool { isSelected && activeState != .inactive }

    /// The most advanced state among this host's sessions.
    private var status: (symbol: String, color: Color, text: String) {
        if sessions.contains(where: \.isLive) { return ("checkmark.circle.fill", Color.statusGood, "connected") }
        if sessions.contains(where: { $0.reconnectIn != nil }) { return ("arrow.triangle.2.circlepath", Color.statusWarning, "reconnecting") }
        if sessions.contains(where: { if case .disconnected(let r) = $0.state { r.isFatal } else { false } }) {
            return ("xmark.octagon.fill", Color.statusBad, "failed")
        }
        if sessions.contains(where: { !$0.canReconnect }) { return ("circle.dotted", Color.statusWarning, "connecting") }
        if !sessions.isEmpty { return ("minus.circle.fill", .secondary, "disconnected") }
        return ("circle", .secondary.opacity(0.6), "idle")
    }

    var body: some View {
        // One line, like a file in a file browser: an icon, the name, and a small mark at the
        // end when there is a session. The address and tags are in the tooltip.
        HStack(spacing: 6) {
            // The folder's colour, as a thin mark at the edge.
            if let color = host.effectiveColor {
                NodeColorMark(color: color)
            }
            // The system's logo in its own colours; the server symbol, tinted by state, until a connection has found it out.
            HostOSIcon(os: host.detectedOS, fallbackTint: onHighlight ? Color.onHighlight : iconColor)
                .frame(width: 16, height: 16)
            Text(host.displayLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(onHighlight ? Color.onHighlight : Color.primary)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(onHighlight ? Color.onHighlight.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 4)
            // Shape as well as colour; nothing at all for an idle host.
            if status.text != "idle" {
                Image(systemName: status.symbol)
                    .foregroundStyle(onHighlight ? Color.onHighlight : status.color)
                    .font(.system(size: 10))
            }
        }
        .help(subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.displayLabel), \(status.text)" + (detail.map { ", \($0)" } ?? "")
            + (host.effectiveColor.map { ", \($0.displayName.lowercased()) folder" } ?? ""))
    }

    /// The generic server icon takes the colour of the state, and stays neutral when idle.
    private var iconColor: Color {
        switch status.text {
        case "idle", "disconnected": .secondary
        default: status.color
        }
    }

    private var subtitle: String {
        let user = host.loginUsername ?? ""
        let authority = user.isEmpty ? host.hostname : "\(user)@\(host.hostname)"
        let withPort = host.port == 22 ? authority : "\(authority):\(host.port)"
        let tagged = host.tags.isEmpty ? withPort : withPort + "  " + host.tags.map { "#\($0)" }.joined(separator: " ")
        return host.isFavourite ? tagged + "\nFavourite" : tagged
    }
}
