import XCTest

/// The one running app the tests share (see `UITestControl` in the app).
///
/// Launching the app costs several seconds and there are dozens of tests, so it is launched once
/// and kept open. Before each test it is put back to a known state by a command written to a file
/// the app watches (sessions closed, extra windows gone, catalogue and vault reseeded, preferences
/// and every view reset), which takes a fraction of a second. A test that needs a genuinely new
/// process (the first-launch offer, "what survives a relaunch") asks for one.
enum SharedApp {
    /// One home folder for the whole run. The app is pointed at it, and tests put a `.ssh` in it.
    nonisolated(unsafe) static let home: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cerberus-uitest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated(unsafe) static let app: XCUIApplication = MainActor.assumeIsolated {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }

    /// The test `sshd` the scheme started, if there is one.
    nonisolated(unsafe) static let server: UITestSSHD? = UITestSSHD.connect()

    nonisolated(unsafe) private static var commandID = 0
    private static var commandFile: URL { home.appendingPathComponent("command.json") }
    private static var ackFile: URL { home.appendingPathComponent("command.json.ack") }
    nonisolated(unsafe) private static var observing = false

    static var isRunning: Bool { app.state == .runningForeground || app.state == .runningBackground }

    /// A fresh process. `scenario` is what the app starts out as.
    static func launch(scenario: [String: Any], firstLaunchOffer: Bool, keepDefaults: Bool) {
        observeBundleEnd()
        if isRunning { app.terminate() }
        try? FileManager.default.removeItem(at: commandFile)
        try? FileManager.default.removeItem(at: ackFile)
        commandID = 0

        var env: [String: String] = [
            "CERBERUS_UI_TESTING": "1",
            "CFFIXED_USER_HOME": home.path,
            "CERBERUS_UI_COMMAND": commandFile.path,
            "CERBERUS_UI_SCENARIO": json(scenario),
        ]
        if firstLaunchOffer { env["CERBERUS_UI_FIRST_LAUNCH"] = "1" }
        if keepDefaults { env["CERBERUS_UI_KEEP_DEFAULTS"] = "1" }
        if let found = server {
            env["CERBERUS_UI_LIVE_PORT"] = "\(found.port)"
            env["CERBERUS_UI_LIVE_KEY"] = found.userKeyPath
            env["CERBERUS_UI_LIVE_HOSTKEY"] = found.hostKeyLine
            env["CERBERUS_UI_LIVE_OTHERKEY"] = found.otherKeyLine
            env["CERBERUS_UI_LIVE_USER"] = found.userName
            env["CERBERUS_UI_LIVE_FORWARD_PORT"] = "\(found.forwardPort)"
            if let sftp = found.sftpPort { env["CERBERUS_UI_LIVE_SFTP_PORT"] = "\(sftp)" }
            if let totp = found.totp {
                env["CERBERUS_UI_LIVE_TOTP_PORT"] = "\(totp.port)"
                env["CERBERUS_UI_LIVE_TOTP_TARGET_PORT"] = "\(totp.targetPort)"
                env["CERBERUS_UI_LIVE_TOTP_HOSTKEY"] = totp.hostKeyLine
            }
        }
        app.launchEnvironment = env
        app.launch()
    }

    /// Puts the running app back to `scenario`, and waits until it says it has.
    static func reset(scenario: [String: Any]) -> Bool {
        commandID += 1
        let command: [String: Any] = ["id": commandID, "scenario": scenario]
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        try? data.write(to: commandFile, options: .atomic)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let ack = try? String(contentsOf: ackFile, encoding: .utf8), Int(ack) == commandID { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        sampleWedgedApp()
        return false
    }

    /// A reset that is never acknowledged (spec N36) leaves nothing to look at afterwards, so take a stack sample of
    /// the app now and say where it is.
    private static func sampleWedgedApp() {
        guard isRunning else { return }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cerberusssh.uitest").first?.processIdentifier else { return }
        let path = "/tmp/cerberus-reset-wedge-\(Int(Date().timeIntervalSince1970)).txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(pid)", "3", "-file", path]
        try? sample.run()
        sample.waitUntilExit()
        NSLog("CERBERUS-UITEST: the app did not acknowledge reset %d; stack sample in %@", commandID, path)
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// Ends the app when the whole run is over, since no single test does.
    private static func observeBundleEnd() {
        guard !observing else { return }
        observing = true
        XCTestObservationCenter.shared.addTestObserver(BundleEndObserver())
    }

    private final class BundleEndObserver: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) {
            if SharedApp.isRunning { SharedApp.app.terminate() }
        }
    }
}

