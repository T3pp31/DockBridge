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
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    sys.exit("error: verify-vendored-sftp-fork.py requires Python 3.11+ (tomllib)")

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKSPACE_MANIFEST = ROOT / "Cargo.toml"
VENDOR_MANIFEST = ROOT / "vendor" / "bssh-russh-sftp" / "Cargo.toml"
CRATE = "bssh-russh-sftp"


def _version_from_section(text, section, key):
    """Read `version` from `[package]` or a `[workspace.dependencies]` entry."""
    manifest = tomllib.loads(text)
    if section == "package":
        return manifest.get("package", {}).get(key)
    entry = manifest.get("workspace", {}).get("dependencies", {}).get(key, {})
    return entry.get("version") if isinstance(entry, dict) else None


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
        raise RuntimeError(f"cargo metadata failed:\n{result.stderr}")
    return json.loads(result.stdout)["packages"]


def main():
    errors = []
    pinned = pinned_requirement()
    vendored = vendored_version()
    if pinned is None:
        errors.append(f"could not read the {CRATE} requirement from {WORKSPACE_MANIFEST}")
    if vendored is None:
        errors.append(f"could not read the package version from {VENDOR_MANIFEST}")
    if pinned is not None and vendored is not None and pinned != f"={vendored}":
        errors.append(
            f"workspace pin {pinned!r} does not match vendored version "
            f"{vendored!r}; Cargo would fall back to the registry crate")

    try:
        packages = resolved_packages()
    except RuntimeError as error:
        errors.append(str(error))
        packages = None
    matches = [package for package in packages or []
               if package["name"] == CRATE]
    if packages is not None and not matches:
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
        if package["version"] != vendored:
            errors.append(
                f"resolved {CRATE} version {package['version']} != vendored "
                f"{vendored}")

    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"{CRATE} {vendored} resolves from the vendored path")
    return 0


if __name__ == "__main__":
    sys.exit(main())
