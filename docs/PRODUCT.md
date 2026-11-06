# Swift: Zero to Hero 2.0 — product

## 27.2 (8) (6 November 2026)

- Versions are named after the iOS release (27.2 now; the Siri AI update will be 27.3 (1)).
- **Asteria Intelligence** replaces the on-device model and Private Cloud Compute (decision C below is retired):
  code coach, review, recap, mini-lessons and the study plan run on it (`ZeroToHero/Intelligence`, synced from
  AsteriaSearch by `tools/sync-intelligence.sh`). The one-time permission sheet comes first; Settings has the switch.
- **Ask Asteria** (the Asteria Intelligence menu; `ZTHChats.swift`): the shared Asteria chat, which knows the open
  lesson. Chats sync with every Asteria app when signed in.
- **Asteria Account** in Settings: normal username, tokens, The Asteria Subscription's tiers, sign out, delete.
  Keychain group `KZFR2T5L2A.technology.asteria.account` in both entitlements.
- The SwiftPM Mac app (SwiftCourseApp) has the same, with Asteria in its own window; it now needs macOS 27.
- Verified: builds for iPhone and Mac with no warnings. Not verified: the real model, devices.

## The brief

Version 2.0 of Swift: Zero to Hero for Mac and iOS, from the owner's seven points:

1. Serverless checking on device for iOS and macOS, with Apple's services where they help.
2. iCloud and Apple's server compute (Private Cloud Compute).
3. Siri and Apple Intelligence for iOS 27 and macOS 27; a version 27 exclusive app.
4. Template 2.0 visual language, simple navigation.
5. Milestones and achievements, shareable through Messages and social.
6. Improve the lessons and fill the gaps.
7. Use Apple's sample code to make the lessons genuinely modern, from zero to hero.

## Decisions

- **A. One repo, one multiplatform target, one scheme.** The app, the synchronized folder and the library-only
  `ZeroToHeroKit` package live together. The old sibling package and SwiftPM executable are retired. Reason: the
  earlier archive failure came from a package scheme and an executable next to the app.
- **B. This repo owns the 2.0 course.** `Resources/course.json` is the reviewed source. MNLearn imports it later. The
  `Modern Apple` chapter is built by `tools/add-modern-apple.py`.
- **C. Private Cloud Compute is wired but gated.** `PrivateCloudComputeLanguageModel` is behind the Info.plist key,
  the entitlement and a setting. Until Apple grants the entitlement, every feature is on device.

## What 2.0 is

- iOS 27 and macOS 27, Swift 6, one target, `SDKROOT = auto`, no Catalyst.
- Template 2.0 type, colour, symbols and glass. SF Pro for reading; Asteria Pixel only for "Asteria".
- Home, sidebar, lesson, code workspace, quiz, milestones, settings. One compact path on iPhone.
- Serverless exercise engine: parser + interpreter + the lesson's tests. Mac compiler when available, same engine as
  the fallback.
- SwiftData + CloudKit private database for progress, code, ticks, streaks and badges. Local fallback, 1.0 import.
- Apple Intelligence: code coach, code review, recap, mini-lesson with a scratch editor, and a weekly study plan built
  from progress. On device; PCC gated.
- App Intents, App Shortcuts, Spotlight, Handoff.
- 24 achievements, pure rules, 1080×1350 share card, and a new-milestone celebration.
- 173 lessons, 10 chapters, 83 exercises, 82 quizzes. 61 exercises checked on device; the other 22 are explicit Xcode
  labs with the tests and starting code shown.

## The acceptance bar

- Both platforms build with no errors.
- `tools/check.sh` passes, including 31 Swift Testing tests in 10 suites.
- A lesson runs end to end on an iPhone simulator with no network.
- The Mac app launches and opens a lesson.
- No endpoint, install id or `RemoteRunner` remains.
- The app bundle contains the course, the font and the device-support list, not the solutions.
- Every lesson has a title and description; every quiz has one correct answer; ids are unique.
- Settings tells the truth about iCloud and Apple Intelligence.
- The shipped `device-support.json` matches the coverage audit; no correct answer is silently marked wrong.

At the bar: both platforms archive and export locally with an Apple Distribution profile, production iCloud and
`get-task-allow` false; the iPhone 6.9-inch, iPad 13-inch and Mac screenshots are at the required sizes; the listing
and review notes are written.

iCloud is verified on one signed Development Mac build: the container opened, mirroring wrote records, and Settings says
"Progress is in your iCloud". The Development schema is also deployed to Production; both environments show the four
SwiftData record types and `Users`. The distribution pkg carries the Production entitlement and is installed via the App
Store/TestFlight; it is not expected to launch from a copied payload. Apple Intelligence is verified on the same Mac.
Two-device sync and Siri/Spotlight on hardware are still outstanding.

Not yet at the bar: a signed install on a physical device, iCloud sync between two devices, Siri phrases and Spotlight
results on hardware, PCC (entitlement), upload to App Store Connect, VoiceOver and Dynamic Type on hardware. These are
listed in every report until they are done.

## Out of scope for 2.0.0

- A web version. The course data remains exportable to MNLearn.
- Accounts, leaderboards, or any Asteria server.
- Executing Swift on iPhone through a bundled compiler. Apple does this in Swift Playgrounds with a toolchain it
  builds; it is not a public API, and the App Store rules make it a poor bet.
- Private Cloud Compute until Apple grants the managed entitlement.

## Next

1. Raise device coverage from 61 to the last 22: extensions, tuples, Codable, async streams and the enum/associated-value cases.
2. Test iCloud on two signed devices. The Development schema is created and deployed to Production; verify the records
   arrive on both devices.
3. Speak every App Shortcut phrase on a device; check Spotlight results. Spotlight indexed all 173 lessons on the iOS
   simulator. CoreSpotlight donation fails in the sandboxed Mac build with `CSIndexErrorDomain -1000` / 4099, matching
   radar 37340318; iOS hardware is the final check.
4. VoiceOver, Dynamic Type, contrast, Reduce Motion on hardware.
5. Archive both platforms, export locally, capture the required screenshot sizes, write the listing, submit.
6. Request the PCC entitlement; only then turn the Info.plist key on.