/// Base for every UI test: the real app in its test mode (see `UITesting` in the app), with an
/// in-memory catalogue, no Keychain, a self-approving Touch ID gate and its own preferences, so
/// nothing on this Mac is read or changed. The app stays open between tests (`SharedApp`).
class CerberusUITestCase: XCTestCase {
    /// What this test wants the app to look like when it starts. Set before `launch()`.
    struct Options {
        /// `nil` takes the class's `seed`.
        var seed: String?
        /// Preferences to have in place.
        var defaults: [String: Any] = [:]
        /// A remembered backup passphrase.
        var backupPassphrase: String?
        /// A first backup has already been made.
        var lastExport = false
        /// Hosts to have connected before the test starts (see `UITesting.Scenario.connect`).
        var connect: [String] = []
        /// Basic seed hosts to mark as favourites before the sidebar chooses its initial tab.
        var favourites: [String] = []
        /// Snippets to have saved, as (title, body).
        var snippets: [(title: String, body: String)] = []
        /// Migration backups to have on disk, by the version each came from (see `UITesting.Scenario.migrationBackups`).
        var migrationBackups: [String] = []
        /// A new process rather than a reset, and with the first-launch import offer allowed.
        var freshLaunch = false
        var firstLaunchOffer = false
    }

    var options = Options()
    var app: XCUIApplication { SharedApp.app }

    /// The test `sshd`, once `startServer` has found it.
    var server: UITestSSHD?
    var forwardPort: Int { server?.forwardPort ?? 0 }

    /// `"basic"` fills the catalogue (see `UITesting.populate`); anything else leaves it empty.
    var seed: String { "basic" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        options = Options()
        server = nil
    }

