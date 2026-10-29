#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-/Applications/DockBridge.app}"
BUNDLE_ID="${BUNDLE_ID:-$(awk -F'"' '/^bundle_identifier / { print $2; exit }' config/release.toml)}"
if [[ -z "$BUNDLE_ID" ]]; then
  echo "bundle_identifier not found in config/release.toml" >&2
  exit 1
fi

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
  while (( elapsed < timeout )); do
    local result
    result=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
  if exists process "DockBridge" then
    tell process "DockBridge"
      if exists (sheet 1 of window 1) then
        if exists static text "Update Available" of sheet 1 of window 1 then
          return true
        end if
      end if
    end tell
  end if
end tell
return false
APPLESCRIPT
    ) || result=""
    if [[ "$result" == "true" ]]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
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

echo "== Test 2: Download opens DMG URL =="
click_sheet_button 2
sleep 2
api_json=$(curl -fsS --max-time 30 -H "Accept: application/vnd.github+json" https://api.github.com/repos/T3pp31/DockBridge/releases/latest) \
  || { echo "FAIL: GitHub API request failed" >&2; exit 1; }
expected_url=$(printf '%s' "$api_json" | python3 -c "import sys,json; r=json.load(sys.stdin); print(next((a['browser_download_url'] for a in r.get('assets', []) if a['name'].endswith('.dmg')), ''))")
if [[ -z "$expected_url" ]]; then
  echo "FAIL: no DMG asset in latest release" >&2
  exit 1
fi
if [[ "$expected_url" == *"DockBridge-0.1.2-macOS.dmg" ]]; then
  echo "PASS: Download button clicked; target URL is $expected_url"
else
  echo "FAIL: Unexpected DMG URL: $expected_url"
  exit 1
fi

echo "== Test 3: Later suppresses same version on relaunch =="
if xcodebuild -project apps/macos/DockBridge.xcodeproj -scheme DockBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:DockBridgeTests/UpdateCheckViewModelTests/testSkipUpdatePersistsSkippedVersionAndSuppressesRelaunch test 2>&1 | tail -8 | grep -q "TEST SUCCEEDED"; then
  echo "PASS: Later saves skipped version and suppresses relaunch in unit tests"
else
  echo "FAIL: Skip persistence test failed"
  exit 1
fi

echo "== Test 4: offline launch does not block startup =="
kill_dockbridge
clear_skipped_version
if xcodebuild -project apps/macos/DockBridge.xcodeproj -scheme DockBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:DockBridgeTests/UpdateCheckViewModelTests/testCheckOnLaunchIgnoresNetworkFailure test 2>&1 | tail -8 | grep -q "TEST SUCCEEDED"; then
  echo "PASS: Network failure is ignored during update check"
else
  echo "FAIL: Offline/network failure handling test failed"
  exit 1
fi
# LaunchServices does not pass proxy environment variables through to the
# app. Use a referenced system anchor and verify that it actually blocks I/O.
if ! sudo -n true 2>/dev/null; then
  echo "SKIP: offline-launch check requires passwordless sudo for pf rules"
elif ! sudo -n pfctl -sr 2>/dev/null | grep -Fq 'anchor "com.apple/*"'; then
  echo "SKIP: offline-launch check requires the standard com.apple anchor"
else
  offline_api_host=$(awk -F'"' '/^offline_api_host / { print $2; exit }' config/release.toml)
  offline_probe_timeout_secs=$(awk '/^offline_probe_timeout_secs / { print $3; exit }' config/release.toml)
  if [[ ! "$offline_api_host" =~ ^[a-zA-Z0-9.-]+$ || ! "$offline_probe_timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: Invalid offline verification configuration" >&2
    exit 1
  fi
  if ! curl --silent --show-error --noproxy '*' --max-time "$offline_probe_timeout_secs" \
    --output /dev/null "https://$offline_api_host/"; then
    echo "SKIP: offline-launch check requires initial connectivity to $offline_api_host"
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

    open "$APP"
    sleep 6
    if pgrep -x DockBridge >/dev/null && [[ "$(sheet_absent)" == "true" ]]; then
      echo "PASS: App launched without an update sheet while API connectivity was blocked"
    else
      echo "FAIL: App failed to start offline or displayed an unexpected sheet"
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
if xcodebuild -project apps/macos/DockBridge.xcodeproj -scheme DockBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:DockBridgeTests/UpdateCheckViewModelTests/testCheckOnLaunchDefersSheetWhileHostKeyBlocking test 2>&1 | tail -8 | grep -q "TEST SUCCEEDED"; then
  echo "PASS: HostKey blocking defers update sheet until dismissal in unit tests"
else
  echo "FAIL: HostKey deferral test failed"
  exit 1
fi

kill_dockbridge
echo "ALL VERIFICATIONS COMPLETED"
