# To do

Features that are wanted but not started. Nothing here is promised for a release.

## Automatic backups that run while the app is closed

Today automatic backups only run while the app is open: `startAutoBackupSchedule()` (`CerberusSSH/Backup/AutoBackup.swift`) checks every quarter of an hour, and if the folder is missing (a network share or external drive not connected) the backup fails and is retried later. Make it a launch agent that `launchd` runs whether the app is open or not, and when the folder is not there, keep the backup in Application Support and move it across once the folder comes back.

Decided: the agent runs the app's own executable in a headless mode, not a separate helper. The vault data key and the backup passphrase are device-only items in the legacy login keychain (`DataKeyStore.swift`, `ExportPassphraseStore.swift` in the kit), trusted by the signature of the program that made them; a separate helper would get a Keychain prompt on every run, and only the Sync build has an access group to share. The same executable has the same signature, so no prompt and no new target.

The agent:

- [ ] `Contents/Library/LaunchAgents/com.cerberusssh.backup.plist` in the bundle, with `BundleProgram` `Contents/MacOS/CerberusSSH` and argument `--background-backup`, `StartInterval` (900 seconds) and `StartOnMount` (so it runs when a share or drive comes back).
- [ ] Register it with `SMAppService.agent(plistName:)` when automatic backups are turned on, unregister when they are turned off. Handle `requiresApproval` (it shows in System Settings ▸ General ▸ Login Items & Extensions) and say so in Settings ▸ Backup, with a button to open that pane.
- [ ] A custom `main()` that checks for `--background-backup` before SwiftUI starts and runs one backup with no window, Dock icon or `NSApplication`, then exits.
- [ ] Read the settings from the app's defaults domain by suite name (bundle id), since `launchd` does not start it as the app.
- [ ] Remove the in-app 15-minute loop; "Back Up Now" stays in the app.

Sharing the store with the open app:

- [ ] A read-only way to open the catalogue in the kit (next to `localContainer`): no migration, no `adoptLegacyStore`, no `StoreBackups` copies or pending restore. If the stored version is not exactly the current one, skip the run and record why.
- [ ] The background run writes nothing to the store. `appSettings.lastExportAt` is taken from `autoBackupLastAt` the next time the app opens.
- [ ] A lock file (`flock`) in Application Support so the app's "Back Up Now" and the agent never write a backup at the same time.

When the folder is not there:

- [ ] Write the backup to `~/Library/Application Support/CerberusSSH/PendingBackups/` and count it as taken, so the schedule moves on.
- [ ] Keep only the newest pending one (each backup is a whole snapshot).
- [ ] On every run, if the folder is back: copy the pending one across, check it (size, and that it opens), remove the local copy, then remove the oldest in the folder beyond the number to keep.
- [ ] Settings ▸ Backup shows "1 backup waiting for the folder" rather than the error, with the folder it is waiting for.
- [ ] Cloud folders (`~/Library/CloudStorage`, iCloud Drive) are nearly always present and upload on their own, so this mostly matters for shares and drives; nothing special for them.

Checks:

- [ ] `Scripts/check-no-local-exec.sh` still passes (a `launchd` agent is not the terminal running a local process, but run it).
- [ ] `AutoBackupTests` drive the in-app schedule today; give UI tests a way to trigger the headless run (or keep an in-app trigger for tests only).
- [ ] Unit tests for the pending-backup move and retention, including the folder coming back mid-move.
- [ ] README and release notes: the background item, where pending backups are kept, and that they include secrets sealed with the backup passphrase.
- [ ] Needs a commit in each repository (read-only store opener in the kit); note the pairing.

## Build the Settings window on an AppKit split view

The Settings sidebar must not collapse, and `NavigationSplitView` does not allow that. Today `SettingsView` (`CerberusSSH/Settings/SettingsView.swift`) reaches into SwiftUI's split view with SwiftUIIntrospect, sets `canCollapse` off, and watches it with key-value observing because SwiftUI turns it back on whenever the category changes (`ebd48c7`). That is a library fighting another library's internals, it only covers macOS 26 and 27, and it is the only use of SwiftUIIntrospect. Do it the way System Settings appears to: own the split view in AppKit and host the SwiftUI parts inside it.

