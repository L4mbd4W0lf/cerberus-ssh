import SwiftUI
import CerberusModels

/// A host's tags as chips: each has an ✕ to take it off, and new ones are added by picking from the tags already
/// in use (so a spelling is made once) or by typing, where matching tags are suggested as you go.
struct TagEditor: View {
    @Binding var tags: [String]
    /// Every tag in use, with how many hosts carry it (see ``NodeTree/tagCounts(hosts:)``).
    let known: [(tag: String, count: Int)]

    @State private var draft = ""

    private var available: [(tag: String, count: Int)] {
        known.filter { entry in !tags.contains { $0.caseInsensitiveCompare(entry.tag) == .orderedSame } }
    }

    private var suggestions: [(tag: String, count: Int)] {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return Array(available.filter { $0.tag.localizedCaseInsensitiveContains(typed) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                TagFlow(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag) { tags.removeAll { $0 == tag } }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add tag", text: $draft, prompt: Text("Type a tag, then Return"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("tag-field")
                    .onSubmit { commit() }
                    .onChange(of: draft) { _, text in if text.contains(",") { commit() } }
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.tag) { entry in
                            Button("\(entry.tag) (\(entry.count))") { add(entry.tag) }
                        }
                    } label: {
                        Label("Existing Tags", systemImage: "tag")
                    }
                    .menuIndicator(.visible)
                    .fixedSize()
                    .accessibilityIdentifier("tag-menu")
                }
            }
            if !suggestions.isEmpty {
                TagFlow(spacing: 6) {
                    ForEach(suggestions, id: \.tag) { entry in
                        Button { add(entry.tag) } label: {
                            Text("#\(entry.tag)").font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tag-suggestion-\(entry.tag)")
                    }
                }
            }
        }
    }

    /// What was typed, split at commas. A tag that exists in another case takes the existing spelling.
    private func commit() {
        for typed in TagEdit.parse(draft) {
            add(known.first { $0.tag.caseInsensitiveCompare(typed) == .orderedSame }?.tag ?? typed)
        }
        draft = ""
    }

    private func add(_ tag: String) {
        tags = TagEdit.apply(to: tags, add: [tag], remove: [])
        draft = ""
    }
}

/// One tag as a chip. With `onRemove`, it has an ✕.
struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)").font(.caption)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove “\(tag)”")
                .accessibilityLabel("Remove tag \(tag)")
                .accessibilityIdentifier("tag-remove-\(tag)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Lays its children out in rows, wrapping to a new row when one is full.
struct TagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
