import AppKit
import Foundation
import CryptoKit
import SwiftData
import CerberusModels
import CerberusVault

/// Support for the UI tests (CerberusSSHUITests).
///
/// The tests launch the real app with `CERBERUS_UI_TESTING=1`. In that mode nothing the person
/// owns is touched: the catalogue is in memory, the vault key is in memory (no Keychain), the
/// Touch ID gate approves itself, the backup passphrase is in memory, and no import offer
/// appears. The test also points the app's home folder at a temporary one, so preferences are
/// not shared with a real install. `CERBERUS_UI_SEED=basic` fills the catalogue with a few
/// hosts, folders, a forward, an identity and a trusted host key to act on.
///
/// `CERBERUS_UI_SEED=live` (or `live-untrusted`) also adds hosts that point at a throwaway
/// `sshd` the test started (`CERBERUS_UI_LIVE_PORT`, `_KEY` the path of a private key it accepts,
/// `_HOSTKEY` its public host key line, `_USER`), so sessions can really connect. With `live` the
/// server's host key is already trusted; with `live-untrusted` it is not, so the host-key sheet appears.
enum UITesting {
    /// The bundle id the UI tests' build of the app has (the "UITest" build configuration), so it has
    /// preferences, saved window state and a container of its own, apart from the real app's.
    static let bundleSuffix = ".uitest"

    /// Debug-style builds only, and only the app built for the UI tests: neither a release build nor
    /// the person's everyday build can be put into this mode from the environment, so its Touch ID
    /// gate cannot be bypassed and nothing of theirs is ever replaced by test data.
    #if DEBUG || PERFGATE
    static let isActive = ProcessInfo.processInfo.environment["CERBERUS_UI_TESTING"] == "1"
        && Bundle.main.bundleIdentifier?.hasSuffix(bundleSuffix) == true
    #else
    static let isActive = false
    #endif

    /// What a test wants the app to look like: set at launch (`CERBERUS_UI_SCENARIO`, JSON) and again,
    /// without restarting the app, by a command from the test (`UITestControl`).
    struct Scenario {
        /// `basic`, `live`, `live-untrusted`, `live-mismatch`, `live-mismatch-partway` (the first hop of `live-chain` trusted, the second not),
        /// `readme` (the demo catalogue the README's pictures are taken of), or anything else for an empty catalogue.
        var seed = "basic"
        /// Preferences to put in place, as the test's JSON object.
        var defaults: [String: Any] = [:]
        /// The remembered backup passphrase, if any.
        var backupPassphrase: String?
        /// A first backup has already been made (which unlocks the automatic-backup section).
        var lastExport = false
        /// Hosts (by name) to have connected, in this order, before the test starts. A click costs the
        /// test most of a second, so a test about something other than connecting skips doing it.
        var connect: [String] = []
        /// Basic seed hosts (by name) to mark as favourites before they enter the catalogue.
        var favourites: [String] = []
        /// Versions of migration backups to have on disk (just their files, named as real ones are).
        var migrationBackups: [String] = []
        /// Snippets to have saved, as (title, body).
        var snippets: [(title: String, body: String)] = []
        /// The performance gate: many sessions at once, each flooding the screen.
        var perf: PerfPlan?
        /// `light` or `dark` whatever the Mac is set to, for pictures in both; `nil` follows the Mac.
        var appearance: String?
        /// The main window's content size, so pictures come out the same size on any screen.
        var windowSize: CGSize?

        struct PerfPlan {
            var host = "live-1"
            var sessions = 20
            /// Typed into every session once all are connected.
            var command = "yes 'the quick brown fox jumps over the lazy dog 0123456789'"
            var seconds = 600
            /// Also open a file tab on the host (to see what that leaves behind when the app quits).
            var fileTab = false
        }

        init() {}

