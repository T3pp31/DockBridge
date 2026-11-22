#!/usr/bin/env python3
"""Exercise transfer-cancel diagnostics without Docker, Rust, or Xcode."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("verify-transfer-cancel.sh")
CONFIG = SCRIPT.parent.parent / "config" / "sftp-test.conf"


class TransferCancelTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)
        for path in ("scripts", "config", "apps/macos"):
            (self.root / path).mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.root / "scripts" / SCRIPT.name)
        shutil.copyfile(CONFIG, self.root / "config" / CONFIG.name)
        self.env = {
            "HOME": str(self.root),
            "PATH": os.defpath,
            "SFTP_CONTAINER": "transfer-cancel-test",
            "TEST_SUMMARY": json.dumps({
                "totalTestCount": 1,
                "passedTests": 1,
                "skippedTests": 0,
                "failedTests": 0,
            }),
        }
        # Bash functions take precedence over installed tools and also work
        # when the sandbox mounts temporary filesystems with noexec. Bash allows
        # a function named after the relative path used for the Rust build.
        self.stubs = self.root / "stubs.sh"
        self.stubs.write_text("""\
docker() {
  case "$1" in
    ps) printf '%s\\n' "$SFTP_CONTAINER" ;;
    inspect) echo true ;;
    exec) return 0 ;;
    *) echo "unexpected docker invocation: $*" >&2; exit 2 ;;
  esac
}
./scripts/build-rust.sh() {
  return "${TEST_BUILD_STATUS:-0}"
}
xcodebuild() {
  if [[ "${TEST_XCODE_STATUS:-0}" -ne 0 ]]; then
    return "$TEST_XCODE_STATUS"
  fi
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
      if [[ "${TEST_MISSING_BUNDLE:-0}" -eq 0 ]]; then
        mkdir -p "$2"
      fi
      return 0
    fi
    shift
  done
  return 2
}
xcrun() {
  if [[ "${TEST_SUMMARY_STATUS:-0}" -ne 0 ]]; then
    return "$TEST_SUMMARY_STATUS"
  fi
  printf '%s\\n' "$TEST_SUMMARY"
}
""")

    def verify(self, **env):
        return subprocess.run(
            # Keep the real script as $0 so its ROOT resolution is unchanged.
            ["bash", "-c", 'source "$1"; source "$0"',
             str(self.root / "scripts" / SCRIPT.name), str(self.stubs)],
            env={**self.env, **env}, capture_output=True, text=True, timeout=10,
        )

    def assert_failure(self, result, message):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stderr, f"[verify-transfer-cancel] {message}\n")
        self.assertNotIn("PASS:", result.stdout)

    def test_missing_result_bundle(self):
        self.assert_failure(self.verify(TEST_MISSING_BUNDLE="1"),
                            "xcodebuild did not produce a result bundle")

    def test_unreadable_result_bundle(self):
        self.assert_failure(self.verify(TEST_SUMMARY_STATUS="42"),
                            "failed to read xcodebuild result bundle")

    def test_no_matching_tests(self):
        self.assert_failure(self.verify(TEST_SUMMARY=json.dumps({
            "totalTestCount": 0, "failedTests": 0,
        })), "no tests matched the -only-testing identifier")

    def test_failed_tests(self):
        self.assert_failure(self.verify(TEST_SUMMARY=json.dumps({
            "totalTestCount": 3, "passedTests": 1, "skippedTests": 0, "failedTests": 2,
        })), "2 transfer-cancel test(s) failed")

    def test_skipped_test_fails(self):
        # Issue #839 F51: an XCTSkip must fail instead of reporting PASS.
        self.assert_failure(self.verify(TEST_SUMMARY=json.dumps({
            "totalTestCount": 1, "passedTests": 0, "skippedTests": 1, "failedTests": 0,
        })), "1 transfer-cancel test(s) were skipped")

    def test_zero_passed_tests_fails(self):
        self.assert_failure(self.verify(TEST_SUMMARY=json.dumps({
            "totalTestCount": 1, "passedTests": 0, "skippedTests": 0, "failedTests": 0,
        })), "expected at least 1 passed transfer-cancel test, got 0")

    def test_exports_sftp_env_to_xcodebuild(self):
        env_dump = self.root / "xcode-env.txt"
        self.stubs.write_text(
            self.stubs.read_text()
            + f"""
xcodebuild() {{
  printf 'SFTP_PORT=%s\\nTEST_RUNNER_SFTP_PORT=%s\\nSFTP_USER=%s\\nTEST_RUNNER_SFTP_USER=%s\\nSFTP_CONTAINER=%s\\n' \\
    "${{SFTP_PORT:-}}" "${{TEST_RUNNER_SFTP_PORT:-}}" "${{SFTP_USER:-}}" "${{TEST_RUNNER_SFTP_USER:-}}" "${{SFTP_CONTAINER:-}}" > "{env_dump}"
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
      mkdir -p "$2"
      return 0
    fi
    shift
  done
  return 2
}}
"""
        )
        result = self.verify(SFTP_PORT="2299", SFTP_USER="custom-user")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        dumped = env_dump.read_text()
        self.assertIn("SFTP_PORT=2299\n", dumped)
        self.assertIn("TEST_RUNNER_SFTP_PORT=2299\n", dumped)
        self.assertIn("SFTP_USER=custom-user\n", dumped)
        self.assertIn("TEST_RUNNER_SFTP_USER=custom-user\n", dumped)
        self.assertIn("SFTP_CONTAINER=transfer-cancel-test\n", dumped)

    def test_success(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn(
            "[verify-transfer-cancel] PASS: in-progress large file upload "
            "can be cancelled via Transfer Queue API\n", result.stdout,
        )

    def test_build_and_xcodebuild_failures_propagate(self):
        for variable in ("TEST_BUILD_STATUS", "TEST_XCODE_STATUS"):
            with self.subTest(variable=variable):
                result = self.verify(**{variable: "42"})
                self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
                self.assertNotIn("PASS:", result.stdout)
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
