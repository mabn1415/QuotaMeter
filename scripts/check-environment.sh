#!/bin/bash
set -euo pipefail

fail() {
  echo "環境確認エラー: $1" >&2
  exit 1
}

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 14 ]; then
  fail "macOS 14 以降が必要です。"
fi

command -v xcode-select >/dev/null 2>&1 || fail "Apple の開発ツールを確認できません。"
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"

# Use a full Xcode already present on the Mac without changing the global
# xcode-select setting. This also repairs the common CLT/Xcode mismatch.
if { [ -z "$DEVELOPER_DIR_PATH" ] || [[ "$DEVELOPER_DIR_PATH" == "/Library/Developer/CommandLineTools" ]]; } && \
   [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  DEVELOPER_DIR_PATH="$DEVELOPER_DIR"
fi

if [ -z "$DEVELOPER_DIR_PATH" ] || [ ! -d "$DEVELOPER_DIR_PATH" ]; then
  cat >&2 <<'EOF'
Apple の開発ツールが未導入です。次を実行し、表示された画面でインストールしてください。

  xcode-select --install

完了後に ./scripts/setup.sh をもう一度実行してください。
EOF
  exit 1
fi

command -v swift >/dev/null 2>&1 || fail "Swift が見つかりません。開発ツールを更新してください。"
SWIFT_VERSION_TEXT="$(swift --version 2>&1)"
SWIFT_MAJOR="$(printf '%s\n' "$SWIFT_VERSION_TEXT" | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -n 1)"
SWIFT_MINOR="$(printf '%s\n' "$SWIFT_VERSION_TEXT" | sed -nE 's/.*Swift version [0-9]+\.([0-9]+).*/\1/p' | head -n 1)"
if [ -z "$SWIFT_MAJOR" ] || [ -z "$SWIFT_MINOR" ] || \
   { [ "$SWIFT_MAJOR" -lt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -lt 9 ]; }; }; then
  fail "Swift 5.9 以降が必要です。開発ツールを更新してください。"
fi

command -v node >/dev/null 2>&1 || fail "Node.js 20 以降が必要です。"
command -v npm >/dev/null 2>&1 || fail "npm が見つかりません。"
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)' || \
  fail "Node.js 20 以降が必要です。"

[ -d "/Applications/Google Chrome.app" ] || fail "Google Chrome を Applications フォルダへインストールしてください。"

echo "macOS: $(sw_vers -productVersion)"
echo "開発ツール: $DEVELOPER_DIR_PATH"
printf '%s\n' "$SWIFT_VERSION_TEXT" | head -n 1
echo "Node.js: $(node --version)"
echo "Google Chrome: 確認済み"
echo "環境確認: 問題ありません"
