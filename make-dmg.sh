#!/bin/bash
# Builds the app and packs it into VehicleMotionCues.dmg (the app plus an Applications shortcut).
#
#   SIGN_IDENTITY   Developer ID Application identity. Signs the app and the disk image.
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                   App Store Connect API key file, key ID and issuer ID. When all three are
#                   set (with SIGN_IDENTITY), the disk image is notarized and stapled, so it
#                   opens on other Macs without a Gatekeeper warning.
set -e
cd "$(dirname "$0")"
APP="Vehicle Motion Cues.app"
DMG="VehicleMotionCues.dmg"

./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Vehicle Motion Cues" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
  if [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$DMG"
    echo "Notarized and stapled."
  else
    echo "Signed but not notarized (set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER to notarize)."
  fi
fi
echo "Wrote $DMG"
