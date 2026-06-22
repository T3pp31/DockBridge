# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.6] - 2026-06-22

### Added

- AGENTS.md with Cursor Cloud dev environment instructions

### Changed

- Release DMGs are Developer ID signed and notarized; CI verifies Gatekeeper acceptance before publishing
- Removed quarantine-removal install script from public release DMGs and the download site

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

[0.1.6]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.6
[0.1.2]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.2
[0.1.1]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.1
[0.1.0]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.0
