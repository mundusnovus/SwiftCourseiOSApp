// A recursive-descent parser for the teaching subset. Unknown Swift is rejected with `unsupported: true`, never
// silently misread.
import Foundation

nonisolated struct Parser {
    private let tokens: [Token]
    private var index = 0
    private var grouping = 0
    private var allowTrailingClosure = true

    init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    static func parse(_ source: String) throws -> [Stmt] {
        var parser = Parser(try Lexer.tokens(source))
        return try parser.program()
    }

    static func parseExpression(_ source: String) throws -> Expr {
        var parser = Parser(try Lexer.tokens(source))
        parser.skipNewlines()
        return try parser.expression()
    }

    // MARK: - token helpers

    private var current: Token { tokens[min(index, tokens.count - 1)] }
    private var next: Token { tokens[min(index + 1, tokens.count - 1)] }

    @discardableResult private mutating func advance() -> Token {
        let token = current
        if token.kind != .eof { index += 1 }
        return token
    }

    private mutating func skipNewlines() {
        while current.kind == .newline { index += 1 }
    }

    private mutating func skipSeparators() {
        while current.kind == .newline || current.isSymbol(";") { index += 1 }
    }

    private mutating func match(_ symbol: String) -> Bool {
        if current.isSymbol(symbol) { index += 1; return true }
        return false
    }

    private mutating func match(keyword: String) -> Bool {
        if current.isKeyword(keyword) { index += 1; return true }
        return false
    }

    @discardableResult
    private mutating func expect(_ symbol: String, _ message: String) throws -> Token {
        guard current.isSymbol(symbol) else { throw error(message) }
        return advance()
    }

    private mutating func expect(name: String, _ message: String = "Expected a name.") throws -> Token {
        guard current.kind == .name else { throw error(message) }
        return advance()
    }

    private func error(_ message: String, unsupported: Bool = false) -> SourceError {
        SourceError(message, line: current.line, unsupported: unsupported)
    }

    // MARK: - statements

    mutating func program() throws -> [Stmt] {
        var out: [Stmt] = []
        skipSeparators()
        while current.kind != .eof {
            out.append(try statement())
            skipSeparators()
        }
        return out
    }

    private mutating func block() throws -> [Stmt] {
        try expect("{", "Expected { to start this block.")
        var out: [Stmt] = []
        skipSeparators()
        while !current.isSymbol("}") && current.kind != .eof {
            out.append(try statement())
            skipSeparators()
        }
        try expect("}", "Expected } to close this block.")
        return out
    }

    private mutating func statement() throws -> Stmt {
        skipNewlines()
        let token = current
        if token.kind == .keyword {
            switch token.text {
            case "let", "var": return try variableDeclaration()
            case "func": return .function(try functionDeclaration())
            case "struct": return .structDecl(try structDeclaration())
            case "enum": return .enumDecl(try enumDeclaration())
            case "if": return try ifStatement()
            case "guard": return try guardStatement()
            case "for": return try forStatement()
            case "while": return try whileStatement()
            case "repeat": return try repeatStatement()
            case "switch": return try switchStatement()
            case "return":
                advance()
                if current.kind == .newline {
                    let saved = index
                    skipNewlines()
                    if current.isSymbol("{") {
                        return .returnStmt(try expression(), line: token.line)
                    }
                    index = saved
                    return .returnStmt(nil, line: token.line)
                }
                if current.isSymbol("}") || current.kind == .eof { return .returnStmt(nil, line: token.line) }
                return .returnStmt(try expression(), line: token.line)
            case "break": advance(); return .breakStmt(line: token.line)
            case "continue": advance(); return .continueStmt(line: token.line)
            case "throw": advance(); return .throwStmt(try expression(), line: token.line)
            case "import":
                // import Foundation, import SwiftUI: no meaning in the sandbox.
                advance()
                while current.kind == .name || current.isSymbol(".") { advance() }
                return .expr(.none(line: token.line))
            case "class", "protocol", "extension", "actor", "typealias":
                throw error("\(token.text) is not supported on this device. Open this lesson in Xcode.", unsupported: true)
            case "private", "public", "internal", "fileprivate", "static", "mutating", "nonmutating", "final", "override", "required", "lazy", "weak", "unowned", "indirect", "convenience":
                advance()
                return try statement()
            case "init":
                throw error("A custom init is not supported here. Open this lesson in Xcode.", unsupported: true)
            case "defer":
                throw error("defer is not supported on this device. Open this lesson in Xcode.", unsupported: true)
            case "do", "try", "catch":
                throw error("Error handling is not supported on this device. Open this lesson in Xcode.", unsupported: true)
            case "async", "await":
                throw error("Concurrency is not supported on this device. Open this lesson in Xcode.", unsupported: true)
            default:
                break
            }
        }
        return .expr(try expression())
    }

    private mutating func variableDeclaration() throws -> Stmt {
        let keyword = advance()
        let mutable = keyword.text == "var"
        let name = try expect(name: "Expected a name after \(keyword.text).")
        var type: String?
        if match(":") { type = try typeName() }
        var value: Expr?
        if match("=") { value = try expression() }
        return .letDecl(name: name.text, type: type, value: value, mutable: mutable, line: keyword.line)
    }

    private mutating func functionDeclaration() throws -> FunctionDecl {
        let keyword = advance()
        let name = try expect(name: "Expected a function name.").text
        if current.isSymbol("<") {
            var depth = 0
            repeat {
                if current.isSymbol("<") { depth += 1 }
                if current.isSymbol(">") { depth -= 1 }
                advance()
            } while depth > 0 && current.kind != .eof
        }
        let params = try parameterList()
        var returnType: String?
        if match("->") { returnType = try typeName() }
        let body = try block()
        return FunctionDecl(name: name, params: params, returnType: returnType, body: body, line: keyword.line)
    }

    private mutating func parameterList() throws -> [Parameter] {
        try expect("(", "Expected ( after the function name.")
        var params: [Parameter] = []
        skipNewlines()
        while !current.isSymbol(")") {
            let first = try expect(name: "Expected a parameter name.")
            var label = first.text
            var name = first.text
            if current.kind == .name {
                label = first.text
                name = advance().text
            }
            var type: String?
            if match(":") {
                if current.isKeyword("inout") {
                    throw error("inout is not supported on this device. Open this lesson in Xcode.", unsupported: true)
                }
                type = try typeName()
            }
            var defaultValue: Expr?
            if match("=") { defaultValue = try expression() }
            let variadic = type?.hasSuffix("...") ?? false
            if variadic { type = String(type!.dropLast(3)) }
            params.append(Parameter(label: label, name: name, type: type, defaultValue: defaultValue, variadic: variadic))
            if !match(",") { break }
            skipNewlines()
        }
        try expect(")", "Expected ) to close the parameter list.")
        return params
    }

    /// Type names are only used for defaults and display; the engine is dynamically typed. Consume the shape.
    private mutating func typeName() throws -> String {
        var text = ""
        var depth = 0
        var parens = 0
        while true {
            let t = current
            if t.kind == .newline || t.kind == .eof { break }
            if t.isSymbol("->") || t.isSymbol("...") || t.isSymbol("..<") { text += advance().text; continue }
            if t.isSymbol("[") { depth += 1; text += advance().text; continue }
            if t.isSymbol("]") { depth -= 1; text += advance().text; continue }
            if t.isSymbol("(") { parens += 1; text += advance().text; continue }
            if t.isSymbol(")") {
                if parens == 0 { break }
                parens -= 1; text += advance().text; continue
            }
            if depth == 0 && parens == 0 {
                if t.isSymbol("=") || t.isSymbol(",") || t.isSymbol("{") || t.isSymbol("}") || t.isSymbol(";") { break }
            }
            if t.kind == .name || t.kind == .keyword || t.isSymbol(".") || t.isSymbol(":") || t.isSymbol("?") ||
                t.isSymbol("<") || t.isSymbol(">") || t.isSymbol("&") || t.isSymbol("(") {
                text += advance().text
                continue
            }
            break
        }
        return text
    }

    private mutating func structDeclaration() throws -> StructDecl {
        let keyword = advance()
        let name = try expect(name: "Expected a struct name.").text
        if match(":") { while !current.isSymbol("{") && current.kind != .eof { advance() } }
        try expect("{", "Expected { after the struct name.")
        var fields: [Field] = []
        var methods: [FunctionDecl] = []
        skipSeparators()
        while !current.isSymbol("}") && current.kind != .eof {
            if current.isKeyword("let") || current.isKeyword("var") {
                let fieldKeyword = advance()
                let fieldName = try expect(name: "Expected a property name.").text
                var type = ""
                var value: Expr?
                if match(":") { type = try typeName() }
                if match("=") { value = try expression() }
                if type.isEmpty && value == nil { throw error("A stored property needs a type or a value.") }
                fields.append(Field(name: fieldName, type: type, defaultValue: value, mutable: fieldKeyword.text == "var"))
            } else if current.isKeyword("func") {
                methods.append(try functionDeclaration())
            } else if current.isKeyword("init") {
                throw error("A custom init is not supported here. Open this lesson in Xcode.", unsupported: true)
            } else if current.isKeyword("static") {
                throw error("Static members are not supported on this device. Open this lesson in Xcode.", unsupported: true)
            } else if current.isKeyword("private") || current.isKeyword("public") || current.isKeyword("mutating") {
                advance()
                continue
            } else {
                throw error("Only stored properties and methods are supported in a struct here.", unsupported: true)
            }
            skipSeparators()
        }
        try expect("}", "Expected } to close the struct.")
        return StructDecl(name: name, fields: fields, methods: methods, line: keyword.line)
    }

    private mutating func enumDeclaration() throws -> EnumDecl {
        let keyword = advance()
        let name = try expect(name: "Expected an enum name.").text
        if match(":") { while !current.isSymbol("{") && current.kind != .eof { advance() } }
        try expect("{", "Expected { after the enum name.")
        var cases: [EnumCase] = []
        skipSeparators()
        while !current.isSymbol("}") && current.kind != .eof {
            guard current.isKeyword("case") else {
                if current.isKeyword("func") { throw error("Methods on enums are not supported on this device.", unsupported: true) }
                throw error("Only case declarations are supported in an enum here.", unsupported: true)
            }
            advance()
            while true {
                let caseName = try expect(name: "Expected a case name.").text
                var payload: [String] = []
                if match("(") {
                    while !current.isSymbol(")") {
                        if current.kind == .name {
                            let label = current.text
                            advance()
                            payload.append(label)
                            if match(":") { _ = try typeName() }
                        } else if current.isName("_") {
                            advance()
                            if match(":") { _ = try typeName() }
                        } else { break }
                        if !match(",") { break }
                    }
                    try expect(")", "Expected ) after the associated values.")
                }
                var rawValue: Int?
                if match("=") {
                    let value = try expression()
                    if case .int(let number, _) = value { rawValue = number }
                }
                cases.append(EnumCase(name: caseName, payload: payload, rawValue: rawValue))
                if !match(",") { break }
            }
            skipSeparators()
        }
        try expect("}", "Expected } to close the enum.")
        if cases.contains(where: { $0.rawValue != nil }) {
            var next = 1
            var filled: [EnumCase] = []
            for var item in cases {
                if let raw = item.rawValue { next = raw + 1 } else { item.rawValue = next; next += 1 }
                filled.append(item)
            }
            cases = filled
        }
        return EnumDecl(name: name, cases: cases, line: keyword.line)
    }

    private mutating func ifStatement() throws -> Stmt {
        let keyword = advance()
        let conditions = try conditions(until: "{")
        let body = try block()
        var otherwise: [Stmt]?
        skipNewlines()
        if current.isKeyword("else") {
            advance()
            skipNewlines()
            if current.isKeyword("if") {
                otherwise = [try ifStatement()]
            } else {
                otherwise = try block()
            }
        }
        return .ifStmt(conditions, body, otherwise, line: keyword.line)
    }

    private mutating func guardStatement() throws -> Stmt {
        let keyword = advance()
        let conditions = try conditions(until: "else")
        guard current.isKeyword("else") else { throw error("guard needs an else block.") }
        advance()
        let body = try block()
        return .guardStmt(conditions, body, line: keyword.line)
    }

    private mutating func conditions(until terminator: String) throws -> [Condition] {
        var out: [Condition] = []
        while true {
            skipNewlines()
            if terminator == "{", current.isSymbol("{") { break }
            if terminator == "else", current.isKeyword("else") { break }
            if current.isKeyword("let"), next.kind == .name {
                let line = advance().line
                let name = advance().text
                let value: Expr = match("=") ? try expression() : .name(name, line: line)
                out.append(.optionalBinding(name: name, value: value, line: line))
            } else {
                out.append(.expression(try expression()))
            }
            if !match(",") { break }
        }
        return out
    }

    private mutating func controlExpression() throws -> Expr {
        let saved = allowTrailingClosure
        allowTrailingClosure = false
        defer { allowTrailingClosure = saved }
        return try expression()
    }

    private mutating func forStatement() throws -> Stmt {
        let keyword = advance()
        if current.isKeyword("try") || current.isKeyword("await") {
            throw error("Only a plain for-in loop is supported here.", unsupported: true)
        }
        let name = try expect(name: "Expected a loop variable.").text
        guard current.isKeyword("in") else { throw error("Expected in after the loop variable.") }
        advance()
        let sequence = try controlExpression()
        let body = try block()
        return .forIn(name: name, sequence: sequence, body: body, line: keyword.line)
    }

    private mutating func whileStatement() throws -> Stmt {
        let keyword = advance()
        let condition = try controlExpression()
        let body = try block()
        return .whileStmt(condition, body, line: keyword.line)
    }

    private mutating func repeatStatement() throws -> Stmt {
        let keyword = advance()
        let body = try block()
        guard current.isKeyword("while") else { throw error("repeat needs a while condition.") }
        advance()
        let condition = try expression()
        return .repeatWhile(body, condition, line: keyword.line)
    }

    private mutating func switchStatement() throws -> Stmt {
        let keyword = advance()
        let subject = try controlExpression()
        try expect("{", "Expected { after the switch value.")
        skipSeparators()
        var cases: [SwitchCase] = []
        while !current.isSymbol("}") && current.kind != .eof {
            var patterns: [Pattern] = []
            if current.isKeyword("default") {
                advance()
                patterns = [.wildcard]
            } else {
                guard current.isKeyword("case") else { throw error("Expected case or default in a switch.") }
                advance()
                while true {
                    patterns.append(try pattern())
                    if !match(",") { break }
                }
                if current.isKeyword("where") {
                    throw error("A where clause in a switch is not supported on this device.", unsupported: true)
                }
            }
            try expect(":", "Expected : after the case.")
            skipSeparators()
            var body: [Stmt] = []
            while !current.isKeyword("case") && !current.isKeyword("default") && !current.isSymbol("}") && current.kind != .eof {
                body.append(try statement())
                skipSeparators()
            }
            cases.append(SwitchCase(patterns: patterns, body: body))
        }
        try expect("}", "Expected } to close the switch.")
        return .switchStmt(subject, cases, line: keyword.line)
    }

    private mutating func pattern() throws -> Pattern {
        if current.isName("_") { advance(); return .wildcard }
        if current.isSymbol("."), next.kind == .name {
            advance()
            let name = advance().text
            if current.isSymbol("(") {
                advance()
                var binding: String?
                if current.isName("let") { advance() }
                if current.kind == .name {
                    binding = advance().text
                    if match(":") { _ = try typeName() }
                }
                try expect(")", "Expected ) after the case value.")
                return .enumCase(name, binding: binding)
            }
            return .enumCase(name, binding: nil)
        }
        if current.isKeyword("let") {
            advance()
            let name = try expect(name: "Expected a name after let.").text
            return .binding(name)
        }
        let expr = try expression(minPrecedence: 6)
        if current.isSymbol("...") || current.isSymbol("..<") {
            let op = advance().text
            let upper = try expression()
            return .range(expr, upper, closed: op == "...")
        }
        return .expression(expr)
    }

    // MARK: - expressions

    private static let precedence: [String: Int] = [
        "=": 0, "+=": 0, "-=": 0, "*=": 0, "/=": 0, "%=": 0,
        "??": 1, "||": 2, "&&": 3,
        "==": 4, "!=": 4, "<": 4, ">": 4, "<=": 4, ">=": 4,
        "...": 5, "..<": 5,
        "+": 6, "-": 6,
        "*": 7, "/": 7, "%": 7,
    ]

    mutating func expression(minPrecedence: Int = 0) throws -> Expr {
        var left = try unary()
        while true {
            let token = current
            if token.kind == .newline && grouping == 0 { break }
            if token.isSymbol("...") && next.isSymbol("{") {
                advance()
                left = .range(left, .int(Int.max, line: token.line), closed: true, line: token.line)
                break
            }
            if token.isSymbol("?") && minPrecedence <= 1 {
                advance()
                let a = try expression()
                try expect(":", "Expected : in a ternary expression.")
                let b = try expression()
                left = .ternary(left, a, b, line: token.line)
                continue
            }
            guard token.kind == .symbol, let prec = Self.precedence[token.text] else { break }
            if prec < minPrecedence { break }
            // An assignment only makes sense to a name, a member or a subscript.
            if prec == 0 {
                switch left {
                case .name, .member, .index, .selfValue: break
                default: throw error("Only a variable, property or element can be assigned to.")
                }
                advance()
                let value = try expression(minPrecedence: 0)
                left = .assign(left, token.text, value, line: token.line)
                continue
            }
            advance()
            let right = try expression(minPrecedence: prec + 1)
            left = .binary(token.text, left, right, line: token.line)
        }
        return left
    }

    private mutating func unary() throws -> Expr {
        let token = current
        if token.isSymbol("-") || token.isSymbol("!") || token.isSymbol("+") {
            advance()
            return .unary(token.text, try unary(), line: token.line)
        }
        if token.isKeyword("try") || token.isKeyword("await") || token.isKeyword("some") || token.isKeyword("any") {
            advance()
            return try unary()
        }
        if token.isSymbol("&") {
            advance()
            return try unary()
        }
        if token.isKeyword("true") { advance(); return .bool(true, line: token.line) }
        if token.isKeyword("false") { advance(); return .bool(false, line: token.line) }
        if token.isKeyword("nil") { advance(); return .none(line: token.line) }
        if token.isKeyword("self") { advance(); return .selfValue(line: token.line) }
        return try postfix()
    }

    private mutating func postfix() throws -> Expr {
        var expr = try primary()
        while true {
            let token = current
            if token.isSymbol("(") {
                let args = try arguments()
                var trailing: ClosureValue?
                if allowTrailingClosure, current.isSymbol("{"), token.line == current.line || true {
                    trailing = try closure()
                }
                expr = .call(expr, args, trailing: trailing, line: token.line)
                continue
            }
            if token.isSymbol("[") {
                advance()
                var indices: [Expr] = []
                while !current.isSymbol("]") {
                    if (current.kind == .name || current.kind == .keyword), next.isSymbol(":") { advance(); advance() }
                    indices.append(try expression())
                    if !match(",") { break }
                }
                try expect("]", "Expected ] after a subscript.")
                expr = .index(expr, indices, line: token.line)
                continue
            }
            if token.isSymbol(".") || token.isSymbol("?.") {
                advance()
                let optional = token.text == "?."
                guard current.kind == .name || current.kind == .keyword else { throw error("Expected a member name after .") }
                let name = advance()
                expr = .member(expr, name.text, optional: optional, line: token.line)
                continue
            }
            if token.isSymbol("!") {
                advance()
                expr = .force(expr, line: token.line)
                continue
            }
            // A trailing closure on a member call: `names.map { $0.uppercased() }`
            if token.isSymbol("{"), allowTrailingClosure, case .member = expr {
                let c = try closure()
                expr = .call(expr, [], trailing: c, line: token.line)
                continue
            }
            break
        }
        return expr
    }

    private mutating func arguments() throws -> [Argument] {
        try expect("(", "Expected (.")
        var args: [Argument] = []
        skipNewlines()
        while !current.isSymbol(")") {
            var label: String?
            if (current.kind == .name || current.isName("_")), next.isSymbol(":") {
                label = advance().text
                advance()
            }
            if current.kind == .symbol, ["+", "-", "*", "/", "%", "<", ">", "==", "&&", "||"].contains(current.text),
               next.isSymbol(",") || next.isSymbol(")") {
                args.append(Argument(label: label, value: .opFunction(advance().text, line: current.line)))
            } else {
                args.append(Argument(label: label, value: try expression()))
            }
            if !match(",") { break }
            skipNewlines()
        }
        try expect(")", "Expected ) after the arguments.")
        return args
    }

    private mutating func primary() throws -> Expr {
        let token = current
        switch token.kind {
        case .number:
            advance()
            if let i = Int(token.text) { return .int(i, line: token.line) }
            if let d = Double(token.text) { return .double(d, line: token.line) }
            throw error("That number is not valid.")
        case .string:
            advance()
            return .string(token.text, line: token.line)
        case .name:
            advance()
            // A generic type used as a value: Optional<String>.self, Set<Character>.self.
            if current.isSymbol("<") {
                var depth = 0
                repeat {
                    if current.isSymbol("<") { depth += 1 }
                    if current.isSymbol(">") { depth -= 1 }
                    advance()
                } while depth > 0 && current.kind != .eof
            }
            return .name(token.text, line: token.line)
        case .keyword:
            switch token.text {
            case "true": advance(); return .bool(true, line: token.line)
            case "false": advance(); return .bool(false, line: token.line)
            case "nil": advance(); return .none(line: token.line)
            case "self": advance(); return .selfValue(line: token.line)
            default:
                throw error("\(token.text) is not supported in an expression here.", unsupported: true)
            }
        case .symbol:
            if token.isSymbol("(") {
                advance()
                grouping += 1
                skipNewlines()
                let first = try expression()
                // A tuple is rare in the course; a parenthesised expression is the common case.
                if current.isSymbol(",") {
                    var values = [first]
                    while match(",") { skipNewlines(); values.append(try expression()) }
                    try expect(")", "Expected ) after the values.")
                    grouping -= 1
                    return .array(values, line: token.line)
                }
                skipNewlines()
                try expect(")", "Expected ) to close the expression.")
                grouping -= 1
                return first
            }
            if token.isSymbol("[") {
                advance()
                grouping += 1
                skipNewlines()
                if current.isSymbol(":") {
                    advance(); try expect("]", "Expected ] after [:"); grouping -= 1
                    return .dictionary([], line: token.line)
                }
                var elements: [Expr] = []
                var pairs: [(key: Expr, value: Expr)] = []
                var isDictionary = false
                while !current.isSymbol("]") {
                    let first = try expression()
                    if match(":") {
                        isDictionary = true
                        pairs.append((first, try expression()))
                    } else {
                        elements.append(first)
                    }
                    if !match(",") { break }
                    skipNewlines()
                }
                try expect("]", "Expected ] after the collection.")
                grouping -= 1
                return isDictionary ? .dictionary(pairs, line: token.line) : .array(elements, line: token.line)
            }
            if token.isSymbol("{") {
                let c = try closure()
                return .closure(c, line: token.line)
            }
            if token.isSymbol("."), next.kind == .name {
                advance()
                let name = try expect(name: "Expected a case name after .")
                return .member(.name("", line: token.line), name.text, optional: false, line: token.line)
            }
        case .newline, .eof:
            throw error("Expected a value.")
        }
        throw error("Unexpected \(token.text.isEmpty ? "end of code" : "“\(token.text)”").")
    }

    private mutating func closure() throws -> ClosureValue {
        let open = current
        try expect("{", "Expected { to start the closure.")
        let saved = index
        var params: [String] = []
        var parsedParams = false
        // Try `a, b in` or `(a: Int, b: Int) in`.
        if current.isSymbol("(") {
            advance()
            while !current.isSymbol(")") {
                if current.kind == .name { params.append(advance().text) }
                else { advance() }
                if !match(",") { break }
            }
            if current.isSymbol(")") { advance() }
            if current.isKeyword("in") {
                advance()
                parsedParams = true
            } else {
                index = saved
                params = []
            }
        } else {
            while current.kind == .name || current.isName("_") {
                params.append(advance().text)
                if !match(",") { break }
            }
            if current.isKeyword("in") {
                advance()
                parsedParams = true
            } else {
                index = saved
                params = []
            }
        }
        var body: [Stmt] = []
        skipSeparators()
        while !current.isSymbol("}") && current.kind != .eof {
            body.append(try statement())
            skipSeparators()
        }
        try expect("}", "Expected } to close the closure.")
        _ = parsedParams
        return ClosureValue(params: params, body: body, line: open.line)
    }
}
