#!/bin/bash
# Builds "Vehicle Motion Cues.app" next to this script. Needs the Xcode command line tools.
#
# By default the app is signed ad hoc, which is fine for running it on your own Mac.
# To sign for distribution, set SIGN_IDENTITY to a Developer ID Application identity:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
set -e
cd "$(dirname "$0")"
APP="Vehicle Motion Cues.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/VehicleMotionCues"

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "Built $APP"
