# Release 2.0.0 — upload checklist

Everything below is for build **5**. The archives are on this Mac under `build/archive/` and are git-ignored; a fresh
clone does not contain them.

## Artifacts

| Platform | File | Signature |
| --- | --- | --- |
| iPhone / iPad | `build/archive/ios/export/Swift Zero to Hero.ipa` | Apple Distribution, production iCloud, `get-task-allow` false |
| Mac | `build/archive/mac/export/Swift Zero to Hero.pkg` | 3rd Party Mac Developer Installer, sandboxed, hardened runtime |

Version 2.0.0, build 5. The 1.0.0 uploads used builds 3 and 4, so 5 is valid.

Verified in this package: `codesign --verify --deep --strict` passes for the archived app and the IPA; the Mac pkg is
signed by the 3rd Party Mac Developer Installer; the privacy manifest declares UserDefaults (`CA92.1`), no tracking and
no collected data; `Metadata.appintents` contains Continue, What's Next, My Progress and Open Lesson, the indexed
`LessonEntity`, and all four App Shortcut phrase sets.

## Before uploading

1. **App Store Connect record.** My Apps → Swift: Zero to Hero, bundle id `technology.asteria.zerotohero`. The Mac
   platform exists from 1.0.0. Add the **iOS platform** if it is not listed; the same record can carry both platforms.
2. **iCloud Production schema — do this before release, not after.** The Development schema was created by the signed
   Mac run of `-allowCloudKit -initCloudKitSchema`. In CloudKit Console → container
   `iCloud.technology.asteria.zerotohero` → Schema → Deploy Development to Production. Until this is done, the App Store
   build opens iCloud but has no record types to sync.
3. **Screenshots** are in `AppStore/screenshots/`: 1320×2868 iPhone, 2064×2752 iPad, 2880×1800 Mac.
4. **App Privacy.** No tracking, no data collected by Asteria. Progress is the person's own data in their private
   iCloud database. Use `AppStore/review-notes.md` for the explanation.
5. **Export compliance.** `ITSAppUsesNonExemptEncryption = NO`; CloudKit uses Apple's exempt encryption.
6. **PCC.** `AsteriaPrivateCloudCompute` is false. Do not turn it on until Apple grants
   `com.apple.developer.private-cloud-compute` and the entitlement is in both files.

## Upload

Use Xcode Organizer (Window → Organizer → Archives → Distribute App → App Store Connect → Upload) or drag the `.ipa`
and `.pkg` into Transporter. Do not use `tools/archive.sh` again after uploading without bumping the build number.

## After upload

1. Wait for processing, then add build 5 to TestFlight.
2. Test on a real iPhone, in this order:
   - Airplane mode: open "Hello, world", press Run. The on-device engine must pass with no network.
   - Turn the network on: progress appears in Settings as "Progress is in your iCloud" on both the iPhone and the Mac,
     signed into the same Apple Account.
   - Siri: "Continue my Swift course in Swift Zero to Hero" and "How far am I in Swift Zero to Hero".
   - Spotlight: search a lesson title; the result opens the lesson. On iOS only; the sandboxed Mac build has the
     known CoreSpotlight limitation.
   - Apple Intelligence on an eligible device: open a lesson, finish it, tap Review; ask for an extra lesson on a
     topic. Private Cloud Compute must still read as unavailable.
   - Earn a badge, open it, tap Share, send the card to Messages.
   - Dynamic Type at AX5 and VoiceOver through Home and one lesson.
   - iPad: sidebar and lesson side by side; rotate.
3. Then submit for review with `AppStore/review-notes.md`.

## Known limitations in 2.0.0

- 61 of 83 exercises are checked on device; 18 are explicit Xcode labs. Nothing is silently marked wrong.
- Spotlight indexed all 173 lessons on the iOS simulator. On the sandboxed Mac build, CoreSpotlight returns
  `CSIndexErrorDomain -1000` (4099); this matches
  [radar 37340318](https://github.com/PSPDFKit-labs/radar.apple.com/blob/master/37340318%20-%20CoreSpotlight%20Sandbox%20Failure%20macOS/README.md).
  iOS hardware is the final check.
- Two-device iCloud sync and Siri phrases are not verified in this session.
- Private Cloud Compute is off until Apple grants the entitlement.
- The app is English only.
