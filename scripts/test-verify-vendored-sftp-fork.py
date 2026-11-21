#!/usr/bin/env python3
"""Tests for verify-vendored-sftp-fork.py.

Run from the repository root: python3 scripts/test-verify-vendored-sftp-fork.py
"""

import importlib.util
import pathlib
import contextlib
import io
import tempfile
import unittest
from unittest import mock

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

    def _fixture(self, directory, pin="=2.4.0", vendored="2.4.0"):
        root = pathlib.Path(directory)
        vendor = root / "vendor" / "bssh-russh-sftp"
        vendor.mkdir(parents=True)
        (root / "Cargo.toml").write_text(
            '[workspace.dependencies]\nrussh-sftp = { package = "bssh-russh-sftp", '
            f'version = "{pin}" }}\n',
            encoding="utf-8",
        )
        (vendor / "Cargo.toml").write_text(
            f'[package]\nname = "bssh-russh-sftp"\nversion = "{vendored}"\n',
            encoding="utf-8",
        )
        self.module.WORKSPACE_MANIFEST = root / "Cargo.toml"
        self.module.VENDOR_MANIFEST = vendor / "Cargo.toml"
        return vendor / "Cargo.toml"

    def _package(self, manifest, version="2.4.0", source=None):
        return {"name": self.module.CRATE, "version": version,
                "source": source, "manifest_path": str(manifest)}

    def _run_main(self, packages):
        stderr = io.StringIO()
        if isinstance(packages, Exception):
            patch = mock.patch.object(self.module, "resolved_packages", side_effect=packages)
        else:
            patch = mock.patch.object(self.module, "resolved_packages", return_value=packages)
        with patch, contextlib.redirect_stderr(stderr), \
                contextlib.redirect_stdout(io.StringIO()):
            code = self.module.main()
        return code, stderr.getvalue()

    def test_main_succeeds_when_pin_and_resolution_match(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._fixture(directory)
            code, stderr = self._run_main([self._package(manifest)])
        self.assertEqual(code, 0)
        self.assertEqual(stderr, "")

    def test_main_fails_on_version_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._fixture(directory, vendored="2.5.0")
            code, stderr = self._run_main([self._package(manifest, "2.5.0")])
        self.assertEqual(code, 1)
        self.assertIn("does not match vendored version", stderr)

    def test_main_reports_mismatch_even_when_cargo_metadata_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            self._fixture(directory, vendored="2.5.0")
            code, stderr = self._run_main(RuntimeError("cargo metadata failed"))
        self.assertEqual(code, 1)
        self.assertIn("does not match vendored version", stderr)
        self.assertIn("cargo metadata failed", stderr)

    def test_main_fails_when_resolved_from_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._fixture(directory)
            code, stderr = self._run_main([self._package(
                manifest, source="registry+https://github.com/rust-lang/crates.io-index")])
        self.assertEqual(code, 1)
        self.assertIn("not the vendored path", stderr)

    def test_main_fails_when_crate_is_missing_from_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            self._fixture(directory)
            code, stderr = self._run_main([])
        self.assertEqual(code, 1)
        self.assertIn("not in the resolved dependency graph", stderr)

    def test_main_fails_when_pin_is_unreadable(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._fixture(directory)
            self.module.WORKSPACE_MANIFEST.write_text("[workspace]\n", encoding="utf-8")
            code, stderr = self._run_main([self._package(manifest)])
        self.assertEqual(code, 1)
        self.assertIn("could not read", stderr)


if __name__ == "__main__":
    unittest.main()
