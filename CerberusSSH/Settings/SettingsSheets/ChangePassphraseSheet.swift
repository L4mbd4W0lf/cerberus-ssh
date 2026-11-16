//
//  ChangePassphraseSheet.swift
//  CerberusSSH
//
//  Created by Adrian Hall on 2026/11/12.
//

import CerberusModels
import CerberusVault
import SwiftData
import SwiftUI

/// Puts a new passphrase on a key, or takes it off, without changing the key. The vault seals the key anyway; a
/// passphrase matters for the file when it is exported or the key is used elsewhere.
struct ChangePassphraseSheet: View {
    let key: VaultKey
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var remember = true
    @State private var remembered = false
    @State private var error: String?
    @State private var isWorking = false

    private var needsOld: Bool { key.isEncrypted && !remembered }
    private var missing: String? {
        if needsOld && old.isEmpty { return "Enter the current passphrase." }
        if new != confirm { return "The two new passphrases differ." }
        if new.isEmpty && !key.isEncrypted { return "Enter a new passphrase." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if needsOld {
                        SecureField("Current passphrase", text: $old)
                            .accessibilityIdentifier("key-passphrase-old")
                    }
                    SecureField(
                        "New passphrase",
                        text: $new,
                        prompt: Text(
                            key.isEncrypted
                                ? "Empty removes the passphrase" : "Required"
                        )
                    )
                    .accessibilityIdentifier("key-passphrase-new")
                    SecureField("Repeat new passphrase", text: $confirm)
                        .accessibilityIdentifier("key-passphrase-confirm")
                    if !new.isEmpty {
                        Toggle(
                            "Remember it in the vault so connecting needs no prompt",
                            isOn: $remember
                        )
                        .accessibilityIdentifier("key-passphrase-remember")
                    }
                } footer: {
                    Text(
                        key.isEncrypted
                            ? "The key stays the same: servers that list its public key keep accepting it."
                            : "This key has no passphrase now. The vault seals it either way; the passphrase protects it in a file you export."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(Color.statusBad).font(.callout)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let missing, !isWorking {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button(new.isEmpty ? "Remove Passphrase" : "Change") { run() }
                    .keyboardShortcut(.defaultAction).disabled(
                        missing != nil || isWorking
                    )
                    .accessibilityIdentifier("key-passphrase-change")
            }
            .padding(12)
        }
        .frame(width: 480, height: needsOld ? 340 : 290)
        .task {
            remembered = await VaultKeyService.remembersPassphrase(
                key,
                context: modelContext,
                vault: app.vault
            )
        }
    }

    private func run() {
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            guard
                await app.gate(
                    .editSecret,
                    reason: "Change the passphrase of “\(key.name)”",
                    declined: $error
                )
            else { return }
            do {
                try await VaultKeyService.changePassphrase(
                    of: key,
                    from: old,
                    to: new,
                    remember: remember,
                    context: modelContext,
                    vault: app.vault
                )
                dismiss()
            } catch let vaultError as VaultError {
                CerberusLog.caught(vaultError)
                error = vaultError.description
            } catch {
                CerberusLog.caught(error)
                self.error = error.localizedDescription
            }
        }
    }
}
