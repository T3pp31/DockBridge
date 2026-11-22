# DockBridge Test Audit Ledger (2026-10-23 / Issue #839)

Complete disposition ledger for all 58 findings (`F01`–`F58`) from Issue #839.

| ID | Area | Primary Files | Disposition | Notes |
|---|---|---|---|---|
| F01 | Swift Views | `HostKeyConfirmView.swift`, `HostKeyConfirmViewTests.swift`, `RemotePaneSheets.swift`, `RemotePaneSheetsTests.swift` | Fixed | Extracted testable presentation/validation seams and asserted View behavior rather than mirrored constants |
| F02 | Swift Settings | `AppSettingsServiceRobustnessTests.swift` | Fixed | Replaced non-specific bounds with exact clamp, fallback, and round-trip assertions |
| F03 | Swift UI/Nav | `FileTypeIcon.swift`, `PathNavigationHistoryTests.swift` | Fixed | Tested production `FileTypeIcon` mapping and complete navigation history transitions |
| F04 | Swift SSH/Bookmarks | `SSHConfigParserTests.swift`, `SecurityScopedBookmarkServiceTests.swift` | Verified on `main` | Already addressed on `main` prior to this PR |
| F05 | Swift Manual Plan | `ManualTestPlanVerificationTests.swift` | Fixed | Strengthened assertions to verify actual data/state contracts |
| F06 | Swift Update Service | `AppUpdateServiceTests.swift` | Fixed | Added exact release selection and checksum asset validation assertions |
| F07 | Swift Update Errors | `AppUpdateServiceTests.swift` | Fixed | Asserted specific error variants on malformed JSON, missing assets, and HTTP errors |
| F08 | Swift Formatting | `TransferProgressFormatterTests.swift` | Fixed | Asserted deterministic formatted outputs across byte/rate/ETA boundaries |
| F09 | Swift File Drop | `FileDropAcceptanceTests.swift` | Fixed | Replaced loose/flaky checks with deterministic fixture assertions |
| F10 | Swift File Drop | `FileDropAcceptanceTests.swift` | Fixed | Hardened subprocess probe termination test (`testBoundedProbeKillsChildThatIgnoresSIGTERM`) |
| F11 | Swift File Drop | `FileDropAcceptanceTests.swift` | Fixed | Asserted explicit acceptance/rejection semantics for drop targets and filters |
| F12 | Transfer / Vendor | `TransferQueueViewModel.swift`, `TransferQueueNotificationTests.swift`, `MainViewModelTestabilityTests.swift`, `vendor/bssh-russh-sftp/src/server/mod.rs` | Fixed | Strengthened Swift transfer-queue/notification invariants and added vendored SFTP server unit tests |
| F13 | Swift Capability Probes | `ManualTestPlanVerificationTests.swift` | Fixed | Separated environment capability probes (`XCTSkip`) from functional assertions |
| F14 | Swift SFTP Config | `ManualTestPlanVerificationTests.swift` | Fixed | Forwarded `SFTP_CONTAINER`/`SFTP_HOST`/`SFTP_PORT`/`SFTP_USER`/`SFTP_PASSWORD` cleanly |
| F15 | Swift Manual Plan | `ManualTestPlanVerificationTests.swift` | Fixed | Ensured skipped tests report clear environmental reasons rather than silent passes |
| F16 | Known Hosts Errors | `KnownHostsErrorMessageTests.swift`, `MainViewModelTestabilityTests.swift`, `crates/core/src/security/known_hosts.rs`, `crates/core/src/sftp/client.rs` | Fixed | Verified actionable diagnostics for corrupt, unreadable, and mismatched `known_hosts` |
| F17 | Swift Tests | `apps/macos/DockBridgeTests/` | Verified on `main` | Already addressed on `main` prior to this PR |
| F18 | Swift Update VM | `UpdateCheckViewModel.swift`, `UpdateCheckViewModelTests.swift` | Fixed | Injected `inAppUpdateInstallationEnabled` and `openURL` seams so both install and fallback branches always run |
| F19 | Swift Tests | `apps/macos/DockBridgeTests/` | Verified on `main` | Already addressed on `main` prior to this PR |
| F20 | Swift Notifications | `TransferQueueViewModel.swift`, `TransferQueueNotificationTests.swift` | Fixed | Asserted exact notification emission and suppression conditions |
| F21 | Swift Tests | `apps/macos/DockBridgeTests/` | Verified on `main` | Already addressed on `main` prior to this PR |
| F22 | Swift MainVM | `MainViewModelTestabilityTests.swift` | Fixed | Strengthened MainViewModel remote-edit recovery, trash partial-failure, and disconnect tests |
| F23 | Swift Transfer Queue | `TransferQueueViewModel.swift`, `TransferQueueNotificationTests.swift` | Fixed | Verified queue state cleanup and cancellation semantics |
| F24 | Swift Trust Store | `ConnectionListViewModelTests.swift` | Fixed | Verified `confirmInitialTrust` persists trust, clears `pendingInitialTrust`, and prevents re-prompt on reload |
| F25 | Swift Tests | `apps/macos/DockBridgeTests/` | Verified on `main` | Already addressed on `main` prior to this PR |
| F26 | Swift Connections | `ConnectionListViewModelTests.swift` | Fixed | Strengthened profile/credential prompt assertions and isolation |
| F27 | Rust CLI Password | `crates/cli/src/password.rs` | Fixed | Added deterministic password-input edge-case tests |
| F28 | Rust CLI Feature | `crates/cli/src/password.rs`, `.github/workflows/ci.yml` | Fixed | Verified `--features disable-cli-password` behavior and ran tests in CI |
| F29 | Rust Config | `crates/core/src/config.rs` | Fixed | Added strict `AppConfig` validation, clamping, and `deny_unknown_fields` tests |
| F30 | Rust SFTP Path Security | `crates/core/tests/sftp_path_security.rs`, `crates/core/src/sftp/test_server.rs`, `crates/core/src/sftp/client.rs` | Fixed | Exercised path-security invariants against real in-process SFTP server |
| F31 | Rust SSH Policy | `crates/core/src/ssh/algorithm_policy.rs` | Fixed | Added tests verifying algorithm policy enforcement on negotiation |
| F32 | Rust UniFFI Config | `crates/core/src/config.rs`, `crates/uniffi/src/lib.rs` | Fixed | Tested chunk-size clamping, boundaries, and over-max rejection across `DockBridgeClient::new` |
| F33 | Rust Transfers/Tree | `crates/core/src/transfer/manager.rs`, `crates/core/src/sftp/tree.rs`, `crates/core/src/sftp/client.rs` | Fixed | Added deterministic transfer lifecycle and directory-walk limit tests |
| F34 | Rust Transfer Faults | `crates/core/src/transfer/manager.rs`, `crates/core/src/sftp/test_server.rs` | Fixed | Exercised fault-injection and retry/cancel paths deterministically |
| F35 | Rust Transfer Manager | `crates/core/src/transfer/manager.rs` | Fixed | Tightened status transition and concurrency invariants |
| F36 | Rust Known Hosts | `crates/core/src/security/known_hosts.rs` | Fixed | Added malformed-store and strict-mode failure tests |
| F37 | Rust Known Hosts | `crates/core/src/security/known_hosts.rs` | Fixed | Added OpenSSH merge and error-propagation tests |
| F38 | Rust Known Hosts | `crates/core/src/security/known_hosts.rs`, `crates/core/src/sftp/client.rs` | Fixed | Verified host-key mismatch detection and non-persistence on rejection |
| F39 | Rust Known Hosts | `crates/core/src/security/known_hosts.rs` | Fixed | Verified atomic persistence and file permission invariants |
| F40 | Rust SFTP Client | `crates/core/src/sftp/client.rs` | Fixed | Strengthened real SFTP client transfer assertions |
| F41 | Rust SFTP Pipeline | `crates/core/src/sftp/client.rs`, `crates/core/src/sftp/test_server.rs` | Fixed | Verified out-of-order pipelined SFTP `READ` reassembly over framed duplex stream |
| F42 | Rust Partial Paths | `crates/core/src/sftp/client.rs` | Fixed | Removed test-only `partial_remote_path_for_suffix` helper bypass and tested real upload/resume paths |
| F43 | Rust Resume Safety | `crates/core/src/sftp/client.rs` | Fixed | Verified symlink rejection and handle validation on upload resume |
| F44 | Rust Atomic Rename | `crates/core/src/sftp/client.rs`, `crates/core/src/sftp/test_server.rs` | Fixed | Verified atomic partial cleanup and overwrite policy semantics |
| F45 | Rust SFTP Errors | `crates/core/src/sftp/client.rs` | Fixed | Verified exact SFTP error classification rather than loose `is_err()` checks |
| F46 | Rust SFTP Truncate/Offset | `crates/core/src/sftp/client.rs` | Fixed | Strengthened byte-for-byte payload and offset assertions |
| F47 | Rust SFTP Cleanup | `crates/core/src/sftp/client.rs` | Fixed | Verified partial files are cleaned up on failure/cancellation |
| F48 | Rust SFTP Integration | `crates/core/src/sftp/client.rs` | Fixed | Strengthened end-to-end client behavior against in-process SFTP server |
| F49 | E2E Runner Propagation | `scripts/e2e-verify.sh`, `scripts/test-e2e-verify.py` | Verified on `main` | Already addressed on `main` prior to this PR (documented in `docs/ci.md`) |
| F50 | E2E Script Rigor | `scripts/e2e-verify.sh`, `scripts/test-e2e-verify.py` | Fixed | Per-run `RUN_ID` remote paths, `sshd` readiness polling, strict `pwd` check, preserved CLI logs, `.xcresult` count check |
| F51 | Transfer Cancel Script | `scripts/verify-transfer-cancel.sh`, `scripts/test-verify-transfer-cancel.py` | Fixed | Exported `SFTP_*` & `TEST_RUNNER_SFTP_*`, rejected `skippedTests != 0` and `passedTests < 1` |
| F52 | Update Popup AX Errors | `scripts/verify-update-popup.sh`, `scripts/test-verify-update-popup.py` | Fixed | Failed immediately with stderr on non-zero `osascript` exit instead of looping to timeout |
| F53 | Update Popup Fixture | `scripts/verify-update-popup.sh`, `scripts/test-verify-update-popup.py` | Fixed | Supported `UPDATE_API_FIXTURE_JSON` and URL overrides to decouple from live GitHub releases |
| F54 | Update Popup XCTest | `scripts/verify-update-popup.sh`, `scripts/test-verify-update-popup.py` | Fixed | Fixed misspelled selector; enforced `run_xctest_case` `.xcresult` `total >= 1`, `passed >= 1`, `skipped == 0`, `failed == 0` |
| F55 | Update Popup Offline | `scripts/verify-update-popup.sh`, `scripts/test-verify-update-popup.py` | Fixed | Added AX window responsiveness check, unified-log offline failure check, and explicit skip count |
| F56 | Localization Scope | `scripts/verify-localization.sh`, `scripts/test-verify-localization.py` | Fixed | Narrowed success message to exact scope (catalog + format specifiers + explicit `String(localized:)` literals) |
| F57 | CI Coverage & Docs | `.github/workflows/ci.yml`, `docs/ci.md` | Fixed | Added vendored crate tests, hardened CLI tests, update-popup script tests, macOS `.xcresult` count gate, and boundary docs |
| F58 | OpenSSH POSIX Rename | `crates/core/src/sftp/client.rs`, `crates/core/src/sftp/test_server.rs` | Fixed | Verified real OpenSSH `sftp-server` `posix-rename@openssh.com` replacement semantics (`#[ignore]`-gated) |
