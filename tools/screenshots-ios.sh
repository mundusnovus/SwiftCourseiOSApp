#!/bin/bash
# App Store iPhone and iPad screenshots from the Debug build's demo data.
#
#   tools/screenshots-ios.sh            # iPhone 6.9-inch set
#   tools/screenshots-ios.sh iphone     # same
#   tools/screenshots-ios.sh ipad       # iPad 13-inch home
#   tools/screenshots-ios.sh all        # both
#   tools/screenshots-ios.sh iphone <udid>   # choose a simulator explicitly
#
# The default devices are picked by name so the output matches App Store Connect's required sizes. If your
# simulators use different names, pass a UDID as the second argument.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-iphone}"
CUSTOM_DEVICE="${2:-}"
OUT=AppStore/screenshots
mkdir -p "$OUT"

choose_device() {
    local kind="$1"
    xcrun simctl list devices available -j | python3 -c '
import json, sys
kind = sys.argv[1]
data = json.load(sys.stdin)
devices = [d for runtime in data["devices"].values() for d in runtime if d.get("isAvailable", True)]
preferred = ["iPhone 18 Pro Max", "iPhone 17 Pro Max", "iPhone 16 Pro Max"] if kind == "iphone" else \
            ["iPad Pro 13-inch (M5)", "iPad Pro 13-inch", "iPad Pro 12.9-inch (6th generation)"]
by_name = {d["name"]: d["udid"] for d in devices}
for name in preferred:
    if name in by_name:
        print(by_name[name]); raise SystemExit
for d in devices:
    if kind == "iphone" and d["name"].startswith("iPhone"):
        print(d["udid"]); raise SystemExit
    if kind == "ipad" and d["name"].startswith("iPad"):
        print(d["udid"]); raise SystemExit
raise SystemExit("No " + kind + " simulator found")
' "$kind"
}

build_once() {
    tools/build.sh ios >/dev/null
}

install_on() {
    local device="$1"
    local app="build/DerivedData/Build/Products/Debug-iphonesimulator/Swift Zero to Hero.app"
    xcrun simctl boot "$device" 2>/dev/null || true
    xcrun simctl bootstatus "$device" -b >/dev/null
    xcrun simctl terminate "$device" technology.asteria.zerotohero 2>/dev/null || true
    xcrun simctl install "$device" "$app"
}

set_status_bar() {
    local device="$1"
    xcrun simctl status_bar "$device" override \
        --time "9:41" --batteryState charged --batteryLevel 100 \
        --wifiBars 3 --cellularBars 4 --operatorName "" >/dev/null 2>&1 || true
}

shot() { # device, name, args…
    local device="$1" name="$2"
    shift 2
    xcrun simctl terminate "$device" technology.asteria.zerotohero 2>/dev/null || true
    xcrun simctl launch "$device" technology.asteria.zerotohero "$@" >/dev/null
    sleep 5
    rm -f "$OUT/$name"
    xcrun simctl io "$device" screenshot "$OUT/$name" >/dev/null 2>&1
    echo "$OUT/$name"
}

check_size() { # file, expected
    local file="$1" expected="$2" actual
    actual="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{print w"x"$2}')"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $file is $actual; App Store Connect wants $expected. Pick the matching simulator." >&2
        return 1
    fi
}

capture_iphone() {
    local device="${CUSTOM_DEVICE:-$(choose_device iphone)}"
    local solution
    solution="$(mktemp -t hello-solution)"
    printf 'print("Hello, world!")\nprint("I am learning Swift.")\n' > "$solution"

    install_on "$device"
    set_status_bar "$device"
    shot "$device" 6.9-1-home.png -demo -seedprogress
    shot "$device" 6.9-2-exercise.png -demo -seedprogress -lesson start-hello -run -codefile "$solution" -nobadges
    shot "$device" 6.9-3-milestones.png -demo -seedprogress -achievements
    rm -f "$solution"
    check_size "$OUT/6.9-1-home.png" "1320x2868"
    check_size "$OUT/6.9-2-exercise.png" "1320x2868"
    check_size "$OUT/6.9-3-milestones.png" "1320x2868"
}

capture_ipad() {
    local device="${CUSTOM_DEVICE:-$(choose_device ipad)}"
    install_on "$device"
    set_status_bar "$device"
    shot "$device" ipad-1-home.png -demo -seedprogress
    check_size "$OUT/ipad-1-home.png" "2064x2752"
}

case "$MODE" in
    iphone) build_once; capture_iphone ;;
    ipad) build_once; capture_ipad ;;
    all)
        build_once
        capture_iphone
        capture_ipad
        ;;
    *)
        echo "usage: tools/screenshots-ios.sh [iphone|ipad|all] [udid]" >&2
        exit 2
        ;;
esac
