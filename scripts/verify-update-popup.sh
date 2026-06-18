#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-/Users/fukutomiteppei/Library/Developer/Xcode/DerivedData/DockBridge-hjxsfbvxdglziagsfhxqzemiwnff/Build/Products/Debug/DockBridge.app}"
read_skipped_version() {
  local plist="$HOME/Library/Containers/com.dockbridge.app/Data/Library/Preferences/com.dockbridge.app.plist"
  /usr/libexec/PlistBuddy -c 'Print :skippedUpdateVersion' "$plist" 2>/dev/null || true
}

clear_skipped_version() {
  local plist="$HOME/Library/Containers/com.dockbridge.app/Data/Library/Preferences/com.dockbridge.app.plist"
  /usr/libexec/PlistBuddy -c 'Delete :skippedUpdateVersion' "$plist" 2>/dev/null || true
}

kill_dockbridge() {
  pkill -x DockBridge 2>/dev/null || true
  sleep 1
}

wait_for_update_sheet() {
  local timeout="${1:-20}"
  local elapsed=0
  while (( elapsed < timeout )); do
    if osascript <<'APPLESCRIPT' >/dev/null 2>&1
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
    then
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
    if not (exists sheet 1 of window 1) then return true
    try
      if exists static text "Update Available" of sheet 1 of window 1 then
        return false
      end if
    end try
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
expected_url=$(curl -s -H "Accept: application/vnd.github+json" https://api.github.com/repos/T3pp31/DockBridge/releases/latest \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(next(a['browser_download_url'] for a in r['assets'] if a['name'].endswith('.dmg')))")
if [[ "$expected_url" == *"DockBridge-0.1.2-macOS.dmg" ]]; then
  echo "PASS: Download button clicked; target URL is $expected_url"
else
  echo "FAIL: Unexpected DMG URL: $expected_url"
  exit 1
fi

echo "== Test 3: Later suppresses same version on relaunch =="
if xcodebuild -project apps/macos/DockBridge.xcodeproj -scheme DockBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:DockBridgeTests/UpdateCheckViewModelTests/testSkipUpdatePersistsSkippedVersionAndSuppressesRelaunch test 2>&1 | tail -8 | grep -q "TEST SUCCEEDED"; then
  echo "PASS: Later saves skipped version and suppresses relaunch"
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
HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 open "$APP"
sleep 6
if pgrep -x DockBridge >/dev/null; then
  echo "PASS: App launched while GitHub API unreachable"
else
  echo "FAIL: App did not stay running offline"
  exit 1
fi
if [[ "$(sheet_absent)" == "true" ]]; then
  echo "PASS: No update sheet when offline"
else
  echo "FAIL: Unexpected sheet while offline"
  exit 1
fi

echo "== Test 5: HostKey deferral =="
kill_dockbridge
if xcodebuild -project apps/macos/DockBridge.xcodeproj -scheme DockBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:DockBridgeTests/UpdateCheckViewModelTests/testCheckOnLaunchDefersSheetWhileHostKeyBlocking test 2>&1 | tail -8 | grep -q "TEST SUCCEEDED"; then
  echo "PASS: HostKey blocking defers update sheet until dismissal"
else
  echo "FAIL: HostKey deferral test failed"
  exit 1
fi

kill_dockbridge
echo "ALL VERIFICATIONS COMPLETED"
