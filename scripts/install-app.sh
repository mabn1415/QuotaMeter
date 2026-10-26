#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/dist/QuotaMeter.app"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/QuotaMeter.app"
if [ ! -d "$SOURCE" ]; then
  echo '先に ./scripts/build-app.sh を実行してください。' >&2
  exit 1
fi
# Match process names literally, independent of installation path.
if pgrep -x AllowanceMonitor >/dev/null 2>&1 || pgrep -x QuotaMeter >/dev/null 2>&1; then
  echo 'インストール前に AllowanceMonitor / QuotaMeter を終了してください。' >&2
  exit 1
fi
mkdir -p "$TARGET_DIR"
STAGING="$(mktemp -d "$TARGET_DIR/.quotameter-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# Finish copying and verifying before touching the installed bundle.
ditto "$SOURCE" "$STAGING/QuotaMeter.app"
codesign --verify --deep --strict "$STAGING/QuotaMeter.app"
BACKUP="$TARGET_DIR/QuotaMeter.app.previous"
if [ -e "$BACKUP" ]; then
  echo "既存のバックアップがあります。内容を確認して別の場所に移動してください: $BACKUP" >&2
  exit 1
fi
if [ -e "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! mv "$STAGING/QuotaMeter.app" "$TARGET"; then
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
  exit 1
fi
echo "インストール完了: $TARGET"
echo '旧アプリとデータは削除していません。旧ログイン項目を無効にしてから使用してください。'
echo 'Finder → ホーム → Applications → QuotaMeter.app から起動できます。'
open "$TARGET"
