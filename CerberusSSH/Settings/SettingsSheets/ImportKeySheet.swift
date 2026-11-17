//
//  ImportKeySheet.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//

import CerberusModels
import CerberusVault
import SwiftData
import SwiftUI

/// Brings an existing key into the vault: the private key file, and optionally its
/// `.pub` file, which is checked against it.
struct ImportKeySheet: View {
    var onAdded: (VaultKey) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var privateKeyPEM = ""
    @State private var privateLabel: String?
    @State private var publicText = ""
    @State private var publicLabel: String?
    @State private var passphrase = ""
    @State private var isEncrypted = false
    @State private var error: String?
    @State private var publicError: String?
    @State private var isWorking = false

    private var nameProblem: IdentityName.Problem? {
        name.isEmpty ? nil : VaultKeyService.nameProblem(name, in: modelContext)
    }

    /// Why Import is greyed out, so it is never a mystery.
    private var missing: String? {
        if privateKeyPEM.isEmpty { return "Choose or paste the private key." }
        if IdentityName.trimmed(name).isEmpty { return "Give the key a name." }
        if case .taken(let other)? = nameProblem {
            return "The name “\(other)” is already used."
        }
        if isEncrypted && passphrase.isEmpty {
            return "Enter the key's passphrase."
        }
        return nil
    }

    private var canImport: Bool { !isWorking && missing == nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let message = error ?? publicError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusBad).font(.callout)
                }
                Section("Name") {
                    TextField("Name", text: $name, prompt: Text("Deploy key"))
                    if let problem = nameProblem,
                        case .taken(let other) = problem
                    {
                        Text(
                            "Another key is already called “\(other)”. Names must be unique."
                        )
                        .font(.caption).foregroundStyle(Color.statusBad)
                    }
                }
                Section("Private key") {
                    KeyInputField(
                        kind: .privateKey,
                        text: $privateKeyPEM,
                        label: $privateLabel,
                        error: $error
                    ) { metadata, fileName in
                        isEncrypted = metadata?.isEncrypted ?? false
                        if let fileName, name.isEmpty { name = fileName }
                    }
                    if isEncrypted {
                        SecureField(
                            "Passphrase",
                            text: $passphrase,
                            prompt: Text("This key is encrypted")
                        )
                    }
                    Text(
                        "The private key is sealed in the vault. A file on disk is not changed or deleted."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Public key (optional)") {
                    KeyInputField(
                        kind: .publicKey,
                        text: $publicText,
                        label: $publicLabel,
                        error: $publicError
                    )
                    Text(
                        "The public key is worked out from the private key. One you add here is only checked against it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let missing, !isWorking {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button("Import") { run() }.keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }

    private func run() {
        isWorking = true
        error = nil
        Task {
            do {
                let key = try await VaultKeyService.importKey(
                    name: name,
                    privateKeyPEM: privateKeyPEM,
                    passphrase: passphrase.isEmpty ? nil : passphrase,
                    publicKeyText: publicText,
                    context: modelContext,
                    vault: app.vault
                )
                onAdded(key)
                dismiss()
            } catch let vaultError as VaultError {
                CerberusLog.caught(vaultError)
                error = vaultError.description
            } catch {
                CerberusLog.caught(error)
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
