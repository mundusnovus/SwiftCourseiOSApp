# Release 26.11.1 — Asteria 26 look

Version **26.11.1**, build **7**. Build 6 went to App Store Connect as 2.0.0, so 7 is the next free number.

## What changed

- **Asteria 26 palette.** Night `#05080F`, aqua `#00FFD3`, sea `#00C9A7`, deep aqua `#00826B`, heavy `#FF0058`, violet
  `#7A5CFF` and starlight cream `#E9FBF7`. The accent is deep aqua in light and aqua in dark, so tinted text keeps
  4.5:1. Text and symbols on an accent fill use `onAccent` (white in light, `#00140F` in dark).
- **Heavy for highlights.** Milestones, trophies, streaks and small labels use heavy (`#E0004E` / `#FF3D7F` as text).
- **Apple Intelligence gradient.** Aqua → violet → heavy on the Apple Intelligence symbols.
- **New accent choice.** "Asteria" (the default, stored as `sea` so saved choices carry over) and a new "Heavy".
- **New icon.** `ZeroToHero/AppIcon.icon`: aqua steps climbing from a cream zero to a heavy Asteria star, with dark,
  clear and tinted versions. `tools/make-icon.py` regenerates the layers; soft glows stay in the flat background
  layer. The `AppIcon.appiconset` PNGs and the Settings → About art are rendered from it with `ictool`.

## Before uploading

1. Archive with `tools/archive.sh` (iOS and Mac). `VERSION` and `MARKETING_VERSION` both say 26.11.1;
   `tools/check.sh` fails if they differ.
2. Retake the App Store screenshots with `tools/screenshots-ios.sh all` and `tools/screenshots-mac.sh`. The files in
   `AppStore/screenshots/` still show the 2.0.0 colours.
3. Upload build 7 for iOS and macOS, then test it in TestFlight with the "After upload" steps below.

---

The 2.0.0 (build 6) checklist follows for reference. Its App Store Connect, privacy and TestFlight steps still apply;
read its version and build numbers as 26.11.1 and 7.


# Release 2.0.0 — upload checklist

Everything below is for build **6**. The archives are on this Mac under `build/archive/` and are git-ignored; a fresh
clone does not contain them.

## Artifacts

| Platform | File | Signature |
| --- | --- | --- |
| iPhone / iPad | `build/archive/ios/export/Swift Zero to Hero.ipa` | Apple Distribution, production iCloud, `get-task-allow` false |
| Mac | `build/archive/mac/export/Swift Zero to Hero.pkg` | 3rd Party Mac Developer Installer, sandboxed, hardened runtime |

Version 2.0.0, build 6. Builds 3 and 4 were the 1.0.0 uploads; build 5 was an earlier 2.0 archive. Build 6 is the
upload. Never reuse a build number once it has been sent to App Store Connect.

Checksums for the exports on this Mac:

| File | Size | SHA-256 |
| --- | --- | --- |
| `Swift Zero to Hero.ipa` | 6.7 MB | `2be343fb623a7b82db762e1cb0af987fb2692058152f5e1e29cb4fbe28001e1a` |
| `Swift Zero to Hero.pkg` | 4.8 MB | `219feca0602307cacbb34689e43618cb1d23ea4f9ed76624222a2da470ee8669` |

## What is in build 6

- The on-device exercise engine, now with a coverage audit that checks the shipped support list.
- iCloud progress, including duplicate-record merging when two devices were offline.
- Apple Intelligence: code coach, review of working code, lesson recap, mini-lessons with a scratch editor, and the
  weekly study plan.
- The week card on Home, My Lessons in the sidebar, and the new-milestone share sheet.
- Accent colour and code size synced through iCloud key-value storage.
- Siri, Shortcuts, Spotlight, Handoff, and 24 shareable milestones.
- The 1080×1350 share card now exports at exactly that size.

## Verified in this package

- The archives are a Release build of the final 2.0.0 tree, version 2.0.0 build 6.
- `codesign --verify --deep --strict` passes for the archived app and the IPA.
- The IPA carries an Apple Distribution signature, the Production iCloud entitlement and `get-task-allow` false.
- The Mac pkg is signed by the 3rd Party Mac Developer Installer; its app is sandboxed with the hardened runtime and
  the Production iCloud entitlement.
- The privacy manifest declares UserDefaults (`CA92.1`), no tracking and no collected data.
- The CloudKit schema is deployed to Production. Production shows `CD_AchievementRecord`, `CD_CustomLessonRecord`,
  `CD_LessonRecord`, `CD_ProfileRecord` and `Users`, with their indexes.
