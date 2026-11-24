#!/usr/bin/env python3
"""Verify macOS XCTest result counts and enforce the skipped-test allowlist (#1435).

Invoked by `.github/actions/run-macos-tests/action.yml` after
`xcodebuild test-without-building` succeeds. Fails CI if:
  - no `.xcresult` bundle is found,
  - `failedTests != 0`, `expectedFailures != 0`, `totalTestCount < 1`, or
    `passedTests < min_passed`,
  - `passedTests + skippedTests + failedTests + expectedFailures != totalTestCount`,
  - `test-results tests` skipped count disagrees with `test-results summary`
    or contains duplicate skipped test identifiers, or
  - any skipped test is not in `ALLOWED_SKIPPED_TESTS`.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import pathlib
import re
import subprocess
from typing import AbstractSet, Any, Dict, Iterable, List, Optional, Sequence, Tuple

# Minimum number of passing non-E2E unit tests expected in a full macOS test run
# (584+ unit tests currently run on CI; this floor catches accidental filter or
# scheme truncation while leaving headroom for legitimate test consolidation).
DEFAULT_MIN_PASSED_TESTS = 100
XCRESULTTOOL_TIMEOUT_SECS = 60

# Canonical `<TestClass>/<testMethod>` identifiers (without trailing `()`) that
# are expected to call `XCTSkip` on unsigned GitHub Actions `macos-15` runners.
# Keep this list tight: any other `XCTSkip` fails CI so test regressions cannot
# be hidden behind skips.
ALLOWED_SKIPPED_TESTS: frozenset[str] = frozenset(
    {
        # Docker SFTP E2E tests (no Docker daemon on GitHub macOS runners)
        "FileDropAcceptanceTests/testRemoteDownloadAcceptsOnSuccess",
        "FileDropAcceptanceTests/testRemoteMoveAcceptsOnSuccess",
        "FileDropAcceptanceTests/testUploadToReadOnlyRemoteDirectoryRejectsDrop",
        "FileDropAcceptanceTests/testUploadToWritableRemoteDirectoryAcceptsDrop",
        "ManualTestPlanVerificationTests/testCancelInProgressLargeFileUpload",
        "ManualTestPlanVerificationTests/testCancelOverwriteUploadPreservesOriginalFile",
        "ManualTestPlanVerificationTests/testConnectShowsConnectedStatusAndListsRemoteDirectory",
        "ManualTestPlanVerificationTests/testDisconnectsWithinHealthCheckIntervalAfterSshdKill",
        "ManualTestPlanVerificationTests/testTransferQueueDoesNotRetainStaleTasksAfterDisconnect",
        "ManualTestPlanVerificationTests/testUnknownHostFirstConnectionShowsPromptAndContinuesAfterAccept",
        "ManualTestPlanVerificationTests/testUnknownHostPromptTimesOutAndRejectsConnection",
        "ManualTestPlanVerificationTests/testUploadToValidRemoteDirectory",
        # Data Protection Keychain tests (require a signed, entitled test host)
        "ManualTestPlanVerificationTests/testProductionKeychainSaveAndLoad",
        "ProfileTrustStoreTests/testDataProtectionKeychainIntegrationWhenEntitled",
        # Case-sensitive APFS test (standard macOS runner volume is case-insensitive)
        "FileDropValidationTests/testLocalListingOrdersCaseOnlyCollisionsByRawName",
    }
)


def emit_error(message: str) -> None:
    """Emit a GitHub Actions `::error::` annotation safely escaped on stdout."""
    escaped = (
        message.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )
    print(f"::error::{escaped}")


def normalize_test_identifier(raw: str) -> str:
    identifier = raw.strip()
    if identifier.endswith("()"):
        identifier = identifier[:-2]
    return identifier


def _attempt_sort_key(path: pathlib.Path) -> Tuple[int, int, str]:
    try:
        mtime_ns = path.stat().st_mtime_ns
    except OSError:
        mtime_ns = -1
    match = re.search(r"(\d+)(?=\.xcresult$)", path.name)
    attempt_num = int(match.group(1)) if match else -1
    return (mtime_ns, attempt_num, path.name)


def find_latest_xcresult(pattern: str = "/tmp/xcodebuild-test-attempt-*.xcresult") -> Optional[pathlib.Path]:
    candidates: List[pathlib.Path] = []
    for raw_path in glob.glob(pattern):
        # Ignore symlinks in world-writable /tmp and plain files.
        if os.path.islink(raw_path) or not os.path.isdir(raw_path):
            continue
        candidates.append(pathlib.Path(raw_path))
    if not candidates:
        return None
    candidates.sort(key=_attempt_sort_key, reverse=True)
    return candidates[0]


def run_xcresulttool(subcommand: str, xcresult: pathlib.Path) -> Dict[str, Any]:
    try:
        proc = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                subcommand,
                "--path",
                str(xcresult),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=XCRESULTTOOL_TIMEOUT_SECS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"xcresulttool get test-results {subcommand} timed out after {XCRESULTTOOL_TIMEOUT_SECS}s"
        ) from exc
    except OSError as exc:
        raise RuntimeError(
            f"Failed to execute xcrun xcresulttool get test-results {subcommand}: {exc}"
        ) from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise RuntimeError(
            f"xcresulttool get test-results {subcommand} failed (exit {proc.returncode}): {detail}"
        )
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON from xcresulttool {subcommand}: {exc}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected JSON object from xcresulttool {subcommand}")
    return payload


def _require_non_negative_int(summary: Dict[str, Any], key: str) -> int:
    value = summary.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RuntimeError(f"Missing or invalid integer field {key!r} in xcresult summary: {value!r}")
    return value


def parse_summary_counts(summary: Dict[str, Any]) -> Tuple[int, int, int, int, int]:
    """Return `(total, passed, skipped, failed, expected_failures)` from summary JSON."""
    return (
        _require_non_negative_int(summary, "totalTestCount"),
        _require_non_negative_int(summary, "passedTests"),
        _require_non_negative_int(summary, "skippedTests"),
        _require_non_negative_int(summary, "failedTests"),
        _require_non_negative_int(summary, "expectedFailures"),
    )


def extract_skipped_tests(tests_payload: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Return `(normalized_identifier, reason)` for every skipped Test Case node."""
    skipped: List[Tuple[str, str]] = []

    def walk(nodes: Iterable[Any], current_suite: Optional[str]) -> None:
        for node in nodes:
            if not isinstance(node, dict):
                continue
            node_type = node.get("nodeType")
            suite = current_suite
            if node_type == "Test Suite" and isinstance(node.get("name"), str):
                suite = node["name"]

            children = node.get("children")
            child_list = children if isinstance(children, list) else []

            if node_type == "Test Case" and node.get("result") == "Skipped":
                raw_id = node.get("nodeIdentifier")
                if not isinstance(raw_id, str) or not raw_id.strip():
                    name = node.get("name")
                    if isinstance(name, str) and name.strip():
                        raw_id = f"{suite}/{name}" if suite else name
                    else:
                        raw_id = "<unknown>"
                reason = ""
                for child in child_list:
                    if isinstance(child, dict) and child.get("nodeType") == "Failure Message":
                        msg = child.get("name")
                        if isinstance(msg, str) and msg.strip():
                            reason = msg.strip()
                            break
                skipped.append((normalize_test_identifier(raw_id), reason))

            if child_list:
                walk(child_list, suite)

    root_nodes = tests_payload.get("testNodes")
    if not isinstance(root_nodes, list):
        raise RuntimeError("Missing or invalid 'testNodes' array in xcresult test-results tests JSON")
    walk(root_nodes, None)
    return skipped


