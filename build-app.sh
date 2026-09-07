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

# App icon
mkdir -p "$APP/Contents/Resources"
cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the ambient audio into Contents/Resources/ambience so it loads via
# `Bundle.main` inside the .app (see AmbientPlayer.loadSeamlessLoop). We do NOT ship
# SwiftPM's `NotchGlass_NotchGlass.bundle` / rely on `Bundle.module`: its generated
# accessor looks next to the binary and hard-fails inside an .app, which crashed the
# app on any machine without the dev build tree.
AMBIENCE_SRC="Sources/NotchGlass/Resources/ambience"
if [ -d "$AMBIENCE_SRC" ]; then
    mkdir -p "$APP/Contents/Resources/ambience"
    cp -R "$AMBIENCE_SRC/." "$APP/Contents/Resources/ambience/"
else
    echo "⚠︎ ambience resources not found at $AMBIENCE_SRC" >&2
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
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.26.09.1</string>
    <key>CFBundleVersion</key>         <string>14</string>
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
    <key>NSContactsUsageDescription</key>
    <string>NotchGlass shows contact names instead of raw phone numbers on the Messages tab.</string>
    <!-- The Chat tab can talk to a local AI server (e.g. LM Studio at
         http://localhost:1234). App Transport Security blocks plain HTTP by
         default; this exception permits loopback/`.local` connections only. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Sign with a *stable* identity (Developer ID) rather than ad-hoc `-`. Ad-hoc gives the
# app a new code identity every build, so macOS treats each rebuild as a new app and
# re-prompts for Screen Recording / other TCC permissions. A stable signature keeps the
# grant across rebuilds. Falls back to ad-hoc if the identity isn't present.
SIGN_ID="Developer ID Application: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "▸ Code signing (stable identity)…"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "▸ Ad-hoc code signing (stable identity not found)…"
    codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"
echo "  Run with:  open $APP"
