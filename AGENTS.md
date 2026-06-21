# AGENTS.md

## Cursor Cloud specific instructions

DockBridge is a macOS-native SFTP client. It has two parts:

- **Rust workspace** (`crates/core`, `crates/uniffi`, `crates/cli`) — the SFTP engine, the UniFFI
  bridge, and a development CLI (`dockbridge`). This is the only part that builds and runs on the
  Linux cloud VM.
- **Swift macOS app** (`apps/macos`) — requires macOS + Xcode 16+, so it **cannot be built or tested
  on this Linux VM**. The macOS-specific scripts (`scripts/build-rust.sh` cross targets,
  `scripts/generate-uniffi.sh`, `scripts/package-macos-release.sh`, the `swift_*` checks in
  `scripts/e2e-verify.sh`) are out of scope here.

### Lint / test / build (Rust, mirrors `.github/workflows/ci.yml`)

- Format check: `cargo fmt --all -- --check`
- Lint: `cargo clippy --workspace --all-targets -- -D warnings`
- Tests: `cargo test --workspace` (core has the bulk; CI runs `cargo test -p dockbridge-core`)
- Build: `cargo build --workspace`

A full clean `cargo build`/`clippy` compiles the whole dependency tree (~1–2 min each). The update
script only runs `cargo fetch`, so the first build of a session still does the actual compilation.

### Running the CLI against a real SFTP server (hello-world)

Docker is **not** preinstalled. `scripts/e2e-verify.sh` expects a Docker `atmoz/sftp` container; on
this VM run a local OpenSSH server instead:

```bash
sudo apt-get update -qq && sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd
ssh-keygen -t ed25519 -f /tmp/sftpdemo/ssh_host_ed25519_key -N ""
echo "ubuntu:password" | sudo chpasswd        # gives the ubuntu user a known password
printf 'Port 2222\nListenAddress 127.0.0.1\nHostKey /tmp/sftpdemo/ssh_host_ed25519_key\nUsePAM yes\nPasswordAuthentication yes\nSubsystem sftp internal-sftp\n' > /tmp/sftpdemo/sshd_config
sudo /usr/sbin/sshd -f /tmp/sftpdemo/sshd_config
```

Then drive the CLI (it reads the password, then `yes` to trust the host key on first connect):

```bash
{ printf '%s\n' password yes; } | cargo run -q -p dockbridge-cli -- --config <cfg.toml> \
  upload --host 127.0.0.1 --port 2222 --user ubuntu --password-stdin \
  --local ./file.txt --remote /home/ubuntu/upload/hello.txt
```

Non-obvious gotchas discovered during setup:

- The CLI config TOML has **no serde defaults**: a partial config fails with `missing field ...`.
  Provide all `AppConfig` fields (see `config/default.toml`), e.g. `transfer_chunk_size_bytes`.
  Point `known_hosts_path` at a writable temp file and set
  `merge_openssh_known_hosts_on_connect = false` to avoid touching `~/.ssh/known_hosts`.
- Remote paths resolve **absolute from `/`**, not the login home. Use full paths like
  `/home/ubuntu/upload/hello.txt` (a bare `upload/hello.txt` becomes `/upload/...` and fails).
- Uploads are atomic: the CLI writes a `.partial` file and renames it onto the target. SFTP rename
  does not overwrite, so re-uploading to an existing remote path fails with `Failure: Failure` —
  delete the remote file (or use a new name) before re-uploading.