    /// The app stays open for the next test, so whatever this one left on screen has to go: the main
    /// window's views are started afresh by the reset, but the Settings window is not (see the app),
    /// so a sheet left open in it would still be there. Escape closes a sheet.
    override func tearDownWithError() throws {
        guard SharedApp.isRunning else { return }
        for _ in 0..<4 {
            let open = settingsWindow.sheets.firstMatch.exists || app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists
            guard open else { break }
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    enum HostKeyState { case trusted, unknown, mismatched }

    func startServer(trusted: Bool = true) throws { try startServer(hostKey: trusted ? .trusted : .unknown) }

    /// Points the seeded `live-*` hosts at the throwaway `sshd` that the scheme's pre-action started
    /// (`Scripts/uitest-sshd.sh`). `.unknown` leaves the server's host key unknown to the app, so the
    /// host-key sheet appears; `.mismatched` pins a different key, so connecting meets a changed one.
    /// Skips the test, saying why, if there is no server (the tests were run without the shared scheme).
    func startServer(hostKey: HostKeyState) throws {
        guard let found = SharedApp.server else {
            throw XCTSkip("no test sshd: run through the CerberusSSH scheme (it starts one with Scripts/uitest-sshd.sh)")
        }
        server = found
        options.seed = switch hostKey { case .trusted: "live"; case .unknown: "live-untrusted"; case .mismatched: "live-mismatch" }
    }

    private var scenario: [String: Any] {
        var scenario: [String: Any] = ["seed": options.seed ?? seed, "lastExport": options.lastExport]
        if !options.defaults.isEmpty { scenario["defaults"] = options.defaults }
        if let passphrase = options.backupPassphrase { scenario["backupPassphrase"] = passphrase }
        if !options.connect.isEmpty { scenario["connect"] = options.connect }
        if !options.favourites.isEmpty { scenario["favourites"] = options.favourites }
        if !options.migrationBackups.isEmpty { scenario["migrationBackups"] = options.migrationBackups }
        if !options.snippets.isEmpty { scenario["snippets"] = options.snippets.map { ["title": $0.title, "body": $0.body] } }
        return scenario
    }

    /// Gets the app ready for this test: the running one reset, or a new one if the test asks for that
    /// (or there is none). Returns when its window is up.
    func launch() {
        if options.freshLaunch || !SharedApp.isRunning {
            SharedApp.launch(scenario: scenario, firstLaunchOffer: options.firstLaunchOffer, keepDefaults: false)
        } else {
            XCTAssertTrue(SharedApp.reset(scenario: scenario), "the app did not acknowledge the reset")
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "the window never appeared")
    }

    /// Chooses an item of the menu bar's Vault menu.
    func chooseVaultMenu(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        app.menuBars.menuBarItems["Vault"].click()
        let entry = app.menuBars.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no “\(item)” in the Vault menu", file: file, line: line)
        entry.click()
    }

    /// Quits and starts the app again, keeping its preferences, to see what survived.
    func relaunchKeepingPreferences() {
        SharedApp.launch(scenario: scenario, firstLaunchOffer: options.firstLaunchOffer, keepDefaults: true)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "the window never appeared")
    }

    // MARK: Finding things

    /// The throwaway home folder the app is pointed at (`CFFIXED_USER_HOME`), where a test can put
    /// a `.ssh` folder for the import sheets to find. One for the whole run, so a test that needs
    /// its own folder inside it makes one with a name of its own.
    var testHome: URL { SharedApp.home }

    var mainWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'SwiftUI.WindowGroup'")).firstMatch
    }

    var settingsWindow: XCUIElement { app.windows["com_apple_SwiftUI_Settings_window"] }

    var sidebar: XCUIElement { mainWindow.outlines["Sidebar"] }

    enum SidebarTab: String { case favourites, hosts, forwards }

    func showSidebarTab(_ tab: SidebarTab) {
        let button = mainWindow.buttons["sidebar-tab-\(tab.rawValue)"]
        wait(button)
        button.click()
    }

    /// A host's row text in the sidebar ("web-1, idle": the state follows the name).
    func hostRow(_ name: String) -> XCUIElement {
        sidebar.staticTexts.matching(NSPredicate(format: "value == %@ OR value BEGINSWITH %@", name, name + ",")).firstMatch
    }

    func folderRow(_ name: String) -> XCUIElement {
        sidebar.staticTexts[name]
    }

    func wait(_ element: XCUIElement, _ message: String = "", timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message.isEmpty ? "not found: \(element)" : message, file: file, line: line)
    }

    func waitGone(_ element: XCUIElement, _ message: String = "", timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message.isEmpty ? "still there: \(element)" : message, file: file, line: line)
    }

    /// A row of the Settings sidebar, by the category's title ("Known Hosts" is `settings-tab-knownHosts`).
    func settingsTab(_ title: String) -> XCUIElement {
        let words = title.split(separator: " ").map(String.init)
        let id = (words.first?.lowercased() ?? "") + words.dropFirst().map(\.capitalized).joined()
        return settingsWindow.descendants(matching: .any).matching(identifier: "settings-tab-\(id)").firstMatch
    }

    /// Opens Settings (⌘,) and, if given, one of its categories.
    func openSettings(tab: String? = nil) {
        app.typeKey(",", modifierFlags: .command)
        wait(settingsWindow, "Settings did not open")
        if let tab {
            let row = settingsTab(tab)
            wait(row, "no \(tab) category")
            row.click()
        }
    }
}
