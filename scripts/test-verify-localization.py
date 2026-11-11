#!/usr/bin/env python3
"""Regression fixtures for language-specific String Catalog plural forms."""
import json
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("verify-localization.sh")


def plural(**forms):
    return {"variations": {"plural": {
        category: {"stringUnit": {"value": value}}
        for category, value in forms.items()
    }}}


class LocalizationTests(unittest.TestCase):
    def verify(self, english, japanese):
        self.assertTrue(SCRIPT.is_file(), f"Verification script not found: {SCRIPT}")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "App" / "Resources" / "Localizable.xcstrings"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"sourceLanguage": "en", "strings": {
                "%lld items": {"localizations": {"en": english, "ja": japanese}}
            }}))
            return subprocess.run(["bash", str(SCRIPT), str(path)], capture_output=True, text=True)

    def assert_validation_failure(self, result, diagnostic):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertIn(diagnostic, result.stderr, output)

    def test_printf_argument_types_and_positions(self):
        cases = [
            ("%d %f", "%2$f %1$d", True),
            ("%lld", "%ld", False),
            ("%qX", "%llX", True),
            ("%.12f", "%f", True),
            ("%*.*f", "%3$*1$.*2$f", True),
            ("%*f", "%f", False),
            ("%%@ %d", "%d", True),
            ("%S", "%s", False),
            ("%Lf", "%f", False),
        ]
        for source, target, valid in cases:
            with self.subTest(source=source, target=target):
                result = self.verify({"stringUnit": {"value": source}},
                                     {"stringUnit": {"value": target}})
                if valid:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assert_validation_failure(
                        result, "FAIL: '%lld items': ja format arguments "
                    )

    def test_japanese_other_without_one(self):
        self.assertEqual(self.verify(plural(one="%lld item", other="%lld items"), plural(other="%lld個")).returncode, 0)

    def test_japanese_scalar_for_english_plural(self):
        self.assertEqual(self.verify(plural(one="%lld item", other="%lld items"), {"stringUnit": {"value": "%lld個"}}).returncode, 0)

    def test_additional_target_category(self):
        self.assertEqual(self.verify(plural(other="%lld items"), plural(one="%lld個", other="%lld個")).returncode, 0)

    def test_missing_target_other(self):
        result = self.verify(plural(one="%lld item", other="%lld items"), plural(one="%lld個"))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': missing ja value at variations.plural.other"
        )

    def test_missing_source_other(self):
        result = self.verify(plural(one="%lld item"), plural(other="%lld個"))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': missing en value at variations.plural.other"
        )

    def test_empty_source_form_not_hidden_by_locale_categories(self):
        result = self.verify(plural(one="", other="%lld items"), plural(other="%lld個"))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': empty en value at variations.plural.one"
        )

    def test_empty_target_form(self):
        result = self.verify(plural(other="%lld items"), plural(other=""))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': empty ja value at variations.plural.other"
        )

    def test_format_mismatch(self):
        result = self.verify(plural(other="%lld items"), plural(other="%@個"))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': ja format arguments [(1, '@')] "
            "at variations.plural.other do not match en [(1, 'lld')]"
        )

    def test_extra_category_format_mismatch(self):
        result = self.verify(plural(other="%lld items"), plural(one="%@個", other="%lld個"))
        self.assert_validation_failure(
            result, "FAIL: '%lld items': ja format arguments [(1, '@')] "
            "at variations.plural.one do not match en [(1, 'lld')]"
        )


if __name__ == "__main__":
    unittest.main()
