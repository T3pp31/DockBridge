#!/usr/bin/env python3
"""Fail when a `.cargo/audit.toml` ignore entry lacks a future expiry date.

The audit ignore list is parsed as TOML rather than by matching text, so a
one-line array or whitespace-only variation cannot slip past the check.
Expiry dates live in `# expires: YYYY-MM-DD` comments, which TOML parsers
discard, so each string inside the ignore array is paired with the comment
on its own source line.

Usage: python3 scripts/check-advisory-expiry.py [path-to-audit.toml]
"""

import datetime
import pathlib
import re
import sys
import tomllib

ADVISORY_PATTERN = r"RUSTSEC-\d{4}-\d{4}"
ADVISORY_ID = re.compile(f"^{ADVISORY_PATTERN}$")
EXPIRY = re.compile(r"#\s*expires:\s*(\d{4}-\d{2}-\d{2})(?:\s|$)")


def scan_line(line):
    """Split a TOML line into its string tokens and trailing comment.

    Handles basic ("...") and literal ('...') strings so a `#` or quote
    inside a string is not mistaken for a comment or another token.
    """
    strings = []
    index = 0
    while index < len(line):
        char = line[index]
        if char == "#":
            return strings, line[index:]
        if char in ('"', "'"):
            quote = char
            index += 1
            value = []
            while index < len(line) and line[index] != quote:
                if quote == '"' and line[index] == "\\" and index + 1 < len(line):
                    value.append(line[index:index + 2])
                    index += 2
                    continue
                value.append(line[index])
                index += 1
            strings.append("".join(value))
        index += 1
    return strings, ""


def ignore_entries(text):
    """Return (advisory string, expiry match, line number, strings on line)
    for each string token inside `[advisories].ignore`, in source order.

    Only the array itself is scanned, and each entry is paired with the
    comment on its own line, so a comment elsewhere that quotes the same id
    cannot change the result.
    """
    entries = []
    table = None
    depth = 0
    for number, line in enumerate(text.splitlines(), start=1):
        strings, comment = scan_line(line)
        code = line[: len(line) - len(comment)] if comment else line
        if depth == 0:
            stripped = code.strip()
            if stripped.startswith("["):
                table = stripped.strip("[] ")
                continue
            if table != "advisories" or not re.match(r"\s*ignore\s*=", code):
                continue
            code = code.split("=", 1)[1]
        # Brackets inside strings were already consumed by scan_line; strip
        # string contents before counting.
        bare = re.sub(r'"(?:\\.|[^"\\])*"|\'[^\']*\'', "", code)
        depth += bare.count("[") - bare.count("]")
        match = EXPIRY.search(comment) if comment else None
        for value in strings:
            entries.append((value, match, number, len(strings)))
    return entries


def validate(text, today=None):
    """Return a list of error strings; empty means the file is acceptable.

    `today` defaults to the current UTC date.
    """
    today = today or datetime.datetime.now(datetime.timezone.utc).date()
    try:
        config = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return [f"audit.toml is not valid TOML: {error}"]

    advisories = config.get("advisories", {})
    ignored = advisories.get("ignore", [])
    if not isinstance(ignored, list) or any(
            not isinstance(entry, str) for entry in ignored):
        return ["[advisories].ignore must be an array of advisory id strings"]

    entries = ignore_entries(text)
    if [entry[0] for entry in entries] != ignored:
        return ["could not match [advisories].ignore entries to their source "
                "lines; write one quoted id per line"]

    errors = []
    seen = set()
    for advisory_id, match, number, per_line in entries:
        if not ADVISORY_ID.match(advisory_id):
            errors.append(f"ignore entry {advisory_id!r} is not a RUSTSEC id")
            continue
        if advisory_id in seen:
            errors.append(f"ignore for {advisory_id} is listed more than once")
            continue
        seen.add(advisory_id)
        if per_line > 1:
            errors.append(
                f"ignore for {advisory_id} shares line {number} with another "
                "entry; give each entry its own line and expiry comment")
            continue
        if match is None:
            errors.append(
                f"ignore for {advisory_id} has no '# expires: YYYY-MM-DD' comment")
            continue
        try:
            expiry = datetime.date.fromisoformat(match.group(1))
        except ValueError:
            errors.append(
                f"ignore for {advisory_id} has invalid expiry date {match.group(1)!r}")
            continue
        if expiry < today:
            errors.append(f"ignore for {advisory_id} expired on {expiry.isoformat()}")
    return errors


def main(argv):
    path = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(".cargo/audit.toml")
    if not path.is_file():
        print(f"error: {path} not found", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    errors = validate(text)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print("add or refresh an '# expires: YYYY-MM-DD' comment for every "
              "ignore entry", file=sys.stderr)
        return 1
    count = len(ignore_entries(text))
    print(f"{path}: {count} ignore entr(y/ies) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
