import SwiftUI
import AppKit
import SwiftData
import CerberusModels
import CerberusVault
import CerberusTerminal

/// Supplies a stable window id even if SwiftUI hands over none.
private struct WindowRoot: View {
    let id: UUID?
    @State private var fallback = UUID()

    var body: some View { ContentView(windowID: id ?? fallback) }
}

enum HelpWindow { static let id = "help" }
enum ForwardsWindowID { static let id = "forwards" }

/// The app's delegate: turns off window tabbing, asks before quitting with live connections, and times how long
/// quitting takes, in the log, so a slow quit can be found rather than guessed at.
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var asked: ContinuousClock.Instant?
    /// The model, for the question asked before quitting with live connections (set by the first window).
    nonisolated(unsafe) static weak var app: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { AppAppearance.follow() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting ends every connection: ask first when there are some (Settings ▸ Behaviour).
        let question = MainActor.assumeIsolated { Self.app?.quitQuestion() }
        if let question {
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        MainActor.assumeIsolated { Self.app?.isQuitting = true }   // what closes now must not be forgotten (workspace.json)
        Self.asked = .now
        // Dragging a file out of a file tab leaves a file promise on the drag pasteboard. AppKit resolves every
        // promise still pending while it terminates, which asks us for the file again (a download from the
        // host, waited on without a timeout) and held the quit for 10+ s. Nothing needs the promise once the
        // app is going, so drop it first.
        NSPasteboard(name: .drag).clearContents()
        CerberusLog.info("app", "quit asked for; \(NSApp.windows.filter(\.isVisible).count) window(s) open")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        let took = Self.asked.map { ContinuousClock.now - $0 }
        CerberusLog.info("app", "about to exit" + (took.map { String(format: ", %.2f s after the quit was asked for", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? ""))
    }
}

@main
struct CerberusSSHApp: App {
    // Keep this the only @NSApplicationDelegateAdaptor: SwiftUI honours just one, and a second silently switches off
    // the other's methods (a second delegate once disabled the quit confirmation). Put new delegate methods in AppDelegate.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Local-only store. Nothing is written to iCloud until the user opts in.
    private let modelContainer: ModelContainer

    /// One model for the whole process, so every window shares sessions, the vault
    /// and the trust store rather than each building its own.
    @State private var appModel = AppModel(vault: UITesting.isActive ? Vault(keyStore: InMemoryDataKeyStore()) : Vault())

    init() {
        #if DEBUG
        // Xcode: Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments ▸ add `--reset-data`.
        // Starts from a fresh install: deletes the store and the vault key before launch.
        if CommandLine.arguments.contains("--reset-data") {
            CerberusSchema.deleteLocalStoreFiles()
            do { try KeychainDataKeyStore().deleteKey() } catch { CerberusLog.caught(error, note: "deleting the vault key for --reset-data") }
        }
        #endif
        // The UI-test build starts from empty preferences every time, so one test cannot leave
        // something (a "first launch already offered", a backup folder) for the next. This is the
        // app's own domain (the bundle id ends in ".uitest"), never the real app's.
        // (`CERBERUS_UI_KEEP_DEFAULTS=1` leaves them, for a test that relaunches to see what persisted.)
        if UITesting.isActive, ProcessInfo.processInfo.environment["CERBERUS_UI_KEEP_DEFAULTS"] != "1",
           let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        // Preferences a test wants in place from the start (written, not passed as launch arguments,
        // because an argument would shadow every later change the app makes).
        if UITesting.isActive {
            for (key, value) in UITesting.launchScenario.defaults { UserDefaults.standard.set(value, forKey: key) }
        }
        // A ⌘-clicked link is written to a file instead of opening a browser; the test reads it.
        if UITesting.isActive, let path = ProcessInfo.processInfo.environment["CERBERUS_UI_COMMAND"] {
            TerminalCoordinator.linkOpener = { url in
                try? (url.absoluteString + "\n").write(toFile: path + ".link", atomically: true, encoding: .utf8)
            }
        }
        HangWatchdog.start()
        do {
            modelContainer = try CerberusSchema.localContainer(inMemory: UITesting.isActive)
        } catch {
            CerberusLog.caught(error)
            fatalError("Could not open the local store: \(error)")
        }
    }

    /// A new window opens at most of the screen's usable area (already in points, so display
    /// scaling is accounted for), never smaller than the minimum or bigger than the screen.
    /// SwiftUI remembers a window's size once the user has resized it, and uses this only
    /// when there is no remembered size.
    private static var defaultWindowSize: CGSize {
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        func fit(_ fraction: CGFloat, of available: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            min(available, min(maximum, max(minimum, available * fraction)))
        }
        return CGSize(
            width: fit(0.82, of: area.width, minimum: 900, maximum: 2400),
            height: fit(0.86, of: area.height, minimum: 560, maximum: 1600)
        )
    }

    var body: some Scene {
        // One window per id, so a tab can be dragged out into a window of its own.
        WindowGroup(for: UUID.self) { $windowID in
            WindowRoot(id: windowID)
                .environment(appModel)
                .frame(minWidth: 900, minHeight: 560)
                .id(appModel.uiTestEpoch)   // a test's reset starts every view afresh (see UITestControl)
        } defaultValue: {
            UUID()
        }
        .defaultSize(Self.defaultWindowSize)
        .modelContainer(modelContainer)
        .commands {
            WorkspaceCommands(app: appModel)
        }

        // Replaces the empty system Help menu entry ("Help isn't available").
        Window("Help", id: HelpWindow.id) {
            HelpView()
                .environment(appModel)
                .id(appModel.uiTestEpoch)
        }
        .defaultSize(width: 860, height: 660)

        // Every port forward, with a switch on each.
        Window("Port Forwards", id: ForwardsWindowID.id) {
            ForwardsWindow()
                .environment(appModel)
                .id(appModel.uiTestEpoch)
        }
        .defaultSize(width: 760, height: 520)
        .modelContainer(modelContainer)

        // The list of recorded sessions, and a window for each one being replayed.
        Window("Recordings", id: RecordingsWindow.id) {
            RecordingsListView()
                .environment(appModel)
                .id(appModel.uiTestEpoch)
        }
        .defaultSize(width: 560, height: 420)
        .modelContainer(modelContainer)

        WindowGroup("Recording", id: RecordingViewerWindow.id, for: URL.self) { $url in
            RecordingViewerWindowContent(url: url)
                .environment(appModel)
                .id(appModel.uiTestEpoch)
        }
        .defaultSize(width: 900, height: 640)
        .restorationBehavior(.disabled)
        .modelContainer(modelContainer)

        Settings {
            // No `.id(uiTestEpoch)` here: the Settings window stays open between tests. Its category is
            // reset in the model.
            SettingsView()
                .environment(appModel)
        }
        .modelContainer(modelContainer)
    }
}

