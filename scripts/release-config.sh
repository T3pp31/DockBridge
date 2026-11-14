#!/usr/bin/env bash
# Read one non-empty string from [release] in config/release.toml.
# Workflow metadata uses single-line, unescaped double-quoted strings, not
# arbitrary TOML values. Reject unsupported values instead of truncating them.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[a-z_][a-z0-9_]*$ ]]; then
  echo "Usage: bash $0 <release-key>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${ROOT}/config/release.toml"

awk -v key="$1" '
  {
    sub(/\r$/, "")
    if ($0 ~ /^[ \t]*\[/) {
      in_release = ($0 ~ /^[ \t]*\[release\][ \t]*(#.*)?$/)
      next
    }
    if (!in_release || $0 !~ "^[ \t]*" key "[ \t]*=") next
    found++
    value = $0
    sub("^[ \t]*" key "[ \t]*=[ \t]*", "", value)
    if (value !~ /^"[^"\\]*"[ \t]*(#.*)?$/) {
      invalid = 1
      next
    }
    sub(/^"/, "", value)
    sub(/"[ \t]*(#.*)?$/, "", value)
  }
  END {
    if (found != 1 || invalid || value == "") {
      printf "error: expected one non-empty, unescaped quoted string for [release].%s in %s\n", key, FILENAME > "/dev/stderr"
      exit 1
    }
    print value
  }
' "$CONFIG"
