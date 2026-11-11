#!/usr/bin/env python3
"""Exercise the documented host-key commands without sudo or an SSH server."""
import os
import pathlib
import subprocess
import tempfile
import unittest

AGENTS = pathlib.Path(__file__).resolve().parent.parent / "AGENTS.md"
SETUP = AGENTS.read_text().split("```bash\n", 1)[1].split("\n```", 1)[0]
KEY_SETUP = SETUP[SETUP.index("mkdir -p /tmp/sftpdemo\n"):SETUP.index("sudo useradd ")]

# Model ssh-keygen's refusal to overwrite an existing (possibly root-owned)
# key non-interactively. sudo only records chown; it never changes ownership.
STUBS = r'''
ssh-keygen() {
    printf 'ssh-keygen\n' >> "$CALLS"
    [[ "$#" == 6 && "$1" == -t && "$2" == ed25519 &&
       "$3" == -f && "$4" == "$DEMO_DIR/ssh_host_ed25519_key" &&
       "$5" == -N && "$6" == "" ]] || return 90
    [[ "$KEYGEN_STATUS" == 0 ]] || return "$KEYGEN_STATUS"
    if [[ -e "$4" ]]; then
        printf 'Overwrite (y/n)?\n' >&2
        return 1
    fi
    (umask 077; printf 'private fixture\n' > "$4")
    printf 'public fixture\n' > "$4.pub"
}
sudo() {
    printf '%s\n' "$*" >> "$CALLS"
    [[ "$#" == 3 && "$1" == chown && "$2" == root:root &&
       "$3" == "$DEMO_DIR/ssh_host_ed25519_key" ]] || return 91
    return "$CHOWN_STATUS"
}
'''


class DemoHostKeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = pathlib.Path(self.temp.name)
        self.demo = self.directory / "demo"
        self.key = self.demo / "ssh_host_ed25519_key"
        self.calls = self.directory / "calls"

    def setup_key(self, keygen_status=0, chown_status=0):
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c",
             STUBS + KEY_SETUP.replace("/tmp/sftpdemo", str(self.demo))],
            env={**os.environ, "DEMO_DIR": str(self.demo), "CALLS": str(self.calls),
                 "KEYGEN_STATUS": str(keygen_status), "CHOWN_STATUS": str(chown_status)},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5,
        )

    def test_first_setup_generates_and_assigns_private_key(self):
        result = self.setup_key()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.key.read_text(), "private fixture\n")
        self.assertEqual(self.key.with_suffix(".pub").read_text(), "public fixture\n")
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["ssh-keygen", f"chown root:root {self.key}"])

    def test_rerun_preserves_keys_without_keygen_or_chown(self):
        self.assertEqual(self.setup_key().returncode, 0)
        before = self.calls.read_text()
        private = self.key.read_bytes()
        public = self.key.with_suffix(".pub").read_bytes()
        result = self.setup_key(keygen_status=42, chown_status=43)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text(), before)
        self.assertEqual(self.key.read_bytes(), private)
        self.assertEqual(self.key.with_suffix(".pub").read_bytes(), public)

    def test_existing_private_key_without_public_file_is_reused(self):
        self.demo.mkdir()
        self.key.write_text("existing private key\n")
        result = self.setup_key()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.key.read_text(), "existing private key\n")
        self.assertFalse(self.key.with_suffix(".pub").exists())

    def test_generation_failure_is_not_hidden_by_chown(self):
        result = self.setup_key(keygen_status=42)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.calls.read_text(), "ssh-keygen\n")
        self.assertFalse(self.key.exists())

    def test_chown_failure_is_reported(self):
        result = self.setup_key(chown_status=43)
        self.assertEqual(result.returncode, 43, result.stderr)


if __name__ == "__main__":
    unittest.main()
