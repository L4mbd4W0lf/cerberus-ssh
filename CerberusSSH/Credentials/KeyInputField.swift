import SwiftUI
import CerberusModels
import AppKit
import UniformTypeIdentifiers
import CerberusVault

/// Takes a key either from a file or as text pasted in, because a key does not always come
/// as a file: it may arrive in a message, a ticket or a password manager.
///
/// `text` holds the key once it has been accepted (tidied, and checked to be a key we can
/// read) and is empty until then.
struct KeyInputField: View {
    enum Kind { case privateKey, publicKey }

    let kind: Kind
    @Binding var text: String
    @Binding var label: String?
    @Binding var error: String?
    var chooseTitle = "Choose file…"
    /// Called when a key was accepted (with what is known about it and, for a file, its name) or
    /// cleared (`nil`).
    var onChange: (OpenSSHKeyMetadata?, String?) -> Void = { _, _ in }

    @Environment(AppModel.self) private var app

    private enum Source: String, CaseIterable, Identifiable { case file = "File", paste = "Paste text"; var id: String { rawValue } }
    @State private var source = Source.file
    @State private var pasted = ""
    @State private var isChoosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source {
            case .file:
                HStack {
                    Button(chooseTitle, systemImage: "doc") { isChoosingFile = true }
                    Text(label ?? "None selected")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            case .paste:
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $pasted)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    if pasted.isEmpty {
                        Text(kind == .privateKey ? "Paste the whole key, from -----BEGIN … to -----END …" : "Paste the public key line (ssh-rsa AAAA…)")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(10).allowsHitTesting(false)
                    }
                }
                HStack {
                    Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                        pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    }
                    if !pasted.isEmpty {
                        Button("Clear", systemImage: "xmark.circle") { pasted = "" }
                    }
                    Spacer()
                    if let label, !text.isEmpty { Label(label, systemImage: "checkmark.circle.fill").foregroundStyle(Color.statusGood).font(.caption) }
                }
                .controlSize(.small)
            }
        }
        .onChange(of: pasted) { _, new in accept(pasted: new) }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { read($0) }
    }

    // MARK: Reading

    private func read(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let contents = try String(contentsOf: url, encoding: .utf8)
            load(KeyText.normalised(contents), description: url.lastPathComponent, fileName: url.lastPathComponent)
        } catch {
            CerberusLog.caught(error)
            fail(error.localizedDescription)
        }
    }

    private func accept(pasted: String) {
        let tidy = KeyText.normalised(pasted)
        guard !tidy.isEmpty else { clear(); return }
        // Half a key is not a mistake yet: wait until it looks finished before complaining.
        let finished = kind == .publicKey || KeyText.looksComplete(tidy)
        load(tidy, description: "Pasted key", fileName: nil, quietIfUnreadable: !finished)
    }

    private func load(_ tidy: String, description: String, fileName: String?, quietIfUnreadable: Bool = false) {
        do {
            switch kind {
            case .privateKey:
                let metadata = try app.vault.inspectPrivateKey(pem: tidy)
                text = tidy
                label = "\(description) — \(metadata.algorithm)"
                error = nil
                onChange(metadata, fileName)
            case .publicKey:
                let parsed = try OpenSSHPublicKey.parse(tidy)
                text = tidy
                label = "\(description) — \(parsed.algorithm)"
                error = nil
                onChange(nil, fileName)
            }
        } catch {
            CerberusLog.caught(error)
            if quietIfUnreadable { clear(keepError: true); return }
            fail((error as? VaultError)?.description ?? error.localizedDescription)
        }
    }

    private func clear(keepError: Bool = false) {
        text = ""
        label = nil
        if !keepError { error = nil }
        onChange(nil, nil)
    }

    private func fail(_ message: String) {
        text = ""
        label = nil
        error = message
        onChange(nil, nil)
    }
}
