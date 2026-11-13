#!/bin/bash
# Builds "Vehicle Motion Cues.app" next to this script. Needs the Xcode command line tools.
set -e
cd "$(dirname "$0")"
APP="Vehicle Motion Cues.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O main.swift -o "$APP/Contents/MacOS/VehicleMotionCues"
codesign --force -s - "$APP"
echo "Built $APP. Open it with: open \"$APP\""
