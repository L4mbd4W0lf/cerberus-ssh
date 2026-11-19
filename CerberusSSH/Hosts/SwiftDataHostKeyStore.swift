import Foundation
import SwiftData
import CerberusModels
import CerberusSSHCore

/// SwiftData-backed trust store.
///
/// `ModelContext` is not `Sendable` and SwiftData containers are not safe to use
/// from arbitrary threads, so every access is funnelled onto the main actor and
/// the results are converted to `StoredHostKey` values before crossing back to
/// the SSH actor.
@MainActor
final class SwiftDataHostKeyStore: HostKeyStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    nonisolated func keys(forPattern pattern: String) async throws -> [StoredHostKey] {
        try await MainActor.run {
            var descriptor = FetchDescriptor<KnownHostKey>(
                predicate: #Predicate { $0.hostPattern == pattern }
            )
            descriptor.fetchLimit = 32
            return try context.fetch(descriptor).map {
                StoredHostKey(
                    hostPattern: $0.hostPattern,
                    keyType: $0.keyType,
                    wireBlob: $0.publicKeyBlob,
                    fingerprintSHA256: $0.fingerprintSHA256,
                    source: $0.source,
                    revoked: $0.revoked
                )
            }
        }
    }

    nonisolated func store(_ key: StoredHostKey) async throws {
        try await MainActor.run {
            let pattern = key.hostPattern
            let fingerprint = key.fingerprintSHA256
            let existing = try context.fetch(
                FetchDescriptor<KnownHostKey>(
                    predicate: #Predicate {
                        $0.hostPattern == pattern && $0.fingerprintSHA256 == fingerprint
                    }
                )
            )
            guard existing.isEmpty else { return }

            context.insert(
                KnownHostKey(
                    hostPattern: key.hostPattern,
                    keyType: key.keyType,
                    publicKeyBlob: key.wireBlob,
                    fingerprintSHA256: key.fingerprintSHA256,
                    source: key.source,
                    revoked: key.revoked
                )
            )
            try context.save()
        }
    }

    nonisolated func removeKeys(forPattern pattern: String) async throws {
        try await MainActor.run {
            let existing = try context.fetch(
                FetchDescriptor<KnownHostKey>(predicate: #Predicate { $0.hostPattern == pattern })
            )
            for key in existing { context.delete(key) }
            try context.save()
        }
    }
}
