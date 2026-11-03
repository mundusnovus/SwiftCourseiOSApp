// The course contract and the achievement rules, tested without a database, a device, or SwiftUI.
import Testing
import Foundation
@testable import ZeroToHeroKit

@Suite("Course contract")
struct CourseContractTests {
    @Test func shape() throws {
        let course = try Course.load()
        #expect(course.chapters.count == 10)
        #expect(course.lessons.count == 173)
        #expect(course.exerciseCount == 83)

        let ids = course.lessons.map(\.id)
        #expect(Set(ids).count == ids.count, "lesson ids are unique")

        for lesson in course.lessons {
            #expect(!lesson.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(lesson.id) has a title")
            #expect(!lesson.description.isEmpty, "\(lesson.id) has a description")
            #expect(lesson.minutes >= 0)
        }
    }

    @Test func quizzesHaveOneRightAnswer() throws {
        let course = try Course.load()
        for lesson in course.lessons where !lesson.questions.isEmpty {
            #expect(lesson.type == .quiz || lesson.type == .lesson || lesson.type == .lab || lesson.type == .xcode,
                    "\(lesson.id) carries questions on a sensible type")
            for question in lesson.questions {
                let correct = question.answers.filter(\.correct).count
                #expect(correct >= 1, "\(lesson.id) has a correct answer")
                #expect(!question.why.isEmpty, "\(lesson.id) explains the answer")
            }
        }
    }

    @Test func everyExerciseHasASolution() throws {
        let course = try Course.load()
        guard let url = Resources.url("solutions.json"),
              let data = try? Data(contentsOf: url),
              let solutions = try? JSONDecoder().decode([String: String].self, from: data) else {
            Issue.record("solutions.json is missing")
            return
        }
        for lesson in course.lessons where lesson.hasCode {
            #expect(solutions[lesson.id] != nil, "\(lesson.id) has a solution")
            #expect(solutions[lesson.id]?.isEmpty == false, "\(lesson.id)'s solution is not empty")
        }
    }

    @Test func nextAndNeighbours() throws {
        let course = try Course.load()
        let first = course.lessons[0]
        let second = course.lessons[1]
        #expect(course.next(after: nil) { _ in false }?.id == first.id)
        #expect(course.next(after: first.id) { _ in false }?.id == second.id)
        #expect(course.next(after: nil) { _ in true } == nil)
        #expect(course.neighbours(of: first.id).previous == nil)
        #expect(course.neighbours(of: first.id).next?.id == second.id)
    }

    @Test func everyLessonIsReachable() throws {
        let course = try Course.load()
        for lesson in course.lessons {
            #expect(course.module(of: lesson.id) != nil, "\(lesson.id) belongs to a module")
        }
    }
}

@Suite("Achievement rules")
struct AchievementRuleTests {
    @Test func firstSteps() {
        var snapshot = ProgressSnapshot()
        snapshot.done = ["start-welcome"]
        snapshot.totalLessons = 173
        let earned = Achievements.earned(snapshot)
        #expect(earned.contains("first-step"))
        #expect(!earned.contains("five-lessons"))
    }

    @Test func exercisesAndStreaks() {
        var snapshot = ProgressSnapshot()
        snapshot.exercisesPassed = 50
        snapshot.streak = 30
        let earned = Achievements.earned(snapshot)
        #expect(earned.contains("first-pass"))
        #expect(earned.contains("ten-exercises"))
        #expect(earned.contains("fifty-exercises"))
        #expect(earned.contains("streak-3"))
        #expect(earned.contains("streak-7"))
        #expect(earned.contains("streak-30"))
        #expect(!earned.contains("streak-100"))
    }

    @Test func courseCompletion() {
        var snapshot = ProgressSnapshot()
        snapshot.totalLessons = 10
        snapshot.done = Set((0..<10).map { "lesson-\($0)" })
        #expect(Achievements.earned(snapshot).contains("course-complete"))
        #expect(Achievements.earned(snapshot).contains("halfway"))
    }

    @Test func quizAndLabRules() throws {
        let course = try Course.load()
        var snapshot = ProgressSnapshot()
        snapshot.quizzesPassed = course.quizCount
        snapshot.labsDone = 1
        snapshot.totalLessons = course.lessons.count
        let earned = Achievements.earned(snapshot, course: course, completedChapters: [])
        #expect(earned.contains("first-quiz"))
        #expect(earned.contains("all-quizzes"))
        #expect(earned.contains("first-lab"))
    }

    @Test func timeOfDayRules() {
        var night = ProgressSnapshot()
        night.hourOfDay = 2
        #expect(Achievements.earned(night).contains("night-owl"))

        var morning = ProgressSnapshot()
        morning.hourOfDay = 6
        #expect(Achievements.earned(morning).contains("early-bird"))
        #expect(!Achievements.earned(morning).contains("night-owl"))
    }

    @Test func chapterRules() {
        var snapshot = ProgressSnapshot()
        snapshot.chaptersDone = 1
        let earned = Achievements.earned(snapshot, course: Course.fallback, completedChapters: ["SwiftUI", "Quality and shipping"])
        #expect(earned.contains("chapter-one"))
        #expect(earned.contains("designer"))
        #expect(earned.contains("shipper"))
    }

    @Test func idsAreUnique() {
        let ids = Achievements.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Achievements.all.count == 24)
    }
}
