import SwiftUI
import CerberusSSHCore

/// The toolbar button for the transfers of every file tab in the window: a ring that fills with how far they have got
/// altogether, and a drop-down listing them. The window shows it only once something has gone from one place to another.
struct TransfersButton: View {
    /// A file tab with transfers, under the name its tab shows.
    struct Source: Identifiable {
        let id: UUID
        let name: String
        let queue: TransferQueue
    }

    let sources: [Source]
    @State private var isShowingList = false

    private var queues: [TransferQueue] { sources.map(\.queue) }
    private var activeCount: Int { queues.map(\.activeCount).reduce(0, +) }
    private var problemCount: Int { queues.map(\.problemCount).reduce(0, +) }
    private var fraction: Double? { TransferQueue.overallFraction(of: queues) }

    var body: some View {
        Button { isShowingList.toggle() } label: {
            Label { Text("Transfers") } icon: { icon }
        }
        .help(summary)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            TransferPanel(sources: sources).frame(width: 560)
        }
        .accessibilityLabel(summary)
        .accessibilityHint("Shows the list of transfers.")
        .accessibilityIdentifier("toolbar-transfers")
    }

    @ViewBuilder
    private var icon: some View {
        if activeCount > 0 {
            RadialProgress(fraction: fraction, size: 16)
        } else if problemCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusGood)
        }
    }

    private var summary: String {
        let active = activeCount
        if active > 0 {
            let count = active == 1 ? "1 transfer in progress" : "\(active) transfers in progress"
            return fraction.map { "\(count), \(Int($0 * 100))%" } ?? count
        }
        if problemCount > 0 { return problemCount == 1 ? "Transfers finished, 1 with problems" : "Transfers finished, \(problemCount) with problems" }
        return "Transfers finished"
    }
}

/// A small ring that fills as a transfer goes; a spinner while the amount is not yet known.
struct RadialProgress: View {
    let fraction: Double?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The transfers: what is running, what is waiting and what finished, each with progress and a cancel button. With
/// more than one file tab, each tab's transfers are under its name.
private struct TransferPanel: View {
    let sources: [TransfersButton.Source]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { for source in sources { source.queue.clearFinished() } }
                    .disabled(!sources.contains { $0.queue.jobs.contains { $0.isFinished } })
                    .accessibilityIdentifier("files-clear-finished")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sources) { source in
                        if sources.count > 1 {
                            Text(source.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        }
                        ForEach(source.queue.jobs) { job in
                            TransferRow(job: job) { source.queue.cancel(job) }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-transfers")
    }
}
