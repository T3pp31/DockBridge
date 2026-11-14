#!/usr/bin/env python3
"""Guard macOS Rust test coverage without running Rust or Xcode (#1332).

These source checks intentionally follow ci.yml's job/step indentation, not
arbitrary YAML. Only the test command is executed, with cargo mocked.
"""
import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
STEP_NAME = "Test Rust workspace (all targets)"


class MacOSRustCITests(unittest.TestCase):
    def setUp(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = re.search(r"^  macos:\n(.*?)(?=^  [\w-]+:|\Z)", workflow, re.M | re.S)
        self.assertIsNotNone(job, "macOS job must exist")
        self.job = job.group(1)
        step = re.search(
            rf"^      - name: {re.escape(STEP_NAME)}\n(.*?)(?=^      - name: |\Z)",
            self.job, re.M | re.S,
        )
        self.assertIsNotNone(step, "macOS must explicitly run Rust tests")
        # Require a direct, unconditional host command: no --no-run, filters,
        # cross-compilation target, continue-on-error, or shell failure masking.
        self.assertEqual(step.group(1).strip(), "run: cargo test --workspace --all-targets")
        self.command = step.group(1).strip().removeprefix("run: ")

    def test_runs_on_macos_after_rust_setup_and_builds_before_swift(self):
        self.assertRegex(self.job, r"(?m)^    runs-on: macos-[\w.-]+$")
        test_position = self.job.index(f"- name: {STEP_NAME}")
        for name in ("Install Rust toolchain", "Cache Rust", "Build Rust static library",
                     "Build x86_64 (Intel) Rust static library"):
            with self.subTest(step=name):
                self.assertLess(self.job.index(f"- name: {name}\n"), test_position)
        self.assertLess(test_position, self.job.index("- name: Build macOS app (for testing)\n"))

    def test_test_success_and_failure_are_propagated(self):
        # Exercise the actual run value in an isolated shell. No real tools,
        # credentials, network access, or shell startup hooks are inherited.
        stub = 'cargo() { printf "%s\\n" "$@"; return "$CARGO_TEST_EXIT"; }\n'
        for code in (0, 101):
            with self.subTest(cargo_exit=code):
                result = subprocess.run(
                    [BASH, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c",
                     stub + self.command],
                    env={"PATH": "", "CARGO_TEST_EXIT": str(code)},
                    capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.stdout.splitlines(), ["test", "--workspace", "--all-targets"])
                self.assertEqual(result.returncode, code, result.stderr)


if __name__ == "__main__":
    unittest.main()
