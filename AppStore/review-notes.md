# App Review notes — Swift: Zero to Hero 2.0

## What the app is

A Swift course for iPhone, iPad and Mac: 173 lessons, 83 exercises, 82 quizzes, from the language to shipping an app.
No account is required.

## No server, no account

Exercises on iPhone and iPad are checked by an engine inside the app. There is no Asteria endpoint, no install id and
no network call for checking code. The Mac uses its own Swift compiler. Progress is stored with SwiftData; when the
build is signed with the iCloud entitlement it syncs to the person's private CloudKit database.

## Apple Intelligence

The code coach, lesson recap and mini-lessons use the on-device Foundation Models framework. The app checks
`SystemLanguageModel.default.availability` and explains when Apple Intelligence is unavailable. Private Cloud Compute
is compiled but disabled: `AsteriaPrivateCloudCompute` is false in Info.plist and the managed entitlement is not in
this build. No model output is sent to Asteria.

## Siri and Spotlight

The app declares App Intents and App Shortcuts (Continue, What's Next, My Progress, Open Lesson). Spotlight indexing
is on by default and can be turned off in Settings → Apple Intelligence → "Share lessons with Siri and Spotlight".
Handoff carries the open lesson between devices.

## Subscriptions, purchases, ads

None. The app is a one-time purchase; there is no StoreKit code.

## Data

No analytics, no tracking, no advertising identifier. The privacy manifest declares UserDefaults (`CA92.1`) and no
tracked data. Progress and code are the person's own, in their private iCloud if available.

## How to test

1. Launch. The course home shows 173 lessons and 10 chapters.
2. Open "Hello, world" (Start here). Press Run. The on-device engine prints both lines and the tests pass.
3. Open "Initializers" (Modelling with types). It is an Xcode lab: the tests and starting code are shown.
4. Open Milestones from the toolbar. Earned badges are gold; locked ones show a lock. Open an earned badge and tap
   Share to see the card.
5. Settings: appearance, editor size, iCloud status, Apple Intelligence status, progress reset.
6. On a Mac, open any lesson; the app uses the Mac's Swift compiler when Xcode or the Command Line Tools are present.
7. Siri: "Continue my Swift course in Swift Zero to Hero" (the exact app name). On a device, also try "How far am I in
   Swift Zero to Hero".

## Known limits in this build

- 61 of 83 exercises are checked fully on device; the rest are explicit Xcode labs. Nothing is silently marked wrong.
- Private Cloud Compute is off until Apple grants the entitlement.
- iCloud is verified on one signed Mac; two-device sync is not verified in this build.
- Apple Intelligence is verified on the Mac; Siri phrases and Spotlight results still need a physical device check.

## Contact

Asteria Technology, team KZFR2T5L2A. Support: https://asteria.technology/support/