def verify_results(
    summary: Dict[str, Any],
    tests_payload: Dict[str, Any],
    *,
    min_passed: int = DEFAULT_MIN_PASSED_TESTS,
    allowed_skipped: AbstractSet[str] = ALLOWED_SKIPPED_TESTS,
) -> List[str]:
    """Validate summary counts and skipped test allowlist. Returns a list of error strings."""
    errors: List[str] = []
    total, passed, skipped, failed, expected_failures = parse_summary_counts(summary)

    if total < 1 or passed < 1 or failed != 0 or expected_failures != 0:
        errors.append(
            "Unexpected macOS test counts "
            f"(total={total}, passed={passed}, skipped={skipped}, "
            f"failed={failed}, expected_failures={expected_failures})"
        )
    elif passed < min_passed:
        errors.append(
            f"Too few macOS tests passed (passed={passed} < min_passed={min_passed}; "
            f"total={total}, skipped={skipped})"
        )

    accounted = passed + skipped + failed + expected_failures
    if accounted != total:
        errors.append(
            f"Unaccounted macOS tests: total={total}, but "
            f"passed({passed}) + skipped({skipped}) + failed({failed}) "
            f"+ expected_failures({expected_failures}) = {accounted}"
        )

    skipped_cases = extract_skipped_tests(tests_payload)
    if len(skipped_cases) != skipped:
        errors.append(
            f"Skipped test count mismatch: summary reported {skipped}, "
            f"but test tree contained {len(skipped_cases)} skipped test case(s)"
        )

    seen_skipped: set[str] = set()
    duplicates: List[str] = []
    for test_id, _ in skipped_cases:
        if test_id in seen_skipped and test_id not in duplicates:
            duplicates.append(test_id)
        seen_skipped.add(test_id)
    if duplicates:
        errors.append(
            f"Duplicate skipped macOS test identifier(s): {', '.join(duplicates)}"
        )

    normalized_allowed = {normalize_test_identifier(item) for item in allowed_skipped}
    unexpected = [
        (test_id, reason)
        for test_id, reason in skipped_cases
        if test_id not in normalized_allowed
    ]
    if unexpected:
        details = "; ".join(
            f"{test_id} ({reason})" if reason else test_id
            for test_id, reason in unexpected
        )
        errors.append(
            f"Unexpected skipped macOS test(s) ({len(unexpected)} not in allowlist): {details}"
        )

    return errors


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--xcresult",
        type=pathlib.Path,
        help="Path to an .xcresult bundle (defaults to newest /tmp/xcodebuild-test-attempt-*.xcresult)",
    )
    parser.add_argument(
        "--min-passed",
        type=int,
        default=DEFAULT_MIN_PASSED_TESTS,
        help=f"Minimum required passing test count (default: {DEFAULT_MIN_PASSED_TESTS})",
    )
    args = parser.parse_args(argv)

    if args.min_passed < 1:
        emit_error("--min-passed must be >= 1")
        return 1

    try:
        if args.xcresult is not None:
            xcresult = args.xcresult
            if not xcresult.is_dir():
                emit_error(f"Specified .xcresult bundle not found: {xcresult}")
                return 1
        else:
            xcresult = find_latest_xcresult()
            if xcresult is None or not xcresult.is_dir():
                emit_error("No .xcresult bundle found after Test macOS app")
                return 1

        summary = run_xcresulttool("summary", xcresult)
        total, passed, skipped, failed, expected_failures = parse_summary_counts(summary)
        print(
            f"macOS test summary: total={total}, passed={passed}, skipped={skipped}, "
            f"failed={failed}, expected_failures={expected_failures}"
        )
        tests_payload = run_xcresulttool("tests", xcresult)
        errors = verify_results(summary, tests_payload, min_passed=args.min_passed)
    except RuntimeError as exc:
        emit_error(str(exc))
        return 1

    if errors:
        for err in errors:
            emit_error(err)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
