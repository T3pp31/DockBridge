# DockBridge

DockBridge is a macOS-native SFTP client inspired by WinSCP.

SCP support may be considered after v1.0.

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

The CLI `--password` flag is for development and testing only. It may appear in shell history and process listings. Prefer `--password-stdin` for scripts.

# Rust static lib + Swift bindings
./scripts/build-rust.sh
./scripts/generate-uniffi.sh
```

Open `apps/macos/DockBridge.xcodeproj` in Xcode to build the macOS app.

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
