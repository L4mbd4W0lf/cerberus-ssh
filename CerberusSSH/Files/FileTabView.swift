import SwiftUI
import CerberusSSHCore

/// A file tab: two panes side by side (a drag from one to the other copies), and a status bar below.
struct FileTabView: View {
    let tab: FileTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilePaneView(pane: tab.left, tab: tab, side: "left")
                Divider()
                FilePaneView(pane: tab.right, tab: tab, side: "right")
            }
            Divider()
            FileEditsStrip(tab: tab)
            FileTabStatusBar(tab: tab)
        }
        .sheet(item: Binding(get: { tab.queue.prompts.first }, set: { _ in })) { prompt in
            ConflictSheet(prompt: prompt, queue: tab.queue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-tab")
    }
}

/// One transfer: where it is going and its name, how far it has got, and a cancel button. For a folder, the file
/// going now is under the progress bar.
struct TransferRow: View {
    let job: TransferJob
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(job.detail).foregroundStyle(.secondary))  \(job.title)").lineLimit(1).truncationMode(.middle)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if job.state == .running {
                    ProgressView(value: job.progress.fraction)
                    if job.hasSeveralFiles && !job.progress.currentName.isEmpty {
                        Text(job.progress.currentName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer()
            if !job.isFinished {
                Button(action: cancel) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel this transfer")
                    .accessibilityLabel("Cancel transfer").accessibilityIdentifier("files-cancel-transfer")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files-transfer-\(job.title)")
    }

    private var symbol: String {
        switch job.state {
        case .waiting: "clock"
        case .running: "arrow.left.arrow.right"
        case .finished(let summary): summary.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .finished(let summary): summary.failures.isEmpty ? Color.statusGood : Color.statusWarning
        case .failed: Color.statusBad
        default: .secondary
        }
    }

    /// How far it has got; where it is going and what is going are on the line above.
    private var status: String {
        switch job.state {
        case .waiting: return "waiting"
        case .running:
            let p = job.progress
            let done = ByteCountFormatter.string(fromByteCount: Int64(p.bytesDone), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(p.bytesTotal), countStyle: .file)
            var text = "\(done) of \(total)"
            if job.rate.bytesPerSecond > 0 {
                text += " · " + ByteCountFormatter.string(fromByteCount: Int64(job.rate.bytesPerSecond), countStyle: .file) + "/s"
            }
            if let left = job.rate.secondsRemaining(bytesLeft: p.bytesTotal - min(p.bytesTotal, p.bytesDone), now: Date()) {
                text += " · " + TransferRate.describe(seconds: left) + " left"
            }
            return job.hasSeveralFiles ? text + " · file \(min(p.filesDone + 1, p.filesTotal)) of \(p.filesTotal)" : text
        case .finished(let s):
            var parts = ["\(s.filesCopied) copied"]
            if s.linksCopied > 0 { parts.append("\(s.linksCopied) link\(s.linksCopied == 1 ? "" : "s")") }
            if s.itemsRenamed > 0 { parts.append("\(s.itemsRenamed) moved") }
            if s.sourcesRemoved > 0 { parts.append("\(s.sourcesRemoved) removed from the source") }
            if s.ownerNotSet > 0 { parts.append("owner not set on \(s.ownerNotSet) (the destination did not allow it)") }
            if s.resumeRestarted > 0 { parts.append("\(s.resumeRestarted) started again (the source had changed)") }
            if s.skippedExisting > 0 { parts.append("\(s.skippedExisting) skipped (already there)") }
            if s.skippedLinks > 0 { parts.append("\(s.skippedLinks) links could not be made") }
            if !s.failures.isEmpty { parts.append("\(s.failures.count) failed: \(s.failures[0].message)") }
            return parts.joined(separator: ", ")
        case .failed(let message): return message
        case .cancelled: return "cancelled"
        }
    }
}

/// What to do about a name that is already at the destination, or a copy that stopped part way.
private struct ConflictSheet: View {
    let prompt: ConflictPrompt
    let queue: TransferQueue
    @State private var applyToAll = false

    private var partial: UInt64? { prompt.conflict.partialSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(partial == nil ? "“\(prompt.conflict.name)” already exists" : "“\(prompt.conflict.name)” was only partly copied").font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Toggle("Do this for all remaining \(partial == nil ? "conflicts" : "partial files") in this transfer", isOn: $applyToAll)
                .accessibilityIdentifier("files-conflict-all")
            HStack {
                Button("Cancel Transfer", role: .cancel) { answer(.cancel) }.accessibilityIdentifier("files-conflict-cancel")
                Spacer()
                Button("Skip") { answer(.skip) }.accessibilityIdentifier("files-conflict-skip")
                if partial == nil {
                    Button("Keep Both") { answer(.keepBoth) }.accessibilityIdentifier("files-conflict-keep")
                    Button("Replace") { answer(.replace) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("files-conflict-replace")
                } else {
                    Button("Start Over") { answer(.replace) }.accessibilityIdentifier("files-conflict-restart")
                    Button("Resume") { answer(.resume) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("files-conflict-resume")
                }
            }
        }
        .padding(20).frame(width: 480)
        .interactiveDismissDisabled()
    }

    private var detail: String {
        func size(_ n: UInt64?) -> String { n.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size" }
        if let partial {
            return "\(size(partial)) of \(size(prompt.conflict.sourceSize)) is already at the destination. Resume carries on from there; Start Over copies it all again."
        }
        var text = "Copying: \(size(prompt.conflict.sourceSize)). Already there: \(size(prompt.conflict.existingSize))"
        if let date = prompt.conflict.existingModified { text += ", changed \(date.formatted(date: .abbreviated, time: .shortened))" }
        return text + "."
    }

    private func answer(_ choice: ConflictChoice) {
        queue.resolve(prompt, with: ConflictResolution(choice, applyToAll: applyToAll))
    }
}
