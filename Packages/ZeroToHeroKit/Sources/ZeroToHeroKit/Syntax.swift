// The teaching subset of Swift: tokens, syntax tree and errors. This is not a general Swift parser. It covers the
// language the course exercises use, and it says so plainly when it meets something it does not know, so the app can
// offer the lesson as an Xcode lab instead of pretending to check it.
import Foundation

nonisolated struct SourceError: Error, Sendable, CustomStringConvertible {
    let line: Int
    let message: String
    /// True when the source uses Swift the on-device engine does not implement. The UI turns this into "open on Mac".
    let unsupported: Bool

    init(_ message: String, line: Int, unsupported: Bool = false) {
        self.message = message
        self.line = line
        self.unsupported = unsupported
    }

    var description: String { "line \(line): \(message)" }
}

// MARK: - Tokens

nonisolated struct Token: Sendable {
    enum Kind: Sendable, Equatable {
        case name, number, string, symbol, keyword, newline, eof
    }

    let kind: Kind
    let text: String
    let line: Int
    var intValue: Int? { kind == .number ? Int(text) : nil }
    var doubleValue: Double? { kind == .number ? Double(text) : nil }

    func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
    func isName(_ s: String) -> Bool { kind == .name && text == s }
    func isKeyword(_ s: String) -> Bool { kind == .keyword && text == s }
}

nonisolated enum Keywords {
    static let all: Set<String> = Set((
        "actor any as associatedtype async await break case catch class continue default defer deinit do else enum " +
        "extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is " +
        "isolated lazy let mutating nil nonisolated open operator optional override private protocol public repeat " +
        "required rethrows return self Self set some static struct subscript super switch throw throws true try " +
        "typealias var weak where while willSet didSet get set"
    ).split(separator: " ").map(String.init))
}

