// The app's shared state: the course, the one progress store, the selected lesson, and the runner.
import Foundation
import Observation
import SwiftUI
import ZeroToHeroKit

@Observable
@MainActor
final class AppModel {
    enum RunnerState {
        case looking
        case ready(String)
        case device(String)
        case unavailable(String)
    }

    let course: Course
    let store: LearnerStore
    var selection: Lesson.ID?
    var runnerState: RunnerState = .looking
    @ObservationIgnored var runner: CodeRunner?
    var notice: String?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showSettings = false
    var showAchievements = false
    var showStudy = false

    init(course: Course, store: LearnerStore = .shared) {
        self.course = course
        self.store = store
        self.selection = store.lastLesson
        #if DEBUG
        if let index = Demo.arguments.firstIndex(of: "-lesson"), Demo.arguments.indices.contains(index + 1) {
            selection = Demo.arguments[index + 1]
        }
        if Demo.arguments.contains("-achievements") { showAchievements = true }
        if Demo.arguments.contains("-settings") { showSettings = true }
        if Demo.arguments.contains("-study") { showStudy = true }
        #endif
    }

    var selectedLesson: Lesson? { selection.flatMap(course.lesson) }

    var nextLesson: Lesson? {
        course.next(after: selection) { store.isDone($0) }
    }

    var doneCount: Int { store.count(in: course.lessons) }

    var progress: Double {
        course.lessons.isEmpty ? 0 : Double(doneCount) / Double(course.lessons.count)
    }

    var currentChapter: Chapter? {
        selection.flatMap { course.module(of: $0)?.chapter }
    }

    func open(_ lesson: Lesson?) {
        selection = lesson?.id
        if let lesson {
            store.open(lesson.id)
            #if os(iOS)
            columnVisibility = .detailOnly
            #endif
        }
    }

    func go(by step: Int) {
        guard let current = selectedLesson else { open(nextLesson ?? course.lessons.first); return }
        let neighbours = course.neighbours(of: current.id)
        if let target = step < 0 ? neighbours.previous : neighbours.next { open(target) }
    }

    func say(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }

    // MARK: Runner

    func findRunner() async {
        #if os(macOS)
        #if os(macOS)
        if let toolchain = await Toolchain.find() {
            runner = LocalRunner(toolchain: toolchain)
            runnerState = .ready("Swift \(toolchain.version) on this Mac. Your code never leaves it.")
            return
        }
        #endif
        runner = OnDeviceRunner()
        runnerState = .device("Checking on this device with the built-in engine. Install Xcode for the full compiler.")
        #else
        runner = OnDeviceRunner()
        runnerState = .device("Checked on this device. No internet needed.")
        #endif
    }

    func check(_ lesson: Lesson, code: String) async -> RunResult {
        if let runner {
            do { return try await runner.check(lesson, code: code) }
            catch {
                // A sandboxed Mac can refuse to start the compiler. The on-device engine still works for the subset.
                #if os(macOS)
                if runner is LocalRunner {
                    let fallback = OnDeviceRunner()
                    if let result = try? await fallback.check(lesson, code: code), !result.unsupported { return result }
                }
                #endif
                return RunResult(compiled: false, errors: [.init(line: nil, message: error.localizedDescription)],
                                 tests: lesson.tests.map { .init(text: $0.text, passed: false) })
            }
        }
        await findRunner()
        return await check(lesson, code: code)
    }
}

#if DEBUG
/// Launch options for screenshots and for looking at a screen quickly.
enum Demo {
    static let arguments = ProcessInfo.processInfo.arguments
    static let isOn = arguments.contains("-demo")
    static let appearance = arguments.firstIndex(of: "-appearance").flatMap { index in
        arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }

    static func applyAppearance() {
        #if os(macOS)
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    static func sizeWindow() {
        #if os(macOS)
        guard arguments.contains("-screenshots") || arguments.contains("-demo") else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            window.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
            NSApp.activate()
        }
        #endif
    }
}
#endif
