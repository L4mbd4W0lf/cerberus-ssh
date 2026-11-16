import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import CerberusModels
import CerberusVault
import CerberusSSHCore


/// One button per tab, plus "+" for quick connect.
struct TabBar: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    @Environment(\.windowID) private var windowID
    @State private var isDropTarget = false

    // Where the tab strip is scrolled to, and how much of it there is, so the bar can say when more
    // tabs are out of sight (a scroll view with no indicator gives no hint that it scrolls).
    @State private var position = ScrollPosition(edge: .leading)
    @State private var metrics = ScrollMetrics()

    struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var view: CGFloat = 0
        var overflows: Bool { content > view + 1 }
        var hiddenBefore: Bool { offset > 1 }
        var hiddenAfter: Bool { offset + view < content - 1 }
    }

    private var tabs: [WorkspaceTab] { app.tabs(in: windowID) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in TabButton(tab: tab).id(tab.id) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 6)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.x, content: geometry.contentSize.width, view: geometry.containerSize.width)
            } action: { _, new in metrics = new }
            // A tab that is selected, or newly opened, is brought into view.
            .onChange(of: app.selectedTabID(in: windowID)) { _, id in
                guard let id else { return }
                if reduceMotion { position.scrollTo(id: id, anchor: .center) } else { withAnimation { position.scrollTo(id: id, anchor: .center) } }
            }
            .overlay(alignment: .leading) { if metrics.hiddenBefore { edgeButton(.leading) } }
            .overlay(alignment: .trailing) { if metrics.hiddenAfter { edgeButton(.trailing) } }
            // Dropping a tab on the empty part of the bar sends it to the end, which is
            // also how a tab dragged from another window lands here.
            .onDrop(of: [TabDrag.type], isTargeted: $isDropTarget) { providers, _ in
                // A pane dragged out by its grip becomes the last tab here.
                if let pane = app.draggingPaneID {
                    TabDrag.consume(providers)
                    app.tabDropHandled()
                    app.placePane(pane, inWindow: windowID, before: nil)
                    return true
                }
                guard let id = app.draggingTabID else { return false }
                TabDrag.consume(providers)
                app.tabDropHandled()
                app.moveTab(id, toWindow: windowID, before: nil)
                return true
            }
            if metrics.overflows { allTabsMenu }
            Button { app.quickConnectRequests += 1 } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("New tab (⌘T)")
            .accessibilityLabel("New tab")
        }
        .frame(height: 30)
        .background(isDropTarget ? AnyShapeStyle(Color.accentColor.fill(0.18, contrast)) : AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A chevron at the edge that has more tabs behind it; one click moves the strip most of a screen.
    private func edgeButton(_ side: HorizontalEdge) -> some View {
        Button {
            let step = max(metrics.view * 0.6, 120) * (side == .leading ? -1 : 1)
            let target = min(max(metrics.offset + step, 0), max(metrics.content - metrics.view, 0))
            if reduceMotion { position.scrollTo(x: target) } else { withAnimation { position.scrollTo(x: target) } }
        } label: {
            Image(systemName: side == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 30)
                .background(.bar)
                .overlay(alignment: side == .leading ? .trailing : .leading) { Divider() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(side == .leading ? "More tabs to the left" : "More tabs to the right")
        .accessibilityLabel(side == .leading ? "Scroll tabs left" : "Scroll tabs right")
    }

    /// Every tab in a list, for when there are more than fit: the way to see them all at once.
    private var allTabsMenu: some View {
        Menu {
            ForEach(tabs) { tab in
                Button { app.selectTab(tab.id) } label: {
                    Label(title(of: tab), systemImage: tab.files != nil ? "folder" : "terminal")
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.leading, 6)
        .help("All \(tabs.count) tabs")
        .accessibilityLabel("All tabs")
    }

    private func title(of tab: WorkspaceTab) -> String { app.title(of: tab) }
}

/// What a dragged tab carries: a private type (declared in `CerberusSSH/Info.plist`)
/// that conforms to nothing another app knows how to store. A system type such as
/// `public.data` was tried first and Finder wrote the tab's id into a file called "data" on
/// the desktop, so the type must stay private. The tab being dragged is found through
/// ``AppModel/draggingTabID``; the data itself is never read.
enum TabDrag {
    static let identifier = "com.cerberusssh.tab"
    static let type = UTType(exportedAs: identifier, conformingTo: .item)

    /// Reads (and ignores) what a drop carries. A drop whose data is never asked for leaves the system waiting for
    /// it, and the dragged tab's image hung about at the drop point for a second before it faded.
    static func consume(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { _, _ in }
        }
    }

    static func provider(for tabID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .ownProcess) { completion in
            completion(Data(), nil)   // nothing to read: see the type's note above
            return nil
        }
        return provider
    }
}

struct TabButton: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let tab: WorkspaceTab
    @Environment(AppModel.self) private var app
    @Environment(\.windowID) private var windowID
    @Environment(\.openWindow) private var openWindow

    private var session: SessionViewModel? { app.session(withID: tab.focusedSessionID) }
    private var isSelected: Bool { tab.id == app.selectedTabID(in: windowID) }
    private var isRenaming: Bool { app.renamingTabID == tab.id }

    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which half of this tab a dragged tab is over, and so which side of it the tab will land on.
    @State private var dropEdge: HorizontalEdge?
    @State private var tabWidth: CGFloat = 100

    /// What the picture that follows the pointer says.
    private var dragTitle: String { app.title(of: tab) }

    /// The edge to draw: none when dropping there would leave the order as it is.
    private var visibleDropEdge: HorizontalEdge? {
        guard let edge = dropEdge, let moved = app.draggingTabID, moved != tab.id else { return nil }
        let mine = app.tabs(in: windowID).map(\.id)
        guard let index = mine.firstIndex(of: tab.id) else { return nil }
        let neighbour = edge == .leading ? (index > 0 ? mine[index - 1] : nil) : (index + 1 < mine.count ? mine[index + 1] : nil)
        return neighbour == moved ? nil : edge
    }

    var body: some View {
        HStack(spacing: 6) {
            if let files = tab.files {
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                if isRenaming {
                    TextField("Tab name", text: $draftName)
                        .textFieldStyle(.plain).frame(minWidth: 80, maxWidth: 200)
                        .focused($nameFieldFocused)
                        .onSubmit { finishRenaming(save: true) }
                        .onExitCommand { finishRenaming(save: false) }
                        .onAppear { draftName = tab.name ?? files.title; nameFieldFocused = true }
                        .onChange(of: nameFieldFocused) { _, focused in if !focused && isRenaming { finishRenaming(save: true) } }
                } else {
                    Text(tab.name ?? files.title).lineLimit(1)
                }
                if files.queue.activeCount > 0 {
                    ProgressView().controlSize(.mini)
                        .help("\(files.queue.activeCount) transfer(s) in progress")
                }
            } else if let session {
                if let color = session.nodeColor { NodeColorMark(color: color, width: 3, height: 12) }
                Image(systemName: session.statusSymbol)
                    .foregroundStyle(session.statusColor)
                    .font(.system(size: 9))
                if isRenaming {
                    TextField("Tab name", text: $draftName)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 80, maxWidth: 200)
                        .focused($nameFieldFocused)
                        .onSubmit { finishRenaming(save: true) }
                        .onExitCommand { finishRenaming(save: false) }
                        .onAppear {
                            draftName = tab.name ?? session.title
                            nameFieldFocused = true
                        }
                        .onChange(of: nameFieldFocused) { _, focused in
                            // Clicking away keeps what was typed, as in Finder.
                            if !focused && isRenaming { finishRenaming(save: true) }
                        }
                } else {
                    Text(tab.name ?? session.title)
                        .lineLimit(1)
                }
                if app.isBroadcasting(tab: tab.id) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.broadcastIndicator)
                        .font(.system(size: 10))
                        .help("Typing is copied to the checked panes")
                }
                if tab.layout.count > 1 {
                    Text("\(tab.layout.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                        .help("\(tab.layout.count) panes")
                }
            }
            Button {
                app.requestClose(tab: tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.fill(0.22, contrast) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { app.selectTab(tab.id) }
        // Middle-click closes, as in a browser.
        .overlay(MiddleClickCatcher { app.requestClose(tab: tab.id) })
        // Double-click renames, as in Finder; simultaneous so a single click selects at once.
        .simultaneousGesture(TapGesture(count: 2).onEnded { app.renamingTabID = tab.id })
        // Drag a tab to reorder it, or onto another window's tab bar to move it there.
        // Let go outside the app and it becomes a window of its own.
        // The system's picture of the tab is left blank. It is shown at the pointer while dragging and, once
        // let go, takes a moment to fade where it was dropped, over the tab that has just moved there. The
        // tab being dragged is dimmed in the bar and the landing line shows where it will go instead.
        .onDrag {
            app.beginTabDrag(tab.id, title: dragTitle) { point in
                openWindow(value: app.detachTab(tab.id, at: point))
            }
            return TabDrag.provider(for: tab.id)
        } preview: {
            Color.clear.frame(width: 1, height: 1)
        }
        .opacity(app.draggingTabID == tab.id && !app.tabDropWasHandled ? 0.4 : 1)
        // The bar shows where the tab will land: a line on the near edge of this tab, or of the next one.
        .overlay(alignment: dropEdge == .trailing ? .trailing : .leading) {
            if let edge = visibleDropEdge {
                Capsule().fill(Color.accentColor).frame(width: 3)
                    .padding(.vertical, 1)
                    .offset(x: edge == .leading ? -2 : 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(GeometryReader { proxy in Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in tabWidth = width } })
        .onDrop(of: [TabDrag.type], delegate: TabDropDelegate(
            tabID: tab.id, width: tabWidth, windowID: windowID, app: app, edge: $dropEdge, reduceMotion: reduceMotion
        ))
        .contextMenu {
            Group {
                Button("Rename Tab…", systemImage: "pencil") { app.selectTab(tab.id); app.renamingTabID = tab.id }
                Button("Move Tab to New Window", systemImage: "macwindow.on.rectangle") { openWindow(value: app.detachTab(tab.id)) }
                    .disabled(app.isTerminalWindow(windowID) && app.tabs(in: windowID).count < 2)
                Divider()
                Button("Close Tab", systemImage: "xmark") { app.requestClose(tab: tab.id) }
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func finishRenaming(save: Bool) {
        guard isRenaming else { return }
        if save { app.renameTab(tab.id, to: draftName) }
        app.renamingTabID = nil
    }
}


/// Reports a middle-button click on the view it covers. SwiftUI has no gesture for it. The view takes part in
/// hit testing only while the event is a middle-button one, so every other click and drag reaches the tab.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
    }
}


/// Dropping a tab on another tab: the half it is over says which side it lands on, and the tab shows it.
struct TabDropDelegate: DropDelegate {
    let tabID: UUID
    let width: CGFloat
    let windowID: UUID
    let app: AppModel
    @Binding var edge: HorizontalEdge?
    let reduceMotion: Bool

    private func edge(at info: DropInfo) -> HorizontalEdge { info.location.x < width / 2 ? .leading : .trailing }

    func validateDrop(info: DropInfo) -> Bool { app.draggingTabID != nil || app.draggingPaneID != nil }

    func dropEntered(info: DropInfo) { edge = edge(at: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = edge(at: info)
        // A move, not a copy: nothing is duplicated, and the drag image does not fly back as it does for a refusal.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { edge = nil }
        let pane = app.draggingPaneID
        guard let moved = app.draggingTabID ?? (pane == nil ? nil : tabID) else { return false }
        TabDrag.consume(info.itemProviders(for: [TabDrag.type]))
        let side = edge(at: info)
        let mine = app.tabs(in: windowID).map(\.id)
        let before: UUID?
        if side == .leading {
            before = tabID
        } else if let index = mine.firstIndex(of: tabID), index + 1 < mine.count {
            before = mine[index + 1]
        } else {
            before = nil
        }
        app.tabDropHandled()
        func place() {
            if let pane { app.placePane(pane, inWindow: windowID, before: before) } else { app.moveTab(moved, toWindow: windowID, before: before) }
        }
        if reduceMotion { place() } else { withAnimation(.snappy(duration: 0.2)) { place() } }
        return true
    }
}
