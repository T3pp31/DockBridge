#!/usr/bin/env python3
"""Unit tests for scripts/verify-macos-test-results.py (#1435)."""
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import typing
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-macos-test-results.py"
MACOS_TESTS_DIR = ROOT / "apps" / "macos" / "DockBridgeTests"
RUN_MACOS_TESTS_ACTION = ROOT / ".github" / "actions" / "run-macos-tests" / "action.yml"


def load_module():
    spec = importlib.util.spec_from_file_location("verify_macos_test_results", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_summary(total, passed, skipped=0, failed=0, expected_failures=0):
    return {
        "totalTestCount": total,
        "passedTests": passed,
        "skippedTests": skipped,
        "failedTests": failed,
        "expectedFailures": expected_failures,
    }


def make_tests_payload(skipped_cases):
    """Build a minimal xcresulttool `test-results tests` JSON payload."""
    suites = {}
    for test_id, reason in skipped_cases:
        suite_name, method_name = test_id.split("/", 1)
        node = {
            "name": f"{method_name}()",
            "nodeIdentifier": f"{suite_name}/{method_name}()",
            "nodeType": "Test Case",
            "result": "Skipped",
        }
        if reason:
            node["children"] = [{"name": reason, "nodeType": "Failure Message"}]
        suites.setdefault(suite_name, []).append(node)

    suite_nodes = [
        {
            "name": suite_name,
            "nodeType": "Test Suite",
            "result": "Skipped",
            "children": cases,
        }
        for suite_name, cases in suites.items()
    ]
    return {
        "testNodes": [
            {
                "name": "DockBridge",
                "nodeType": "Test Plan",
                "result": "Passed",
                "children": [
                    {
                        "name": "DockBridgeTests",
                        "nodeType": "Unit test bundle",
                        "result": "Passed",
                        "children": suite_nodes,
                    }
                ],
            }
        ]
    }


class VerifyMacOSTestResultsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_type_hints_resolve_on_python_39_plus(self):
        hints = typing.get_type_hints(self.mod.verify_results)
        self.assertIn("allowed_skipped", hints)

    def test_accepts_expected_ci_summary_with_allowlisted_skips(self):
        allowed = sorted(self.mod.ALLOWED_SKIPPED_TESTS)
        summary = make_summary(584 + len(allowed), 584, skipped=len(allowed))
        tests_payload = make_tests_payload([(tid, "Test skipped - expected") for tid in allowed])
        self.assertEqual(self.mod.verify_results(summary, tests_payload), [])

    def test_accepts_zero_skips_when_all_tests_pass(self):
        summary = make_summary(600, 600)
        self.assertEqual(self.mod.verify_results(summary, make_tests_payload([])), [])

    def test_rejects_single_unexpected_skipped_test(self):
        summary = make_summary(585, 584, skipped=1)
        tests_payload = make_tests_payload(
            [("ConnectionListViewModelTests/testImportantBehavior", "Test skipped - accidental")]
        )
        errors = self.mod.verify_results(summary, tests_payload)
        self.assertEqual(len(errors), 1)
        self.assertIn("Unexpected skipped macOS test(s)", errors[0])
        self.assertIn("ConnectionListViewModelTests/testImportantBehavior", errors[0])
        self.assertIn("Test skipped - accidental", errors[0])

    def test_rejects_mass_skips_even_when_one_test_passes(self):
        summary = make_summary(200, 1, skipped=199)
        skipped = [(f"SomeSuite/testCase{i}", "Test skipped - broken") for i in range(199)]
        errors = self.mod.verify_results(summary, make_tests_payload(skipped))
        self.assertTrue(any("Too few macOS tests passed" in err for err in errors))
        self.assertTrue(any("Unexpected skipped macOS test(s)" in err for err in errors))

    def test_rejects_below_minimum_passed_floor_without_skips(self):
        summary = make_summary(5, 5)
        errors = self.mod.verify_results(summary, make_tests_payload([]), min_passed=100)
        self.assertEqual(len(errors), 1)
        self.assertIn("Too few macOS tests passed", errors[0])

    def test_rejects_failed_empty_expected_failures_and_unaccounted_totals(self):
        for summary, expected_fragment in (
            (make_summary(0, 0), "Unexpected macOS test counts"),
            (make_summary(100, 99, failed=1), "Unexpected macOS test counts"),
            (make_summary(150, 140, expected_failures=10), "Unexpected macOS test counts"),
            (make_summary(150, 140, skipped=0, failed=0, expected_failures=0), "Unaccounted macOS tests"),
        ):
            with self.subTest(summary=summary):
                errors = self.mod.verify_results(summary, make_tests_payload([]))
                self.assertTrue(any(expected_fragment in err for err in errors), errors)

    def test_rejects_duplicate_skipped_identifiers(self):
        dup = "FileDropValidationTests/testLocalListingOrdersCaseOnlyCollisionsByRawName"
        summary = make_summary(102, 100, skipped=2)
        errors = self.mod.verify_results(
            summary,
            make_tests_payload([(dup, "first"), (dup, "second")]),
        )
        self.assertTrue(any("Duplicate skipped macOS test identifier(s)" in err for err in errors), errors)

    def test_rejects_mismatch_between_summary_skipped_and_test_tree(self):
        summary = make_summary(585, 584, skipped=1)
        errors = self.mod.verify_results(summary, make_tests_payload([]))
        self.assertTrue(any("Skipped test count mismatch" in err for err in errors))

    def test_rejects_boolean_summary_counts_and_missing_test_nodes(self):
        bad_summary = make_summary(100, True)
        with self.assertRaises(RuntimeError):
            self.mod.verify_results(bad_summary, make_tests_payload([]))

        with self.assertRaises(RuntimeError):
            self.mod.extract_skipped_tests({"testNodes": "not-a-list"})

    def test_extract_handles_non_list_children_and_suite_fallback(self):
        payload = {
            "testNodes": [
                {
                    "name": "FileDropValidationTests",
                    "nodeType": "Test Suite",
                    "children": [
                        {
                            "name": "testLocalListingOrdersCaseOnlyCollisionsByRawName()",
                            "nodeType": "Test Case",
                            "result": "Skipped",
                            "children": "malformed-not-a-list",
                        }
                    ],
                }
            ]
        }
        skipped = self.mod.extract_skipped_tests(payload)
        self.assertEqual(
            skipped,
            [("FileDropValidationTests/testLocalListingOrdersCaseOnlyCollisionsByRawName", "")],
        )

    def test_find_latest_xcresult_selects_newest_ignores_symlinks_and_breaks_ties_numerically(self):
        with tempfile.TemporaryDirectory(prefix="find-xcresult-") as tmp:
            root = pathlib.Path(tmp)
            pattern = str(root / "xcodebuild-test-attempt-*.xcresult")
            self.assertIsNone(self.mod.find_latest_xcresult(pattern))

            # Plain file matching pattern is ignored.
            (root / "xcodebuild-test-attempt-99.xcresult").write_text("not a dir")
            self.assertIsNone(self.mod.find_latest_xcresult(pattern))

            # Directories with equal mtime: attempt-10 beats attempt-9 numerically.
            d9 = root / "xcodebuild-test-attempt-9.xcresult"
            d10 = root / "xcodebuild-test-attempt-10.xcresult"
            d9.mkdir()
            d10.mkdir()
            fixed = 1_700_000_000_000_000_000
            os.utime(d9, ns=(fixed, fixed))
            os.utime(d10, ns=(fixed, fixed))
            self.assertEqual(self.mod.find_latest_xcresult(pattern), d10)

            # Newer mtime wins over higher number.
            os.utime(d9, ns=(fixed + 10_000_000_000, fixed + 10_000_000_000))
            self.assertEqual(self.mod.find_latest_xcresult(pattern), d9)

            # Symlink to a directory is ignored even if it has a higher attempt number.
            target = root / "external-bundle"
            target.mkdir()
            symlink = root / "xcodebuild-test-attempt-20.xcresult"
            symlink.symlink_to(target)
            self.assertEqual(self.mod.find_latest_xcresult(pattern), d9)

    def test_allowlist_entries_match_real_swift_test_methods(self):
        # Guard against stale allowlist entries when tests are renamed or removed.
        swift_sources = {
            path.stem: path.read_text()
            for path in MACOS_TESTS_DIR.glob("*.swift")
        }
        self.assertTrue(swift_sources, "Expected Swift test files in DockBridgeTests")
        for entry in sorted(self.mod.ALLOWED_SKIPPED_TESTS):
            with self.subTest(entry=entry):
                suite, method = entry.split("/", 1)
                self.assertIn(suite, swift_sources, f"Test class file {suite}.swift not found")
                self.assertRegex(
                    swift_sources[suite],
                    rf"\bfunc\s+{re.escape(method)}\s*\(",
                    f"Allowlisted test {entry} no longer exists in {suite}.swift",
                )

    def test_cli_invocation_and_error_modes_with_mocked_xcrun(self):
        with tempfile.TemporaryDirectory(prefix="verify-macos-tests-") as tmp:
            tmp_path = pathlib.Path(tmp)
            xcresult = tmp_path / "attempt-1.xcresult"
            xcresult.mkdir()
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            summary_json = tmp_path / "summary.json"
            tests_json = tmp_path / "tests.json"
            args_log = tmp_path / "xcrun-args.jsonl"

            xcrun = fake_bin / "xcrun"
            xcrun.write_text(
                f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "{args_log}"
if [[ "${{MOCK_XCRUN_FAIL:-0}}" == "1" ]]; then
  printf 'Error: broken\\n::warning::injected\\n' >&2
  exit 64
fi
if [[ "$1" == "xcresulttool" && "$2" == "get" && "$3" == "test-results" && "$4" == "summary" && "$5" == "--path" && "$#" -eq 6 ]]; then
  cat "{summary_json}"
elif [[ "$1" == "xcresulttool" && "$2" == "get" && "$3" == "test-results" && "$4" == "tests" && "$5" == "--path" && "$#" -eq 6 ]]; then
  cat "{tests_json}"
else
  echo "unexpected xcrun args: $*" >&2
  exit 2
fi
"""
            )
            xcrun.chmod(0o755)
            env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}

            # Case 1: allowlisted skip passes with exact xcresulttool args (no --format).
            summary_json.write_text(json.dumps(make_summary(101, 100, skipped=1)))
            tests_json.write_text(json.dumps(make_tests_payload([
                ("FileDropValidationTests/testLocalListingOrdersCaseOnlyCollisionsByRawName", "case-insensitive"),
            ])))
            ok = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            self.assertIn(
                "macOS test summary: total=101, passed=100, skipped=1, failed=0, expected_failures=0",
                ok.stdout,
            )
            self.assertNotIn("--format", args_log.read_text())

            # Case 2: unexpected skip with newlines escapes ::error:: safely.
            tests_json.write_text(json.dumps(make_tests_payload([
                ("ConnectionListViewModelTests/testUnexpected", "line1\n::notice::injected 100%"),
            ])))
            bad = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(bad.returncode, 0)
            error_lines = [line for line in bad.stdout.splitlines() if line.startswith("::error::")]
            self.assertEqual(len(error_lines), 1, bad.stdout)
            self.assertIn("Unexpected skipped macOS test(s)", error_lines[0])
            self.assertIn("%0A", error_lines[0])
            self.assertIn("100%25", error_lines[0])
            self.assertFalse(any(line.startswith("::notice::") for line in bad.stdout.splitlines()))

            # Case 3: xcrun non-zero exit with multi-line stderr escapes ::error:: and fails.
            fail_env = {**env, "MOCK_XCRUN_FAIL": "1"}
            xcrun_fail = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=fail_env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(xcrun_fail.returncode, 0)
            self.assertFalse(any(line.startswith("::warning::") for line in xcrun_fail.stdout.splitlines()))
            self.assertIn("%0A", xcrun_fail.stdout)

            # Case 4: invalid JSON fails cleanly without traceback.
            summary_json.write_text("not-json")
            bad_json = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(bad_json.returncode, 0)
            self.assertIn("::error::Invalid JSON", bad_json.stdout)
            self.assertEqual(bad_json.stderr, "")

            # Case 5: missing explicit --xcresult reports the path; --min-passed 0 fails cleanly.
            missing = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(tmp_path / "missing.xcresult")],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("missing.xcresult", missing.stdout)

            bad_min = subprocess.run(
                [sys.executable, str(SCRIPT), "--min-passed", "0", "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(bad_min.returncode, 0)
            self.assertIn("::error::--min-passed must be >= 1", bad_min.stdout)

    def test_composite_action_invokes_verification_script(self):
        action_text = RUN_MACOS_TESTS_ACTION.read_text()
        match = re.search(
            r"(?ms)^    - name: Verify macOS test result counts\n(.*?)(?=^    - name: |\Z)",
            action_text,
        )
        self.assertIsNotNone(match, "Verify macOS test result counts step not found")
        self.assertRegex(
            match.group(1),
            r"(?m)^      run:\s*python3 scripts/verify-macos-test-results\.py\s*$",
        )


if __name__ == "__main__":
    unittest.main()
