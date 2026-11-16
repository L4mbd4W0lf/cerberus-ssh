# Repository guide

These instructions apply to all contributors and coding agents working in this repository. They are tool- and vendor-neutral.

## Project

CerberusSSH is a native macOS SSH client written in Swift and SwiftUI. It stores hosts, credentials, keys, and session logs locally; secrets are encrypted using a key held in the macOS Keychain. Read `README.md` for product behavior and build instructions. The detailed product and security specification is private and kept outside this repository; consult it when available before making changes that affect behavior.

The app requires macOS 26 or later and the project currently targets Xcode 27 / Swift 6.

## Two repositories

This repository holds the interface only. The vault, SSH engine, data models and terminal live in a separate private repository, `cerberus-ssh-kit` (the `CerberusKit` Swift package), which also holds the build, test and release scripts. Clone them side by side, in any folder, and the project finds the package at `../cerberus-ssh-kit`:

```
git clone git@github.com:L4mbd4W0lf/cerberus-ssh.git
git clone git@github.com:L4mbd4W0lf/cerberus-ssh-kit.git
```

This repository is public. Keep anything private out of it: no kit source, no private specification or notes, no credentials, signing details beyond what the project already needs, or host data. A change may need a commit in each repository; note the pairing in the commit messages.

## Repository map

- `CerberusSSH/`: macOS app, organized by feature (hosts, sessions, files, credentials, settings, and workspace).
- `CerberusSSHUITests/`: app UI tests.
- The `CerberusKit` package (models, vault, SSH core, terminal, vendored `swift-nio-ssh`) is in `../cerberus-ssh-kit`. Read its `AGENTS.md` before changing it.

## Build and verification

- Build the app: `xcodebuild -project CerberusSSH.xcodeproj -scheme CerberusSSH -configuration Debug build`
- Run the other checks from `../cerberus-ssh-kit`: `swift test` for the package, `Scripts/uitest.sh quick` (also `offline`, `live`, `full`) for the UI tests, `Scripts/check-no-local-exec.sh` for the SSH-only invariant, and `Scripts/perf-gate.sh` (`--seconds 100` for a shorter run).

Choose the narrowest relevant verification for a change, and report what was run and any limitations. UI tests and the performance gate can be slow and may require a suitable macOS/Xcode environment.

## Product and security constraints

- The terminal must always use an SSH channel. Do not add local shell or process execution; `Scripts/check-no-local-exec.sh` (in the kit repository) enforces this invariant.
- Do not add telemetry, accounts, cloud sync, or remote storage. User data is intended to remain on the Mac, except for explicit SSH connections and user-directed backups.
- Protect passwords, private keys, vault data, and session logs. Avoid logging secrets or exposing them in errors, diagnostics, previews, fixtures, or tests. Follow the existing Keychain, encryption, and secret-wiping patterns.
- Preserve strict host-key verification behavior: a changed host key must block a connection. Do not weaken cryptographic defaults or silently downgrade algorithms; compatibility changes must follow the specification and existing negotiation behavior.
- SSH agent forwarding is intentionally not supported. Do not add it.
- Keep changes focused and consistent with the specification. Update relevant documentation or release notes when user-visible behavior or security properties change.
- The SSH dependency (in the kit repository) is locally modified. Preserve its documented patches and licensing notices, and keep the summary of the changes in `THIRD_PARTY_NOTICES.md` accurate.

## Working practices

- Inspect the relevant implementation, tests, and specification before changing behavior. Prefer extending existing abstractions over introducing parallel mechanisms.
- Keep Swift 6 concurrency and sendability requirements intact. Avoid blocking event loops and UI work.
- Add or update tests for behavior changes, especially parsing, cryptography, authentication, host-key verification, vault handling, and transfer edge cases.
- Do not commit, revert, or reformat unrelated user changes. Check the working tree before editing and keep the final diff limited to the requested work.
- Never include real credentials, private keys, personal host data, or production logs in source, test fixtures, or documentation.

## Branches

- Always work on a branch, never directly on `main`. Before changing anything, check the current branch with `git branch --show-current`; if it is `main`, create a new branch first (a short, descriptive name such as `migration-backups`). This applies to every change, including small ones and documentation.
- Merge into `main` only when the user asks, and with a fast-forward where possible so history stays linear.
- Never delete a branch, local or remote, and never force-push or rewrite history that has been pushed. Branches are kept on purpose as rollback points, and the user removes them by hand when they choose to.
