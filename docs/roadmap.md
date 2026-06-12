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
- `profiles.json` tamper warnings (Issue #27)
- External editor integration
- Auto-upload on save
- Drag and drop
- chmod, hidden files, symlinks

## v0.3

- Directory sync with preview
- Workspaces

## 1.0

- Developer ID signing + Notarization
- Stable SFTP feature set
- Evaluate encrypted profile storage (Keychain or encrypted blob) for high-assurance deployments — see [security.md](security.md#encrypted-storage-migration-under-consideration)

## After 1.0

- SCP support may be considered
