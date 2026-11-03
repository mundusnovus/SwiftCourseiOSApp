// The engine's own tests, and the audit that decides which lessons can be checked on an iPhone.
import Testing
import Foundation
@testable import ZeroToHeroKit

@Suite("Exercise engine")
struct EngineTests {
    @Test func valuesAndPrinting() async throws {
        let result = try await OnDeviceRunner().check(lesson(code: "print(1 + 2)"), code: "print(1 + 2)")
        #expect(result.compiled)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }

    @Test func functionsAndOptionals() async throws {
        let lesson = lesson(code: """
        func greet(_ name: String) -> String { "Hello, \\(name)!" }
        expect(greet("Ada") == "Hello, Ada!")
        """)
        let result = try await OnDeviceRunner().check(lesson, code: """
        func greet(_ name: String) -> String { "Hello, \\(name)!" }
        """)
        #expect(result.compiled)
        #expect(result.passed, "\(result.tests)")
    }

    @Test func arraysAndClosures() async throws {
        let lesson = lesson(code: "expect([1, 2, 3].map { $0 * 2 } == [2, 4, 6])")
        let result = try await OnDeviceRunner().check(lesson, code: "")
        #expect(result.passed, "\(result.tests)")
    }

    @Test func structsAndMethods() async throws {
        let lesson = lesson(code: """
        struct Counter { var count = 0; mutating func bump() { count += 1 } }
        var c = Counter()
        c.bump(); c.bump()
        expect(c.count == 2)
        """)
        let result = try await OnDeviceRunner().check(lesson, code: """
        struct Counter { var count = 0; mutating func bump() { count += 1 } }
        """)
        #expect(result.passed, "\(result.errors) \(result.tests)")
    }

    @Test func enumsAndSwitch() async throws {
        let lesson = lesson(code: """
        enum Direction { case north, south }
        func turn(_ d: Direction) -> Direction {
            switch d { case .north: return .south; case .south: return .north }
        }
        expect(turn(.north) == .south)
        """)
        let result = try await OnDeviceRunner().check(lesson, code: """
        enum Direction { case north, south }
        func turn(_ d: Direction) -> Direction {
            switch d { case .north: return .south; case .south: return .north }
        }
        """)
        #expect(result.passed, "\(result.errors) \(result.tests)")
    }

    @Test func unsupportedCodeSaysSo() async throws {
        let result = try await OnDeviceRunner().check(lesson(code: ""), code: "actor A {}")
        #expect(result.unsupported)
    }

    private func lesson(code: String) -> Lesson {
        Lesson(id: "test", title: "Test", type: .lesson, minutes: 1, description: [], instructions: [], seed: "",
               tests: [LessonTest(text: "It works", checks: [Check(kind: .swift, code: code)])],
               hints: [], checklist: [], questions: [])
    }
}

/// How much of the shipped course the on-device engine can check. This is the audit the plan promised: it prints a
/// coverage report and fails only if it finds no coverage at all, so it can be run on every change without hiding gaps.
@Suite("Course coverage")
struct CoverageTests {
    @Test func measure() async throws {
        let course = try Course.load()
        guard let url = Resources.url("solutions.json"),
              let data = try? Data(contentsOf: url),
              let solutions = try? JSONDecoder().decode([String: String].self, from: data) else {
            Issue.record("No solutions.json beside the course.")
            return
        }
        let runner = OnDeviceRunner()
        var runnable: [String] = []
        var labs: [String] = []
        var broken: [(String, String)] = []
        for lesson in course.lessons where lesson.hasCode {
            guard let solution = solutions[lesson.id] else { continue }
            print("CHECK \(lesson.id)")
            let result = try await runner.check(lesson, code: solution)
            if result.unsupported || !result.compiled {
                let first = result.errors.first
                labs.append("\(lesson.id) [\(first?.message ?? "?") line \(first?.line.map(String.init) ?? "-")]")
            } else if result.passed {
                runnable.append(lesson.id)
            } else {
                broken.append((lesson.id, result.tests.filter { !$0.passed }.map(\.text).joined(separator: " | ")))
            }
        }
        print("DEVICE COVERAGE: \(runnable.count) runnable, \(labs.count) labs, \(broken.count) failing")
        if let data = try? JSONEncoder().encode(runnable.sorted()), let json = String(data: data, encoding: .utf8) {
            print("RUNNABLE_JSON:\(json)")
        }
        for (id, why) in broken.prefix(60) { print("  FAIL \(id): \(why.prefix(160))") }
        for id in labs.prefix(60) { print("  LAB  \(id)") }
        #expect(runnable.count > 20, "The engine should cover a useful part of the course, not almost none.")
    }
}

@Suite("Diagnostics")
struct DiagnosticTests {
    @Test func specificLessons() async throws {
        guard let wanted = ProcessInfo.processInfo.environment["ZTH_DIAGNOSE"] else { return }
        let course = try Course.load()
        guard let url = Resources.url("solutions.json"), let data = try? Data(contentsOf: url),
              let solutions = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for id in wanted.split(separator: ",").map(String.init) {
            guard let lesson = course.lesson(id), let solution = solutions[id] else { print("MISSING \(id)"); continue }
            let result = try await OnDeviceRunner().check(lesson, code: solution)
            print("=== \(id) compiled=\(result.compiled) unsupported=\(result.unsupported) crashed=\(result.crashed) timedOut=\(result.timedOut)")
            print("errors: \(result.errors) crash: \(result.crashReason)")
            print("output: \(result.output.debugDescription)")
            for t in result.tests { print("  \(t.passed ? "PASS" : "FAIL") \(t.text)") }
            if let expression = ProcessInfo.processInfo.environment["ZTH_EXPR"] {
                let i = Interpreter()
                do {
                    try i.run(try Parser.parse(solution))
                    let value = try i.evaluate(try Parser.parseExpression(expression))
                    print("EXPR \(expression) = \(i.display(value))")
                } catch { print("EXPR ERROR \(error)") }
            }
        }
    }
}

@Suite("Type diagnostics")
struct TypeTests {
    @Test func typeOf() throws {
        let i = Interpreter()
        try i.run(try Parser.parse("let x = 1"))
        let t = try i.evaluate(try Parser.parseExpression("type(of: x)"))
        print("TYPE OF X =", i.display(t))
        let s = try i.evaluate(try Parser.parseExpression("Int.self"))
        print("INT.SELF =", i.display(s))
        let eq = try i.evaluate(try Parser.parseExpression("type(of: x) == Int.self"))
        print("EQUAL =", i.display(eq))
    }
}

@Suite("Parse diagnostics")
struct ParseTests {
    @Test func snippets() throws {
        let snippets = [
            "let isEven: (Int) -> Bool = { n in n % 2 == 0 }",
            "for n in 1...100 { total += n }",
            "for n in stride(from: 2, through: 20, by: 2) { evens.append(n) }",
            "func f(_ x: Int) -> Int { x + 1 }",
            "let a: [Int] = [1, 2]",
            "let d = [\"a\": 1]",
            "stride(from: 2, through: 20, by: 2)",
        ]
        for snippet in snippets {
            do { _ = try Parser.parse(snippet); print("PARSE OK  \(snippet)") }
            catch { print("PARSE ERR \(snippet) -> \(error)") }
        }
    }
}

@Suite("Capture and raw values")
struct CaptureTests {
    @Test func separateAccumulators() throws {
        let code = """
        func makeAccumulator(start: Int) -> (Int) -> Int {
            var total = start
            return { amount in
                total += amount
                return total
            }
        }
        let a = makeAccumulator(start: 0)
        let b = makeAccumulator(start: 100)
        print(a(1))
        print(b(1))
        print(a(1))
        """
        let parsed = try Parser.parse(code)
        dump(parsed)
        let i = Interpreter()
        try i.run(parsed)
        print("CAPTURE OUTPUT:\n\(i.output)")
    }

    @Test func rawValues() throws {
        let code = """
        enum Weekday: Int, CaseIterable {
            case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
        }
        """
        let statements = try Parser.parse(code)
        dump(statements)
        let i = Interpreter()
        try i.run(statements)
        print("RAW monday =", i.display(try i.evaluate(try Parser.parseExpression("Weekday.monday.rawValue"))))
        print("RAW sunday =", i.display(try i.evaluate(try Parser.parseExpression("Weekday.sunday.rawValue"))))
        print("ALL =", i.display(try i.evaluate(try Parser.parseExpression("Weekday.allCases.count"))))
    }
}

