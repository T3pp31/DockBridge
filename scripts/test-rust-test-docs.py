#!/usr/bin/env python3
"""Keep AGENTS.md's Rust test instructions aligned with the CI command (offline)."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RustTestDocsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

    def ci_test_commands(self):
        # CI currently uses a single inline cargo test step. Fail rather than
        # silently passing if it is removed or changed to a different YAML form.
        commands = re.findall(r"^\s+run: (cargo test [^\n]+)$", self.workflow, re.MULTILINE)
        self.assertEqual(len(commands), 1, "Expected one inline CI cargo test command")
        return commands

    def test_recommended_command_matches_ci(self):
        commands = re.findall(r"^- Tests: `(cargo test [^`]+)`", self.doc, re.MULTILINE)
        self.assertEqual(commands, self.ci_test_commands())

    def test_ci_scope_description_matches_ci(self):
        lines = re.findall(r"^- Tests: .+$", self.doc, re.MULTILINE)
        self.assertEqual(len(lines), 1, "Expected one Rust Tests instruction")
        commands = re.findall(r"CI runs `(cargo test [^`]+)`", lines[0])
        self.assertEqual(commands, self.ci_test_commands())


if __name__ == "__main__":
    unittest.main()
