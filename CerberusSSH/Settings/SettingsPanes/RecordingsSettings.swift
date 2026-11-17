//
//  RecordingsSettings.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//

import CerberusModels
import CerberusVault
import SwiftData
import SwiftUI

// MARK: - Settings ▸ Recordings

/// The recording settings: how long recordings are kept. The recordings themselves are in the Recordings window.
struct RecordingsSettings: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query private var allSettings: [AppSettings]

    @State private var message: String?

    private let store = RecordingStore()

    var body: some View {
        Form {
            if let settings = allSettings.first { retention(settings) }
            Section {
                Button("Show Recordings…", systemImage: "record.circle") {
                    openWindow(id: RecordingsWindow.id)
                }
                .accessibilityIdentifier("show-recordings")
            }
        }
        .formStyle(.grouped)
    }

    private func retention(_ settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return Section("Retention") {
            Stepper(value: $settings.logRetentionDays, in: 0...3650, step: 5) {
                Text(
                    settings.logRetentionDays == 0
                        ? "Keep recordings forever"
                        : "Delete recordings older than \(settings.logRetentionDays) days"
                )
            }
            Stepper(
                value: $settings.logMaxMegabytes,
                in: 0...102_400,
                step: 128
            ) {
                Text(
                    settings.logMaxMegabytes == 0
                        ? "No size limit"
                        : "Keep at most \(settings.logMaxMegabytes.formatted()) MB (oldest deleted first)"
                )
            }
            HStack {
                Button("Apply Now") {
                    let removed = store.enforceRetention(
                        maxAgeDays: settings.logRetentionDays,
                        maxMegabytes: settings.logMaxMegabytes
                    )
                    message =
                        removed == 0
                        ? "Nothing to delete" : "Deleted \(removed)"
                    modelContext.saveLogged()
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "Also applied when the app starts. Recordings stay on this Mac and are never synced or exported."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
