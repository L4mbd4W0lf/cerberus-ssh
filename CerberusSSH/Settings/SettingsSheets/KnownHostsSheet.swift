import CerberusModels
import CerberusVault
import SwiftData
//
//  KnownHostsSheet.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//
import SwiftUI

struct KnownHostsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var parsed: KnownHostsParser.Result?
    @State private var preview: ImportPreview?
    @State private var fileName: String?
    @State private var result: ImportResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import known_hosts", systemImage: "checkmark.shield")
                .font(.title2.bold())

            if let result {
                Label(
                    "Imported \(result.added) host keys.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(Color.statusGood)
                if !result.hostKeyConflicts.isEmpty {
                    Text(
                        "\(result.hostKeyConflicts.count) hosts already have a different trusted key and were left unchanged."
                    )
                    .foregroundStyle(Color.statusWarning)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(
                        .defaultAction
                    )
                }
            } else if let parsed, let preview {
                Text(
                    "**\(parsed.records.count)** host keys found in \(fileName ?? "the file"); **\(preview.knownHostKeys.new)** are new."
                )
                if parsed.skippedTotal > 0 {
                    skippedSummary(parsed)
                }
                if !preview.hostKeyConflicts.isEmpty {
                    Label(
                        "\(preview.hostKeyConflicts.count) hosts have a different key than the one you already trust. Those are never overwritten.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(Color.statusWarning)
                }
                actions(canImport: preview.knownHostKeys.new > 0)
            } else {
                Text(
                    "Choose your known_hosts file. Entries are copied into CerberusSSH's own trust store, so the app never depends on ~/.ssh."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(
                        "Choose file…",
                        systemImage: "doc",
                        action: chooseFile
                    ).keyboardShortcut(.defaultAction)
                }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(
                    Color.statusBad
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func skippedSummary(_ parsed: KnownHostsParser.Result) -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            Text("Skipped \(parsed.skippedTotal) entries that can't be used:")
                .font(.callout)
            Group {
                if parsed.skippedHashed > 0 {
                    Text(
                        "• \(parsed.skippedHashed) hashed host names (can't be reversed)"
                    )
                }
                if parsed.skippedPatterns > 0 {
                    Text(
                        "• \(parsed.skippedPatterns) wildcard or negated patterns"
                    )
                }
                if parsed.skippedKeyTypes > 0 {
                    Text(
                        "• \(parsed.skippedKeyTypes) DSA or other unsupported key types"
                    )
                }
                if parsed.skippedAuthorities > 0 {
                    Text(
                        "• \(parsed.skippedAuthorities) certificate authorities"
                    )
                }
                if parsed.malformed > 0 {
                    Text("• \(parsed.malformed) unreadable lines")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actions(canImport: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                .cancelAction
            )
            Button("Import") { Task { await importKeys() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = KnownHostsParser.parse(text)
            parsed = result
            fileName = url.lastPathComponent
            preview = try BackupService.preview(
                BackupService.archive(from: result),
                context: modelContext
            )
            error = nil
        } catch {
            CerberusLog.caught(error)
            self.error = error.localizedDescription
        }
    }

    private func importKeys() async {
        guard let parsed else { return }
        do {
            result = try await BackupService.apply(
                BackupService.archive(from: parsed),
                mode: .merge,
                context: modelContext,
                vault: app.vault
            )
        } catch {
            CerberusLog.caught(error)
            self.error = error.localizedDescription
        }
    }
}
