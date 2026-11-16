import SwiftUI
import CerberusModels

/// Picks a jump host from a long list: a search box over every host that could be used, with
/// enough beside each name (its folder and address) to tell apart hosts that share one.
struct JumpHostPicker: View {
    let candidates: [SSHHost]
    let onPick: (SSHHost) -> Void

    @State private var isOpen = false

    var body: some View {
        Button("Add jump host…", systemImage: "point.3.connected.trianglepath.dotted") { isOpen = true }
            .disabled(candidates.isEmpty)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                JumpHostList(candidates: candidates) { host in
                    isOpen = false
                    onPick(host)
                }
            }
    }
}

struct JumpHostList: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let candidates: [SSHHost]
    /// The line under the list; the file tab says something different from the host editor.
    var hint = "Return adds the highlighted one"
    /// A first choice that is not a host (a file pane's "This Mac"), shown above the hosts.
    var thisMac: (() -> Void)?
    let onPick: (SSHHost) -> Void

    @State private var search = ""
    @State private var highlighted: UUID?
    @FocusState private var searchFocused: Bool

    /// What tells two hosts with the same name apart: who and where they are.
    static func detail(_ host: SSHHost) -> String {
        let user = host.loginUsername ?? ""
        return (user.isEmpty ? "" : "\(user)@") + host.hostname + (host.port == 22 ? "" : ":\(host.port)")
    }

    private var matches: [SSHHost] {
        let query = SidebarSearch.parse(search)
        return candidates
            .filter { host in
                SidebarSearch.matches(query, .init(
                    name: host.displayLabel, hostname: host.hostname, username: host.loginUsername ?? "",
                    folderPath: host.folderPath, tags: host.tags
                ))
            }
            .sorted { $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name, address, folder or #tag", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = pick() { onPick(first) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear the search")
                }
            }
            .padding(10)
            Divider()

            let shown = matches
            if let thisMac, search.isEmpty || "this mac".contains(search.lowercased()) {
                Button(action: thisMac) {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary).frame(width: 18)
                        Text("This Mac")
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("files-source-this-mac")
                Divider()
            }
            if shown.isEmpty {
                ContentUnavailableView.search(text: search).frame(height: 160)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { host in
                                row(host, isHighlighted: host.id == (highlighted ?? shown.first?.id))
                                    .id(host.id)
                            }
                        }
                    }
                    .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                }
                .frame(height: 280)
            }
            Divider()
            Text("\(shown.count) of \(candidates.count) hosts · \(hint)")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 400)
        .onAppear { searchFocused = true }
        .onChange(of: search) { _, _ in highlighted = nil }
    }

    private func row(_ host: SSHHost, isHighlighted: Bool) -> some View {
        Button { onPick(host) } label: {
            HStack(spacing: 8) {
                HostOSIcon(os: host.detectedOS).frame(width: 18, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayLabel)
                    Text(Self.detail(host)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isHighlighted ? Color.accentColor.fill(0.18, contrast) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick() -> SSHHost? {
        let shown = matches
        return shown.first { $0.id == highlighted } ?? shown.first
    }

    private func move(_ delta: Int) {
        let shown = matches
        guard !shown.isEmpty else { return }
        let current = shown.firstIndex { $0.id == (highlighted ?? shown.first?.id) } ?? 0
        highlighted = shown[min(max(current + delta, 0), shown.count - 1)].id
    }
}
