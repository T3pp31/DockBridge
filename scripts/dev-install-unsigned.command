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

if [[ ! -w "/Applications" ]] || [[ -d "$INSTALL_PATH" && ! -w "$INSTALL_PATH" ]]; then
  alert "インストールできません。\\n\\n/Applications または既存の DockBridge.app に書き込み権限がありません。"
  exit 1
fi

echo "DockBridge を Applications にインストールしています..."
if ! ditto "$SOURCE_PATH" "$INSTALL_PATH"; then
  alert "DockBridge.app のインストールに失敗しました。"
  exit 1
fi

echo "macOS のセキュリティ制限を解除しています..."
if ! xattr -cr "$INSTALL_PATH"; then
  alert "DockBridge.app のセキュリティ属性の更新に失敗しました。"
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
