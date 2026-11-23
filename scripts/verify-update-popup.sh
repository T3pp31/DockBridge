#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-/Applications/DockBridge.app}"
BUNDLE_ID="${BUNDLE_ID:-$(bash "${ROOT}/scripts/release-config.sh" bundle_identifier)}"
if [[ -z "$BUNDLE_ID" ]]; then
  echo "bundle_identifier not found in config/release.toml" >&2
  exit 1
fi

SKIPPED_CHECKS=0

read_skipped_version() {
  # Use `defaults` (cfprefsd) instead of editing the plist directly with
  # PlistBuddy; the hardcoded container path broke for sandboxed installs and
  # bypassed cfprefsd caching.
  defaults read "$BUNDLE_ID" skippedUpdateVersion 2>/dev/null || true
}

clear_skipped_version() {
  defaults delete "$BUNDLE_ID" skippedUpdateVersion 2>/dev/null || true
}

kill_dockbridge() {
  pkill -x DockBridge 2>/dev/null || true
  sleep 1
}

wait_for_update_sheet() {
  local timeout="${1:-20}"
  local elapsed=0
  local err_file
  err_file="$(mktemp)"
  while (( elapsed < timeout )); do
    local result=""
    local status=0
    set +e
    result=$(osascript <<'APPLESCRIPT' 2>"$err_file"
tell application "System Events"
  if exists process "DockBridge" then
    tell process "DockBridge"
      if exists (sheet 1 of window 1) then
        if exists static text "Update Available" of sheet 1 of window 1 then
          return "true"
        end if
      end if
    end tell
  end if
end tell
return "false"
APPLESCRIPT
    )
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
      # Issue #839 F52: do not silently swallow Accessibility/osascript errors as timeout.
      echo "FAIL: osascript failed while waiting for update sheet (exit $status): $(cat "$err_file")" >&2
      rm -f "$err_file"
      return 2
    fi
    if [[ "$result" == "true" ]]; then
      rm -f "$err_file"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  rm -f "$err_file"
  return 1
}

sheet_absent() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "DockBridge") then return true
  tell process "DockBridge"
    if not (exists window 1) then return true
    return not (exists sheet 1 of window 1)
  end tell
end tell
return true
APPLESCRIPT
}

modals_absent() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "DockBridge") then return true
  tell process "DockBridge"
    if not (exists window 1) then return true
    return not ((exists sheet 1 of window 1) or (exists alert 1))
  end tell
end tell
return true
APPLESCRIPT
}

app_window_responsive() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  if not (exists process "DockBridge") then return false
  tell process "DockBridge"
    if not (exists window 1) then return false
    set _title to name of window 1
    return true
  end tell
end tell
APPLESCRIPT
}

click_sheet_button() {
  local index="$1"
  osascript <<APPLESCRIPT
tell application "System Events"
  tell process "DockBridge"
    set buttonsFound to {}
    set allElems to entire contents of sheet 1 of window 1
    repeat with e in allElems
      try
        if (role of e as text) is "AXButton" then
          set end of buttonsFound to e
        end if
      end try
    end repeat
    click item $index of buttonsFound
  end tell
end tell
APPLESCRIPT
}

# Issue #839 F54: run a single XCTest case and inspect its xcresult summary so
# a misspelled selector (0 tests) or XCTSkip can never report PASS.
run_xctest_case() {
  local test_identifier="$1"
  local description="$2"
  local result_dir
  result_dir="$(mktemp -d)"
  local result_bundle="${result_dir}/results.xcresult"
  local rc=0
  set +e
  xcodebuild \
    -project apps/macos/DockBridge.xcodeproj \
    -scheme DockBridge \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:"$test_identifier" \
    -resultBundlePath "$result_bundle" \
    test
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    rm -rf "$result_dir"
    echo "FAIL: ${description} (xcodebuild exit ${rc})" >&2
    return 1
  fi
  if [[ ! -d "$result_bundle" ]]; then
    rm -rf "$result_dir"
    echo "FAIL: ${description} (missing xcresult bundle)" >&2
    return 1
  fi
  local summary total passed skipped failed
  if ! summary=$(xcrun xcresulttool get test-results summary --path "$result_bundle" --format json 2>/dev/null); then
    rm -rf "$result_dir"
    echo "FAIL: ${description} (failed to read xcresult summary)" >&2
    return 1
  fi
  rm -rf "$result_dir"
  total=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("totalTestCount", 0))')
  passed=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("passedTests", 0))')
  skipped=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("skippedTests", 0))')
  failed=$(printf '%s' "$summary" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("failedTests", 0))')
  if [[ "$total" -lt 1 ]]; then
    echo "FAIL: ${description} (no tests matched ${test_identifier})" >&2
    return 1
  fi
  if [[ "$failed" -ne 0 || "$skipped" -ne 0 || "$passed" -lt 1 ]]; then
    echo "FAIL: ${description} (total=${total} passed=${passed} skipped=${skipped} failed=${failed})" >&2
    return 1
  fi
  return 0
}

