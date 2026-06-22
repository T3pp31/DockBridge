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
| Swift Services | Keychain, AppConfig assembly, connection profiles, file watching |
| UniFFI | Type-safe bridge between Swift and Rust |
| Rust Core | SSH/SFTP, transfer queue, known hosts, error classification, transfer overwrite policy |

## Configuration flow

- **macOS app**: Swift reads settings → builds `AppConfig` → passes via UniFFI to Rust
- **CLI**: reads `config/default.toml` directly

## Host key verification

- Fingerprint format: OpenSSH SHA256 (`SHA256:...`)
- Storage: `~/Library/Application Support/DockBridge/known_hosts.json` (mode 0600)
- Swift shows accept/reject UI; Rust performs verification
