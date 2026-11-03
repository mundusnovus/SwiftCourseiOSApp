// Milestones and badges. The rules are pure, so they can be tested without SwiftUI, a database, or a model.
import Foundation

public nonisolated struct Achievement: Identifiable, Sendable, Hashable {
    public enum Tier: Int, Sendable, Comparable {
        case bronze = 1, silver, gold, platinum
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
        public var name: String {
            switch self {
            case .bronze: "Bronze"
            case .silver: "Silver"
            case .gold: "Gold"
            case .platinum: "Platinum"
            }
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let tier: Tier
}

public nonisolated struct ProgressSnapshot: Sendable {
    public var done: Set<String> = []
    public var exercisesPassed: Int = 0
    public var quizzesPassed: Int = 0
    public var labsDone: Int = 0
    public var streak: Int = 0
    public var chaptersDone: Int = 0
    public var lessonsInDoneChapters: Int = 0
    public var totalLessons: Int = 161
    public var hourOfDay: Int = 12
    public var daysSinceStart: Int = 0
    public var cameBackAfterBreak: Bool = false
    public var completedChapters: Set<String> = []

    public init() {}
}

public nonisolated enum Achievements {
    public static let all: [Achievement] = [
        .init(id: "first-step", title: "First Step", detail: "Finish your first lesson.", symbol: "figure.walk", tier: .bronze),
        .init(id: "hello-world", title: "Hello, World", detail: "Run your first program.", symbol: "terminal", tier: .bronze),
        .init(id: "first-pass", title: "It Compiles", detail: "Pass your first exercise.", symbol: "checkmark.seal", tier: .bronze),
        .init(id: "five-lessons", title: "Getting Warm", detail: "Finish five lessons.", symbol: "flame", tier: .bronze),
        .init(id: "ten-exercises", title: "Ten Down", detail: "Pass ten exercises.", symbol: "10.circle", tier: .silver),
        .init(id: "twenty-five", title: "Quarter Way", detail: "Finish 25 lessons.", symbol: "circle.quarter.filled", tier: .silver),
        .init(id: "fifty-exercises", title: "Fifty", detail: "Pass fifty exercises.", symbol: "50.circle", tier: .gold),
        .init(id: "halfway", title: "Halfway There", detail: "Finish half the course.", symbol: "chart.bar.fill", tier: .silver),
        .init(id: "streak-3", title: "Three in a Row", detail: "Practise three days in a row.", symbol: "3.circle", tier: .bronze),
        .init(id: "streak-7", title: "A Good Week", detail: "Practise seven days in a row.", symbol: "calendar", tier: .silver),
        .init(id: "streak-30", title: "A Good Month", detail: "Practise thirty days in a row.", symbol: "calendar.badge.clock", tier: .gold),
        .init(id: "chapter-one", title: "Chapter One", detail: "Finish your first chapter.", symbol: "book.closed", tier: .bronze),
        .init(id: "first-quiz", title: "Quiz Whiz", detail: "Pass your first quiz.", symbol: "questionmark.circle", tier: .bronze),
        .init(id: "ten-quizzes", title: "Examiner", detail: "Pass ten quizzes.", symbol: "checklist", tier: .silver),
        .init(id: "all-quizzes", title: "Every Answer", detail: "Pass every quiz in the course.", symbol: "star.circle", tier: .platinum),
        .init(id: "night-owl", title: "Night Owl", detail: "Finish a lesson after midnight.", symbol: "moon.stars", tier: .bronze),
        .init(id: "early-bird", title: "Early Bird", detail: "Finish a lesson before seven.", symbol: "sunrise", tier: .bronze),
        .init(id: "comeback", title: "Back Again", detail: "Return after a week away.", symbol: "arrow.uturn.backward", tier: .silver),
        .init(id: "hundred", title: "A Hundred", detail: "Finish a hundred lessons.", symbol: "100.circle", tier: .gold),
        .init(id: "course-complete", title: "Zero to Hero", detail: "Finish the whole course.", symbol: "trophy", tier: .platinum),
        .init(id: "streak-100", title: "Unbroken", detail: "Practise a hundred days in a row.", symbol: "flame.fill", tier: .platinum),
        .init(id: "first-lab", title: "Lab Rat", detail: "Finish your first lab.", symbol: "flask", tier: .bronze),
        .init(id: "designer", title: "Taste", detail: "Finish the design chapter.", symbol: "paintpalette", tier: .gold),
        .init(id: "shipper", title: "Shipped", detail: "Finish the shipping chapter.", symbol: "shippingbox", tier: .gold),
    ]

    public static func byID(_ id: String) -> Achievement? { all.first { $0.id == id } }

    /// Every badge the snapshot has earned. Pure, deterministic, and cheap enough to run after each lesson.
    public static func earned(_ snapshot: ProgressSnapshot) -> Set<String> {
        var out: Set<String> = []
        if !snapshot.done.isEmpty { out.insert("first-step") }
        if snapshot.exercisesPassed >= 1 { out.insert("first-pass"); out.insert("hello-world") }
        if snapshot.done.count >= 5 { out.insert("five-lessons") }
        if snapshot.exercisesPassed >= 10 { out.insert("ten-exercises") }
        if snapshot.done.count >= 25 { out.insert("twenty-five") }
        if snapshot.exercisesPassed >= 50 { out.insert("fifty-exercises") }
        if snapshot.totalLessons > 0, snapshot.done.count * 2 >= snapshot.totalLessons { out.insert("halfway") }
        if snapshot.done.count >= 100 { out.insert("hundred") }
        if snapshot.done.count >= snapshot.totalLessons, snapshot.totalLessons > 0 { out.insert("course-complete") }
        if snapshot.streak >= 3 { out.insert("streak-3") }
        if snapshot.streak >= 7 { out.insert("streak-7") }
        if snapshot.streak >= 30 { out.insert("streak-30") }
        if snapshot.streak >= 100 { out.insert("streak-100") }
        if snapshot.chaptersDone >= 1 { out.insert("chapter-one") }
        if snapshot.quizzesPassed >= 1 { out.insert("first-quiz") }
        if snapshot.labsDone >= 1 { out.insert("first-lab") }
        if snapshot.quizzesPassed >= 10 { out.insert("ten-quizzes") }
        if snapshot.cameBackAfterBreak { out.insert("comeback") }
        if snapshot.hourOfDay < 5 { out.insert("night-owl") }
        if snapshot.hourOfDay >= 5 && snapshot.hourOfDay < 7 { out.insert("early-bird") }
        return out
    }

    /// Badges that depend on the course structure, evaluated with the chapter titles the course actually has.
    public static func earned(_ snapshot: ProgressSnapshot, course: Course, completedChapters: Set<String>) -> Set<String> {
        var out = earned(snapshot)
        if completedChapters.contains(where: { $0.localizedCaseInsensitiveContains("design") || $0.localizedCaseInsensitiveContains("swiftui") }) { out.insert("designer") }
        if completedChapters.contains(where: { $0.localizedCaseInsensitiveContains("shipping") }) { out.insert("shipper") }
        if snapshot.quizzesPassed >= course.quizCount, course.quizCount > 0 { out.insert("all-quizzes") }
        return out
    }
}
