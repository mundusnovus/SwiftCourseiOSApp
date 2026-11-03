// The study plan is worked out from progress alone, so it can be tested without a model or a device.
import Testing
import Foundation
@testable import ZeroToHeroKit

@Suite("Study plan")
struct StudyPlanTests {
    @Test func freshStartFollowsTheCourse() throws {
        let course = try Course.load()
        let plan = StudyPlan.make(course: course, done: [:], from: nil, minutesPerDay: 30, days: 7)
        #expect(plan.days.count == 7)
        #expect(plan.days[0].lessons.first?.id == course.lessons[0].id)
        #expect(plan.review.isEmpty, "nothing to review before anything is done")
        let planned = plan.days.flatMap(\.lessons).map(\.id)
        #expect(Set(planned).count == planned.count, "no lesson twice")
        #expect(planned == Array(course.lessons.prefix(planned.count).map(\.id)), "in course order")
    }

    @Test func daysKeepToTheBudget() throws {
        let course = try Course.load()
        let plan = StudyPlan.make(course: course, done: [:], from: nil, minutesPerDay: 25, days: 7)
        for day in plan.days where day.lessons.count > 1 {
            #expect(day.minutes <= 25, "day \(day.id) fits the budget")
        }
    }

    @Test func skipsFinishedLessonsAndStartsAtContinue() throws {
        let course = try Course.load()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var done: [Lesson.ID: Date] = [:]
        for lesson in course.lessons.prefix(10) { done[lesson.id] = now.addingTimeInterval(-10 * 86_400) }
        let plan = StudyPlan.make(course: course, done: done, from: course.lessons[9].id, now: now)
        #expect(plan.days.first?.lessons.first?.id == course.lessons[10].id)
        #expect(!plan.days.flatMap(\.lessons).contains { done[$0.id] != nil })
    }

    @Test func reviewsOldWorkWithQuestionsOrCode() throws {
        let course = try Course.load()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let checked = course.lessons.filter { !$0.questions.isEmpty || $0.hasCode }
        let reading = try #require(course.lessons.first { $0.questions.isEmpty && !$0.hasCode })
        var done: [Lesson.ID: Date] = [:]
        done[checked[0].id] = now.addingTimeInterval(-1 * 86_400)   // too recent
        done[checked[1].id] = now.addingTimeInterval(-20 * 86_400)  // oldest
        done[checked[2].id] = now.addingTimeInterval(-5 * 86_400)
        done[reading.id] = now.addingTimeInterval(-30 * 86_400)     // nothing to check yourself on
        let plan = StudyPlan.make(course: course, done: done, from: nil, now: now)
        #expect(plan.review.map(\.id) == [checked[1].id, checked[2].id])
    }

    @Test func finishedCourseHasNoDays() throws {
        let course = try Course.load()
        var done: [Lesson.ID: Date] = [:]
        for lesson in course.lessons { done[lesson.id] = .distantPast }
        let plan = StudyPlan.make(course: course, done: done, from: nil)
        #expect(plan.days.isEmpty)
        #expect(plan.review.count == 3)
    }
}

@Suite("Plain text for prompts")
struct PlainTextTests {
    @Test func blocksReadAsText() throws {
        let blocks: [Block] = [.heading(level: 2, text: "Optionals"), .paragraph("A value or **nothing**."),
                               .list(ordered: false, items: ["one", "two"]), .rule, .code(language: "swift", code: "let x: Int? = nil")]
        let text = blocks.plainText
        #expect(text == "Optionals\n\nA value or **nothing**.\n\n- one\n- two\n\nlet x: Int? = nil")
        #expect(!text.contains("Block."), "no Swift debug descriptions reach a model")
    }

    @Test func everyLessonHasReadableText() throws {
        for lesson in try Course.load().lessons {
            #expect(!lesson.description.plainText.isEmpty, "\(lesson.id)")
        }
    }
}
