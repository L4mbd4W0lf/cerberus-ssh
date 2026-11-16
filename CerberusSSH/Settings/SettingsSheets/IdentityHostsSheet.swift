import CerberusModels
import SwiftUI

/// The hosts that use an identity, with a search field (the same one as the sidebar: name, address, folder or #tag).
struct IdentityHostsSheet: View {
    let identity: Identity
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [SSHHost] {
        let query = SidebarSearch.parse(search)
        return (identity.hosts ?? [])
            .filter { host in
                SidebarSearch.matches(
                    query,
                    .init(
                        name: host.displayLabel,
                        hostname: host.hostname,
                        username: identity.username,
                        folderPath: host.folderPath,
                        tags: host.tags,
                        notes: host.notes ?? ""
                    )
                )
            }
            .sorted {
                $0.displayLabel.localizedStandardCompare($1.displayLabel)
                    == .orderedAscending
            }
    }

    private func detail(_ host: SSHHost) -> String {
        host.hostname + (host.port == 22 ? "" : ":\(host.port)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Hosts using “\(identity.name)”").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    "Search by name, address, folder or #tag",
                    text: $search
                )
                .textFieldStyle(.plain)
                .accessibilityIdentifier("identity-hosts-search")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(10)
            Divider()
            let shown = matches
            if shown.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "No host uses this identity",
                        systemImage: "server.rack"
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List(shown) { host in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.displayLabel)
                        Text(detail(host)).font(.caption).foregroundStyle(
                            .secondary
                        )
                    }
                }
                .accessibilityLabel("Hosts using this identity")
            }
            Divider()
            HStack {
                Text("\(identity.hosts?.count ?? 0) hosts").font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
    }
}
