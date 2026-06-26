# DockBridge Security

## v0.1 minimum security baseline

- First-connection host key fingerprint display (SHA256)
- User accept/reject for unknown host keys
- Trusted keys stored in DockBridge `known_hosts.json` (written `0600`; on Unix, load rejects files that are not owner-only `0600`/`0400`, owned by the current user, or accessed through a symlink)
- Hostname/IP alias normalization: same port and fingerprint are trusted across identifiers (OpenSSH-style comma-separated hosts)
- OpenSSH `known_hosts` import/export helpers on `KnownHostsManager`
- Automatic merge with OpenSSH `known_hosts` on connect (configurable; see macOS Settings)
- Hashed host entry (`|1|...`) import and matching
- `@revoked` entries reject matching keys; `@cert-authority` entries are imported but not used for host trust (host certificate authentication is not supported)
- Host key mismatch prompts with previous and new SHA256 fingerprints (explicit accept required)
- Passwords and key passphrases stored in Keychain only
- Private key files require a security-scoped bookmark (selected via Browse…); plaintext path-only references are not used for connections
- No passwords, keys, or passphrases in logs
- Rust secrets use `Debug` redaction and `zeroize` where applicable
- CLI `--password-stdin` read buffers use `Zeroizing<String>` so stdin input is zeroized on drop
- UniFFI credentials use a `SecretCredential` custom type that zeroizes on drop after lift
- Swift clears password/passphrase and `ConnectionProfileRecord` credentials after connect
- Delete confirmation for destructive operations
- Warning when connecting as root
- **FileVault (or equivalent full-disk encryption) recommended** on the boot volume — see [Connection profiles](#connection-profiles-profilesjson)

## CLI password authentication

Password-based CLI connections support two mechanisms:

| Flag | Use case | Risk |
|------|----------|------|
| `--password-stdin` | Scripts, CI, production | **Recommended**; password is not visible in argv or `ps` |
| `--password` | Local development and testing only | Visible in argv, shell history, and process listings ([CWE-214](https://cwe.mitre.org/data/definitions/214.html)) |

### Distribution policy

For production deployments and release artifacts, build the CLI **without** inline `--password` support:

```bash
cargo build -p dockbridge-cli --release --features disable-cli-password
```

This removes the `--password` flag at compile time so operators cannot accidentally pass secrets on the command line. Use `--password-stdin` exclusively in scripts, CI, and automation.

Example (recommended):

```bash
printf '%s\n' "$PASSWORD" | dockbridge list \
  --host example.com --user demo --password-stdin --path .
```

When `CI=true` or in release builds, the CLI prints a warning if `--password` is used. Set `DOCKBRIDGE_SUPPRESS_PASSWORD_WARNING=1` only when you accept the risk (for example, a one-off local test in CI).

## Host key trust policy

Rust core settings in `config/default.toml` (and UniFFI `AppConfigRecord`):

| Setting | Default | Effect |
|---------|---------|--------|
| `known_hosts_strict_mode` | `true` | When `true`, trusts host keys only for exact host/port (or stored alias) matches. Disables fingerprint alias fallback across hostnames. Set to `false` in Settings or config to preserve OpenSSH-style alias behavior. |
| `fail_connect_on_openssh_merge_error` | `true` | When `true`, aborts the connection if merging OpenSSH `known_hosts` fails. Set to `false` to log merge failures and continue connecting. |

## Connection profiles (`profiles.json`)

### Storage location and format

Connection profiles are stored at:

`~/Library/Application Support/DockBridge/profiles.json`

The file is written with owner-only permissions (`0600`) on every save and load. Passwords and private-key passphrases are **not** stored in this file; they live in the macOS Keychain only.

Profile metadata is stored as an **AES-GCM encrypted envelope**. A 256-bit master key is generated on first save and kept in Keychain (`encryption-key.profiles.master-key` under service `com.dockbridge`). The on-disk JSON contains only:

| Field | Contents |
|-------|----------|
| `format` | Envelope version (`dockbridge-profiles-v1`) |
| `payload` | Base64-encoded AES-GCM ciphertext (nonce + ciphertext + tag) |

Plaintext hostnames, usernames, bookmarks, and other metadata never appear in `profiles.json`.

Fields encrypted inside the payload include:

| Field | Sensitivity |
|-------|-------------|
| `name`, `host`, `port`, `username` | Infrastructure mapping |
| `authType` | Reveals authentication method per host |
| `privateKeyBookmark` | Security-scoped bookmark for sandboxed key access |
| `lastConnectedAt` | Usage metadata |

`privateKeyPath` is **not persisted**. It is resolved from `privateKeyBookmark` at runtime for UI display and connections.

### Residual risk

Application-layer encryption reduces exposure from same-user disk reads, backups of `profiles.json`, and casual forensic inspection. Residual risks include:

- Same-user malware with Keychain access can decrypt profiles while the Mac is unlocked
- Loss or corruption of the Keychain master key makes the encrypted file unreadable
- Physical access to an unlocked Mac

Relevant classifications:

- [OWASP A02: Cryptographic Failures](https://owasp.org/Top10/A02_2021-Cryptographic_Failures/)
- [CWE-311: Missing Encryption of Sensitive Data](https://cwe.mitre.org/data/definitions/311.html)

Severity in DockBridge’s threat model: **Low to Medium**, depending on deployment; encryption materially reduces metadata leakage compared to plaintext JSON.

### Mitigations

- **AES-GCM envelope encryption** — profile metadata is not stored in plaintext JSON.
- **Keychain master key** — encryption key never written to `profiles.json`.
- **File permissions (`0600`)** — only the owning user can read or write `profiles.json`.
- **App Sandbox** — the app cannot read arbitrary paths; private keys require explicit user selection.
- **Keychain for secrets** — passwords and passphrases never appear in `profiles.json` or logs.
- **No secret material in logs** — connection logs must not echo credentials or key contents.

`0600` and encryption protect against other OS users and unprivileged processes. They do **not** fully protect against:

- Malware running as the same user with Keychain access
- Physical access to an unlocked Mac
- Disk images or backups copied while the volume is decrypted (Keychain items may still be protected separately)

### FileVault recommendation

**FileVault (or equivalent full-disk encryption) is strongly recommended** on any Mac that stores production connection profiles. DockBridge uses application-layer encryption for profile metadata, but Keychain items and referenced private key files still benefit from OS-level encryption at rest when the machine is powered off or the volume is locked.

Without full-disk encryption, `0600`, App Sandbox, and profile encryption reduce casual exposure but do not prevent offline disk extraction of non-Keychain artifacts. Enable FileVault before saving production profiles in shared, travel, or compliance-sensitive environments.

### Migration from legacy plaintext JSON

DockBridge automatically upgrades legacy plaintext `profiles.json` files (pre-v0.2 format: a JSON array of profiles) on first load:

1. Read and decode the legacy array.
2. Strip `privateKeyPath` from the persisted payload.
3. Re-encrypt and atomically rewrite `profiles.json`.
4. Leave Keychain credentials unchanged.

Operators who back up profiles must back up **both** `profiles.json` and the DockBridge Keychain items (master key and per-profile credentials).

### Corrupt store recovery

If decryption fails (missing master key, truncated file, or tampered ciphertext), DockBridge surfaces a corrupt-store error. Recovery options:

1. Restore `profiles.json` **and** matching Keychain items from backup.
2. Delete `~/Library/Application Support/DockBridge/profiles.json`, remove stale DockBridge Keychain entries, and recreate connections in the app.

Do not edit the encrypted envelope manually.

### Legacy note (pre-v0.2 plaintext format)

Earlier versions stored profile metadata as plaintext JSON with `0600` permissions and relied primarily on FileVault for confidentiality at rest. That format is migrated automatically; see above.

### OpenSSH known_hosts merge (macOS Sandbox)

The macOS app runs in App Sandbox and cannot read `~/.ssh/known_hosts` without explicit user consent. To merge OpenSSH trust on connect:

1. Enable **Merge OpenSSH known_hosts on connect** in Settings.
2. Use **Choose…** to select your `known_hosts` file (security-scoped bookmark is saved).
3. If no file is selected or the path is unreadable, merge is skipped silently and connections continue.

The CLI and non-sandboxed environments use `openssh_known_hosts_path` from `config/default.toml` (default: `~/.ssh/known_hosts`).

On Unix, DockBridge `known_hosts.json` must be owned by the effective user, must not be a symbolic link, and must have permissions `0600` or `0400` when loaded. Files with looser permissions are rejected so a tampered trust anchor cannot be trusted silently. Repair with `chmod 600` on the DockBridge store file.

When merging OpenSSH `known_hosts` on connect, the external file must be owned by the effective user, must not be a symbolic link, and must not be writable by group or others (standard `0644` is accepted). Files with group/other write bits (for example `0664` or `0666`) are rejected at import.

### Known hosts strict mode

Set `known_hosts_strict_mode = true` in `config/default.toml` (or pass it via `AppConfigRecord`) to trust host keys only when the connecting host/port matches a stored entry or hashed OpenSSH entry. Fingerprint-only alias trust (same key, different hostname) is disabled in strict mode. Default is `true`; set to `false` to preserve OpenSSH-style alias behavior.

### OpenSSH merge failure handling

By default, a failed OpenSSH `known_hosts` merge aborts the connection (`fail_connect_on_openssh_merge_error = true`). Set `fail_connect_on_openssh_merge_error = false` to log merge failures and continue connecting.

### Hashed host entries and SHA-1

OpenSSH hashed host lines (`|1|salt|hash`) use **SHA-1** to derive the stored hostname hash. DockBridge implements the same algorithm when importing and matching hashed entries in `KnownHostsManager` (see `openssh_hostname_hash` in `crates/core/src/security/known_hosts.rs`).

This SHA-1 usage is **OpenSSH specification–compliant**, not a general-purpose integrity choice. DockBridge does not use SHA-1 for host-key fingerprints shown to users (those use SHA-256) or for SSH transport cryptography. Hashed-entry matching must remain SHA-1–compatible to interoperate with standard `known_hosts` files.

## macOS App Sandbox

DockBridge runs with App Sandbox enabled for defense in depth and a reduced attack surface. An SFTP client does not need full filesystem access; user-selected paths and security-scoped bookmarks are sufficient for browsing, transfers, and private-key references. The app accesses only folders and keys explicitly chosen by the user.

## SFTP transfer safety

Uploads and downloads write to temporary partial files before renaming to the final destination:

| Stage | Local partial | Remote partial |
|-------|---------------|----------------|
| Create | `create_new(true)` + `O_NOFOLLOW` (Unix) | `CREATE \| EXCLUDE \| WRITE` |
| Name | `.dockbridge-<32-hex>.partial` (cryptographic random) | same pattern in destination directory |
| Cancel / failure | partial file removed; destination untouched | partial file removed; destination untouched |
| Success | rename partial → final | delete existing destination when policy is `Replace`, then rename |

`TransferOverwritePolicy` controls final-destination behavior:

| Policy | Behavior |
|--------|----------|
| `Replace` (default) | Replace an existing destination after the transfer completes successfully. Remote uploads delete the existing file before rename when the server does not overwrite via rename alone. |
| `FailIfExists` | Fail without modifying the destination when it already exists. |

Local finalize rejects symlink destinations without following them. Partial files are never opened through symlinks on Unix.

### Entitlements

- `com.apple.security.app-sandbox` — confines the app to its container and granted capabilities
- `com.apple.security.network.client` — outbound TCP for SSH/SFTP connections
- `com.apple.security.files.user-selected.read-write` — read/write access to paths chosen via open panel or drag-and-drop
- `com.apple.security.files.bookmarks.app-scope` — persist user-selected paths across launches
- `keychain-access-groups` (`$(AppIdentifierPrefix)com.dockbridge.app`) — Keychain access under Sandbox

Entitlements not granted include `network.server`, `temporary-exception.files.absolute-path.*`, and broad folder access such as `downloads.read-write`.

### Code signing and distribution

- Hardened Runtime enabled for Release builds
- CI builds the macOS app unsigned (`CODE_SIGNING_ALLOWED=NO`) for compile and test verification only
- Public releases are signed with a Developer ID Application certificate, notarized with Apple Notary Service, and verified before upload

#### Release signing pipeline

GitHub Release workflow (`.github/workflows/release.yml`) requires these repository secrets:

| Secret | Purpose |
|--------|---------|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application `.p12` (Base64-encoded) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool` |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

Release packaging runs `scripts/sign-and-notarize-macos.sh`, which:

1. Signs the Release `.app` with a Developer ID Application certificate (`codesign --options runtime`)
2. Submits the build to Apple's Notary Service (`notarytool submit --wait`)
3. Staples the notarization ticket to the app bundle (`stapler staple`)
4. Verifies Gatekeeper acceptance (`spctl --assess --type execute`)

If signing or notarization fails, the release workflow stops before publishing assets.

Local unsigned builds for development:

```bash
SIGN_AND_NOTARIZE=false ./scripts/package-macos-release.sh
```

Do not distribute unsigned DMGs. The dev-only helper `scripts/dev-install-unsigned.command` removes quarantine attributes and must not be shipped in release DMGs.

## Dependency vulnerability management

### Automated scanning

- **CI (`cargo audit`)**: Every push to `main` and every pull request runs `rustsec/audit-check` against `Cargo.lock`. The job fails when a new advisory is reported.
- **Dependabot**: Weekly pull requests for `cargo` and `github-actions` dependency updates (see `.github/dependabot.yml`).

### Response workflow when a vulnerability is detected

1. **Triage** — Read the advisory (ID, CVSS severity, affected crate/version, upstream fix).
2. **Assess exposure** — Determine whether DockBridge uses the vulnerable code path (direct vs transitive dependency, client vs server role).
3. **Remediate** — Prefer, in order:
   - Merge a Dependabot PR or run `cargo update -p <crate>`.
   - Bump the direct dependency version in `Cargo.toml` and run tests.
   - If no fix exists, document the accepted risk (see step 4).
4. **Document exceptions** — When remediation is blocked (no upstream fix, major-version migration, toolchain requirement), add the advisory ID to `.cargo/audit.toml` with an inline comment explaining the blocker and link a tracking issue. Remove the entry once fixed.
5. **Verify** — Run `cargo audit` locally and confirm CI passes before merging.

### Severity targets

| CVSS | Target response |
|------|-----------------|
| Critical / High | Fix or document exception within one release cycle |
| Medium | Fix in next planned dependency update |
| Low / Info | Track via Dependabot; fix when convenient |

### Currently tracked exceptions

| Advisory | Crate | Severity | Status |
|----------|-------|----------|--------|
| RUSTSEC-2023-0071 | rsa | Medium (5.9) | No fixed upgrade available; see [RSA Marvin Attack](#rsa-marvin-attack-rustsec-2023-0071) |

### Recently resolved advisories

| Advisory | Crate | Severity | Resolution |
|----------|-------|----------|------------|
| RUSTSEC-2026-0153 | russh-cryptovec | High (7.5) | Fixed in `russh 0.61.2` / `russh-cryptovec 0.61.0` (patched `>=0.60.3`) |
| RUSTSEC-2026-0154 | russh | High (7.5) | Same as above |

### RSA Marvin Attack (RUSTSEC-2023-0071)

The `rsa` crate (currently `0.10.0-rc.18` in `Cargo.lock`) has no patched release. It is pulled in transitively by `russh` and `ssh-key`.

**Exposure in DockBridge**

- **Client authentication with an RSA private key** — DockBridge uses the `rsa` crate for RSA signing during SSH public-key authentication. An attacker who can observe network timing during authentication may recover key material (Marvin Attack).
- **Server host keys using RSA** — DockBridge also uses the same crate when verifying RSA server host keys (`ssh-rsa` with SHA-256/512 in `algorithm_policy.rs`). This is a different code path from client signing but shares the same dependency.

**Mitigations**

- **Prefer Ed25519 or ECDSA private keys** for client authentication. The macOS app shows a connection warning when an RSA private key is selected.
- **Host key policy** — DockBridge rejects legacy `ssh-rsa` without a hash (`Algorithm::Rsa { hash: None }`). Only RSA with SHA-256 or SHA-512 is accepted for server host keys.
- **Tracked exception** — `RUSTSEC-2023-0071` remains in `.cargo/audit.toml` until upstream ships a constant-time fix or DockBridge can drop RSA support entirely.

Run `cargo audit` locally to match CI (`.cargo/audit.toml` applies tracked exceptions):

```bash
cargo install cargo-audit --locked
cargo audit
```
