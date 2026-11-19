#!/usr/bin/env python3
"""Tests for check-advisory-expiry.py.

Run from the repository root: python3 scripts/test-check-advisory-expiry.py
"""

import datetime
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
TODAY = datetime.date(2026, 11, 19)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "check_advisory_expiry", ROOT / "scripts" / "check-advisory-expiry.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AdvisoryExpiryTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def errors(self, text):
        return self.module.validate(text, today=TODAY)

    def test_accepts_commented_future_entry(self):
        text = (
            "[advisories]\n"
            "ignore = [\n"
            '    "RUSTSEC-2023-0071", # reason # expires: 2026-12-31\n'
            "]\n"
        )
        self.assertEqual(self.errors(text), [])

    def test_rejects_missing_expiry(self):
        text = '[advisories]\nignore = ["RUSTSEC-2023-0071"]\n'
        self.assertEqual(
            self.errors(text),
            ["ignore for RUSTSEC-2023-0071 has no '# expires: YYYY-MM-DD' comment"],
        )

    def test_rejects_expired_entry(self):
        text = (
            "[advisories]\n"
            "ignore = [\n"
            '    "RUSTSEC-2023-0071", # expires: 2026-11-18\n'
            "]\n"
        )
        self.assertEqual(
            self.errors(text),
            ["ignore for RUSTSEC-2023-0071 expired on 2026-11-18"],
        )

    def test_rejects_one_line_array_without_expiry(self):
        # The old awk/sed check skipped this line entirely.
        text = '[advisories]\nignore = ["RUSTSEC-2023-0071"]\n'
        self.assertTrue(self.errors(text))

    def test_rejects_whitespace_variation_without_expiry(self):
        # `ignore=[...]` did not match the old line regex either.
        text = '[advisories]\nignore=["RUSTSEC-2023-0071"]\n'
        self.assertTrue(self.errors(text))

    def test_rejects_invalid_date(self):
        text = (
            "[advisories]\n"
            "ignore = [\n"
            '    "RUSTSEC-2023-0071", # expires: 2026-13-01\n'
            "]\n"
        )
        self.assertEqual(
            self.errors(text),
            ["ignore for RUSTSEC-2023-0071 has invalid expiry date '2026-13-01'"],
        )

    def test_rejects_non_rustsec_entry(self):
        text = '[advisories]\nignore = ["CVE-2020-0001"]\n'
        self.assertTrue(self.errors(text))

    def test_rejects_invalid_toml(self):
        self.assertTrue(self.errors("[advisories\nignore = [\n"))

    def test_ignores_commented_out_entries(self):
        text = (
            "[advisories]\n"
            "ignore = [\n"
            "    # \"RUSTSEC-2020-0001\", # expires: 2020-01-01\n"
            '    "RUSTSEC-2023-0071", # expires: 2026-12-31\n'
            "]\n"
        )
        self.assertEqual(self.errors(text), [])

    def test_repository_config_passes(self):
        text = (ROOT / ".cargo" / "audit.toml").read_text(encoding="utf-8")
        self.assertEqual(self.errors(text), [])

    def test_main_reports_failure_for_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = pathlib.Path(directory) / "audit.toml"
            self.assertEqual(self.module.main(["script", str(missing)]), 1)


if __name__ == "__main__":
    unittest.main()
