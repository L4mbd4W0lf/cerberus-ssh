import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// The biometric gate, the remembered backup passphrase, host-key replacement and erasing everything.
extension AppModel {
    /// The remembered backup passphrase, after the gate, or `nil` if there is none or the gate was refused.
    func rememberedBackupPassphrase() async -> String? {
        guard await gate(.reveal, reason: "Use the saved backup passphrase") else { return nil }
        do { return try exportPassphrases.load() } catch {
            CerberusLog.caught(error)
            return nil
        }
    }

    /// Asks for Touch ID (or the account password) if the policy in Settings says this action
    /// needs it (spec §6.4). A Mac with nothing set up to ask with is treated as approved.
    func gate(_ action: GatedAction, reason: String) async -> Bool {
        if UITesting.isActive { return true }  // tests can't answer Touch ID
        let policy = settingsRecord?.gatePolicy ?? .default
        guard policy.requiresGate(for: action) else { return true }
        if action == .useSecret, let last = lastGateApproval, Date().timeIntervalSince(last) < 30 { return true }
        let outcome = await BiometricGate.authenticate(reason: reason)
        if outcome == .denied {
            CerberusLog.info("vault", "Gate denied for \(action)")
            return false
        }
        lastGateApproval = Date()
        return true
    }

    /// `gate`, but a refusal is also written to `note`, so a control that snapped back, or a button that did
    /// nothing, says why beside itself. An approval clears the note.
    func gate(_ action: GatedAction, reason: String, declined note: Binding<String?>) async -> Bool {
        let approved = await gate(action, reason: reason)
        note.wrappedValue = approved ? nil : "Authentication was cancelled."
        return approved
    }

    /// Explicit recovery from a host-key mismatch (spec §7.2): forgets the pinned key
    /// behind the biometric gate, then reconnects so the new key goes through the
    /// normal first-use prompt. There is no way to connect past a mismatch without it.
    func replaceStoredHostKey(for session: SessionViewModel) async {
        guard let hostKeyStore else { return }
        // The key that changed: a jump host's, when the mismatch was on the way, not the final host's.
        let pattern = session.hostKeyMismatch?.pattern ?? session.hostKeyPattern
        guard await gate(.replaceHostKey, reason: "Replace the stored host key for \(pattern)") else { return }
        do {
            try await hostKeyStore.removeKeys(forPattern: pattern)
        } catch {
            CerberusLog.caught(error)
            report(describe(error))
            return
        }
        await session.reconnect()
    }

    /// Wipes the catalogue, trust store, settings and vault key, as on a fresh install.
    /// Backups made earlier are unaffected and can still be imported.
    func eraseAllData(context: ModelContext) async throws {
        await closeAll()
        try context.delete(model: SSHHost.self)
        try context.delete(model: TreeNode.self)
        try context.delete(model: Identity.self)
        try context.delete(model: VaultItem.self)
        try context.delete(model: VaultKey.self)
        try context.delete(model: KnownHostKey.self)
        try context.delete(model: Snippet.self)
        try context.delete(model: PortForward.self)
        try context.delete(model: AppSettings.self)
        try context.save()
        // The copies kept before a migration hold the same catalogue, so erasing everything takes them too.
        StoreBackups.deleteAll(in: storeBackupFolder)
        try await vault.eraseAndRecreateKey()
    }

    /// Where the copies made before a migration are kept (a throwaway folder in a UI test).
    var storeBackupFolder: URL { UITesting.isActive ? UITesting.backupFolder : StoreBackups.folder }
}
