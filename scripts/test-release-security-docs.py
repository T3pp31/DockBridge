#!/usr/bin/env python3
"""Keep public release summaries delegated to the canonical security document."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICY = "docs/security.md#code-signing-and-distribution"
SUMMARIES = {
    "README.md": ("Download",),
    "SECURITY.md": ("Security posture (summary)", "Known constraints"),
}


def section(text, heading):
    return text.split(f"## {heading}\n", 1)[1].split("\n## ", 1)[0]


class ReleaseSecurityDocsTests(unittest.TestCase):
    def test_public_summaries_link_to_existing_canonical_section(self):
        target, anchor = POLICY.split("#", 1)
        canonical = (ROOT / target).read_text(encoding="utf-8")
        headings = re.findall(r"^#{1,6} (.+)$", canonical, re.MULTILINE)
        self.assertEqual(
            sum(heading.lower().replace(" ", "-") == anchor for heading in headings),
            1,
            "The canonical release policy anchor must resolve unambiguously",
        )
        for name, headings in SUMMARIES.items():
            with self.subTest(document=name):
                text = (ROOT / name).read_text(encoding="utf-8")
                self.assertRegex(section(text, headings[0]), rf"\[[^\]]+\]\({re.escape(POLICY)}\)")

    def test_summaries_do_not_duplicate_signing_or_notarization_status(self):
        # Both affirmative and negative status claims belong only in the policy.
        # This catches the old "unsigned / not notarized" and "signed and
        # notarized" claims, including the second stale Known constraints entry.
        for name, headings in SUMMARIES.items():
            text = (ROOT / name).read_text(encoding="utf-8")
            for heading in headings:
                with self.subTest(document=name, section=heading):
                    self.assertNotRegex(
                        section(text, heading),
                        r"(?i)\b(?:unsigned|signed|notari[sz](?:ed|ation)|developer id)\b",
                        "Keep release status in docs/security.md, not in public summaries",
                    )


if __name__ == "__main__":
    unittest.main()
