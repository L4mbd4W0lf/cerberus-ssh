import AppKit
import CerberusModels
import CerberusSSHCore
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

/// A terminal pane. (The status bar belongs to the tab: ``TabStatusBar``.) The terminal is constructed from a
/// ``TerminalTransport``, so it can only ever show an SSH channel.
struct SessionPane: View {
    @Bindable var session: SessionViewModel
    /// Whether this pane has the keyboard, and whether to draw a ring to show it
    /// (only worth showing when the tab has more than one pane).
    var isFocused = true
    var showsFocusRing = false
    /// Broadcast input: whether this tab is broadcasting, and whether this pane
    /// is one of the panes that take part.
    var isBroadcasting = false
    var inBroadcastGroup = false
    var onToggleBroadcastMembership: () -> Void = {}
    var onInput: (([UInt8]) -> Void)?
    var onPaste: ((String) -> Void)?
    /// How many panes a paste here reaches while broadcasting, this one included.
    var broadcastPaneCount = 1
    var onFocus: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingReplace = false
    @Query private var allSettings: [AppSettings]
    @AppStorage(BehaviourSettings.copyOnSelectKey) private var copiesOnSelect = true
    @AppStorage(ThemeCatalog.followSystemKey) private var followsSystemTheme =
        false
    @Environment(\.colorScheme) private var colorScheme

    /// The host's theme, else the app-wide one, with the font, cursor and scrollback from
    /// Settings.
    private var appearance: TerminalAppearance {
        let settings = allSettings.first
        return TerminalAppearance(
            theme: followed(
                ThemeCatalog.resolve(
                    hostThemeID: session.themeID,
                    defaultThemeID: settings?.defaultThemeID,
                    custom: app.customThemes
                )
            ),
            fontName: settings?.fontName
                ?? TerminalAppearance.systemMonospacedName,
            fontSize: settings?.fontSize ?? 13,
            cursorStyle: (settings?.cursorStyle ?? .blinkBlock)
                .respectingReduceMotion(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ),
            scrollbackLines: settings?.scrollbackLines ?? 10_000
        )
    }

    /// With "follow the system" on, a theme that has a light and a dark version shows the one that matches macOS.
    private func followed(_ theme: TerminalTheme) -> TerminalTheme {
        followsSystemTheme
            ? ThemeCatalog.following(theme, systemIsDark: colorScheme == .dark)
            : theme
    }

