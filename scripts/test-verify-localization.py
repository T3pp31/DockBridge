#!/usr/bin/env python3
"""Regression fixtures for String Catalog translations and format arguments."""
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
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "App" / "Resources" / "Localizable.xcstrings"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"sourceLanguage": "en", "strings": {
                "%lld items": {"localizations": {"en": english, "ja": japanese}}
            }}))
            return subprocess.run(["bash", str(SCRIPT), str(path)], capture_output=True, text=True)

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
            ("% d", "%d", True),
            ("% d", "%@", False),
            ("%'d", "%d", True),
            ("%'d", "%@", False),
            ("%+#08.2f", "%f", True),
            ("%+#08.2f", "%d", False),
            ("%@files", "%@個", True),
            ("%@files", "個", False),
        ]
        for source, target, valid in cases:
            with self.subTest(source=source, target=target):
                result = self.verify({"stringUnit": {"value": source}},
                                     {"stringUnit": {"value": target}})
                self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)

    def test_explicit_formats_allow_adjacent_units(self):
        cases = [
            ("%llds", "%lld秒"),
            ("%1$ds", "%1$d秒"),
            ("%08dms", "%dミリ秒"),
            ("%.fms", "%fミリ秒"),
            ("%*.*fms", "%3$*1$.*2$fミリ秒"),
            ("%+dms", "%dミリ秒"),
            ("%-dms", "%dミリ秒"),
        ]
        for source, target in cases:
            with self.subTest(source=source, target=target):
                result = self.verify({"stringUnit": {"value": source}},
                                     {"stringUnit": {"value": target}})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                missing = self.verify({"stringUnit": {"value": source}},
                                      {"stringUnit": {"value": "引数なし"}})
                self.assertEqual(missing.returncode, 1, missing.stdout + missing.stderr)
                self.assertIn("ja format arguments []", missing.stderr)
                self.assertIn("do not match en", missing.stderr)

    def test_literal_percent_in_words(self):
        cases = [
            ("50% off", "50%割引"),
            ("100%CPU", "100%使用"),
            ("100% Done", "100%完了"),
            ("50%'off", "50%割引"),
            ("100% disk", "100%ディスク"),
            ("100% free", "100%空き"),
            ("100%", "100%完了"),
            ("100% ready", "100%準備完了"),
        ]
        for source, target in cases:
            # Literal percentages can occur in either localization.
            for english, japanese in ((source, target), (target, source)):
                with self.subTest(english=english, japanese=japanese):
                    result = self.verify({"stringUnit": {"value": english}},
                                         {"stringUnit": {"value": japanese}})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_literal_percent_does_not_hide_real_arguments(self):
        cases = [
            ("%@ is 50% off", "%@ は50%割引", 0),
            ("%@ is 50% off", "%d は50%割引", 1),
            ("%@ is 50% off", "50%割引", 1),
            ("50% off: %d %@", "%2$@は50%割引（%1$d）", 0),
            ("50% off: %d %@", "%@は50%割引", 1),
        ]
        for source, target, expected_code in cases:
            with self.subTest(source=source, target=target):
                result = self.verify({"stringUnit": {"value": source}},
                                     {"stringUnit": {"value": target}})
                self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
                if expected_code:
                    self.assertIn("ja format arguments", result.stderr)
                    self.assertIn("do not match en", result.stderr)

    def test_japanese_other_without_one(self):
        self.assertEqual(self.verify(plural(one="%lld item", other="%lld items"), plural(other="%lld個")).returncode, 0)

    def test_japanese_scalar_for_english_plural(self):
        self.assertEqual(self.verify(plural(one="%lld item", other="%lld items"), {"stringUnit": {"value": "%lld個"}}).returncode, 0)

    def test_additional_target_category(self):
        self.assertEqual(self.verify(plural(other="%lld items"), plural(one="%lld個", other="%lld個")).returncode, 0)

    def test_missing_target_other(self):
        self.assertNotEqual(self.verify(plural(one="%lld item", other="%lld items"), plural(one="%lld個")).returncode, 0)

    def test_missing_source_other(self):
        self.assertNotEqual(self.verify(plural(one="%lld item"), plural(other="%lld個")).returncode, 0)

    def test_empty_source_form_not_hidden_by_locale_categories(self):
        self.assertNotEqual(self.verify(plural(one="", other="%lld items"), plural(other="%lld個")).returncode, 0)

    def test_empty_target_form(self):
        self.assertNotEqual(self.verify(plural(other="%lld items"), plural(other="")).returncode, 0)

    def test_format_mismatch(self):
        self.assertNotEqual(self.verify(plural(other="%lld items"), plural(other="%@個")).returncode, 0)

    def test_extra_category_format_mismatch(self):
        self.assertNotEqual(self.verify(plural(other="%lld items"), plural(one="%@個", other="%lld個")).returncode, 0)


if __name__ == "__main__":
    unittest.main()