- `Metadata.appintents` contains Continue, What's Next, My Progress, Open Lesson and Show My Milestones, the indexed
  `LessonEntity`, and all five App Shortcut phrase sets.
- The kit has 31 Swift Testing tests in 10 suites, including the course contract, the 61 runnable exercises and the
  study plan.
- The App Store screenshots were captured from this build at 1320×2868 (iPhone), 2064×2752 (iPad) and 2880×1800 (Mac).

The distribution-signed Mac app is installed by the App Store/TestFlight. Copying it out of the pkg and launching it
fails with launchd 163, which is expected; use the pkg or a TestFlight install to test that exact build.

## Before uploading

1. **App Store Connect record.** My Apps → Swift: Zero to Hero, bundle id `technology.asteria.zerotohero`. The Mac
   platform exists from 1.0.0. Add the **iOS platform** if it is not listed; the same record can carry both platforms.
2. **iCloud Production schema — done.** The Development schema was created by the signed Mac run of
   `-allowCloudKit -initCloudKitSchema`, then deployed with CloudKit Console → Schema → Deploy Schema Changes. Production
   now shows the four SwiftData record types and `Users`. If the schema changes again, repeat the deploy before upload.
   Container: `iCloud.technology.asteria.zerotohero`.
3. **Screenshots** are in `AppStore/screenshots/`: `6.9-1-home.png`, `6.9-2-exercise.png`, `6.9-3-milestones.png`
   (1320×2868), `ipad-1-home.png` (2064×2752) and `mac-2880.png` (2880×1800). The other images are older or
   promotional captures and are not the required upload set.
4. **App Privacy.** No tracking, no data collected by Asteria. Progress is the person's own data in their private
   iCloud database. Use `AppStore/review-notes.md` for the explanation.
5. **Export compliance.** `ITSAppUsesNonExemptEncryption = NO`; CloudKit uses Apple's exempt encryption.
6. **PCC.** `AsteriaPrivateCloudCompute` is false. Do not turn it on until Apple grants
   `com.apple.developer.private-cloud-compute` and the entitlement is in both files.
7. **Version check.** `VERSION`, `MARKETING_VERSION` and the archives must all say 2.0.0; the build must say 6.

## Upload

Use Xcode Organizer (Window → Organizer → Archives → Distribute App → App Store Connect → Upload) or drag the `.ipa`
and `.pkg` into Transporter. Do not use `tools/archive.sh` again after uploading without bumping the build number.

## After upload

1. Wait for processing, then add build 6 to TestFlight.
2. Test on a real iPhone, in this order:
   - Airplane mode: open "Hello, world", press Run. The on-device engine must pass with no network.
   - Turn the network on: progress appears in Settings as "Progress is in your iCloud" on both the iPhone and the Mac,
     signed into the same Apple Account.
   - Siri: "Continue my Swift course in Swift Zero to Hero" and "How far am I in Swift Zero to Hero".
   - Spotlight: search a lesson title; the result opens the lesson. On iOS only; the sandboxed Mac build has the
     known CoreSpotlight limitation.
   - Apple Intelligence on an eligible device: open a lesson, finish it, tap Review; ask for an extra lesson on a
     topic; open Plan My Week. Private Cloud Compute must still read as unavailable.
   - Earn a badge, open it, tap Share, send the card to Messages. Check the exported image is 1080×1350.
   - Open My Lessons, keep a generated lesson, and run its scratch editor.
   - Dynamic Type at AX5 and VoiceOver through Home and one lesson.
   - iPad: sidebar and lesson side by side; rotate.
3. Then submit for review with `AppStore/review-notes.md`.

## Known limitations in 2.0.0

- 61 of 83 exercises are checked on device. The other 22 open as Xcode labs (18 authored lessons, 3 labs, 1 project);
  four of those use Codable or async runtime features outside the teaching subset. Nothing is silently marked wrong.
- Spotlight indexed all 173 lessons on the iOS simulator. On the sandboxed Mac build, CoreSpotlight returns
  `CSIndexErrorDomain -1000` (4099); this matches
  [radar 37340318](https://github.com/PSPDFKit-labs/radar.apple.com/blob/master/37340318%20-%20CoreSpotlight%20Sandbox%20Failure%20macOS/README.md).
  iOS hardware is the final check.
- Two-device iCloud sync and Siri phrases are not verified in this session.
- Private Cloud Compute is off until Apple grants the entitlement.
- The app is English only.
