# Swift: Zero to Hero 2.0

A complete Swift course for iPhone, iPad and Mac, by Asteria Technology. One multiplatform app, 173 lessons in 10
chapters, no account, and no server of ours.

The course goes from the first line of Swift to a shipped app: values and types, collections, control flow, functions,
optionals, closures, structs, classes, enums, protocols, generics, errors, concurrency, Codable, SwiftUI, SwiftData,
networking, Apple Intelligence, Siri, iCloud, Liquid Glass, evaluations, sharing and release.

## What 2.0 changes

- **Serverless exercises.** On iPhone and iPad the learner's code is checked by an on-device engine in
  `ZeroToHeroKit`: a parser, a teaching-subset interpreter and the lesson's own tests. No endpoint, no install id, no
  network. The Mac still uses its own Swift compiler, and falls back to the same engine.
- **One multiplatform target.** iOS 27 and macOS 27, one scheme, one synchronized app folder, a library-only package
  with tests. The old SwiftPM executable and the sibling-package split are gone.
- **Template 2.0 design.** SF Pro for reading, Asteria Pixel for the word "Asteria" only, hierarchical SF Symbols,
  Liquid Glass chrome, one `NavigationSplitView` with a real compact path, Settings on both platforms.
- **iCloud.** SwiftData in the person's private CloudKit database: lessons, code, checklist ticks, streaks and badges.
  A local store is used when the entitlement is absent, and Settings says which one is in use.
- **Apple Intelligence.** A code coach that explains a compiler error without rewriting the code, lesson recaps,
  generated mini-lessons, and a weekly study plan. On device by default; Private Cloud Compute is wired but gated
  until Apple grants `com.apple.developer.private-cloud-compute`.
- **Siri, Spotlight, Handoff.** Lesson and achievement entities, Continue / Open Lesson / Progress intents, App
  Shortcuts, Spotlight indexing behind a switch, and Handoff between devices.
- **Milestones.** 24 badges with pure rules and a 1080×1350 share card for Messages and social.
- **Modern Apple chapter.** Foundation Models, Private Cloud Compute, App Intents, SwiftData + CloudKit, key-value
  storage, Liquid Glass, Evaluations, ShareLink and Live Activities: 12 new lessons.

## Build and test

```sh
tools/build.sh              # iOS Simulator + macOS unsigned + kit tests
tools/check.sh              # everything a machine can check
cd Packages/ZeroToHeroKit && swift test
tools/archive.sh ios        # archive + local App Store export (uploads nothing)
tools/archive.sh mac
tools/screenshots-ios.sh
```

Open `ZeroToHero.xcodeproj`, scheme **ZeroToHero**, destination My Mac or an iPhone simulator.

## Layout

| Path | What it is |
| --- | --- |
| `ZeroToHero/` | The app. A synchronized root group: a new file here is in the target |
| `ZeroToHero/ZeroToHeroApp.swift` | App, scenes, Settings on the Mac |
| `ZeroToHero/Theme.swift` | Palette, accents, Asteria Pixel, `.reading`, `.symbol`, `Wordmark`, `GlassCard` |
| `ZeroToHero/Records.swift` | SwiftData models, CloudKit container, local fallback, the one store, 1.0 import |
| `ZeroToHero/RootView.swift` | Split view, sidebar, course home |
| `ZeroToHero/LessonView.swift` | Reading, code, quiz, Xcode labs, console |
| `ZeroToHero/AchievementsView.swift` | Badges, detail, share card |
| `ZeroToHero/Intelligence.swift` | Foundation Models, guided generation, PCC gate, the three AI sheets |
| `ZeroToHero/Intents.swift` | Entities, intents, App Shortcuts, Spotlight |
| `ZeroToHero/Editor.swift` | Native code editor with line numbers and a symbol bar |
| `ZeroToHero/Resources/` | `course.json`, the font, `device-support.json` |
| `Packages/ZeroToHeroKit/` | Course model, exercise engine, achievements; Swift Testing |
| `Config/` | Info.plist, per-platform entitlements, ExportOptions |
| `tools/` | build, check, archive, screenshots, course builder |
| `AppStore/` | Listing, review notes, screenshots |
| `docs/PRODUCT.md` | The brief, decisions, the acceptance bar |

## The on-device engine

`ZeroToHeroKit` contains a lexer, parser and tree-walking interpreter for the teaching subset: values, strings,
collections, control flow, functions, closures, optionals, structs, enums, raw values and simple protocols of the
language the early and middle course uses. It runs the lesson's existing `expect(...)` checks in the same process and
captures `print` output.

The audit in `CoverageTests` checks every shipped solution and writes the list of lessons the engine can check today
(`ZeroToHero/Resources/device-support.json`). **61 of the 83 exercises are fully checked on device.** The rest open as
Xcode labs: the lesson, its tests and the starting code are shown, with an honest note that the full compiler needs a
Mac. That is a deliberate, visible limit, not a hidden failure. Extending the subset (extensions, tuples, Codable and async streams) is the next coverage work.

## Privacy

No account. No analytics. No Asteria server. Progress lives on the device and, when signed with the iCloud
entitlement, in the person's private CloudKit database. Apple Intelligence runs on device; Private Cloud Compute is off
in this build. The privacy manifest declares UserDefaults (`CA92.1`) and no tracking.

## Status

Verified: both platforms build in Debug and Release; `tools/archive.sh ios` and `tools/archive.sh mac` both produce a
real archive and a local App Store export (`Swift Zero to Hero.ipa` and `Swift Zero to Hero.pkg`), signed with an Apple
Distribution profile, production iCloud and `get-task-allow` false; the on-device engine passes 61 exercise solutions;
the app runs end to end on iPhone and iPad simulators; the Mac app launches signed; the kit has 12 tests.

Not verified: upload to App Store Connect (yours to do), iCloud sync between two signed devices, Siri phrases and
Spotlight results on hardware, Private Cloud Compute (entitlement not granted), VoiceOver and Dynamic Type on hardware.

## License

Asteria License 1.0. See `LICENSE`.
