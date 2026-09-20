#!/usr/bin/env bash
set -euo pipefail

# Verifies that every user-facing string in Localizable.xcstrings has both an
# English (development language) and Japanese translation, and that the file
# is valid JSON. Used by CI to catch untranslated / missing keys early.
#
# Usage: scripts/verify-localization.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

XCS="$ROOT/apps/macos/DockBridge/Resources/Localizable.xcstrings"

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
    en = localizations[source_language].get("stringUnit", {}).get("value")
    if not en:
        errors.append(f"{key!r}: empty {source_language} value")

    # The first target language the project ships must be translated too.
    for target in ("ja",):
        loc = localizations.get(target)
        if loc is None:
            errors.append(f"{key!r}: missing {target} localization")
            continue
        value = loc.get("stringUnit", {}).get("value")
        if value is None or value == "":
            errors.append(f"{key!r}: empty {target} value")
        elif en and format_signature(value) != format_signature(en):
            errors.append(
                f"{key!r}: {target} format arguments {format_signature(value)} "
                f"do not match {source_language} {format_signature(en)}"
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
