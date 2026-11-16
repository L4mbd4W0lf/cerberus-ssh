//
//  SnippetEditorSheet.swift
//  CerberusSSH
//
//  Created by Adrian Hall on 2026/11/12.
//

import CerberusModels
import SwiftData
import SwiftUI

struct SnippetEditorSheet: View {
    let snippet: Snippet?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]

    @State private var title = ""
    @State private var text = ""
    @State private var tagsText = ""
    @State private var sendNewline = true
    @State private var limitToHosts = false
    @State private var scope = Set<UUID>()

    private var template: SnippetTemplate { SnippetTemplate(text) }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command").font(.callout)
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6).strokeBorder(
                                    .separator
                                )
                            )
                        if template.hasPlaceholders {
                            Label(
                                "Asks for: "
                                    + template.placeholders.map(\.name).joined(
                                        separator: ", "
                                    ),
                                systemImage: "text.cursor"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(
                                "Use {{name}} or {{name:default}} for parts that change. Write \\{{ for a literal {{."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Press Return after sending", isOn: $sendNewline)
                    TextField(
                        "Tags",
                        text: $tagsText,
                        prompt: Text("deploy, docker")
                    )
                }

                Section("Available on") {
                    Picker("Hosts", selection: $limitToHosts) {
                        Text("All hosts").tag(false)
                        Text("Only selected hosts").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if limitToHosts {
                        ForEach(hosts) { host in
                            Toggle(
                                isOn: Binding(
                                    get: { scope.contains(host.id) },
                                    set: { isOn in
                                        if isOn {
                                            scope.insert(host.id)
                                        } else {
                                            scope.remove(host.id)
                                        }
                                    }
                                )
                            ) {
                                HStack(spacing: 6) {
                                    HostOSIcon(os: host.detectedOS).frame(
                                        width: 16,
                                        height: 14
                                    )
                                    Text(host.displayLabel)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button(snippet == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            guard let snippet else { return }
            title = snippet.title
            text = snippet.body
            tagsText = snippet.tags.joined(separator: ", ")
            sendNewline = snippet.sendNewline
            limitToHosts = !snippet.scopeHostIDs.isEmpty
            scope = Set(snippet.scopeHostIDs)
        }
    }

    private func save() {
        let target = snippet ?? Snippet()
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.body = text
        target.tags = TagEdit.parse(tagsText)
        target.sendNewline = sendNewline
        target.scopeHostIDs = limitToHosts ? Array(scope) : []
        if snippet == nil { modelContext.insert(target) }
        modelContext.saveLogged()
        dismiss()
    }
}