nonisolated struct Lexer {
    private let source: [Character]
    private var index = 0
    private var line = 1
    private var tokens: [Token] = []

    init(_ source: String) {
        self.source = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    static func tokens(_ source: String) throws -> [Token] {
        var lexer = Lexer(source)
        return try lexer.run()
    }

    private mutating func run() throws -> [Token] {
        while index < source.count {
            let c = source[index]
            if c == "\n" {
                tokens.append(Token(kind: .newline, text: "\n", line: line))
                line += 1
                index += 1
            } else if c == " " || c == "\t" {
                index += 1
            } else if c == "/" && peek(1) == "/" {
                while index < source.count && source[index] != "\n" { index += 1 }
            } else if c == "/" && peek(1) == "*" {
                try skipBlockComment()
            } else if c == "\"" {
                try readString()
            } else if c == "#" && peek(1) == "\"" {
                try readRawString()
            } else if c.isNumber {
                readNumber()
            } else if c.isLetter || c == "_" {
                readName()
            } else if c == "$" && peek(1)?.isNumber == true {
                let start = index
                index += 1
                while index < source.count && source[index].isNumber { index += 1 }
                tokens.append(Token(kind: .name, text: String(source[start..<index]), line: line))
            } else {
                readSymbol()
            }
        }
        tokens.append(Token(kind: .eof, text: "", line: line))
        return tokens
    }

    private func peek(_ offset: Int) -> Character? {
        let i = index + offset
        return i < source.count ? source[i] : nil
    }

    private mutating func skipBlockComment() throws {
        var depth = 0
        while index < source.count {
            if source[index] == "/" && peek(1) == "*" { depth += 1; index += 2; continue }
            if source[index] == "*" && peek(1) == "/" {
                depth -= 1; index += 2
                if depth == 0 { return }
                continue
            }
            if source[index] == "\n" { line += 1 }
            index += 1
        }
        throw SourceError("This comment is never closed.", line: line)
    }

    private mutating func readString() throws {
        let startLine = line
        let multiline = peek(1) == "\"" && peek(2) == "\""
        index += multiline ? 3 : 1
        var value = ""
        while index < source.count {
            let c = source[index]
            if multiline {
                if c == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                    index += 3
                    tokens.append(Token(kind: .string, text: value, line: startLine))
                    return
                }
            } else if c == "\"" {
                index += 1
                tokens.append(Token(kind: .string, text: value, line: startLine))
                return
            }
            if c == "\\" {
                let next = peek(1)
                switch next {
                case "n": value.append("\n"); index += 2
                case "t": value.append("\t"); index += 2
                case "\"": value.append("\""); index += 2
                case "\\": value.append("\\"); index += 2
                case "(":
                    // Keep the interpolation in the literal; the evaluator parses the inside.
                    value.append("\\(")
                    index += 2
                    var depth = 1
                    while index < source.count && depth > 0 {
                        let ch = source[index]
                        if ch == "(" { depth += 1 }
                        if ch == ")" { depth -= 1 }
                        if ch == "\n" { line += 1 }
                        if depth > 0 { value.append(ch) }
                        index += 1
                    }
                    value.append(")")
                default:
                    value.append(c)
                    index += 1
                }
            } else {
                if c == "\n" && !multiline { throw SourceError("This string is never closed.", line: startLine) }
                if c == "\n" { line += 1 }
                value.append(c)
                index += 1
            }
        }
        throw SourceError("This string is never closed.", line: startLine)
    }

    private mutating func readRawString() throws {
        let startLine = line
        let hashes = { () -> Int in
            var n = 0
            while self.index + n < self.source.count && self.source[self.index + n] == "#" { n += 1 }
            return n
        }()
        index += hashes + 1
        var value = ""
        let terminator = "\"" + String(repeating: "#", count: hashes)
        while index < source.count {
            if source[index] == "\"", String(source[index...]).hasPrefix(terminator) {
                index += terminator.count
                tokens.append(Token(kind: .string, text: value, line: startLine))
                return
            }
            if source[index] == "\n" { line += 1 }
            value.append(source[index])
            index += 1
        }
        throw SourceError("This string is never closed.", line: startLine)
    }

    private mutating func readNumber() {
        let start = index
        while index < source.count, source[index].isNumber || source[index] == "_" { index += 1 }
        if index < source.count, source[index] == ".", peek(1)?.isNumber == true {
            index += 1
            while index < source.count, source[index].isNumber || source[index] == "_" { index += 1 }
        }
        let text = String(source[start..<index]).replacingOccurrences(of: "_", with: "")
        tokens.append(Token(kind: .number, text: text, line: line))
    }

    private mutating func readName() {
        let start = index
        while index < source.count, source[index].isLetter || source[index].isNumber || source[index] == "_" { index += 1 }
        let text = String(source[start..<index])
        tokens.append(Token(kind: Keywords.all.contains(text) ? .keyword : .name, text: text, line: line))
    }

    private mutating func readSymbol() {
        let three: Set<String> = ["...", "..<", "===", "!=="]
        if index + 2 < source.count {
            let trio = String(source[index...index + 2])
            if three.contains(trio) {
                tokens.append(Token(kind: .symbol, text: trio, line: line))
                index += 3
                return
            }
        }
        let two: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "??", "->", "+=", "-=", "*=", "/=", "%=", "?."]
        if index + 1 < source.count {
            let pair = String(source[index...index + 1])
            if two.contains(pair) {
                tokens.append(Token(kind: .symbol, text: pair, line: line))
                index += 2
                return
            }
        }
        tokens.append(Token(kind: .symbol, text: String(source[index]), line: line))
        index += 1
    }
}

// MARK: - Syntax tree

