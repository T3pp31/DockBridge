#!/usr/bin/env python3
"""Exercise E2E failure propagation and cleanup without Docker, Rust, or Xcode."""
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


class E2ECheckTests(unittest.TestCase):
    def run_check(self, target, *, fail_call=0, cmp_failure="", reject_status=3,
                  persist_trust=False, fixture="", real_helpers=False):
        source = SCRIPT.read_text()
        invocation = 'main "$@"'
        self.assertTrue(source.rstrip().endswith(invocation))
        source = source.rstrip()[:-len(invocation)]
        # Keep the selected production check and the real main/check aggregation.
        # Stub external tools, unrelated checks, and setup helpers unless under test.
        stubs = "\n".join(f"{name}() {{ :; }}" for name in CHECK_FUNCTIONS
                          if name != target)
        helpers = "" if real_helpers else """
ensure_key() { :; }
prepare_config() { :; }
"""
        harness = source + stubs + helpers + """
ensure_container() { :; }
CLI=(fixture_cli)
fixture_cli() {
  cat >/dev/null || return 1
  local call
  call=$(grep -c '^cli:' "$TEST_TRACE") || call=0
  call=$((call + 1))
  printf 'cli:%s\n' "$1" >> "$TEST_TRACE"
  if [[ "$TEST_TARGET" == host_key_reject ]]; then
    if [[ "$TEST_PERSIST_TRUST" == 1 ]]; then
      printf '{"entries":[]}\n' > "$KNOWN_HOSTS"
    fi
    return "$TEST_REJECT_STATUS"
  fi
  # Leave valid trust behind even on failure: a later file assertion must not
  # turn a failed CLI operation into a successful check.
  printf '{"entries":[]}\n' > "$KNOWN_HOSTS"
  if [[ "$TEST_TARGET" == corrupted_known_hosts_errors && "$call" == 2 ]]; then
    echo 'known hosts fixture error'
    return 17
  fi
  printf '[]\n'
  if [[ "$call" == "$TEST_FAIL_CALL" ]]; then return 17; fi
}
cmp() {
  printf 'cmp:%s\n' "${2##*/}" >> "$TEST_TRACE"
  [[ "${2##*/}" != "$TEST_CMP_FAILURE" ]]
}
""" + fixture + "\n" + invocation + "\n"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            temporary_root = root / "temporary files"
            temporary_root.mkdir()
            trace = root / "trace"
            trace.touch()
            env = dict(os.environ, TMPDIR=str(temporary_root), TEST_TRACE=str(trace),
                       TEST_TARGET=target, TEST_FAIL_CALL=str(fail_call),
                       TEST_CMP_FAILURE=cmp_failure, TEST_REJECT_STATUS=str(reject_status),
                       TEST_PERSIST_TRUST=str(int(persist_trust)))
            result = subprocess.run(["bash", "-c", harness, str(SCRIPT)],
                                    env=env, capture_output=True, text=True, timeout=10)
            return result, trace.read_text().splitlines()

    def assert_summary(self, result, *, failed):
        self.assertEqual(result.returncode, int(failed), result.stdout + result.stderr)
        expected = "14 passed, 1 failed" if failed else "15 passed, 0 failed"
        self.assertIn(f"SUMMARY: {expected}", result.stdout)

    def test_host_key_reject_requires_exit_three_and_no_persisted_trust(self):
        for status, persisted in ((3, False), (0, False), (1, False), (3, True)):
            with self.subTest(status=status, persisted=persisted):
                result, trace = self.run_check("host_key_reject", reject_status=status,
                                               persist_trust=persisted)
                self.assert_summary(result, failed=status != 3 or persisted)
                self.assertEqual(trace, ["cli:list"])

    def test_host_key_accept_requires_cli_success_even_with_valid_store(self):
        for fail_call in (0, 1):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("host_key_accept", fail_call=fail_call)
                self.assert_summary(result, failed=fail_call != 0)
                self.assertEqual(trace, ["cli:list"])

    def test_mkdir_rename_delete_requires_every_cli_operation(self):
        operations = ["cli:mkdir", "cli:rename", "cli:upload", "cli:delete"]
        for fail_call in range(5):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("mkdir_rename_delete", fail_call=fail_call)
                self.assert_summary(result, failed=fail_call != 0)
                self.assertEqual(trace, operations[:fail_call] if fail_call else operations)

    def test_recursive_transfer_requires_each_cli_and_each_comparison(self):
        operations = ["cli:upload", "cli:download", "cmp:a.txt", "cmp:b.txt"]
        for fail_call, cmp_failure, completed in (
                (0, "", 4), (1, "", 1), (2, "", 2),
                (0, "a.txt", 3), (0, "b.txt", 4)):
            with self.subTest(fail_call=fail_call, cmp_failure=cmp_failure):
                result, trace = self.run_check("recursive_upload_download",
                                               fail_call=fail_call, cmp_failure=cmp_failure)
                self.assert_summary(result, failed=bool(fail_call or cmp_failure))
                self.assertEqual(trace, operations[:completed])

    def test_private_key_auth_requires_successful_trust_seeding(self):
        for fail_call in (0, 1, 2):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("private_key_auth_plain", fail_call=fail_call)
                self.assert_summary(result, failed=fail_call != 0)
                self.assertEqual(trace, ["cli:list"] * (fail_call or 2))

    def test_download_requires_cli_success_before_comparing(self):
        for fail_call in (0, 1):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("download_file", fail_call=fail_call)
                self.assert_summary(result, failed=fail_call != 0)
                expected = ["cli:download"] + ([] if fail_call else ["cmp:local-upload.txt"])
                self.assertEqual(trace, expected)

    def test_corrupt_store_requires_successful_trust_seeding(self):
        for fail_call in (0, 1):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("corrupted_known_hosts_errors",
                                               fail_call=fail_call)
                self.assert_summary(result, failed=fail_call != 0)
                self.assertEqual(trace, ["cli:list"] * (1 if fail_call else 2))

    def test_host_key_accept_does_not_ignore_config_preparation_failure(self):
        result, trace = self.run_check("host_key_accept", fixture="""
preparations=0
prepare_config() {
  preparations=$((preparations + 1))
  # main's initial preparation succeeds; preparation inside check fails.
  [[ "$preparations" == 1 ]]
}
""")
        self.assert_summary(result, failed=True)
        self.assertEqual(trace, [])

    def test_config_helper_does_not_mask_sed_failure_with_later_writes(self):
        result, trace = self.run_check("host_key_accept", real_helpers=True, fixture="""
sed_calls=0
sed() {
  sed_calls=$((sed_calls + 1))
  # Fail inside check, not during main's initial preparation.
  if [[ "$sed_calls" == 2 ]]; then return 17; fi
  command sed "$@"
}
""")
        self.assert_summary(result, failed=True)
        self.assertEqual(trace, [])

    def test_key_helper_requires_both_key_generations(self):
        for fail_call in (0, 1, 2):
            with self.subTest(fail_call=fail_call):
                result, trace = self.run_check("private_key_auth_plain", real_helpers=True,
                                               fail_call=fail_call, fixture="""
keygen_calls=0
ssh-keygen() {
  keygen_calls=$((keygen_calls + 1))
  printf 'keygen\n' >> "$TEST_TRACE"
  [[ "$keygen_calls" != "$TEST_FAIL_CALL" ]]
}
""")
                self.assert_summary(result, failed=fail_call != 0)
                expected = ["keygen"] * (fail_call or 2)
                if not fail_call:
                    expected += ["cli:list", "cli:list"]
                self.assertEqual(trace, expected)


if __name__ == "__main__":
    unittest.main()
