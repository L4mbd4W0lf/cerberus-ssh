import SwiftUI
import AppKit
import SwiftData
import CerberusModels
import CerberusVault
import CerberusTerminal

/// Lets a UI test put the running app back to a known state without restarting it (a launch costs
/// seconds, and there are dozens of tests). Debug-style builds with the `.uitest` bundle id only.
///
/// The test writes a JSON command to the file named by `CERBERUS_UI_COMMAND`:
/// `{"id": 3, "scenario": {...}}`. The app polls that file; on a new id it resets everything (see
/// ``AppModel/uiTestReset(_:)``) and writes the id to `<file>.ack`, which is what the test waits for.
@MainActor
enum UITestControl {
    private static var started = false

    static func start(app: AppModel) {
        #if DEBUG || PERFGATE
        guard UITesting.isActive, !started, let path = ProcessInfo.processInfo.environment["CERBERUS_UI_COMMAND"] else { return }
        started = true
        Task { @MainActor in
            var lastID = 0
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let data = FileManager.default.contents(atPath: path),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = object["id"] as? Int, id > lastID else { continue }
                lastID = id
                var scenario = UITesting.Scenario()
                if let raw = object["scenario"],
                   let json = try? JSONSerialization.data(withJSONObject: raw),
                   let text = String(data: json, encoding: .utf8) { scenario = UITesting.Scenario(json: text) }
                await app.uiTestReset(scenario)
                try? "\(id)".write(toFile: path + ".ack", atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}

extension AppModel {
    /// Connects the named hosts one after another, as a double-click on each would, and returns once
    /// each connection attempt has finished (a prompt, such as a host-key question, is left for the test).
    func uiTestConnect(_ names: [String]) async {
        #if DEBUG || PERFGATE
        guard UITesting.isActive, let context else { return }
        for name in names {
            guard let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.name == name }) else { continue }
            await connect(to: host)
        }
        #endif
    }
}

#if DEBUG || PERFGATE
extension AppModel {
    /// Everything a test can have changed, put back: sessions, windows, the catalogue and vault,
    /// preferences, the remembered passphrase, the model's own flags, and every view.
    func uiTestReset(_ scenario: UITesting.Scenario) async {
        guard UITesting.isActive, let context else { return }

        // Windows: keep the oldest workspace window, close every other window (extra terminals,
        // Settings, Help, Port Forwards). Sheets inside the kept one go with the remount below.
        let workspace = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("SwiftUI.WindowGroup") == true }
        let main = workspace.min { $0.windowNumber < $1.windowNumber }
        for window in NSApp.windows where window !== main && window.isVisible && !(window is NSPanel) { window.close() }

        autoBackupTask?.cancel()
        autoBackupTask = nil
        do { try await eraseAllData(context: context) } catch { CerberusLog.caught(error, note: "resetting for a UI test") }

        // Preferences and the remembered passphrase.
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        for (key, value) in scenario.defaults { UserDefaults.standard.set(value, forKey: key) }
        try? exportPassphrases.forget()
        if let passphrase = scenario.backupPassphrase { try? exportPassphrases.save(passphrase) }

        // The model's own state.
        resetCustomThemes()
        forwardFailures = [:]
        startingForwards = []
        renamingTabID = nil
        draggingTabID = nil
        pendingWindowOrigins = [:]
        inspectorWindows = []
        terminalWindows = []
        lastError = nil
        isExportingBackup = false
        isImportingBackup = false
        isImportingKnownHosts = false
        isImportingSSHFolder = false
        isImportingSSHConfig = false
        isAutoBackupRunning = false
        isShowingConnectionLog = false
        isShowingReplayLog = false
        isShowingSnippets = false
        sidebarTabRequest = nil
        settingsTab = .backup
        helpPage = .shortcuts
        lastGateApproval = nil

        await UITesting.populate(context: context, vault: vault, scenario: scenario)
        await uiTestConnect(scenario.connect)
        startAutoBackupSchedule()

        uiTestEpoch += 1   // every view starts afresh: no sheet, search text or selection survives
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
