#!/usr/bin/env python3
"""Fail when a `.cargo/audit.toml` ignore entry lacks a future expiry date.

The audit ignore list is parsed as TOML rather than by matching text, so a
one-line array or whitespace-only variation cannot slip past the check.
Expiry dates live in `# expires: YYYY-MM-DD` comments, which TOML parsers
discard, so each ignore entry is matched back to its source line by
advisory id.

Usage: python3 scripts/check-advisory-expiry.py [path-to-audit.toml]
"""

import datetime
import pathlib
import re
import sys
import tomllib

ADVISORY_ID = re.compile(r"^RUSTSEC-\d{4}-\d{4}$")
EXPIRY = re.compile(r"#\s*expires:\s*(\d{4}-\d{2}-\d{2})(?:\s|$)")


def expiry_comments_by_id(text):
    """Map advisory id -> the expiry comment on the line naming it."""
    comments = {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for advisory_id in re.findall(r'"(RUSTSEC-\d{4}-\d{4})"', line):
            comments[advisory_id] = EXPIRY.search(line)
    return comments


def validate(text, today=None):
    """Return a list of error strings; empty means the file is acceptable."""
    today = today or datetime.date.today()
    try:
        config = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return [f"audit.toml is not valid TOML: {error}"]

    advisories = config.get("advisories", {})
    ignored = advisories.get("ignore", [])
    if not isinstance(ignored, list) or any(
            not isinstance(entry, str) for entry in ignored):
        return ["[advisories].ignore must be an array of advisory id strings"]

    comments = expiry_comments_by_id(text)
    errors = []
    for advisory_id in ignored:
        if not ADVISORY_ID.match(advisory_id):
            errors.append(f"ignore entry {advisory_id!r} is not a RUSTSEC id")
            continue
        match = comments.get(advisory_id)
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
    errors = validate(path.read_text(encoding="utf-8"))
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print("add or refresh an '# expires: YYYY-MM-DD' comment for every "
              "ignore entry", file=sys.stderr)
        return 1
    count = len(tomllib.loads(path.read_text(encoding="utf-8"))
                .get("advisories", {}).get("ignore", []))
    print(f"{path}: {count} ignore entr(y/ies) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
