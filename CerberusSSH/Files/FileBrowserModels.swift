import SwiftUI
import Observation
import UniformTypeIdentifiers
import CerberusModels
import CerberusSSHCore

/// A connection that a file pane owns, and how to end it. Each file tab dials its own (spec §9.6).
struct FileSession: Sendable {
    let backend: any FileBackend
    let close: @Sendable () async -> Void
    /// What the status bar says about the connection; nil for This Mac.
    var info: FileSessionInfo?
}

struct FileSessionInfo: Sendable {
    /// "user@host:port".
    var endpoint: String
    var hostKeyFingerprint: String?
    var connectedSince: Date?
    /// Said in the status bar when the connection is not the usual kind ("shell, no SFTP").
    var note: String? = nil
}

typealias FileSessionConnector = @MainActor (UUID) async throws -> FileSession

/// One side of a file tab: a place (this Mac, or a host), a folder in it, and what is selected.
@MainActor
@Observable
final class FilePaneModel: Identifiable {
    enum Source: Equatable {
        case local
        case host(id: UUID, name: String)

        var title: String {
            switch self { case .local: "This Mac"; case .host(_, let name): name }
        }
    }

    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    enum SortKey: String, CaseIterable { case name, size, modified }

    let id = UUID()
    private(set) var source: Source
    private(set) var phase = Phase.connecting
    private(set) var backend: (any FileBackend)?
    private(set) var info: FileSessionInfo?
    private(set) var path = ""
    private(set) var entries: [FileEntry] = [] { didSet { refreshVisible() } }
    /// `entries` as shown: hidden files left out unless asked for, folders first, then sorted. Kept up to
    /// date when something it depends on changes, because sorting a big folder on every redraw is slow.
    private(set) var visibleEntries: [FileEntry] = []
    private(set) var isLoading = false
    /// A problem with the last thing done in this pane (a listing, a rename), shown on the pane.
    var notice: String?
    /// A key asked for something this pane's view should do (see ``PaneRequest``); the view clears it.
    var request: PaneRequest?
    var selection: Set<String> = []
    var showsHidden = false { didSet { refreshVisible() } }
    var sortKey = SortKey.name { didSet { refreshVisible() } }
    var ascending = true { didSet { refreshVisible() } }

    @ObservationIgnored private var session: FileSession?
    @ObservationIgnored private var connector: FileSessionConnector?

    init(source: Source) { self.source = source }

    /// Folders first, then by the chosen column; names compare the way Finder does.
    private func refreshVisible() {
        let shown = showsHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        visibleEntries = shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult = switch sortKey {
            case .name: a.name.localizedStandardCompare(b.name)
            case .size: compare(a.size ?? 0, b.size ?? 0)
            case .modified: compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return (order == .orderedAscending) == ascending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending) }

    /// The ".." row shown at the top of the listing, which goes up a folder; nil at the top.
    var parentEntry: FileEntry? {
        guard !path.isEmpty, path != "/" else { return nil }
        return FileEntry(name: "..", path: POSIXPath.parent(path), isDirectory: true)
    }

