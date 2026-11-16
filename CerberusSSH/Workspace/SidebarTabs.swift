import SwiftUI
import AppKit
import CerberusModels

/// What the sidebar shows, picked with the navigator bar at its top, as in Xcode (spec §4.1).
enum SidebarTab: String, CaseIterable, Identifiable {
    case hosts, forwards, favourites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: "Favourites"
        case .hosts: "Hosts"
        case .forwards: "Port Forwards"
        }
    }

    var help: String {
        switch self {
        case .favourites: "Favourites"
        case .hosts: "Hosts and folders"
        case .forwards: "Port Forwards"
        }
    }

    var symbol: String {
        switch self {
        case .favourites: "star"
        case .hosts: "server.rack"
        case .forwards: "arrow.left.arrow.right"
        }
    }

    /// Filled where a filled symbol exists, so the chosen tab differs by shape as well as colour (spec §13.2).
    var selectedSymbol: String { self == .favourites ? "star.fill" : symbol }

    /// For the UI tests: `sidebar-tab-favourites`, `sidebar-tab-hosts`, `sidebar-tab-forwards`.
    var identifier: String { "sidebar-tab-\(rawValue)" }
}

/// A View-menu choice of tab, for one main window's sidebar.
struct SidebarTabRequest: Equatable {
    let tab: SidebarTab
    let window: UUID
}

/// The row of icon buttons at the top of the sidebar. All three are always there, in the same
/// places, so nothing moves under the pointer; the chosen one has a highlight and its filled
/// symbol. Switching is instant: nothing slides.
struct SidebarTabBar: View {
    @Binding var selection: SidebarTab
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    private var isInactive: Bool { activeState == .inactive }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    button(tab)
                }
            }
            .padding(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(isInactive ? Color.primary.fill(0.15, contrast) : nil), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar-tab-bar")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ tab: SidebarTab) -> some View {
        let isSelected = tab == selection
        return Button { selection = tab } label: {
            Image(systemName: isSelected ? tab.selectedSymbol : tab.symbol)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isInactive ? Color(nsColor: .disabledControlTextColor) : Color.primary)
                .frame(width: 32, height: 26)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(isInactive ? 0.1 : 0.18))
                            .overlay { if contrast == .increased { Capsule().strokeBorder(Color.accentColor) } }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier(tab.identifier)
        // The chosen tab, for the UI tests, which read it from the button.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Hosts tab's bottom bar: a round + for a new host or folder, and the filter. Both are glass
/// floating over the list, as in Xcode's navigator; show it with `safeAreaBar` so the list scrolls
/// beneath it.
struct SidebarBottomBar: View {
    @Binding var filter: String
    @Binding var order: HostSortOrder
    let onNewHost: () -> Void
    let onNewFolder: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                addMenu
                filterField
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addMenu: some View {
        Menu {
            Group {
                Button("New Host…", systemImage: "plus", action: onNewHost)
                Button("New Folder…", systemImage: "folder.badge.plus", action: onNewFolder)
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Add a host or folder")
        .accessibilityLabel("Add a host or folder")
        .accessibilityIdentifier("sidebar-add")
    }

    /// A plain field rather than `.searchable`, which would also claim ⌘F and clash with Find in the terminal.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .autocorrectionDisabled()
                .accessibilityLabel("Filter")
                .accessibilityIdentifier("sidebar-filter")
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear the filter")
                    .accessibilityIdentifier("sidebar-filter-clear")
                    .accessibilityLabel("Clear the filter")
            }
            sortMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassEffect(.regular, in: .capsule)
        .help("Filter by name, address, user, folder or notes. Start a word with # to match a tag.")
    }

    /// Accent-coloured when the order is not the default, so a changed order is noticed.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $order) {
                HostSortOrderChoices()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(order == .default ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by: \(order.title)")
        .accessibilityLabel("Sort by")
        .accessibilityValue(order.title)
        .accessibilityIdentifier("sidebar-sort")
    }
}

/// The sort orders as picker choices.
struct HostSortOrderChoices: View {
    var body: some View {
        ForEach(HostSortOrder.allCases) { Text($0.title).tag($0) }
    }
}

/// The Favourites tab: favourite hosts in a flat list.
struct FavouriteRows: View {
    let hosts: [SSHHost]
    let selection: Set<UUID>
    let sessions: [SessionViewModel]

    var body: some View {
        ForEach(hosts) { host in
            HostRow(
                host: host,
                sessions: sessions.filter { $0.hostID == host.id },
                isSelected: selection.contains(host.id)
            )
            .tag(host.id)
        }
    }
}
