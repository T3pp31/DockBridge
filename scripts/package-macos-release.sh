#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE_CONFIG="${ROOT}/config/release.toml"
INFO_PLIST="${ROOT}/apps/macos/DockBridge/Resources/Info.plist"
MACOS_DIR="${ROOT}/apps/macos"
DIST_DIR="${DIST_DIR:-${ROOT}/dist}"

read_release_value() {
  local key="$1"
  awk -F'"' -v key="$key" '
    $0 ~ "^" key " " { print $2; exit }
  ' "$RELEASE_CONFIG"
}

VERSION="${VERSION:-$(read_release_value version)}"
APP_NAME="${APP_NAME:-$(read_release_value app_name)}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
ASSET_TEMPLATE="$(read_release_value asset_name_template)"
RELEASE_ARCHS="${RELEASE_ARCHS:-arm64 x86_64}"
RUST_TARGETS="${RUST_TARGETS:-aarch64-apple-darwin x86_64-apple-darwin}"

if [[ -z "$VERSION" || -z "$APP_NAME" || -z "$ASSET_TEMPLATE" ]]; then
  echo "Failed to read release configuration from ${RELEASE_CONFIG}" >&2
  exit 1
fi

ASSET_NAME="${ASSET_TEMPLATE//\{app_name\}/${APP_NAME}}"
ASSET_NAME="${ASSET_NAME//\{version\}/${VERSION}}"
DMG_PATH="${DIST_DIR}/${ASSET_NAME}"
SHA256_PATH="${DMG_PATH}.sha256"

echo "Packaging ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER})..."

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$INFO_PLIST"

UNIVERSAL_LIB="${CARGO_TARGET_DIR}/release/libdockbridge_uniffi.a"
RUST_LIB_PATHS=()

for target in ${RUST_TARGETS}; do
  rustup target add "${target}" >/dev/null 2>&1 || true
  ./scripts/build-rust.sh "${target}" release
  RUST_LIB_PATHS+=("${CARGO_TARGET_DIR}/${target}/release/libdockbridge_uniffi.a")
done

if [[ ${#RUST_LIB_PATHS[@]} -eq 1 ]]; then
  cp "${RUST_LIB_PATHS[0]}" "${UNIVERSAL_LIB}"
else
  lipo -create "${RUST_LIB_PATHS[@]}" -output "${UNIVERSAL_LIB}"
fi

./scripts/generate-uniffi.sh "" release

DERIVED_DATA="${DERIVED_DATA:-${ROOT}/.derivedData/Release}"
mkdir -p "$DERIVED_DATA"

SIGN_AND_NOTARIZE="${SIGN_AND_NOTARIZE:-false}"

echo "Building macOS app (Release, archs: ${RELEASE_ARCHS})..."
export DOCKBRIDGE_SKIP_HOST_BUILD=1
(
  cd "$MACOS_DIR"
  xcodebuild \
    -scheme DockBridge \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="${RELEASE_ARCHS}" \
    ONLY_ACTIVE_ARCH=NO \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM=""
)

APP_PATH="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle not found: ${APP_PATH}" >&2
  exit 1
fi

if [[ "$SIGN_AND_NOTARIZE" == "true" ]]; then
  echo "Signing and notarizing release app bundle..."
  "${ROOT}/scripts/sign-and-notarize-macos.sh" "$APP_PATH"
fi

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$SHA256_PATH"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Preparing DMG staging directory..."
ditto "$APP_PATH" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "Creating DMG: ${DMG_PATH}"
hdiutil create \
  -volname "DockBridge ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$SHA256_PATH")"
)

echo "Package ready:"
echo "  DMG:    ${DMG_PATH}"
echo "  SHA256: ${SHA256_PATH}"
