# DockBridge Security

## v0.1 minimum security baseline

- First-connection host key fingerprint display (SHA256)
- User accept/reject for unknown host keys
- Trusted keys stored in DockBridge `known_hosts.json` (0600)
- Hostname/IP alias normalization: same port and fingerprint are trusted across identifiers (OpenSSH-style comma-separated hosts)
- OpenSSH `known_hosts` import/export helpers on `KnownHostsManager`
- Automatic merge with OpenSSH `known_hosts` on connect (configurable; see macOS Settings)
- Hashed host entry (`|1|...`) import and matching
- `@revoked` entries reject matching keys; `@cert-authority` entries are imported but not used for host trust (host certificate authentication is not supported)
- Host key mismatch prompts with previous and new SHA256 fingerprints (explicit accept required)
- Passwords and key passphrases stored in Keychain only
- Private key files are referenced by path, never copied into the app bundle
- No passwords, keys, or passphrases in logs
- Rust secrets use `Debug` redaction and `zeroize` where applicable
- UniFFI credentials use a `SecretCredential` custom type that zeroizes on drop after lift
- Swift clears password/passphrase and `ConnectionProfileRecord` credentials after connect
- Delete confirmation for destructive operations
- Warning when connecting as root

## CLI password authentication

Password-based CLI connections support two mechanisms:

| Flag | Use case | Risk |
|------|----------|------|
| `--password-stdin` | Scripts, CI, production | Recommended; password is not visible in argv or `ps` |
| `--password` | Local development and testing only | Visible in argv, shell history, and process listings ([CWE-214](https://cwe.mitre.org/data/definitions/214.html)) |

Example (recommended):

```bash
printf '%s\n' "$PASSWORD" | dockbridge list \
  --host example.com --user demo --password-stdin --path .
```

When `CI=true` or in release builds, the CLI prints a warning if `--password` is used. Set `DOCKBRIDGE_SUPPRESS_PASSWORD_WARNING=1` only when you accept the risk (for example, a one-off local test in CI).

For hardened deployments, build the CLI without the flag:

```bash
cargo build -p dockbridge-cli --release --features disable-cli-password
```

## Connection profiles (`profiles.json`)

### Storage location and contents

Connection profiles are stored as JSON at:

`~/Library/Application Support/DockBridge/profiles.json`

The file is written with owner-only permissions (`0600`) on every save and load. Passwords and private-key passphrases are **not** stored in this file; they live in the macOS Keychain only.

Fields persisted in plaintext JSON include:

| Field | Sensitivity |
|-------|-------------|
| `name`, `host`, `port`, `username` | Infrastructure mapping |
| `authType` | Reveals authentication method per host |
| `privateKeyPath` | Path to a private key on disk |
| `privateKeyBookmark` | Security-scoped bookmark for sandboxed key access |
| `lastConnectedAt` | Usage metadata |

### Plaintext storage risk

Because profile metadata is not encrypted at the application layer, anyone who can read `profiles.json` can learn which hosts you connect to, under which accounts, and where private keys are referenced. That does not expose passwords or passphrases directly, but it can leak enough context for targeted follow-on attacks (for example, stealing a referenced key file or phishing a specific account).

Relevant classifications:

- [OWASP A02: Cryptographic Failures](https://owasp.org/Top10/A02_2021-Cryptographic_Failures/)
- [CWE-311: Missing Encryption of Sensitive Data](https://cwe.mitre.org/data/definitions/311.html)

Severity in DockBridge’s threat model: **Low**, assuming the mitigations below are in place.

### Current mitigations

- **File permissions (`0600`)** — only the owning user can read or write `profiles.json`.
- **App Sandbox** — the app cannot read arbitrary paths; private keys require explicit user selection.
- **Keychain for secrets** — passwords and passphrases never appear in `profiles.json` or logs.
- **No secret material in logs** — connection logs must not echo credentials or key contents.

`0600` protects against other OS users and unprivileged processes. It does **not** protect against:

- Malware running as the same user
- Physical access to an unlocked Mac
- Disk images or backups copied while the volume is decrypted

### FileVault prerequisite

DockBridge assumes the boot volume is protected with **FileVault** (or equivalent full-disk encryption). FileVault encrypts data at rest so that `profiles.json`, Keychain items, and private key files are not readable from a stolen drive while the Mac is powered off.

Without full-disk encryption, `0600` and App Sandbox reduce casual exposure but do not prevent offline disk extraction. Operators in shared, travel, or compliance-sensitive environments should enable FileVault before storing production connection profiles.

### Encrypted store migration (future consideration)

For environments that require stronger confidentiality than plaintext JSON plus OS-level controls, these approaches are under consideration for a future release:

| Approach | Pros | Cons |
|----------|------|------|
| **Keychain-backed profiles** — store each profile (or profile blob) as a Keychain generic-password item | OS-managed encryption; reuses existing `KeychainService` patterns | Harder to inspect or bulk-edit; migration from JSON; per-item Keychain UX limits |
| **Encrypted JSON file** — AES-GCM envelope encryption with a master key held in Keychain | Keeps a single portable file; familiar backup/restore shape | Key rotation and migration complexity; must handle corrupt ciphertext gracefully |
| **Status quo** — plaintext JSON with `0600` + Sandbox + FileVault | Simple, debuggable, sufficient for typical developer workstations | Metadata readable by same-user malware or forensic disk access on an unlocked machine |

No migration is planned for v0.1. See [roadmap.md](roadmap.md) for tracking. Implementation would include a one-time upgrade path from existing `profiles.json` files and documentation for operators who export or back up profiles.

### OpenSSH known_hosts merge (macOS Sandbox)

The macOS app runs in App Sandbox and cannot read `~/.ssh/known_hosts` without explicit user consent. To merge OpenSSH trust on connect:

1. Enable **Merge OpenSSH known_hosts on connect** in Settings.
2. Use **Choose…** to select your `known_hosts` file (security-scoped bookmark is saved).
3. If no file is selected or the path is unreadable, merge is skipped silently and connections continue.

The CLI and non-sandboxed environments use `openssh_known_hosts_path` from `config/default.toml` (default: `~/.ssh/known_hosts`).

## macOS App Sandbox

DockBridge runs with App Sandbox enabled for defense in depth and a reduced attack surface. An SFTP client does not need full filesystem access; user-selected paths and security-scoped bookmarks are sufficient for browsing, transfers, and private-key references. The app accesses only folders and keys explicitly chosen by the user.

### Entitlements

- `com.apple.security.app-sandbox` — confines the app to its container and granted capabilities
- `com.apple.security.network.client` — outbound TCP for SSH/SFTP connections
- `com.apple.security.files.user-selected.read-write` — read/write access to paths chosen via open panel or drag-and-drop
- `com.apple.security.files.bookmarks.app-scope` — persist user-selected paths across launches
- `keychain-access-groups` (`$(AppIdentifierPrefix)com.dockbridge.app`) — Keychain access under Sandbox

Entitlements not granted include `network.server`, `temporary-exception.files.absolute-path.*`, and broad folder access such as `downloads.read-write`.

### Code signing

- Hardened Runtime enabled for Release builds
- Notarization is not yet in CI (planned for v1.0); required before Developer ID distribution outside the Mac App Store

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
| RUSTSEC-2026-0153 | russh-cryptovec | High (7.5) | Upgrade to `russh >=0.60.3` when Rust toolchain supports 1.85+ |
| RUSTSEC-2026-0154 | russh | High (7.5) | Same as above |
| RUSTSEC-2023-0071 | rsa | Medium (5.9) | No fixed upgrade available; transitive via `russh` / `ssh-key` |

Run `cargo audit` locally to match CI (`.cargo/audit.toml` applies tracked exceptions):

```bash
cargo install cargo-audit --locked
cargo audit
```