    var body: some View {
        VStack(spacing: 0) {
            if let mismatch = session.hostKeyMismatch {
                mismatchBanner(mismatch)
            }
            if let detail = session.incompatibility {
                incompatibleBanner(detail)
            }
            // A pane that shares its tab can be dragged out of it by this strip.
            if showsFocusRing {
                PaneGrip(session: session, theme: appearance.theme)
            }
            TerminalSessionView(
                host: session.terminalHost,
                transport: session.connection,
                appearance: appearance,
                behavior: TerminalBehavior(
                    confirmMultilinePaste: allSettings.first?
                        .confirmMultilinePaste ?? true,
                    allowRemoteClipboardWrite: allSettings.first?
                        .allowRemoteClipboardWrite ?? false,
                    copyOnSelect: copiesOnSelect
                ),
                onInput: isBroadcasting && inBroadcastGroup ? onInput : nil,
                onPaste: isBroadcasting && inBroadcastGroup ? onPaste : nil,
                pastePaneCount: isBroadcasting && inBroadcastGroup ? broadcastPaneCount : 1,
                isFocused: isFocused,
                onFocus: onFocus,
                menuEntries: {
                    onFocus()
                    return paneMenuEntries
                },
                onSelectionCopied: { count in session.noteCopied(characters: count) }
            ) { title in
                session.remoteTitle = title
            }
            // A margin in the theme's own colour, so the focus ring and the broadcast outline,
            // which are drawn over the pane's edge, never cover the first column of text.
            .padding(5)
            .background(appearance.theme.background.swiftUIColor)
        }
        .overlay { connectingOverlay }
        .overlay(alignment: .topTrailing) {
            // The tab has one status bar, so each pane's broadcast tick lives on the pane.
            if isBroadcasting {
                Toggle(
                    isOn: Binding(
                        get: { inBroadcastGroup },
                        set: { _ in onToggleBroadcastMembership() }
                    )
                ) {
                    Label(
                        "Broadcast",
                        systemImage: "dot.radiowaves.left.and.right"
                    ).font(.caption)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .solidPanel(Capsule())
                .padding(8)
                .help("Include this pane when typing is broadcast")
            }
        }
        .overlay {
            // A participating pane is always outlined, so it is never ambiguous where typing goes.
            if isBroadcasting && inBroadcastGroup {
                Rectangle().strokeBorder(Color.broadcast, lineWidth: 3)
                    .allowsHitTesting(false)
            } else if showsFocusRing && isFocused {
                Rectangle().strokeBorder(
                    Color.accentColor.opacity(0.8),
                    lineWidth: 2
                ).allowsHitTesting(false)
            }
        }
        .sheet(item: $session.pendingKeyboardPrompt) { prompt in
            KeyboardInteractiveSheet(
                sessionTitle: session.title,
                prompt: prompt
            ) { answers in
                session.answerKeyboardPrompt(answers)
            }
        }
        .sheet(item: $session.pendingHostKeyPrompt) { prompt in
            HostKeyPromptSheet(hostName: session.title, prompt: prompt) {
                trust in
                session.answerHostKey(trust: trust)
            }
        }
    }

    /// Shown over the terminal until the connection is up: a spinner while it is being made,
    /// the reason when it could not be. A session that was up and then lost keeps its terminal.
    @ViewBuilder private var connectingOverlay: some View {
        if session.connectedSince == nil {
            switch session.state {
            case .resolving, .connecting, .verifyingHostKey, .authenticating,
                .authenticated, .channelOpen, .reconnecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(session.title)…").font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appearance.theme.background.swiftUIColor)
                .accessibilityElement(children: .combine)
            case .disconnected(let reason)
            where reason != .userInitiated && session.hostKeyMismatch == nil:
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(
                        .largeTitle
                    ).foregroundStyle(.secondary)
                    Text("Could not connect to \(session.title)").font(
                        .headline
                    )
                    if let detail = session.statusDetail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    if session.canReconnect {
                        Button("Reconnect", systemImage: "arrow.clockwise") {
                            Task { await session.reconnect() }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appearance.theme.background.swiftUIColor)
            default:
                EmptyView()
            }
        }
    }

    /// What right-clicking the terminal adds after the standard items (copy, paste, select
    /// all, find). Each action first makes this the focused pane, since the sheets and
    /// commands it opens work on the focused pane.
    private var paneMenuEntries: [TerminalMenuEntry] {
        var entries: [TerminalMenuEntry] = []
        if session.canReconnect {
            entries.append(
                .init("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await session.reconnect() }
                }
            )
            entries.append(.separator)
        }
        entries += [
            .submenu(
                "Split",
                systemImage: "rectangle.split.2x1",
                [
                    .init(
                        "Split Right",
                        systemImage: "rectangle.righthalf.inset.filled",
                        shortcut: MenuShortcut(.splitRight)
                    ) {
                        onFocus()
                        Task {
                            await app.duplicate(session, placement: .splitRight)
                        }
                    },
                    .init(
                        "Split Left",
                        systemImage: "rectangle.lefthalf.inset.filled"
                    ) {
                        onFocus()
                        Task {
                            await app.duplicate(session, placement: .splitLeft)
                        }
                    },
                    .init(
                        "Split Up",
                        systemImage: "rectangle.tophalf.inset.filled"
                    ) {
                        onFocus()
                        Task {
                            await app.duplicate(session, placement: .splitUp)
                        }
                    },
                    .init(
                        "Split Down",
                        systemImage: "rectangle.bottomhalf.inset.filled",
                        shortcut: MenuShortcut(.splitDown)
                    ) {
                        onFocus()
                        Task {
                            await app.duplicate(session, placement: .splitDown)
                        }
                    },
                ]
            ),
            .init(
                "Move Pane to New Tab",
                systemImage: "rectangle.portrait.on.rectangle.portrait",
                shortcut: MenuShortcut(.movePaneToTab),
                isEnabled: app.canMovePaneToTab(session)
            ) {
                onFocus()
                app.movePaneToTab(session)
            },
            .init(
                isBroadcasting ? "Stop Broadcasting Input" : "Broadcast Input",
                systemImage: "dot.radiowaves.left.and.right",
                shortcut: MenuShortcut(.broadcast)
            ) {
                onFocus()
                if let tab = app.tab(containing: session) {
                    app.toggleBroadcast(inTab: tab.id)
                }
            },
            .init(
                "Insert Snippet…",
                systemImage: "text.badge.plus",
                shortcut: MenuShortcut(.snippets)
            ) {
                onFocus()
                app.isShowingSnippets = true
            },
            .separator,
            .submenu(
                "Logs",
                systemImage: "list.bullet.rectangle",
                [
                    .init(
                        "Connection Log",
                        systemImage: "list.bullet.rectangle",
                        shortcut: MenuShortcut(.connectionLog)
                    ) {
                        onFocus()
                        app.isShowingConnectionLog = true
                    },
                    .init(
                        "Replay Log",
                        systemImage: "play.rectangle",
                        shortcut: MenuShortcut(.replayLog)
                    ) {
                        onFocus()
                        app.isShowingReplayLog = true
                    },
                    .init(
                        "Recordings",
                        systemImage: "record.circle",
                        shortcut: MenuShortcut(.sessionRecordings)
                    ) { openWindow(id: RecordingsWindow.id) },
                ]
            ),
            .separator,
            .init(
                "Close Pane",
                systemImage: "xmark",
                shortcut: MenuShortcut(.closePane)
            ) { app.requestClose(pane: session) },
        ]
        return entries
    }

    /// The server offers nothing CerberusSSH can speak. Explains exactly what, since
    /// the library itself only reports a bare negotiation failure.
    private func incompatibleBanner(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "This server can't be reached by CerberusSSH",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            Text(detail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "No connection was attempted past the handshake, so nothing was trusted or sent. The server's settings (or a newer server key) need to change."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningBackground)
    }

    /// Blocking warning for a changed host key. The only way forward is to replace
    /// the pinned key explicitly; there is deliberately no "connect anyway".
    private func mismatchBanner(
        _ mismatch: (pattern: String, expected: String, actual: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Host key has changed — connection refused",
                systemImage: "exclamationmark.octagon.fill"
            )
            .font(.headline)
            // In a chain the key that changed may be a jump host's, not the host that was asked for.
            Text(
                mismatch.pattern == session.hostKeyPattern
                    ? "The key of \(mismatch.pattern) is not the one that was stored. Someone may be intercepting this connection, or the server was reinstalled."
                    : "The key of \(mismatch.pattern), a jump host on the way to \(session.title), is not the one that was stored. Someone may be intercepting this connection, or that server was reinstalled."
            )
            .accessibilityIdentifier("host-key-mismatch-detail")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2)
            {
                GridRow {
                    Text("Stored").foregroundStyle(.secondary)
                    Text(mismatch.expected)
                }
                GridRow {
                    Text("Presented").foregroundStyle(.secondary)
                    Text(mismatch.actual)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            Button(
                "Replace stored key…",
                systemImage: "arrow.triangle.2.circlepath"
            ) { isConfirmingReplace = true }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dangerBackground)
        .confirmationDialog(
            "Replace the stored key for \(mismatch.pattern)?",
            isPresented: $isConfirmingReplace
        ) {
            Button("Replace Key", role: .destructive) {
                Task { await app.replaceStoredHostKey(for: session) }
            }
        } message: {
            Text(
                "Only do this if you know why the key changed. You will be asked to verify the new key."
            )
        }
    }
}

extension KeyboardInteractivePrompt: @retroactive Identifiable {
    public var id: String {
        hostDescription + "#" + name + "#"
            + items.map(\.text).joined(separator: "|")
    }
}

/// Asks for a one-time code, or whatever else the server wants to know (RFC 4256).
/// Answers go straight to the server and are never stored or logged.
struct KeyboardInteractiveSheet: View {
    let sessionTitle: String
    let prompt: KeyboardInteractivePrompt
    let finish: ([String]?) -> Void

    @State private var answers: [String]
    @FocusState private var focusedIndex: Int?

    init(
        sessionTitle: String,
        prompt: KeyboardInteractivePrompt,
        finish: @escaping ([String]?) -> Void
    ) {
        self.sessionTitle = sessionTitle
        self.prompt = prompt
        self.finish = finish
        _answers = State(
            initialValue: Array(repeating: "", count: prompt.items.count)
        )
    }

    private var canContinue: Bool {
        !answers.isEmpty && answers.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                prompt.name.isEmpty ? "Verification required" : prompt.name,
                systemImage: "lock.shield"
            )
            .font(.title2.bold())

            Text(
                "**\(prompt.hostDescription)** is asking for more than your key or password."
            )
            .fixedSize(horizontal: false, vertical: true)
            if !prompt.instruction.isEmpty {
                Text(prompt.instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(prompt.items.enumerated()), id: \.offset) {
                index,
                item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        item.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    )
                    .font(.callout)
                    // Secrets are never shown; the server says which answers may be echoed.
                    Group {
                        if item.echo {
                            TextField("", text: $answers[index])
                        } else {
                            SecureField("", text: $answers[index])
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedIndex, equals: index)
                    .onSubmit { submit() }
                }
            }

            Text("Used once to sign in. It is not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear { focusedIndex = 0 }
    }

    private func submit() {
        guard canContinue else { return }
        finish(answers.map(KeyboardInteractivePrompt.normalizedAnswer))
    }
}

extension HostKeyPrompt: @retroactive Identifiable {
    public var id: String { "\(hostPattern)#\(fingerprintSHA256)" }
}

/// First-use trust decision. Shows what OpenSSH shows, and requires an
/// explicit click: there is no default button, so Return cannot trust a key by accident.
struct HostKeyPromptSheet: View {
    let hostName: String
    let prompt: HostKeyPrompt
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Trust this host?", systemImage: "lock.shield")
                .font(.title2.bold())
            Text(
                "The authenticity of **\(hostName)** (\(prompt.hostPattern)) can't be established. Compare this fingerprint with one you got from the server's administrator."
            )
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4)
            {
                GridRow {
                    Text("Key type").foregroundStyle(.secondary)
                    Text(prompt.keyType)
                }
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(prompt.fingerprintSHA256)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

            Text(prompt.randomArt)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                .accessibilityLabel("Key randomart")

            HStack {
                Spacer()
                Button("Cancel") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { decide(true) }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}

/// A connection log kept after its session ended, so a host that is no longer connected can still be asked why.
struct SavedConnectionLog: Equatable, Identifiable {
    var id: Date { date }
    var title: String
    var text: String
    var lineCount: Int
    var date: Date
}

/// The connection log for one session, like the output of `ssh -vvv`.
struct ConnectionLogSheet: View {
    let session: SessionViewModel

    var body: some View {
        ConnectionLogContent(
            title: "Connection log — \(session.title)",
            text: session.diagnosticsText,
            lineCount: session.diagnostics.count,
            emptyMessage: "Nothing has been logged for this session yet.",
            fileName: "\(session.title) connection log.txt"
        )
    }
}

/// The last recording of a host that was connected before.
struct SavedConnectionLogSheet: View {
    let log: SavedConnectionLog

    var body: some View {
        ConnectionLogContent(
            title: "Last connection log — \(log.title)",
            text: log.text,
            lineCount: log.lineCount,
            emptyMessage: "Nothing was logged.",
            fileName: "\(log.title) connection log.txt",
            note:
                "From \(log.date.formatted(date: .abbreviated, time: .standard))."
        )
    }
}

struct ConnectionLogContent: View {
    let title: String
    let text: String
    let lineCount: Int
    let emptyMessage: String
    let fileName: String
    var note: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ConnectionLogSettings.key) private var logLevel = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(lineCount) lines").font(.caption).foregroundStyle(
                    .secondary
                )
            }
            if lineCount == 0 {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 6)
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let note { Text(note) }
                    Text(
                        "Passwords, keys and environment values are never logged."
                    )
                    Text(
                        logLevel >= 2
                            ? "Detail level: \(logLevel == 2 ? "-vv" : "-vvv")."
                            : "Detail level: basic. Choose more in Settings ▸ Connection for the next connection."
                    )
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save…") { save() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch
        {
            CerberusLog.caught(error, note: "saving the connection log")
        }
    }
}

