#!/bin/bash
# Builds Swift: Zero to Hero for both platforms without signing.
#
#   tools/build.sh          both platforms and the kit tests
#   tools/build.sh ios      iOS Simulator only
#   tools/build.sh mac      macOS only
set -euo pipefail
cd "$(dirname "$0")/.."

build_ios() {
    echo "Building iOS Simulator…"
    xcodebuild -project ZeroToHero.xcodeproj -scheme ZeroToHero -sdk iphonesimulator \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData build | tail -3
}

build_mac() {
    echo "Building macOS (unsigned)…"
    xcodebuild -project ZeroToHero.xcodeproj -scheme ZeroToHero -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath build/DerivedData \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | tail -3
}

case "${1:-all}" in
    ios) build_ios ;;
    mac) build_mac ;;
    all)
        build_ios
        build_mac
        echo "Testing ZeroToHeroKit…"
        (cd Packages/ZeroToHeroKit && swift test 2>&1 | tail -3)
        ;;
    *) echo "usage: tools/build.sh [ios|mac|all]"; exit 2 ;;
esac
