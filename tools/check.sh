#!/bin/bash
# Everything a machine can check before a release. It fails loudly; a warning means look, an error means stop.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }

echo "1. Plists"
plutil -lint Config/Info.plist Config/ZeroToHero-iOS.entitlements Config/ZeroToHero-macOS.entitlements Config/ExportOptions.plist >/dev/null
plutil -lint ZeroToHero/PrivacyInfo.xcprivacy >/dev/null

echo "2. Project"
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = technology.asteria.zerotohero;' ZeroToHero.xcodeproj/project.pbxproj || fail "bundle id"
[ "$(grep -c 'PRODUCT_BUNDLE_IDENTIFIER = technology.asteria.zerotohero;' ZeroToHero.xcodeproj/project.pbxproj)" -eq 2 ] || fail "bundle id must appear in Debug and Release"
grep -q 'SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";' ZeroToHero.xcodeproj/project.pbxproj || fail "multiplatform"
grep -q 'SUPPORTS_MACCATALYST = NO;' ZeroToHero.xcodeproj/project.pbxproj || fail "no catalyst"
grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 27.0;' ZeroToHero.xcodeproj/project.pbxproj || fail "iOS 27"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 27.0;' ZeroToHero.xcodeproj/project.pbxproj || fail "macOS 27"
[ -d Packages/ZeroToHeroKit ] || fail "kit package missing"
! grep -Rq 'executableTarget' Packages/ZeroToHeroKit/Package.swift || fail "no executable target next to the app"

echo "3. Serverless"
! grep -Rq 'learn\.asteria\.technology' ZeroToHero Packages || fail "a server endpoint is still referenced"
! grep -Rq 'RemoteRunner' ZeroToHero Packages || fail "RemoteRunner still exists"
[ ! -f ZeroToHero/Resources/solutions.json ] || fail "solutions must not ship in the app"

echo "4. Privacy"
grep -q 'CA92.1' ZeroToHero/PrivacyInfo.xcprivacy || fail "UserDefaults reason CA92.1"
grep -q 'NSPrivacyTracking' ZeroToHero/PrivacyInfo.xcprivacy || fail "tracking declaration"

echo "5. Course"
python3 - <<'PY'
import json, sys
c = json.load(open("Resources/course.json"))
ids = [l["id"] for ch in c["chapters"] for m in ch["modules"] for l in m["lessons"]]
assert len(ids) == len(set(ids)), "duplicate lesson ids"
for ch in c["chapters"]:
    for m in ch["modules"]:
        for l in m["lessons"]:
            assert l["title"].strip(), l["id"]
            assert l["description"], l["id"]
            if l["questions"]:
                assert any(a["correct"] for q in l["questions"] for a in q["answers"]), l["id"]
print(f"   {len(c['chapters'])} chapters, {len(ids)} lessons, {sum(1 for l in c['lessons'] if l['tests']) if False else sum(1 for ch in c['chapters'] for m in ch['modules'] for l in m['lessons'] if l['tests'])} exercises")
PY
[ -f ZeroToHero/Resources/course.json ] || fail "course not in the app"
cmp -s Resources/course.json ZeroToHero/Resources/course.json || fail "app course differs from the reviewed course"

echo "6. Tests and builds"
(cd Packages/ZeroToHeroKit && swift test 2>&1 | tail -4)
xcodebuild -project ZeroToHero.xcodeproj -scheme ZeroToHero -sdk iphonesimulator -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build 2>&1 | tail -2
xcodebuild -project ZeroToHero.xcodeproj -scheme ZeroToHero -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tail -2

echo "7. Schemes"
xcodebuild -list -project ZeroToHero.xcodeproj 2>/dev/null | awk '/Schemes:/{flag=1;next} flag && NF{print}' | while read -r scheme; do
    [ "$scheme" = "ZeroToHero" ] || warn "extra scheme: $scheme (archive with ZeroToHero)"
done

echo "OK. Not checked here: signing, device install, iCloud sync, Siri phrases, PCC."
