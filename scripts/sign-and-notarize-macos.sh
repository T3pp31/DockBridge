#!/usr/bin/env bash
set -euo pipefail

# Signs and notarizes a macOS .app bundle for release distribution.
#
# Required environment:
#   APP_PATH              — path to the .app bundle
#
# Optional environment:
#   ENTITLEMENTS_PATH     — entitlements plist (default: DockBridge.entitlements)
#   CODE_SIGN_IDENTITY    — signing identity (auto-detected from keychain if unset)
#   NOTARY_KEYCHAIN_PROFILE — notarytool profile name (default: AC_NOTARY)
#   SKIP_NOTARIZATION     — set to "true" to sign only (local testing)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_PATH="${1:-${APP_PATH:-}}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Usage: $0 <path-to-app-bundle>" >&2
  echo "  or set APP_PATH environment variable" >&2
  exit 1
fi

ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-${ROOT}/apps/macos/DockBridge/Resources/DockBridge.entitlements}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-AC_NOTARY}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-false}"

if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
  echo "Entitlements file not found: ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi

resolve_sign_identity() {
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    echo "$CODE_SIGN_IDENTITY"
    return
  fi

  local identity
  identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/ { print $2; exit }'
  )"

  if [[ -z "$identity" ]]; then
    echo "No Developer ID Application identity found in the keychain." >&2
    echo "Import a signing certificate or set CODE_SIGN_IDENTITY." >&2
    exit 1
  fi

  echo "$identity"
}

verify_signature() {
  echo "Verifying code signature..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

verify_gatekeeper() {
  echo "Verifying Gatekeeper acceptance..."
  spctl -a -vv -t execute "$APP_PATH"
}

SIGN_IDENTITY="$(resolve_sign_identity)"
echo "Signing ${APP_PATH} with identity: ${SIGN_IDENTITY}"

codesign --force --deep --options runtime \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

verify_signature

if [[ "$SKIP_NOTARIZATION" == "true" ]]; then
  echo "SKIP_NOTARIZATION=true — skipping notarization."
  exit 0
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "Notary keychain profile not found: ${NOTARY_KEYCHAIN_PROFILE}" >&2
  echo "Run: xcrun notarytool store-credentials ${NOTARY_KEYCHAIN_PROFILE} ..." >&2
  exit 1
fi

SUBMIT_DIR="$(mktemp -d)"
trap 'rm -rf "$SUBMIT_DIR"' EXIT
ZIP_PATH="${SUBMIT_DIR}/$(basename "$APP_PATH").zip"

echo "Creating notarization archive..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting to Apple Notary Service..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

verify_signature
verify_gatekeeper

echo "Sign and notarization complete: ${APP_PATH}"
