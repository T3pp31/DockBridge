#!/bin/bash
# DEV ONLY — do not ship in release DMGs.
#
# Installs an unsigned local build, removes quarantine attributes, and launches
# the app. This bypasses Gatekeeper download protection and must not be used for
# public distribution. Release builds are Developer ID signed and notarized.

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

echo "DockBridge を Applications にインストールしています..."
ditto "$SOURCE_PATH" "$INSTALL_PATH"

echo "macOS のセキュリティ制限を解除しています..."
xattr -cr "$INSTALL_PATH"

echo "DockBridge を起動しています..."
open "$INSTALL_PATH"

notify "インストールが完了しました"

echo ""
echo "完了しました。このウィンドウは閉じてください。"
read -r -p "Enter キーで終了します... " _
