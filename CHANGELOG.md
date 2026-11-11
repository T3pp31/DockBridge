# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Resolve home directories with the platform-standard `dirs` API. On Windows,
  this intentionally uses the user profile known folder instead of honoring a
  custom `HOME` override.

### Fixed

- Disable Disconnect consistently in the connection toolbar and context menu while a connection is being established (#1224)
- Preserve entered credentials for the session when saving them to Keychain fails, and clarify that only the connection profile was saved (#1222)
- Preserve the existing private-key selection when bookmark creation fails during reselection (#1223)
- 新規セッションの接続失敗時に、最後に開いたセッションではなく直前のアクティブセッションへ戻るよう修正 (#1220)
- Keep Quick Look's presenter in a non-preview window's responder chain when updating an already focused preview panel (#1221)
- Local file and directory drag exports allow access to the original URL instead of staging a full copy (#1215)
- Avoid classifying unrelated `mismatch` errors as host key changes in macOS error messages (#1216)
- Report update presentation failures in Finder instead of returning success, with guidance to retry or download manually (#1217)
- Remote deletion in the macOS app now always requires confirmation; remove the
  opt-out setting and ignore previously saved disabled values (#1211).
- Accept local items dropped back onto the same local pane as a no-op instead of showing an invalid-move error (#1190)
- Local pane double-click fallback no longer navigates to `..` when it is part of a multiple selection; selecting only `..` still opens the parent directory (#1191)
- Keep prompted credentials in a clearable buffer until connection handoff, and clear it on rejected input or failed attempts (#1188)
- SFTP URL imports now use the saved profile list directly, avoiding stale UI state and duplicate profiles when a post-save reload would fail (#1186).
- リモートのリネームを名前の変更なしで確定した際、衝突エラーを出さずにシートを閉じるよう修正 (#1187)
- Wait for cancelled synchronous bridge operations to finish before reporting timeout, and dismiss cancelled authentication prompts (#1184)
- Prevent update disk image attach/detach from hanging when hdiutil emits more output than a pipe can buffer (#1180)
- 保存済みの接続プロファイル削除を、後続の信頼エントリ削除エラーで失敗と誤報告しないよう修正 (#1181)
- Reject local moves into self, the current parent, or descendants through symlinked ancestors while still allowing moves of symlinks themselves (#1178)
- Preserve local directory types via a separate file-system lookup when resource metadata is unreadable (#1179)
- Transfer results no longer fall back to stale Pending tasks when the queue is
  cleared concurrently (#1200).
- Zeroize private key file buffers on read/UTF-8 errors and buffer growth during
  algorithm inspection and authentication (#1199)
- Detect connection loss in doubly Debug-formatted SSH/SFTP errors without matching quoted filenames (#1167)
- Exclude keyboard-interactive user input time from the shared SSH/SFTP startup timeout (#1168).
- Preserve committed in-memory host trust when accepting a host key fails to save (#1228).
- Keep imported plain host trust separate from existing `@cert-authority` records
  for the same host and key, without changing CA scope (#1195)
- Preserve expanded aliases and exclusions when reimporting matching `@revoked` or
  `@cert-authority` known_hosts entries (#1159).
- Preserve `@revoked` and `@cert-authority` markers on hashed known_hosts entries during OpenSSH export (#1158)
- CLI `list --output json` now reports non-BrokenPipe write and flush failures instead of silently succeeding with truncated output (#1193).
- Avoid retaining stdin passwords and passphrases in an unzeroized read-ahead buffer (#1194)
- Omit unrepresentable transfer ETAs to prevent crashes at very low transfer speeds or large remaining byte counts (#1152).
- Clamp oversized UInt64 settings when saving on macOS to prevent integer conversion crashes (#1148)
- Use an operation-neutral message for remote read and unspecified permission-denied errors instead of incorrectly reporting missing write permissions (#1147).
- Distinguish download-site GitHub API rate limits and HTTP errors from network
  failures, and cache successful DMG links for up to one hour (#1239).
- Clear update-check ETags when the release-body cache is missing, unreadable, or corrupt (#1143)
- E2E verification now reports the saved debug log path only after a successful copy, rather than a deleted temporary path (#1171).
- Publish SBOM and checksum files with readable `0644` permissions instead of staging-only `0600` (#1172)
- Report keychain signing identity query failures separately from missing certificates and preserve `security` diagnostics (#1173)
- Clarify that the security baseline trusts stored hostname/IP aliases in default strict mode; fingerprint-only alias trust requires `known_hosts_strict_mode = false` (#1205).
- Stop AppIcon.icns generation when copying PNGs into staging fails (#1207)
- Development installer preflight checks only the parent directory and reports actual move failures (#1206)
- Download site now explains the Privacy & Security "Open Anyway" flow for blocked first launches on macOS 15+ instead of the obsolete right-click override (#1210)
- README, CHANGELOG, docs, and download site now accurately describe unsigned GitHub Release DMGs (#136)
- 外部ドロップで一部ファイルのセキュリティスコープを取得できなかった場合に、転送後も対象ファイル名を通知するよう修正 (#1189)
- Allow ExpandingFrame content to grow and shrink after measurement in scroll containers (#1185)
- Avoid mirroring unreadable local directories, repeated local symlink targets,
  and duplicate remote directory listing entries (#1166).

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

## [v1.0.7] - 2026-06-27

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
[v1.0.7]: https://github.com/T3pp31/DockBridge/releases/tag/v1.0.7
[0.1.6]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.6
[0.1.2]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.2
[0.1.1]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.1
[0.1.0]: https://github.com/T3pp31/DockBridge/releases/tag/v0.1.0
