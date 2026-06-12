# DockBridge Security

## v0.1 minimum security baseline

- First-connection host key fingerprint display (SHA256)
- User accept/reject for unknown host keys
- Trusted keys stored in DockBridge `known_hosts.json` (0600)
- Connection profiles stored in `profiles.json` (0600); see [Connection profile storage](#connection-profile-storage-profilesjson)
- Connection blocked on host key mismatch
- Passwords and key passphrases stored in Keychain only
- Private key files are referenced by path, never copied into the app bundle
- No passwords, keys, or passphrases in logs
- CLI `--password` is for development and testing only; prefer `--password-stdin` in scripts
- Rust secrets use `Debug` redaction and `zeroize` where applicable
- Delete confirmation for destructive operations
- Warning when connecting as root

## Connection profile storage (`profiles.json`)

Connection profiles are persisted as **unencrypted JSON** at:

`~/Library/Application Support/DockBridge/profiles.json`

Implementation: `ConnectionStore` (`apps/macos/DockBridge/Services/ConnectionStore.swift`).

### What is stored in plaintext

| Field | Sensitivity | Notes |
|-------|-------------|-------|
| `host`, `port` | High | Reveals infrastructure endpoints |
| `username` | High | Identifies privileged accounts (e.g. `root`) |
| `name` | Medium | May describe environment or role |
| `authType` | Medium | Indicates authentication method |
| `privateKeyPath` | High | Points to SSH private key location |
| `privateKeyBookmark` | High | Security-scoped bookmark to key file |
| `lastConnectedAt` | Low | Usage metadata |

Passwords and key passphrases are **not** stored in `profiles.json`; they live in Keychain only (`KeychainService`).

### Risk

Anyone who can read `profiles.json` learns which servers exist, which accounts are used, and where private keys are referenced. This is a **confidentiality** exposure (OWASP A02 Cryptographic Failures, CWE-311 Missing Encryption of Sensitive Data), not a credential leak by itself.

Typical exposure paths:

- Another user or process on the same Mac (mitigated partly by `0600`; see Issue #16)
- Backup or sync tools copying Application Support without encryption
- Forensic disk imaging when the volume is **not** encrypted at rest
- Malware running as the same user (file permissions do not help)

Severity is assessed as **Low** for typical single-user workstations with disk encryption, but rises in shared-machine or high-assurance environments.

### Mitigations in place

- POSIX `0600` on `profiles.json` (owner read/write only) — same policy as `known_hosts.json`
- App Sandbox limits filesystem access to the app container and user-selected paths
- Secrets (passwords, passphrases) isolated in Keychain with app-scoped access group

### FileVault prerequisite

DockBridge assumes the system volume is protected with **full-disk encryption** (macOS FileVault or equivalent). `0600` restricts access while macOS is running under the owner account; it does **not** protect data if an attacker obtains an unencrypted copy of the disk.

**Recommendation:** enable FileVault on any Mac that stores DockBridge connection profiles. Treat unencrypted volumes as out of scope for profile confidentiality.

### Encrypted storage migration (under consideration)

For environments that require stronger protection of connection metadata, the following approaches are under review for a future release:

| Approach | Pros | Cons |
|----------|------|------|
| **Keychain for profile fields** | OS-managed encryption, integrates with Sandbox entitlements | Per-field or blob storage; migration from JSON; Keychain size and UX limits for many profiles |
| **Encrypted file store** (e.g. AES-GCM blob, key in Keychain) | Keeps a single document model; transparent to list/edit UI | Custom crypto and key rotation; backup/restore complexity |
| **Hybrid** (non-sensitive fields in JSON, sensitive paths in Keychain) | Smaller migration; host/user still visible | Partial exposure remains |

No migration is scheduled for v0.1/v0.2. Related hardening (host-change warnings on tampering — Issue #27) may land earlier. Track progress in [roadmap.md](roadmap.md).

## v0.2 planned

- OpenSSH `~/.ssh/known_hosts` compatibility
- Stricter host key change warnings

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
