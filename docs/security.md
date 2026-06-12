# DockBridge Security

## v0.1 minimum security baseline

- First-connection host key fingerprint display (SHA256)
- User accept/reject for unknown host keys
- Trusted keys stored in DockBridge `known_hosts.json` (0600)
- Connection blocked on host key mismatch
- Passwords and key passphrases stored in Keychain only
- Private key files are referenced by path, never copied into the app bundle
- No passwords, keys, or passphrases in logs
- CLI `--password` is for development and testing only; prefer `--password-stdin` in scripts
- Rust secrets use `Debug` redaction and `zeroize` where applicable
- Delete confirmation for destructive operations
- Warning when connecting as root

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
