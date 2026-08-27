#!/bin/bash
# Builds NotchGlass.app (via build-app.sh) and packages it into a distributable
# .dmg with a drag-to-Applications layout. Output: ./NotchGlass-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

# Build the .app bundle first (release config).
./build-app.sh release

APP="NotchGlass.app"
VOL="All in a notch"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="NotchGlass-${VERSION}.dmg"

echo "▸ Packaging ${DMG}…"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGING"
echo "✓ Built $DMG"
