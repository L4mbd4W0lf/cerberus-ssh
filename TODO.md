# To do

Features that are wanted but not started. Nothing here is promised for a release.

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

## Move file transfers to a toolbar button

Transfers are shown as a badge in the file tab's status bar (`transfersBadge` in `CerberusSSH/Files/FileTabStatusBar.swift`), with a mini spinner on the tab (`CerberusSSH/Workspace/TabBar.swift`). The badge is easy to miss, so it looks as if nothing is downloading, and the status bar is already cramped with what it shows.

- [ ] A toolbar button whose icon is a ring filling with the total progress of all transfers (reuse `RadialProgress`). Done state when everything has finished; hidden or idle when there have been no transfers.
- [ ] Clicking it opens a drop-down (popover) listing the files and folders being transferred, with their details: direction, size, progress, speed / time left, waiting / done / failed, and cancel (reuse `TransferPanel` and `TransferRow`).
- [ ] Take the transfers badge out of the status bar.
- [ ] Decide: the queue is per file tab (`tab.queue`), so should the button show the current tab's transfers or every tab's in the window?
- [ ] Keep the VoiceOver label and the `files-transfers-badge` / `files-transfers` identifiers working, or update the UI tests.

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

- [ ] The `(Dark)` / `(Light)` variants newer iTerm2 writes are ignored; only the plain keys are read.
- [ ] "Calibrated" colours are read as sRGB, so they come out slightly off.
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
