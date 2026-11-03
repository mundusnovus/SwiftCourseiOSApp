// A week of study, worked out from progress alone. The plan is pure and deterministic: Apple Intelligence may write a
// sentence of encouragement on top of it, but it never chooses the lessons, so a plan can never point at a lesson that
// does not exist.
import Foundation

public nonisolated struct StudyPlan: Sendable {
    public struct Day: Sendable, Identifiable {
        public let id: Int
        public let lessons: [Lesson]
        public var minutes: Int { lessons.reduce(0) { $0 + $1.minutes } }
    }

    public let days: [Day]
    /// Finished lessons worth a second look, oldest first.
    public let review: [Lesson]

    public var isEmpty: Bool { days.isEmpty && review.isEmpty }

    /// Review gaps that suit memory: a lesson becomes worth reviewing three days after it was finished.
    public static let reviewAfterDays = 3

    /// - Parameters:
    ///   - done: when each finished lesson was finished.
    ///   - from: where Continue would start (the last lesson opened).
    ///   - minutesPerDay: the daily budget. A lesson longer than the budget gets a day to itself.
    public static func make(course: Course, done: [Lesson.ID: Date], from: Lesson.ID?, minutesPerDay: Int = 30,
                            days dayCount: Int = 7, reviewCount: Int = 3, now: Date = .now) -> StudyPlan {
        // Unfinished lessons in course order, starting where Continue would, then wrapping to any gaps before it.
        let all = course.lessons
        let start = from.flatMap { id in all.firstIndex { $0.id == id } } ?? 0
        let queue = (all[start...] + all[..<start]).filter { done[$0.id] == nil }.prefix(dayCount * 8)

        var days: [Day] = []
        var current: [Lesson] = []
        var minutes = 0
        for lesson in queue {
            if !current.isEmpty, minutes + lesson.minutes > minutesPerDay {
                days.append(Day(id: days.count, lessons: current))
                current = []
                minutes = 0
                if days.count == dayCount { break }
            }
            current.append(lesson)
            minutes += lesson.minutes
        }
        if !current.isEmpty, days.count < dayCount { days.append(Day(id: days.count, lessons: current)) }

        let cutoff = now.addingTimeInterval(-Double(reviewAfterDays) * 86_400)
        let review = done
            .filter { $0.value <= cutoff }
            .compactMap { id, date in course.lesson(id).map { ($0, date) } }
            .filter { !$0.0.questions.isEmpty || $0.0.hasCode }
            .sorted { $0.1 < $1.1 }
            .prefix(reviewCount)
            .map(\.0)

        return StudyPlan(days: days, review: Array(review))
    }
}
