//
//  InstallKeySheet.swift
//  CerberusSSH
//
//  Created by Adrian Hall on 2026/11/12.
//

import CerberusModels
import CerberusSSHCore
import CerberusVault
import SwiftData
import SwiftUI

/// Puts a key's public half in a server's `~/.ssh/authorized_keys`, over a file connection to a host that already lets
/// this Mac in some other way (its password, another key). Only the public key is sent.
struct InstallKeySheet: View {
    let key: VaultKey
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]
    @State private var hostID: UUID?
    @State private var search = ""
    @State private var result: String?
    @State private var failed = false
    @State private var isWorking = false

    private var matching: [SSHHost] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return hosts }
        return hosts.filter { host in
            let haystack = [
                host.displayLabel, host.hostname, host.loginUsername ?? "",
            ].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install “\(key.name)” on a server")
                .font(.headline)
            Text(
                "Connects to the host the way a file tab does (its own password or key, and a host-key question the first time) and adds the public key of “\(key.name)” to ~/.ssh/authorized_keys there. A key that is already listed is not added twice. Nothing else on the server is changed."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(
                "Search hosts",
                text: $search,
                prompt: Text("Search by name, address, user or folder")
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("key-install-search")
            Table(matching, selection: $hostID) {
                TableColumn("Name") { host in
                    HStack(spacing: 6) {
                        HostOSIcon(os: host.detectedOS).frame(
                            width: 16,
                            height: 14
                        )
                        Text(host.displayLabel).lineLimit(1)
                    }
                }
                TableColumn("Address") {
                    Text($0.hostname).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("User") {
                    Text($0.loginUsername ?? "").foregroundStyle(
                        .secondary
                    ).lineLimit(1)
                }.width(90)
            }
            .alternatingRowBackgrounds(.disabled)
            .frame(minHeight: 180)
            .accessibilityLabel("Hosts")
            .accessibilityIdentifier("key-install-hosts")
            .overlay {
                if matching.isEmpty {
                    ContentUnavailableView(
                        hosts.isEmpty ? "No hosts" : "No matching hosts",
                        systemImage: "server.rack"
                    )
                }
            }

            if let result {
                Label(
                    result,
                    systemImage: failed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(failed ? Color.statusBad : Color.green).font(
                    .callout
                )
                .accessibilityIdentifier("key-install-result")
            }
            HStack {
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(
                    result == nil || failed ? "Cancel" : "Done",
                    role: .cancel
                ) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { run() }
                    .keyboardShortcut(.defaultAction).disabled(
                        hostID == nil || isWorking
                    )
                    .accessibilityIdentifier("key-install-go")
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    private func run() {
        guard let hostID else { return }
        isWorking = true
        result = nil
        Task {
            defer { isWorking = false }
            do {
                let session = try await app.makeFileSession(for: hostID)
                do {
                    let outcome = try await AuthorizedKeysInstaller.install(
                        publicKeyLine: key.publicKeyLine,
                        on: session.backend
                    )
                    await session.close()
                    failed = false
                    result =
                        outcome == .installed
                        ? "The key is installed. Connect with it from an identity that uses “\(key.name)”."
                        : "That server already lists this key."
                } catch {
                    await session.close()
                    throw error
                }
            } catch {
                CerberusLog.caught(error)
                failed = true
                result = error.localizedDescription
            }
        }
    }
}
