# DockBridge Test Quality Audit (2026-10-23 / Issue #839)

This document records the audit and remediation of all 58 findings (`F01`–`F58`) tracked in GitHub Issue #839 across the Swift macOS app (`apps/macos`), Rust crates (`crates/core`, `crates/cli`, `crates/uniffi`), vendored SFTP crate (`vendor/bssh-russh-sftp`), verification scripts (`scripts/`), and CI workflows (`.github/workflows/ci.yml`).

## Audit Summary

| Status on `main` prior to this PR | Count | Findings |
|---|---|---|
| Already resolved on `main` | 6 | F04, F17, F19, F21, F25, F49 |
| Remediated in this PR | 52 | F01–F03, F05–F16, F18, F20, F22–F24, F26–F48, F50–F58 |
| **Total** | **58** | **F01–F58** |

## Remediation by Workstream

### 1. Swift Production Seams & XCTest Suite (`F01`–`F26`)

- **F01 (View behavior vs pure static helper duplication)**: Extracted testable pure presentation/action logic (`HostKeyConfirmView.Presentation`, `RemotePaneSheets` confirmation/validation helpers) and asserted real View presentation state & callbacks in `HostKeyConfirmViewTests.swift` and `RemotePaneSheetsTests.swift`.
- **F02 (`AppSettingsServiceRobustnessTests`)**: Replaced `>= 0` and non-specific checks with exact clamping, round-trip persistence, and default fallback assertions against isolated `UserDefaults` suites.
- **F03 (`PathNavigationHistoryTests` & `FileTypeIcon`)**: Covered real `FileTypeIcon` production mapping (directories, symlinks, known extensions, case-insensitivity, unknown fallback) and full navigation history forward/back/truncate invariants.
- **F04**: Already resolved on `main` (SSH config parser & security-scoped bookmark coverage verified).
- **F05 (`ManualTestPlanVerificationTests`)**: Replaced loose existence-only assertions with concrete payload, error-type, and state-transition checks for manual verification flows.
- **F06 / F07 (`AppUpdateServiceTests`)**: Asserted exact release version selection, SHA-256 checksum asset matching, missing-asset / malformed-JSON error handling, and HTTP status error propagation.
- **F08 (`TransferProgressFormatterTests`)**: Asserted exact formatted byte/speed/ETA outputs across boundary values (`0`, sub-KiB, MiB/s, unknown totals, completion) without brittle locale-independent loose substring checks.
- **F09 / F10 / F11 (`FileDropAcceptanceTests`)**: Replaced placeholder/timing-sensitive drop assertions with deterministic temp-file fixtures, bounded subprocess probe checks (`testBoundedProbeKillsChildThatIgnoresSIGTERM`), and explicit reject/accept validation assertions.
- **F12 (`TransferQueueViewModel`, `MainViewModelTestabilityTests`, `vendor/bssh-russh-sftp`)**: Added deterministic cancel/completion/notification invariants in Swift (`TransferQueueNotificationTests.swift`, `MainViewModelTestabilityTests.swift`) and real unit tests in `vendor/bssh-russh-sftp/src/server/mod.rs` verifying protocol framing and error mapping.
- **F13 / F14 / F15 (`ManualTestPlanVerificationTests`)**: Separated environment/signing capability probes (`XCTSkip` with explicit reason when Docker SFTP or signed Keychain access is unavailable) from actual assertions, and forwarded `SFTP_CONTAINER` / `SFTP_HOST` / `SFTP_PORT` / `SFTP_USER` / `SFTP_PASSWORD` cleanly.
- **F16 (`KnownHostsErrorMessageTests`, `MainViewModelTestabilityTests`, `crates/core/src/security/known_hosts.rs`, `crates/core/src/sftp/client.rs`)**: Ensured corrupted/mismatched/unreadable `known_hosts` errors map to distinct, user-actionable localized diagnostics across Rust core and Swift UI.
- **F17 / F19 / F21 / F25**: Verified already resolved on `main`.
- **F18 (`UpdateCheckViewModel`, `UpdateCheckViewModelTests`)**: Injected `inAppUpdateInstallationEnabled` and `openURL` seams into `UpdateCheckViewModel` so both in-app signature-verification failure and browser-fallback branches run unconditionally in unit tests regardless of build signing configuration.
- **F20 / F23 (`TransferQueueViewModel`, `TransferQueueNotificationTests`)**: Added exact assertion coverage for transfer notification suppression/delivery, status transitions, and cancellation state cleanup.
- **F22 (`MainViewModelTestabilityTests`)**: Added behavioral tests for remote edit recovery, partial failure selection preservation, and disconnect/upload guards.
- **F24 / F26 (`ConnectionListViewModelTests`)**: Strengthened `testConfirmInitialTrustSeedsTrustStore` to verify persisted `ProfileTrustStore` entries, cleared `pendingInitialTrust`, and fresh-VM reload without re-prompting; tightened credential prompt & profile persistence assertions.

