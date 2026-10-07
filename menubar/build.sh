#!/bin/bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Insomnia.app"
TMP_BIN="$(mktemp -d)/InsomniaBar"

WORK="$(dirname "$TMP_BIN")"
swiftc -O -swift-version 5 -framework Cocoa "$SRC_DIR/Icons.swift" "$SRC_DIR/main.swift" -o "$TMP_BIN"
swiftc -O -swift-version 5 -framework Cocoa "$SRC_DIR/Icons.swift" "$SRC_DIR/tools/main.swift" -o "$WORK/render"
CLAUDE_ICNS="/Applications/Claude.app/Contents/Resources/electron.icns"
if [ -f "$CLAUDE_ICNS" ]; then
  iconutil -c iconset "$CLAUDE_ICNS" -o "$WORK/claude.iconset"
  "$WORK/render" spark-mask "$WORK/claude-spark.png" "$WORK/claude.iconset/icon_512x512@2x.png"
  export INSOMNIA_SPARK="$WORK/claude-spark.png"
fi
mkdir -p "$WORK/Insomnia.iconset"
"$WORK/render" iconset "$WORK/Insomnia.iconset"
iconutil -c icns "$WORK/Insomnia.iconset" -o "$WORK/Insomnia.icns"

pkill -x InsomniaBar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv "$TMP_BIN" "$APP/Contents/MacOS/InsomniaBar"
mkdir -p "$APP/Contents/Resources"
cp "$WORK/Insomnia.icns" "$APP/Contents/Resources/Insomnia.icns"
[ -f "$WORK/claude-spark.png" ] && cp "$WORK/claude-spark.png" "$APP/Contents/Resources/claude-spark.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.artemkorchunov.insomnia</string>
  <key>CFBundleName</key><string>Insomnia</string>
  <key>CFBundleDisplayName</key><string>Insomnia</string>
  <key>CFBundleExecutable</key><string>InsomniaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Insomnia</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
touch "$APP"
open "$APP"
echo "Built and launched $APP"
