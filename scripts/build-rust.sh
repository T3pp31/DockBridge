#!/usr/bin/env bash
set -euo pipefail

# Xcode build phases often run with a minimal PATH; ensure cargo is discoverable.
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Release packaging builds a universal static library before xcodebuild.
if [[ "${DOCKBRIDGE_SKIP_HOST_BUILD:-}" == "1" && -z "${1:-}" ]]; then
  echo "Skipping host Rust build (DOCKBRIDGE_SKIP_HOST_BUILD=1)."
  exit 0
fi

# Use native target by default (target/release). Pass a rust triple to cross-compile.
RUST_TARGET="${1:-}"
PROFILE="${2:-release}"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

if [[ -n "$RUST_TARGET" ]]; then
  echo "Building dockbridge-uniffi for ${RUST_TARGET} (${PROFILE})..."
  cargo build -p dockbridge-uniffi --target "$RUST_TARGET" --"$PROFILE"
  LIB_PATH="$CARGO_TARGET_DIR/${RUST_TARGET}/${PROFILE}/libdockbridge_uniffi.a"
else
  echo "Building dockbridge-uniffi for host (${PROFILE})..."
  cargo build -p dockbridge-uniffi --"$PROFILE"
  LIB_PATH="$CARGO_TARGET_DIR/${PROFILE}/libdockbridge_uniffi.a"
fi

LIB_NAME="libdockbridge_uniffi.a"

if [[ ! -f "$LIB_PATH" ]]; then
  echo "Expected library not found: $LIB_PATH" >&2
  exit 1
fi

echo "Built: $LIB_PATH"
