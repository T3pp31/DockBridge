#!/usr/bin/env python3
"""Offline regression checks for the September 2026 UI/UX tracker.

These check the document, not GitHub PR state or feature acceptance.
Run from the repository root: python3 scripts/test-ui-ux-tracking.py
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TRACKER = ROOT / "docs" / "ui-ux-tracking-2026-09.md"


class UIUXTrackingTests(unittest.TestCase):
    def setUp(self):
        self.document = TRACKER.read_text(encoding="utf-8")
        self.rows = [line for line in self.document.splitlines()
                     if line.startswith("| [#")]

    def test_original_survey_issue_and_pr_mapping_is_preserved(self):
        expected = {212: 254, 213: 256, 214: 257, 234: 258}
        expected.update({issue: issue + 20 for issue in range(215, 234)})
        actual = []
        for row in self.rows:
            issue = re.search(r"/issues/(\d+)\)", row)
            pr = re.search(r"/pull/(\d+)\)", row)
            self.assertIsNotNone(issue, row)
            self.assertIsNotNone(pr, row)
            actual.append((int(issue.group(1)), int(pr.group(1))))
        self.assertEqual(sorted(actual), sorted(expected.items()))

    def test_each_row_has_resolvable_local_implementation_evidence(self):
        self.assertTrue(self.rows)
        for row in self.rows:
            with self.subTest(row=row):
                self.assertEqual(len(row.strip("|").split("|")), 5)
                evidence = row.strip("|").split("|")[-1]
                links = re.findall(r"\]\((\.\./[^)#]+)(?:#[^)]*)?\)", evidence)
                self.assertTrue(links, "Missing local implementation evidence")
                for link in links:
                    self.assertTrue((TRACKER.parent / link).is_file(), link)

    def test_implementation_and_pr_lifecycle_are_not_conflated(self):
        self.assertEqual(self.document.count("| Implementation status |"), 3)
        self.assertNotIn("PRs are open and unmerged by policy", self.document)
        self.assertNotRegex(self.document, r"\|\s*PR open\s*\|")
        self.assertNotIn("merge pending review", self.document)


if __name__ == "__main__":
    unittest.main()
