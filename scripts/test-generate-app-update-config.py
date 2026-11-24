#!/usr/bin/env python3
"""Offline tests for scripts/generate-app-update-config.sh (#403)."""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "generate-app-update-config.sh"
APP_UPDATE_CONFIG = ROOT / "apps" / "macos" / "DockBridge" / "Config" / "AppUpdateConfig.swift"
GENERATED_CONFIG = ROOT / "apps" / "macos" / "DockBridge" / "Generated" / "AppUpdateReleaseConfig.swift"

FIXTURE_TOML = """[release]
version = "0.1.6"
app_name = "DockBridge"
github_repo = "T3pp31/DockBridge"
bundle_identifier = "com.dockbridge.app"
team_id = ""
signing_certificate_fingerprint_sha256 = ""
require_signed_updates = true
require_notarized_updates = true
"""


class GenerateAppUpdateConfigTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="app-update-config-")
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name)
        (self.root / "scripts").mkdir()
        (self.root / "config").mkdir()
        shutil.copyfile(ROOT / "scripts" / "release-config.sh", self.root / "scripts" / "release-config.sh")
        shutil.copyfile(GENERATOR, self.root / "scripts" / "generate-app-update-config.sh")
        self.script = self.root / "scripts" / "generate-app-update-config.sh"
        self.config = self.root / "config" / "release.toml"
        self.config.write_text(FIXTURE_TOML)
        self.out = self.root / "apps" / "macos" / "DockBridge" / "Generated" / "AppUpdateReleaseConfig.swift"

    def run_gen(self, *args):
        return subprocess.run(
            ["bash", str(self.script), *args],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_repo_generated_file_matches_release_toml(self):
        result = subprocess.run(
            ["bash", str(GENERATOR), "--check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(GENERATED_CONFIG.is_file())

    def test_app_update_config_delegates_to_generated_constants(self):
        source = APP_UPDATE_CONFIG.read_text()
        for prop in (
            "githubRepo",
            "appName",
            "bundleIdentifier",
            "expectedTeamIdentifier",
            "signingCertificateFingerprintSHA256",
            "requireSignedUpdates",
            "requireNotarizedUpdates",
        ):
            with self.subTest(property=prop):
                self.assertIn(f"AppUpdateReleaseConfig.{prop}", source)

    def test_generates_default_and_signed_configs_and_checks_drift(self):
        # Missing output fails --check.
        missing = self.run_gen("--check")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("out of date", missing.stderr)

        # Generate with default empty signing fields.
        gen = self.run_gen()
        self.assertEqual(gen.returncode, 0, gen.stderr)
        text = self.out.read_text()
        self.assertIn('static let githubRepo = "T3pp31/DockBridge"', text)
        self.assertIn('static let appName = "DockBridge"', text)
        self.assertIn('static let bundleIdentifier = "com.dockbridge.app"', text)
        self.assertIn('static let expectedTeamIdentifier = ""', text)
        self.assertIn('static let signingCertificateFingerprintSHA256 = ""', text)
        self.assertIn("static let requireSignedUpdates = true", text)
        self.assertIn("static let requireNotarizedUpdates = true", text)

        # --check succeeds when up to date.
        ok = self.run_gen("--check")
        self.assertEqual(ok.returncode, 0, ok.stderr)

        # Idempotent re-run preserves mtime.
        old_mtime = self.out.stat().st_mtime_ns - 10_000_000_000
        os.utime(self.out, ns=(old_mtime, old_mtime))
        rerun = self.run_gen()
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertEqual(self.out.stat().st_mtime_ns, old_mtime)

        # Mutate config/release.toml with populated signing fields -> --check fails.
        self.config.write_text(
            FIXTURE_TOML
            .replace('team_id = ""', 'team_id = "AB12CD34EF"')
            .replace(
                'signing_certificate_fingerprint_sha256 = ""',
                'signing_certificate_fingerprint_sha256 = "' + "ab" * 32 + '"',
            )
            .replace("require_notarized_updates = true", "require_notarized_updates = false")
        )
        drifted = self.run_gen("--check")
        self.assertNotEqual(drifted.returncode, 0)

        # Regenerating picks up new values and passes --check.
        regen = self.run_gen()
        self.assertEqual(regen.returncode, 0, regen.stderr)
        updated = self.out.read_text()
        self.assertIn('static let expectedTeamIdentifier = "AB12CD34EF"', updated)
        self.assertIn(f'static let signingCertificateFingerprintSHA256 = "{"ab" * 32}"', updated)
        self.assertIn("static let requireNotarizedUpdates = false", updated)
        self.assertEqual(self.run_gen("--check").returncode, 0)

    def test_rejects_invalid_values_and_arguments(self):
        for bad_line in (
            'github_repo = "not-a-repo"',
            'github_repo = "owner/repo/extra"',
            'bundle_identifier = "com.dockbridge/evil"',
            'team_id = "TEAM;evil"',
            'signing_certificate_fingerprint_sha256 = "not-hex-xyz"',
        ):
            with self.subTest(bad_line=bad_line):
                key = bad_line.split("=", 1)[0].strip()
                lines = [
                    bad_line if line.startswith(f"{key} =") else line
                    for line in FIXTURE_TOML.splitlines()
                ]
                self.config.write_text("\n".join(lines) + "\n")
                result = self.run_gen()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.out.exists())

        self.config.write_text(FIXTURE_TOML)
        for bad_args in (("--unknown",), ("--out",), ("--check", "--check")):
            with self.subTest(args=bad_args):
                self.assertNotEqual(self.run_gen(*bad_args).returncode, 0)


if __name__ == "__main__":
    unittest.main()
