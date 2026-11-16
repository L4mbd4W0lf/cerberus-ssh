//
//  RecordingViewerSheet.swift
//  CerberusSSH
//
//  Created by Adrian Hall on 2026/11/12.
//

import SwiftUI
import SwiftData
import CerberusModels
import CerberusVault
import CerberusTerminal

/// One session recording in a window of its own: replays it with colours, and exports plain text or asciinema
/// `.cast` (spec §10).
struct RecordingViewerSheet: View {
    let entry: RecordingStore.Entry
    let hostName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query private var allSettings: [AppSettings]

    @State private var contents: RecordingContents?
    @State private var errorText: String?
    @State private var player: ReplayPlayer?
    @State private var terminal = ReplayTerminal()
    @State private var position: Double = 0
    @State private var isPlaying = false
    @State private var speed: Double = 1
    @State private var isDragging = false
    @State private var query = ""
    @State private var matches: [RecordingSearch.Match] = []
    @State private var currentMatch: Int?
    @FocusState private var searchFocused: Bool

    @AppStorage(ThemeCatalog.followSystemKey) private var followsSystemTheme = false
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: TerminalAppearance {
        let settings = allSettings.first
        let chosen = ThemeCatalog.theme(id: settings?.defaultThemeID, custom: app.customThemes)
        return TerminalAppearance(
            theme: followsSystemTheme ? ThemeCatalog.following(chosen, systemIsDark: colorScheme == .dark) : chosen,
            fontName: settings?.fontName ?? TerminalAppearance.systemMonospacedName,
            fontSize: min(settings?.fontSize ?? 13, 14),
            cursorStyle: (settings?.cursorStyle ?? .blinkBlock).respectingReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), scrollbackLines: 5_000
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let errorText {
                ContentUnavailableView("Can't open this recording", systemImage: "lock.trianglebadge.exclamationmark", description: Text(errorText))
            } else if let contents {
                searchBar(contents)
                replay(contents)
                controls(contents)
            } else {
                ProgressView("Decrypting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(hostName).font(.title3.bold())
                if let meta = contents?.meta {
                    Text("\(meta.username)@\(meta.hostname) · \(meta.startedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let contents {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Self.clock(contents.duration)) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                    if !contents.isComplete {
                        Label("Ended abruptly", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.statusWarning)
                            .help("The app quit or crashed while this session was running. Everything written before that is intact.")
                    } else if contents.meta.recordsInput {
                        Label("Includes typed input", systemImage: "keyboard")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The replay fills whatever room the viewer has, whatever size the recorded terminal was: the text
    /// wraps to the viewer's width, and a change of size redraws it from the start to the current moment.
    private func replay(_ contents: RecordingContents) -> some View {
        GeometryReader { proxy in
            LogReplayView(terminal: terminal, appearance: appearance)
                .onChange(of: proxy.size) { _, _ in
                    guard let player, !player.isPlaying else { return }
                    player.seek(toMS: player.position)
                }
        }
        .background(appearance.theme.background.swiftUIColor)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }

    private func searchBar(_ contents: RecordingContents) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search this recording", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("log-search-field")
                .onSubmit { step(1) }
                .onChange(of: query) { _, _ in search(contents) }
            Text(matchSummary)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("log-search-count")
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty)
                .help("Previous match (⇧⌘G)")
                .accessibilityLabel("Previous match")
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty)
                .help("Next match (⌘G)")
                .accessibilityLabel("Next match")
                .keyboardShortcut("g", modifiers: .command)
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    private var matchSummary: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No matches" }
        return "\((currentMatch ?? 0) + 1) of \(matches.count)"
    }

    private func search(_ contents: RecordingContents) {
        matches = RecordingSearch.find(query, in: contents.events)
        currentMatch = nil
        if !matches.isEmpty { step(1) }
    }

    /// Moves to the next (or previous) match and shows the replay as it was when that line appeared.
    private func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let next = currentMatch.map { ($0 + direction + count) % count } ?? (direction > 0 ? 0 : count - 1)
        currentMatch = next
        player?.seek(toMS: matches[next].timeMS)
    }

    private func controls(_ contents: RecordingContents) -> some View {
        HStack(spacing: 10) {
            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .accessibilityLabel(isPlaying ? "Pause the replay" : "Play the replay")
            .keyboardShortcut(.space, modifiers: [])
            .help(isPlaying ? "Pause" : "Play")

            Button { player?.restart() } label: { Image(systemName: "backward.end.fill") }
                .help("Restart")
                .accessibilityLabel("Restart the replay")

            Slider(
                value: Binding(get: { position }, set: { position = $0 }),
                in: 0...max(1, Double(player?.duration ?? 1))
            ) { editing in
                isDragging = editing
                if !editing { player?.seek(toMS: UInt32(position)) }
            }

            Text("\(Self.clock(position / 1000)) / \(Self.clock(Double(player?.duration ?? 0) / 1000))")
                .font(.caption).monospacedDigit().frame(width: 100)

            Picker("Speed", selection: $speed) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
                Text("10×").tag(10.0)
                Text("Instant").tag(0.0)
            }
            .labelsHidden()
            .frame(width: 90)
            .onChange(of: speed) { _, new in player?.speed = new }
        }
    }

    private var footer: some View {
        HStack {
            Text("Long pauses are shortened in the replay.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Export Text…", systemImage: "doc.plaintext") { exportText() }.disabled(contents == nil)
            Button("Export .cast…", systemImage: "terminal") { exportCast() }.disabled(contents == nil)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Loading and playback

    private func load() async {
        do {
            // Normally one key; two while this Mac and iCloud Keychain hold different ones, when a recording may
            // have been written under either.
            let keys = try await app.vault.sessionRecordingKeys()
            let url = entry.url
            let loaded = try await Task.detached(priority: .userInitiated) {
                var failure: any Error = RecordingError.wrongKey
                for key in keys {
                    do { return try RecordingReader.read(url: url, key: key) } catch RecordingError.wrongKey { failure = RecordingError.wrongKey }
                }
                throw failure
            }.value
            contents = loaded

            // The recorded terminal's size is not replayed; the viewer's own size is used.
            let newPlayer = ReplayPlayer(events: loaded.events)
            newPlayer.sink = terminal
            newPlayer.speed = speed
            newPlayer.onChange = { [weak newPlayer] in
                guard let newPlayer else { return }
                isPlaying = newPlayer.isPlaying
                if !isDragging { position = Double(newPlayer.position) }
            }
            player = newPlayer
            // Show the finished screen first; the user can press play to watch it run.
            newPlayer.seek(toMS: newPlayer.duration)
        } catch let error as RecordingError {
            CerberusLog.caught(error)
            errorText = error.description
        } catch {
            CerberusLog.caught(error)
            errorText = error.localizedDescription
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    // MARK: Size and formatting


    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Export

    private func exportText() {
        guard let contents else { return }
        save(ANSIText.plainText(of: contents.events), suggested: "\(hostName) \(stamp(contents)).txt")
    }

    private func exportCast() {
        guard let contents else { return }
        save(AsciicastExport.render(contents), suggested: "\(hostName) \(stamp(contents)).cast")
    }

    private func stamp(_ contents: RecordingContents) -> String {
        contents.meta.startedAt.formatted(.iso8601.year().month().day())
    }

    private func save(_ text: String, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { CerberusLog.caught(error); errorText = "Could not save: \(error.localizedDescription)" }
    }
}
