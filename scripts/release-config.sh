#!/usr/bin/env bash
# Read metadata from config/release.toml or [workspace.package].version from Cargo.toml.
# Supported invocations:
#   bash scripts/release-config.sh [--section <name>] [--bool|--int] <key>
#   bash scripts/release-config.sh --expand <template_key> --version <version> [--app-name <app_name>]
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
EXPAND=false
EXPAND_VERSION=""
HAS_EXPAND_VERSION=false
EXPAND_APP_NAME=""
HAS_EXPAND_APP_NAME=false
KEY=""

usage() {
  echo "Usage: bash $0 [--section <section>] [--bool|--int] <key> | --expand <template_key> --version <version> [--app-name <app_name>] | --cargo-version" >&2
  exit 1
}

read_config_value() {
  local config_file="$1"
  local section="$2"
  local value_type="$3"
  local key="$4"

  awk -v section="$section" -v key="$key" -v value_type="$value_type" '
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
  ' "$config_file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cargo-version)
      if [[ "$CARGO_VERSION" == true || "$EXPAND" == true || "$SECTION" != "release" || "$VALUE_TYPE" != "string" || -n "$KEY" ]]; then
        usage
      fi
      CARGO_VERSION=true
      shift
      ;;
    --expand)
      if [[ $# -lt 2 || "$EXPAND" == true || "$CARGO_VERSION" == true || "$SECTION" != "release" || "$VALUE_TYPE" != "string" || -n "$KEY" ]]; then
        usage
      fi
      EXPAND=true
      KEY="$2"
      shift 2
      ;;
    --version)
      if [[ $# -lt 2 || "$EXPAND" != true || "$HAS_EXPAND_VERSION" == true ]]; then
        usage
      fi
      EXPAND_VERSION="$2"
      HAS_EXPAND_VERSION=true
      shift 2
      ;;
    --app-name)
      if [[ $# -lt 2 || "$EXPAND" != true || "$HAS_EXPAND_APP_NAME" == true ]]; then
        usage
      fi
      EXPAND_APP_NAME="$2"
      HAS_EXPAND_APP_NAME=true
      shift 2
      ;;
    --section)
      [[ $# -ge 2 && "$CARGO_VERSION" == false && "$EXPAND" == false ]] || usage
      SECTION="$2"
      shift 2
      ;;
    --bool)
      [[ "$CARGO_VERSION" == false && "$EXPAND" == false && "$VALUE_TYPE" == "string" ]] || usage
      VALUE_TYPE="bool"
      shift
      ;;
    --int)
      [[ "$CARGO_VERSION" == false && "$EXPAND" == false && "$VALUE_TYPE" == "string" ]] || usage
      VALUE_TYPE="int"
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [[ -z "$KEY" && "$CARGO_VERSION" == false && "$EXPAND" == false ]] || usage
      KEY="$1"
      shift
      ;;
  esac
done

if [[ "$CARGO_VERSION" == true ]]; then
  read_config_value "${ROOT}/Cargo.toml" "workspace.package" "string" "version"
  exit 0
fi

if [[ -z "$KEY" || ! "$KEY" =~ ^[a-z_][a-z0-9_]*$ || ! "$SECTION" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
  usage
fi

if [[ "$EXPAND" == true ]]; then
  if [[ -z "$EXPAND_VERSION" ]]; then
    usage
  fi
  TEMPLATE="$(read_config_value "$CONFIG" "$SECTION" "string" "$KEY")"
  if [[ "$HAS_EXPAND_APP_NAME" != true ]]; then
    EXPAND_APP_NAME="$(read_config_value "$CONFIG" "$SECTION" "string" "app_name")"
  fi
  if [[ -z "$EXPAND_APP_NAME" ]]; then
    echo "error: app_name must not be empty when expanding ${KEY}" >&2
    exit 1
  fi
  if [[ "$EXPAND_APP_NAME" == *[{}]* || "$EXPAND_VERSION" == *[{}]* ]]; then
    echo "error: template replacement values must not contain braces when expanding ${KEY}" >&2
    exit 1
  fi
  # Disable Bash 5.2+ patsub_replacement so '&' and '\' in values stay literal.
  shopt -u patsub_replacement 2>/dev/null || true
  EXPANDED="${TEMPLATE//\{app_name\}/${EXPAND_APP_NAME}}"
  EXPANDED="${EXPANDED//\{version\}/${EXPAND_VERSION}}"
  if [[ "$EXPANDED" == *[{}]* ]]; then
    echo "error: ${KEY} has an unsupported placeholder: ${TEMPLATE}" >&2
    exit 1
  fi
  printf '%s\n' "$EXPANDED"
  exit 0
fi

read_config_value "$CONFIG" "$SECTION" "$VALUE_TYPE" "$KEY"