nonisolated indirect enum Expr {
    case int(Int, line: Int)
    case double(Double, line: Int)
    case string(String, line: Int)
    case bool(Bool, line: Int)
    case none(line: Int)
    case name(String, line: Int)
    case array([Expr], line: Int)
    case dictionary([(key: Expr, value: Expr)], line: Int)
    case unary(String, Expr, line: Int)
    case binary(String, Expr, Expr, line: Int)
    case ternary(Expr, Expr, Expr, line: Int)
    case call(Expr, [Argument], trailing: ClosureValue?, line: Int)
    case member(Expr, String, optional: Bool, line: Int)
    case index(Expr, [Expr], line: Int)
    case force(Expr, line: Int)
    case assign(Expr, String, Expr, line: Int)
    case closure(ClosureValue, line: Int)
    case range(Expr, Expr, closed: Bool, line: Int)
    case selfValue(line: Int)
    case superValue(line: Int)
    case tryOptional(Expr, line: Int)
    case tryForced(Expr, line: Int)
    case keyPath(String, line: Int)
    case interpolated(String, line: Int)
    case opFunction(String, line: Int)

    var line: Int {
        switch self {
        case .int(_, let l), .double(_, let l), .string(_, let l), .bool(_, let l), .none(let l), .name(_, let l),
             .array(_, let l), .dictionary(_, let l), .unary(_, _, let l), .binary(_, _, _, let l),
             .ternary(_, _, _, let l), .call(_, _, _, let l), .member(_, _, _, let l), .index(_, _, let l),
             .force(_, let l), .assign(_, _, _, let l), .closure(_, let l), .range(_, _, _, let l),
             .selfValue(let l), .superValue(let l), .tryOptional(_, let l), .tryForced(_, let l), .keyPath(_, let l),
             .interpolated(_, let l), .opFunction(_, let l):
            l
        }
    }
}

nonisolated struct Argument {
    let label: String?
    let value: Expr
}

nonisolated struct ClosureValue {
    let params: [String]
    let body: [Stmt]
    let line: Int
}

nonisolated indirect enum Stmt {
    case letDecl(name: String, type: String?, value: Expr?, mutable: Bool, line: Int)
    case expr(Expr)
    case ifStmt([Condition], [Stmt], [Stmt]?, line: Int)
    case guardStmt([Condition], [Stmt], line: Int)
    case forIn(name: String, sequence: Expr, whereClause: Expr?, body: [Stmt], line: Int)
    case whileStmt(Expr, [Stmt], line: Int)
    case repeatWhile([Stmt], Expr, line: Int)
    case function(FunctionDecl)
    case structDecl(StructDecl)
    case classDecl(StructDecl)
    case enumDecl(EnumDecl)
    case returnStmt(Expr?, line: Int)
    case breakStmt(line: Int)
    case continueStmt(line: Int)
    case switchStmt(Expr, [SwitchCase], line: Int)
    case throwStmt(Expr, line: Int)
    case doCatch([Stmt], [CatchClause], line: Int)
}

nonisolated enum Condition {
    case expression(Expr)
    case optionalBinding(name: String, value: Expr, line: Int)
}

nonisolated struct FunctionDecl {
    let name: String
    let params: [Parameter]
    let returnType: String?
    let body: [Stmt]
    let line: Int
}

nonisolated struct Parameter {
    let label: String
    let name: String
    let type: String?
    let defaultValue: Expr?
    var variadic = false
}

nonisolated struct StructDecl {
    let name: String
    var fields: [Field]
    var methods: [FunctionDecl]
    var computed: [ComputedProperty] = []
    var initializers: [FunctionDecl] = []
    var staticFields: [Field] = []
    var staticMethods: [FunctionDecl] = []
    var deinitBody: [Stmt] = []
    var superclass: String? = nil
    var isClass = false
    let line: Int
}

nonisolated struct ComputedProperty {
    let name: String
    let body: [Stmt]
    let line: Int
}

nonisolated struct Field {
    let name: String
    let type: String
    let defaultValue: Expr?
    let mutable: Bool
}

nonisolated struct EnumDecl {
    let name: String
    let cases: [EnumCase]
    let line: Int
}

nonisolated struct EnumCase {
    let name: String
    let payload: [String]
    var rawValue: Int? = nil
}

nonisolated struct CatchClause {
    let pattern: Pattern?
    let body: [Stmt]
}

nonisolated struct SwitchCase {
    let patterns: [Pattern]
    let body: [Stmt]
}

nonisolated indirect enum Pattern {
    case wildcard
    case expression(Expr)
    case enumCase(String, binding: String?)
    case range(Expr, Expr, closed: Bool)
    case binding(String)
}
