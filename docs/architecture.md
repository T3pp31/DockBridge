# DockBridge Architecture

## Overview

```text
Swift / SwiftUI App
  |
  | UniFFI
  v
Rust Core (dockbridge-core)
  |
  v
SSH / SFTP (russh + russh-sftp)
  |
  v
Remote Server
```

## Layer responsibilities

| Layer | Responsibility |
|-------|----------------|
| SwiftUI | 2-pane UI, connection management, settings, host key dialogs |
| Swift Services | Keychain, AppConfig assembly, connection profiles |
| UniFFI | Type-safe bridge between Swift and Rust |
| Rust Core | SSH/SFTP, transfer queue, known hosts, error classification, transfer overwrite policy |

## Configuration flow

- **macOS app**: Swift reads settings → builds `AppConfig` → passes via UniFFI to Rust
- **CLI**: reads `config/default.toml` directly

## Host key verification

- Fingerprint format: OpenSSH SHA256 (`SHA256:...`)
- Storage: `~/Library/Application Support/DockBridge/known_hosts.json` (mode 0600)
- Swift shows accept/reject UI; Rust performs verification

## Known limitations

- **UniFFI is synchronous**: every exported `DockBridgeClient` method runs a
  blocking Tokio `block_on`. A large transfer therefore occupies a Swift
  cooperative thread for its whole duration; Swift wraps calls in
  `Task.detached`. Async UniFFI exports and `Task.cancel` propagation are
  planned but not yet implemented.
- **Errors are flattened**: `DockBridgeError` is a single
  `Generic { message }` variant at the UniFFI boundary. Swift re-parses
  strings to classify auth / host-key / cancellation errors. Typed error
  variants are planned.
- **No file watching**: local directory changes (e.g. in Finder) are not
  auto-refreshed; the local pane reloads on navigation / explicit actions.
  This section will be updated if FSEvents/DispatchSource watching is added.
- **known_hosts stores are not shared between app and CLI**: the macOS app
  (sandboxed) stores its store under its container data directory, while the
  CLI uses `~/.dockbridge/known_hosts.json` (see `config/default.toml`). Both
  are mode 0600. Editing one does not affect the other.
- **Two known_hosts sources**: the app uses its own JSON store plus an
  optional merge from OpenSSH `~/.ssh/known_hosts` on connect
  (`merge_openssh_known_hosts_on_connect`).
