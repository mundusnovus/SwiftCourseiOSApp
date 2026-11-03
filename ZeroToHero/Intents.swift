// Siri, Shortcuts and Spotlight. The entities and intents read the same store the window shows, on the main actor.
import AppIntents
import CoreSpotlight
import Foundation
import ZeroToHeroKit

/// The window registers how to open a lesson. Intents call this on the main actor instead of owning a second model.
@MainActor
enum AppRouter {
    static var open: ((String?) -> Void)?
}

struct LessonEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lesson", numericFormat: "\(placeholder: .int) lessons")
    static let defaultQuery = LessonQuery()

    let id: String
    let title: String
    let chapter: String
    let minutes: Int
    let done: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(chapter) · \(minutes) min", image: .init(systemName: "book"))
    }

    @ComputedProperty(indexingKey: \.contentDescription)
    var searchDescription: String { "\(chapter). \(title). \(done ? "Done" : "Not done yet")." }

    init(_ lesson: Lesson, chapter: String, done: Bool) {
        self.id = lesson.id
        self.title = lesson.title
        self.chapter = chapter
        self.minutes = lesson.minutes
        self.done = done
    }
}

struct LessonQuery: EntityStringQuery {
    func entities(for identifiers: [LessonEntity.ID]) async throws -> [LessonEntity] {
        await MainActor.run {
            guard let course = try? Course.load() else { return [] }
            return identifiers.compactMap { id in entity(id, course: course) }
        }
    }

    func entities(matching string: String) async throws -> [LessonEntity] {
        await MainActor.run {
            guard let course = try? Course.load() else { return [] }
            return course.lessons
                .filter { $0.title.localizedStandardContains(string) || $0.id.contains(string.lowercased()) }
                .prefix(20)
                .compactMap { entity($0.id, course: course) }
        }
    }

    func suggestedEntities() async throws -> [LessonEntity] {
        await MainActor.run {
            guard let course = try? Course.load() else { return [] }
            let store = LearnerStore.shared
            if let next = course.next(after: store.lastLesson, done: { store.isDone($0) }) {
                return [entity(next.id, course: course)].compactMap { $0 }
            }
            return course.lessons.prefix(5).compactMap { entity($0.id, course: course) }
        }
    }

    @MainActor
    private func entity(_ id: String, course: Course) -> LessonEntity? {
        guard let lesson = course.lesson(id) else { return nil }
        let chapter = course.module(of: id)?.chapter.title ?? ""
        return LessonEntity(lesson, chapter: chapter, done: LearnerStore.shared.isDone(id))
    }
}

struct OpenLessonIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Lesson"
    static let description = IntentDescription("Opens a lesson in Swift: Zero to Hero.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Lesson") var target: LessonEntity

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppRouter.open?(target.id) }
        return .result()
    }
}

struct ContinueLessonIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue the Course"
    static let description = IntentDescription("Opens the next lesson you have not finished.")
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result: (String?, String) = await MainActor.run {
            guard let course = try? Course.load() else { return (nil, "The course could not be loaded.") }
            let store = LearnerStore.shared
            guard let next = course.next(after: store.lastLesson, done: { store.isDone($0) }) else {
                return (nil, "You have finished every lesson. Well done.")
            }
            AppRouter.open?(next.id)
            return (next.id, "Opening \(next.title).")
        }
        return .result(dialog: "\(result.1)")
    }
}

struct CourseProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "How Far Have I Got"
    static let description = IntentDescription("Says how many lessons you have finished.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let result: (Int, Int, Int) = await MainActor.run {
            guard let course = try? Course.load() else { return (0, 0, 0) }
            let store = LearnerStore.shared
            return (store.count(in: course.lessons), course.lessons.count, store.streak)
        }
        let dialog = result.0 == 0
            ? "You have not started yet. \(result.1) lessons are waiting."
            : "You have finished \(result.0) of \(result.1) lessons, with a \(result.2) day streak."
        return .result(value: result.0, dialog: "\(dialog)")
    }
}

struct NextLessonIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Next"
    static let description = IntentDescription("Says which lesson is next.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<LessonEntity> {
        let value: LessonEntity? = await MainActor.run {
            guard let course = try? Course.load() else { return nil }
            let store = LearnerStore.shared
            guard let next = course.next(after: store.lastLesson, done: { store.isDone($0) }) else { return nil }
            return LessonEntity(next, chapter: course.module(of: next.id)?.chapter.title ?? "", done: false)
        }
        guard let value else { return .result(value: LessonEntity(Lesson.warmUp, chapter: "", done: false), dialog: "You have finished the course.") }
        return .result(value: value, dialog: "Next is \(value.title).")
    }
}

struct ZeroToHeroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueLessonIntent(), phrases: [
            "Continue my Swift course in \(.applicationName)",
            "Continue learning in \(.applicationName)",
            "\(.applicationName) continue",
        ], shortTitle: "Continue", systemImageName: "play.fill")

        AppShortcut(intent: NextLessonIntent(), phrases: [
            "What's next in \(.applicationName)",
            "What is my next Swift lesson in \(.applicationName)",
        ], shortTitle: "What's Next", systemImageName: "arrow.right")

        AppShortcut(intent: CourseProgressIntent(), phrases: [
            "How far am I in \(.applicationName)",
            "My progress in \(.applicationName)",
        ], shortTitle: "My Progress", systemImageName: "chart.bar")

        AppShortcut(intent: OpenLessonIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Open a lesson in \(.applicationName)",
        ], shortTitle: "Open Lesson", systemImageName: "book")
    }
}

/// Keeps Spotlight in step with progress. Off when the person turns off sharing with Siri.
enum SpotlightIndex {
    static func refresh() async {
        let share = UserDefaults.standard.object(forKey: "shareWithSiri") as? Bool ?? true
        guard share, let course = try? Course.load() else {
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            return
        }
        let store = LearnerStore.shared
        let entities = course.lessons.map { lesson in
            LessonEntity(lesson, chapter: course.module(of: lesson.id)?.chapter.title ?? "", done: store.isDone(lesson.id))
        }
        try? await CSSearchableIndex.default().indexAppEntities(entities)
    }
}
