//
//  SnippetPaletteSheet.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//

import CerberusModels
import SwiftData
import SwiftUI

// MARK: - Palette (⇧⌘K)

/// Search saved commands and send one to the focused pane, or to the whole broadcast group
/// when the pane is part of one (spec §9.4). A snippet with `{{placeholders}}` asks for its
/// values first.
struct SnippetPalette: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query private var snippets: [Snippet]

    @State private var query = ""
    @State private var selection = 0
    @State private var filling: Snippet?
    @State private var values: [String: String] = [:]
    @FocusState private var isSearching: Bool
    /// Panes picked by hand with "Choose panes…". Empty means the usual: the focused pane, or its
    /// broadcast group.
    @State private var chosen = Set<UUID>()
    @State private var isChoosing = false

    private var session: SessionViewModel? { app.selectedSession }

    private var results: [Snippet] {
        let candidates = snippets.map {
            SnippetSearch.Candidate(
                id: $0.id,
                title: $0.title,
                body: $0.body,
                tags: $0.tags,
                scopeHostIDs: $0.scopeHostIDs
            )
        }
        let order = SnippetSearch.rank(
            query,
            in: candidates,
            for: session?.hostID
        ).map(\.id)
        let byID = Dictionary(
            snippets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return order.compactMap { byID[$0] }
    }

    var body: some View {
        Group {
            if let snippet = filling {
                fillForm(for: snippet)
            } else {
                chooser
            }
        }
        .frame(width: 520, height: 400)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        let shown = results
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search snippets…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearching)
                    .onSubmit { choose(shown) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(12)

            Divider()

            if session == nil {
                notice(
                    "Open a session first. Snippets are typed into the focused pane."
                )
            } else if shown.isEmpty {
                notice(
                    snippets.isEmpty
                        ? "No snippets yet. Add some in Settings ▸ Snippets."
                        : "No matching snippets."
                )
            } else {
                List(Array(shown.enumerated()), id: \.element.id) {
                    index,
                    snippet in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snippet.title)
                        Text(preview(of: snippet)).font(.caption)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(
                        index == selection
                            ? Color.accentColor.opacity(0.25) : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = index
                        choose(shown)
                    }
                }
                .listStyle(.plain)
            }

            Divider()
            HStack {
                if !chosen.isEmpty {
                    Label(
                        "Sends to \(chosen.count) chosen pane\(chosen.count == 1 ? "" : "s")",
                        systemImage: "checklist"
                    )
                    .foregroundStyle(Color.broadcastIndicator)
                    .accessibilityIdentifier("snippet-target")
                } else if let session, app.groupSize(for: session) > 1 {
                    Label(
                        "Sends to \(app.groupSize(for: session)) broadcast panes",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .foregroundStyle(Color.broadcastIndicator)
                } else {
                    Text("Sends to the focused pane").accessibilityIdentifier(
                        "snippet-target"
                    )
                }
                Button("Choose panes…") { isChoosing = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("snippet-choose-panes")
                    .popover(isPresented: $isChoosing, arrowEdge: .top) {
                        paneChooser
                    }
                Spacer()
                Text("↩ send · esc close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .onAppear { isSearching = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, shown.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
    }

    private var paneChooser: some View {
        let choices = app.paneChoices()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Send to these panes").font(.headline)
            if choices.isEmpty {
                Text("No pane is connected.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices) { choice in
                            Toggle(
                                isOn: Binding(
                                    get: { chosen.contains(choice.id) },
                                    set: { isOn in
                                        if isOn {
                                            chosen.insert(choice.id)
                                        } else {
                                            chosen.remove(choice.id)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(choice.title)
                                    Text(choice.tabTitle).font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier(
                                "snippet-pane-\(choice.title)"
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Button("Clear") { chosen = [] }.disabled(chosen.isEmpty)
                Spacer()
                Button("Done") { isChoosing = false }.keyboardShortcut(
                    .defaultAction
                )
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func notice(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(
            maxWidth: .infinity,
            minHeight: 80
        )
    }

    private func preview(of snippet: Snippet) -> String {
        snippet.body.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private func choose(_ shown: [Snippet]) {
        guard session != nil, shown.indices.contains(selection) else { return }
        let snippet = shown[selection]
        let template = SnippetTemplate(snippet.body)
        guard template.hasPlaceholders else {
            send(snippet, values: [:])
            return
        }
        values = Dictionary(
            uniqueKeysWithValues: template.placeholders.map {
                ($0.name, $0.defaultValue ?? "")
            }
        )
        filling = snippet
    }

    // MARK: Filling placeholders

    private func fillForm(for snippet: Snippet) -> some View {
        let template = SnippetTemplate(snippet.body)
        return VStack(alignment: .leading, spacing: 12) {
            Text(snippet.title).font(.title3.bold())
            Text(SnippetTemplate.sanitise(template.expand(values)))
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .lineLimit(3)
            ForEach(template.placeholders) { placeholder in
                HStack {
                    Text(placeholder.name).frame(
                        width: 120,
                        alignment: .trailing
                    )
                    TextField(
                        "",
                        text: Binding(
                            get: { values[placeholder.name] ?? "" },
                            set: { values[placeholder.name] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(snippet, values: values) }
                }
            }
            Text(
                "Line breaks and control characters in what you type are removed."
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Back") { filling = nil }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button("Send") { send(snippet, values: values) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func send(_ snippet: Snippet, values: [String: String]) {
        guard let session else { return }
        let bytes = SnippetTemplate(snippet.body).bytes(
            values: values,
            sendNewline: snippet.sendNewline
        )
        dismiss()
        if chosen.isEmpty {
            app.sendToGroup(bytes, from: session)
        } else {
            app.sendToPanes(bytes, panes: chosen)
        }
    }
}
