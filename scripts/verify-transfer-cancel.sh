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
HOST="${SFTP_HOST:-127.0.0.1}"
PORT="${SFTP_PORT:-2222}"
# shellcheck source=config/sftp-test.conf
source "$ROOT/config/sftp-test.conf"
IMAGE="${SFTP_IMAGE:-$DEFAULT_SFTP_IMAGE}"
USER="${SFTP_USER:-demo}"
PASSWORD="${SFTP_PASSWORD:-password}"

log() {
  echo "[verify-transfer-cancel] $*"
}

fail() {
  echo "[verify-transfer-cancel] $*" >&2
  exit 1
}

ensure_container() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Docker SFTP container $CONTAINER_NAME is already running"
  else
    log "Starting Docker SFTP container $CONTAINER_NAME on port $PORT ..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER_NAME" -p "127.0.0.1:${PORT}:22" -e SFTP_USER="$USER" \
      "$IMAGE" "${USER}:${PASSWORD}:::upload" >/dev/null
  fi
  wait_for_sftp_readiness
}

wait_for_sftp_readiness() {
  local attempts=30
  for _ in $(seq 1 "$attempts"); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]] \
      && docker exec "$CONTAINER_NAME" pgrep -x sshd >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Docker SFTP container $CONTAINER_NAME did not become ready" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  return 1
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
  result_bundle="$ROOT/.derivedData-transfer-cancel/results.xcresult"
  rm -rf "$result_bundle"
  # Export both SFTP_* and TEST_RUNNER_SFTP_* so the hosted XCTest target
  # receives custom container overrides regardless of xcodebuild forwarding mode
  # (Issue #839 F51).
  SFTP_CONTAINER="$CONTAINER_NAME" \
  SFTP_HOST="$HOST" \
  SFTP_PORT="$PORT" \
  SFTP_USER="$USER" \
  SFTP_PASSWORD="$PASSWORD" \
  TEST_RUNNER_SFTP_CONTAINER="$CONTAINER_NAME" \
  TEST_RUNNER_SFTP_HOST="$HOST" \
  TEST_RUNNER_SFTP_PORT="$PORT" \
  TEST_RUNNER_SFTP_USER="$USER" \
  TEST_RUNNER_SFTP_PASSWORD="$PASSWORD" \
  xcodebuild \
    -scheme DockBridge \
    -destination 'platform=macOS' \
    -configuration Debug \
    -only-testing:DockBridgeTests/ManualTestPlanVerificationTests/testCancelInProgressLargeFileUpload \
    -resultBundlePath "$result_bundle" \
    build test \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM=""

  # -only-testing silently succeeds with 0 tests or an XCTSkip; require at least
  # one passed test and zero failed or skipped tests (issue #680, #839 F51).
  if [[ ! -d "$result_bundle" ]]; then
    fail "xcodebuild did not produce a result bundle"
  fi
  summary=$(xcrun xcresulttool get test-results summary --path "$result_bundle" 2>/dev/null) \
    || fail "failed to read xcodebuild result bundle"
  total=$(echo "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("totalTestCount", 0))')
  failed=$(echo "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("failedTests", 0))')
  skipped=$(echo "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("skippedTests", 0))')
  passed=$(echo "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("passedTests", 0))')
  if [[ "$total" -lt 1 ]]; then
    fail "no tests matched the -only-testing identifier"
  fi
  if [[ "$failed" -ne 0 ]]; then
    fail "$failed transfer-cancel test(s) failed"
  fi
  if [[ "$skipped" -ne 0 ]]; then
    fail "$skipped transfer-cancel test(s) were skipped"
  fi
  if [[ "$passed" -lt 1 ]]; then
    fail "expected at least 1 passed transfer-cancel test, got $passed"
  fi

  log "PASS: in-progress large file upload can be cancelled via Transfer Queue API"
}

main "$@"
