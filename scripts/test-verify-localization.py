#!/usr/bin/env python3
"""Regression fixtures for String Catalog variations and format arguments."""
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


def variation(kind, **values):
    return {"variations": {kind: {
        name: {"stringUnit": {"value": value}}
        for name, value in values.items()
    }}}


NON_PLURAL_VARIATIONS = (("device", "iphone", "mac"), ("width", "compact", "regular"))


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
                if valid:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assert_validation_failure(
                        result, "FAIL: '%lld items': ja format arguments "
                    )

    def test_non_plural_variation_only(self):
        for kind, first, second in NON_PLURAL_VARIATIONS:
            with self.subTest(kind=kind):
                result = self.verify(
                    variation(kind, **{first: "%lld items", second: "%@ item"}),
                    variation(kind, **{first: "%lld個", second: "%@個"}),
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_plural_variation_with_scalar(self):
        for kind, first, _ in NON_PLURAL_VARIATIONS:
            with self.subTest(kind=kind):
                result = self.verify(
                    {"stringUnit": {"value": "%lld items"},
                     **variation(kind, **{first: "%@ item"})},
                    {"stringUnit": {"value": "%lld個"},
                     **variation(kind, **{first: "%@個"})},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_plural_missing_or_unexpected_target_value(self):
        for kind, first, second in NON_PLURAL_VARIATIONS:
            for source_values, target_values, diagnostic in (
                ({first: "%lld items", second: "%lld items"}, {second: "%lld個"},
                 f"missing ja value at variations.{kind}.{first}"),
                ({first: "%lld items"}, {first: "%lld個", second: "%lld個"},
                 f"unexpected ja value at variations.{kind}.{second}"),
            ):
                with self.subTest(kind=kind, diagnostic=diagnostic):
                    result = self.verify(
                        {"stringUnit": {"value": "%lld items"},
                         **variation(kind, **source_values)},
                        {"stringUnit": {"value": "%lld個"},
                         **variation(kind, **target_values)},
                    )
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(diagnostic, result.stderr)

    def test_non_plural_invalid_value_is_not_hidden_by_scalar(self):
        for kind, first, _ in NON_PLURAL_VARIATIONS:
            for language in ("en", "ja"):
                for invalid_node in (None, {}, {"stringUnit": {}},
                                     {"stringUnit": {"value": ""}}):
                    with self.subTest(kind=kind, language=language, node=invalid_node):
                        english = {"stringUnit": {"value": "%lld items"},
                                   **variation(kind, **{first: "%lld items"})}
                        japanese = {"stringUnit": {"value": "%lld個"},
                                    **variation(kind, **{first: "%lld個"})}
                        invalid = english if language == "en" else japanese
                        invalid["variations"][kind][first] = invalid_node
                        result = self.verify(english, japanese)
                        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                        self.assertIn(
                            f"empty {language} value at variations.{kind}.{first}",
                            result.stderr,
                        )

    def test_non_plural_invalid_mapping_is_not_hidden_by_scalar(self):
        for kind, _, _ in NON_PLURAL_VARIATIONS:
            for language in ("en", "ja"):
                with self.subTest(kind=kind, language=language):
                    english = {"stringUnit": {"value": "%lld items"}}
                    japanese = {"stringUnit": {"value": "%lld個"}}
                    invalid = english if language == "en" else japanese
                    invalid["variations"] = {kind: []}
                    result = self.verify(english, japanese)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(f"empty {language} value at variations.{kind}", result.stderr)

    def test_non_plural_format_mismatch_is_not_hidden_by_scalar(self):
        for kind, first, _ in NON_PLURAL_VARIATIONS:
            with self.subTest(kind=kind):
                result = self.verify(
                    {"stringUnit": {"value": "%lld items"},
                     **variation(kind, **{first: "%lld items"})},
                    {"stringUnit": {"value": "%lld個"},
                     **variation(kind, **{first: "%@個"})},
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("ja format arguments", result.stderr)
                self.assertIn(f"at variations.{kind}.{first} do not match", result.stderr)

    def test_nested_non_plural_and_plural_variations(self):
        for kind, first, _ in NON_PLURAL_VARIATIONS:
            for outer_plural in (False, True):
                for valid in (True, False):
                    with self.subTest(kind=kind, outer_plural=outer_plural, valid=valid):
                        target_value = "%lld個" if valid else "%@個"
                        # The extra target category must fall back to source
                        # `other` without changing the non-plural path segments.
                        if outer_plural:
                            english = {"variations": {"plural": {
                                "other": variation(kind, **{first: "%lld items"}),
                            }}}
                            japanese = {"variations": {"plural": {
                                "one": variation(kind, **{first: target_value}),
                                "other": variation(kind, **{first: "%lld個"}),
                            }}}
                            target_path = f"variations.plural.one.variations.{kind}.{first}"
                        else:
                            english = {"variations": {kind: {
                                first: plural(other="%lld items"),
                            }}}
                            japanese = {"variations": {kind: {
                                first: plural(one=target_value, other="%lld個"),
                            }}}
                            target_path = f"variations.{kind}.{first}.variations.plural.one"
                        result = self.verify(english, japanese)
                        self.assertEqual(result.returncode, 0 if valid else 1,
                                         result.stdout + result.stderr)
                        if not valid:
                            self.assertIn("ja format arguments", result.stderr)
                            self.assertIn(f"at {target_path} do not match", result.stderr)

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
