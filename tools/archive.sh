#!/bin/bash
# Archives and exports the app without uploading anything.
#
#   tools/archive.sh ios     iOS archive + local App Store export
#   tools/archive.sh mac     macOS archive + local App Store export
#
# Needs the Asteria team signed in to Xcode. If automatic signing cannot make a profile, the script stops and says so.
# The archive check is the one that matters: a real app archive has ApplicationProperties:ApplicationPath. A generic
# archive does not, and App Store Connect will not take it.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:-ios}"
case "$TARGET" in
    ios) DEST='generic/platform=iOS' ;;
    mac) DEST='generic/platform=macOS' ;;
    *) echo "usage: tools/archive.sh [ios|mac]"; exit 2 ;;
esac

OUT="build/archive/$TARGET"
ARCHIVE="$OUT/SwiftZeroToHero.xcarchive"
EXPORT="$OUT/export"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "Archiving $TARGET…"
xcodebuild archive \
    -project ZeroToHero.xcodeproj -scheme ZeroToHero -configuration Release \
    -destination "$DEST" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates | tail -4

/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist" >/dev/null \
    || { echo "FAIL: the archive has no ApplicationProperties. It is a generic archive; check the scheme and signing."; exit 1; }
echo "Archive looks real: $(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist")"

echo "Exporting for the App Store locally (no upload)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist Config/ExportOptions.plist -exportPath "$EXPORT" \
    -allowProvisioningUpdates | tail -4

echo "Exported to $EXPORT. Nothing was uploaded."
