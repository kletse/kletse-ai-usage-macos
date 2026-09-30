#!/bin/zsh
# Builds AIUsage.app, installs it into ~/Applications and (re)starts it.
#   scripts/bundle.sh            build, install and launch
#   scripts/bundle.sh --no-open  build and install only
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME=AIUsage
BUNDLE_ID=be.kletse.ai-usage
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI Usage</string>
    <key>CFBundleDisplayName</key><string>AI Usage</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed $INSTALL_DIR/$APP_NAME.app"

if [[ "${1:-}" != "--no-open" ]]; then
    open "$INSTALL_DIR/$APP_NAME.app"
fi
