# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Release DMGs are Developer ID signed and notarized; CI verifies Gatekeeper acceptance before publishing
- Removed quarantine-removal install script from public release DMGs and the download site

### Removed

- `DockBridgeをインストール.command` from release DMGs (dev-only helper moved to `scripts/dev-install-unsigned.command`)

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

[0.1.2]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.2
[0.1.1]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.1
[0.1.0]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.0
