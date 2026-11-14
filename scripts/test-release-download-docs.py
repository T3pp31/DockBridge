#!/usr/bin/env python3
"""Exercise the README download verification example offline with fixture files."""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
SHASUM = shutil.which("shasum")
SHA256SUM = shutil.which("sha256sum")


class DownloadVerificationTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(BASH, "bash is required")
        self.assertTrue(SHASUM or SHA256SUM, "shasum or sha256sum is required")
        directory = tempfile.TemporaryDirectory(prefix="release docs ")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.artifact = self.directory / "DockBridge-1.2.3-macOS.dmg"
        self.artifact.write_bytes(b"fixture release artifact\n")
        self.checksum = self.artifact.with_suffix(".dmg.sha256")
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.checksum.write_text(f"{digest}  {self.artifact.name}\n")
        self.calls = self.directory / "gh-calls"
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        download = readme.split("## Download\n", 1)[1].split("\n## ", 1)[0]
        examples = re.findall(r"```bash\n(.*?)```", download, re.DOTALL)
        self.assertEqual(len(examples), 1, "Keep one copyable verification example")
        self.example = examples[0].replace('VERSION="X.Y.Z"', 'VERSION="1.2.3"')
        # Use the real checksum utility, but never invoke a real gh or network.
        self.env = {
            "PATH": str(Path(SHASUM or SHA256SUM).parent),
            "HOME": str(self.directory),
            "CALLS": str(self.calls),
        }

    def verify(self, attestation_status=0):
        # Minimal Linux images may lack Perl's shasum. Validate the documented
        # arguments and delegate hashing/check-file parsing to GNU sha256sum.
        checksum_adapter = "" if SHASUM else r'''
shasum() {
    [[ "$#" == 4 && "$1" == -a && "$2" == 256 && "$3" == -c ]] || return 91
    sha256sum -c "$4"
}
'''
        script = checksum_adapter + r'''
gh() {
    printf '%s\n' "$*" >> "$CALLS"
    [[ "$#" == 5 && "$1" == attestation && "$2" == verify &&
       "$3" == DockBridge-1.2.3-macOS.dmg && "$4" == --repo &&
       "$5" == T3pp31/DockBridge ]] || return 90
    return "$ATTESTATION_STATUS"
}
''' + self.example
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c", script],
            cwd=self.directory,
            env={**self.env, "ATTESTATION_STATUS": str(attestation_status)},
            capture_output=True, text=True, timeout=5,
        )

    def test_valid_download_verifies_checksum_then_repository_provenance(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{self.artifact.name}: OK", result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(), [
            "attestation verify DockBridge-1.2.3-macOS.dmg --repo T3pp31/DockBridge",
        ])

    def test_corrupt_download_stops_before_attestation(self):
        self.artifact.write_bytes(b"modified artifact\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_missing_download_or_checksum_fails_closed(self):
        for missing in (self.artifact, self.checksum):
            with self.subTest(missing=missing.name):
                original = missing.read_bytes()
                missing.unlink()
                try:
                    result = self.verify()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(self.calls.exists())
                finally:
                    missing.write_bytes(original)

    def test_attestation_failure_is_not_reported_as_success(self):
        result = self.verify(attestation_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
