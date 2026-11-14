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
        # CI runs the same inline command on Linux and macOS. Fail rather than
        # silently passing if a step is removed or changes to a different form.
        commands = re.findall(r"^\s+run: (cargo test [^\n]+)$", self.workflow, re.MULTILINE)
        self.assertTrue(commands, "Expected inline CI cargo test commands")
        self.assertEqual(
            set(commands), {commands[0]},
            "CI must use the same cargo test command on every runner",
        )
        return [commands[0]]

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
