import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// Settings read from and written to the settings record, repairs made at launch, and log retention.
extension AppModel {
    // MARK: Quick settings (menu bar)

    /// The settings record, if one exists yet. Reading its properties from a view or menu
    /// keeps that view up to date, since SwiftData models are observable.
    var settingsRecord: AppSettings? {
        guard let context else { return nil }
        return context.fetchLogged(FetchDescriptor<AppSettings>()).first
    }

    /// Applies a change to the settings record, creating it first if need be.
    func changeSettings(_ change: (AppSettings) -> Void) {
        guard let context else { return }
        change(appSettings(in: context))
        context.saveLogged()
    }

    /// Identities made before names had to be unique may share a name, or have none; the
    /// later ones get a number so each can be told apart (and chosen) by name.
    func repairIdentityNames() {
        guard let context, case let identities = context.fetchLogged(FetchDescriptor<Identity>()),
              identities.count > 1 || identities.contains(where: { IdentityName.trimmed($0.name).isEmpty })
        else { return }
        let ordered = identities.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        let renames = IdentityName.repairs(for: ordered.map { (id: $0.id, name: $0.name) })
        guard !renames.isEmpty else { return }
        for identity in identities { if let name = renames[identity.id] { identity.name = name } }
        context.saveLogged()
    }

    /// Deletes logs past the retention settings. Runs at launch.
    func applyRecordingRetention() {
        guard let context else { return }
        let settings = context.fetchLogged(FetchDescriptor<AppSettings>()).first
        let days = settings?.logRetentionDays ?? 30
        let megabytes = settings?.logMaxMegabytes ?? 1_024
        Task.detached(priority: .utility) {
            RecordingStore().enforceRetention(maxAgeDays: days, maxMegabytes: megabytes)
        }
    }
}
