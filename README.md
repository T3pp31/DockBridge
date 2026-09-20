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

### CLI private-key authentication

For servers that only allow key authentication (`PasswordAuthentication no`), use `--identity` (short `-i`). `~` in the path is expanded to the home directory:

```bash
cargo run -q -p dockbridge-cli -- list \
  --host 127.0.0.1 --user demo --identity ~/.ssh/id_ed25519 --path upload
```

Encrypted keys are unlocked with `--passphrase-stdin` (which reads from stdin exactly like `--password-stdin` and reuses the same zeroize-on-drop handling):

```bash
printf '%s\n' "$KEY_PASSPHRASE" | cargo run -q -p dockbridge-cli -- list \
  --host 127.0.0.1 --user demo --identity ~/.ssh/id_ed25519 --passphrase-stdin
```

`--identity` is mutually exclusive with `--password-stdin`. Keys whose algorithm is outside the supported set (ed25519, ec/ecdsa, rsa) are rejected with a clear error before any connection is attempted.

**Development builds** (`cargo build` / `cargo run` without extra features) include `--password` for local testing. Passwords on the command line may appear in shell history and process listings (CWE-214). In CI and release builds, the CLI prints a warning when `--password` is used.

**Release builds** (`.github/workflows/release.yml`) compile the CLI with `--features disable-cli-password`, which removes `--password` at compile time. Release artifacts accept only `--password-stdin`. To reproduce a release build locally:

```bash
cargo build -p dockbridge-cli --release --features disable-cli-password
```

See [docs/security.md](docs/security.md#cli-password-authentication) for the full distribution policy.

### Host key verification

`--host-key-policy` controls how unknown or changed host keys are handled (default `ask`):

- `ask` — prompt on `/dev/tty` (never stdin); falls back to `strict` when no controlling terminal is available
- `accept-new` — trust unknown host keys automatically; still rejects changed keys (use for first connection in scripts/CI)
- `strict` — only trust keys already present in the known-hosts store

Because prompts are read from `/dev/tty`, `--password-stdin` / `--passphrase-stdin` exclusively own stdin:

```bash
# First-time connection, non-interactive: trust the new host key automatically
printf '%s\n' "$PASSWORD" | cargo run -q -p dockbridge-cli -- list \
  --host 127.0.0.1 --user demo --password-stdin --host-key-policy accept-new
```

### Exit codes

The CLI exits with distinct codes so scripts can branch on the failure category (documented in `dockbridge --help`):

| Exit | Meaning                |
|------|------------------------|
| 0    | success                |
| 1    | other error            |
| 2    | usage or configuration |
| 3    | host key verification  |
| 4    | authentication        |
| 5    | transfer failed       |
| 6    | transfer cancelled    |

### Machine-readable output

`list --output json` emits an array of `{"kind":"file|dir","size":...,"path":"...","modified_at":...}` objects (tab-separated text is the default). `modified_at` is a Unix timestamp (`null` when the server reported no modification time) — consumers must handle `null`. This format is safe for file names containing tabs or newlines:

```bash
cargo run -q -p dockbridge-cli -- list \
  --host 127.0.0.1 --user demo --password-stdin --output json
```

### Subcommands

`list`, `upload`, `download`, `delete`, `rename`, `mkdir`, and `pwd` are available. `upload`/`download` accept `--recursive` to transfer a whole directory tree (`enqueue_upload_entry` / `enqueue_download_entry`):

```bash
cargo run -q -p dockbridge-cli -- upload \
  --host 127.0.0.1 --user demo --password-stdin \
  --local ./dist --remote /upload/dist --recursive

cargo run -q -p dockbridge-cli -- mkdir \
  --host 127.0.0.1 --user demo --password-stdin --remote /upload/new

cargo run -q -p dockbridge-cli -- pwd \
  --host 127.0.0.1 --user demo --password-stdin
```

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
crates/core/       Rust SFTP core
crates/uniffi/     UniFFI bridge
crates/cli/        Development CLI
apps/macos/        SwiftUI macOS app
config/            CLI default configuration
docs/              Product / architecture / security docs
scripts/           Build, packaging, and verification helpers (e2e-verify.sh, verify-*.sh)
website/           GitHub Pages download site
.cargo/            Rust toolchain and cargo-audit ignore policy
.github/           Workflows, issue/PR templates, SECURITY.md, CONTRIBUTING.md
```

## License

MIT
