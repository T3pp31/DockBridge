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
    "version", "app_name", "asset_name_template", "cli_name_template",
    "sbom_name_template", "cargo_cyclonedx_version", "xcodegen_version",
    "xcodegen_sha256",
)
CONFIG = '''[release]
version = "1.2.3"
app_name = "Fixture App"
asset_name_template = "{app_name}-{version}-macOS.dmg"
cli_name_template = "dockbridge-{version}-macOS"
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

    def run_step(self, workflow, name, version="1.2.3", preamble="", cli_name=None,
                 event_name="push"):
        block = workflow_block(workflow, name).replace(
            "${{ steps.version.outputs.version }}", version)
        block = block.replace(
            "${{ steps.version.outputs.cli_name }}",
            cli_name if cli_name is not None else f"dockbridge-{version}-macOS")
        block = block.replace("${{ github.event_name }}", event_name)
        env = dict(self.env)
        # `Resolve version` derives the version from the tag on a tag push.
        # Always override: CI runners set their own GITHUB_REF_NAME.
        env["GITHUB_REF_NAME"] = f"v{version}"
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", preamble + block],
            cwd=self.root, env=env, capture_output=True, text=True, timeout=5,
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
            "app_name=Fixture App",
            f"dmg={dmg}", f"sha256={dmg}.sha256", f"cli={cli}",
            f"cli_sha256={cli}.sha256", f"sbom={sbom}", f"sbom_sha256={sbom}.sha256",
        ])

    def test_custom_cli_template_flows_to_build_and_assets(self):
        self.config.write_text(CONFIG.replace(
            'cli_name_template = "dockbridge-{version}-macOS"',
            'cli_name_template = "{app_name}-cli-{version}"'))
        result = self.run_step("release.yml", "Resolve version")
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = dict(
            line.split("=", 1) for line in self.output.read_text().splitlines())
        self.assertEqual(outputs["version"], "1.2.3")
        self.assertEqual(outputs["prerelease"], "false")
        self.assertEqual(outputs["cli_name"], "Fixture App-cli-1.2.3")
        self.output.write_text("")
        result = self.run_step(
            "release.yml", "Resolve asset paths", cli_name=outputs["cli_name"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cli=dist/Fixture App-cli-1.2.3", self.output.read_text().splitlines())

    def test_unresolved_cli_placeholder_fails(self):
        self.config.write_text(CONFIG.replace(
            'cli_name_template = "dockbridge-{version}-macOS"',
            'cli_name_template = "dockbridge-{versoin}-macOS"'))
        result = self.run_step("release.yml", "Resolve version")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported placeholder", result.stderr)
        self.assertEqual(self.output.read_text(), "")

    def test_unresolved_asset_and_sbom_placeholders_fail(self):
        cases = (
            (
                'asset_name_template = "{app_name}-{version}-macOS.dmg"',
                'asset_name_template = "{app_name}-{versoin}-macOS.dmg"',
            ),
            (
                'sbom_name_template = "{app_name}-{version}.cdx.json"',
                'sbom_name_template = "{app_name}-{unknown}.cdx.json"',
            ),
        )
        for old, new in cases:
            with self.subTest(template=new):
                self.output.write_text("")
                self.config.write_text(CONFIG.replace(old, new))
                result = self.run_step("release.yml", "Resolve asset paths")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsupported placeholder", result.stderr)
                self.assertEqual(self.output.read_text(), "")

    def test_expand_mode_handles_placeholders_overrides_and_invalid_inputs(self):
        result = self.read("--expand", "asset_name_template", "--version", "2.0.0-rc.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Fixture App-2.0.0-rc.1-macOS.dmg\n")

        result = self.read(
            "--expand", "sbom_name_template", "--version", "2.0.0", "--app-name", "Custom App"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Custom App-2.0.0.cdx.json\n")

        # Reject missing --version, braces in replacement values, and unsupported combinations.
        for bad_args in (
            ("--expand", "asset_name_template"),
            ("--expand", "asset_name_template", "--version", "{app_name}"),
            ("--expand", "asset_name_template", "--version", "1.0.0", "--app-name", "{version}"),
            ("--expand", "asset_name_template", "--version", "1.0.0", "--app-name", ""),
            ("--expand", "asset_name_template", "--bool", "--version", "1.0.0"),
        ):
            with self.subTest(args=bad_args):
                self.assert_failure(self.read(*bad_args))

    def test_downstream_steps_read_resolved_names(self):
        build = workflow_block("release.yml", "Build hardened CLI")
        self.assertIn("${{ steps.version.outputs.cli_name }}", build)
        self.assertNotIn("dockbridge-${VERSION}", build)
        text = (ROOT / ".github" / "workflows" / "release.yml").read_text()
        self.assertIn(
            "name: ${{ needs.build.outputs.app_name }} ${{ needs.build.outputs.version }}",
            text)

    def test_missing_tool_and_asset_keys_stop_before_publication(self):
        for key, workflow, name in (
            ("cargo_cyclonedx_version", "ci.yml", "Resolve cargo-cyclonedx version"),
            ("cargo_cyclonedx_version", "release.yml", "Install cargo-cyclonedx"),
            ("app_name", "release.yml", "Resolve asset paths"),
            ("asset_name_template", "release.yml", "Resolve asset paths"),
            # Resolved once in `Resolve version`; downstream steps read the
            # output instead of re-reading the template (issue #1363).
            ("cli_name_template", "release.yml", "Resolve version"),
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
            used_keys.update(re.findall(r"bash scripts/release-config\.sh (?:--expand )?([a-z_][a-z0-9_]*)", text))
            self.assertNotRegex(text, r"awk[^\n]*config/release\.toml")
            self.assertNotRegex(text, r"awk[^\n]*Cargo\.toml")
            self.assertNotRegex(text, r"//\\\{(?:app_name|version)\\\}/")
        self.assertEqual(used_keys, set(KEYS))

    def test_scripts_use_shared_reader_without_adhoc_awk(self):
        for script in sorted((ROOT / "scripts").glob("*.sh")):
            if script.name == "release-config.sh":
                continue
            text = script.read_text()
            with self.subTest(script=script.name):
                self.assertNotRegex(text, r"awk[^\n]*(?:config/release\.toml|RELEASE_CONFIG)")
                self.assertNotRegex(text, r"awk[^\n]*Cargo\.toml")
                self.assertNotRegex(text, r"//\\\{(?:app_name|version)\\\}/")

    def test_bool_int_section_and_cargo_version_modes(self):
        text = (ROOT / "config" / "release.toml").read_text()
        self.config.write_text(text)
        for key in ("require_signed_updates", "require_notarized_updates"):
            result = self.read("--bool", key)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(result.stdout.strip(), ("true", "false"))
        self.assert_failure(self.read("--bool", "version"))

        result = self.read("--section", "verification", "offline_api_host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "api.github.com")
        for key in ("offline_probe_timeout_secs", "offline_observation_secs", "offline_poll_interval_secs"):
            result = self.read("--section", "verification", "--int", key)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout.strip(), r"^[0-9]+$")
        self.assert_failure(self.read("--section", "verification", "--int", "offline_api_host"))

        (self.root / "Cargo.toml").write_text(
            '[dependencies]\nversion = "9.9.9"\n[workspace.package]\nversion = "2.3.4"\n[other]\nversion = "8.8.8"\n'
        )
        result = self.read("--cargo-version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "2.3.4\n")
        self.assert_failure(self.read("--cargo-version", "version"))

    def concurrency_block(self):
        text = (ROOT / ".github" / "workflows" / "release.yml").read_text()
        block = re.search(r"^concurrency:\n((?:[ \t]+.*\n)+)", text, re.MULTILINE)
        self.assertIsNotNone(block, "release.yml has no workflow-level concurrency")
        return block[1]

    def test_release_concurrency_normalizes_the_version(self):
        # A dispatch for 1.0.0 must share the concurrency group of a v1.0.0
        # tag push, or the two runs publish concurrently (issue #1364).
        block = self.concurrency_block()
        match = re.search(
            r"""^\s*group:\s*["']?release-\$\{\{\s*(.+?)\s*&&\s*(.+?)\s*\|\|\s*(.+?)\s*\}\}""",
            block, re.MULTILINE)
        self.assertIsNotNone(match, block)
        condition, dispatch, tag = (re.sub(r"\s+", "", part) for part in match.groups())
        self.assertEqual(condition, "github.event_name=='workflow_dispatch'")
        self.assertEqual(dispatch, "format('v{0}',github.event.inputs.version)")
        self.assertEqual(tag, "github.ref_name")

        def group(event_name, version="", ref_name=""):
            # Mirrors the expression's semantics for the fixed parts above.
            if event_name == "workflow_dispatch" and version:
                return f"release-v{version}"
            return f"release-{ref_name}"

        self.assertEqual(group("workflow_dispatch", version="1.0.0"),
                         group("push", ref_name="v1.0.0"))
        self.assertNotEqual(group("workflow_dispatch", version="2.0.0"),
                            group("push", ref_name="v1.0.0"))

    def test_release_concurrency_waits_instead_of_cancelling(self):
        # Cancelling would abort an in-progress publish of the same release.
        self.assertRegex(self.concurrency_block(),
                         r"(?m)^\s*cancel-in-progress:\s*false\s*$")


if __name__ == "__main__":
    unittest.main()
