// The course, as exported from Asteria Learn (MundusNovusLearn/tools/export-app.mjs) into Resources/course.json.
// v2 keeps the same schema and adds optional fields, so an older export still loads.
import Foundation

public nonisolated struct Course: Decodable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let versions: String
    public let summary: String
    public let chapters: [Chapter]
    /// v2: the date the course was last checked against a shipping OS. Optional so older exports load.
    public let updated: String?

    /// Every lesson in course order, and where each one sits. Built once at decode time: views read these on every
    /// update, so they must not be rebuilt each time.
    public let lessons: [Lesson]
    private let positions: [Lesson.ID: Position]

    private struct Position: Sendable {
        let index: Int
        let chapter: Int
        let module: Int
    }

    private enum CodingKeys: String, CodingKey { case id, title, subtitle, versions, summary, chapters, updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        versions = try c.decode(String.self, forKey: .versions)
        summary = try c.decode(String.self, forKey: .summary)
        chapters = try c.decode([Chapter].self, forKey: .chapters)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        var lessons: [Lesson] = []
        var positions: [Lesson.ID: Position] = [:]
        for (ci, chapter) in chapters.enumerated() {
            for (mi, module) in chapter.modules.enumerated() {
                for lesson in module.lessons {
                    positions[lesson.id] = Position(index: lessons.count, chapter: ci, module: mi)
                    lessons.append(lesson)
                }
            }
        }
        self.lessons = lessons
        self.positions = positions
    }

    public func lesson(_ id: Lesson.ID) -> Lesson? { positions[id].map { lessons[$0.index] } }

    public func module(of id: Lesson.ID) -> (chapter: Chapter, module: Module)? {
        guard let p = positions[id] else { return nil }
        return (chapters[p.chapter], chapters[p.chapter].modules[p.module])
    }

    public func neighbours(of id: Lesson.ID) -> (previous: Lesson?, next: Lesson?) {
        guard let i = positions[id]?.index else { return (nil, nil) }
        return (i > 0 ? lessons[i - 1] : nil, i + 1 < lessons.count ? lessons[i + 1] : nil)
    }

    /// The next lesson that is not done, in course order. When `id` itself is unfinished it is returned first, which is
    /// what Continue should do; when it is done, the search starts with the lesson after it.
    public func next(after id: Lesson.ID?, done: (Lesson.ID) -> Bool) -> Lesson? {
        let start = id.flatMap { positions[$0]?.index } ?? 0
        return lessons[start...].first { !done($0.id) } ?? lessons[..<start].first { !done($0.id) }
    }

    public var exerciseCount: Int { lessons.filter(\.hasCode).count }
    public var quizCount: Int { lessons.filter { !$0.questions.isEmpty }.count }
    public var totalMinutes: Int { lessons.reduce(0) { $0 + $1.minutes } }
}

public nonisolated struct Chapter: Decodable, Sendable, Identifiable {
    public let title: String
    public let summary: String
    public let modules: [Module]
    public var id: String { title }

    public var lessons: [Lesson] { modules.flatMap(\.lessons) }
}

public nonisolated struct Module: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let lessons: [Lesson]
}

public nonisolated struct Lesson: Decodable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Decodable, Sendable, CaseIterable {
        case lesson, workshop, lab, quiz, xcode, project

        public var label: String {
            switch self {
            case .lesson: "Lesson"
            case .workshop: "Workshop"
            case .lab: "Lab"
            case .quiz: "Quiz"
            case .xcode: "Xcode"
            case .project: "Project"
            }
        }

        public var symbol: String {
            switch self {
            case .quiz: "questionmark.circle"
            case .xcode: "hammer"
            case .project: "star"
            case .lab: "flask"
            case .workshop: "wrench.and.screwdriver"
            case .lesson: "book"
            }
        }
    }

    public let id: String
    public let title: String
    public let type: Kind
    public let minutes: Int
    public let description: [Block]
    public let instructions: [Block]
    public let seed: String?
    public let tests: [LessonTest]
    public let hints: [String]
    public let checklist: [String]
    public let questions: [Question]

    public var hasCode: Bool { !tests.isEmpty }

    /// Lessons that are meant to be done in Xcode on a Mac.
    public var worksInXcode: Bool { type == .xcode || type == .project }

    /// A lesson with no tests, run once to warm up the compiler.
    public static let warmUp = Lesson(id: "warm-up", title: "", type: .lesson, minutes: 0, description: [], instructions: [], seed: nil,
                               tests: [], hints: [], checklist: [], questions: [])

    public static func == (a: Lesson, b: Lesson) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A test is a sentence with one or more checks; it passes when every check does.
