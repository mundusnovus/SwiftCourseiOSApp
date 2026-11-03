#!/bin/bash
# iPhone screenshots from the Debug build's demo data. Usage: tools/screenshots-ios.sh [device-udid]
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-5431383D-0E89-4EA0-A522-DDE958804D06}"
OUT=AppStore/screenshots/ios; mkdir -p "$OUT"
tools/build.sh ios >/dev/null
APP="build/DerivedData/Build/Products/Debug-iphonesimulator/Swift Zero to Hero.app"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" technology.asteria.zerotohero 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

shot() { # name, args…
    local name="$1"; shift
    xcrun simctl terminate "$DEVICE" technology.asteria.zerotohero 2>/dev/null || true
    xcrun simctl launch "$DEVICE" technology.asteria.zerotohero "$@" >/dev/null
    sleep 4
    xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1
    echo "$OUT/$name.png"
}

shot 1-home -demo -seedprogress
shot 2-lesson -demo -seedprogress -lesson start-hello
shot 3-exercise -demo -seedprogress -lesson start-hello -run -codefile /tmp/hello-solution.swift
shot 4-modern -demo -seedprogress -lesson modern-fm-session
shot 5-milestones -demo -seedprogress -achievements
