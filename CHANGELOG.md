# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- README, CHANGELOG, docs, and download site now accurately describe unsigned GitHub Release DMGs (#136)
- Local directory walk symlink cycle detection when `follow_symlinks` is enabled (#120)

## [v1.1.1] - 2026-07-24

### Added

- CycloneDX SBOM generation to CI and release

### Fixed

- Connection list ViewModel unit tests failing in CI (#197)

## [v1.1.0] - 2026-07-24

### Added

- Connect to host on double-click in sidebar
- Disconnect action in connection list context menu

### Fixed

- Sidebar green checkmark persisting after disconnect
- Zeroize SensitiveString internal buffer in place (#187)
- Re-validate local move before file operation to narrow TOCTOU (#191)
- Harden host-key timeout continuation handling (#190)
- Reject null bytes in remote path normalization (#182)
- Stop deleting keychain items on transient auth failure (#188)
- Normalize remote paths before passing to Rust bridge (#189)
- Reject malformed version tags in update checks (#186)
- Close TOCTOU window in FailIfExists download finalize (#185)
- Use constant-time comparison for host key fingerprints and hashes (#184)
- Validate HOME is absolute and reject `..` in `expand_tilde` (#183)
- Avoid deadlock and clarify result unwrap in DropOperationSync (#192)

## [1.0.7] - 2026-06-27

### Added

- Upgrade DMG code signature verification (#144)
- Sheet UI unified with DialogCard (#154)
- Directory walk resource limits (#142)
- Path bar visual polish, rounded corners and depth (#148)
- Connection and transfer status distinguishable beyond color (#146)
- Drag-and-drop target visual feedback (#153)
- Breadcrumb navigation visibility and accessibility (#149)
- Transfer queue header button hierarchy (#152)
- Empty state ContentUnavailableView in connection list (#150)
- Allow Clear All transfers without an active session (#140)

### Changed

- Remote file table Path column cleanup (#151)
- Toolbar and path bar duplicated actions consolidated (#145)
- Release CI disables CLI `--password` by default (#143)

### Fixed

- Remote directory walk rejects out-of-subtree and symlink entries (#141)
- Local directory walk symlink cycle detection and limits (#120)
- Clear transfer queue error message on disconnect (#137)
- `--password-stdin` read buffer zeroized (#134)
- known_hosts secure read: owner/permission validation, TOCTOU mitigation,
  negated host patterns, parent dir mode 0700, list error propagation, and
  stale bookmark notification (#113, #114, #115, #116, #117, #118, #122)
- OpenSSH 0644 accept test and relaxed known_hosts validation

## [0.1.6] - 2026-06-22

### Added

- AGENTS.md with Cursor Cloud dev environment instructions

### Changed

- Removed quarantine-removal install script from public release DMGs and the download site (release DMGs remain unsigned; see #136)

### Removed

- `DockBridgeをインストール.command` from release DMGs (dev-only helper moved to `scripts/dev-install-unsigned.command`)

### Fixed

- GitHub release asset download URL allowlist validation (#67)
- Connection profile metadata encryption at rest (#73)
- HMAC tamper detection for trusted_endpoints.json (#72)
- Shortened security-scoped bookmark access for private keys and known_hosts
- Drag-and-drop payload validation against displayed items and security scope
- Symlink-safe atomic known_hosts writes
- SFTP tree walk DoS prevention for `.` entries and cycles
- SFTP transfer overwrite policy and partial file safety (#70)
- Partial file cleanup on transfer failure (#69)

## [0.1.2] - 2026-06-18

### Added

- DMG helper script `DockBridgeをインストール.command` for one-click install, quarantine removal, and launch

## [0.1.1] - 2026-06-18

### Changed

- Distribution format switched from ZIP to DMG with Applications drag-and-drop shortcut

## [0.1.0] - 2026-06-18

### Added

- macOS SFTP client with two-pane local/remote file browser
- Connection profiles with Keychain-backed passwords and passphrases
- Private key authentication with security-scoped bookmarks
- Upload, download, delete, rename, and mkdir over SFTP
- Sequential transfer queue
- Host key fingerprint verification (SHA-256) on first connect
- GitHub Pages download site and automated GitHub Release packaging

### Notes

- Requires macOS 15 Sequoia or later
- Early releases are unsigned; see the download site for Gatekeeper instructions
- Developer ID signing and Apple Notarization are planned for v1.0

[v1.1.1]: https://github.com/T3pp31/DockBridge/releases/tag/v1.1.1
[v1.1.0]: https://github.com/T3pp31/DockBridge/releases/tag/v1.1.0
[1.0.7]: https://github.com/T3pp31/DockBridge/releases/tag/v1.0.7
[0.1.6]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.6
[0.1.2]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.2
[0.1.1]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.1
[0.1.0]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.0
