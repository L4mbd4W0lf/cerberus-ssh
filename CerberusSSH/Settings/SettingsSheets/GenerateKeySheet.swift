//
//  GenerateKeySheet.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//

import CerberusModels
import CerberusVault
import SwiftData
import SwiftUI

struct GenerateKeySheet: View {
    var onAdded: (VaultKey) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var algorithm = SSHKeyAlgorithm.ed25519
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var remember = true
    @State private var error: String?
    @State private var created: VaultKey?
    @State private var isGenerating = false

    private var nameProblem: IdentityName.Problem? {
        name.isEmpty ? nil : VaultKeyService.nameProblem(name, in: modelContext)
    }
    private var canGenerate: Bool {
        !IdentityName.trimmed(name).isEmpty && nameProblem == nil
            && !isGenerating
    }
    private var isRSA: Bool { algorithm.rawValue.hasPrefix("rsa") }
    private var strength: PassphraseStrength { PassphraseStrength(passphrase) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let created {
                    Section("Created") {
                        Text(
                            "“\(created.name)” is in the vault. Add its public key to the server's ~/.ssh/authorized_keys:"
                        )
                        Text(created.publicKeyLine)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                created.publicKeyLine,
                                forType: .string
                            )
                        }
                    }
                } else {
                    Section("New key") {
                        TextField(
                            "Name",
                            text: $name,
                            prompt: Text("Deploy key")
                        )
                        .accessibilityIdentifier("key-generate-name")
                        if case .taken(let other)? = nameProblem {
                            Text(
                                "Another key is already called “\(other)”. Names must be unique."
                            )
                            .font(.caption).foregroundStyle(Color.statusBad)
                        }
                        Picker("Type", selection: $algorithm) {
                            ForEach(SSHKeyAlgorithm.allCases) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        if isRSA {
                            Text(
                                "RSA is for older servers that do not accept Ed25519. Prefer Ed25519 when the server allows it. A 4096-bit key can take several seconds to make."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField(
                            "Comment",
                            text: $comment,
                            prompt: Text(name.isEmpty ? "Optional" : name)
                        )
                        SecureField(
                            "Passphrase",
                            text: $passphrase,
                            prompt: Text("Optional")
                        )
                        .accessibilityIdentifier("key-generate-passphrase")
                        if !passphrase.isEmpty {
                            HStack {
                                ProgressView(value: strength.fraction).tint(
                                    strength.color
                                ).frame(width: 120)
                                Text(strength.label).font(.caption)
                                    .foregroundStyle(strength.color)
                                    .accessibilityLabel(
                                        "Passphrase strength: \(strength.label)"
                                    )
                                    .accessibilityIdentifier(
                                        "key-generate-strength"
                                    )
                            }
                            if strength == .weak {
                                Text(
                                    "This passphrase is easy to guess. You can still use it."
                                )
                                .font(.caption).foregroundStyle(
                                    Color.statusWarning
                                )
                            }
                            Toggle(
                                "Remember it in the vault so connecting needs no prompt",
                                isOn: $remember
                            )
                        }
                        Text(
                            "The key is made here and goes straight into the vault; no private key file is written. The vault seals it, so a passphrase is optional: it protects the key in a file you export."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Color.statusBad).font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                if created == nil {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if isGenerating { ProgressView().controlSize(.small) }
                    Button(isGenerating ? "Generating…" : "Generate") { run() }
                        .keyboardShortcut(.defaultAction).disabled(!canGenerate)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(
                        .defaultAction
                    )
                }
            }
            .padding(12)
        }
        .frame(width: 520, height: 420)
    }

    private func run() {
        error = nil
        isGenerating = true
        Task {
            defer { isGenerating = false }
            do {
                let key = try await VaultKeyService.generateKey(
                    name: name,
                    algorithm: algorithm,
                    comment: comment.isEmpty
                        ? IdentityName.trimmed(name) : comment,
                    passphrase: passphrase,
                    remember: remember,
                    context: modelContext,
                    vault: app.vault
                )
                created = key
                onAdded(key)
            } catch {
                CerberusLog.caught(error)
                self.error = error.localizedDescription
            }
        }
    }
}
