#!/usr/bin/env python3
"""Test release metadata and workflow consumers offline, without build tools."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEYS = (
    "version", "app_name", "asset_name_template", "sbom_name_template",
    "cargo_cyclonedx_version", "xcodegen_version", "xcodegen_sha256",
)
CONFIG = '''[release]
version = "1.2.3"
app_name = "Fixture App"
asset_name_template = "{app_name}-{version}-macOS.dmg"
sbom_name_template = "{app_name}-{version}.cdx.json"
cargo_cyclonedx_version = "0.5.9"
xcodegen_version = "2.45.4"
xcodegen_sha256 = "''' + "a" * 64 + '''"
'''


def workflow_block(workflow, name):
    """Extract only the named literal run block, with no YAML dependency."""
    text = (ROOT / ".github" / "workflows" / workflow).read_text()
    step = text.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
    block = step.split("        run: |\n", 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:])
    return "\n".join(lines)


class ReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release config ")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "config").mkdir()
        self.other_cwd = self.root / "unrelated directory"
        self.other_cwd.mkdir()
        self.script = self.root / "scripts" / "release-config.sh"
        shutil.copyfile(ROOT / "scripts" / "release-config.sh", self.script)
        self.config = self.root / "config" / "release.toml"
        self.config.write_text(CONFIG)
        (self.root / "Cargo.toml").write_text('[workspace.package]\nversion = "1.2.3"\n')
        self.output = self.root / "output"
        self.output.write_text("")
        self.env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(self.output)}

    def read(self, *args):
        # Do not run at the repo root: paths must be relative to the helper.
        return subprocess.run(
            ["bash", str(self.script), *args], cwd=self.other_cwd, env=self.env,
            capture_output=True, text=True, timeout=5,
        )

    def run_step(self, workflow, name, version="1.2.3", preamble=""):
        block = workflow_block(workflow, name).replace(
            "${{ steps.version.outputs.version }}", version)
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", preamble + block],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=5,
        )

    def assert_failure(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(result.stderr)

    def test_current_workflow_keys(self):
        text = (ROOT / "config" / "release.toml").read_text()
        self.config.write_text(text)
        for key in KEYS:
            with self.subTest(key=key):
                expected = re.search(rf'^{key} = "([^"]+)"$', text, re.MULTILINE)[1]
                result = self.read(key)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected + "\n")

    def test_whitespace_comments_crlf_and_section_scope(self):
        self.config.write_bytes(
            b'version = "root"\r\n[other]\r\nversion = "wrong"\r\n'
            b'  [release] # metadata\r\n\tversion\t=\t"1.2.3-rc.1+build" # comment\r\n'
            b'[verification]\r\nversion = "also wrong"\r\n')
        result = self.read("version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.2.3-rc.1+build\n")

    def test_values_are_not_evaluated(self):
        value = '$(touch unexpected); `false` # {version}'
        self.config.write_text(f'[release]\napp_name = "{value}" # trailing "quote"\n')
        result = self.read("app_name")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, value + "\n")
        self.assertFalse((self.other_cwd / "unexpected").exists())

    def test_missing_empty_duplicate_and_unsupported_values_fail(self):
        for content in (
            '[other]\nversion = "1.2.3"\n',
            '[release]\n# version = "1.2.3"\n',
            '[release]\nversion_extra = "1.2.3"\n',
            '[release]\nversion = ""\n',
            '[release]\nversion = "1.2.3"\nversion = "1.2.4"\n',
            '[release]\nversion = true\n',
            '[release]\nversion = "unterminated\n',
            '[release]\nversion = "1.2.3" trailing\n',
            '[release]\nversion = """multiline"""\n',
            '[release]\nversion = "escaped\\nvalue"\n',
        ):
            with self.subTest(content=content):
                self.config.write_text(content)
                self.assert_failure(self.read("version"))

    def test_missing_file_and_invalid_arguments_fail(self):
        self.config.unlink()
        self.assert_failure(self.read("version"))
        for args in ((), ("version", "extra"), (".*",), ("",)):
            with self.subTest(args=args):
                self.assert_failure(self.read(*args))

    def test_version_guards_preserve_matching_and_mismatching_behavior(self):
        guards = (
            ("ci.yml", "Check version consistency (Cargo.toml == release.toml)"),
            ("release.yml", "Verify release.toml / Cargo.toml match the tag version"),
        )
        for workflow, name in guards:
            with self.subTest(workflow=workflow, case="match"):
                result = self.run_step(workflow, name)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path in (self.config, self.root / "Cargo.toml"):
                with self.subTest(workflow=workflow, mismatch=path.name):
                    original = path.read_text()
                    path.write_text(original.replace('"1.2.3"', '"9.8.7"'))
                    result = self.run_step(workflow, name)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("!=", result.stderr)
                    path.write_text(original)
            with self.subTest(workflow=workflow, case="missing release version"):
                self.config.write_text('[release]\n')
                self.assert_failure(self.run_step(workflow, name))
                self.config.write_text(CONFIG)
        result = self.run_step(*guards[1], version="1.2.4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("!= tag version", result.stderr)

    def test_cyclonedx_and_asset_outputs(self):
        result = self.run_step("ci.yml", "Resolve cargo-cyclonedx version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "version=0.5.9\n")
        result = self.run_step(
            "release.yml", "Install cargo-cyclonedx",
            preamble='cargo() { printf "%s\\n" "$*" > "$GITHUB_OUTPUT"; }\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "install cargo-cyclonedx --version 0.5.9 --locked\n")
        self.output.write_text("")
        result = self.run_step("release.yml", "Resolve asset paths", version="1.2.3-rc.1+build")
        self.assertEqual(result.returncode, 0, result.stderr)
        version = "1.2.3-rc.1+build"
        dmg = f"dist/Fixture App-{version}-macOS.dmg"
        cli = f"dist/dockbridge-{version}-macOS"
        sbom = f"dist/Fixture App-{version}.cdx.json"
        self.assertEqual(self.output.read_text().splitlines(), [
            f"dmg={dmg}", f"sha256={dmg}.sha256", f"cli={cli}",
            f"cli_sha256={cli}.sha256", f"sbom={sbom}", f"sbom_sha256={sbom}.sha256",
        ])

    def test_missing_tool_and_asset_keys_stop_before_publication(self):
        for key, workflow, name in (
            ("cargo_cyclonedx_version", "ci.yml", "Resolve cargo-cyclonedx version"),
            ("cargo_cyclonedx_version", "release.yml", "Install cargo-cyclonedx"),
            ("app_name", "release.yml", "Resolve asset paths"),
            ("asset_name_template", "release.yml", "Resolve asset paths"),
            ("sbom_name_template", "release.yml", "Resolve asset paths"),
        ):
            with self.subTest(key=key, workflow=workflow):
                self.config.write_text(re.sub(rf"^{key} = .*\n", "", CONFIG, flags=re.MULTILINE))
                result = self.run_step(
                    workflow, name,
                    preamble='cargo() { echo unexpected > "$GITHUB_OUTPUT"; }\n')
                self.assert_failure(result)
                self.assertEqual(self.output.read_text(), "")

    def test_xcodegen_validation_still_precedes_download(self):
        # Stop unconditionally at curl; these tests never download or install tools.
        self.env.update(RUNNER_TEMP=str(self.root), GITHUB_PATH=str(self.output))
        preamble = 'curl() { echo download > "$GITHUB_OUTPUT"; return 99; }\n'
        result = self.run_step("ci.yml", "Install pinned XcodeGen", preamble=preamble)
        self.assertEqual(result.returncode, 99, result.stdout + result.stderr)
        self.assertEqual(self.output.read_text(), "download\n")
        self.output.write_text("")
        for key in ("xcodegen_version", "xcodegen_sha256"):
            with self.subTest(key=key):
                self.config.write_text(re.sub(
                    rf'^{key} = .*$', f'{key} = "invalid"', CONFIG, flags=re.MULTILINE))
                result = self.run_step(
                    "ci.yml", "Install pinned XcodeGen",
                    preamble='curl() { echo unexpected > "$GITHUB_OUTPUT"; return 99; }\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Invalid {key}", result.stdout)
                self.assertEqual(self.output.read_text(), "")

    def test_workflows_use_shared_reader(self):
        used_keys = set()
        for workflow in ("ci.yml", "release.yml"):
            text = (ROOT / ".github" / "workflows" / workflow).read_text()
            used_keys.update(re.findall(r"bash scripts/release-config\.sh ([a-z_][a-z0-9_]*)", text))
            self.assertNotRegex(text, r"awk[^\n]*config/release\.toml")
        self.assertEqual(used_keys, set(KEYS))


if __name__ == "__main__":
    unittest.main()
