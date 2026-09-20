# Contributing to DockBridge

Thanks for contributing! This document covers setup, what to check before
opening a PR, and the conventions used in this repository.

## Project layout

- `crates/core` — Rust SFTP engine (builds on Linux and macOS)
- `crates/uniffi` — UniFFI bridge exposing core to Swift
- `crates/cli` — development CLI (`dockbridge`)
- `apps/macos` — Swift/SwiftUI macOS app (macOS + Xcode 16+ required)
- `scripts/` — build, packaging, and verification helpers
- `website/` — GitHub Pages download site

## Setup

### Rust

```sh
rustup toolchain install stable
rustup component add rustfmt clippy
cargo build --workspace
```

### macOS app

You need macOS with **Xcode 16+**.

```sh
./scripts/build-rust.sh            # builds the Rust crates (all targets)
./scripts/generate-uniffi.sh       # regenerates apps/macos/DockBridge/Generated
open DockBridge.xcworkspace        # or open apps/macos/DockBridge.xcodeproj
```

When the UniFFI surface changes (records, methods, error types), you **must**
regenerate bindings with `./scripts/generate-uniffi.sh` and commit the
generated Swift files.

## Checks required before a PR

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
swift-format lint -r apps/macos/DockBridge apps/macos/DockBridgeTests  # if maintained
xcodebuild -scheme DockBridge -destination 'platform=macOS' build test  # macOS
```

If your change touches Rust internals or transfer behavior, also run
`./scripts/e2e-verify.sh` (requires Docker or a local OpenSSH SFTP server).

## Issue conventions

Issue titles use a category prefix:

- `Security:` — trust, keychain, host keys, supply chain
- `Bug:` — incorrect behavior
- `UI:` / `Accessibility:` / `i18n:` — app-facing changes
- `CI:` / `docs:` / `deps:` — pipeline / documentation / dependencies
- `Feature:` / `Perf:` / `Robustness:` — enhancements

Labels: `bug`, `enhancement`, `security`, `rust`, `github_actions`,
`documentation`, `macos`.

## PR conventions

- One PR per issue; reference the issue with `Closes #NNN`.
- Keep changes minimal and focused; avoid unrelated refactors.
- For `crates/*` changes, ensure `cargo test --workspace` and clippy pass.
- For `apps/macos` changes, note whether UniFFI bindings were regenerated and
  whether the change is testable on Linux (macOS-only code must at least parse).
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
- Do not commit secrets, `.env.local`, or generated build artifacts.

## Release process (maintainers)

1. Update the version in `Cargo.toml` and `config/release.toml`, move
   `CHANGELOG.md` `[Unreleased]` to a dated section.
2. Tag `v<version>` and push; the release workflow builds DMG/CLI/SBOM and
   attaches them to a GitHub Release.
3. Verify the release page, the download site, and `gh attestation verify`
   output.
