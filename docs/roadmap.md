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

- [x] OpenSSH known_hosts compatibility (import/export/merge; see #302, #303)
- [x] Drag and drop (see #153, #337)
- [x] Encrypted connection-profile storage (AES-GCM envelope + Keychain master key); see [security.md](security.md#connection-profiles-profilesjson)
- [ ] Security: Developer ID signing and notarization for release DMGs (#391); see [security.md](security.md#code-signing-and-distribution)
- [ ] External editor integration (#361)
- [ ] Auto-upload on save (part of #361)
- [ ] chmod / permissions UI (#363)
- [ ] Symbolic link display & navigation (#300)

## v0.3

- [ ] Directory sync with preview
- [ ] Workspaces

## 1.0

- [x] Stable SFTP feature set (list/upload/download/delete/rename/mkdir, host keys, transfer queue)
- [x] Remote recursive delete (#315)
- [ ] Resume interrupted transfers (#313)
- [ ] Preserve file times/permissions on transfer (#314)

## After 1.0

- [ ] SCP support may be considered
- [ ] Multi-connection / tabs (#359)
