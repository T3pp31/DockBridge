#!/usr/bin/env python3
"""Exercise SBOM publication with offline doubles for cargo, jq and shasum.

The doubles inject validation/digest failures; these tests cover the shell's
publication and cleanup, not cargo-cyclonedx or jq's validation expressions.
"""
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SBOM = json.dumps({
    "bomFormat": "CycloneDX", "specVersion": "1.5",
    "components": [{"purl": "pkg:cargo/uniffi@0.29.0"}],
}) + "\n"
TOOL_DOUBLE = """import hashlib
import os
import pathlib
import sys

name = sys.argv[1]
args = sys.argv[2:]
failure = os.environ.get("SBOM_TEST_FAILURE", "")
gate = ("schema" if "--arg" in args else "components") if name == "jq" else name
with open(os.environ["SBOM_TEST_LOG"], "a") as log:
    log.write(gate + "\\n")
if name == "cargo":
    assert args[0] == "cyclonedx", args
    manifest = pathlib.Path(args[args.index("--manifest-path") + 1])
    basename = args[args.index("--override-filename") + 1]
    (manifest.parent / (basename + ".json")).write_text(os.environ["SBOM_TEST_CONTENT"])
elif name == "jq":
    # Simulate each validation gate independently without requiring jq locally.
    pathlib.Path(args[-1]).read_bytes()
    sys.exit(1 if failure == gate else 0)
elif name == "checksum":
    if failure == "checksum":
        sys.exit(1)
    assert args[:2] == ["-a", "256"], args
    path = pathlib.Path(args[2])
    print(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path))
elif name == "permissions":
    sys.exit(1)
"""
BASH_ENV = """cargo() { python3 "$SBOM_TEST_TOOL" cargo "$@"; }
cargo-cyclonedx() { :; }
jq() { python3 "$SBOM_TEST_TOOL" jq "$@"; }
shasum() { python3 "$SBOM_TEST_TOOL" checksum "$@"; }
if [[ "$SBOM_TEST_FAILURE" == permissions ]]; then
    chmod() { python3 "$SBOM_TEST_TOOL" permissions "$@"; }
fi
"""


class GenerateSBOMTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "config").mkdir()
        for crate in ("cli", "core", "uniffi"):
            (self.root / "crates" / crate).mkdir(parents=True)
        self.script = self.root / "scripts" / "generate-sbom.sh"
        shutil.copyfile(ROOT / "scripts" / "generate-sbom.sh", self.script)
        shutil.copyfile(ROOT / "config" / "release.toml", self.root / "config" / "release.toml")
        # Bash functions avoid executing fixture files on noexec temp mounts.
        self.tool = self.root / "tool-double.py"
        self.tool.write_text(TOOL_DOUBLE)
        self.bash_env = self.root / "bash-env"
        self.bash_env.write_text(BASH_ENV)
        self.log = self.root / "tool-calls"
        self.out = self.root / "output artifacts"
        self.out.mkdir()
        self.sbom = self.out / "DockBridge-sbom-test.cdx.json"
        self.checksum = self.out / (self.sbom.name + ".sha256")

    def generate(self, mask=0o022, failure=""):
        self.log.write_text("")
        env = dict(os.environ, HOME=str(self.root / "home"), VERSION="sbom-test",
                   APP_NAME="DockBridge", SBOM_TEST_CONTENT=SBOM,
                   BASH_ENV=str(self.bash_env), SBOM_TEST_TOOL=str(self.tool),
                   SBOM_TEST_LOG=str(self.log), SBOM_TEST_FAILURE=failure)
        return subprocess.run(["bash", str(self.script), "--out", str(self.out)],
                              env=env, umask=mask, capture_output=True, text=True)

    def seed_artifacts(self):
        self.sbom.write_text("previous SBOM\n")
        self.checksum.write_text("previous checksum\n")
        for path in (self.sbom, self.checksum):
            path.chmod(0o600)

    def assert_no_temporary_files(self):
        self.assertEqual(list(self.out.glob("*.tmp.*")), [])
        self.assertEqual(list((self.root / "crates").glob("*/dockbridge-sbom-*.json")), [])

    def test_publication_permissions_and_checksum(self):
        for mask in (0o022, 0o077):
            for existing in (False, True):
                with self.subTest(umask=oct(mask), existing=existing):
                    for path in (self.sbom, self.checksum):
                        if path.exists():
                            path.unlink()
                    if existing:
                        self.seed_artifacts()
                    result = self.generate(mask=mask)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.sbom.read_text(), SBOM)
                    digest = hashlib.sha256(self.sbom.read_bytes()).hexdigest()
                    self.assertEqual(self.checksum.read_text(), f"{digest}  {self.sbom.name}\n")
                    for path in (self.sbom, self.checksum):
                        with self.subTest(artifact=path.name):
                            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
                    self.assert_no_temporary_files()

    def assert_failed_publication(self, failure):
        for existing in (False, True):
            with self.subTest(failure=failure, existing=existing):
                for path in (self.sbom, self.checksum):
                    if path.exists():
                        path.unlink()
                if existing:
                    self.seed_artifacts()
                before = {p: (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                          for p in self.out.iterdir()}
                result = self.generate(failure=failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.log.read_text().splitlines()[-1], failure)
                after = {p: (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
                         for p in self.out.iterdir()}
                self.assertEqual(after, before)
                self.assert_no_temporary_files()

    def test_validation_failure_preserves_artifacts(self):
        for gate in ("schema", "components"):
            self.assert_failed_publication(gate)

    def test_checksum_failure_preserves_artifacts(self):
        self.assert_failed_publication("checksum")

    def test_permission_failure_preserves_artifacts(self):
        self.assert_failed_publication("permissions")


if __name__ == "__main__":
    unittest.main()
