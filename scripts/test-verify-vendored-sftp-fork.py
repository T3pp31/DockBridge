#!/usr/bin/env python3
"""Tests for verify-vendored-sftp-fork.py.

Run from the repository root: python3 scripts/test-verify-vendored-sftp-fork.py
"""

import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_module():
    spec = importlib.util.spec_from_file_location(
        "verify_vendored_sftp_fork", ROOT / "scripts" / "verify-vendored-sftp-fork.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VendoredForkTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_repository_pin_matches_vendored_version(self):
        self.assertEqual(
            self.module.pinned_requirement(),
            f"={self.module.vendored_version()}",
        )

    def test_repository_resolves_from_the_vendored_path(self):
        matches = [package for package in self.module.resolved_packages()
                   if package["name"] == self.module.CRATE]
        self.assertTrue(matches)
        for package in matches:
            self.assertIsNone(package.get("source"))
            self.assertEqual(
                pathlib.Path(package["manifest_path"]).resolve(),
                self.module.VENDOR_MANIFEST.resolve(),
            )

    def test_version_mismatch_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            vendor = root / "vendor" / "bssh-russh-sftp"
            vendor.mkdir(parents=True)
            (root / "Cargo.toml").write_text(
                '[workspace.dependencies]\nrussh-sftp = { package = "bssh-russh-sftp", '
                'version = "=2.4.0" }\n',
                encoding="utf-8",
            )
            (vendor / "Cargo.toml").write_text(
                '[package]\nname = "bssh-russh-sftp"\nversion = "2.5.0"\n',
                encoding="utf-8",
            )
            self.module.WORKSPACE_MANIFEST = root / "Cargo.toml"
            self.module.VENDOR_MANIFEST = vendor / "Cargo.toml"
            pinned = self.module.pinned_requirement()
            vendored = self.module.vendored_version()
            self.assertEqual(pinned, "=2.4.0")
            self.assertEqual(vendored, "2.5.0")
            self.assertNotEqual(pinned, f"={vendored}")


if __name__ == "__main__":
    unittest.main()
