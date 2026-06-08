#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUST_TARGET="${1:-}"
PROFILE="${2:-release}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
OUT_DIR="$ROOT/apps/macos/DockBridge/Generated"

if [[ -n "$RUST_TARGET" ]]; then
  LIB_PATH="$CARGO_TARGET_DIR/${RUST_TARGET}/${PROFILE}/libdockbridge_uniffi.a"
else
  LIB_PATH="$CARGO_TARGET_DIR/${PROFILE}/libdockbridge_uniffi.a"
fi

if [[ ! -f "$LIB_PATH" ]]; then
  ./scripts/build-rust.sh "$RUST_TARGET" "$PROFILE"
fi

mkdir -p "$OUT_DIR"

echo "Generating Swift bindings from $LIB_PATH ..."
cargo run -p dockbridge-uniffi --bin uniffi-bindgen -- \
  generate --library "$LIB_PATH" --language swift --out-dir "$OUT_DIR"

HEADER_DIR="$OUT_DIR/Headers"
mkdir -p "$HEADER_DIR"
cp "$OUT_DIR/dockbridge_uniffiFFI.h" "$HEADER_DIR/" 2>/dev/null || true
if [[ -f "$OUT_DIR/dockbridge_uniffiFFI.modulemap" ]]; then
  cp "$OUT_DIR/dockbridge_uniffiFFI.modulemap" "$HEADER_DIR/module.modulemap"
fi

echo "Swift bindings written to $OUT_DIR"
