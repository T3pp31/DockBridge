#!/usr/bin/env bash
# Read metadata from config/release.toml or [workspace.package].version from Cargo.toml.
# Supported invocations:
#   bash scripts/release-config.sh [--section <name>] [--bool|--int] <key>
#   bash scripts/release-config.sh --cargo-version
# Workflow and script metadata uses single-line, unescaped double-quoted strings,
# bare TOML booleans (true/false), or non-negative integers. Unsupported values
# fail loudly instead of being truncated or evaluated as shell code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${ROOT}/config/release.toml"
SECTION="release"
VALUE_TYPE="string"
CARGO_VERSION=false
KEY=""

usage() {
  echo "Usage: bash $0 [--section <section>] [--bool|--int] <key> | --cargo-version" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cargo-version)
      if [[ "$CARGO_VERSION" == true || "$SECTION" != "release" || "$VALUE_TYPE" != "string" || -n "$KEY" ]]; then
        usage
      fi
      CARGO_VERSION=true
      shift
      ;;
    --section)
      [[ $# -ge 2 && "$CARGO_VERSION" == false ]] || usage
      SECTION="$2"
      shift 2
      ;;
    --bool)
      [[ "$CARGO_VERSION" == false && "$VALUE_TYPE" == "string" ]] || usage
      VALUE_TYPE="bool"
      shift
      ;;
    --int)
      [[ "$CARGO_VERSION" == false && "$VALUE_TYPE" == "string" ]] || usage
      VALUE_TYPE="int"
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [[ -z "$KEY" && "$CARGO_VERSION" == false ]] || usage
      KEY="$1"
      shift
      ;;
  esac
done

if [[ "$CARGO_VERSION" == true ]]; then
  CONFIG="${ROOT}/Cargo.toml"
  SECTION="workspace.package"
  VALUE_TYPE="string"
  KEY="version"
else
  if [[ -z "$KEY" || ! "$KEY" =~ ^[a-z_][a-z0-9_]*$ || ! "$SECTION" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
    usage
  fi
fi

awk -v section="$SECTION" -v key="$KEY" -v value_type="$VALUE_TYPE" '
  {
    sub(/\r$/, "")
    if ($0 ~ /^[ \t]*\[/) {
      line = $0
      sub(/^[ \t]*\[/, "", line)
      sub(/\][ \t]*(#.*)?$/, "", line)
      in_section = ($0 ~ /^[ \t]*\[[^]]+\][ \t]*(#.*)?$/ && line == section)
      next
    }
    if (!in_section || $0 !~ "^[ \t]*" key "[ \t]*=") next
    found++
    value = $0
    sub("^[ \t]*" key "[ \t]*=[ \t]*", "", value)
    if (value_type == "string") {
      if (value !~ /^"[^"\\]*"[ \t]*(#.*)?$/) {
        invalid = 1
        next
      }
      sub(/^"/, "", value)
      sub(/"[ \t]*(#.*)?$/, "", value)
    } else if (value_type == "bool") {
      if (value !~ /^(true|false)[ \t]*(#.*)?$/) {
        invalid = 1
        next
      }
      sub(/[ \t]*(#.*)?$/, "", value)
    } else if (value_type == "int") {
      if (value !~ /^[0-9]+[ \t]*(#.*)?$/) {
        invalid = 1
        next
      }
      sub(/[ \t]*(#.*)?$/, "", value)
    } else {
      invalid = 1
      next
    }
  }
  END {
    if (found != 1 || invalid || value == "") {
      printf "error: expected one valid %s for [%s].%s in %s\n", value_type, section, key, FILENAME > "/dev/stderr"
      exit 1
    }
    print value
  }
' "$CONFIG"
