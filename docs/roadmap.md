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
- Evaluate encrypted connection-profile storage (Keychain-backed items or AES-GCM file envelope) for high-security deployments — see [security.md](security.md#encrypted-store-migration-future-consideration)

## v0.3

- Directory sync with preview
- Workspaces

## 1.0

- Developer ID signing + Notarization
- Stable SFTP feature set

## After 1.0

- SCP support may be considered
