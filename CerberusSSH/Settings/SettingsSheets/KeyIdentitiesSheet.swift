import CerberusModels
import SwiftUI

/// The identities that sign in with a vault key, with a search field.
struct KeyIdentitiesSheet: View {
    let keyName: String
    let identities: [Identity]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [Identity] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return
            identities
            .filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.username.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Identities using “\(keyName)”").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or user", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("key-identities-search")
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
                        "No identity uses this key",
                        systemImage: "person.badge.key"
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List(shown) { identity in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.name)
                        Text(identity.username).font(.caption).foregroundStyle(
                            .secondary
                        )
                    }
                }
                .accessibilityLabel("Identities using this key")
            }
            Divider()
            HStack {
                Text(
                    identities.count == 1
                        ? "1 identity" : "\(identities.count) identities"
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
    }
}
