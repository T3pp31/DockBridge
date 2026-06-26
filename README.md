# DockBridge

<p align="center">
  <img src="docs/assets/thumbnail.png" alt="DockBridge" width="256">
</p>

DockBridge is a macOS-native SFTP client inspired by WinSCP.

SCP support may be considered after v1.0.

## Download

Pre-built macOS releases are available on the [download site](https://t3pp31.github.io/DockBridge/) and [GitHub Releases](https://github.com/T3pp31/DockBridge/releases).

- Requires macOS 15 Sequoia or later
- Public releases are unsigned; on first launch, right-click `DockBridge.app` in Applications and choose **Open** (or allow it under **System Settings → Privacy & Security**). Developer ID signing and notarization are planned for v1.0.

## Requirements

- macOS 15 Sequoia or later
- Rust stable toolchain
- Xcode 16+

## Build

```bash
# Rust workspace
cargo build --release

# CLI (development)
cargo run -p dockbridge-cli -- list --help
```

### CLI password authentication

Prefer `--password-stdin` for scripts, CI, and production. The password is not stored in argv, shell history, or `ps` output:

```bash
printf '%s\n' "$PASSWORD" | cargo run -q -p dockbridge-cli -- list \
  --host 127.0.0.1 --user demo --password-stdin --path upload
```

The `--password` flag is for local development and testing only. Passwords on the command line may appear in shell history and process listings (CWE-214). In CI and release builds, the CLI prints a warning when `--password` is used.

To remove `--password` entirely, build with `--features disable-cli-password` on `dockbridge-cli`.

### macOS app (Rust + UniFFI)

```bash
# Rust static lib + Swift bindings
./scripts/build-rust.sh
./scripts/generate-uniffi.sh
```

Open `apps/macos/DockBridge.xcodeproj` in Xcode to build the macOS app.

The DockBridge target runs a **preBuild** phase on every Xcode build (`alwaysOutOfDate = 1`) that executes `./scripts/build-rust.sh` and `./scripts/generate-uniffi.sh` from the repository root. The app links `target/release/libdockbridge_uniffi.a` with `-force_load`.

#### After changing Rust or UniFFI (`crates/core`, `crates/uniffi`)

1. From the repository root, rebuild the static library and regenerate Swift bindings:

   ```bash
   ./scripts/build-rust.sh
   ./scripts/generate-uniffi.sh
   ```

2. If you changed the UniFFI surface (new or renamed functions, types, or errors), commit the updated `apps/macos/DockBridge/Generated/DockBridgeUniffi.swift`. CI verifies that this file matches the generated output.

3. Build or run the app in Xcode (Cmd+B / Cmd+R). The preBuild phase also runs the scripts, but running them manually first avoids stale artifacts and makes binding diffs easier to review before committing.

See `apps/macos/README.md` for app-specific details.

#### Troubleshooting (macOS app)

**Linker error: `Undefined symbol: _uniffi_dockbridge_uniffi_fn_...`**

The Swift bindings and the static library are out of sync. Rebuild from the repository root:

```bash
./scripts/build-rust.sh
./scripts/generate-uniffi.sh
```

Then clean the Xcode build folder (Product → Clean Build Folder) and rebuild. If you changed the UniFFI API, regenerate `DockBridgeUniffi.swift` and commit it.

**UniFFI checksum mismatch at runtime**

Swift bindings were generated from a different library than the one linked into the app. Run both scripts above, ensure `target/release/libdockbridge_uniffi.a` is fresh, clean the Xcode build folder, and rebuild.

## Project layout

```text
crates/core/     Rust SFTP core
crates/uniffi/   UniFFI bridge
crates/cli/      Development CLI
apps/macos/      SwiftUI macOS app
config/          CLI default configuration
docs/            Product and architecture docs
scripts/         Build helpers
```

## License

MIT