# Issue #839 F53: support a controlled fixture JSON via UPDATE_API_FIXTURE_JSON
# (or direct EXPECTED_RELEASE_URL / EXPECTED_ASSET_URL overrides) so local
# pre-release config/release.toml versions do not fail against live GitHub API.
fetch_release_api_json() {
  if [[ -n "${UPDATE_API_FIXTURE_JSON:-}" ]]; then
    cat "$UPDATE_API_FIXTURE_JSON"
  else
    curl -fsS --max-time 30 -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/T3pp31/DockBridge/releases/latest
  fi
}

main() {
  echo "== Test 1: update sheet on launch =="
  kill_dockbridge
  clear_skipped_version
  open "$APP"
  if wait_for_update_sheet 25; then
    echo "PASS: Update sheet displayed"
  else
    echo "FAIL: Update sheet not found"
    exit 1
  fi

  echo "== Test 2: Download opens release page =="
  LOG_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  click_sheet_button 2
  sleep 2
  local expected_asset_url expected_url
  if [[ -n "${EXPECTED_RELEASE_URL:-}" && -n "${EXPECTED_ASSET_URL:-}" ]]; then
    expected_url="$EXPECTED_RELEASE_URL"
    expected_asset_url="$EXPECTED_ASSET_URL"
  else
    local api_json
    api_json=$(fetch_release_api_json) \
      || { echo "FAIL: GitHub API request failed" >&2; exit 1; }
    expected_asset_url=$(printf '%s' "$api_json" | python3 -c "import sys,json; r=json.load(sys.stdin); print(next((a['browser_download_url'] for a in r.get('assets', []) if a['name'].endswith('.dmg')), ''))")
    expected_url=$(printf '%s' "$api_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['html_url'])")
  fi
  if [[ -z "$expected_asset_url" ]]; then
    echo "FAIL: no DMG asset in latest release" >&2
    exit 1
  fi
  local release_version expected_dmg_name
  release_version="${EXPECTED_RELEASE_VERSION:-$(bash "${ROOT}/scripts/release-config.sh" version)}"
  expected_dmg_name=$(bash "${ROOT}/scripts/release-config.sh" --expand asset_name_template --version "$release_version")
  if [[ -z "$release_version" || -z "$expected_dmg_name" ]]; then
    echo "FAIL: Required release asset configuration is missing" >&2
    exit 1
  fi
  if [[ "$expected_asset_url" != *"$expected_dmg_name" ]]; then
    echo "FAIL: Unexpected DMG URL: $expected_asset_url (expected suffix $expected_dmg_name)" >&2
    exit 1
  fi

  local observed_url
  observed_url=$(log show --info --start "$LOG_START" --style compact \
    --predicate 'process == "DockBridge" AND eventMessage CONTAINS "opening update release page:"' 2>/dev/null \
    | sed -n 's/.*opening update release page: \(https:\/\/[^ ]*\).*/\1/p' | tail -1)
  if [[ -n "$observed_url" && "$observed_url" == "$expected_url" ]]; then
    echo "PASS: Download button clicked; target URL is $expected_url"
  else
    echo "FAIL: Expected $expected_url, observed ${observed_url:-<none>}"
    exit 1
  fi

  echo "== Test 3: Later and Skip Version behavior =="
  if run_xctest_case \
    "DockBridgeTests/UpdateCheckViewModelTests/testLaterDismissesWithoutPersistingSkip" \
    "Later dismisses without persisting skip"; then
    echo "PASS: Later dismisses without persisting skip in unit tests"
  else
    exit 1
  fi
  if run_xctest_case \
    "DockBridgeTests/UpdateCheckViewModelTests/testSkipVersionPersistsSkippedVersionAndSuppressesRelaunch" \
    "Skip Version persists skipped version and suppresses relaunch"; then
    echo "PASS: Skip Version saves skipped version and suppresses relaunch in unit tests"
  else
    exit 1
  fi

  echo "== Test 4: offline launch does not block startup =="
  kill_dockbridge
  clear_skipped_version
  if run_xctest_case \
    "DockBridgeTests/UpdateCheckViewModelTests/testCheckOnLaunchIgnoresNetworkFailure" \
    "Offline/network failure handling test"; then
    echo "PASS: Network failure is ignored during update check"
  else
    exit 1
  fi
  # LaunchServices does not pass proxy environment variables through to the
  # app. Use a referenced system anchor and verify that it actually blocks I/O.
  if ! sudo -n true 2>/dev/null; then
    echo "SKIP: offline-launch check requires passwordless sudo for pf rules"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
  elif ! sudo -n pfctl -sr 2>/dev/null | grep -Fq 'anchor "com.apple/*"'; then
    echo "SKIP: offline-launch check requires the standard com.apple anchor"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
  else
    local offline_api_host offline_probe_timeout_secs offline_observation_secs offline_poll_interval_secs
    offline_api_host=$(bash "${ROOT}/scripts/release-config.sh" --section verification offline_api_host)
    offline_probe_timeout_secs=$(bash "${ROOT}/scripts/release-config.sh" --section verification --int offline_probe_timeout_secs)
    offline_observation_secs=$(bash "${ROOT}/scripts/release-config.sh" --section verification --int offline_observation_secs)
    offline_poll_interval_secs=$(bash "${ROOT}/scripts/release-config.sh" --section verification --int offline_poll_interval_secs)
    if [[ ! "$offline_observation_secs" =~ ^[1-9][0-9]*$ || ! "$offline_poll_interval_secs" =~ ^[1-9][0-9]*$ ]] ||
       (( offline_poll_interval_secs > offline_observation_secs )); then
      echo "FAIL: Invalid offline observation settings" >&2
      exit 1
    fi
    if [[ ! "$offline_api_host" =~ ^[a-zA-Z0-9.-]+$ || ! "$offline_probe_timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
      echo "FAIL: Invalid offline verification configuration" >&2
      exit 1
    fi
    if ! curl --silent --show-error --noproxy '*' --max-time "$offline_probe_timeout_secs" \
      --output /dev/null "https://$offline_api_host/"; then
      echo "SKIP: offline-launch check requires initial connectivity to $offline_api_host"
      SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
    else
      BLOCK_ANCHOR="com.apple/dockbridge_offline_check_$$"
      PF_TOKEN=""
      restore_pf() {
        sudo -n pfctl -a "$BLOCK_ANCHOR" -F rules >/dev/null 2>&1 || true
        if [[ -n "$PF_TOKEN" ]]; then
          sudo -n pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
          PF_TOKEN=""
        fi
      }
      trap restore_pf EXIT
      local pf_enable_output
      pf_enable_output=$(sudo -n pfctl -E 2>&1)
      PF_TOKEN=$(printf '%s\n' "$pf_enable_output" | awk '/Token[[:space:]]*:/ { print $3; exit }')
      if [[ ! "$PF_TOKEN" =~ ^[0-9]+$ ]]; then
        PF_TOKEN=""
        echo "FAIL: PF did not return an enable-reference token" >&2
        exit 1
      fi
      printf 'block drop out quick proto tcp to %s port {80, 443}\n' "$offline_api_host" \
        | sudo -n pfctl -a "$BLOCK_ANCHOR" -f - >/dev/null
      if curl --silent --noproxy '*' --max-time "$offline_probe_timeout_secs" \
        --output /dev/null "https://$offline_api_host/"; then
        echo "FAIL: Offline rule did not block $offline_api_host" >&2
        exit 1
      fi

      local offline_log_start
      offline_log_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      open "$APP"
      local offline_check_deadline=$((SECONDS + offline_observation_secs))
      # LaunchServices may return before the process appears. Wait for startup
      # within the same deadline before treating process absence as a crash.
      while ! pgrep -x DockBridge >/dev/null; do
        if (( SECONDS >= offline_check_deadline )); then
          echo "FAIL: App did not launch offline"
          exit 1
        fi
        sleep "$offline_poll_interval_secs"
      done
      while (( SECONDS < offline_check_deadline )); do
        if ! pgrep -x DockBridge >/dev/null; then
          echo "FAIL: App did not stay running offline"
          exit 1
        fi
        if [[ "$(sheet_absent)" != "true" ]]; then
          echo "FAIL: Unexpected sheet while offline"
          exit 1
        fi
        sleep "$offline_poll_interval_secs"
      done
      # Issue #839 F55: verify UI window responsiveness and that the launch
      # update check actually attempted and logged its offline network failure.
      if [[ "$(app_window_responsive)" != "true" ]]; then
        echo "FAIL: Main window was not responsive while offline"
        exit 1
      fi
      local offline_failure_log
      offline_failure_log=$(log show --info --start "$offline_log_start" --style compact \
        --predicate 'process == "DockBridge" AND eventMessage CONTAINS "update check failed on launch:"' 2>/dev/null \
        | grep -F "update check failed on launch:" || true)
      if [[ -z "$offline_failure_log" ]]; then
        echo "FAIL: Did not observe expected 'update check failed on launch:' log while offline"
        exit 1
      fi
      if pgrep -x DockBridge >/dev/null && [[ "$(sheet_absent)" == "true" ]]; then
        echo "PASS: App stayed responsive without a sheet and logged offline update failure"
      else
        echo "FAIL: App or sheet state changed during offline launch"
        exit 1
      fi
      restore_pf
      trap - EXIT
    fi
  fi
  if [[ "$(modals_absent)" != "true" ]]; then
    echo "FAIL: Blocking modal or alert appeared while offline"
    exit 1
  fi

  echo "== Test 5: HostKey deferral =="
  kill_dockbridge
  if run_xctest_case \
    "DockBridgeTests/UpdateCheckViewModelTests/testCheckOnLaunchDefersSheetWhileHostKeyBlocking" \
    "HostKey deferral test"; then
    echo "PASS: HostKey blocking defers update sheet until dismissal in unit tests"
  else
    exit 1
  fi

  kill_dockbridge
  if (( SKIPPED_CHECKS > 0 )); then
    echo "ALL VERIFICATIONS COMPLETED (${SKIPPED_CHECKS} skipped)"
  else
    echo "ALL VERIFICATIONS COMPLETED (0 skipped)"
  fi
}

main "$@"
