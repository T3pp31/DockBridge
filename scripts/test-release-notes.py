#!/usr/bin/env python3
"""Exercise the release workflow's notes step offline with real awk and grep."""
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def notes_script():
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    step = workflow.split("      - name: Extract release notes\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    script = textwrap.dedent(step.split("        run: |\n", 1)[1])
    return script.replace("${{ steps.version.outputs.version }}", "${TEST_VERSION}")


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release notes ")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.notes = self.root / "release-notes.md"
        self.output = self.root / "github-output"
        self.awk_calls = self.root / "awk-calls"
        self.output.touch()
        self.awk_calls.touch()
        # A rerun must validate newly extracted notes, not an existing file.
        self.notes.write_text("stale notes\n")

    def extract(self, changelog, version="1.2.3"):
        if changelog is not None:
            (self.root / "CHANGELOG.md").write_text(changelog)
        env = dict(os.environ, RUNNER_TEMP=str(self.root),
                   GITHUB_OUTPUT=str(self.output), TEST_VERSION=version,
                   TEST_AWK_LOG=str(self.awk_calls))
        # Count real parser executions without duplicating its extraction rules.
        spy = 'awk() { printf "awk\\n" >> "$TEST_AWK_LOG"; command awk "$@"; }\n'
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", spy + notes_script()],
            cwd=self.root, env=env, capture_output=True, text=True,
        )

    def assert_success(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.notes.read_text(), expected)
        self.assertEqual(self.output.read_text(), f"path={self.notes}\n")
        self.assertEqual(self.awk_calls.read_text().splitlines(), ["awk"])

    def test_extracts_only_requested_section_once(self):
        body = "\n### Fixed\n\n- Preserve **Markdown** and 日本語.\n\n"
        result = self.extract(
            "# Changelog\n\n## [Unreleased]\n\n- Not released.\n\n"
            "## [1x2x3] - 2026-01-01\n\n- Not a literal match.\n\n"
            "## [1.2.3] - 2026-01-02\n" + body
            + "## [1.2.2] - 2026-01-01\n\n- Older release.\n"
        )
        self.assert_success(result, body)

    def test_extracts_final_section_without_trailing_newline(self):
        result = self.extract("## [1.2.3-rc.1+build.2] - 2026-01-02\n- Last note",
                              version="1.2.3-rc.1+build.2")
        self.assert_success(result, "- Last note\n")

    def test_preserves_whitespace_only_nonempty_lines(self):
        # grep -q . accepts spaces; do not silently change the existing policy.
        self.assert_success(self.extract("## [1.2.3]\n \t\n"), " \t\n")

    def test_rejects_missing_empty_and_blank_only_sections(self):
        cases = {
            "missing": "## [1.2.30]\n- Different version.\n",
            "empty_at_eof": "## [1.2.3]\n",
            "empty_before_next": "## [1.2.3]\n## [1.2.2]\n- Older.\n",
            "blank_only": "## [1.2.3]\n\n\n## [1.2.2]\n- Older.\n",
        }
        for name, changelog in cases.items():
            with self.subTest(case=name):
                self.notes.write_text("stale notes\n")
                result = self.extract(changelog)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("error: no [1.2.3] section found", result.stderr)
                self.assertEqual(self.output.read_text(), "")

    def test_missing_changelog_does_not_publish_path(self):
        result = self.extract(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CHANGELOG.md", result.stderr)
        self.assertEqual(self.output.read_text(), "")


if __name__ == "__main__":
    unittest.main()
