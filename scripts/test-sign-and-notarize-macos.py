#!/usr/bin/env python3
"""Run signing identity regressions with mocked macOS commands (no signing required)."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("sign-and-notarize-macos.sh").resolve()
MODES = ((), ("--posix",))  # POSIX mode inherits errexit in command substitutions.
FIRST_IDENTITY = "Developer ID Application: First Signer (TEAM123)"
IDENTITIES = (
    '  1) AAA "Apple Development: Local Developer (TEAM123)"\n'
    f'  2) BBB "{FIRST_IDENTITY}"\n'
    '  3) CCC "Developer ID Application: Second Signer (TEAM456)"\n'
    '     3 valid identities found\n'
)
WRAPPER = r'''
security() {
  printf '%s\n' "$@" > "$TEST_SECURITY_LOG"
  printf '%s' "$TEST_SECURITY_STDOUT"
  printf '%s' "$TEST_SECURITY_STDERR" >&2
  return "$TEST_SECURITY_STATUS"
}
codesign() {
  printf '%s\n' "$@" >> "$TEST_CODESIGN_LOG"
}
unexpected_command() {
  printf '%s\n' "$@" >> "$TEST_UNEXPECTED_LOG"
  return 99
}
spctl() { unexpected_command spctl "$@"; }
xcrun() { unexpected_command xcrun "$@"; }
ditto() { unexpected_command ditto "$@"; }
export -f security codesign unexpected_command spctl xcrun ditto
exec bash "$@"
'''


class SigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.app = self.root / "Test App.app"
        self.app.mkdir()
        self.entitlements = self.root / "test.entitlements"
        self.entitlements.write_text("<plist/>")

    def run_script(self, mode, output="", error="", status=0, identity=None):
        env = os.environ.copy()
        for name in (
            "BASH_ENV", "BASHOPTS", "SHELLOPTS", "POSIXLY_CORRECT",
            "CODE_SIGN_IDENTITY", "DMG_PATH",
        ):
            env.pop(name, None)
        env.update({
            "ENTITLEMENTS_PATH": str(self.entitlements),
            "SKIP_NOTARIZATION": "true",
            "TEST_SECURITY_STDOUT": output,
            "TEST_SECURITY_STDERR": error,
            "TEST_SECURITY_STATUS": str(status),
        })
        for command in ("security", "codesign", "unexpected"):
            log = self.root / f"{command}.log"
            if log.exists():
                log.unlink()
            env[f"TEST_{command.upper()}_LOG"] = str(log)
        if identity is not None:
            env["CODE_SIGN_IDENTITY"] = identity
        result = subprocess.run(
            ["bash", "-c", WRAPPER, "test-signing", *mode, str(SCRIPT), str(self.app)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertFalse((self.root / "unexpected.log").exists(), result.stderr)
        return result

    def assert_query_called(self):
        self.assertEqual(
            (self.root / "security.log").read_text().splitlines(),
            ["find-identity", "-v", "-p", "codesigning"],
        )

    def assert_signed_with(self, identity):
        self.assertEqual(
            (self.root / "codesign.log").read_text().splitlines(),
            ["--force", "--timestamp", "--options", "runtime", "--entitlements",
             str(self.entitlements), "--sign", identity, str(self.app),
             "--verify", "--strict", "--verbose=2", str(self.app)],
        )

    def test_query_failure_reports_error_and_does_not_sign(self):
        for mode in MODES:
            # A failed query must not use even a partially returned identity.
            for output, error in (
                ("", "security: simulated keychain access failure\n"),
                (IDENTITIES, "security: simulated keychain access failure\n"),
                ("", ""),
            ):
                with self.subTest(mode=mode, output=output, error=error):
                    result = self.run_script(mode, output=output, error=error, status=51)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Failed to query signing identities from keychain", result.stderr)
                    if error:
                        self.assertIn(error, result.stderr)
                    self.assertNotIn("No Developer ID Application identity found", result.stderr)
                    self.assert_query_called()
                    self.assertFalse((self.root / "codesign.log").exists())

    def test_no_matching_identity_retains_existing_guidance(self):
        for mode in MODES:
            for output in ("", "     0 valid identities found\n",
                           '  1) AAA "Apple Development: Local Developer (TEAM123)"\n'):
                with self.subTest(mode=mode, output=output):
                    result = self.run_script(mode, output=output)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("No Developer ID Application identity found in the keychain.", result.stderr)
                    self.assertIn("Import a signing certificate or set CODE_SIGN_IDENTITY.", result.stderr)
                    self.assertNotIn("Failed to query", result.stderr)
                    self.assert_query_called()
                    self.assertFalse((self.root / "codesign.log").exists())

    def test_auto_detection_signs_with_first_developer_id(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                result = self.run_script(mode, output=IDENTITIES)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assert_query_called()
                self.assert_signed_with(FIRST_IDENTITY)

    def test_explicit_identity_bypasses_keychain_query(self):
        identity = "Developer ID Application: Explicit Signer (TEAM789)"
        for mode in MODES:
            with self.subTest(mode=mode):
                result = self.run_script(mode, status=51, identity=identity)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertFalse((self.root / "security.log").exists())
                self.assert_signed_with(identity)


if __name__ == "__main__":
    unittest.main()
