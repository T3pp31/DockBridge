#!/usr/bin/env python3
"""Exercise E2E summary/EXIT cleanup without Docker, Rust, or Xcode."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().with_name("e2e-verify.sh")
CHECK_FUNCTIONS = (
    "host_key_reject", "host_key_accept", "host_key_no_reprompt", "json_output",
    "pwd_command", "mkdir_rename_delete", "recursive_upload_download",
    "private_key_auth_plain", "private_key_auth_encrypted", "upload_file",
    "download_file", "transfer_queue_states", "corrupted_known_hosts_errors",
    "swift_corrupted_known_hosts_message", "transfer_cancel_in_progress",
)


class E2ELogTests(unittest.TestCase):
    def run_verification(self, directory, *, failed=False, copy_failed=False):
        source = SCRIPT.read_text()
        invocation = 'main "$@"'
        self.assertTrue(source.rstrip().endswith(invocation))
        # Load the real functions, but replace external checks before calling main.
        source = source.rstrip()[:-len(invocation)]
        stubs = "\n".join(f"{name}() {{ :; }}" for name in CHECK_FUNCTIONS)
        harness = source + stubs + """
ensure_container() { printf '%s' "$WORKDIR" > "$TEST_WORKDIR_FILE"; }
prepare_config() { :; }
host_key_reject() {
  echo 'fixture diagnostic'
  return "$TEST_STATUS"
}
"""
        if copy_failed:
            harness += "cp() { echo 'fixture copy failure' >&2; return 1; }\n"
        harness += invocation + "\n"
        temporary_root = directory / "temporary files"
        temporary_root.mkdir()
        workdir_file = directory / "workdir"
        env = dict(os.environ, TMPDIR=str(temporary_root),
                   TEST_WORKDIR_FILE=str(workdir_file), TEST_STATUS=str(int(failed)))
        result = subprocess.run(["bash", "-c", harness, str(SCRIPT)],
                                env=env, capture_output=True, text=True, timeout=10)
        workdir = pathlib.Path(workdir_file.read_text())
        self.assertFalse(workdir.exists(), result.stdout + result.stderr)
        return result, temporary_root / "dockbridge-e2e-verify.log", workdir

    def test_failure_reports_existing_saved_log_after_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            result, saved_log, workdir = self.run_verification(
                pathlib.Path(directory), failed=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUMMARY: 14 passed, 1 failed", result.stdout)
            self.assertIn(f"[e2e] Keeping debug log: {saved_log}\n", result.stdout)
            self.assertNotIn(str(workdir), result.stdout)
            diagnostics = saved_log.read_text()
            self.assertIn("fixture diagnostic", diagnostics)
            self.assertIn("FAIL: host key reject", diagnostics)
            self.assertIn("SUMMARY: 14 passed, 1 failed", diagnostics)

    def test_success_removes_workdir_without_advertising_deleted_log(self):
        with tempfile.TemporaryDirectory() as directory:
            result, saved_log, workdir = self.run_verification(pathlib.Path(directory))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("SUMMARY: 15 passed, 0 failed", result.stdout)
            self.assertNotIn("Keeping debug log:", result.stdout)
            self.assertNotIn("Log:", result.stdout)
            self.assertNotIn(str(workdir), result.stdout)
            self.assertFalse(saved_log.exists())

    def test_copy_failure_does_not_claim_log_was_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            result, saved_log, workdir = self.run_verification(
                pathlib.Path(directory), failed=True, copy_failed=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("SUMMARY: 14 passed, 1 failed", result.stdout)
            self.assertIn(f"WARNING: Could not save debug log to {saved_log}", result.stdout)
            self.assertNotIn("Keeping debug log:", result.stdout)
            self.assertNotIn("Log:", result.stdout)
            self.assertNotIn(str(workdir), result.stdout)
            self.assertFalse(saved_log.exists())


if __name__ == "__main__":
    unittest.main()
