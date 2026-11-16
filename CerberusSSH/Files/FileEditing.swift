import SwiftUI
import AppKit
import CerberusSSHCore

/// One server file being edited here, as the file tab shows it: the session that does the work, and its state.
@MainActor @Observable
final class FileEdit: Identifiable {
    let id = UUID()
    let name: String
    let session: RemoteEditSession
    var state: RemoteEditSession.State = .downloading
    /// Where the local copy was left when it could not be sent.
    var keptAt: URL?

    init(path: String, backend: any FileBackend) {
        name = POSIXPath.name(path)
        // The state is set from the session's own callbacks, which arrive off the main actor.
        let holder = Holder()
        // A test finds the copy where it can look: the home it runs the app in.
        let scratch = UITesting.isActive ? URL(fileURLWithPath: NSHomeDirectory()) : FileManager.default.temporaryDirectory
        session = RemoteEditSession(remote: backend, path: path, scratch: scratch) { state in
            Task { @MainActor in holder.edit?.state = state }
        }
        holder.edit = self
    }

    @MainActor private final class Holder { weak var edit: FileEdit? }

    var statusText: String {
        switch state {
        case .downloading: "Fetching…"
        case .watching: "Waiting for you to save"
        case .uploading: "Sending…"
        case .uploaded(let date): "Sent " + date.formatted(date: .omitted, time: .standard)
        case .serverChanged: "The server's copy changed meanwhile, so your save was not sent"
        case .failed(let message): "Not sent: \(message)"
        }
    }
}

extension FileTabModel {
    /// Fetches the file, opens it in the default app and sends back each save.
    func edit(_ entry: FileEntry, in pane: FilePaneModel) {
        guard let backend = pane.backend, !entry.isDirectory else { return }
        if let existing = edits.first(where: { $0.session.remotePath == entry.path && $0.state != .downloading }) {
            NSWorkspace.shared.open(existing.session.localURL)
            return
        }
        let edit = FileEdit(path: entry.path, backend: backend)
        edits.append(edit)
        Task { @MainActor in
            do {
                try await edit.session.start()
                // Under UI testing the test edits the copy itself, and no app should open.
                if !UITesting.isActive { NSWorkspace.shared.open(edit.session.localURL) }
            } catch {
                edits.removeAll { $0.id == edit.id }
                pane.notice = "Could not fetch \(entry.name) to edit it: \(error.localizedDescription)"
            }
        }
    }

    /// Ends the edit: a last save is sent, and the local copy goes. One that could not be sent stays, and is shown.
    func stopEditing(_ edit: FileEdit) {
        Task { @MainActor in
            let kept = await edit.session.finish()
            edits.removeAll { $0.id == edit.id }
            if let kept {
                focusedPane.notice = "\(edit.name) was not sent: the copy you edited is at \(kept.path)"
                NSWorkspace.shared.activateFileViewerSelecting([kept])
            }
        }
    }
}

/// What is being edited, above the status bar: each file, how it stands, and the ways to end it.
struct FileEditsStrip: View {
    let tab: FileTabModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tab.edits) { edit in
                HStack(spacing: 8) {
                    Image(systemName: "pencil.circle").foregroundStyle(.secondary)
                    Text(edit.name).lineLimit(1)
                    Text(edit.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if edit.state == .serverChanged {
                        Button("Send Anyway") { Task { await edit.session.uploadAnyway() } }
                            .accessibilityIdentifier("files-edit-send-anyway")
                    }
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([edit.session.localURL]) }
                    Button("Stop Editing") { tab.stopEditing(edit) }
                        .accessibilityIdentifier("files-edit-stop")
                }
                .controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("files-edit-\(edit.name)")
                .accessibilityValue(edit.statusText)
                Divider()
            }
        }
        .background(.bar)
    }
}