    var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.path) } }

    /// Connects to the place this pane shows and lists a folder of it: `folder` if one is given (the last run's),
    /// else the one it was showing when this is the same place again (a reconnect keeps the folder), else home. A
    /// folder that is no longer there falls back to home.
    func open(_ source: Source, startingIn folder: String? = nil, connector: @escaping FileSessionConnector) async {
        let remembered = folder ?? (self.source == source ? path : "")
        await disconnect()
        self.source = source
        self.connector = connector
        phase = .connecting
        entries = []; selection = []; notice = nil; path = ""
        switch source {
        case .local:
            backend = LocalFileBackend()
        case .host(let id, _):
            do {
                let made = try await connector(id)
                session = made
                backend = made.backend
                info = made.info
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        guard let backend else { return }
        do {
            if !remembered.isEmpty {
                await go(to: remembered)
                if path == remembered { phase = .ready; return }
                notice = nil   // it is gone: home instead, without a complaint
            }
            await go(to: try await backend.home())
            phase = .ready
        } catch { phase = .failed(error.localizedDescription) }
    }

    func disconnect() async {
        let ending = session
        session = nil; backend = nil; info = nil
        await ending?.close()
    }

    func go(to newPath: String) async {
        guard let backend else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try await backend.list(newPath)
            path = newPath
            entries = listed
            selection = []
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func reload() async {
        guard backend != nil, !path.isEmpty else { return }
        let keep = selection
        await go(to: path)
        selection = keep.intersection(Set(entries.map(\.path)))
    }

    func goUp() async { await go(to: POSIXPath.parent(path)) }

    /// A folder opens; a file does nothing yet.
    func activate(_ entry: FileEntry) async { if entry.isDirectory { await go(to: entry.path) } }

    // MARK: Changing things

    private func perform(_ work: () async throws -> Void) async {
        do { try await work(); notice = nil } catch { notice = error.localizedDescription }
        await reload()
    }

    func makeFolder(named name: String) async {
        guard let backend, !name.isEmpty else { return }
        await perform { try await backend.makeDirectory(POSIXPath.join(path, name)) }
    }

    func rename(_ entry: FileEntry, to name: String) async {
        guard let backend, !name.isEmpty, name != entry.name else { return }
        await perform { try await backend.rename(entry.path, to: POSIXPath.join(POSIXPath.parent(entry.path), name)) }
    }

    func delete(_ doomed: [FileEntry]) async {
        guard let backend else { return }
        await perform { for entry in doomed { try await FileOperations.removeTree(backend, entry) } }
    }

    func setPermissions(_ entry: FileEntry, _ mode: UInt32) async {
        guard let backend else { return }
        await perform { try await backend.setPermissions(entry.path, mode) }
    }
}

/// A transfer on the queue.
@MainActor
@Observable
final class TransferJob: Identifiable {
    enum State: Equatable {
        case waiting
        case running
        case finished(TransferSummary)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let title: String
    let detail: String
    /// Shown in the transfers list: files going from one place to another. A copy or move within one place (the
    /// same Mac, the same server) is not a transfer and is left out; it is gone from the queue once it is done.
    let isListed: Bool
    fileprivate(set) var state = State.waiting
    fileprivate(set) var progress = TransferProgress() {
        didSet { rate.add(transferred: progress.bytesDone - min(progress.bytesDone, progress.bytesResumed), at: Date()) }
    }
    private(set) var rate = TransferRate()
    fileprivate let request: TransferRequest
    fileprivate let onFinish: @MainActor (TransferJob) async -> Void
    fileprivate var task: Task<Void, Never>?

    fileprivate init(title: String, detail: String, isListed: Bool, request: TransferRequest, onFinish: @escaping @MainActor (TransferJob) async -> Void) {
        self.title = title; self.detail = detail; self.isListed = isListed; self.request = request; self.onFinish = onFinish
    }

    var isFinished: Bool { if case .waiting = state { false } else if case .running = state { false } else { true } }

    /// What went wrong, if something did: the failure, or the first item that did not copy.
    var problem: String? {
        switch state {
        case .failed(let message): message
        case .finished(let summary): summary.failures.first.map { "\($0.path): \($0.message)" }
        default: nil
        }
    }
}

/// A name that is already taken, waiting for the person to say what to do.
struct ConflictPrompt: Identifiable {
    let id = UUID()
    let conflict: TransferConflict
    fileprivate let answer: @MainActor (ConflictResolution) -> Void
}

/// Runs transfers one after another and asks about clashes as they come up.
@MainActor
@Observable
final class TransferQueue {
    /// Everything waiting, running or done, transfers or not (see ``TransferJob/isListed``).
    private var all: [TransferJob] = []
    private(set) var prompts: [ConflictPrompt] = []
    @ObservationIgnored private var runner: Task<Void, Never>?

    /// The transfers, as the transfers list shows them; the counts below are of these.
    var jobs: [TransferJob] { all.filter(\.isListed) }

    var activeCount: Int { jobs.filter { !$0.isFinished }.count }

    /// Everything still to finish, transfers or not: what closing the tab would cancel.
    var unfinishedCount: Int { all.filter { !$0.isFinished }.count }

    /// How far along the transfers in progress are, as one figure; nil while that is not yet known
    /// (a transfer being planned), which the status bar shows as a spinner.
    var overallFraction: Double? {
        let active = jobs.filter { !$0.isFinished }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(UInt64(0)) { $0 + $1.progress.bytesTotal }
        guard total > 0 else { return nil }
        return Double(active.reduce(UInt64(0)) { $0 + min($1.progress.bytesDone, $1.progress.bytesTotal) }) / Double(total)
    }

    /// Transfers that finished with something that did not copy, or failed outright.
    var problemCount: Int {
        jobs.filter {
            switch $0.state {
            case .failed: true
            case .finished(let summary): !summary.failures.isEmpty
            default: false
            }
        }.count
    }

    func enqueue(title: String, detail: String, isListed: Bool = true, request: TransferRequest,
                 onFinish: @escaping @MainActor (TransferJob) async -> Void) {
        all.append(TransferJob(title: title, detail: detail, isListed: isListed, request: request, onFinish: onFinish))
        if runner == nil { runner = Task { await self.drain() } }
    }

    private func drain() async {
        while let job = all.first(where: { $0.state == .waiting }) {
            await run(job)
        }
        runner = nil
    }

    private func run(_ job: TransferJob) async {
        job.state = .running
        let throttle = ProgressThrottle()
        let task = Task { @MainActor in
            do {
                let summary = try await TransferEngine.run(
                    job.request,
                    conflict: { conflict in await self.ask(conflict) },
                    progress: { progress in
                        // A fast copy reports many times a second; the screen needs a few.
                        guard throttle.allow(final: progress.bytesDone >= progress.bytesTotal) else { return }
                        Task { @MainActor in job.progress = progress }
                    }
                )
                job.state = .finished(summary)
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                job.state = .failed(error.localizedDescription)
            }
        }
        job.task = task
        await task.value
        if !job.isListed { all.removeAll { $0 === job } }
        await job.onFinish(job)
    }

    private func ask(_ conflict: TransferConflict) async -> ConflictResolution {
        await withCheckedContinuation { continuation in
            prompts.append(ConflictPrompt(conflict: conflict) { continuation.resume(returning: $0) })
        }
    }

    func resolve(_ prompt: ConflictPrompt, with resolution: ConflictResolution) {
        prompts.removeAll { $0.id == prompt.id }
        prompt.answer(resolution)
    }

    func cancel(_ job: TransferJob) {
        if job.state == .waiting { job.state = .cancelled; return }
        // A pending question for this job would otherwise never be answered.
        for prompt in prompts { resolve(prompt, with: ConflictResolution(.cancel)) }
        job.task?.cancel()
    }

    func clearFinished() { all.removeAll { $0.isFinished } }

    func cancelAll() {
        for job in all where !job.isFinished { cancel(job) }
    }
}

/// What a file tab holds: two panes and the transfers between them.
@MainActor
@Observable
final class FileTabModel: Identifiable {
    let id = UUID()
    let left: FilePaneModel
    let right: FilePaneModel
    let queue = TransferQueue()
    /// The rows being dragged out of one of this tab's panes, noted as the drag starts. A drop that
    /// finds this fresh is a drag between the panes, whatever the dropped data looks like: reading
    /// it back would ask a row's file offered for Finder, which for a server file means fetching it
    /// to this Mac and sending it on. The rows themselves are kept, so a drop can tell which are folders (one may not
    /// go into itself) without looking them up again.
    var activeDrag: (pane: UUID, entries: [FileEntry], started: Date)?

    // MARK: Focus and the clipboard

    /// The pane that has the keyboard: ⌘C and ⌘V act on it, and it wears the focus ring. "left" or "right".
    var focusedSide = "left"
    var focusedPane: FilePaneModel { focusedSide == "left" ? left : right }

    /// What ⌘C put aside: the rows and where they are. Kept in this tab only: nothing goes onto the system clipboard,
    /// so copying between this app and Finder is by drag and drop.
    struct Clipboard {
        var entries: [FileEntry]
        var backend: any FileBackend
        var source: FilePaneModel.Source
        var folder: String
    }
    var clipboard: Clipboard?

    /// Server files being edited here (see ``FileEdit``).
    var edits: [FileEdit] = []

    func focus(_ side: String) { if focusedSide != side { focusedSide = side } }

    /// Moves the focus to the pane on that side. Up and down have nowhere to go: the panes are side by side.
    func moveFocus(toward direction: PaneLayout.Direction) {
        switch direction {
        case .left: focus("left")
        case .right: focus("right")
        case .up, .down: break
        }
    }

    /// The other pane (what ⌘[ and ⌘] reach: there are only two).
    func cycleFocus() { focus(focusedSide == "left" ? "right" : "left") }

    /// ⌘C: sets the selected rows of `pane` aside.
    func copySelection(of pane: FilePaneModel) {
        let chosen = pane.selectedEntries
        guard let backend = pane.backend, !chosen.isEmpty else { return }
        clipboard = Clipboard(entries: chosen, backend: backend, source: pane.source, folder: pane.path)
    }

    /// ⌘V: copies what was set aside into the folder `pane` shows. Into the folder the files came from it keeps
    /// both, naming the new ones "… (copy)", without asking.
    /// With `moving` (⌥⌘V, Finder's Move Item Here) the originals are removed once they have arrived, and what was set
    /// aside is spent.
    func paste(into pane: FilePaneModel, moving: Bool = false) {
        guard let clip = clipboard else { return }
        let sameFolder = clip.folder == pane.path && clip.source == pane.source
        if moving && sameFolder { return }   // already there
        copy(clip.entries, using: clip.backend, from: clip.source, to: pane,
             conflictPolicy: sameFolder && !moving ? .keepBoth : nil, moving: moving)
        if moving { clipboard = nil }
    }

    /// The Files menu's "Copy Ownership" (a setting for every copy and move).
    nonisolated static let copyOwnershipKey = "filesCopyOwnership"

    /// Where files dragged out to Finder were fetched to; removed when the tab closes.
    @ObservationIgnored private var dragFolders: [URL] = []
    @ObservationIgnored private var dragWatcher: Task<Void, Never>?

    @ObservationIgnored private let baseConnector: FileSessionConnector
    /// Sessions in use, by host: both panes showing one host share one connection, so a copy between
    /// them can be done by the server itself (see ``ServerSideCopying``). Counted, so the last pane to
    /// leave a host closes it.
    @ObservationIgnored private var shared: [UUID: (task: Task<FileSession, any Error>, panes: Int)] = [:]

    init(left: FilePaneModel.Source, right: FilePaneModel.Source, connector: @escaping FileSessionConnector) {
        self.left = FilePaneModel(source: left)
        self.right = FilePaneModel(source: right)
        self.baseConnector = connector
    }

    /// What the panes connect with: a host already open in the other pane is reused.
    var connector: FileSessionConnector { { [self] hostID in try await self.session(for: hostID) } }

    private func session(for hostID: UUID) async throws -> FileSession {
        if let entry = shared[hostID] {
            shared[hostID] = (entry.task, entry.panes + 1)
            do { return wrap(try await entry.task.value, hostID) } catch { forget(hostID); throw error }
        }
        let task = Task { @MainActor in try await self.baseConnector(hostID) }
        shared[hostID] = (task, 1)
        do { return wrap(try await task.value, hostID) } catch { shared[hostID] = nil; throw error }
    }

    private func wrap(_ session: FileSession, _ hostID: UUID) -> FileSession {
        FileSession(backend: session.backend, close: { [weak self] in await self?.release(hostID, closing: true) }, info: session.info)
    }

    private func release(_ hostID: UUID, closing: Bool) async {
        guard let entry = shared[hostID] else { return }
        if entry.panes > 1 { shared[hostID] = (entry.task, entry.panes - 1); return }
        shared[hostID] = nil
        if closing, let session = try? await entry.task.value { await session.close() }
    }

    /// A pane that failed to get the session lets go of its share without closing anything.
    private func forget(_ hostID: UUID) {
        guard let entry = shared[hostID] else { return }
        shared[hostID] = entry.panes > 1 ? (entry.task, entry.panes - 1) : nil
    }

    var title: String {
        let places = [left.source, right.source].filter { $0 != .local }.map(\.title)
        return "Files: " + (places.isEmpty ? "This Mac" : places.joined(separator: " ⇄ "))
    }

    /// The servers this tab is connected to, once each: both panes on one server share its connection, and This Mac
    /// is not a connection. What closing the tab would end.
    var connectedHosts: [String] {
        var seen: Set<UUID> = [], names: [String] = []
        for pane in [left, right] where pane.phase == .ready {
            if case .host(let id, let name) = pane.source, seen.insert(id).inserted { names.append(name) }
        }
        return names
    }

    func pane(withID id: UUID) -> FilePaneModel? { [left, right].first { $0.id == id } }
    func other(than pane: FilePaneModel) -> FilePaneModel { pane === left ? right : left }

    /// Connects both panes. They connect side by side, so a slow host does not hold up the other.
    func start(leftFolder: String? = nil, rightFolder: String? = nil) async {
        async let a: Void = left.open(left.source, startingIn: leftFolder, connector: connector)
        async let b: Void = right.open(right.source, startingIn: rightFolder, connector: connector)
        _ = await (a, b)
    }

    func shutdown() async {
        queue.cancelAll()
        for edit in edits { await edit.session.finish() }
        edits = []
        for folder in dragFolders { try? FileManager.default.removeItem(at: folder) }
        dragFolders = []
        await left.disconnect()
        await right.disconnect()
    }

    /// Copies `entries` out of `from` into the folder the other pane is showing, or into `folder` of it.
    func copy(_ entries: [FileEntry], from: FilePaneModel, to destination: FilePaneModel, into folder: String? = nil, moving: Bool = false) {
        guard let source = from.backend else { return }
        copy(entries, using: source, from: from.source, to: destination, into: folder, moving: moving)
    }

    /// Copies `entries` from anywhere `source` reaches (a pane's place, or files dropped from Finder, `from` nil) into
    /// the folder `destination` shows, or into `folder` (a folder row something was dropped on). Within one place it is
    /// not a transfer: it is left out of the transfers list, and a problem with it is said on the pane instead.
    func copy(_ entries: [FileEntry], using source: any FileBackend, from origin: FilePaneModel.Source?, to destination: FilePaneModel,
              into folder: String? = nil, conflictPolicy: ConflictChoice? = nil, moving: Bool = false) {
        guard let target = destination.backend, !destination.path.isEmpty else {
            destination.notice = "\(destination.source.title) is not ready to receive files yet."
            return
        }
        guard !entries.isEmpty else { return }
        let what = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        let isTransfer = origin != destination.source
        queue.enqueue(
            title: what,
            detail: "\(origin?.title ?? "Finder") → \(destination.source.title)" + (moving ? " (move)" : ""),
            isListed: isTransfer,
            request: TransferRequest(source: source, sources: entries, destination: target, destinationDirectory: folder ?? destination.path,
                                     conflictPolicy: conflictPolicy, removesSources: moving,
                                     copiesOwnership: UserDefaults.standard.bool(forKey: Self.copyOwnershipKey)),
            onFinish: { [self] job in
                await destination.reload()
                if !isTransfer, let problem = job.problem { destination.notice = problem }
                // A move changed the folder the files came from, too.
                if moving { await other(than: destination).reload() }
            }
        )
    }

    /// What a drag between panes carries: the pane it started in and the paths picked up.
    static func dragPayload(pane: FilePaneModel, paths: [String]) -> String {
        let json = (try? JSONEncoder().encode(paths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "cerberus-pane:\(pane.id.uuidString):\(json)"
    }

    /// The type a row dragged inside this tab carries, so such a drag is told from a file dragged in
    /// from Finder, whose provider names the file's own type (markdown, a PDF, anything).
    nonisolated static let paneItemType = UTType(exportedAs: "com.cerberusssh.pane-item")

    /// Whether the rows being dragged may be let go on `folder` of `destination`. Within one place (the same Mac, the
    /// same server) they may not go into the folder they are already in, nor a folder into itself or one of its own
    /// folders. Files from Finder may go anywhere.
    func acceptsDrop(on folder: String, in destination: FilePaneModel) -> Bool {
        guard let drag = activeDrag, let from = pane(withID: drag.pane), from.source == destination.source else { return true }
        return !drag.entries.contains { entry in
            POSIXPath.parent(entry.path) == folder
                || (entry.isDirectory && !entry.isSymlink && (folder == entry.path || folder.hasPrefix(entry.path + "/")))
        }
    }

    /// Whether letting the rows being dragged go on `destination` moves them, as Finder decides between volumes: within
    /// one place it moves and ⌥ copies, between places it copies and ⌘ moves. Files from Finder are always copied.
    func dropMoves(onto destination: FilePaneModel) -> Bool {
        guard let drag = activeDrag, let from = pane(withID: drag.pane) else { return false }
        let keys = NSEvent.modifierFlags
        return from.source == destination.source ? !keys.contains(.option) : keys.contains(.command)
    }

    /// A drop onto `destination`: rows from a pane, or files from Finder. They go into the folder the pane shows, or
    /// into `folder` when they were let go on a folder row.
    func drop(providers: [NSItemProvider], onto destination: FilePaneModel, into folder: String? = nil) -> Bool {
        CerberusLog.info("files", "drop on the \(destination.source.title) pane\(folder == nil ? "" : " (on a folder)"): \(providers.count) item(s), types \(providers.map(\.registeredTypeIdentifiers))")
        guard !providers.isEmpty else { return false }
        let paneType = Self.paneItemType.identifier

        // A drag from one of these panes, known from when it started.
        // (The drag is forgotten shortly after the mouse button comes up, so this is only ever set for a
        // drag that began in one of these panes and is being let go now.)
        if let drag = activeDrag {
            guard let from = pane(withID: drag.pane), acceptsDrop(on: folder ?? destination.path, in: destination) else {
                activeDrag = nil
                return false
            }
            let moving = dropMoves(onto: destination)
            activeDrag = nil
            copy(drag.entries, from: from, to: destination, into: folder, moving: moving)
            return !drag.entries.isEmpty
        }
        activeDrag = nil
        Task { @MainActor in
            var strings: [String] = [], urls: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(paneType) {
                    if let text = await Self.loadPayload(from: provider) { strings.append(text) }
                } else if let url = await Self.loadFile(from: provider) {
                    urls.append(url)
                }
            }
            if !self.drop(strings: strings, urls: urls, onto: destination, into: folder) {
                destination.notice = "Nothing could be read from what was dropped."
            }
        }
        return true
    }

    private static func loadPayload(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: paneItemType.identifier) { data, _ in
                continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
    }

    /// A file dragged in from Finder, in place where the drag allows it, else a copy of it.
    private static func loadFile(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var found: URL?
                    if let url = item as? URL { found = url }
                    else if let data = item as? Data { found = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let text = item as? String { found = URL(string: text) }
                    continuation.resume(returning: found)
                }
            }
        }
        return await loadFileCopy(from: provider)
    }

    private static func loadFileCopy(from provider: NSItemProvider) async -> URL? {
        let type = provider.registeredTypeIdentifiers.first ?? UTType.item.identifier
        return await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, error in
                guard let url else {
                    CerberusLog.warning("files", "could not read a dropped file: \(error.map { CerberusLog.describe($0) } ?? "no file")")
                    continuation.resume(returning: nil)
                    return
                }
                if inPlace { continuation.resume(returning: url); return }
                // Valid only inside this callback, so it is copied somewhere that lasts.
                let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cerberus-drop-\(UUID().uuidString)")
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    CerberusLog.warning("files", "could not keep a dropped file: \(CerberusLog.describe(error))")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Handles dropped data: items from the other pane, or files from Finder, into `folder` or the pane's own.
    func drop(strings: [String], urls: [URL], onto destination: FilePaneModel, into folder: String? = nil) -> Bool {
        CerberusLog.info("files", "dropped \(urls.count) file(s) and \(strings.count) text item(s) on the \(destination.source.title) pane")
        activeDrag = nil
        var accepted = false
        // Every dragged row carries its own payload; gather them per pane so one drag is one transfer.
        var paths: [UUID: Set<String>] = [:]
        for text in strings where text.hasPrefix("cerberus-pane:") {
            let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
                  let list = try? JSONDecoder().decode([String].self, from: Data(parts[2].utf8)) else { continue }
            paths[id, default: []].formUnion(list)
        }
        for (id, picked) in paths {
            guard let from = pane(withID: id), from !== destination else { continue }
            let entries = from.entries.filter { picked.contains($0.path) }
            copy(entries, from: from, to: destination, into: folder)
            accepted = accepted || !entries.isEmpty
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            let local = LocalFileBackend()
            Task {
                var entries: [FileEntry] = []
                for url in files { if let entry = try? await local.stat(url.path) { entries.append(entry) } }
                CerberusLog.info("files", "copying \(entries.count) dropped file(s) to \(destination.source.title)")
                if entries.isEmpty { destination.notice = "The dropped files could not be read." }
                copy(entries, using: local, from: nil, to: destination, into: folder)
            }
            accepted = true
        }
        return accepted
    }
}

extension FileTabModel {
    /// AppKit says nothing when a drag ends outside the app, so watch the mouse button: once it is up
    /// and the drop (which comes first) has had its chance, the drag is over and is forgotten.
    private func forgetDragWhenReleased() {
        dragWatcher?.cancel()
        dragWatcher = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { self?.activeDrag = nil }
        }
    }

    /// What one dragged row carries: its place in this tab (so another pane can copy it), and a
    /// file for Finder. A file on a server is only fetched when it is let go on Finder, into a
    /// folder of its own that is removed when the tab closes.
    func itemProvider(for entry: FileEntry, in pane: FilePaneModel) -> NSItemProvider {
        // Called as the drag starts, once per row carried: a row inside the selection carries all of it.
        let paths = pane.selection.contains(entry.path) ? pane.selection : [entry.path]
        activeDrag = (pane.id, pane.entries.filter { paths.contains($0.path) }, Date())
        CerberusLog.info("files", "drag started from the \(pane.source.title) pane with \(activeDrag?.entries.count ?? 0) row(s)")
        forgetDragWhenReleased()
        let provider = NSItemProvider()
        let payload = Data(Self.dragPayload(pane: pane, paths: [entry.path]).utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.paneItemType.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        provider.suggestedName = entry.name
        guard let backend = pane.backend else { return provider }
        // A file is offered as plain data, not as its own type: Finder adds the type's usual extension to the
        // name it is given, so offering "a.sql" as an SQL file made "a.sql.sql".
        let type = entry.isDirectory ? UTType.folder : UTType.data
        let title = pane.source.title
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion(nil, false, CancellationError()); return }
                if !backend.isRemote {
                    completion(URL(fileURLWithPath: entry.path), false, nil)
                } else {
                    self.fetchForFinder(entry, from: backend, sourceTitle: title, completion: completion)
                }
            }
            return nil
        }
        return provider
    }

    private func fetchForFinder(_ entry: FileEntry, from backend: any FileBackend, sourceTitle: String,
                                completion: @escaping @Sendable (URL?, Bool, (any Error)?) -> Void) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cerberus-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dragFolders.append(folder)
        queue.enqueue(
            title: entry.name, detail: "\(sourceTitle) → Finder",
            request: TransferRequest(source: backend, sources: [entry], destination: LocalFileBackend(), destinationDirectory: folder.path),
            onFinish: { job in
                switch job.state {
                case .finished(let summary) where summary.failures.isEmpty:
                    completion(folder.appendingPathComponent(entry.name), false, nil)
                case .finished(let summary):
                    completion(nil, false, NSError(domain: "CerberusSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: summary.failures[0].message]))
                case .failed(let message):
                    completion(nil, false, NSError(domain: "CerberusSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                default:
                    completion(nil, false, CancellationError())
                }
            }
        )
    }
}

extension FileTabModel: Equatable {
    nonisolated static func == (a: FileTabModel, b: FileTabModel) -> Bool { a === b }
}

/// Lets progress through at most four times a second, and always the last.
private nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func allow(final: Bool) -> Bool {
        lock.withLock {
            let now = Date()
            guard final || now.timeIntervalSince(last) >= 0.25 else { return false }
            last = now
            return true
        }
    }
}
