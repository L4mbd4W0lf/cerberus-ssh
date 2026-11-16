import SwiftUI
import AppKit
import CerberusModels

/// Shown in the detail area while nothing is open: a few quick actions and the hosts
/// used most recently.
struct WelcomeView: View {
    let hosts: [SSHHost]
    let onNewHost: () -> Void
    let onConnect: (SSHHost) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    private var recents: [SSHHost] {
        hosts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recents.isEmpty ? "Welcome to CerberusSSH" : "Welcome back")
                        .font(.title2.weight(.medium))
                    Text("Secure shells, kept close")
                        .font(.subheadline).italic().foregroundStyle(.secondary)
                }
            }

            section("Get started") {
                row("plus", "New Host…", shortcut: nil, action: onNewHost)
                row("magnifyingglass", "Quick Connect…", shortcut: "⌘K") { app.quickConnectRequests += 1 }
                row("gearshape", "Settings…", shortcut: "⌘,") { openSettings() }
            }

            section("Manage") {
                row("person.badge.key", "Identities", shortcut: nil) { showSettings(.identities) }
                row("key", "Keys", shortcut: nil) { showSettings(.keys) }
                row("externaldrive", "Backups", shortcut: nil) { showSettings(.backup) }
                row("text.badge.plus", "Snippets", shortcut: nil) { showSettings(.snippets) }
            }

            if !recents.isEmpty {
                section("Recent hosts") {
                    ForEach(recents) { host in
                        row("server.rack", host.displayLabel, shortcut: nil, host: host) { onConnect(host) }
                    }
                }
            }
        }
        .frame(width: 380, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens Settings on one of its tabs.
    private func showSettings(_ tab: SettingsTab) {
        app.settingsTab = tab
        openSettings()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }
            .padding(.bottom, 4)
            content()
        }
    }

    private func row(_ symbol: String, _ title: String, shortcut: String?, host: SSHHost? = nil, action: @escaping () -> Void) -> some View {
        WelcomeRow(symbol: symbol, title: title, shortcut: shortcut, host: host, action: action)
    }
}

private struct WelcomeRow: View {
    let symbol: String
    let title: String
    let shortcut: String?
    /// For a host's row: its system's logo takes the place of the symbol.
    var host: SSHHost?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let host {
                    HostOSIcon(os: host.detectedOS).frame(width: 18, height: 16)
                } else {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                }
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.callout).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}
