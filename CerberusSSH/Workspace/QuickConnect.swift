import SwiftUI
import AppKit
import CerberusModels

/// Quick connect (⌘K): a field in the middle of the toolbar that fuzzy-searches every host, with its matches
/// in a dropdown beneath it. Return opens the chosen host in a new tab, ⌥Return splits beside the current pane,
/// ⇧Return opens a window of its own. Recent and frequent hosts are listed first, before anything is typed.
enum QuickConnect {
    /// The hosts that match `query`, best first, at most twelve.
    static func results(_ query: String, in hosts: [SSHHost]) -> [SSHHost] {
        let candidates = hosts.map {
            QuickConnectSearch.Candidate(
                id: $0.id, name: $0.displayLabel, hostname: $0.hostname,
                username: $0.loginUsername ?? "", tags: $0.tags,
                folderPath: $0.folderPath,
                connectionCount: $0.connectionCount, lastConnectedAt: $0.lastConnectedAt
            )
        }
        let order = QuickConnectSearch.rank(query, in: candidates).prefix(12).map(\.id)
        let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// Who and where the host is, and its tags: what tells two hosts with one name apart.
    static func detail(_ host: SSHHost) -> String {
        let user = host.loginUsername ?? ""
        var parts = [user.isEmpty ? host.hostname : "\(user)@\(host.hostname)"]
        if !host.tags.isEmpty { parts.append(host.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts.joined(separator: "  ·  ")
    }
}

/// The matches under the toolbar's quick connect field. It is drawn over the window's content rather than as a
/// popover, so the field keeps the keyboard while it is open.
struct QuickConnectDropdown: View {
    let results: [SSHHost]
    let hasHosts: Bool
    @Binding var selection: Int
    /// Whether the pointer is over it, so it stays open for a click even if the field lost the keyboard on the way.
    @Binding var isHovering: Bool
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text(hasHosts ? "No matching hosts." : "No hosts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, host in
                                row(host)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { onChoose(index) }
                                    .id(host.id)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("quick-connect-row-\(host.displayLabel)")
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Text("↩ new tab").help("Open in a new tab")
                Text("⌥↩ split").help("Open beside the current pane")
                Text("⇧↩ window").help("Open in a window of its own")
                Spacer()
                Text("esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .frame(width: 480)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-connect-dropdown")
    }

    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 8) {
            HostOSIcon(os: host.detectedOS).frame(width: 18, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayLabel)
                Text(QuickConnect.detail(host)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The quick connect field: an AppKit search field, because SwiftUI's focus state does not reach a toolbar item
/// reliably, and this one must say when it has the keyboard (so the dropdown opens), take the keyboard when ⌘K asks,
/// and handle ↑ ↓ Return and Escape itself.
struct QuickConnectTextField: NSViewRepresentable {
    @Binding var text: String
    /// Whether the keyboard is in the field.
    @Binding var isEditing: Bool
    /// Changed to ask the field to take the keyboard (and select what is in it), or to let it go.
    let focusToken: Int
    let blurToken: Int
    /// -1 for ↑, 1 for ↓.
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Quick Connect"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.toolTip = "Quick Connect (\(AppShortcut.quickConnect.display))"
        field.setAccessibilityIdentifier("quick-connect-field")
        field.onFocus = { [coordinator = context.coordinator] in coordinator.parent.isEditing = true }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        if coordinator.blurToken != blurToken {
            coordinator.blurToken = blurToken
            DispatchQueue.main.async { if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Says when it gets the keyboard (the field editor, which has it while typing, reports the end).
    final class Field: NSSearchField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }

        /// A click starts editing without the field being asked to become first responder (that is how ⌘K does it), so
        /// without this a click would leave the dropdown shut. Once the click has done its work, the field editor is in.
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if currentEditor() != nil { onFocus?() }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: QuickConnectTextField
        var focusToken: Int
        var blurToken: Int
        init(_ parent: QuickConnectTextField) {
            self.parent = parent
            focusToken = parent.focusToken
            blurToken = parent.blurToken
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isEditing = true }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.isEditing = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            // Return, and Return with a modifier: a text field is told ⌥Return and ⌃Return are different commands from
            // plain Return (insert a newline *ignoring the field editor*, a line break), and one it does not handle just beeps.
            // The modifier is read by the one who opens the host.
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }
}
