#!/bin/bash
# Builds NotchGlass and wraps it in a proper .app bundle (no Dock icon,
# correct Apple Events usage prompt). Output: ./NotchGlass.app
set -euo pipefail

CONFIG="${1:-release}"
APP="NotchGlass.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/NotchGlass"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH" "$APP/Contents/MacOS/NotchGlass"

# Bundle SwiftPM resources (ambient audio) so `Bundle.module` resolves inside the
# .app. SwiftPM emits `NotchGlass_NotchGlass.bundle` next to the built binary.
BIN_DIR="$(dirname "$BIN_PATH")"
RES_BUNDLE="$BIN_DIR/NotchGlass_NotchGlass.bundle"
if [ -d "$RES_BUNDLE" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
    echo "⚠︎ resource bundle not found at $RES_BUNDLE" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>NotchGlass</string>
    <key>CFBundleDisplayName</key>     <string>All in a notch</string>
    <key>CFBundleIdentifier</key>      <string>com.notchglass.app</string>
    <key>CFBundleExecutable</key>      <string>NotchGlass</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.1</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchGlass reads and controls the currently playing track in Music and Spotify.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NotchGlass shows your location on the Map and Weather tabs.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>NotchGlass shows your upcoming events on the Calendar tab.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>NotchGlass shows your upcoming events on the Calendar tab.</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"
echo "  Run with:  open $APP"
