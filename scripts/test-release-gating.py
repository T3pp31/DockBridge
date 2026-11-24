#!/usr/bin/env python3
"""Guard the release workflow's test gate (issue #1365).

A tag push does not run ci.yml, so release.yml must run the same tests
before publishing. These checks fail if the gate is removed or if the
release test steps drift from ci.yml.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
MACOS_TEST_ACTION = ROOT / ".github" / "actions" / "run-macos-tests" / "action.yml"
MACOS_TEST_ACTION_REF = "./.github/actions/run-macos-tests"
MACOS_DIAG_ACTION = ROOT / ".github" / "actions" / "upload-macos-test-diagnostics" / "action.yml"
MACOS_DIAG_ACTION_REF = "./.github/actions/upload-macos-test-diagnostics"


def jobs(text):
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\n", body)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts), 2)}


def step(job_text, name, indent="      "):
    match = re.search(
        rf"(?ms)^{indent}- name: {re.escape(name)}\n.*?(?=^{indent}- name: |\Z)", job_text
    )
    if match is None:
        raise AssertionError(f"step {name!r} not found")
    return match.group(0).rstrip()


class ReleaseGatingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = jobs((WORKFLOWS / "release.yml").read_text())
        cls.ci = jobs((WORKFLOWS / "ci.yml").read_text())
        cls.action = MACOS_TEST_ACTION.read_text()
        cls.diag_action = MACOS_DIAG_ACTION.read_text()

    def test_release_job_needs_test_job(self):
        self.assertIn("test", self.release)
        self.assertRegex(self.release["release"], r"(?m)^    needs: (test|\[.*\btest\b.*\])$")

    def test_test_job_runs_rust_and_macos_suites(self):
        test_job = self.release["test"]
        self.assertIn("run: cargo test --workspace --all-targets", test_job)
        self.assertIn(f"uses: {MACOS_TEST_ACTION_REF}", test_job)
        self.assertIn("run: python3 scripts/test-release-gating.py", test_job)
        self.assertIn("build-for-testing", self.action)
        self.assertIn("test-without-building", self.action)

    def test_macos_test_steps_share_composite_action(self):
        for step_name, action_ref in (
            ("Build and test macOS app", MACOS_TEST_ACTION_REF),
            ("Upload macOS test diagnostics", MACOS_DIAG_ACTION_REF),
        ):
            with self.subTest(step=step_name):
                ci_step = step(self.ci["macos"], step_name)
                release_step = step(self.release["test"], step_name)
                self.assertEqual(release_step, ci_step)
                self.assertIn(f"uses: {action_ref}", release_step)
        # Ensure neither workflow duplicates xcodebuild build/test steps inline.
        self.assertNotIn("build-for-testing", self.ci["macos"])
        self.assertNotIn("test-without-building", self.ci["macos"])
        self.assertNotIn("build-for-testing", self.release["test"])
        self.assertNotIn("test-without-building", self.release["test"])
        # Composite actions must not use invalid composite-level `timeout-minutes:`.
        self.assertNotRegex(self.action, r"(?m)^\s*timeout-minutes:")
        self.assertNotRegex(self.diag_action, r"(?m)^\s*timeout-minutes:")
        for name in (
            "Build macOS app (for testing)",
            "Test macOS app",
            "Verify macOS test result counts",
        ):
            with self.subTest(step=name):
                self.assertTrue(step(self.action, name, indent="    "))
        for name in (
            "List failed tests from xcresult",
            "Upload macOS test artifacts",
        ):
            with self.subTest(step=name):
                self.assertTrue(step(self.diag_action, name, indent="    "))

    def test_static_and_artifact_consistency_checks_match_ci(self):
        # Issue #1434: a tag push / workflow_dispatch does not run ci.yml, so
        # the pre-release test gate must also run CI's localization, Settings
        # wiring, xcodeproj, and UniFFI Swift binding consistency checks.
        test_job = self.release["test"]
        for step_name in (
            "Verify localization catalog (en + ja)",
            "Verify AppUpdateReleaseConfig matches config/release.toml",
            "Guard Settings scene state wiring",
            "Build Rust static library",
            "Generate UniFFI bindings",
            "Install pinned XcodeGen",
            "Verify xcodeproj matches project.yml (xcodegen)",
            "Verify committed Swift bindings are up to date",
        ):
            with self.subTest(step=step_name):
                self.assertEqual(step(test_job, step_name), step(self.ci["macos"], step_name))

        def step_pos(name):
            return test_job.index(f"      - name: {name}\n")

        build_and_test = step_pos("Build and test macOS app")
        self.assertLess(step_pos("Verify localization catalog (en + ja)"), build_and_test)
        self.assertLess(step_pos("Verify AppUpdateReleaseConfig matches config/release.toml"), build_and_test)
        self.assertLess(step_pos("Guard Settings scene state wiring"), build_and_test)
        self.assertLess(
            step_pos("Build Rust static library"),
            step_pos("Generate UniFFI bindings"),
        )
        self.assertLess(
            step_pos("Install pinned XcodeGen"),
            step_pos("Verify xcodeproj matches project.yml (xcodegen)"),
        )
        self.assertLess(step_pos("Verify xcodeproj matches project.yml (xcodegen)"), build_and_test)
        self.assertLess(
            step_pos("Generate UniFFI bindings"),
            step_pos("Verify committed Swift bindings are up to date"),
        )
        self.assertLess(step_pos("Verify committed Swift bindings are up to date"), build_and_test)

    def test_rust_test_command_matches_ci(self):
        self.assertIn("run: cargo test --workspace --all-targets", self.ci["macos"])

    def test_publish_permissions_only_on_release_job(self):
        for perm in ("contents: write", "id-token: write", "attestations: write"):
            with self.subTest(permission=perm):
                self.assertNotIn(perm, self.release["test"])
                self.assertNotIn(perm, self.release["build"])
                self.assertIn(perm, self.release["release"])

    def test_build_job_isolates_cargo_and_xcode_from_release_secrets(self):
        # Issue #1227: Rust/Cargo/Xcode builds must run on a separate runner
        # without signing secrets, and the signing/publishing job must never
        # invoke Cargo or Xcode builds.
        self.assertIn("build", self.release)
        self.assertRegex(self.release["release"], r"(?m)^    needs: \[.*\bbuild\b.*\]$")
        self.assertNotIn("secrets.", self.release["test"])
        self.assertNotIn("secrets.", self.release["build"])
        release_job = self.release["release"]
        for forbidden in (
            "cargo", "rust-toolchain", "build-rust.sh", "generate-uniffi.sh",
            "xcodebuild", "xcodegen", MACOS_TEST_ACTION_REF,
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, release_job)
        self.assertIn("PREBUILT_APP_PATH:", release_job)


if __name__ == "__main__":
    unittest.main()
