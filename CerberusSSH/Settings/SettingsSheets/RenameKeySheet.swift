//
//  RenameKeySheet.swift
//  CerberusSSH
//
//  Created by L4mbd4W0lf on 2026/11/12.
//

import CerberusModels
import CerberusVault
import SwiftData
import SwiftUI

struct RenameKeySheet: View {
    let key: VaultKey
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    private var problem: IdentityName.Problem? {
        VaultKeyService.nameProblem(name, excluding: key.id, in: modelContext)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                if case .taken(let other)? = problem {
                    Text("Another key is already called “\(other)”.").font(
                        .caption
                    ).foregroundStyle(Color.statusBad)
                }
                if let error { Text(error).foregroundStyle(Color.statusBad) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(
                    .cancelAction
                )
                Button("Save") {
                    do {
                        try VaultKeyService.rename(
                            key,
                            to: name,
                            context: modelContext
                        )
                        dismiss()
                    } catch {
                        CerberusLog.caught(error)
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
            .padding(12)
        }
        .frame(width: 420, height: 200)
        .onAppear { name = key.name }
    }
}
