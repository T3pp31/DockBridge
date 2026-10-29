#!/bin/bash
# DEV ONLY — do not ship in release DMGs.
#
# Installs an unsigned local build, removes quarantine attributes, and launches
# the app. This bypasses Gatekeeper download protection and must not be used for
# public distribution. GitHub Release DMGs are also unsigned (see README).

set -euo pipefail

APP_NAME="DockBridge.app"
INSTALL_PATH="/Applications/${APP_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_PATH="${SCRIPT_DIR}/${APP_NAME}"

alert() {
  osascript -e "display alert \"DockBridge\" message \"${1}\" as warning"
}

notify() {
  osascript -e "display notification \"${1}\" with title \"DockBridge\""
}

if [[ ! -d "$SOURCE_PATH" ]]; then
  alert "DockBridge.app が見つかりません。\\n\\nDMG を開いた状態で、このファイルを実行してください。"
  exit 1
fi

# Read the required companion settings from beside this script.
SETTINGS_PATH="${SCRIPT_DIR}/dev-install-settings.conf"
if [[ ! -f "$SETTINGS_PATH" ]]; then
  alert "dev-install-settings.conf が見つかりません。スクリプトと同じ場所に置いてください。"
  exit 1
fi
# shellcheck source=scripts/dev-install-settings.conf
source "$SETTINGS_PATH"
if [[ ! "${INSTALL_EXIT_TIMEOUT_SECONDS:-}" =~ ^[1-9][0-9]*$ ||
      ! "${INSTALL_EXIT_POLL_INTERVAL_SECONDS:-}" =~ ^[1-9][0-9]*$ ]] ||
   (( INSTALL_EXIT_POLL_INTERVAL_SECONDS > INSTALL_EXIT_TIMEOUT_SECONDS )); then
  alert "終了待機設定は正の整数で指定し、確認間隔を待機時間以下にしてください。"
  exit 1
fi

echo "DockBridge を Applications にインストールしています..."
# Confirm the old instance has exited before replacing its bundle (#670).
# Do not force-kill it: a timeout must leave the installed app untouched.
pkill -x DockBridge 2>/dev/null || true
exit_deadline=$((SECONDS + INSTALL_EXIT_TIMEOUT_SECONDS))
while true; do
  if pgrep -x DockBridge >/dev/null 2>&1; then
    if (( SECONDS >= exit_deadline )); then
      alert "DockBridge が終了しなかったため、インストールを中止しました。終了後に再実行してください。"
      exit 1
    fi
    sleep "$INSTALL_EXIT_POLL_INTERVAL_SECONDS"
  else
    query_status=$?
    if [[ "$query_status" != 1 ]]; then
      alert "DockBridge の終了状態を確認できなかったため、インストールを中止しました。"
      exit 1
    fi
    break
  fi
done
ditto "$SOURCE_PATH" "$INSTALL_PATH"

echo "macOS のセキュリティ制限を解除しています..."
xattr -cr "$INSTALL_PATH"

echo "DockBridge を起動しています..."
open "$INSTALL_PATH"

notify "インストールが完了しました"

echo ""
echo "完了しました。このウィンドウは閉じてください。"
read -r -p "Enter キーで終了します... " _
