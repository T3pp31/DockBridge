#!/usr/bin/env bash
# Emit a Makefile dependency file (.d) covering Rust/UniFFI inputs so Xcode's
# "Generate UniFFI Bindings" phase skips when no Rust source changed and re-runs
# whenever any nested Rust source, manifest, UDL, or script changes (issue #616).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <repo-root> <stamp-path> <depfile-path>" >&2
  exit 1
fi

ROOT="$1"
STAMP="$2"
DEPFILE="$3"

mkdir -p "$(dirname "$STAMP")" "$(dirname "$DEPFILE")"

python3 - "$ROOT" "$STAMP" "$DEPFILE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
stamp = sys.argv[2]
depfile = pathlib.Path(sys.argv[3])

deps = []
for rel in (
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "scripts/build-rust.sh",
    "scripts/generate-uniffi.sh",
    "scripts/write-uniffi-depfile.sh",
):
    candidate = root / rel
    if candidate.exists():
        deps.append(str(candidate))

for top in ("crates", "vendor"):
    base = root / top
    if not base.exists():
        continue
    for path in sorted(base.rglob("*")):
        if "target" in path.relative_to(base).parts:
            continue
        if path.is_file() and path.suffix in {".rs", ".toml", ".udl"}:
            deps.append(str(path))

def escape_make(path_str: str) -> str:
    return (
        path_str.replace("\\", "\\\\")
        .replace(" ", "\\ ")
        .replace("#", "\\#")
        .replace("$", "$$")
    )

depfile.write_text(
    f"{escape_make(stamp)}: " + " ".join(escape_make(d) for d in deps) + "\n",
    encoding="utf-8",
)
PY

touch "$STAMP"
