# DockBridge Roadmap

## v0.1 internal milestones

| Milestone | Goal |
|-----------|------|
| v0.1-a | Rust CLI: SFTP list/upload/download + host key verification |
| v0.1-b | UniFFI: HostKeyChallenge callback + listDirectory |
| v0.1-c | SwiftUI 2-pane UI + connection profiles |
| v0.1-d | Keychain + private key auth + transfer queue |
| v0.1-e | delete/rename/mkdir + security E2E |

## v0.2

- OpenSSH known_hosts compatibility
- External editor integration
- Auto-upload on save
- Drag and drop
- chmod, hidden files, symlinks
- Encrypted connection-profile storage (AES-GCM envelope + Keychain master key) — implemented; see [security.md](security.md#connection-profiles-profilesjson)
- Developer ID signing and notarization for release DMGs — implemented; see [security.md](security.md#release-signing-pipeline)

## v0.3

- Directory sync with preview
- Workspaces

## 1.0

- Stable SFTP feature set

## After 1.0

- SCP support may be considered
