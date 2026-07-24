#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE_CONFIG="${ROOT}/config/release.toml"

read_release_value() {
  local key="$1"
  awk -F'"' -v key="$key" '
    $0 ~ "^" key " " { print $2; exit }
  ' "$RELEASE_CONFIG"
}

OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  echo "Usage: $0 --out <output-directory>" >&2
  exit 1
fi

VERSION="${VERSION:-$(read_release_value version)}"
APP_NAME="${APP_NAME:-$(read_release_value app_name)}"
SBOM_TEMPLATE="$(read_release_value sbom_name_template)"
SBOM_MANIFEST="$(read_release_value sbom_manifest_path)"
SPEC_VERSION="$(read_release_value cyclonedx_spec_version)"

if [[ -z "$VERSION" || -z "$APP_NAME" || -z "$SBOM_TEMPLATE" || -z "$SBOM_MANIFEST" || -z "$SPEC_VERSION" ]]; then
  echo "Failed to read SBOM configuration from ${RELEASE_CONFIG}" >&2
  exit 1
fi

SBOM_FILENAME="${SBOM_TEMPLATE//\{app_name\}/${APP_NAME}}"
SBOM_FILENAME="${SBOM_FILENAME//\{version\}/${VERSION}}"

MANIFEST_ABS="${ROOT}/${SBOM_MANIFEST}"
MANIFEST_DIR="$(dirname "$MANIFEST_ABS")"
OVERRIDE_BASENAME="dockbridge-sbom-${VERSION}"
GENERATED_JSON="${MANIFEST_DIR}/${OVERRIDE_BASENAME}.json"

cleanup_generated_files() {
  for crate_dir in crates/cli crates/core crates/uniffi; do
    rm -f "${ROOT}/${crate_dir}/${OVERRIDE_BASENAME}.json"
  done
}
trap cleanup_generated_files EXIT

if ! command -v cargo-cyclonedx >/dev/null 2>&1; then
  echo "cargo-cyclonedx not found. Install it before running this script." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

cargo cyclonedx \
  --format json \
  --spec-version "${SPEC_VERSION}" \
  --all \
  --target all \
  --manifest-path "${SBOM_MANIFEST}" \
  --override-filename "${OVERRIDE_BASENAME}"

if [[ ! -f "$GENERATED_JSON" ]]; then
  echo "SBOM generation failed: expected ${GENERATED_JSON}" >&2
  exit 1
fi

OUT_PATH="${OUT_DIR}/${SBOM_FILENAME}"
cp "$GENERATED_JSON" "$OUT_PATH"

jq -e --arg spec "${SPEC_VERSION}" '
  .bomFormat == "CycloneDX" and .specVersion == $spec
' "$OUT_PATH" >/dev/null

(
  cd "$OUT_DIR"
  shasum -a 256 "${SBOM_FILENAME}" > "${SBOM_FILENAME}.sha256"
)

echo "SBOM written to ${OUT_PATH}"
