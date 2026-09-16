#!/usr/bin/env bash
# Manual E2E verification against Docker SFTP (atmoz/sftp).
# Usage: ./scripts/e2e-verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="${SFTP_HOST:-127.0.0.1}"
PORT="${SFTP_PORT:-2222}"
USER="${SFTP_USER:-demo}"
PASSWORD="${SFTP_PASSWORD:-password}"
CONTAINER_NAME="${SFTP_CONTAINER:-dockbridge-e2e}"

WORKDIR="$(mktemp -d)"
KNOWN_HOSTS="$WORKDIR/known_hosts.json"
CONFIG="$WORKDIR/config.toml"
LOCAL_FILE="$WORKDIR/local-upload.txt"
DOWNLOAD_FILE="$WORKDIR/local-download.txt"
REMOTE_FILE="upload/e2e-verify.txt"
LOG="$WORKDIR/e2e.log"
KEYFILE="$WORKDIR/id_ed25519"
KEYFILE_ENC="$WORKDIR/id_ed25519_enc"
KEY_PASSPHRASE="${SFTP_KEY_PASSPHRASE:-testpassphrase}"

CLI=(cargo run -q -p dockbridge-cli -- --config "$CONFIG")

pass=0
fail=0

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

log() {
  echo "[e2e] $*" | tee -a "$LOG"
}

check() {
  local name="$1"
  shift
  log "CHECK: $name"
  if "$@" >>"$LOG" 2>&1; then
    log "PASS: $name"
    pass=$((pass + 1))
  else
    log "FAIL: $name"
    fail=$((fail + 1))
  fi
}

prepare_config() {
  rm -f "$KNOWN_HOSTS"
  cat >"$CONFIG" <<EOF
connection_timeout_secs = 30
session_health_check_interval_secs = 10
transfer_retry_count = 3
known_hosts_path = "$KNOWN_HOSTS"
EOF
  echo "e2e upload $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCAL_FILE"
}

ensure_key() {
  # Generate an unencrypted ed25519 key and a directly-encrypted copy for the
  # private-key auth cases. The public keys are mounted into the container's
  # /home/$USER/.ssh/keys directory so atmoz/sftp appends them to
  # authorized_keys at startup.
  if [[ ! -f "$KEYFILE" ]]; then
    ssh-keygen -q -t ed25519 -N "" -f "$KEYFILE" >/dev/null 2>&1
    ssh-keygen -q -t ed25519 -N "$KEY_PASSPHRASE" -f "$KEYFILE_ENC" >/dev/null 2>&1
  fi
}

ensure_container() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    return 0
  fi
  ensure_key
  log "Starting Docker SFTP container $CONTAINER_NAME ..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER_NAME" -p "${PORT}:22" -e SFTP_USER="$USER" \
    -v "$WORKDIR/id_ed25519.pub:/home/$USER/.ssh/keys/id_ed25519.pub:ro" \
    -v "$WORKDIR/id_ed25519_enc.pub:/home/$USER/.ssh/keys/id_ed25519_enc.pub:ro" \
    atmoz/sftp "${USER}:${PASSWORD}:::upload" >/dev/null
  sleep 3
}

host_key_reject() {
  prepare_config
  { printf '%s\n' "$PASSWORD" "no"; } | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin
  test ! -s "$KNOWN_HOSTS"
}

host_key_accept() {
  prepare_config
  { printf '%s\n' "$PASSWORD" "yes"; } | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin
  test -s "$KNOWN_HOSTS"
  grep -q '"entries"' "$KNOWN_HOSTS"
}

host_key_no_reprompt() {
  printf '%s\n' "$PASSWORD" | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin \
    --path upload >/dev/null
}

private_key_auth_plain() {
  ensure_key
  prepare_config
  # Seed the store with the host key first so the actual key-only run below
  # never needs an interactive host-key prompt. In this non-TTY CI pipe the
  # "yes" answer to the host-key confirmation is supplied before the password.
  { printf '%s\n' "$PASSWORD" "yes"; } | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin \
    --path upload >/dev/null
  # Now authenticate with the key (host key already trusted)
  "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" \
    --identity "$WORKDIR/id_ed25519" --path upload >/dev/null
}

private_key_auth_encrypted() {
  # Authenticate with an encrypted key; passphrase comes from --passphrase-stdin
  printf '%s\n' "$KEY_PASSPHRASE" | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" \
    --identity "$WORKDIR/id_ed25519_enc" --passphrase-stdin \
    --path upload >/dev/null
}

upload_file() {
  printf '%s\n' "$PASSWORD" | "${CLI[@]}" upload \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin \
    --local "$LOCAL_FILE" --remote "$REMOTE_FILE"
}

download_file() {
  rm -f "$DOWNLOAD_FILE"
  printf '%s\n' "$PASSWORD" | "${CLI[@]}" download \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin \
    --remote "$REMOTE_FILE" --local "$DOWNLOAD_FILE"
  cmp -s "$LOCAL_FILE" "$DOWNLOAD_FILE"
}

transfer_queue_states() {
  cargo test -q -p dockbridge-core transfer::manager::tests -- --nocapture >/dev/null
}

corrupted_known_hosts_errors() {
  prepare_config
  { printf '%s\n' "$PASSWORD" "yes"; } | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin >/dev/null
  echo '{}' >"$KNOWN_HOSTS"
  local output
  output=$(printf '%s\n' "$PASSWORD" | "${CLI[@]}" list \
    --host "$HOST" --port "$PORT" --user "$USER" --password-stdin \
    2>&1) && return 1
  echo "$output" | grep -qi 'known hosts'
}

swift_corrupted_known_hosts_message() {
  cd "$ROOT/apps/macos"
  xcodebuild \
    -scheme DockBridge \
    -destination 'platform=macOS' \
    -only-testing:DockBridgeTests/KnownHostsErrorMessageTests \
    -configuration Debug \
    build test \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    >/dev/null 2>&1
}

transfer_cancel_in_progress() {
  "$ROOT/scripts/verify-transfer-cancel.sh" >/dev/null 2>&1
}

main() {
  ensure_container
  prepare_config

  check "host key reject does not persist trust" host_key_reject
  check "host key accept persists trusted entry" host_key_accept
  check "second connection skips host key prompt" host_key_no_reprompt
  check "private-key auth (plain key)" private_key_auth_plain
  check "private-key auth (encrypted key, --passphrase-stdin)" private_key_auth_encrypted
  check "upload succeeds" upload_file
  check "download matches uploaded content" download_file
  check "transfer queue lifecycle tests pass" transfer_queue_states
  check "corrupted known_hosts returns readable error (CLI)" corrupted_known_hosts_errors
  check "corrupted known_hosts user-facing message (Swift)" swift_corrupted_known_hosts_message
  check "in-progress large upload can be cancelled (Transfer Queue)" transfer_cancel_in_progress

  log "SUMMARY: $pass passed, $fail failed"
  log "Log: $LOG"

  if [[ "$fail" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
