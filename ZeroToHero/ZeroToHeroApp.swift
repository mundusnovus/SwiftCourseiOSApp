// Swift: Zero to Hero 2.0, by Asteria Technology. One multiplatform app: iPhone, iPad and Mac.
import SwiftUI
import SwiftData
import AppIntents
import ZeroToHeroKit

@main
struct ZeroToHeroApp: App {
    @State private var store: LearnerStore
    @State private var model: AppModel

    init() {
        _ = BrandFont.isRegistered
        let course = (try? Course.load()) ?? .fallback
        let store = LearnerStore.shared
        _store = State(initialValue: store)
        _model = State(initialValue: AppModel(course: course, store: store))
        ZeroToHeroShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    Demo.applyAppearance()
                    Demo.sizeWindow()
                    #endif
                    await SpotlightIndex.refresh()
                }
        }
        .modelContainer(store.container)
        #if os(macOS)
        .defaultSize(width: 1240, height: 800)
        .commands { LessonCommands(model: model) }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(store.container)
        }
        #endif
    }
}
