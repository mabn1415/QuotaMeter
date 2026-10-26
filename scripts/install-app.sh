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
  BACKUP_DIR="$TARGET_DIR/QuotaMeter Backups"
  mkdir -p "$BACKUP_DIR"
  STAMP="$(date '+%Y%m%d-%H%M%S')"
  ARCHIVED_BACKUP="$BACKUP_DIR/QuotaMeter-$STAMP.app"
  COUNTER=1
  while [ -e "$ARCHIVED_BACKUP" ]; do
    ARCHIVED_BACKUP="$BACKUP_DIR/QuotaMeter-$STAMP-$COUNTER.app"
    COUNTER=$((COUNTER + 1))
  done
  mv "$BACKUP" "$ARCHIVED_BACKUP"
  echo "以前のバックアップを退避: $ARCHIVED_BACKUP"
fi
if [ -e "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! mv "$STAGING/QuotaMeter.app" "$TARGET"; then
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; fi
  exit 1
fi
echo "インストール完了: $TARGET"
echo 'Finder → ホーム → Applications → QuotaMeter.app から起動できます。'
open "$TARGET"
