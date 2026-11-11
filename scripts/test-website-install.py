#!/usr/bin/env python3
"""Content regressions for the macOS 15+ download site's install instructions."""
from html.parser import HTMLParser
from pathlib import Path
import unittest


PAGE = Path(__file__).resolve().parents[1] / "website" / "index.html"


class InstallStepsParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_install = False
        self.current_step = None
        self.steps = []

    def handle_starttag(self, tag, attrs):
        if tag == "section" and dict(attrs).get("id") == "install":
            self.in_install = True
        if self.in_install and tag == "li":
            self.current_step = []

    def handle_data(self, data):
        if self.current_step is not None:
            self.current_step.append(data)

    def handle_endtag(self, tag):
        if tag == "li" and self.current_step is not None:
            self.steps.append(" ".join("".join(self.current_step).split()))
            self.current_step = None
        if tag == "section":
            self.in_install = False


class WebsiteInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parser = InstallStepsParser()
        parser.feed(PAGE.read_text(encoding="utf-8"))
        cls.steps = parser.steps
        cls.instructions = " ".join(parser.steps)

    def test_normal_install_and_launch_are_preserved(self):
        self.assertGreaterEqual(len(self.steps), 4)
        for step, expected in zip(self.steps, [
            "Download the latest", "Double-click the DMG", "Drag DockBridge.app",
            "Open DockBridge from Applications",
        ]):
            self.assertIn(expected, step)
        self.assertIn("Applications", self.steps[2])

    def test_blocked_launch_recovery_is_actionable_and_ordered(self):
        actions = [
            "Open DockBridge from Applications", "If macOS blocks", "dismiss the alert",
            "System Settings", "Privacy & Security", "scroll to Security", "Open Anyway",
            "authenticate", "click Open in the confirmation dialog",
        ]
        for action in actions:
            self.assertIn(action, self.instructions)
        positions = [self.instructions.index(action) for action in actions]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("Touch ID", self.instructions)
        self.assertIn("login password", self.instructions)

    def test_override_is_conditional_on_block_and_trust(self):
        self.assertIn("If the app was blocked", self.instructions)
        self.assertIn("only if you trust", self.instructions)
        self.assertIn("appears only after a blocked launch attempt", self.instructions)

    def test_no_obsolete_finder_override(self):
        self.assertNotRegex(self.instructions.lower(), r"(?:right|control)[\s\-–‑]*click")


if __name__ == "__main__":
    unittest.main()
