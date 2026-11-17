import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CerberusModels
import CerberusSSHCore

/// One side of the file tab: where it is, the folder's contents, and what can be done to them.
struct FilePaneView: View {
    let pane: FilePaneModel
    let tab: FileTabModel
    let side: String
    @Environment(AppModel.self) private var app
    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]

    @State private var pathText = ""
    @State private var isMakingFolder = false
    @State private var newName = ""
    @State private var renaming: FileEntry?
    @State private var doomed: [FileEntry] = []
    @State private var changingMode: FileEntry?
    @State private var modeText = ""
    @State private var isDropTarget = false
    @State private var isPickingSource = false
    /// The list has the keyboard. Kept in step with ``FileTabModel/focusedSide``: clicking a pane focuses it, and
    /// moving the focus with the keys puts the keyboard in the pane that gets it.
    @FocusState private var listFocused: Bool
    /// The path field has the keyboard: a click on it focuses the pane but must not hand the keyboard to the list.
    @FocusState private var pathFocused: Bool
    private var isFocusedPane: Bool { tab.focusedSide == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let notice = pane.notice {
                Divider()
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.statusWarning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .accessibilityIdentifier("files-notice-\(side)")
            }
        }
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        // The pane that ⌘C, ⌘V and the keys act on, outlined as the focused pane of an SSH tab is.
        .overlay { if isFocusedPane { Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2).allowsHitTesting(false) } }
        // A click anywhere in the pane (its header, the empty part of the list) focuses it, and gives the list the
        // keyboard unless the click was on the path field.
        .simultaneousGesture(TapGesture().onEnded { tab.focus(side); if !pathFocused { listFocused = true } })
        .onChange(of: listFocused) { _, focused in if focused { tab.focus(side) } }
        .onChange(of: pathFocused) { _, focused in if focused { tab.focus(side) } }
        .onChange(of: tab.focusedSide) { _, focusedSide in if focusedSide == side, !pathFocused { listFocused = true } }
        // One destination for everything: two stacked `dropDestination`s leave only one of them working.
        // Not `.item`: accepting any file type makes the system fetch the file a dragged row offers for
        // Finder as soon as it is dropped, which for a file on a server downloads it to this Mac.
        .onDrop(of: [FileTabModel.paneItemType, .fileURL], isTargeted: $isDropTarget) { providers in
            tab.drop(providers: providers, onto: pane)
        }
        .onChange(of: pane.request) { _, request in
            guard let request else { return }
            pane.request = nil
            let chosen = pane.selectedEntries
            switch request {
            case .newFolder: newName = ""; isMakingFolder = true
            case .rename: if chosen.count == 1 { renaming = chosen[0] }
            case .permissions:
                if chosen.count == 1 { modeText = chosen[0].mode.map { String($0, radix: 8) } ?? "644"; changingMode = chosen[0] }
            case .delete: if !chosen.isEmpty { doomed = chosen }
            }
        }
        .onChange(of: pane.path) { _, new in pathText = new }
        .onChange(of: isDropTarget) { _, targeted in CerberusLog.info("files", "the \(pane.source.title) pane is \(targeted ? "" : "no longer ")being dragged over") }
        .onAppear {
            pathText = pane.path
            if isFocusedPane { listFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-pane-\(side)")
        .sheet(isPresented: $isMakingFolder) { nameSheet(title: "New Folder", field: "Folder name", confirm: "Create", id: "new-folder") { name in Task { await pane.makeFolder(named: name) } } }
        .sheet(item: $renaming) { entry in
            nameSheet(title: "Rename", field: "New name", confirm: "Rename", id: "rename", initial: entry.name) { name in Task { await pane.rename(entry, to: name) } }
        }
        .sheet(item: $changingMode) { entry in permissionsSheet(entry) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !doomed.isEmpty }, set: { if !$0 { doomed = [] } })) {
            Button("Delete", role: .destructive) { let items = doomed; doomed = []; Task { await pane.delete(items) } }
                .accessibilityIdentifier("files-confirm-delete")
            Button("Cancel", role: .cancel) { doomed = [] }
        } message: { Text("This cannot be undone. Folders are deleted with everything in them.") }
    }

    private var deleteTitle: String { doomed.count == 1 ? "Delete “\(doomed[0].name)”?" : "Delete \(doomed.count) items?" }

    // MARK: Header

    /// This Mac, or the host with its system's logo.
    @ViewBuilder private var sourceLabel: some View {
        switch pane.source {
        case .local:
            Label(pane.source.title, systemImage: "laptopcomputer").lineLimit(1)
        case .host(let id, _):
            HStack(spacing: 4) {
                HostOSIcon(os: hosts.first { $0.id == id }?.detectedOS).frame(width: 16, height: 14)
                Text(pane.source.title).lineLimit(1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // The same searchable picker as the jump host button in the host editor, with This Mac added.
            Button { isPickingSource = true } label: {
                HStack(spacing: 4) {
                    sourceLabel
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Choose what this pane shows")
            .accessibilityIdentifier("files-source-\(side)")
            .popover(isPresented: $isPickingSource, arrowEdge: .bottom) {
                JumpHostList(
                    candidates: hosts, hint: "Return shows the highlighted one",
                    thisMac: { isPickingSource = false; switchTo(.local) }
                ) { host in
                    isPickingSource = false
                    switchTo(.host(id: host.id, name: host.displayLabel))
                }
            }

            Button { Task { await pane.goUp() } } label: { Image(systemName: "arrow.up") }
                .help("Enclosing folder").disabled(pane.path.isEmpty || pane.path == "/")
                .accessibilityLabel("Enclosing folder").accessibilityIdentifier("files-up-\(side)")
            TextField("Path", text: $pathText)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .focused($pathFocused)
                .onSubmit { Task { await pane.go(to: pathText) } }
                .accessibilityIdentifier("files-path-\(side)")
            Button { Task { await pane.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").accessibilityLabel("Refresh")
            Menu {
                Picker("Sort by", selection: Binding(get: { pane.sortKey }, set: { pane.sortKey = $0 })) {
                    ForEach(FilePaneModel.SortKey.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Ascending", isOn: Binding(get: { pane.ascending }, set: { pane.ascending = $0 }))
                Divider()
                Toggle("Show Hidden Files", isOn: Binding(get: { pane.showsHidden }, set: { pane.showsHidden = $0 }))
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            .menuStyle(.borderlessButton).fixedSize().help("Sort and filter")
            .accessibilityLabel("Sort and filter")
        }
        .padding(6)
    }

    private func switchTo(_ source: FilePaneModel.Source) {
        guard source != pane.source else { return }
        Task { await pane.open(source, connector: tab.connector) }
    }

    // MARK: Contents

    @ViewBuilder
    private var content: some View {
        switch pane.phase {
        case .connecting:
            VStack(spacing: 8) { ProgressView(); Text("Connecting to \(pane.source.title)…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not open \(pane.source.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again") { reconnect() }
            }
            .accessibilityIdentifier("files-failed-\(side)")
        case .ready:
            listing
        }
    }

    private func reconnect() {
        Task { await pane.open(pane.source, connector: tab.connector) }
    }

    private func isParent(_ entry: FileEntry) -> Bool { entry.name == ".." && entry.path == pane.parentEntry?.path }

    // Made once: building a formatter for every cell of every redraw is slow in a big folder.
    private static let sizeFormatter: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()

    private static let rowHeight: CGFloat = 24
    private static let stripe = Color(nsColor: NSColor.alternatingContentBackgroundColors[1])

    private var stripes: some View {
        Canvas { context, size in
            // Band 0 is plain, band 1 shaded, and so on, from the top: the same bands the rows above use.
            for band in stride(from: 1, through: Int(size.height / Self.rowHeight), by: 2) {
                let rect = CGRect(x: 0, y: CGFloat(band) * Self.rowHeight, width: size.width, height: Self.rowHeight)
                context.fill(Path(rect), with: .color(Self.stripe))
            }
        }
        .allowsHitTesting(false)
    }

    private static let sizeWidth: CGFloat = 80, modifiedWidth: CGFloat = 150, modeWidth: CGFloat = 48

    /// A list rather than a SwiftUI `Table`: a `Table` is a drag destination of its own that takes every
    /// drop and never hands it to the pane, so nothing could be dropped on a folder that had files in it.
    private var listing: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            List(selection: Binding(get: { pane.selection }, set: { pane.selection = $0 })) {
                ForEach(Array(((pane.parentEntry.map { [$0] } ?? []) + pane.visibleEntries).enumerated()), id: \.element.id) { index, entry in
                    Group {
                        if isParent(entry) {
                            fileRow(entry)
                        } else {
                            // Every selected row is dragged, each carrying itself; see `FileTabModel.itemProvider`.
                            fileRow(entry).itemProvider { tab.itemProvider(for: entry, in: pane) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(index.isMultiple(of: 2) ? Color.clear : Self.stripe)
                }
            }
            .listStyle(.plain)
            // The stripes are drawn here, not by the list: it continues them below the last row according to
            // how many rows there are, so two panes with different numbers of rows were out of step. Rows are
            // one fixed height and the empty space below is striped from the same top edge, so panes line up.
            .scrollContentBackground(.hidden)
            .background(alignment: .top) { stripes }
            .contextMenu(forSelectionType: String.self) { ids in menu(for: ids) } primaryAction: { ids in
                if let parent = pane.parentEntry, ids.contains(parent.path) { Task { await pane.goUp() }; return }
                if let entry = pane.entries.first(where: { ids.contains($0.path) }) { Task { await pane.activate(entry) } }
            }
            .focused($listFocused)
            .accessibilityLabel("Files in \(pane.source.title)")
            .accessibilityIdentifier("files-table-\(side)")
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            headerButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("Size", .size).frame(width: Self.sizeWidth, alignment: .trailing)
            headerButton("Modified", .modified).frame(width: Self.modifiedWidth, alignment: .leading)
            Text("Mode").frame(width: Self.modeWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    /// A column title that sorts by it; a second click reverses the order.
    private func headerButton(_ title: String, _ key: FilePaneModel.SortKey) -> some View {
        Button {
            if pane.sortKey == key { pane.ascending.toggle() } else { pane.sortKey = key; pane.ascending = true }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if pane.sortKey == key { Image(systemName: pane.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 8) {
            // Only the icon is tinted; the name stays the colour of a file's.
            Label {
                Text(entry.name)
            } icon: {
                Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "link" : "doc"))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.primary)
            }
            .foregroundStyle(Color.primary)
            .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(LinkTargetTip(entry: entry, backend: pane.backend))
            Text(entry.size.map { Self.sizeFormatter.string(fromByteCount: Int64($0)) } ?? "—")
                .foregroundStyle(.secondary).frame(width: Self.sizeWidth, alignment: .trailing)
            Text(entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                .foregroundStyle(.secondary).lineLimit(1).frame(width: Self.modifiedWidth, alignment: .leading)
            Text(entry.mode.map { String($0, radix: 8) } ?? "")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: Self.modeWidth, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let chosen = pane.entries.filter { ids.contains($0.path) }
        let other = tab.other(than: pane)
        Group {
            if !chosen.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { tab.copySelection(of: pane) }
                    .keyboardShortcut(.filesCopy)
            }
            Button("Paste", systemImage: "doc.on.clipboard") { tab.paste(into: pane) }
                .keyboardShortcut(.filesPaste)
                .disabled(tab.clipboard == nil)
            Button("Move Item Here", systemImage: "arrow.right.doc.on.clipboard") { tab.paste(into: pane, moving: true) }
                .keyboardShortcut(.filesMoveHere)
                .disabled(tab.clipboard == nil)
            Divider()
            if !chosen.isEmpty {
                Button("Copy to \(other.source.title)", systemImage: side == "left" ? "arrow.right.circle" : "arrow.left.circle") { tab.copy(chosen, from: pane, to: other) }
                    .keyboardShortcut(side == "left" ? AppShortcut.copyToRightPane : .copyToLeftPane)
                    .disabled(other.phase != .ready)
                Button("Move to \(other.source.title)", systemImage: side == "left" ? "arrow.right.to.line" : "arrow.left.to.line") { tab.copy(chosen, from: pane, to: other, moving: true) }
                    .keyboardShortcut(side == "left" ? AppShortcut.moveToRightPane : .moveToLeftPane)
                    .disabled(other.phase != .ready)
                Divider()
                if chosen.count == 1, !chosen[0].isDirectory, pane.source != .local {
                    Button("Edit in Default App", systemImage: "square.and.pencil") { tab.edit(chosen[0], in: pane) }
                }
                if chosen.count == 1 {
                    Button("Rename…", systemImage: "pencil") { renaming = chosen[0] }
                        .keyboardShortcut(.filesRename)
                    Button("Permissions…", systemImage: "lock") { modeText = chosen[0].mode.map { String($0, radix: 8) } ?? "644"; changingMode = chosen[0] }
                        .keyboardShortcut(.filesPermissions)
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { doomed = chosen }
                    .keyboardShortcut(.filesDelete)
                Divider()
            }
            Button("New Folder…", systemImage: "folder.badge.plus") { newName = ""; isMakingFolder = true }
                .keyboardShortcut(.filesNewFolder)
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.reload() } }
                .keyboardShortcut(.filesRefresh)
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: Sheets

    private func nameSheet(title: String, field: String, confirm: String, id: String, initial: String = "", _ done: @escaping (String) -> Void) -> some View {
        NameSheet(title: title, field: field, confirm: confirm, id: id, initial: initial, done: done)
    }

    private func permissionsSheet(_ entry: FileEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions for “\(entry.name)”").font(.headline)
            TextField("Octal mode, for example 644 or 755", text: $modeText)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("files-mode-field")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { changingMode = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let mode = UInt32(modeText, radix: 8), mode <= 0o7777 { Task { await pane.setPermissions(entry, mode) } }
                    changingMode = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(UInt32(modeText, radix: 8).map { $0 > 0o7777 } ?? true)
                .accessibilityIdentifier("files-mode-apply")
            }
        }
        .padding(20).frame(width: 360)
    }
}

/// A one-field sheet: a name for a new folder, or a new name for a file.
private struct NameSheet: View {
    let title: String
    let field: String
    let confirm: String
    let id: String
    let initial: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(field, text: $text).textFieldStyle(.roundedBorder)
                .onSubmit(commit).accessibilityIdentifier("files-name-field")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: commit).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("/"))
                    .accessibilityIdentifier("files-name-confirm")
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { text = initial }
    }

    private func commit() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        done(name)
        dismiss()
    }
}


/// A link's target as the row's tooltip ("→ ../current"), read when the row appears (one request per link, only
/// for links).
private struct LinkTargetTip: ViewModifier {
    let entry: FileEntry
    let backend: (any FileBackend)?
    @State private var target: String?

    func body(content: Content) -> some View {
        content
            .help(target.map { "Link to \($0)" } ?? "")
            .task(id: entry.path) {
                guard entry.isSymlink, let backend else { return }
                target = try? await backend.readLink(entry.path)
            }
    }
}