### 2. Rust Core, CLI, UniFFI & Vendored SFTP (`F27`–`F48`, `F58`)

- **F27 / F28 (`crates/cli/src/password.rs`)**: Added tests for TTY/stdin password reading, empty/whitespace handling, trailing newline stripping, and `--features disable-cli-password` build/test coverage.
- **F29 (`crates/core/src/config.rs`)**: Added strict boundary and `deny_unknown_fields` deserialization tests for `AppConfig` (chunk size clamping/rejection, pipeline depths, walk limits, unknown field rejection).
- **F30 (`crates/core/tests/sftp_path_security.rs`, `crates/core/src/sftp/test_server.rs`, `crates/core/src/sftp/client.rs`)**: Hardened symlink/traversal/path-normalization security tests against the real in-process SFTP server rather than string-only helpers.
- **F31 (`crates/core/src/ssh/algorithm_policy.rs`)**: Added unit tests exercising real SSH algorithm negotiation & policy rejection paths.
- **F32 (`crates/core/src/config.rs`, `crates/uniffi/src/lib.rs`)**: Verified `AppConfig` transfer chunk size clamping (`< MIN`), exact boundary acceptance (`MIN`, `MAX`), and rejection (`> MAX`) directly through the UniFFI `DockBridgeClient::new` FFI boundary.
- **F33 / F34 / F35 (`crates/core/src/transfer/manager.rs`, `crates/core/src/sftp/tree.rs`, `crates/core/src/sftp/client.rs`, `crates/core/src/sftp/test_server.rs`)**: Added deterministic tests for transfer queue concurrency, retry/cancellation transitions, directory-walk safety limits (max files, max depth, max total bytes), and pause/error injection hooks.
- **F36–F39 (`crates/core/src/security/known_hosts.rs`, `crates/core/src/sftp/client.rs`)**: Strengthened known-hosts parsing, OpenSSH merge failure handling, host-key mismatch rejection, atomic writes, and permission enforcement tests.
- **F40–F48, F58 (`crates/core/src/sftp/client.rs`, `crates/core/src/sftp/test_server.rs`)**:
  - Verified out-of-order pipelined SFTP `READ` response reassembly over a real duplex SFTP framing stream.
  - Removed test-only helper bypass (`partial_remote_path_for_suffix`) and exercised real resume/symlink/TOCTOU handle validation and atomic partial-file cleanup.
  - Covered real OpenSSH `sftp-server` `posix-rename@openssh.com` replacement semantics via `openssh_sftp_server_replaces_existing_file_via_posix_rename` (`#[ignore]`-gated for environments with `sftp-server`).

### 3. Verification Scripts & CI (`F49`–`F57`)

