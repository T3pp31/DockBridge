#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUST_TARGET="${1:-}"
PROFILE="${2:-release}"
# Cargo has no --debug/--dev flags and dev artifacts live under target/debug.
# Normalize the profile before constructing paths or cargo flags (issue #676).
case "$PROFILE" in
  release)
    CARGO_FLAG=(--release)
    PROFILE_DIR="release"
    ;;
  debug|dev)
    CARGO_FLAG=(--profile dev)
    PROFILE_DIR="debug"
    ;;
  *)
    echo "error: unsupported profile '$PROFILE' (use release or debug)" >&2
    exit 1
    ;;
esac
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
OUT_DIR="$ROOT/apps/macos/DockBridge/Generated"

if [[ -n "$RUST_TARGET" ]]; then
  LIB_PATH="$CARGO_TARGET_DIR/${RUST_TARGET}/${PROFILE_DIR}/libdockbridge_uniffi.a"
else
  LIB_PATH="$CARGO_TARGET_DIR/${PROFILE_DIR}/libdockbridge_uniffi.a"
fi

if [[ ! -f "$LIB_PATH" ]]; then
  ./scripts/build-rust.sh "$RUST_TARGET" "$PROFILE"
fi

mkdir -p "$OUT_DIR"

BINDGEN_BIN="$CARGO_TARGET_DIR/${PROFILE_DIR}/uniffi-bindgen"

echo "Generating Swift bindings from $LIB_PATH ..."
if [[ -x "$BINDGEN_BIN" ]]; then
  echo "Using existing bindgen: $BINDGEN_BIN"
  "$BINDGEN_BIN" generate --library "$LIB_PATH" --language swift --out-dir "$OUT_DIR"
else
  echo "bindgen not found; building via cargo run --$PROFILE"
  cargo run -p dockbridge-uniffi --features cli --bin uniffi-bindgen "${CARGO_FLAG[@]}" -- \
    generate --library "$LIB_PATH" --language swift --out-dir "$OUT_DIR"
fi

HEADER_DIR="$OUT_DIR/Headers"
mkdir -p "$HEADER_DIR"
cp "$OUT_DIR/dockbridge_uniffiFFI.h" "$HEADER_DIR/" 2>/dev/null || true
if [[ -f "$OUT_DIR/dockbridge_uniffiFFI.modulemap" ]]; then
  cp "$OUT_DIR/dockbridge_uniffiFFI.modulemap" "$HEADER_DIR/module.modulemap"
fi

# Patch the generated RustBuffer lift so decoding errors do not leak the
# underlying allocation (issue #769).
python3 - "$OUT_DIR/DockBridgeUniffi.swift" <<'PATCH'
import sys
path = sys.argv[1]
src = open(path).read()
old = """    public static func lift(_ buf: RustBuffer) throws -> SwiftType {
        var reader = createReader(data: Data(rustBuffer: buf))
        let value = try read(from: &reader)
        if hasRemaining(reader) {
            throw UniffiInternalError.incompleteData
        }
        buf.deallocate()
        return value
    }"""
new = """    public static func lift(_ buf: RustBuffer) throws -> SwiftType {
        defer { buf.deallocate() }
        var reader = createReader(data: Data(rustBuffer: buf))
        let value = try read(from: &reader)
        if hasRemaining(reader) {
            throw UniffiInternalError.incompleteData
        }
        return value
    }"""
if old in src:
    open(path, "w").write(src.replace(old, new))
    print("patched RustBuffer.lift")
elif new in src:
    print("RustBuffer.lift already patched")
else:
    sys.exit("RustBuffer.lift pattern changed; review the allocation cleanup patch")
PATCH

echo "Swift bindings written to $OUT_DIR"
