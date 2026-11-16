import SwiftUI
import SwiftData
import AppKit
import CerberusModels
import CerberusVault
import CerberusTerminal

/// The Recordings window, which lists every recorded session.
enum RecordingsWindow { static let id = "recordings" }

/// One recording's own window; its value is the recording file's URL.
enum RecordingViewerWindow {
    static let id = "recording"

    /// The most recent recording of a host, if it has any.
    static func latest(for hostID: UUID) -> RecordingStore.Entry? {
        RecordingStore().entries().filter { $0.hostID == hostID }.max { $0.modified < $1.modified }
    }
}

/// The content of a recording's window: finds it by URL, and says so if it has been deleted.
struct RecordingViewerWindowContent: View {
    let url: URL?
    @Query private var hosts: [SSHHost]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let url, let entry = RecordingStore().entries().first(where: { $0.url == url }) {
            RecordingViewerSheet(entry: entry, hostName: hosts.first { $0.id == entry.hostID }?.displayLabel ?? "Deleted host")
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("This recording is gone", systemImage: "record.circle",
                                       description: Text("It was deleted, or removed by the retention settings."))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            .frame(minWidth: 420, minHeight: 260)
        }
    }
}

// MARK: - Recordings window

/// Every recorded session, newest first. Opening one gives it a window of its own.
struct RecordingsListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query private var hosts: [SSHHost]

    @State private var entries: [RecordingStore.Entry] = []
    @State private var selection: URL?
    @State private var isConfirmingDeleteAll = false
    @State private var pendingDeletion: RecordingStore.Entry?

    private let store = RecordingStore()

    private func hostName(for entry: RecordingStore.Entry) -> String {
        hosts.first { $0.id == entry.hostID }?.displayLabel ?? "Deleted host"
    }

    private func open(_ entry: RecordingStore.Entry) { openWindow(id: RecordingViewerWindow.id, value: entry.url) }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hostName(for: entry))
                            Text(entry.modified.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry.url)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No recordings", systemImage: "record.circle",
                        description: Text("Press Record Session in the toolbar while connected to a host.")
                    )
                }
            }

            Divider()
            HStack {
                Button("Open", systemImage: "play.rectangle") {
                    if let entry = entries.first(where: { $0.url == selection }) { open(entry) }
                }.disabled(selection == nil)
                Button("Delete…") {
                    pendingDeletion = entries.first(where: { $0.url == selection })
                }.disabled(selection == nil)
                Spacer()
                Text("\(entries.count) recordings · \(ByteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                Button("Delete All Recordings…", systemImage: "trash", role: .destructive) { isConfirmingDeleteAll = true }.disabled(entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 280)
        .task { reload() }
        // A recording started or finished since the window was opened shows up when it is brought forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .confirmationDialog(
            "Delete the recording of \(pendingDeletion.map(hostName(for:)) ?? "this session")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                if let entry = pendingDeletion { store.delete(entry); selection = nil; reload() }
                pendingDeletion = nil
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete every session recording?", isPresented: $isConfirmingDeleteAll) {
            Button("Delete All", systemImage: "trash", role: .destructive) { store.deleteAll(); reload() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func reload() { entries = store.entries() }
}
