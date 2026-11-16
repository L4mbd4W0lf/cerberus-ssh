import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

struct KnownHostsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KnownHostKey.hostPattern) private var keys: [KnownHostKey]

    @State private var selection = Set<UUID>()
    @State private var isConfirmingRemoval = false
    @State private var isImporting = false
    @State private var search = ""
    @State private var sortOrder = [
        KeyPathComparator(
            \KnownHostKey.hostPattern,
            comparator: .localizedStandard
        )
    ]
    @State private var notice: String?

    private var filtered: [KnownHostKey] {
        guard !search.isEmpty else { return keys.sorted(using: sortOrder) }
        return keys.sorted(using: sortOrder).filter {
            $0.hostPattern.localizedCaseInsensitiveContains(search)
                || $0.fingerprintSHA256.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedKeys: [KnownHostKey] {
        keys.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    "Host keys you trust. A changed key blocks the connection until you decide."
                )
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Import…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(
                    "Host",
                    value: \.hostPattern,
                    comparator: .localizedStandard
                ) { Text($0.hostPattern) }
                TableColumn("Type", value: \.keyType) {
                    Text($0.keyType).foregroundStyle(.secondary)
                }.width(130)
                TableColumn("Fingerprint", value: \.fingerprintSHA256) {
                    Text($0.fingerprintSHA256)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                TableColumn("Source", value: \.sourceSortKey) {
                    Text(label($0.source))
                }.width(70)
                TableColumn("Added", value: \.addedAt) {
                    Text(
                        $0.addedAt.formatted(date: .abbreviated, time: .omitted)
                    )
                }.width(100)
                TableColumn("Status", value: \.statusSortKey) {
                    if $0.revoked {
                        Label("Revoked", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(Color.statusBad)
                    } else {
                        Label("Trusted", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.statusGood)
                    }
                }.width(90)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityLabel("Trusted host keys")
            .overlay {
                if keys.isEmpty {
                    ContentUnavailableView(
                        "No known hosts",
                        systemImage: "checkmark.shield",
                        description: Text(
                            "Hosts you trust on first connect appear here."
                        )
                    )
                }
            }

            Divider()
            HStack {
                TextField("Filter", text: $search).textFieldStyle(
                    .roundedBorder
                ).frame(width: 180)
                Spacer()
                Button("Copy Fingerprint", systemImage: "doc.on.doc") {
                    copyFingerprint()
                }
                .disabled(selectedKeys.count != 1)
                Button(allRevoked ? "Restore Trust" : "Revoke") {
                    Task { await toggleRevoked() }
                }
                .disabled(selectedKeys.isEmpty)
                Button("Remove…", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(selectedKeys.isEmpty)
            }
            .padding(10)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $isImporting) { KnownHostsSheet() }
        .confirmationDialog(
            "Remove \(selectedKeys.count) known host key\(selectedKeys.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text(
                "The next connection to these hosts will ask you to verify the key again."
            )
        }
    }

    private var allRevoked: Bool {
        !selectedKeys.isEmpty && selectedKeys.allSatisfy(\.revoked)
    }

    private func label(_ source: HostKeySource) -> String {
        switch source {
        case .tofu: "Trusted"
        case .imported: "Imported"
        case .manual: "Manual"
        }
    }

    private func copyFingerprint() {
        guard let key = selectedKeys.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.fingerprintSHA256, forType: .string)
    }

    /// Removing or un-revoking a pin weakens trust (§7.2), so it needs the gate.
    /// Revoking only tightens it.
    private func toggleRevoked() async {
        let restoring = allRevoked
        notice = nil
        if restoring {
            guard
                await app.gate(
                    .replaceHostKey,
                    reason: "Restore trust in the selected host keys",
                    declined: $notice
                )
            else { return }
        }
        for key in selectedKeys { key.revoked = !restoring }
        modelContext.saveLogged()
    }

    private func remove() async {
        guard
            await app.gate(
                .replaceHostKey,
                reason: "Remove trusted host keys",
                declined: $notice
            )
        else { return }
        for key in selectedKeys { modelContext.delete(key) }
        modelContext.saveLogged()
        selection.removeAll()
    }
}

/// What the Source and Status columns sort by: the order they read in, not the stored raw values.
extension KnownHostKey {
    fileprivate var sourceSortKey: String {
        switch source {
        case .tofu: "Trusted"
        case .imported: "Imported"
        case .manual: "Manual"
        }
    }
    fileprivate var statusSortKey: Int { revoked ? 1 : 0 }
}
