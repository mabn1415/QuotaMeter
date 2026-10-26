#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ ! -d "$ROOT/collector/node_modules/playwright" ]; then
  echo '先に ./scripts/install-deps.sh を実行してください。' >&2
  exit 1
fi
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
# Use a fresh staging directory so old resources never enter the new bundle.
STAGING="$(mktemp -d "$ROOT/.build/quotameter-app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/QuotaMeter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/collector"
cp "$BIN_DIR/QuotaMeter" "$APP/Contents/MacOS/QuotaMeter"
for file in collector.mjs parser.mjs privacy.mjs package.json; do
  cp "$ROOT/collector/$file" "$APP/Contents/Resources/collector/"
done
cp -R "$ROOT/collector/node_modules" "$APP/Contents/Resources/collector/"
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
<key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 mabn1415. GPL-3.0-only.</string>
<key>CFBundleVersion</key><string>31</string>
<key>CFBundleShortVersionString</key><string>3.1</string>
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