/// A thin strip above a pane in a split tab, to drag the pane out by: onto the tab bar or a tab it becomes a tab of its
/// own, and let go outside the window it gets a window. (The terminal itself cannot be the handle: a drag there selects
/// text.)
struct PaneGrip: View {
    let session: SessionViewModel
    let theme: TerminalTheme
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var isOver = false

    var body: some View {
        ZStack {
            theme.background.swiftUIColor
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle().frame(width: 3, height: 3)
                }
            }
            .foregroundStyle(
                theme.foreground.swiftUIColor.opacity(isOver ? 0.7 : 0.25)
            )
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { over in
            isOver = over
            if over { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onDrag {
            app.beginPaneDrag(
                session.id,
                title: session.remoteTitle ?? session.title
            ) { point in
                if let tab = app.movePaneToTab(session) {
                    openWindow(value: app.detachTab(tab, at: point))
                }
            }
            return TabDrag.provider(for: session.id)
        } preview: {
            Color.clear.frame(width: 1, height: 1)
        }
        .help("Drag onto the tab bar to give this pane a tab of its own, or onto another pane to put it beside that one")
        .accessibilityElement()
        .accessibilityLabel("Pane handle, \(session.title)")
        .accessibilityHint("Moves this pane into a tab of its own")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.movePaneToTab(session) }
        .accessibilityIdentifier("pane-grip")
    }
}
