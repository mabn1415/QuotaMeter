#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ ! -d "$ROOT/collector/node_modules/playwright" ]; then
  echo '先に ./scripts/install-deps.sh を実行してください。' >&2
  exit 1
fi

command -v xcode-select >/dev/null 2>&1 || {
  echo 'Xcode または Command Line Tools が見つかりません。' >&2
  exit 1
}
command -v swift >/dev/null 2>&1 || {
  echo 'Swift が見つかりません。Xcode のインストールと選択状態を確認してください。' >&2
  exit 1
}

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$DEVELOPER_DIR_PATH" ]; then
  echo '開発ツールが選択されていません。Xcode のインストールと xcode-select の状態を確認してください。' >&2
  exit 1
fi

# Prefer an installed full Xcode for this build without changing the user's
# system-wide xcode-select setting. Command Line Tools remain supported.
if [[ "$DEVELOPER_DIR_PATH" == "/Library/Developer/CommandLineTools" ]] && \
   [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  DEVELOPER_DIR_PATH="$DEVELOPER_DIR"
fi
echo "開発ツール: $DEVELOPER_DIR_PATH"
swift --version | head -n 1

# A failed build must not leave an older bundle available to install.
rm -rf "$ROOT/dist/QuotaMeter.app"
if ! swift build -c release; then
  echo 'QuotaMeter のビルドに失敗しました。dist/QuotaMeter.app は作成していません。' >&2
  echo 'SwiftUIMacros のエラーが出る場合は、macOS のソフトウェアアップデートで Command Line Tools を更新するか、Xcode をインストールしてください。' >&2
  exit 1
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
# Use a fresh staging directory so old resources never enter the new bundle.
STAGING="$(mktemp -d "$ROOT/.build/quotameter-app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/QuotaMeter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/collector"
cp "$BIN_DIR/QuotaMeter" "$APP/Contents/MacOS/QuotaMeter"
for file in collector.mjs manual-setup.mjs parser.mjs privacy.mjs package.json; do
  cp "$ROOT/collector/$file" "$APP/Contents/Resources/collector/"
done
cp -R "$ROOT/collector/node_modules" "$APP/Contents/Resources/collector/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Include this project's terms and source availability notice in the bundle.
cp "$ROOT/LICENSE" "$ROOT/README.org" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.quotameter.app</string>
<key>CFBundleName</key><string>QuotaMeter</string>
<key>CFBundleDisplayName</key><string>QuotaMeter</string>
<key>CFBundleExecutable</key><string>QuotaMeter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 mabn1415. GPL-3.0-only.</string>
<key>CFBundleVersion</key><string>35</string>
<key>CFBundleShortVersionString</key><string>3.5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/QuotaMeter"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/QuotaMeter.app"
mv "$APP" "$ROOT/dist/QuotaMeter.app"
echo "作成: $ROOT/dist/QuotaMeter.app"
echo '起動前に旧アプリを終了してください。通常は ./scripts/install-app.sh でインストールします。'
