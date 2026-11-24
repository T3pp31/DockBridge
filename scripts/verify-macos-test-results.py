#!/usr/bin/env python3
"""Verify macOS XCTest result counts and enforce the skipped-test allowlist (#1435).

Invoked by `.github/actions/run-macos-tests/action.yml` after
`xcodebuild test-without-building` succeeds. Fails CI if:
  - no `.xcresult` bundle is found,
  - `failedTests != 0`, `totalTestCount < 1`, or `passedTests < min_passed`,
  - `test-results tests` skipped count disagrees with `test-results summary`, or
  - any skipped test is not in `ALLOWED_SKIPPED_TESTS`.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import pathlib
import subprocess
import sys
from typing import Any, Iterable, List, Optional, Sequence, Set, Tuple

# Minimum number of passing non-E2E unit tests expected in a full macOS test run
# (584+ unit tests currently run on CI; this floor catches accidental filter or
# scheme truncation while leaving headroom for legitimate test consolidation).
DEFAULT_MIN_PASSED_TESTS = 100

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


def normalize_test_identifier(raw: str) -> str:
    identifier = raw.strip()
    if identifier.endswith("()"):
        identifier = identifier[:-2]
    return identifier


def find_latest_xcresult(pattern: str = "/tmp/xcodebuild-test-attempt-*.xcresult") -> Optional[pathlib.Path]:
    candidates = [
        pathlib.Path(path)
        for path in glob.glob(pattern)
        if os.path.isdir(path)
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
    return candidates[0]


def run_xcresulttool(subcommand: str, xcresult: pathlib.Path) -> dict[str, Any]:
    proc = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            subcommand,
            "--path",
            str(xcresult),
            "--format",
            "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
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


def _require_non_negative_int(summary: dict[str, Any], key: str) -> int:
    value = summary.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RuntimeError(f"Missing or invalid integer field {key!r} in xcresult summary: {value!r}")
    return value


def extract_skipped_tests(tests_payload: dict[str, Any]) -> List[Tuple[str, str]]:
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

            if node_type == "Test Case" and node.get("result") == "Skipped":
                raw_id = node.get("nodeIdentifier")
                if not isinstance(raw_id, str) or not raw_id.strip():
                    name = node.get("name")
                    if isinstance(name, str) and name.strip():
                        raw_id = f"{suite}/{name}" if suite else name
                    else:
                        raw_id = "<unknown>"
                reason = ""
                for child in node.get("children") or ():
                    if isinstance(child, dict) and child.get("nodeType") == "Failure Message":
                        msg = child.get("name")
                        if isinstance(msg, str) and msg.strip():
                            reason = msg.strip()
                            break
                skipped.append((normalize_test_identifier(raw_id), reason))

            children = node.get("children")
            if isinstance(children, list):
                walk(children, suite)

    root_nodes = tests_payload.get("testNodes")
    if not isinstance(root_nodes, list):
        raise RuntimeError("Missing or invalid 'testNodes' array in xcresult test-results tests JSON")
    walk(root_nodes, None)
    return skipped


def verify_results(
    summary: dict[str, Any],
    tests_payload: dict[str, Any],
    *,
    min_passed: int = DEFAULT_MIN_PASSED_TESTS,
    allowed_skipped: Set[str] | frozenset[str] = ALLOWED_SKIPPED_TESTS,
) -> List[str]:
    """Validate summary counts and skipped test allowlist. Returns a list of error strings."""
    errors: List[str] = []
    total = _require_non_negative_int(summary, "totalTestCount")
    passed = _require_non_negative_int(summary, "passedTests")
    skipped = _require_non_negative_int(summary, "skippedTests")
    failed = _require_non_negative_int(summary, "failedTests")

    if total < 1 or passed < 1 or failed != 0:
        errors.append(
            f"Unexpected macOS test counts (total={total}, passed={passed}, skipped={skipped}, failed={failed})"
        )
    elif passed < min_passed:
        errors.append(
            f"Too few macOS tests passed (passed={passed} < min_passed={min_passed}; total={total}, skipped={skipped})"
        )

    skipped_cases = extract_skipped_tests(tests_payload)
    if len(skipped_cases) != skipped:
        errors.append(
            f"Skipped test count mismatch: summary reported {skipped}, "
            f"but test tree contained {len(skipped_cases)} skipped test case(s)"
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
        print("::error::--min-passed must be >= 1", file=sys.stderr)
        return 1

    xcresult = args.xcresult if args.xcresult is not None else find_latest_xcresult()
    if xcresult is None or not xcresult.is_dir():
        print("::error::No .xcresult bundle found after Test macOS app")
        return 1

    try:
        summary = run_xcresulttool("summary", xcresult)
        tests_payload = run_xcresulttool("tests", xcresult)
        total = _require_non_negative_int(summary, "totalTestCount")
        passed = _require_non_negative_int(summary, "passedTests")
        skipped = _require_non_negative_int(summary, "skippedTests")
        failed = _require_non_negative_int(summary, "failedTests")
        print(
            f"macOS test summary: total={total}, passed={passed}, skipped={skipped}, failed={failed}"
        )
        errors = verify_results(summary, tests_payload, min_passed=args.min_passed)
    except RuntimeError as exc:
        print(f"::error::{exc}")
        return 1

    if errors:
        for err in errors:
            print(f"::error::{err}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
