#!/usr/bin/env python3
"""Run CI's build/test blocks with a fake xcodebuild, without Xcode or a build."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
BUILD = "Build macOS app (for testing)"
TEST = "Test macOS app"
# Shell functions also work on noexec filesystems. Mock only process lookup,
# xcodebuild, and the watchdog's exec boundary, not the workflow's control flow.
STUBS = r'''
pgrep() { return 1; }
xcodebuild() { "$MOCK_PYTHON" "$MOCK_XCODEBUILD" "$@"; }
perl() {
    [[ "$1" == -e && "$3" == -- ]] || return 90
    shift 3
    "$@"
}
'''
DEFAULTS = {
    "XCODEBUILD_SCHEME": "DockBridge",
    "XCODEBUILD_DESTINATION": "platform=macOS",
    "XCODEBUILD_CONFIGURATION": "Debug",
    "XCODEBUILD_CODE_SIGN_IDENTITY": "-",
    "XCODEBUILD_CODE_SIGNING_REQUIRED": "NO",
    "XCODEBUILD_CODE_SIGNING_ALLOWED": "NO",
    "XCODEBUILD_DEVELOPMENT_TEAM": "",
}


def environment(block, indent):
    # Read only the workflow's quoted string env entries (no YAML dependency).
    match = re.search(rf"^{indent}env:\n((?:{indent}  .*\n)+)", block, re.MULTILINE)
    if not match:
        return {}
    return {
        key: json.loads(value)
        for key, value in re.findall(
            rf"^{indent}  (\w+): (.*)$", match[1], re.MULTILINE)
    }


class CIXcodebuildTests(unittest.TestCase):
    def setUp(self):
        macos = WORKFLOW.read_text().split("  macos:\n", 1)[1]
        self.job_env = environment(macos, "    ")
        self.steps = {}
        for name in (BUILD, TEST):
            block = re.search(
                rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |\Z)",
                macos, re.MULTILINE | re.DOTALL)[1]
            run = re.search(
                r"^        run: \|\n((?:          .*\n|\n)+)",
                block, re.MULTILINE)[1]
            self.steps[name] = (textwrap.dedent(run), environment(block, "        "))
        temporary = tempfile.TemporaryDirectory(prefix="ci-xcodebuild-")
        self.addCleanup(temporary.cleanup)
        self.directory = pathlib.Path(temporary.name)
        self.calls = self.directory / "calls.jsonl"
        self.mock = self.directory / "xcodebuild.py"
        self.mock.write_text('''import json
import os
import sys
with open(os.environ["CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ["XCODEBUILD_EXIT"]))
''')

    def run_step(self, name, overrides=None, status=0):
        self.calls.unlink(missing_ok=True)
        run, step_env = self.steps[name]
        # Keep result bundles/log cleanup inside the fixture. Never inspect or
        # signal real app processes; only normal success and exit 65 run here.
        run = run.replace("/tmp/xcodebuild-test-attempt-",
                          str(self.directory / "xcodebuild-test-attempt-"))
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c",
             STUBS + run],
            env={"PATH": os.defpath,
                 "MOCK_PYTHON": sys.executable, "MOCK_XCODEBUILD": str(self.mock),
                 "CALLS": str(self.calls), "XCODEBUILD_EXIT": str(status),
                 **self.job_env, **(overrides or {}), **step_env},
            cwd=self.directory, capture_output=True, text=True, timeout=5,
        )
        calls = ([json.loads(line) for line in self.calls.read_text().splitlines()]
                 if self.calls.exists() else [])
        return result, calls

    def expected_args(self, name, values):
        args = [
            "-scheme", values["XCODEBUILD_SCHEME"],
            "-destination", values["XCODEBUILD_DESTINATION"],
            "-configuration", values["XCODEBUILD_CONFIGURATION"],
            "build-for-testing" if name == BUILD else "test-without-building",
        ]
        if name == TEST:
            args += ["-test-timeouts-enabled", "YES",
                     "-default-test-execution-time-allowance", "300",
                     "-resultBundlePath",
                     str(self.directory / "xcodebuild-test-attempt-1.xcresult")]
        return args + [
            f"{key}={values['XCODEBUILD_' + key]}" for key in (
                "CODE_SIGN_IDENTITY", "CODE_SIGNING_REQUIRED",
                "CODE_SIGNING_ALLOWED", "DEVELOPMENT_TEAM")
        ]

    def test_shared_defaults_preserve_existing_build_and_test_arguments(self):
        self.assertEqual({key: value for key, value in self.job_env.items()
                          if key.startswith("XCODEBUILD_")}, DEFAULTS)
        for name in (BUILD, TEST):
            with self.subTest(step=name):
                result, calls = self.run_step(name)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(calls, [self.expected_args(name, DEFAULTS)])

    def test_both_steps_use_shared_values_without_splitting_or_evaluation(self):
        values = {
            "XCODEBUILD_SCHEME": "Fixture Scheme",
            "XCODEBUILD_DESTINATION": "platform=macOS,arch=arm64",
            "XCODEBUILD_CONFIGURATION": "Fixture Debug",
            "XCODEBUILD_CODE_SIGN_IDENTITY": "Fixture Identity $HOME * ;",
            "XCODEBUILD_CODE_SIGNING_REQUIRED": "YES",
            "XCODEBUILD_CODE_SIGNING_ALLOWED": "YES",
            "XCODEBUILD_DEVELOPMENT_TEAM": "Fixture Team",
        }
        for name in (BUILD, TEST):
            with self.subTest(step=name):
                result, calls = self.run_step(name, overrides=values)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(calls, [self.expected_args(name, values)])

    def test_xcodebuild_failure_is_not_hidden_or_retried(self):
        for name in (BUILD, TEST):
            with self.subTest(step=name):
                result, calls = self.run_step(name, status=65)
                self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                self.assertEqual(calls, [self.expected_args(name, DEFAULTS)])


if __name__ == "__main__":
    unittest.main()
