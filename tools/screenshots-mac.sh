#!/bin/bash
# Mac screenshots from the Debug build's demo data. Needs Screen Recording permission for the terminal.
# The window is 1440 by 900 points; on a Retina Mac the capture is 2880 by 1800, the size App Store Connect wants.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project ZeroToHero.xcodeproj -scheme ZeroToHero -configuration Debug \
    -destination "platform=macOS" -derivedDataPath build/DerivedData-MacSigned build >/dev/null
APP="build/DerivedData-MacSigned/Build/Products/Debug/Swift Zero to Hero.app"
OUT=AppStore/screenshots
mkdir -p "$OUT"
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true; sleep 1
open -n "$APP" --args -demo -seedprogress -screenshots
id=""; for _ in $(seq 1 20); do sleep 1; id=$(swift tools/windowid.swift "Zero to Hero"); [ -n "$id" ] && break; done
[ -n "$id" ] || { echo "No window found. Is Screen Recording granted?" >&2; exit 1; }
# Keystroke focus went to the terminal while we looked up the window id. Bring the app back so the controls are live,
# not dimmed, in the capture.
open -a "$APP" 2>/dev/null || true
sleep 2
screencapture -x -o -l"$id" "$OUT/mac-2880.png"
echo "$OUT/mac-2880.png"
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
