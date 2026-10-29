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

if [[ ! -w "/Applications" ]] || [[ -d "$INSTALL_PATH" && ! -w "$INSTALL_PATH" ]]; then
  alert "インストールできません。/Applications または既存アプリに書き込み権限がありません。"
  exit 1
fi

# Prepare a complete replacement on the destination filesystem first. Failed
# preparation leaves the installed bundle intact; ditto never merges into it.
STAGE_DIR="$(mktemp -d "/Applications/.DockBridge-install.XXXXXX")"
STAGED_APP="${STAGE_DIR}/${APP_NAME}"
BACKUP_PATH="${STAGE_DIR}/previous.app"
cleanup_install() {
  if [[ -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ]]; then
    if [[ ! -e "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]]; then
      if ! mv "$BACKUP_PATH" "$INSTALL_PATH"; then
        echo "復元できませんでした。元のアプリを ${BACKUP_PATH} に保持します。" >&2
        return
      fi
    fi
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup_install EXIT

echo "DockBridge を Applications にインストールしています..."
if ! ditto "$SOURCE_PATH" "$STAGED_APP"; then
  alert "DockBridge.app の準備に失敗しました。"
  exit 1
fi
if ! xattr -cr "$STAGED_APP"; then
  alert "DockBridge.app のセキュリティ属性の更新に失敗しました。"
  exit 1
fi

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
# The old app is stopped. Retain it until the prepared bundle is installed.
if [[ -e "$INSTALL_PATH" || -L "$INSTALL_PATH" ]]; then
  if ! mv "$INSTALL_PATH" "$BACKUP_PATH"; then
    alert "既存の DockBridge.app を移動できませんでした。"
    exit 1
  fi
fi
if ! mv "$STAGED_APP" "$INSTALL_PATH"; then
  alert "DockBridge.app の置換に失敗しました。元のアプリを復元します。"
  exit 1
fi

echo "DockBridge を起動しています..."
if ! open "$INSTALL_PATH"; then
  alert "DockBridge.app の起動に失敗しました。"
  exit 1
fi

notify "インストールが完了しました"

echo ""
echo "完了しました。このウィンドウは閉じてください。"
read -r -p "Enter キーで終了します... " _