- [ ] An `NSSplitViewController` for the Settings window, with the sidebar as `NSSplitViewItem(sidebarWithViewController:)` (the real full-height glass sidebar), `canCollapse` and `canCollapseFromWindowResize` off, and a fixed width. AppKit owns it, so nothing turns collapsing back on.
- [ ] The category list and the panes stay SwiftUI, hosted with `NSHostingController`; selection still goes through `app.settingsTab`.
- [ ] Keep opening Settings on a given category (⌘, and the places that set `app.settingsTab`) working, and keep the window's size (880 × 600).
- [ ] Back and forward toolbar buttons driven by a history of the categories shown (and, with search, the setting jumped to).
- [ ] Room for the search field at the top of the sidebar (see Search in Settings below), so the two can be built together.
- [ ] Remove `SidebarLock`, `findSplitView`, `lockSidebar`, the `.introspect` call and the `onChange` workaround, then the SwiftUIIntrospect package.
- [ ] The UI tests that caught the collapse bug still pass, and the `settings-tab-*` identifiers still work.

## Search in Settings

Add `.searchable` to `SettingsView` (`CerberusSSH/Settings/SettingsView.swift`) so people can find a setting without knowing which category it is in, as in System Settings.

- [ ] A search field in the Settings window's sidebar; while there is text, the sidebar lists the matching settings (and the categories they are in) instead of only the categories.
- [ ] An index of what can be found: each setting's label, the category (`SettingsTab`) it is in, and extra words people might search for (for example "font" for the terminal font, "passphrase" for backups). Kept next to the panes in `CerberusSSH/Settings/SettingsPanes/` so a new setting is not left out.
- [ ] Choosing a result opens its category, scrolls to the setting and highlights it briefly.
- [ ] No results: say so, and keep the categories reachable.
- [ ] ⌘F focuses the field. The sidebar's host filter avoids `.searchable` because ⌘F would clash with Find in the terminal (`SidebarTabs.swift`); Settings is its own window, so check that the clash does not happen there.
- [ ] VoiceOver label and an accessibility identifier for the field, and a UI test.

## Upgrade the port forwarding UI

The windows and sheets for port forwarding, and how forwards are presented, need a design pass. Scope not decided yet.

- Where it lives now: `CerberusSSH/Forwards/ForwardViews.swift`, `CerberusSSH/Forwards/SidebarForwards.swift`, the forwards part of `CerberusSSH/Hosts/HostEditorView.swift`, and the model in `CerberusSSH/App/AppModel/AppModel+Forwards.swift`.
- [ ] Review the current sheets and sidebar list, and decide what to change.
- [ ] Redesign the add / edit sheets.
- [ ] Improve how forwards and their state are shown (sidebar, host inspector, session status bar).

## Import hosts from iTerm2 profiles

Today the only thing brought in from iTerm2 is a colour preset (`.itermcolors`, via `ITermColors.theme(from:name:)` in the kit, from Settings ▸ Appearance ▸ Your themes ▸ Import from iTerm2…). Hosts come only from `~/.ssh/config` (`SSHConfigImporter`).

Where iTerm2 keeps profiles:

- `~/Library/Preferences/com.googlecode.iterm2.plist` (or the custom folder set under "Load preferences from a custom folder"): profiles under `New Bookmarks`, colour presets under `Custom Color Presets`.
- `~/Library/Application Support/iTerm2/DynamicProfiles/`: JSON with the same profile keys. The easiest place to start.

What to do:

- [ ] Read profiles from both places and offer the ones whose command is `ssh …` as hosts. iTerm2 has no host field, so parse the command (user, host, `-p`, `-i`, `-J`, `-o` options) and skip the ones that cannot be read.
- [ ] Carry over the profile's name and tags (as a group?).
- [ ] Bring the profile's colours in as a custom theme and set it on the host.
- [ ] Maybe: font and size, cursor style, scrollback.
- [ ] Import the presets saved in iTerm2 itself (`Custom Color Presets`), not only exported `.itermcolors` files.

Gaps in today's `.itermcolors` import, to fix while here:

- [x] The `(Dark)` / `(Light)` variants newer iTerm2 writes are ignored; only the plain keys are read. (A preset with separate colours now imports as two themes.)
- [x] "Calibrated" colours are read as sRGB, so they come out slightly off. (Calibrated and P3 are now converted to sRGB.)
- [ ] Bold, cursor text and link colours are dropped.

## Import hosts from other apps

People moving from another client should be able to bring their hosts. Paths and formats below are from memory and need checking against a real install before building each one. Passwords that the other app encrypts with its own scheme are not imported; the host comes in without one.

### Tabby

- `~/Library/Application Support/tabby/config.yaml` (YAML).
- [ ] Profiles with `type: ssh`: host, port, user, key paths, jump host, group, colour scheme.
- Passwords are in the Keychain or Tabby's encrypted vault: skip them.

### SecureCRT

- `~/Library/Application Support/VanDyke/SecureCRT/Config/Sessions/**/*.ini`, one file per session; folders are groups.
- [ ] Hostname, port, username, key file, port forwards, colours.
- Passwords are encrypted with SecureCRT's own scheme: skip them.

### Royal TSX

- Documents are `.rtsx` (XML, can be encrypted with a document password); the app can also export to CSV.
- [ ] Start with the CSV export; read `.rtsx` directly later if it is worth it.
- [ ] Folders as groups, SSH connections as hosts, credentials only where they are not encrypted.

### FileZilla

- `~/.config/filezilla/sitemanager.xml` (XML).
- [ ] SFTP sites as hosts (skip plain FTP), folders as groups, user, port, key file.
- Passwords are only base64-encoded, so they can be read: bring them into the vault, and say so in the import sheet.

### Cyberduck / Mountain Duck

- One `.duck` bookmark per host (property list), in Cyberduck's application support folder.
- [ ] SFTP bookmarks as hosts: host, port, user, key file, default remote folder.
- Passwords are in the Keychain under Cyberduck's entries: skip them.

### Shared

- [ ] One step that parses an `ssh …` command line into a host (user, host, `-p`, `-i`, `-J`, `-o`), used by the iTerm2 profile import above (and Shuttle, if it is ever added).
- [ ] One import sheet for all of these, like `ImportSSHConfigSheet`: pick the source, preview the hosts, choose which to bring in, and report what was skipped and why.

## Saved workspaces

A saved set of hosts that opens together with a double-click: as one tab of panes or as a tab each, in the current window or a new one. Listed in a sidebar tab of its own, and made either from scratch or from a tab that is already open.

The name is Workspace for the user. In the code it needs a name of its own (`SavedWorkspace`), because "workspace" there already means the main window and its tabs (`WorkspaceTab`, `CerberusSSH/Workspace/`, "workspace windows").

Where things are now: the sidebar tabs are `SidebarTab` (`CerberusSSH/Workspace/SidebarTabs.swift`); hosts are opened by `AppModel.connect(to:placement:)` with a `SessionPlacement` (`.newTab`, `.splitRight`…, `.newWindow`); a tab's arrangement is its `PaneLayout`; the tab's context menu is in `CerberusSSH/Workspace/TabBar.swift`; snippets are the `Snippet` model.

The model:

- [ ] A `SavedWorkspace` SwiftData model in the kit: name, an ordered list of hosts (by host id, so renaming or moving a host keeps it), how it opens, and the options below. CloudKit-safe (everything optional or defaulted), with the schema version bumped and `SchemaFreezeTests` updated, as `SchemaFreeze.swift` says.
- [ ] How it opens, one choice that is the double-click default: Current Window + Tabs, Current Window + Panes, New Window + Tabs, New Window + Panes.
- [ ] When a host is already connected: open a new session (the default) or reuse the session that is open. A setting on each workspace.
- [ ] A host that has since been deleted is skipped when opening, and shown as missing in the editor.
- [ ] Include workspaces in backups and restore (`CerberusVault/Backup`).

The sidebar tab:

