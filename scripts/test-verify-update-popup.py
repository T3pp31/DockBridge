#!/usr/bin/env python3
"""Offline regression tests for verify-update-popup.sh (Issue #839 F52-F55)."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().with_name("verify-update-popup.sh")
REPO_ROOT = SCRIPT.parent.parent


class VerifyUpdatePopupTests(unittest.TestCase):
    def load_functions_prefix(self):
        source = SCRIPT.read_text()
        invocation = 'main "$@"'
        self.assertTrue(source.rstrip().endswith(invocation))
        return source.rstrip()[:-len(invocation)]

    def run_snippet(self, snippet, *, extra_env=None):
        harness = self.load_functions_prefix() + "\n" + snippet + "\n"
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", "-c", harness, str(SCRIPT)],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_wait_for_update_sheet_fails_immediately_on_osascript_error(self):
        # Issue #839 F52: Accessibility denial / osascript failure must not be
        # swallowed and retried until timeout.
        result = self.run_snippet("""
osascript() {
  echo "System Events got an error: osascript is not allowed assistive access. (-1719)" >&2
  return 1
}
sleep() {
  echo "UNEXPECTED_SLEEP" >&2
  return 99
}
wait_for_update_sheet 5
""")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("not allowed assistive access", result.stderr)
        self.assertNotIn("UNEXPECTED_SLEEP", result.stderr)

    def test_run_xctest_case_rejects_zero_matched_tests(self):
        # Issue #839 F54: a misspelled -only-testing selector (totalTestCount=0)
        # must fail instead of succeeding.
        summary = json.dumps({
            "totalTestCount": 0,
            "passedTests": 0,
            "skippedTests": 0,
            "failedTests": 0,
        })
        result = self.run_snippet("""
xcodebuild() {
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
      mkdir -p "$2"
      return 0
    fi
    shift
  done
  return 2
}
xcrun() {
  printf '%s\\n' "$TEST_SUMMARY"
}
run_xctest_case "DockBridgeTests/UpdateCheckViewModelTests/nonExistentSelector" "misspelled selector"
""", extra_env={"TEST_SUMMARY": summary})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("no tests matched", result.stderr)

    def test_run_xctest_case_rejects_skipped_test(self):
        # Issue #839 F54: an XCTSkip must fail instead of passing.
        summary = json.dumps({
            "totalTestCount": 1,
            "passedTests": 0,
            "skippedTests": 1,
            "failedTests": 0,
        })
        result = self.run_snippet("""
xcodebuild() {
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
      mkdir -p "$2"
      return 0
    fi
    shift
  done
  return 2
}
xcrun() {
  printf '%s\\n' "$TEST_SUMMARY"
}
run_xctest_case "DockBridgeTests/UpdateCheckViewModelTests/testLaterDismissesWithoutPersistingSkip" "skipped test"
""", extra_env={"TEST_SUMMARY": summary})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("skipped=1", result.stderr)

    def test_run_xctest_case_succeeds_when_one_test_passes(self):
        summary = json.dumps({
            "totalTestCount": 1,
            "passedTests": 1,
            "skippedTests": 0,
            "failedTests": 0,
        })
        result = self.run_snippet("""
xcodebuild() {
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
      mkdir -p "$2"
      return 0
    fi
    shift
  done
  return 2
}
xcrun() {
  printf '%s\\n' "$TEST_SUMMARY"
}
run_xctest_case "DockBridgeTests/UpdateCheckViewModelTests/testSkipVersionPersistsSkippedVersionAndSuppressesRelaunch" "skip version"
""", extra_env={"TEST_SUMMARY": summary})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_script_references_existing_xctest_selectors(self):
        # Issue #839 F54: every -only-testing selector used in verify-update-popup.sh
        # must actually exist in UpdateCheckViewModelTests.swift.
        script_source = SCRIPT.read_text()
        tests_source = (
            REPO_ROOT / "apps/macos/DockBridgeTests/UpdateCheckViewModelTests.swift"
        ).read_text()
        self.assertNotIn("testSkipUpdatePersistsSkippedVersionAndSuppressesRelaunch", script_source)
        for selector in (
            "testLaterDismissesWithoutPersistingSkip",
            "testSkipVersionPersistsSkippedVersionAndSuppressesRelaunch",
            "testCheckOnLaunchIgnoresNetworkFailure",
            "testCheckOnLaunchDefersSheetWhileHostKeyBlocking",
        ):
            self.assertIn(f"UpdateCheckViewModelTests/{selector}", script_source)
            self.assertIn(f"func {selector}(", tests_source)

    def test_fetch_release_api_json_supports_controlled_fixture(self):
        # Issue #839 F53: UPDATE_API_FIXTURE_JSON lets verification run without
        # requiring live GitHub API to match local config/release.toml.
        with tempfile.TemporaryDirectory() as directory:
            fixture = pathlib.Path(directory) / "release.json"
            fixture.write_text('{"html_url":"https://example.invalid/release","assets":[]}\n')
            result = self.run_snippet(
                "fetch_release_api_json",
                extra_env={"UPDATE_API_FIXTURE_JSON": str(fixture)},
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("https://example.invalid/release", result.stdout)


if __name__ == "__main__":
    unittest.main()
