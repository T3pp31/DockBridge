#!/usr/bin/env bash
# Verifies Issue #3 manual test plan item:
# "大きなファイル転送中に Transfer Queue の Cancel ボタンで中断できること"
#
# Prerequisites: Docker, Xcode 16+, Rust toolchain
# Usage: ./scripts/verify-transfer-cancel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

CONTAINER_NAME="${SFTP_CONTAINER:-dockbridge-e2e}"
PORT="${SFTP_PORT:-2222}"
USER="${SFTP_USER:-demo}"
PASSWORD="${SFTP_PASSWORD:-password}"

log() {
  echo "[verify-transfer-cancel] $*"
}

ensure_container() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Docker SFTP container $CONTAINER_NAME is already running"
    return 0
  fi

  log "Starting Docker SFTP container $CONTAINER_NAME on port $PORT ..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER_NAME" -p "${PORT}:22" -e SFTP_USER="$USER" \
    atmoz/sftp "${USER}:${PASSWORD}:::upload" >/dev/null
  sleep 3
}

main() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required. Install Docker Desktop and retry." >&2
    exit 1
  fi

  ensure_container

  log "Building Rust static library ..."
  ./scripts/build-rust.sh

  log "Running automated transfer-cancel E2E test ..."
  cd "$ROOT/apps/macos"
  xcodebuild \
    -scheme DockBridge \
    -destination 'platform=macOS' \
    -configuration Debug \
    -only-testing:DockBridgeTests/ManualTestPlanVerificationTests/testCancelInProgressLargeFileUpload \
    build test \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM=""

  log "PASS: in-progress large file upload can be cancelled via Transfer Queue API"
}

main "$@"
