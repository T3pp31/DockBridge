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

## Verify transfer cancel (Issue #3)

### Automated (recommended)

Requires Docker. Starts `dockbridge-e2e` on port 2222 if needed, then runs the E2E test that mirrors the Transfer Queue Cancel flow:

```bash
./scripts/verify-transfer-cancel.sh
```

This is also included in the full E2E suite:

```bash
./scripts/e2e-verify.sh
```

### Manual UI check

1. Start Docker SFTP: `docker run -d --name dockbridge-e2e -p 2222:22 -e SFTP_USER=demo atmoz/sftp demo:password:::upload`
2. Build Rust (`./scripts/build-rust.sh`) and run the app in Xcode (Cmd+R).
3. Connect to `127.0.0.1:2222` as `demo` / `password`; accept the host key.
4. Upload a large local file (32 MB or more) to the remote pane.
5. Open **Transfer Queue**, confirm the task shows **In Progress** with a **Cancel** button.
6. Click **Cancel**; the task status should change to **Cancelled**.

Cancel is checked between read/write chunks, so large transfers can be interrupted at chunk boundaries (default chunk size: 256 KiB).

When cancelling an upload that would overwrite an existing remote file, the original remote file is preserved. Transfers write to a temporary `.dockbridge-<timestamp>.partial` file in the same directory and atomically rename it on success; cancel removes only the partial file.

If cancel succeeds but partial-file cleanup fails, the Transfer Queue shows **Failed** with a message that a partial file may remain on the server or locally. Remove any leftover `.dockbridge-*.partial` files manually if needed.

## Architecture

- Swift builds `AppConfigRecord` and passes it to Rust via UniFFI.
- `HostKeyHandler` shows accept/reject UI for unknown host keys (SHA256 fingerprint).
- Passwords and key passphrases are stored in Keychain (`com.dockbridge`).
- Connection profiles live in `~/Library/Application Support/DockBridge/profiles.json` (AES-GCM encrypted envelope; master key in Keychain).
- Known hosts: `~/Library/Application Support/DockBridge/known_hosts.json` (mode 0600).
