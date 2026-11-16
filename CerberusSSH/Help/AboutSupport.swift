import SwiftUI
import AppKit

/// The About panel and the Acknowledgements window (the licence, the notice and the third-party
/// notices, which the Apache-2.0 licence asks to travel with the app).
enum AcknowledgementsWindow {
    static let id = "acknowledgements"
}

enum AboutPanel {
    /// The system's own About panel: the icon, the name, the version and build, and the copyright come
    /// from the app's bundle; the credits are what is added here.
    @MainActor
    static func show() {
        let credits = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 6
        func add(_ text: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: centred]
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("A native macOS SSH client that keeps everything on this Mac: your hosts, logins and keys are sealed locally, with an encrypted backup you control.\n")
        add("Licensed under the Apache License 2.0.\n")
        add("github.com/L4mbd4W0lf/cerberus-ssh", link: URL(string: "https://github.com/L4mbd4W0lf/cerberus-ssh"))
        add("\n\nBuilt with swift-nio-ssh, SwiftNIO, swift-crypto and SwiftTerm. See Acknowledgements.")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// The licence texts shipped inside the app (copies of the files in the repository, see `CerberusSSH/Legal`).
struct AcknowledgementsView: View {
    private enum Document: String, CaseIterable, Identifiable {
        case thirdParty = "Third-party software"
        case licence = "Licence"
        case notice = "Notice"
        var id: String { rawValue }
        var file: String {
            switch self {
            case .thirdParty: "THIRD_PARTY_NOTICES.md"
            case .licence: "LICENSE"
            case .notice: "NOTICE"
            }
        }
    }

    @State private var document = Document.thirdParty

    var body: some View {
        VStack(spacing: 0) {
            Picker("Document", selection: $document) {
                ForEach(Document.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            .accessibilityIdentifier("acknowledgements-picker")
            Divider()
            ScrollView {
                Text(text(of: document))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .accessibilityIdentifier("acknowledgements-text")
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func text(of document: Document) -> String {
        guard let url = Bundle.main.url(forResource: document.file, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This text is not in the app. It is in the project's repository: \(document.file)."
        }
        return text
    }
}
