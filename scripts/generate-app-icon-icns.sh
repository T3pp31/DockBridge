#!/usr/bin/env bash
# Build a Dock-compatible AppIcon.icns from AppIcon.appiconset PNGs.
# actool (Xcode 26+) may emit ic13 icons that Dock fails to render; iconutil
# produces a legacy multi-size icns that Launch Services reliably displays.
set -euo pipefail

OUT="${1:?output path for AppIcon.icns is required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_SRC="${ROOT}/apps/macos/DockBridge/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -d "$ICONSET_SRC" ]]; then
  echo "error: AppIcon.appiconset not found at $ICONSET_SRC" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp -R "$ICONSET_SRC" "$TMP/AppIcon.iconset"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"
