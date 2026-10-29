#!/usr/bin/env bash
set -euo pipefail

# Verifies that every user-facing string in Localizable.xcstrings has both an
# English (development language) and Japanese translation, and that the file
# is valid JSON. Used by CI to catch untranslated / missing keys early.
#
# Usage: scripts/verify-localization.sh [path-to-xcstrings]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

XCS="${1:-$ROOT/apps/macos/DockBridge/Resources/Localizable.xcstrings}"

if [[ ! -f "$XCS" ]]; then
  echo "FAIL: $XCS not found" >&2
  exit 1
fi

python3 - "$XCS" <<'PY'
import json
import pathlib
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

strings = data.get("strings", {})
if not isinstance(strings, dict):
    print("FAIL: 'strings' must be a dictionary", file=sys.stderr)
    sys.exit(1)

source_language = data.get("sourceLanguage", "en")
print(f"Verifying {len(strings)} keys (sourceLanguage={source_language})")

errors = []
format_pattern = re.compile(r"%(?:(\d+)\$)?(lld|@)")


def format_signature(value):
    signature = []
    next_index = 1
    for match in format_pattern.finditer(value):
        if match.group(1) is None:
            index = next_index
            next_index += 1
        else:
            index = int(match.group(1))
        signature.append((index, match.group(2)))
    return sorted(signature)


def collect_string_units(node, prefix=()):
    """Return translation values keyed by their String Catalog variation path."""
    units = {}
    if not isinstance(node, dict):
        return units

    string_unit = node.get("stringUnit")
    if string_unit is not None:
        if isinstance(string_unit, dict):
            units[prefix] = string_unit.get("value")
        else:
            units[prefix] = None

    variations = node.get("variations")
    if variations is not None:
        if not isinstance(variations, dict):
            units[prefix + ("variations",)] = None
        else:
            for variation_name, variation in variations.items():
                variation_path = prefix + ("variations", variation_name)
                if variation_name == "plural":
                    if not isinstance(variation, dict):
                        units[variation_path] = None
                        continue
                    for category, category_node in variation.items():
                        category_path = variation_path + (category,)
                        category_units = collect_string_units(
                            category_node, category_path
                        )
                        if not category_units:
                            units[category_path] = None
                        else:
                            units.update(category_units)
                else:
                    units.update(
                        collect_string_units(variation, variation_path)
                    )
    return units


for key in sorted(strings):
    entry = strings[key]
    localizations = entry.get("localizations", {})
    # String Catalog format: a non-dictionary value marks an entry as
    # "manual only" or a place for comments; require a dictionary here.
    if not isinstance(localizations, dict):
        errors.append(f"{key!r}: localizations is not a dictionary")
        continue
    if source_language not in localizations:
        errors.append(f"{key!r}: missing {source_language} localization")
        continue
    source_units = collect_string_units(localizations[source_language])
    if not source_units:
        errors.append(f"{key!r}: missing {source_language} value")

    # The first target language the project ships must be translated too.
    for target in ("ja",):
        loc = localizations.get(target)
        if loc is None:
            errors.append(f"{key!r}: missing {target} localization")
            continue
        target_units = collect_string_units(loc)
        if not target_units:
            errors.append(f"{key!r}: missing {target} value")
            continue

        # A locale without grammatical plurals may use one scalar translation
        # for a source plural group. Treat it as that group's `other` form.
        plural_other = ("variations", "plural", "other")
        if set(target_units) == {()} and plural_other in source_units:
            target_units = {plural_other: target_units[()]}

        # Plural categories depend on the language. Japanese may contain only
        # `other`, while English also has `one`. Compare extra target categories
        # against the corresponding source `other` form.
        def fallback_path(unit_path):
            parts = list(unit_path)
            for index in range(len(parts) - 1):
                if parts[index] == "plural":
                    parts[index + 1] = "other"
            return tuple(parts)

        for language, units in ((source_language, source_units), (target, target_units)):
            for unit_path, value in units.items():
                if not isinstance(value, str) or not value:
                    errors.append(f"{key!r}: empty {language} value at {'.'.join(unit_path)}")
                other_path = fallback_path(unit_path)
                if other_path not in units:
                    errors.append(f"{key!r}: missing {language} value at {'.'.join(other_path)}")

        # Every non-plural variation and every plural group must be present,
        # but category sets are allowed to differ between locales.
        for unit_path in source_units:
            required_path = fallback_path(unit_path)
            if required_path not in target_units:
                errors.append(f"{key!r}: missing {target} value at {'.'.join(required_path)}")

        for unit_path, target_value in target_units.items():
            source_path = unit_path if unit_path in source_units else fallback_path(unit_path)
            if source_path not in source_units:
                errors.append(f"{key!r}: unexpected {target} value at {'.'.join(unit_path)}")
                continue
            source_value = source_units[source_path]
            if isinstance(source_value, str) and isinstance(target_value, str) and source_value and target_value:
                if format_signature(target_value) != format_signature(source_value):
                    errors.append(
                        f"{key!r}: {target} format arguments "
                        f"{format_signature(target_value)} at {'.'.join(unit_path)} do not match "
                        f"{source_language} {format_signature(source_value)}"
                    )

# Every explicit String(localized:) literal must have a catalog entry. Dynamic
# interpolation inside the localization key is rejected so placeholder keys
# cannot silently diverge from what Xcode extracts.
source_root = pathlib.Path(path).parent.parent
localized_call = re.compile(
    r'String\s*\(\s*localized:\s*"((?:\\.|[^"\\])*)"',
    re.DOTALL,
)
for source_path in sorted(source_root.rglob("*.swift")):
    if "Generated" in source_path.parts:
        continue
    source = source_path.read_text(encoding="utf-8")
    for match in localized_call.finditer(source):
        raw_key = match.group(1)
        line = source.count("\n", 0, match.start()) + 1
        location = f"{source_path.relative_to(source_root)}:{line}"
        if r"\(" in raw_key:
            errors.append(
                f"{location}: interpolate values with String(format:) outside "
                "String(localized:)"
            )
            continue
        try:
            key = json.loads(f'"{raw_key}"')
        except json.JSONDecodeError as error:
            errors.append(f"{location}: invalid localized string literal: {error}")
            continue
        if key not in strings:
            errors.append(f"{location}: missing catalog key {key!r}")

if errors:
    for message in errors:
        print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)

print("OK: all user-facing strings are translated (en + ja)")
PY
