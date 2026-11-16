import CerberusModels
import SwiftUI

/// The Help window: how to get started, every keyboard shortcut, and the things that are
/// easy to miss. Opened from Help ▸ CerberusSSH Help (⌘?).
enum HelpPage: String, CaseIterable, Identifiable {
    case start = "Getting Started"
    case shortcuts = "Keyboard Shortcuts"
    case files = "Files (SFTP)"
    case forwarding = "Port Forwarding"
    case tips = "Tips"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .start: "flag"
        case .shortcuts: "command"
        case .files: "folder"
        case .forwarding: "arrow.left.arrow.right"
        case .tips: "lightbulb"
        }
    }
}

struct HelpView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            // The topics, down the left like a manual's contents.
            List(
                HelpPage.allCases,
                selection: Binding(
                    get: { app.helpPage },
                    set: { if let page = $0 { app.helpPage = page } }
                )
            ) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            // The topics are always shown, so there is no need to hide them.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch app.helpPage {
                case .start: GettingStarted()
                case .shortcuts: Shortcuts(search: $search)
                case .files: FilesHelp()
                case .forwarding: PortForwardingHelp()
                case .tips: Tips()
                }
            }
            .navigationTitle(app.helpPage.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Shortcuts

private struct Shortcuts: View {
    @Binding var search: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts", text: $search).textFieldStyle(
                    .plain
                )
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(8)
            .background(
                .quaternary.opacity(0.6),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding([.horizontal, .top], 12)

            let sections = ShortcutCatalog.filtered(search)
            if sections.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(
                                    section.title,
                                    systemImage: section.systemImage
                                )
                                .font(.headline)
                                ForEach(section.shortcuts) { shortcut in
                                    HStack(
                                        alignment: .firstTextBaseline,
                                        spacing: 12
                                    ) {
                                        KeyCaps(shortcut.keys).frame(
                                            width: 120,
                                            alignment: .leading
                                        )
                                        Text(shortcut.title)
                                        Spacer(minLength: 8)
                                        if let menu = shortcut.menu {
                                            Text(menu).font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        Text(
                            "Shortcuts for the other commands are shown next to them in the menu bar."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Keys drawn as little key caps.
private struct KeyCaps: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

// MARK: - Getting started

private struct GettingStarted: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                step(
                    1,
                    "plus",
                    "Add a host",
                    "Choose the Hosts tab and click + in its bottom bar (or right-click empty sidebar space) and choose New Host. Give it an address and a name. In the Hosts tab, right-click a folder and choose New Host to start inside it. ⌘N does the same from anywhere in the app: it makes a host in the selected folder, or at the top level when none is selected, and ⇧⌘N makes a folder the same way."
                )
                step(
                    2,
                    "person.badge.key",
                    "Choose how to sign in",
                    "A host signs in with an identity: a username with a password or a key. Several hosts can share one identity, so you change a password once. Keep keys in the vault under Settings ▸ Keys, import one or generate a new one, and choose it in the identity."
                )
                step(
                    3,
                    "bolt.fill",
                    "Connect",
                    "Double-click a host, select it and press Return or ⌘S, or press ⌘K and start typing a name. Each connection opens in a tab of its own, even when the host is already open. The first time, you are asked to trust the server's host key. Check the fingerprint, then trust it."
                )
                step(
                    4,
                    "rectangle.split.2x1",
                    "Work in tabs and panes",
                    "⌘T opens another tab, ⌘D splits the pane to the right. ⌥⌘ and an arrow key moves between panes, and ⌥⌘T takes a pane out into a tab of its own. Right-click a pane for splits on every side, broadcast, copy and paste, and the logs. Drag a tab onto another tab's terminal to bring two sessions side by side, or out of the window to give it a window of its own. A middle-click closes a tab."
                )
                step(
                    5,
                    "folder",
                    "Move files",
                    "Right-click a host and choose SFTP (⇧⌘S with the host selected). A tab opens with two panes: This Mac on the left and the host on the right. Drag files between them, or copy in one pane (⌘C) and paste in the other (⌘V). Select two hosts and choose SFTP 2 to copy from one server to the other. See the Files page."
                )
                step(
                    6,
                    "arrow.left.arrow.right",
                    "Tunnel without a terminal",
                    "Add port forwards in a host's settings. The ones that are switched on are listed in the sidebar's Port Forwards tab: double-click one to start it with no terminal at all, and it shows as Active, also when it is already running in a terminal you have open."
                )
                step(
                    7,
                    "externaldrive",
                    "Keep a backup",
                    "Your logins are kept sealed in a vault file on this Mac, opened with a key in the Keychain. Choose Vault ▸ Export Vault Backup now and then; the file is sealed with a passphrase you choose and restores on any Mac."
                )

                Divider()
                Text("Where things are").font(.headline)
                menuRow("File", "New host and folder, quick connect (the toolbar's search field), new tab, close pane")
                menuRow(
                    "Host",
                    "What the sidebar does with the selected host or folder: connect, SFTP, edit, duplicate, favourites, new host, delete"
                )
                menuRow(
                    "View",
                    "Show or hide the sidebar and inspector; choose Hosts, Port Forwards or Favourites in the sidebar"
                )
                menuRow(
                    "Tab",
                    "Switch tabs, rename a tab, move a tab to its own window"
                )
                menuRow(
                    "Files",
                    "In a file tab: new folder, rename, delete, permissions, refresh, copy to the other pane"
                )
                menuRow(
                    "Vault",
                    "Backups, import known_hosts, identities and known hosts"
                )
                menuRow(
                    "Terminal",
                    "Text size, theme, cursor, clipboard safety"
                )
                menuRow(
                    "Session",
                    "Splits, pane selection, move a pane to a tab, SFTP, broadcast, snippets, port forwards (⌥⌘P), replay and recordings"
                )
                menuRow(
                    "Debug",
                    "How much of the connection log to show, and the log itself"
                )
                menuRow(
                    "Help (⌘?)",
                    "This window: getting started, shortcuts, port forwarding and tips"
                )
                menuRow(
                    "Settings (⌘,)",
                    "Identities, keys, appearance, behaviour, snippets, session recordings and more"
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(
        _ number: Int,
        _ symbol: String,
        _ title: String,
        _ text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)").font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
    }

    private func menuRow(_ menu: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(menu).fontWeight(.medium).frame(
                width: 110,
                alignment: .leading
            )
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tips

private struct Tips: View {
    private let tips: [(symbol: String, title: String, text: String)] = [
        (
            "magnifyingglass", "Search with tags",
            "Type in the filter field at the bottom of the Hosts tab. Words match names, addresses, users, folders and notes. A word starting with # is a tag: #prod #eu narrows to hosts with both, and it narrows as you type. The filter text is kept when you leave Hosts and return; Favourites and Port Forwards have no filter and always show all their rows."
        ),
        (
            "star", "Favourites",
            "Right-click a host and choose Add to Favourites, or use the star in its inspector. The Favourites tab lists your marked hosts; choose Remove from Favourites to unmark one. New windows always open on the Hosts tab. Each sidebar tab remembers its own selection. Creating or duplicating while another tab is showing switches to Hosts and clears the filter so the new items can be seen."
        ),
        (
            "arrow.triangle.branch", "Jump hosts",
            "In a host's settings, add hosts to go through. Each one signs in with its own identity, and a code from your authenticator is asked for when a server wants one."
        ),
        (
            "dot.radiowaves.left.and.right",
            "Type into several servers at once",
            "Drag a tab onto another tab's terminal, then press ⇧⌘B. Whatever you type goes to every pane with a tick. Untick the ones to leave out; an orange outline shows who is listening."
        ),
        (
            "text.badge.plus", "Snippets",
            "Save commands you repeat in Settings ▸ Snippets. Write {{name}} for a blank to fill in, or {{name:default}}. Press ⇧⌘K to insert one; Choose panes… in the palette sends it to panes you pick instead of the focused one."
        ),
        (
            "arrow.left.arrow.right", "Port forwarding",
            "A forward is a tunnel. Local (-L) opens a port on this Mac that leads through the server; remote (-R) makes the server open a port that leads back here; dynamic (-D) is a SOCKS proxy. Add them in a host's settings or in Session ▸ Show Port Forwards (⌥⌘P), where each has a switch: turn one off to keep it without using it. Start and stop them from the forwards button in the status bar."
        ),
        (
            "record.circle", "Record a session",
            "While connected, press Record Session in the toolbar, next to Connection Log. Recording starts from that moment and the button turns red; press it again (or disconnect) to stop. Only what the server prints is recorded. Recordings are encrypted and stay on this Mac. Session ▸ Show Recordings (⌥⇧⌘L), or Recordings in a pane's right-click menu, opens the list; double-click one to replay it in a window of its own, which you can move and resize (the text wraps to fit). Show Replay Log (⌥⌘L) opens this host's latest recording. Search a recording with the field above the replay (⌘F, then ⌘G for the next match), and export it as text or asciinema. How long recordings are kept is in Settings ▸ Recordings."
        ),
        (
            "sidebar.left", "Keys in the sidebar",
            "With the sidebar list active and a host selected: ⌘S connects (each host in a new tab), ⇧⌘S opens SFTP, ⌘E edits, ⇧⌘D duplicates, ⌘⌫ deletes. With a folder selected: ⌘E renames it. In a terminal these keys keep their usual jobs."
        ),
        (
            "rectangle.portrait.on.rectangle.portrait", "Pane back to a tab",
            "With a tab split into panes, ⌥⌘T (or the button at the top right, or Session ▸ Move Pane to New Tab) gives the focused pane a tab of its own. The connection and everything on its screen come with it, and so they do when you drag a tab out to a window or onto another tab."
        ),
        (
            "stethoscope", "When a host will not connect",
            "Right-click a host that has no open tab and choose Show Last Connection Log to read how its last connection went. For a host reached through jump hosts, Edit it and press Test Chain: it connects through the chain as saved and says which hop failed and why."
        ),
        (
            "arrow.clockwise.circle", "Tabs come back",
            "When CerberusSSH starts it reopens the tabs and windows that were open when you quit, where they were: the same hosts, splits, tab names and file tabs (in the folders they were in), each connecting again. Closing a tab yourself takes it out. Settings ▸ Behaviour turns this off, and turns off the question that is asked before a tab, a window or the app is closed while connections are live."
        ),
        (
            "xmark.circle", "Close a tab with the middle button",
            "A middle-click on a tab closes it. In a file tab ⌘W closes the tab too."
        ),
        (
            "circle.lefthalf.filled", "Follow the system's light and dark",
            "Settings ▸ Appearance can make the terminal follow macOS: Cerberus and Solarized switch between their dark and light versions, and Nord and Dracula stay as they are. A host's own theme follows it the same way."
        ),
        (
            "paintpalette", "Colour a folder",
            "Right-click a folder and choose Colour. Its hosts and subfolders show the colour as a mark in the sidebar, the tab and the pane, so a production terminal can't be taken for a test one."
        ),
        (
            "pencil", "Rename a tab",
            "Double-click its title. Press Return to keep the name, Escape to cancel, or clear it to go back to the automatic one."
        ),
        (
            "doc.on.clipboard", "Safer pasting",
            "Pasting several lines asks first, because each line would run at once. Programs on the server can't change your clipboard unless you allow it in the Terminal menu."
        ),
        (
            "plus.square.on.square", "Duplicate a host",
            "Right-click a host (or press ⇧⌘D with it selected) and choose Duplicate to make a copy with its settings, named \"web copy\". It shares the original's identity, so changing the login changes both."
        ),
        (
            "key", "Keys in the vault",
            "Settings ▸ Keys keeps SSH keys under names you choose. Import one from a file or paste its text, or generate a new one (Ed25519, ECDSA or RSA). An identity can then sign in with it, and several identities can share one key. Keys are in your backups."
        ),
        (
            "arrow.uturn.backward.circle", "Backups before an update changes your data",
            "When CerberusSSH opens a catalogue written by an older version, it first copies the file to a Migration Backups folder beside it, named after the version it came from (for example CerberusSSH-v1.3.0-20261115-203000.store). Settings ▸ Advanced ▸ Migration backups lists them. Re-migrate puts a copy back as the catalogue and migrates it again the next time CerberusSSH starts, after saving what you have now as a backup of its own; Delete removes one. A copy holds what the catalogue holds (saved passwords and keys sealed), so Erase All Data deletes them too. If a copy cannot be made, CerberusSSH still opens."
        ),
        (
            "clock.arrow.2.circlepath", "Automatic backups",
            "After your first backup, Settings ▸ Backup can keep making them for you into a folder you choose, daily, weekly or monthly, and remove the oldest ones. The passphrase is kept in this Mac's Keychain so it can run without you; keep a copy of it somewhere else, because you need it to restore, and a Keychain on a lost Mac won't help."
        ),
        (
            "touchid", "When Touch ID is asked for",
            "By default Touch ID (or your password) is asked for before a saved password is shown, a saved password or key is replaced, the vault is exported, or a trusted host key is forgotten. Settings ▸ Behaviour ▸ Security can make it also ask before every connection that signs in with a saved secret, or never."
        ),
        (
            "doc.text", "Import your ssh config",
            "In the Vault menu or in Settings ▸ Backup, Import Hosts from ssh config reads ~/.ssh/config once and turns each Host into a host here, with its user, port, key, jump hosts and port forwards. Wildcard blocks (Host *) fill in defaults. Hosts you already have are left alone, so it is safe to run again. The file itself is never changed."
        ),
        (
            "square.and.arrow.down.on.square", "Bring in your ~/.ssh",
            "On a fresh install CerberusSSH offers to copy your keys and known_hosts from ~/.ssh. You can do it any time from the Vault menu or Settings ▸ Backup. Your ~/.ssh folder is only read, never changed, and keys are sealed in the vault."
        ),
        (
            "clock.arrow.circlepath", "Older servers",
            "A server from before about 2014 may offer only RSA keys, AES-CTR or CBC ciphers and Diffie-Hellman key exchange. All of those are supported, tried after the modern ones, so you should not need to change anything. If one still cannot be reached, the connection log names what is missing."
        ),
        (
            "checkmark.shield", "Is this server trusted?",
            "The inspector (⌥⌘I) shows whether the selected host's key is already in your known hosts, and for a host reached through jump hosts, each hop's too. Settings ▸ Known Hosts lists them."
        ),
        (
            "macwindow.on.rectangle", "Windows for tabs",
            "Drag a tab out of the window to open it in a window of its own, with just the terminal and its splits. Drag it back onto a tab bar, or onto another terminal, to join it again."
        ),
        (
            "arrow.up.arrow.down", "Order and memory",
            "The sidebar sorts by name, folders first, unless you choose otherwise with the ↑↓ button in its filter, Host ▸ Sort Hosts By, or Settings ▸ Behaviour: by name from Z to A, by most recent or most frequent connection, by address, or Custom Order. In Custom Order folders and hosts share one list, and you drag a row to rearrange it: onto the top or bottom of another row to put it beside that row, onto the middle of a folder to put it inside (a closed folder opens if you wait over it), or onto the empty space below the list to move it to the top level. Select several rows first, and dragging one of them takes them all. Dragging is off in the other orders, and while a filter is in use. The sidebar remembers which folders were closed, and in Settings ▸ Behaviour you can have a double-click close a folder's subfolders as well."
        ),
        (
            "lifepreserver", "When a connection fails",
            "Show the connection log from the Debug menu (⇧⌘L), and raise the detail there to see what was tried, like ssh -v. Passwords and keys are never written to it. While running from Xcode, the same lines and every error also appear in its console, marked [CerberusSSH]."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(tips, id: \.title) { tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.symbol)
                            .frame(width: 24)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tip.title).font(.headline)
                            Text(tip.text).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Files (SFTP)

private struct FilesHelp: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "A file tab shows two folders side by side and copies files between them. It has a connection of its own, so it does not touch your terminals."
                )
                .fixedSize(horizontal: false, vertical: true)

                section(
                    "Opening one",
                    "Right-click a host and choose SFTP, press ⇧⌘S with the host selected in the sidebar, or use Session ▸ SFTP for the host of the terminal you are in. One host puts This Mac on the left and the host on the right. Select two hosts and choose SFTP 2 to copy from one server to the other through this Mac (on the same server, the server does the copy itself when it can). The button at the top of a pane changes what it shows."
                )
                section(
                    "Focus",
                    "One pane is focused, outlined in the accent colour. Click a pane, or press ⌥⌘← and ⌥⌘→ (or ⌘[ and ⌘]), to change it. The keys below act on the focused pane."
                )
                section(
                    "Copying",
                    "Drag files from one pane to the other, or onto a folder. Or select files and press ⌘C, move to the other pane and press ⌘V. In the pane the files came from, ⌘V makes a copy named “… (copy)”. ⌃⌘→ and ⌃⌘← copy the selection to the other pane at once. Dragging to and from Finder works too; ⌘C and ⌘V are between the panes only."
                )
                section(
                    "Moving around",
                    "Return or ⌘↓ opens the selected folder, ⌘↑ goes up a folder. ⇧⌘N makes a folder, ⌥⌘R renames, ⌘⌫ deletes (it asks first), ⌘I changes permissions and ⌘R refreshes. The right-click menu shows these keys."
                )
                section(
                    "Name clashes",
                    "When a name is already taken you are asked what to do: replace, skip or keep both, for this file or for all of them. A copy that stopped part way can be resumed."
                )
                section(
                    "Transfers",
                    "The status bar under the panes shows each connection and, on the right, the transfers: a ring for how far they are, and a list that rises when you point at it or click it, with the speed and the time left. Folders copy with everything in them. Copies never delete the original."
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(
                horizontal: false,
                vertical: true
            )
        }
    }
}

// MARK: - Port forwarding

private struct PortForwardingHelp: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "A port forward is a tunnel. It makes one port on one computer lead to a port on another, through the encrypted SSH connection, so you can reach something the network would not otherwise let you reach, or share something of yours."
                )
                .fixedSize(horizontal: false, vertical: true)

                kind(
                    "arrow.right.circle",
                    "Local (-L): a port on this Mac leads through the server",
                    "Use it to reach something that only the server can see, such as a database. Listen on 127.0.0.1 port 5433 and go to db.internal port 5432: now a program on this Mac that connects to localhost:5433 is talking to db.internal:5432, from the server's side."
                )
                kind(
                    "arrow.left.circle",
                    "Remote (-R): a port on the server leads back to this Mac",
                    "Use it to show something of yours to the server's side, such as a web page you are working on. Make the server listen on port 8080 and connect back to localhost port 3000: anyone on the server who opens localhost:8080 is shown your localhost:3000. Port 0 lets the server pick a free port and tell you which."
                )
                kind(
                    "network",
                    "Dynamic (-D): a SOCKS5 proxy on this Mac",
                    "Listen on 127.0.0.1 port 1080 and point a browser or tool at it as a SOCKS5 proxy. Everything it asks for is fetched by the server, so it can reach whatever the server can."
                )

                Divider()
                Text("The switches and boxes").font(.headline)
                term(
                    "On",
                    "The master switch. A forward that is off is kept, so you do not have to type it in again, but it is never started, and one that is running is stopped when you switch it off. Switch it on when you want it."
                )
                term(
                    "Name",
                    "Optional. A name such as \"Staging database\" is shown instead of the port numbers in the sidebar, the status bar and the Port Forwards window, so forwards are easy to tell apart. You can search for it in the sidebar."
                )
                term(
                    "Start automatically",
                    "Starts the forward by itself every time you connect to the host, and straight away when you switch it on while connected. With it off, the forward waits for you to press Start, in the status bar under the terminal or in the Port Forwards window. It does nothing for a forward that is switched off."
                )
                term(
                    "Listen on / Server listens on",
                    "Where the tunnel's door is. 127.0.0.1 means only programs on that same computer can use it, which is the safe choice. 0.0.0.0 opens it to the whole network, so anyone who can reach that computer can use your tunnel. For a remote forward the server only listens on something other than its own address if it has GatewayPorts set."
                )
                term(
                    "Go to / Connect to",
                    "Where the tunnel leads. For a local forward it is a host and port as the server sees them. For a remote forward it is a host and port as this Mac sees them (localhost works)."
                )

                Divider()
                Text("Where to manage them").font(.headline)
                Text(
                    "Add them in a host's settings, or in Session ▸ Show Port Forwards (⌥⌘P), which lists every forward of every host with its switch, whether it is running, and how much has gone through. The sidebar's Port Forwards tab lists the ones that are switched on: double-click one to start it, with no terminal at all (a connection is made just for it, and closed again when its last forward stops). A forward that is already running in a terminal session shows as Active. The status bar's forwards button starts and stops the ones for the session you are in."
                )
                .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text("When one will not start").font(.headline)
                Text(
                    "A port that is already in use, a server that does not allow forwarding (AllowTcpForwarding no), or a destination that is not there are reported in the status bar. Switching the forward off and on, or choosing another port, usually sorts it out."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kind(_ symbol: String, _ title: String, _ text: String)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
    }

    private func term(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(
                horizontal: false,
                vertical: true
            )
        }
    }
}
