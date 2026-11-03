#!/bin/bash
# Mac screenshots from the Debug build's demo data. Needs Screen Recording permission for the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
tools/build.sh mac >/dev/null
APP="build/DerivedData/Build/Products/Debug/Swift Zero to Hero.app"
OUT=AppStore/screenshots/mac; mkdir -p "$OUT"
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true; sleep 1
open -n "$APP" --args -demo -seedprogress -screenshots
id=""; for _ in $(seq 1 20); do sleep 1; id=$(swift tools/windowid.swift "Swift Zero to Hero"); [ -n "$id" ] && break; done
[ -n "$id" ] || { echo "No window found. Is Screen Recording granted?" >&2; exit 1; }
sleep 2
screencapture -x -o -l"$id" "$OUT/1-home.png"
sips -c 1800 2880 "$OUT/1-home.png" >/dev/null
echo "$OUT/1-home.png"
pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