public nonisolated struct LessonTest: Decodable, Sendable {
    public let text: String
    public let checks: [Check]
}

public nonisolated struct Check: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case swift              // Swift code run after the learner's, calling expect(...)
        case output, nooutput   // a regular expression the printed output must (or must not) match
        case source, nosource   // a regular expression the code must (or must not) match
    }
    public let kind: Kind
    public let code: String
}

public nonisolated struct Question: Decodable, Sendable {
    public struct Answer: Decodable, Sendable {
        public let text: String
        public let correct: Bool
    }
    public let question: String
    public let detail: [Block]
    public let answers: [Answer]
    public let why: String
}

/// Lesson text, block by block. Inline text is Markdown: bold, italics, `code` and links.
public nonisolated indirect enum Block: Decodable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String)
    case list(ordered: Bool, items: [String])
    case note(kind: String, blocks: [Block])
    case quote([Block])
    case table(head: [String], rows: [[String]])
    case rule

    private enum Keys: String, CodingKey { case type, level, text, lang, code, ordered, items, kind, blocks, head, rows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "heading": self = .heading(level: try c.decode(Int.self, forKey: .level), text: try c.decode(String.self, forKey: .text))
        case "code": self = .code(language: try c.decode(String.self, forKey: .lang), code: try c.decode(String.self, forKey: .code))
        case "list": self = .list(ordered: try c.decode(Bool.self, forKey: .ordered), items: try c.decode([String].self, forKey: .items))
        case "note": self = .note(kind: try c.decode(String.self, forKey: .kind), blocks: try c.decode([Block].self, forKey: .blocks))
        case "quote": self = .quote(try c.decode([Block].self, forKey: .blocks))
        case "table": self = .table(head: try c.decode([String].self, forKey: .head), rows: try c.decode([[String]].self, forKey: .rows))
        case "rule": self = .rule
        default: self = .paragraph(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }
}

extension Block {
    /// The block as plain text, for a model prompt or a search: no Markdown structure, code kept as written.
    public var plainText: String {
        switch self {
        case .heading(_, let text), .paragraph(let text): text
        case .code(_, let code): code
        case .list(_, let items): items.map { "- " + $0 }.joined(separator: "\n")
        case .note(_, let blocks), .quote(let blocks): blocks.plainText
        case .table(let head, let rows): ([head] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .rule: ""
        }
    }
}

extension [Block] {
    public var plainText: String { map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

extension Course {
    public enum LoadError: Error { case missing }

    /// A tiny course so a preview or a missing resource never crashes the app.
    public static var fallback: Course {
        let json = """
        {"id":"fallback","title":"Swift: Zero to Hero","subtitle":"The course could not be loaded.","versions":"","summary":"","chapters":[]}
        """
        return try! JSONDecoder().decode(Course.self, from: Data(json.utf8))
    }

    /// The course shipped inside the app.
    public static func load() throws -> Course {
        guard let url = Resources.url("course.json") else { throw LoadError.missing }
        var text = try String(contentsOf: url, encoding: .utf8)
        for (web, app) in appWording { text = text.replacingOccurrences(of: web, with: app) }
        return try JSONDecoder().decode(Course.self, from: Data(text.utf8))
    }

    /// The course is written for the website; these phrases read right in the app instead.
    public static let appWording = [
        ("right here in your browser", "right here in the app"),
        ("this site's exercises", "this app's exercises"),
        ("the editor on this site", "the editor in this app"),
        ("the exercises on this site", "the exercises in this app"),
        ("Every lesson on this site", "Every lesson in this app"),
    ]
}

/// Files that ship with the app: course.json and the font.
public nonisolated enum Resources {
    public static func url(_ name: String) -> URL? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        if let url = Bundle.main.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil) { return url }
        // SwiftPM tests and `swift run` from the repository: look in the repository's Resources.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { dir = dir.deletingLastPathComponent() }
        for folder in ["Resources", "ZeroToHero/Resources"] {
            let dev = dir.appending(path: folder + "/" + name).standardized
            if FileManager.default.fileExists(atPath: dev.path) { return dev }
        }
        return nil
    }
}
