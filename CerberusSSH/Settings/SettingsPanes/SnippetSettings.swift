import CerberusModels
import SwiftData
import SwiftUI

// MARK: - Managing snippets (Settings ▸ Snippets)

struct SnippetsSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Snippet.title) private var snippets: [Snippet]

    @State private var selection: UUID?
    @State private var editing: Snippet?
    @State private var isAdding = false
    @State private var pendingDeletion: Snippet?

    private var selected: Snippet? { snippets.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(snippets) { snippet in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.title)
                            if !snippet.isGlobal {
                                Text(
                                    "\(snippet.scopeHostIDs.count) host\(snippet.scopeHostIDs.count == 1 ? "" : "s")"
                                )
                                .font(.caption2).padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(
                            snippet.body.replacingOccurrences(
                                of: "\n",
                                with: " ⏎ "
                            )
                        )
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(snippet.id)
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if snippets.isEmpty {
                    ContentUnavailableView(
                        "No snippets",
                        systemImage: "text.badge.plus",
                        description: Text(
                            "Save commands you type often, with {{placeholders}} for the parts that change."
                        )
                    )
                }
            }

            Divider()
            HStack {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
                Button("Edit…", systemImage: "pencil") { editing = selected }
                    .disabled(selected == nil)
                Button("Delete…", systemImage: "trash", role: .destructive) {
                    pendingDeletion = selected
                }.disabled(selected == nil)
                Spacer()
                Text("Insert with ⇧⌘K").font(.caption).foregroundStyle(
                    .secondary
                )
            }
            .padding(10)
        }
        .sheet(isPresented: $isAdding) { SnippetEditorSheet(snippet: nil) }
        .sheet(item: $editing) { SnippetEditorSheet(snippet: $0) }
        .confirmationDialog(
            "Delete this snippet?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { snippet in
            Button("Delete \(snippet.title)", role: .destructive) {
                modelContext.delete(snippet)
                modelContext.saveLogged()
                selection = nil
            }
        }
    }
}
