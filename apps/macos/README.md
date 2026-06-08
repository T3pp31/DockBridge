# DockBridge macOS App

SwiftUI front-end for DockBridge. Requires macOS 15+ and Xcode 16+.

## Open in Xcode

```bash
open apps/macos/DockBridge.xcodeproj
```

## Build Rust + Swift bindings

From the repository root:

```bash
./scripts/build-rust.sh
./scripts/generate-uniffi.sh
```

This writes Swift bindings to `DockBridge/Generated/` and links `target/release/libdockbridge_uniffi.a`.

### Generated artifacts policy

Policy B (v0.1): commit `DockBridge/Generated/DockBridgeUniffi.swift` only. Do not commit headers, modulemaps, static libraries, or other generated files under `Generated/`.

## Run

1. Build the Rust library (above).
2. Open the Xcode project and press Cmd+R.

## Architecture

- Swift builds `AppConfigRecord` and passes it to Rust via UniFFI.
- `HostKeyHandler` shows accept/reject UI for unknown host keys (SHA256 fingerprint).
- Passwords and key passphrases are stored in Keychain (`com.dockbridge`).
- Connection profiles live in `~/Library/Application Support/DockBridge/profiles.json`.
- Known hosts: `~/Library/Application Support/DockBridge/known_hosts.json` (mode 0600).