        init(json: String?) {
            guard let json, let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
            seed = object["seed"] as? String ?? seed
            defaults = object["defaults"] as? [String: Any] ?? [:]
            backupPassphrase = object["backupPassphrase"] as? String
            lastExport = object["lastExport"] as? Bool ?? false
            connect = object["connect"] as? [String] ?? []
            favourites = object["favourites"] as? [String] ?? []
            migrationBackups = object["migrationBackups"] as? [String] ?? []
            snippets = (object["snippets"] as? [[String: String]] ?? []).map { ($0["title"] ?? "", $0["body"] ?? "") }
            appearance = object["appearance"] as? String
            if let size = object["windowSize"] as? [Double], size.count == 2 { windowSize = CGSize(width: size[0], height: size[1]) }
            if let plan = object["perf"] as? [String: Any] {
                var parsed = PerfPlan()
                parsed.host = plan["host"] as? String ?? parsed.host
                parsed.sessions = plan["sessions"] as? Int ?? parsed.sessions
                parsed.command = plan["command"] as? String ?? parsed.command
                parsed.seconds = plan["seconds"] as? Int ?? parsed.seconds
                parsed.fileTab = plan["fileTab"] as? Bool ?? false
                perf = parsed
            }
        }
    }

    static var launchScenario: Scenario { Scenario(json: ProcessInfo.processInfo.environment["CERBERUS_UI_SCENARIO"]) }

    /// What the status bar shows for a `readme` host that really connects to the test's `sshd`: the address it would
    /// have, not 127.0.0.1 and the login of the person running the tests. Empty outside that seed.
    @MainActor static var shownEndpoints: [UUID: String] = [:]

    @MainActor static func shownEndpoint(for host: SSHHost) -> String? { isActive ? shownEndpoints[host.id] : nil }

    /// Where the `readme` seed puts its demo files: a website's folder on "this Mac" (`Projects/website`) and one
    /// folder per host standing in for its server (`servers/<host>`), at a path that names nobody. Hosts' stand-ins
    /// are under the test home for every other seed.
    static let readmeFiles = "/tmp/cerberus-demo"
    @MainActor static var hostFolders: String?