- **F49 (`scripts/e2e-verify.sh`)**: Already resolved on `main` (`check()` explicit return propagation tested by `scripts/test-e2e-verify.py`).
- **F50 (`scripts/e2e-verify.sh`, `scripts/test-e2e-verify.py`)**: Scoped remote paths with per-run `RUN_ID`, replaced fixed `sleep 3` with container `sshd` readiness polling, tightened `pwd_command` to assert exact canonical `/` or `/home/$USER`, stopped discarding CLI output with `>/dev/null`, and added `.xcresult` count validation for `swift_corrupted_known_hosts_message`.
- **F51 (`scripts/verify-transfer-cancel.sh`, `scripts/test-verify-transfer-cancel.py`)**: Exported `SFTP_*` and `TEST_RUNNER_SFTP_*` to `xcodebuild` and required `totalTestCount >= 1`, `passedTests >= 1`, `skippedTests == 0`, and `failedTests == 0`.
- **F52–F55 (`scripts/verify-update-popup.sh`, `scripts/test-verify-update-popup.py`)**:
  - Propagated `osascript` exit codes/stderr immediately instead of masking Accessibility denial as timeout (`F52`).
  - Added `UPDATE_API_FIXTURE_JSON` / `EXPECTED_RELEASE_URL` / `EXPECTED_ASSET_URL` overrides (`F53`).
  - Replaced broken selector `testSkipUpdatePersistsSkippedVersionAndSuppressesRelaunch` with real `testLaterDismissesWithoutPersistingSkip` and `testSkipVersionPersistsSkippedVersionAndSuppressesRelaunch`, and enforced `.xcresult` count verification via `run_xctest_case` (`F54`).
  - Added AX main-window responsiveness check, `"update check failed on launch:"` unified-log verification, and explicit skipped-check summary count (`F55`).
- **F56 (`scripts/verify-localization.sh`, `scripts/test-verify-localization.py`)**: Narrowed success output to accurately state the verified scope (catalog `en`+`ja`, format specifiers, and explicit `String(localized:)` literals; excluding implicit SwiftUI `Text`/`Button` keys).
- **F57 (`.github/workflows/ci.yml`, `docs/ci.md`)**: Wired `cargo test -p bssh-russh-sftp --lib`, `cargo test -p dockbridge-cli --features disable-cli-password`, `python3 scripts/test-verify-update-popup.py`, and post-test macOS `.xcresult` count verification into CI, and documented suite execution boundaries in `docs/ci.md`.

## Remaining Capability-Gated Boundaries

The following checks intentionally remain gated on host capabilities and report explicit `XCTSkip` / `SKIP` rather than false passes when prerequisites are absent:

1. **Docker SFTP E2E (`ManualTestPlanVerificationTests`, `scripts/e2e-verify.sh`, `scripts/verify-transfer-cancel.sh`)**: Requires Docker daemon and a reachable SFTP container (`SFTP_HOST`/`SFTP_PORT`).
2. **Signed macOS Keychain & App Sandbox (`ManualTestPlanVerificationTests.testProductionKeychainSaveAndLoad`, `scripts/verify-update-popup.sh`)**: Requires a signed app bundle / Accessibility permission / passwordless `sudo pfctl` for live offline firewall testing.
3. **Host OpenSSH `sftp-server` (`openssh_sftp_server_replaces_existing_file_via_posix_rename`)**: `#[ignore]`-gated so environments without `/usr/libexec/sftp-server` are not broken; run explicitly with `-- --ignored`.

## Verification Commands

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
cargo test -p dockbridge-cli --features disable-cli-password
cargo test -p bssh-russh-sftp --lib
cargo test -p dockbridge-core --lib openssh_sftp_server_replaces_existing_file_via_posix_rename -- --ignored
shellcheck -x scripts/*.sh
for t in scripts/test-*.py; do python3 "$t" || exit 1; done
node --test scripts/test-website-download.cjs
./scripts/verify-localization.sh
(cd apps/macos && xcodebuild -scheme DockBridge -destination 'platform=macOS' -configuration Debug CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM='' test)
```

See [docs/test-ledger-2026-10-23.md](test-ledger-2026-10-23.md) for the finding-by-finding ledger covering `F01` through `F58`.
