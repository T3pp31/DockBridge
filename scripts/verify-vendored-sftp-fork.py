#!/usr/bin/env python3
"""Verify the vendored bssh-russh-sftp fork is the version Cargo resolves.

`Cargo.toml` pins `bssh-russh-sftp = "=2.4.0"` and patches it to
`vendor/bssh-russh-sftp`. If the vendored package version and the pin drift
apart, Cargo silently falls back to the registry crate, dropping the fork's
posix-rename support that Replace uploads rely on (issue #1367).

Run from the repository root: python3 scripts/verify-vendored-sftp-fork.py
"""

import json
import pathlib
import re
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11 (CI uses 3.12)
    tomllib = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKSPACE_MANIFEST = ROOT / "Cargo.toml"
VENDOR_MANIFEST = ROOT / "vendor" / "bssh-russh-sftp" / "Cargo.toml"
CRATE = "bssh-russh-sftp"


def _version_from_section(text, section, key):
    """Read `version` from a dependency table without requiring tomllib."""
    if tomllib is not None:
        manifest = tomllib.loads(text)
        if section == "package":
            return manifest.get("package", {}).get(key)
        return manifest.get("workspace", {}).get("dependencies", {}).get(key, {}).get("version")
    # Fallback for Python < 3.11: match the inline table on the key's line.
    match = re.search(
        rf'^{key}\s*=\s*\{{[^}}]*version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match:
        return match.group(1)
    match = re.search(rf'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    return match.group(1) if match else None


def pinned_requirement():
    return _version_from_section(
        WORKSPACE_MANIFEST.read_text(encoding="utf-8"), "workspace", "russh-sftp")


def vendored_version():
    return _version_from_section(
        VENDOR_MANIFEST.read_text(encoding="utf-8"), "package", "version")


def resolved_packages():
    result = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked"],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise SystemExit("error: cargo metadata failed")
    return json.loads(result.stdout)["packages"]


def main():
    errors = []
    pinned = pinned_requirement()
    if pinned != f"={vendored_version()}":
        errors.append(
            f"workspace pin {pinned!r} does not match vendored version "
            f"{vendored_version()!r}; Cargo would fall back to the registry crate")

    matches = [package for package in resolved_packages()
               if package["name"] == CRATE]
    if not matches:
        errors.append(f"{CRATE} is not in the resolved dependency graph")
    for package in matches:
        source = package.get("source")
        if source is not None:
            errors.append(
                f"{CRATE} {package['version']} resolves from {source}, not the "
                f"vendored path; the fork patches are not in use")
        vendor_path = pathlib.Path(package["manifest_path"]).resolve()
        if vendor_path != VENDOR_MANIFEST.resolve():
            errors.append(
                f"{CRATE} resolves from {vendor_path}, expected "
                f"{VENDOR_MANIFEST.resolve()}")
        if package["version"] != vendored_version():
            errors.append(
                f"resolved {CRATE} version {package['version']} != vendored "
                f"{vendored_version()}")

    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"{CRATE} {vendored_version()} resolves from the vendored path")
    return 0


if __name__ == "__main__":
    sys.exit(main())