- [ ] A Workspaces tab in `SidebarTab`, listing them by name with their host count (and the group colours of their hosts, as a tab shows them).
- [ ] Double-click opens it the workspace's own way. Return does the same, as for hosts.
- [ ] Context menu: Open, then Open As ▸ each of the other three ways, for this time only (the workspace's setting is unchanged); Edit…, Duplicate, Rename, Delete (asks first).
- [ ] A + button and an empty state that says how to make one (from the button, or from a tab's context menu).

Making and editing one:

- [ ] An editor sheet: name, the hosts (add from a host picker, remove, drag to reorder), how it opens, and what to do with hosts that are already connected.
- [ ] Tab context menu: Save as Workspace… opens the editor filled in from the tab: its hosts in pane order, Panes (or Tabs for a single-pane tab), and its split layout.
- [ ] Maybe: Save Window as Workspace…, from every terminal tab in the window, opened as Tabs.

Extras:

- [ ] Keep the split layout: saved from a tab, a workspace keeps how its panes are split (sides and divider positions, the tab's `PaneLayout` with host ids in place of session ids), and opening it as Panes rebuilds that layout. Without one (or after hosts were added or removed in the editor), Panes splits evenly.
- [ ] Command on open: each host in a workspace can have a command or a snippet that is sent once it has connected (e.g. `cd` to a folder, `tail -f` a log). Sent once, after the shell is ready, never on a reconnect.
- [ ] Broadcast on open: a workspace opened as Panes can start with broadcast on, every pane ticked.
- [ ] Open from Quick Connect: workspaces show in Quick Connect (⌘K) beside hosts, and in a menu (Session ▸ Open Workspace ▸ …), and a workspace can have its own keyboard shortcut.

Checks:

- [ ] Unit tests in the kit for the model (an ordered host list, deleted hosts skipped, the saved layout mapped back from host ids to new sessions) and the schema snapshot.
- [ ] UI tests: open each of the four ways, Open As from the context menu, Save as Workspace from a split tab and reopen it with the same layout, a command on open running in the right pane.
- [ ] Help: a section on workspaces; the shortcut catalogue if they get shortcuts.

## Replace SwiftTerm with libghostty for the terminal

Render the terminal with libghostty, the terminal engine behind the Ghostty terminal, in place of SwiftTerm. Nothing has been looked into yet: start with a spike that answers the questions below, and only then decide whether to swap.

Where things are now: SwiftTerm is pinned exactly in the kit (`Package.swift`, 1.99.0) and used only in `CerberusTerminal` (`TerminalSessionView.swift`, `TerminalAppearance.swift`, `TerminalContextMenu.swift`, `LogReplayView.swift`, `TerminalUITestSupport.swift`). Bytes come from the SSH channel through `TerminalTransport` (`CerberusSSHCore/TerminalTransport.swift`), so a swap stays inside `CerberusTerminal`.

Find out first:

- [ ] What libghostty offers today: its API, licence, how stable it is, and how it is built (Zig) and linked into a Swift package and a signed, notarised app.
- [ ] That it can be fed bytes from our own SSH channel and send keystrokes back, with no local process or pty. The app must never start a local process (`Scripts/check-no-local-exec.sh`).
- [ ] What it would give: speed, rendering quality (Metal), correctness of escape sequences, ligatures (SwiftTerm cannot join them), and accessibility (VoiceOver reading the screen).
- [ ] What it would cost: build complexity, app size, and release risk.

The spike:

- [ ] A live session rendered by libghostty next to SwiftTerm, behind a debug switch, to compare by eye and with `Scripts/perf-gate.sh`.

What would have to be rebuilt on it, if the answer is yes:

- [ ] Themes (`TerminalAppearance`, including following the app's light or dark), font, size and cursor style.
- [ ] Selection, copy (and copy on select), the paste confirmation for multi-line text and control characters, and OSC 52 clipboard writes (off by default).
- [ ] Scrollback, Find in the terminal, ⌘-click links, and the context menu.
- [ ] Broadcast input to several panes, split panes, and moving a pane to another tab or window with its screen.
- [ ] Session recordings and log replay (`LogReplayView`).
- [ ] The UI tests' hooks into the terminal (`TerminalUITestSupport`).
- [ ] `THIRD_PARTY_NOTICES.md` and the README: remove SwiftTerm, add libghostty and anything it brings in.

Not decided: whether to replace SwiftTerm at all depends on what the spike finds.
