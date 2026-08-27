#!/bin/bash
# Builds NotchGlass.app, re-signs it with a Developer ID + hardened runtime,
# notarizes it, staples the ticket, and packages a notarized, drag-to-Applications
# .dmg. Output: ./NotchGlass-<version>.dmg
#
# Requires (one-time):
#   - A "Developer ID Application" certificate in the keychain.
#   - A stored notarytool credential profile named by $NOTARY_PROFILE, e.g.:
#       xcrun notarytool store-credentials "notch-notary" \
#         --apple-id "you@example.com" --team-id "JLR4F273N8" --password "app-specific-pw"
#     (or --key/--key-id/--issuer for an App Store Connect API key)
#
# Set SKIP_NOTARIZE=1 to sign + package only (e.g. for a quick local build).
set -euo pipefail

cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notch-notary}"
ENTITLEMENTS="NotchGlass.entitlements"
APP="NotchGlass.app"
VOL="All in a notch"

# Build the .app bundle first (release config; ad-hoc signed inside build-app.sh).
./build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="NotchGlass-${VERSION}.dmg"

echo "▸ Signing with Developer ID (hardened runtime)…"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "▸ Notarizing app (this can take a few minutes)…"
    ZIP="NotchGlass-${VERSION}-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo "▸ Stapling app…"
    xcrun stapler staple "$APP"
fi

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

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "▸ Signing + notarizing the DMG…"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "▸ Verifying Gatekeeper acceptance…"
    spctl -a -t open --context context:primary-signature -vv "$DMG" || true
fi

echo "✓ Built $DMG"
