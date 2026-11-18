import AppKit
import SwiftUI

/// Settings ▸ About, which the app menu's About CerberusSSH opens: the app, the libraries it is built with, and the
/// licence texts that travel with it (the licence, the notice and the third-party notices, as Apache-2.0 asks).
struct AboutSettings: View {
    @State private var document = LegalDocument.thirdParty
    private let libraries = ThirdPartyNotices.libraries()

    var body: some View {
        Form {
            Section { header }

            Section("Built with") {
                if libraries.isEmpty {
                    Text("The list is in the third-party notices below.").foregroundStyle(.secondary)
                }
                ForEach(libraries) { library in
                    LabeledContent {
                        Text("\(library.version) · \(library.licence)").foregroundStyle(.secondary).monospacedDigit()
                    } label: {
                        if let url = library.url { Link(library.name, destination: url) } else { Text(library.name) }
                    }
                }
            }

            // In the pane's own type, not the licences' fixed width: it is a few sentences, read rather than scanned.
            Section("Notice") {
                ForEach(LegalDocument.notice.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityIdentifier("about-notice")

            Section("Licences") {
                Picker("Document", selection: $document) {
                    ForEach(LegalDocument.licences) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("acknowledgements-picker")
                ScrollView {
                    Text(document.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280)
                .accessibilityIdentifier("acknowledgements-text")
            }
        }
        .formStyle(.grouped)
    }

    /// The icon in the middle, then what the system's About panel shows: the name, version, a line about the app,
    /// where it lives, and the copyright.
    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("CerberusSSH").font(.title2.bold())
            Text("Version \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion")))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("about-version")
            Text("A native macOS SSH client that keeps everything on this Mac: your hosts, logins and keys are sealed locally, with an encrypted backup you control.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text("Licensed under the Apache License 2.0")
            Link("github.com/L4mbd4W0lf/cerberus-ssh", destination: URL(string: "https://github.com/L4mbd4W0lf/cerberus-ssh")!)
            Text(Self.info("NSHumanReadableCopyright")).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private static func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }
}

/// The licence texts shipped inside the app (copies of the files in the repository, see `CerberusSSH/Legal`).
private enum LegalDocument: String, CaseIterable, Identifiable {
    case thirdParty, licence, notice
    var id: Self { self }

    var title: String {
        switch self {
        case .thirdParty: "Third-party software"
        case .licence: "Licence"
        case .notice: "Notice"
        }
    }

    var file: String {
        switch self {
        case .thirdParty: ThirdPartyNotices.file
        case .licence: "LICENSE"
        case .notice: "NOTICE"
        }
    }

    /// The ones under Licences; the notice has a section of its own.
    static let licences: [LegalDocument] = [.thirdParty, .licence]

    /// The text as paragraphs with its wrapping undone: the file is wrapped at about 80 columns for reading as plain
    /// text, and those line ends would break lines short in a proportional font. A short line ends where it does on
    /// purpose (the name above the copyright), so only a long one is joined to the next.
    var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { paragraph in
            let lines = paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var joined = ""
            for (index, line) in lines.enumerated() {
                if index > 0 { joined += lines[index - 1].count >= 60 ? " " : "\n" }
                joined += line
            }
            return joined
        }
        .filter { !$0.isEmpty }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This text is not in the app. It is in the project's repository: \(file)."
        }
        return text
    }
}

/// The libraries in the app, read from the table at the top of the bundled third-party notices, so the list and the
/// notices cannot disagree.
enum ThirdPartyNotices {
    static let file = "THIRD_PARTY_NOTICES.md"

    struct Library: Identifiable, Equatable {
        var name: String
        var version: String
        var licence: String
        var url: URL?
        var id: String { name }
    }

    static func libraries() -> [Library] {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return libraries(in: text)
    }

    /// Each row of the table: its component without the note in brackets, leaving out the rows marked "not in the app".
    static func libraries(in text: String) -> [Library] {
        text.split(separator: "\n").compactMap { line -> Library? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // "| component | version | licence | from |" splits into six pieces, the outer two empty; not the header or its rule.
            guard cells.count == 6, cells[0].isEmpty,
                  cells[1] != "Component", !cells[1].hasPrefix("---"), !cells[1].contains("not in the app"),
                  let name = cells[1].components(separatedBy: " (").first else { return nil }
            return Library(name: name, version: cells[2], licence: cells[3], url: URL(string: cells[4]))
        }
    }
}
