#!/usr/bin/env python3
"""Check hello-world credential flow without installing or contacting an SSH server."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

DOC = pathlib.Path(__file__).resolve().parents[1] / "AGENTS.md"
BASH = shutil.which("bash")

# Only shell builtins run: no real openssl, sudo, cargo, or network access.
STUBS = r"""
openssl() { printf '%s\n' 'fixture-password/+=='; }
sudo() {
    [[ "$*" == chpasswd ]] || return 90
    local account_password
    IFS= read -r account_password
    printf '%s\n' "$account_password" > "$STATE"
}
cargo() {
    printf 'called\n' >> "$CALLS"
    local secret user expected
    IFS= read -r secret
    if [[ " $* " == *" --password-stdin "* ]]; then
        IFS=: read -r user expected < "$STATE"
        [[ "$user" == dockbridge-demo ]] || return 91
    else
        expected='fixture passphrase $with spaces'
    fi
    [[ -n "$secret" && "$secret" == "$expected" ]]
}
"""


class HelloWorldDocsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = pathlib.Path(directory.name) / "account-password"
        self.calls = pathlib.Path(directory.name) / "cli-calls"
        # Deliberately do not inherit credentials or shell startup hooks.
        self.env = {"PATH": "", "STATE": str(self.state), "CALLS": str(self.calls)}
        section = DOC.read_text().split(
            "### Running the CLI against a real SFTP server (hello-world)", 1
        )[1].split("Non-obvious gotchas", 1)[0]
        self.blocks = re.findall(r"```bash\n(.*?)```", section, re.DOTALL)

    def run_auth(self, variable, extra_env=None):
        results = []
        for block in self.blocks:
            # Project only credential statements, preserving code-fence boundaries.
            # Never execute the documented installation, account, or sshd setup.
            commands = [line for line in block.replace("\\\n", "").splitlines()
                        if variable in line and not line.lstrip().startswith("#")]
            if commands:
                script = "\n".join(commands).replace("<cfg.toml>", "fixture.toml")
                results.append(subprocess.run(
                    [BASH, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", STUBS + script],
                    env={**self.env, **(extra_env or {})},
                    capture_output=True, text=True, timeout=5,
                ))
        self.assertTrue(results, f"No credential commands found for {variable}")
        return results

    def test_shell_examples_parse(self):
        self.assertTrue(self.blocks, "No hello-world shell examples found")
        for block in self.blocks:
            result = subprocess.run(
                [BASH, "--noprofile", "--norc", "-n"],
                input=block.replace("<cfg.toml>", "fixture.toml"), env=self.env,
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_password_reaches_upload_in_fresh_shell_per_block(self):
        for result in self.run_auth("DEMO_PASS"):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")  # Do not print the generated password.
        self.assertEqual(self.state.read_text(), "dockbridge-demo:fixture-password/+==\n")
        self.assertEqual(self.calls.read_text(), "called\n")

    def test_explicit_passphrase_reaches_key_auth(self):
        for result in self.run_auth("KEY_PASSPHRASE", {
            "KEY_PASSPHRASE": "fixture passphrase $with spaces",
        }):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls.read_text(), "called\n")

    def test_missing_or_empty_passphrase_stops_before_cli(self):
        for value in (None, ""):
            with self.subTest(value=value):
                env = {} if value is None else {"KEY_PASSPHRASE": value}
                results = self.run_auth("KEY_PASSPHRASE", env)
                self.assertTrue(any(result.returncode != 0 for result in results))
                self.assertIn("KEY_PASSPHRASE", "".join(result.stderr for result in results))
                self.assertFalse(self.calls.exists(), "CLI must not receive an empty passphrase")


if __name__ == "__main__":
    unittest.main()
