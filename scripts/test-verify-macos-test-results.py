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

    def test_accepts_expected_ci_summary_with_allowlisted_skips(self):
        allowed = sorted(self.mod.ALLOWED_SKIPPED_TESTS)
        summary = {
            "totalTestCount": 584 + len(allowed),
            "passedTests": 584,
            "skippedTests": len(allowed),
            "failedTests": 0,
        }
        tests_payload = make_tests_payload([(tid, "Test skipped - expected") for tid in allowed])
        self.assertEqual(self.mod.verify_results(summary, tests_payload), [])

    def test_accepts_zero_skips_when_all_tests_pass(self):
        summary = {
            "totalTestCount": 600,
            "passedTests": 600,
            "skippedTests": 0,
            "failedTests": 0,
        }
        tests_payload = make_tests_payload([])
        self.assertEqual(self.mod.verify_results(summary, tests_payload), [])

    def test_rejects_single_unexpected_skipped_test(self):
        summary = {
            "totalTestCount": 585,
            "passedTests": 584,
            "skippedTests": 1,
            "failedTests": 0,
        }
        tests_payload = make_tests_payload(
            [("ConnectionListViewModelTests/testImportantBehavior", "Test skipped - accidental")]
        )
        errors = self.mod.verify_results(summary, tests_payload)
        self.assertEqual(len(errors), 1)
        self.assertIn("Unexpected skipped macOS test(s)", errors[0])
        self.assertIn("ConnectionListViewModelTests/testImportantBehavior", errors[0])
        self.assertIn("Test skipped - accidental", errors[0])

    def test_rejects_mass_skips_even_when_one_test_passes(self):
        summary = {
            "totalTestCount": 200,
            "passedTests": 1,
            "skippedTests": 199,
            "failedTests": 0,
        }
        skipped = [(f"SomeSuite/testCase{i}", "Test skipped - broken") for i in range(199)]
        errors = self.mod.verify_results(summary, make_tests_payload(skipped))
        self.assertTrue(any("Too few macOS tests passed" in err for err in errors))
        self.assertTrue(any("Unexpected skipped macOS test(s)" in err for err in errors))

    def test_rejects_below_minimum_passed_floor_without_skips(self):
        summary = {
            "totalTestCount": 5,
            "passedTests": 5,
            "skippedTests": 0,
            "failedTests": 0,
        }
        errors = self.mod.verify_results(summary, make_tests_payload([]), min_passed=100)
        self.assertEqual(len(errors), 1)
        self.assertIn("Too few macOS tests passed", errors[0])

    def test_rejects_failed_or_empty_counts(self):
        for summary in (
            {"totalTestCount": 0, "passedTests": 0, "skippedTests": 0, "failedTests": 0},
            {"totalTestCount": 100, "passedTests": 99, "skippedTests": 0, "failedTests": 1},
        ):
            with self.subTest(summary=summary):
                errors = self.mod.verify_results(summary, make_tests_payload([]))
                self.assertTrue(any("Unexpected macOS test counts" in err for err in errors))

    def test_rejects_mismatch_between_summary_skipped_and_test_tree(self):
        summary = {
            "totalTestCount": 585,
            "passedTests": 584,
            "skippedTests": 1,
            "failedTests": 0,
        }
        # Test tree reports 0 skipped nodes while summary reports 1.
        errors = self.mod.verify_results(summary, make_tests_payload([]))
        self.assertTrue(any("Skipped test count mismatch" in err for err in errors))

    def test_extract_fallback_uses_suite_and_name_without_node_identifier(self):
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

    def test_cli_invocation_with_mocked_xcrun(self):
        with tempfile.TemporaryDirectory(prefix="verify-macos-tests-") as tmp:
            tmp_path = pathlib.Path(tmp)
            xcresult = tmp_path / "attempt-1.xcresult"
            xcresult.mkdir()
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            summary_json = tmp_path / "summary.json"
            tests_json = tmp_path / "tests.json"

            xcrun = fake_bin / "xcrun"
            xcrun.write_text(
                f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "$4" == "summary" ]]; then
  cat "{summary_json}"
elif [[ "$4" == "tests" ]]; then
  cat "{tests_json}"
else
  echo "unexpected subcommand: $*" >&2
  exit 2
fi
"""
            )
            xcrun.chmod(0o755)
            env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}

            # Case 1: allowlisted skip passes.
            summary_json.write_text(json.dumps({
                "totalTestCount": 101,
                "passedTests": 100,
                "skippedTests": 1,
                "failedTests": 0,
            }))
            tests_json.write_text(json.dumps(make_tests_payload([
                ("FileDropValidationTests/testLocalListingOrdersCaseOnlyCollisionsByRawName", "case-insensitive"),
            ])))
            ok = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            self.assertIn("macOS test summary: total=101, passed=100, skipped=1, failed=0", ok.stdout)

            # Case 2: unexpected skip fails.
            tests_json.write_text(json.dumps(make_tests_payload([
                ("ConnectionListViewModelTests/testUnexpected", "oops"),
            ])))
            bad = subprocess.run(
                [sys.executable, str(SCRIPT), "--xcresult", str(xcresult)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("Unexpected skipped macOS test(s)", bad.stdout)

    def test_composite_action_invokes_verification_script(self):
        action_text = RUN_MACOS_TESTS_ACTION.read_text()
        self.assertIn("python3 scripts/verify-macos-test-results.py", action_text)


if __name__ == "__main__":
    unittest.main()