    /// Light or dark, and the main window's size, as the scenario asks. At launch the window may not be up yet,
    /// so it is looked for a few times.
    @MainActor static func applyLook(_ scenario: Scenario) async {
        guard isActive else { return }
        NSApp.appearance = switch scenario.appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        guard let size = scenario.windowSize else { return }
        for _ in 0..<30 {
            let workspace = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("SwiftUI.WindowGroup") == true && $0.isVisible }
            if let main = workspace.min(by: { $0.windowNumber < $1.windowNumber }) {
                main.setContentSize(size)
                main.center()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The password stored for the seeded "deploy" identity, which a test reveals.
    static let seededPassword = "uitest-password-1"

    /// With `CERBERUS_UI_FIRST_LAUNCH=1` the first-launch import offer is allowed in test mode (it is
    /// otherwise off, so it cannot fire over the home folder of the machine's real user).
    static let allowsFirstLaunchOffer = isActive && ProcessInfo.processInfo.environment["CERBERUS_UI_FIRST_LAUNCH"] == "1"

    /// A host's stand-in in a file tab: a folder of its own under the test home, since the SFTP
    /// channel is not wired yet and the point is the browser and the copy engine. `nil` outside test mode.
    @MainActor
    static func fileHostRoot(for hostID: UUID, context: ModelContext?) -> (path: String, name: String)? {
        guard isActive, let context,
              let host = context.fetchLogged(FetchDescriptor<SSHHost>()).first(where: { $0.id == hostID }),
              host.name != "live-sftp" else { return nil }   // "live-sftp" is the one that is really connected to
        let base = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? NSHomeDirectory()
        let folder = hostFolders.map { ($0 as NSString).appendingPathComponent(host.displayLabel) }
            ?? (base as NSString).appendingPathComponent("uitest-hosts/\(host.displayLabel)")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return (folder, host.displayLabel)
    }

    /// The same id for a seeded host every time, so a test that restarts the app (whose catalogue is rebuilt each
    /// launch) finds the hosts that the last run remembered.
    static func stableID(_ name: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Where a test's migration backups are: a folder of its own, never the real one.
    static var backupFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cerberus-uitest-migration-backups", isDirectory: true)
    }

    /// Starts the test with exactly these backups (files named as real ones are, a minute apart, with a little in them).
    private static func seedMigrationBackups(_ versions: [String]) {
        guard isActive else { return }
        let fm = FileManager.default
        StoreBackups.deleteAll(in: backupFolder)
        guard !versions.isEmpty else { return }
        try? fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        for (index, version) in versions.enumerated() {
            let name = StoreBackups.fileName(version: version, reason: .migration, date: Date().addingTimeInterval(-Double(index) * 60 - 3600))
            fm.createFile(atPath: backupFolder.appendingPathComponent(name).path, contents: Data(repeating: 0, count: 4096))
        }
    }

    @MainActor
    static func populate(context: ModelContext, vault: Vault, scenario: Scenario) async {
        // Whatever the seed, a test may ask for "a backup has been made", which unlocks the
        // automatic-backup section (which waits for a first one).
        if isActive, scenario.lastExport {
            appSettings(in: context).lastExportAt = Date()
            context.saveLogged()
        }
        seedMigrationBackups(scenario.migrationBackups)
        let seed = scenario.seed
        shownEndpoints = [:]
        hostFolders = nil
        if isActive, seed == "readme" {
            await populateReadme(context: context, vault: vault)
            context.saveLogged()
            return
        }
        guard isActive, ["basic", "live", "live-untrusted", "live-mismatch", "live-mismatch-partway"].contains(seed) else { return }

        let production = TreeNode(name: "Production")
        let europe = TreeNode(name: "EU", parent: production)
        let staging = TreeNode(name: "Staging")
        [production, europe, staging].forEach(context.insert)

        var identity: Identity?
        do {
            let item = try await VaultItemBridge.makeItem(for: .password(seededPassword), using: vault)
            context.insert(item)
            let made = Identity(name: "deploy", username: "deploy", kind: .password, vaultItemID: item.id)
            context.insert(made)
            identity = made
        } catch {
            CerberusLog.caught(error, note: "seeding the UI-test identity")
        }

        let web1 = SSHHost(id: stableID("web-1"), name: "web-1", hostname: "web-1.example.test", identity: identity, folder: production)
        let web2 = SSHHost(id: stableID("web-2"), name: "web-2", hostname: "web-2.example.test", identity: identity, folder: europe)
        let db = SSHHost(id: stableID("db-1"), name: "db-1", hostname: "db-1.example.test", identity: identity, folder: staging)
        for host in [web1, web2, db] {
            host.isFavourite = scenario.favourites.contains(host.name)
            context.insert(host)
        }
        context.insert(PortForward(
            kind: .local, bindPort: 15432, destinationHost: "db.internal", destinationPort: 5432,
            name: "Staging database", host: db
        ))
        context.insert(KnownHostKey(
            hostPattern: "web-1.example.test:22", keyType: "ssh-ed25519",
            publicKeyBlob: Data([1, 2, 3]), fingerprintSHA256: "SHA256:uitestFingerprintOne"
        ))
        if seed != "basic" { await populateLive(context: context, vault: vault, trust: seed == "live" ? .correct : seed == "live-mismatch" ? .wrong : seed == "live-mismatch-partway" ? .partway : .none, folder: production) }
        for snippet in scenario.snippets { context.insert(Snippet(title: snippet.title, body: snippet.body)) }
        context.saveLogged()
    }

    /// What the app already holds for the test server's host key.
    /// `partway`: the first server's key is pinned right and the second (SFTP) server's wrong, for a chain whose second hop it is.
    private enum LiveTrust { case none, correct, wrong, partway }

    /// Hosts that reach the test's own `sshd`.
    @MainActor
    private static func populateLive(context: ModelContext, vault: Vault, trust: LiveTrust, folder: TreeNode) async {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["CERBERUS_UI_LIVE_PORT"], let port = Int(portText),
              let keyPath = env["CERBERUS_UI_LIVE_KEY"], let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let user = env["CERBERUS_UI_LIVE_USER"] else {
            CerberusLog.warning("uitest", "live seed requested without a server")
            return
        }
        do {
            let item = try await VaultItemBridge.makeItem(for: .privateKey(pem), using: vault)
            context.insert(item)
            let identity = Identity(name: "live", username: user, kind: .privateKey, vaultItemID: item.id)
            context.insert(identity)
            for name in ["live-1", "live-2"] {
                context.insert(SSHHost(id: stableID(name), name: name, hostname: "127.0.0.1", port: port, identity: identity, folder: folder))
            }
            // One that goes through another, as a jump host (here the same server, reached through itself).
            if let first = try context.fetch(FetchDescriptor<SSHHost>()).first(where: { $0.name == "live-1" }) {
                context.insert(SSHHost(id: stableID("live-jump"), name: "live-jump", hostname: "127.0.0.1", port: port, identity: identity, folder: folder,
                                       jumpHostIDs: [first.id]))
            }
            // A server that wants a one-time code as well as the key, and a plain one reached through it.
            if let totpText = env["CERBERUS_UI_LIVE_TOTP_PORT"], let totpPort = Int(totpText),
               let _ = env["CERBERUS_UI_LIVE_TOTP_TARGET_PORT"] {
                let tester = Identity(name: "live-tester", username: "tester", kind: .privateKey, vaultItemID: item.id)
                context.insert(tester)
                let box = SSHHost(id: stableID("live-2fa"), name: "live-2fa", hostname: "127.0.0.1", port: totpPort, identity: tester, folder: folder)
                context.insert(box)
                // The target listens on 2222 inside the container; that is the address the jump host dials.
                context.insert(SSHHost(id: stableID("live-behind-2fa"), name: "live-behind-2fa", hostname: "127.0.0.1", port: 2222, identity: tester,
                                       folder: folder, jumpHostIDs: [box.id]))
                if trust == .correct, let line = env["CERBERUS_UI_LIVE_TOTP_HOSTKEY"], let parsed = try? OpenSSHPublicKey.parse(line) {
                    for p in [totpPort, 2222] {
                        context.insert(KnownHostKey(
                            hostPattern: "127.0.0.1:\(p)", keyType: parsed.algorithm, publicKeyBlob: parsed.blob,
                            fingerprintSHA256: SSHFingerprint.sha256(ofPublicKeyBlob: parsed.blob)
                        ))
                    }
                }
            }
            // One whose server offers SFTP, which a file tab really uses (the others' server runs a forced command).
            // Its host key is the same file as the first server's.
            if let sftpText = env["CERBERUS_UI_LIVE_SFTP_PORT"], let sftpPort = Int(sftpText) {
                let sftpHost = SSHHost(id: stableID("live-sftp"), name: "live-sftp", hostname: "127.0.0.1", port: sftpPort, identity: identity, folder: folder)
                context.insert(sftpHost)
                // A chain of two hops (this server, then the SFTP one) to a host on this server again.
                if let first = try context.fetch(FetchDescriptor<SSHHost>()).first(where: { $0.name == "live-1" }) {
                    context.insert(SSHHost(id: stableID("live-chain"), name: "live-chain", hostname: "127.0.0.1", port: port, identity: identity, folder: folder,
                                           jumpHostIDs: [first.id, sftpHost.id]))
                }
                let sftpPin = trust == .partway ? env["CERBERUS_UI_LIVE_OTHERKEY"] : trust == .correct ? env["CERBERUS_UI_LIVE_HOSTKEY"] : nil
                if let line = sftpPin, let parsed = try? OpenSSHPublicKey.parse(line) {
                    context.insert(KnownHostKey(
                        hostPattern: "127.0.0.1:\(sftpPort)", keyType: parsed.algorithm, publicKeyBlob: parsed.blob,
                        fingerprintSHA256: SSHFingerprint.sha256(ofPublicKeyBlob: parsed.blob)
                    ))
                }
            }
            // One that cannot connect (nothing listens on its port) and keeps trying, to watch the countdown.
            if let downText = env["CERBERUS_UI_LIVE_FORWARD_PORT"], let downPort = Int(downText) {
                context.insert(SSHHost(id: stableID("live-down"), name: "live-down", hostname: "127.0.0.1", port: downPort, identity: identity, folder: folder,
                                       keepAliveInterval: 5, autoReconnect: true))
            }
            // One that reconnects by itself when the connection drops.
            let auto = SSHHost(id: stableID("live-auto"), name: "live-auto", hostname: "127.0.0.1", port: port, identity: identity, folder: folder,
                               keepAliveInterval: 5, autoReconnect: true)
            context.insert(auto)
            // A forward that leads to the server itself, so a test can see it carry traffic.
            if let first = try context.fetch(FetchDescriptor<SSHHost>()).first(where: { $0.name == "live-1" }),
               let forwardPort = env["CERBERUS_UI_LIVE_FORWARD_PORT"].flatMap(Int.init) {
                context.insert(PortForward(
                    kind: .local, bindPort: forwardPort, destinationHost: "127.0.0.1", destinationPort: port,
                    name: "Live forward", host: first
                ))
            }
            let pinned = trust == .correct || trust == .partway ? env["CERBERUS_UI_LIVE_HOSTKEY"] : trust == .wrong ? env["CERBERUS_UI_LIVE_OTHERKEY"] : nil
            if let line = pinned, let parsed = try? OpenSSHPublicKey.parse(line) {
                context.insert(KnownHostKey(
                    hostPattern: "127.0.0.1:\(port)", keyType: parsed.algorithm, publicKeyBlob: parsed.blob,
                    fingerprintSHA256: SSHFingerprint.sha256(ofPublicKeyBlob: parsed.blob)
                ))
            }
        } catch {
            CerberusLog.caught(error, note: "seeding the live UI-test hosts")
        }
    }

    /// The demo catalogue the README's pictures are taken of (ReadmeScreenshotTests): folders with colours, hosts
    /// with tags, forwards and identities that look like a real setup. `web-1` and `api-1` really connect, to the
    /// test's `sshd`, and show the address they would have (`shownEndpoints`); the rest are never connected to.
    @MainActor
    private static func populateReadme(context: ModelContext, vault: Vault) async {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["CERBERUS_UI_LIVE_PORT"], let port = Int(portText),
              let keyPath = env["CERBERUS_UI_LIVE_KEY"], let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let user = env["CERBERUS_UI_LIVE_USER"] else {
            CerberusLog.warning("uitest", "readme seed requested without a server")
            return
        }
        let production = TreeNode(name: "Production", colorTag: NodeColor.red.rawValue)
        let staging = TreeNode(name: "Staging", colorTag: NodeColor.yellow.rawValue)
        let homeLab = TreeNode(name: "Home Lab", colorTag: NodeColor.teal.rawValue)
        [production, staging, homeLab].forEach(context.insert)

        do {
            let key = try await VaultItemBridge.makeItem(for: .privateKey(pem), using: vault)
            context.insert(key)
            // Signs in as the person running the tests, which the status bar never shows for these hosts.
            let deploy = Identity(name: "deploy", username: user, kind: .privateKey, vaultItemID: key.id)
            context.insert(deploy)
            let password = try await VaultItemBridge.makeItem(for: .password(seededPassword), using: vault)
            context.insert(password)
            let ops = Identity(name: "ops", username: "ops", kind: .password, vaultItemID: password.id)
            context.insert(ops)

            let web1 = SSHHost(id: stableID("web-1"), name: "web-1", hostname: "127.0.0.1", port: port, identity: deploy,
                               folder: production, tags: ["nginx"])
            let api1 = SSHHost(id: stableID("api-1"), name: "api-1", hostname: "127.0.0.1", port: port, identity: deploy,
                               folder: production, tags: ["api"])
            shownEndpoints[web1.id] = "deploy@web-1.example.com"
            shownEndpoints[api1.id] = "deploy@api-1.example.com"
            let hosts = [
                web1, api1,
                SSHHost(id: stableID("web-2"), name: "web-2", hostname: "web-2.example.com", identity: ops, folder: production, tags: ["nginx"]),
                SSHHost(id: stableID("db-1"), name: "db-1", hostname: "db-1.example.com", identity: ops, folder: production, tags: ["postgres"]),
                SSHHost(id: stableID("staging-web"), name: "staging-web", hostname: "web.staging.example.com", identity: ops, folder: staging),
                SSHHost(id: stableID("staging-db"), name: "staging-db", hostname: "db.staging.example.com", identity: ops, folder: staging,
                        tags: ["postgres"]),
                SSHHost(id: stableID("nas"), name: "nas", hostname: "nas.home.arpa", port: 2222, identity: ops, folder: homeLab),
                SSHHost(id: stableID("pi-hole"), name: "pi-hole", hostname: "pihole.home.arpa", identity: ops, folder: homeLab),
            ]
            hosts.forEach(context.insert)
            web1.isFavourite = true
            api1.isFavourite = true

            context.insert(PortForward(kind: .local, bindPort: 15432, destinationHost: "db.internal", destinationPort: 5432,
                                       name: "Production database", host: hosts[3]))
            context.insert(PortForward(kind: .dynamic, bindPort: 1080, name: "SOCKS proxy", host: web1))
            context.insert(PortForward(kind: .remote, bindPort: 8080, destinationHost: "localhost", destinationPort: 3000,
                                       name: "Webhook to my dev server", host: api1))
            context.insert(PortForward(kind: .local, bindPort: 8443, destinationHost: "localhost", destinationPort: 443,
                                       name: "NAS admin", host: hosts[6]))

            if let line = env["CERBERUS_UI_LIVE_HOSTKEY"], let parsed = try? OpenSSHPublicKey.parse(line) {
                context.insert(KnownHostKey(
                    hostPattern: "127.0.0.1:\(port)", keyType: parsed.algorithm, publicKeyBlob: parsed.blob,
                    fingerprintSHA256: SSHFingerprint.sha256(ofPublicKeyBlob: parsed.blob)
                ))
            }
            makeReadmeFiles()
        } catch {
            CerberusLog.caught(error, note: "seeding the readme UI-test hosts")
        }
    }

    /// The demo files a file tab shows in the README's picture (see `readmeFiles`), made afresh each time.
    @MainActor
    private static func makeReadmeFiles() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: readmeFiles)
        func put(_ folder: String, _ names: [String], size: Int) {
            for name in names {
                let path = (readmeFiles as NSString).appendingPathComponent("\(folder)/\(name)")
                try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: Data(repeating: 0x78, count: size + name.count * 137))
            }
        }
        put("Projects/website", ["index.html", "about.html", "styles.css", "app.js", "assets/logo.svg", "assets/hero.jpg", "README.md"], size: 900)
        put("servers/web-2", ["index.html", "styles.css", "app.js", "assets/logo.svg", "nginx.conf", "logs/access.log", "logs/error.log",
                              "backups/site-2026-11-01.tar.gz"], size: 1200)
        hostFolders = (readmeFiles as NSString).appendingPathComponent("servers")
    }
}
