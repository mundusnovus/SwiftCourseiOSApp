// A tree-walking evaluator for the teaching subset: values, functions, structs, enums, optionals, collections and
// closures. It is deliberately small. Anything outside the subset throws `unsupported`, and the app offers the lesson
// as an Xcode lab instead of pretending to run it.
import Foundation

// MARK: - Values

nonisolated final class ArrayRef {
    var items: [Value]
    /// True for a Set: same storage, different type name and uniqueness rules.
    var isSet = false
    init(_ items: [Value], isSet: Bool = false) { self.items = items; self.isSet = isSet }
}

nonisolated final class DictRef {
    var items: [String: Value]
    init(_ items: [String: Value]) { self.items = items }
}

nonisolated final class InstanceRef {
    let typeName: String
    var fields: [String: Value]
    let isClass: Bool
    init(typeName: String, fields: [String: Value], isClass: Bool = false) {
        self.typeName = typeName
        self.fields = fields
        self.isClass = isClass
    }
}

nonisolated struct EnumRef {
    let typeName: String
    let caseName: String
    var payload: [Value]
}

nonisolated enum TypeRef {
    case builtin(String)
    case structure(StructDecl)
    case enumeration(EnumDecl)
}

nonisolated indirect enum Value {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array(ArrayRef)
    case dictionary(DictRef)
    case none
    case function(Function)
    case instance(InstanceRef)
    case enumeration(EnumRef)
    case type(TypeRef)
    case range(Int, Int, Bool)
    case void
}

nonisolated final class Scope {
    var vars: [String: Value] = [:]
    weak var parent: Scope?

    init(parent: Scope? = nil) { self.parent = parent }

    func lookup(_ name: String) -> Value? {
        if let v = vars[name] { return v }
        return parent?.lookup(name)
    }

    func define(_ name: String, _ value: Value) { vars[name] = value }

    @discardableResult
    func set(_ name: String, _ value: Value) -> Bool {
        if vars[name] != nil { vars[name] = value; return true }
        return parent?.set(name, value) ?? false
    }
}

nonisolated final class Function {
    let params: [Parameter]
    let body: [Stmt]
    let closure: Scope
    let owner: InstanceRef?
    let native: (([Value], Int) throws -> Value)?

    init(params: [Parameter] = [], body: [Stmt] = [], closure: Scope, owner: InstanceRef? = nil,
         native: (([Value], Int) throws -> Value)? = nil) {
        self.params = params
        self.body = body
        self.closure = closure
        self.owner = owner
        self.native = native
    }

    func bound(to instance: InstanceRef) -> Function {
        Function(params: params, body: body, closure: closure, owner: instance, native: native)
    }
}

nonisolated struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "line \(line): \(message)" }
}

nonisolated struct TimeoutError: Error {}

nonisolated struct ThrownError: Error {
    let value: Value
    let line: Int
}

// MARK: - Interpreter

nonisolated final class Interpreter {
    let globals = Scope()
    private(set) var scope: Scope
    private var selfStack: [InstanceRef] = []
    private var structures: [String: StructDecl] = [:]
    private var enumerations: [String: EnumDecl] = [:]

    private(set) var stdout = ""
    private var steps = 0
    private let stepLimit: Int
    private(set) var expectFailed = false
    private var suppressOutput = false

    init(stepLimit: Int = 1_500_000) {
        self.stepLimit = stepLimit
        self.scope = globals
        installBuiltins()
    }

    var output: String { stdout }

    func resetExpectation() { expectFailed = false }

    // MARK: running

    func run(_ statements: [Stmt]) throws {
        _ = try runBody(statements)
    }

    @discardableResult
    private func runBody(_ statements: [Stmt]) throws -> Flow {
        for statement in statements {
            let flow = try execute(statement)
            if case .normal = flow { continue }
            return flow
        }
        return .normal
    }

    enum Flow {
        case normal
        case returnValue(Value)
        case breakLoop
        case continueLoop
    }

    private func tick(_ line: Int) throws {
        steps += 1
        if steps > stepLimit { throw RuntimeError(message: "This code ran for too long. Is there a loop that never ends?", line: line) }
    }

    private func execute(_ statement: Stmt) throws -> Flow {
        switch statement {
        case .letDecl(let name, let type, let value, _, let line):
            try tick(line)
            let resolved = try value.map { try copyValue(try evaluate($0)) } ?? defaultValue(for: type, line: line)
            if let type, type.hasPrefix("Set<"), case .array(let array) = resolved { array.isSet = true }
            scope.define(name, coerce(resolved, to: type))
            return .normal

        case .expr(let expr):
            _ = try evaluate(expr)
            return .normal

        case .ifStmt(let conditions, let body, let otherwise, let line):
            try tick(line)
            let outer = scope
            let inner = Scope(parent: outer)
            scope = inner
            defer { scope = outer }
            if try check(conditions) {
                return try runBody(body)
            } else if let otherwise {
                return try runBody(otherwise)
            }
            return .normal

        case .guardStmt(let conditions, let body, let line):
            try tick(line)
            if try check(conditions) { return .normal }
            let flow = try runBody(body)
            if case .normal = flow { throw RuntimeError(message: "A guard’s else block must return or stop.", line: line) }
            return flow

        case .forIn(let name, let sequence, let whereClause, let body, let line):
            try tick(line)
            let value = try evaluate(sequence)
            if case .range(let lower, let upper, let closed) = value {
                let last = closed ? upper : upper - 1
                var n = lower
                while n <= last {
                    try tick(line)
                    let outer = scope
                    let inner = Scope(parent: outer)
                    inner.define(name, .int(n))
                    scope = inner
                    if let whereClause, try !truth(evaluate(whereClause), line: line) { scope = outer; n += 1; continue }
                    let flow = try runBody(body)
                    scope = outer
                    switch flow {
                    case .normal, .continueLoop: break
                    case .breakLoop: return .normal
                    case .returnValue: return flow
                    }
                    n += 1
                }
                return .normal
            }
            let items: [Value]
            switch value {
            case .array(let a): items = a.items
            case .dictionary(let d): items = d.items.keys.sorted().map { Value.string($0) }
            case .string(let s): items = s.map { Value.string(String($0)) }
            default: throw RuntimeError(message: "A for loop needs a collection or a range.", line: line)
            }
            for item in items {
                try tick(line)
                let outer = scope
                let inner = Scope(parent: outer)
                inner.define(name, copyValue(item))
                scope = inner
                if let whereClause, try !truth(evaluate(whereClause), line: line) { scope = outer; continue }
                let flow = try runBody(body)
                scope = outer
                switch flow {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case .returnValue: return flow
                }
            }
            return .normal

        case .whileStmt(let condition, let body, let line):
            while true {
                try tick(line)
                guard try truth(evaluate(condition), line: line) else { break }
                let flow = try runBody(body)
                switch flow {
                case .normal, .continueLoop: continue
                case .breakLoop: break
                case .returnValue: return flow
                }
                break
            }
            return .normal

        case .repeatWhile(let body, let condition, let line):
            while true {
                try tick(line)
                let flow = try runBody(body)
                switch flow {
                case .returnValue: return flow
                case .breakLoop: return .normal
                case .normal, .continueLoop: break
                }
                guard try truth(evaluate(condition), line: line) else { break }
            }
            return .normal

        case .function(let decl):
            globals.define(decl.name, .function(Function(params: decl.params, body: decl.body, closure: globals)))
            return .normal

        case .structDecl(let decl):
            structures[decl.name] = decl
            globals.define(decl.name, .type(.structure(decl)))
            return .normal

        case .classDecl(let decl):
            structures[decl.name] = decl
            globals.define(decl.name, .type(.structure(decl)))
            return .normal

        case .enumDecl(let decl):
            enumerations[decl.name] = decl
            globals.define(decl.name, .type(.enumeration(decl)))
            return .normal

        case .returnStmt(let expr, let line):
            try tick(line)
            return .returnValue(try expr.map { try copyValue(try evaluate($0)) } ?? .void)

        case .breakStmt: return .breakLoop
        case .continueStmt: return .continueLoop

        case .switchStmt(let subject, let cases, let line):
            try tick(line)
            let value = try evaluate(subject)
            for item in cases {
                for pattern in item.patterns {
                    let (matched, binding) = try match(pattern, value, line: line)
                    if matched {
                        let outer = scope
                        let inner = Scope(parent: outer)
                        scope = inner
                        if let binding { inner.define(binding, boundValue(pattern, value)) }
                        let flow = try runBody(item.body)
                        scope = outer
                        if case .breakLoop = flow { return .normal }
                        if case .returnValue = flow { return flow }
                        return .normal
                    }
                }
            }
            return .normal

        case .throwStmt(let expr, let line):
            throw ThrownError(value: try evaluate(expr), line: line)

        case .doCatch(let body, let catches, _):
            let outer = scope
            do {
                let inner = Scope(parent: outer)
                scope = inner
                let flow = try runBody(body)
                scope = outer
                return flow
            } catch let thrown as ThrownError {
                scope = outer
                for clause in catches {
                    let pattern = clause.pattern ?? .wildcard
                    let (matched, binding) = try match(pattern, thrown.value, line: thrown.line)
                    guard matched else { continue }
                    let inner = Scope(parent: outer)
                    scope = inner
                    if let binding { inner.define(binding, boundValue(pattern, thrown.value)) }
                    let flow = try runBody(clause.body)
                    scope = outer
                    return flow
                }
                throw thrown
            }
        }
    }

    private func boundValue(_ pattern: Pattern, _ value: Value) -> Value {
        if case .enumCase(_, _) = pattern, case .enumeration(let e) = value, let first = e.payload.first { return first }
        return value
    }

    /// Whether the pattern matches, and the name it binds (if any).
    private func match(_ pattern: Pattern, _ value: Value, line: Int) throws -> (Bool, String?) {
        switch pattern {
        case .wildcard:
            return (true, nil)
        case .binding(let name):
            return (true, name)
        case .expression(let expr):
            let other = try evaluate(expr)
            return (valuesEqual(value, other), nil)
        case .range(let lowerExpr, let upperExpr, let closed):
            guard case .int(let n) = value else { return (false, nil) }
            let lower = try intValue(try evaluate(lowerExpr), line: line)
            let upper = try intValue(try evaluate(upperExpr), line: line)
            let inside = closed ? (n >= lower && n <= upper) : (n >= lower && n < upper)
            return (inside, nil)
        case .enumCase(let name, let binding):
            guard case .enumeration(let e) = value, e.caseName == name else { return (false, nil) }
            return (true, binding)
        }
    }

    private func check(_ conditions: [Condition]) throws -> Bool {
        for condition in conditions {
            switch condition {
            case .expression(let expr):
                guard try truth(evaluate(expr), line: expr.line) else { return false }
            case .optionalBinding(let name, let value, _):
                let evaluated = try evaluate(value)
                if case .none = evaluated { return false }
                scope.define(name, copyValue(evaluated))
            }
        }
        return true
    }

    // MARK: expressions

    func evaluate(_ expr: Expr) throws -> Value {
        try tick(expr.line)
        switch expr {
        case .int(let n, _): return .int(n)
        case .double(let d, _): return .double(d)
        case .string(let raw, let line): return .string(try interpolate(raw, line: line))
        case .interpolated(let raw, let line): return .string(try interpolate(raw, line: line))
        case .bool(let b, _): return .bool(b)
        case .none: return .none
        case .name(let name, let line):
            if let value = scope.lookup(name) { return value }
            if let instance = selfStack.last, let field = instance.fields[name] { return field }
            throw RuntimeError(message: "“\(name)” is not defined yet.", line: line)
        case .keyPath(let name, _):
            return .function(Function(closure: globals, native: { args, line in
                try self.member(of: args[0], name: name, line: line)
            }))
        case .tryOptional(let inner, _):
            do { return try evaluate(inner) } catch is ThrownError { return .none }
        case .tryForced(let inner, let line):
            do { return try evaluate(inner) } catch is ThrownError {
                throw RuntimeError(message: "A forced try failed.", line: line)
            }
        case .selfValue(let line):
            guard let instance = selfStack.last else { throw RuntimeError(message: "self is not available here.", line: line) }
            return .instance(instance)
        case .superValue(let line):
            guard let instance = selfStack.last else { throw RuntimeError(message: "super is not available here.", line: line) }
            return .instance(instance)
        case .array(let items, _): return .array(ArrayRef(try items.map { try evaluate($0) }))
        case .dictionary(let pairs, let line):
            var out: [String: Value] = [:]
            for pair in pairs {
                let key = try evaluate(pair.key)
                guard case .string(let s) = key else { throw RuntimeError(message: "A dictionary key must be text here.", line: line) }
                out[s] = try evaluate(pair.value)
            }
            return .dictionary(DictRef(out))
        case .unary(let op, let value, let line):
            let v = try evaluate(value)
            switch op {
            case "-": return try negate(v, line: line)
            case "+": return v
            case "!": return .bool(!(try truth(v, line: line)))
            default: throw RuntimeError(message: "Unknown operator \(op).", line: line)
            }
        case .binary(let op, let left, let right, let line):
            if op == "&&" {
                guard try truth(evaluate(left), line: line) else { return .bool(false) }
                return .bool(try truth(evaluate(right), line: line))
            }
            if op == "||" {
                if try truth(evaluate(left), line: line) { return .bool(true) }
                return .bool(try truth(evaluate(right), line: line))
            }
            if op == "..." || op == "..<" {
                let l = try intValue(try evaluate(left), line: line)
                let r = try intValue(try evaluate(right), line: line)
                return .range(l, r, op == "...")
            }
            if op == "??" {
                let l = try evaluate(left)
                if case .none = l { return try evaluate(right) }
                return l
            }
            return try binary(op, try evaluate(left), try evaluate(right), line: line)
        case .ternary(let condition, let a, let b, let line):
            return try truth(evaluate(condition), line: line) ? evaluate(a) : evaluate(b)
        case .call(let callee, let args, let trailing, let line):
            if case .name("print", _) = callee {
                return try runPrint(args, trailing: trailing, line: line)
            }
            if case .member(.superValue, "init", _, _) = callee {
                return try runSuperInit(try args.map { try evaluate($0.value) }, line: line)
            }
            if case .member(.name("Task", _), "sleep", _, _) = callee {
                return .void
            }
            if case .member(.selfValue, "init", _, _) = callee {
                return try runSelfInit(try args.map { try evaluate($0.value) }, labels: args.map(\.label), line: line)
            }
            let function: Value
            if case .name(let calleeName, _) = callee, scope.lookup(calleeName) == nil, let instance = selfStack.last {
                function = try member(of: .instance(instance), name: calleeName, line: line)
            } else {
                function = try evaluate(callee)
            }
            var values = try args.map { try evaluate($0.value) }
            if let trailing { values.append(.function(Function(params: trailing.params.map { Parameter(label: "_", name: $0, type: nil, defaultValue: nil) }, body: trailing.body, closure: scope))) }
            return try call(function, values, line: line, labels: args.map(\.label))
        case .member(let base, let name, let optional, let line):
            if case .name(let root, _) = base, root.isEmpty {
                // A leading-dot case such as `.red`. Infer the enum from the cases the program declares.
                let matches = enumerations.values.filter { $0.cases.contains { $0.name == name } }
                if let decl = matches.first {
                    return .enumeration(EnumRef(typeName: decl.name, caseName: name, payload: []))
                }
            }
            let value = try evaluate(base)
            if optional, case .none = value { return .none }
            return try member(of: value, name: name, line: line)
        case .index(let base, let indices, let line):
            let value = try evaluate(base)
            return try subscriptValue(value, indices.map { try evaluate($0) }, line: line)
        case .force(let inner, let line):
            let value = try evaluate(inner)
            if case .none = value { throw RuntimeError(message: "A nil value was unwrapped.", line: line) }
            return value
        case .assign(let target, let op, let valueExpr, let line):
            let newValue = try evaluate(valueExpr)
            switch target {
            case .name(let name, _):
                let old: Value
                if op == "=" {
                    old = scope.lookup(name) ?? selfStack.last?.fields[name] ?? .void
                } else {
                    if let existing = scope.lookup(name) { old = existing }
                    else if let field = selfStack.last?.fields[name] { old = field }
                    else { throw RuntimeError(message: "“\(name)” is not defined yet.", line: line) }
                }
                if name == "_" { return .void }
                let result = op == "=" ? newValue : try binary(String(op.dropLast()), old, newValue, line: line)
                if scope.set(name, copyValue(result)) {
                    if case .none = result, case .instance(let released) = old, released.isClass {
                        if !isReferenced(released, excluding: name) { try runDeinit(released, line: line) }
                    }
                    return .void
                }
                if let instance = selfStack.last, instance.fields[name] != nil {
                    instance.fields[name] = copyValue(result)
                    return .void
                }
                throw RuntimeError(message: "“\(name)” is not defined yet.", line: line)
            case .member(let base, let name, _, _):
                let object = try evaluate(base)
                let old: Value
                if op == "=" { old = .void } else {
                    old = try member(of: object, name: name, line: line)
                }
                let result = op == "=" ? newValue : try binary(String(op.dropLast()), old, newValue, line: line)
                try setMember(of: object, name: name, to: copyValue(result), line: line)
                return .void
            case .index(let base, let indices, _):
                let object = try evaluate(base)
                let index = try evaluate(indices[0])
                let old: Value
                if op == "=" { old = .void } else { old = try subscriptValue(object, [index], line: line) }
                let result = op == "=" ? newValue : try binary(String(op.dropLast()), old, newValue, line: line)
                try setSubscript(object, index, to: copyValue(result), line: line)
                return .void
            default:
                throw RuntimeError(message: "This cannot be assigned to.", line: line)
            }
        case .closure(let c, _):
            return .function(Function(params: c.params.map { Parameter(label: "_", name: $0, type: nil, defaultValue: nil) },
                                      body: c.body, closure: scope))
        case .range(let lower, let upper, let closed, let line):
            return .range(try intValue(try evaluate(lower), line: line), try intValue(try evaluate(upper), line: line), closed)
        case .opFunction(let op, _):
            return .function(Function(closure: globals, native: { args, line in
                guard args.count >= 2 else { return .none }
                return try self.binary(op, args[0], args[1], line: line)
            }))
        }
    }

    private func interpolate(_ raw: String, line: Int) throws -> String {
        guard raw.contains("\\(") else { return raw }
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\\", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "(" {
                var depth = 1
                var j = raw.index(i, offsetBy: 2)
                let start = j
                while j < raw.endIndex, depth > 0 {
                    if raw[j] == "(" { depth += 1 }
                    if raw[j] == ")" { depth -= 1 }
                    if depth > 0 { j = raw.index(after: j) }
                }
                let inner = String(raw[start..<j])
                let expression = try Parser.parseExpression(inner)
                out += display(try evaluate(expression))
                i = j < raw.endIndex ? raw.index(after: j) : j
            } else {
                out.append(raw[i])
                i = raw.index(after: i)
            }
        }
        return out
    }

    private func runPrint(_ args: [Argument], trailing: ClosureValue?, line: Int) throws -> Value {
        var values: [Value] = []
        var separator = " "
        var terminator = "\n"
        for arg in args {
            let value = try evaluate(arg.value)
            switch arg.label {
            case "separator": separator = display(value)
            case "terminator": terminator = display(value)
            default: values.append(value)
            }
        }
        if let trailing {
            let f = Function(params: trailing.params.map { Parameter(label: "_", name: $0, type: nil, defaultValue: nil) }, body: trailing.body, closure: scope)
            for value in values { _ = try call(.function(f), [value], line: line) }
        }
        stdout += values.map(display).joined(separator: separator) + terminator
        if stdout.count > 200_000 { stdout = String(stdout.prefix(200_000)) }
        return .void
    }

    // MARK: calls

    func call(_ value: Value, _ args: [Value], line: Int, labels: [String?] = []) throws -> Value {
        switch value {
        case .function(let function):
            return try invoke(function, args, line: line, labels: labels)
        case .type(let type):
            return try construct(type, args, line: line, labels: labels)
        case .enumeration(let e):
            return .enumeration(EnumRef(typeName: e.typeName, caseName: e.caseName, payload: args))
        default:
            throw RuntimeError(message: "This value cannot be called.", line: line)
        }
    }

    private func invoke(_ function: Function, _ args: [Value], line: Int, labels: [String?]) throws -> Value {
        if let native = function.native { return try native(args, line) }
        let local = Scope(parent: function.closure)
        var used = Array(repeating: false, count: args.count)
        for (index, param) in function.params.enumerated() {
            if param.variadic {
                let rest = args.enumerated().filter { !used[$0.offset] }.map { copyValue($0.element) }
                local.define(param.name, .array(ArrayRef(rest)))
                continue
            }
            if let position = args.indices.first(where: {
                let label = $0 < labels.count ? labels[$0] : nil
                return !used[$0] && (label == param.label || param.label == "_" || label == nil)
            }) {
                used[position] = true
                local.define(param.name, coerce(copyValue(args[position]), to: param.type))
            } else if let fallback = param.defaultValue {
                local.define(param.name, try evaluate(fallback))
            } else {
                throw RuntimeError(message: "\(functionName(function)) needs a value for “\(param.name)”.".replacingOccurrences(of: "()", with: ""), line: line)
            }
        }
        // Closure shorthands: $0, $1, …
        if function.params.isEmpty {
            for (i, arg) in args.enumerated() { local.define("$\(i)", copyValue(arg)) }
        }
        let outer = scope
        scope = local
        if let owner = function.owner { selfStack.append(owner) }
        defer {
            if function.owner != nil { selfStack.removeLast() }
            scope = outer
        }
        // Implicit return: a function whose body is one expression, or one switch, returns that value.
        if function.body.count == 1 {
            if case .expr(let expression) = function.body[0] { return try evaluate(expression) }
            if case .switchStmt(let subject, let cases, let line) = function.body[0] {
                return try switchValue(subject, cases, line: line)
            }
        }
        let flow = try runBody(function.body)
        if case .returnValue(let value) = flow { return value }
        return .void
    }

    private func switchValue(_ subject: Expr, _ cases: [SwitchCase], line: Int) throws -> Value {
        let value = try evaluate(subject)
        for item in cases {
            for pattern in item.patterns {
                let (matched, binding) = try match(pattern, value, line: line)
                if matched {
                    let outer = scope
                    let inner = Scope(parent: outer)
                    scope = inner
                    if let binding { inner.define(binding, boundValue(pattern, value)) }
                    defer { scope = outer }
                    if let last = item.body.last, case .expr(let expression) = last {
                        return try evaluate(expression)
                    }
                    let flow = try runBody(item.body)
                    if case .returnValue(let result) = flow { return result }
                    return .void
                }
            }
        }
        return .void
    }

    private func functionName(_ function: Function) -> String { "this function" }

    private func construct(_ type: TypeRef, _ args: [Value], line: Int, labels: [String?]) throws -> Value {
        switch type {
        case .builtin(let name):
            return try builtinConstruct(name, args, line: line)
        case .structure(let decl):
            var fields: [String: Value] = [:]
            var chain: [StructDecl] = []
            var current: String? = decl.name
            while let name = current, let item = structures[name] {
                chain.insert(item, at: 0)
                current = item.superclass
            }
            for item in chain {
                for field in item.fields {
                    fields[field.name] = try field.defaultValue.map { coerce(try evaluate($0), to: field.type) } ?? defaultValue(for: field.type, line: line)
                }
            }
            if !decl.isClass && decl.initializers.isEmpty {
                for (index, field) in decl.fields.enumerated() where index < args.count {
                    fields[field.name] = coerce(args[index], to: field.type)
                }
            }
            let instance = InstanceRef(typeName: decl.name, fields: fields, isClass: decl.isClass)
            if let initializer = chooseInitializer(decl, labels: labels, count: args.count) {
                let f = Function(params: initializer.params, body: initializer.body, closure: globals, owner: instance)
                let flow = try invoke(f, args, line: line, labels: labels)
                if case .none = flow { return .none }
            }
            return .instance(instance)
        case .enumeration(let decl):
            if let first = args.first, case .int(let raw) = first,
               let item = decl.cases.first(where: { $0.rawValue == raw }) {
                return .enumeration(EnumRef(typeName: decl.name, caseName: item.name, payload: []))
            }
            guard let first = args.first, case .string(let caseName) = first else {
                throw RuntimeError(message: "\(decl.name) needs a case name.", line: line)
            }
            return .enumeration(EnumRef(typeName: decl.name, caseName: caseName, payload: Array(args.dropFirst())))
        }
    }

    private func builtinConstruct(_ name: String, _ args: [Value], line: Int) throws -> Value {
        guard let first = args.first else { return .none }
        switch name {
        case "String": return .string(display(first))
        case "Int":
            switch first {
            case .int(let n): return .int(n)
            case .double(let d): return .int(Int(d))
            case .string(let s): return Int(s).map(Value.int) ?? .none
            case .bool(let b): return .int(b ? 1 : 0)
            default: return .none
            }
        case "Double":
            switch first {
            case .int(let n): return .double(Double(n))
            case .double(let d): return .double(d)
            case .string(let s): return Double(s).map(Value.double) ?? .none
            default: return .none
            }
        case "Bool":
            switch first {
            case .bool(let b): return .bool(b)
            case .string(let s): return .bool(s == "true")
            case .int(let n): return .bool(n != 0)
            default: return .none
            }
        case "Array":
            if args.count == 2, case .int(let count) = args[1] {
                return .array(ArrayRef(Array(repeating: args[0], count: max(0, count))))
            }
            if args.count == 1, case .array(let a) = args[0] { return .array(ArrayRef(a.items)) }
            return .array(ArrayRef(args))
        case "Set":
            guard case .array(let a) = args.first ?? .none else { return .array(ArrayRef([], isSet: true)) }
            var seen: [Value] = []
            for item in a.items where !seen.contains(where: { self.valuesEqual($0, item) }) { seen.append(item) }
            return .array(ArrayRef(seen, isSet: true))
        default: return .none
        }
    }

    // MARK: members

    private func valueReferences(_ value: Value, _ instance: InstanceRef) -> Bool {
        switch value {
        case .instance(let other): return other === instance
        case .array(let array): return array.items.contains { valueReferences($0, instance) }
        case .dictionary(let dictionary): return dictionary.items.values.contains { valueReferences($0, instance) }
        default: return false
        }
    }

    private func isReferenced(_ instance: InstanceRef, excluding name: String) -> Bool {
        var current: Scope? = scope
        while let item = current {
            for (key, value) in item.vars where key != name {
                if valueReferences(value, instance) { return true }
            }
            current = item.parent
        }
        return false
    }

    private func runDeinit(_ instance: InstanceRef, line: Int) throws {
        var typeName: String? = instance.typeName
        while let name = typeName, let decl = structures[name] {
            if !decl.deinitBody.isEmpty {
                let function = Function(params: [], body: decl.deinitBody, closure: globals, owner: instance)
                _ = try invoke(function, [], line: line, labels: [])
                return
            }
            typeName = decl.superclass
        }
    }

    private func runSelfInit(_ args: [Value], labels: [String?], line: Int) throws -> Value {
        guard let instance = selfStack.last, let decl = structures[instance.typeName] else { return .void }
        let initializer = chooseInitializer(decl, labels: labels, count: args.count)
        guard let initializer else { return .void }
        let function = Function(params: initializer.params, body: initializer.body, closure: globals, owner: instance)
        _ = try invoke(function, args, line: line, labels: labels)
        return .void
    }

    private func chooseInitializer(_ decl: StructDecl, labels: [String?], count: Int) -> FunctionDecl? {
        let candidates = decl.initializers.filter { $0.params.count == count }
        return candidates.first { initializer in
            zip(initializer.params, labels).allSatisfy { param, label in
                label == nil || param.label == "_" || param.label == label
            }
        } ?? candidates.first ?? decl.initializers.first
    }

    private func runSuperInit(_ args: [Value], line: Int) throws -> Value {
        guard let instance = selfStack.last, let decl = structures[instance.typeName],
              let parent = decl.superclass, let superDecl = structures[parent],
              let initializer = superDecl.initializers.first else { return .void }
        let f = Function(params: initializer.params, body: initializer.body, closure: globals, owner: instance)
        _ = try invoke(f, args, line: line, labels: [])
        return .void
    }

    private func member(of value: Value, name: String, line: Int) throws -> Value {
        if name == "flatMap", case .array = value {
            // Array.flatMap is handled below; only optionals and other values use the generic form.
        } else if name == "flatMap" {
            return method(name) { args, l in
                if case .none = value { return .none }
                return try self.call(args[0], [value], line: l)
            }
        }
        switch value {
        case .string(let s):
            return try stringMember(s, name, line: line)
        case .array(let a):
            return try arrayMember(a, name, line: line)
        case .dictionary(let d):
            return try dictionaryMember(d, name, line: line)
        case .instance(let instance):
            if let field = instance.fields[name] { return field }
            var typeName: String? = instance.typeName
            while let current = typeName, let decl = structures[current] {
                if let method = decl.methods.first(where: { $0.name == name }) {
                    return .function(Function(params: method.params, body: method.body, closure: globals, owner: instance))
                }
                if let property = decl.computed.first(where: { $0.name == name }) {
                    let function = Function(params: [], body: property.body, closure: globals, owner: instance)
                    return try invoke(function, [], line: line, labels: [])
                }
                typeName = decl.superclass
            }
            throw RuntimeError(message: "\(instance.typeName) has no member “\(name)”.", line: line)
        case .type(.structure(let decl)):
            if let property = decl.staticFields.first(where: { $0.name == name }) {
                return try property.defaultValue.map { try evaluate($0) } ?? defaultValue(for: property.type, line: line)
            }
            if let method = decl.staticMethods.first(where: { $0.name == name }) {
                return .function(Function(params: method.params, body: method.body, closure: globals))
            }
            if let method = decl.methods.first(where: { $0.name == name }) {
                return .function(Function(params: method.params, body: method.body, closure: globals))
            }
            throw RuntimeError(message: "\(decl.name) has no member “\(name)”.", line: line)
        case .type(let type):
            if name == "self" { return .type(type) }
            if case .enumeration(let decl) = type {
                if name == "allCases" {
                    return .array(ArrayRef(decl.cases.map { .enumeration(EnumRef(typeName: decl.name, caseName: $0.name, payload: [])) }))
                }
                if decl.cases.contains(where: { $0.name == name }) {
                    return .enumeration(EnumRef(typeName: decl.name, caseName: name, payload: []))
                }
            }
            throw RuntimeError(message: "This type has no member “\(name)”.", line: line)
        case .enumeration(let e):
            if name == "rawValue" {
                if let decl = enumerations[e.typeName], let item = decl.cases.first(where: { $0.name == e.caseName }),
                   let raw = item.rawValue { return .int(raw) }
                return .string(e.caseName)
            }
            throw RuntimeError(message: "\(e.typeName).\(e.caseName) has no member “\(name)”.", line: line)
        case .range(let lower, let upper, let closed):
            if name == "count" { return .int(max(0, (closed ? upper : upper - 1) - lower + 1)) }
            if name == "isEmpty" { return .bool(lower > (closed ? upper : upper - 1)) }
            throw RuntimeError(message: "A range has no member “\(name)”.", line: line)
        default:
            throw RuntimeError(message: "This value has no member “\(name)”.", line: line)
        }
    }

    private func setMember(of value: Value, name: String, to newValue: Value, line: Int) throws {
        guard case .instance(let instance) = value else {
            throw RuntimeError(message: "Only a property of your own struct can be changed here.", line: line)
        }
        guard instance.fields[name] != nil else {
            throw RuntimeError(message: "\(instance.typeName) has no property “\(name)”.", line: line)
        }
        instance.fields[name] = newValue
    }

    private func subscriptValue(_ value: Value, _ indices: [Value], line: Int) throws -> Value {
        guard let index = indices.first else { throw RuntimeError(message: "A subscript needs an index.", line: line) }
        switch value {
        case .array(let a):
            let i = try intValue(index, line: line)
            guard i >= 0, i < a.items.count else { throw RuntimeError(message: "Index out of range.", line: line) }
            return a.items[i]
        case .dictionary(let d):
            guard case .string(let key) = index else { throw RuntimeError(message: "A dictionary key must be text here.", line: line) }
            return d.items[key] ?? (indices.count > 1 ? indices[1] : .none)
        case .string(let s):
            let i = try intValue(index, line: line)
            let characters = Array(s)
            guard i >= 0, i < characters.count else { throw RuntimeError(message: "Index out of range.", line: line) }
            return .string(String(characters[i]))
        default:
            throw RuntimeError(message: "This value cannot be indexed.", line: line)
        }
    }

    private func setSubscript(_ value: Value, _ index: Value, to newValue: Value, line: Int) throws {
        switch value {
        case .array(let a):
            let i = try intValue(index, line: line)
            guard i >= 0, i < a.items.count else { throw RuntimeError(message: "Index out of range.", line: line) }
            a.items[i] = newValue
        case .dictionary(let d):
            guard case .string(let key) = index else { throw RuntimeError(message: "A dictionary key must be text here.", line: line) }
            if case .none = newValue { d.items[key] = nil } else { d.items[key] = newValue }
        default:
            throw RuntimeError(message: "This value cannot be changed by index.", line: line)
        }
    }

    // MARK: operators

    private func binary(_ op: String, _ lhs: Value, _ rhs: Value, line: Int) throws -> Value {
        switch op {
        case "+":
            if case .string(let a) = lhs, case .string(let b) = rhs { return .string(a + b) }
            if case .array(let a) = lhs, case .array(let b) = rhs { return .array(ArrayRef(a.items + b.items)) }
            return try numeric("+", lhs, rhs, line: line)
        case "-": return try numeric("-", lhs, rhs, line: line)
        case "*": return try numeric("*", lhs, rhs, line: line)
        case "/": return try numeric("/", lhs, rhs, line: line)
        case "%": return try numeric("%", lhs, rhs, line: line)
        case "==": return .bool(valuesEqual(lhs, rhs))
        case "!=": return .bool(!valuesEqual(lhs, rhs))
        case "===":
            if case .instance(let a) = lhs, case .instance(let b) = rhs { return .bool(a === b) }
            return .bool(false)
        case "!==":
            if case .instance(let a) = lhs, case .instance(let b) = rhs { return .bool(a !== b) }
            return .bool(true)
        case "<", ">", "<=", ">=":
            if case .instance = lhs, case .instance = rhs {
                let less = try lessThan(lhs, rhs, line: line)
                switch op {
                case "<": return .bool(less)
                case ">": return .bool(try lessThan(rhs, lhs, line: line))
                case "<=": return .bool(!(try lessThan(rhs, lhs, line: line)))
                default: return .bool(!less)
                }
            }
            if case .string(let a) = lhs, case .string(let b) = rhs {
                switch op {
                case "<": return .bool(a < b)
                case ">": return .bool(a > b)
                case "<=": return .bool(a <= b)
                default: return .bool(a >= b)
                }
            }
            let (a, b) = try doubles(lhs, rhs, line: line)
            switch op {
            case "<": return .bool(a < b)
            case ">": return .bool(a > b)
            case "<=": return .bool(a <= b)
            default: return .bool(a >= b)
            }
        default:
            throw RuntimeError(message: "Unknown operator \(op).", line: line)
        }
    }

    private func numeric(_ op: String, _ lhs: Value, _ rhs: Value, line: Int) throws -> Value {
        if case .int(let a) = lhs, case .int(let b) = rhs {
            switch op {
            case "+": return .int(a + b)
            case "-": return .int(a - b)
            case "*": return .int(a * b)
            case "/":
                guard b != 0 else { throw RuntimeError(message: "Division by zero.", line: line) }
                return .int(a / b)
            case "%":
                guard b != 0 else { throw RuntimeError(message: "Division by zero.", line: line) }
                return .int(a % b)
            default: break
            }
        }
        let (a, b) = try doubles(lhs, rhs, line: line)
        switch op {
        case "+": return .double(a + b)
        case "-": return .double(a - b)
        case "*": return .double(a * b)
        case "/": return .double(a / b)
        default: throw RuntimeError(message: "Unknown operator \(op).", line: line)
        }
    }

    private func doubles(_ lhs: Value, _ rhs: Value, line: Int) throws -> (Double, Double) {
        func double(_ v: Value) throws -> Double {
            switch v {
            case .int(let n): return Double(n)
            case .double(let d): return d
            default: throw RuntimeError(message: "This needs two numbers.", line: line)
            }
        }
        return (try double(lhs), try double(rhs))
    }

    private func intValue(_ value: Value, line: Int) throws -> Int {
        switch value {
        case .int(let n): return n
        case .double(let d): return Int(d)
        default: throw RuntimeError(message: "This needs a whole number.", line: line)
        }
    }

    private func negate(_ value: Value, line: Int) throws -> Value {
        switch value {
        case .int(let n): return .int(-n)
        case .double(let d): return .double(-d)
        default: throw RuntimeError(message: "This needs a number.", line: line)
        }
    }

    private func truth(_ value: Value, line: Int) throws -> Bool {
        guard case .bool(let b) = value else { throw RuntimeError(message: "This needs a true or false value.", line: line) }
        return b
    }

    func valuesEqual(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.int(let x), .double(let y)): return Double(x) == y
        case (.double(let x), .int(let y)): return x == Double(y)
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.none, .none): return true
        case (.range(let a, let b, let c), .range(let d, let e, let f)): return a == d && b == e && c == f
        case (.type(let x), .type(let y)):
            switch (x, y) {
            case (.builtin(let a), .builtin(let b)): return a == b
            case (.structure(let a), .structure(let b)): return a.name == b.name
            case (.enumeration(let a), .enumeration(let b)): return a.name == b.name
            default: return false
            }
        case (.array(let x), .array(let y)):
            return x.items.count == y.items.count && zip(x.items, y.items).allSatisfy { valuesEqual($0, $1) }
        case (.dictionary(let x), .dictionary(let y)):
            return x.items.count == y.items.count && x.items.allSatisfy { key, value in
                y.items[key].map { valuesEqual(value, $0) } ?? false
            }
        case (.enumeration(let x), .enumeration(let y)):
            return x.typeName == y.typeName && x.caseName == y.caseName && x.payload.count == y.payload.count &&
                zip(x.payload, y.payload).allSatisfy { valuesEqual($0, $1) }
        case (.instance(let x), .instance(let y)):
            return x.typeName == y.typeName && x.fields.count == y.fields.count && x.fields.allSatisfy { key, value in
                y.fields[key].map { valuesEqual(value, $0) } ?? false
            }
        default: return false
        }
    }

    func display(_ value: Value) -> String {
        switch value {
        case .int(let n): return String(n)
        case .double(let d): return d == d.rounded() ? "\(Int(d)).0" : String(d)
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .none: return "nil"
        case .void: return ""
        case .array(let a): return "[" + a.items.map(display).joined(separator: ", ") + "]"
        case .dictionary(let d):
            return "[" + d.items.keys.sorted().map { "\"\($0)\": \(display(d.items[$0]!))" }.joined(separator: ", ") + "]"
        case .enumeration(let e):
            return e.payload.isEmpty ? e.caseName : "\(e.caseName)(\(e.payload.map(display).joined(separator: ", ")))"
        case .instance(let i):
            return i.typeName + "(" + i.fields.keys.sorted().map { "\($0): \(display(i.fields[$0]!))" }.joined(separator: ", ") + ")"
        case .function: return "(function)"
        case .type(let t):
            switch t {
            case .builtin(let name): return name
            case .structure(let d): return d.name
            case .enumeration(let d): return d.name
            }
        case .range(let a, let b, let c): return "\(a)\(c ? "..." : "..<")\(b)"
        }
    }

    private func copyValue(_ value: Value) -> Value {
        switch value {
        case .array(let a): return .array(ArrayRef(a.items.map(copyValue), isSet: a.isSet))
        case .dictionary(let d): return .dictionary(DictRef(d.items.mapValues(copyValue)))
        case .instance(let i): return i.isClass ? value : .instance(InstanceRef(typeName: i.typeName, fields: i.fields.mapValues(copyValue)))
        default: return value
        }
    }

    private func coerce(_ value: Value, to type: String?) -> Value {
        guard let type else { return value }
        switch type {
        case "Double":
            if case .int(let n) = value { return .double(Double(n)) }
            if case .string(let text) = value, let d = Double(text) { return .double(d) }
        case "Int":
            if case .double(let d) = value { return .int(Int(d)) }
            if case .string(let text) = value, let n = Int(text) { return .int(n) }
        case "String":
            if case .string = value { return value }
        default:
            if type.hasPrefix("[Double]"), case .array(let a) = value {
                return .array(ArrayRef(a.items.map { coerce($0, to: "Double") }))
            }
        }
        return value
    }

    private func defaultValue(for type: String?, line: Int) -> Value {
        guard let type else { return .none }
        switch type {
        case "Int": return .int(0)
        case "Double": return .double(0)
        case "Bool": return .bool(false)
        case "String": return .string("")
        default:
            if type.hasPrefix("Set<") { return .array(ArrayRef([], isSet: true)) }
            if type.hasPrefix("[") && type.contains(":") { return .dictionary(DictRef([:])) }
            if type.hasPrefix("[") { return .array(ArrayRef([])) }
            return .none
        }
    }

    // MARK: members for built-in types

    private func method(_ name: String, _ body: @escaping ([Value], Int) throws -> Value) -> Value {
        .function(Function(closure: globals, native: { args, line in try body(args, line) }))
    }

    private func stringMember(_ s: String, _ name: String, line: Int) throws -> Value {
        switch name {
        case "count": return .int(s.count)
        case "isEmpty": return .bool(s.isEmpty)
        case "isNumber": return .bool(s.count == 1 && s.first?.isNumber == true)
        case "isLetter": return .bool(s.count == 1 && s.first?.isLetter == true)
        case "isUppercase": return .bool(s.count == 1 && s == s.uppercased() && s != s.lowercased())
        case "isLowercase": return .bool(s.count == 1 && s == s.lowercased() && s != s.uppercased())
        case "isWhitespace": return .bool(s.count == 1 && s.first?.isWhitespace == true)
        case "first": return s.first.map { .string(String($0)) } ?? .none
        case "last": return s.last.map { .string(String($0)) } ?? .none
        case "uppercased": return method(name) { _, _ in .string(s.uppercased()) }
        case "lowercased": return method(name) { _, _ in .string(s.lowercased()) }
        case "hasPrefix": return method(name) { args, l in .bool(s.hasPrefix(try self.text(args[0], l))) }
        case "hasSuffix": return method(name) { args, l in .bool(s.hasSuffix(try self.text(args[0], l))) }
        case "contains": return method(name) { args, l in .bool(s.contains(try self.text(args[0], l))) }
        case "split":
            return method(name) { args, l in
                let separator = try self.text(args[0], l)
                return .array(ArrayRef(s.split(separator: Character(separator)).map { .string(String($0)) }))
            }
        case "replacingOccurrences":
            return method(name) { args, l in
                .string(s.replacingOccurrences(of: try self.text(args[0], l), with: try self.text(args[1], l)))
            }
        case "prefix":
            return method(name) { args, l in .string(String(s.prefix(try self.intValue(args[0], line: l)))) }
        case "suffix":
            return method(name) { args, l in .string(String(s.suffix(try self.intValue(args[0], line: l)))) }
        case "suffix":
            return method(name) { args, l in .string(String(s.suffix(try self.intValue(args[0], line: l)))) }
        case "trimmingCharacters":
            return method(name) { _, _ in .string(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case "map":
            return method(name) { args, l in
                let f = args[0]
                return .array(ArrayRef(try s.map { try self.call(f, [.string(String($0))], line: l) }))
            }
        case "allSatisfy":
            return method(name) { args, l in
                let f = args[0]
                for character in s {
                    if try !self.truth(self.call(f, [.string(String(character))], line: l), line: l) { return .bool(false) }
                }
                return .bool(true)
            }
        case "compactMap":
            return method(name) { args, l in
                let f = args[0]
                var out: [Value] = []
                for character in s {
                    let value = try self.call(f, [.string(String(character))], line: l)
                    if case .none = value { continue }
                    out.append(value)
                }
                return .array(ArrayRef(out))
            }
        case "components":
            return method(name) { args, l in
                .array(ArrayRef(s.components(separatedBy: try self.text(args[0], l)).map { .string($0) }))
            }
        default:
            throw RuntimeError(message: "Text has no member “\(name)” here.", line: line)
        }
    }

    private func arrayMember(_ a: ArrayRef, _ name: String, line: Int) throws -> Value {
        switch name {
        case "count": return .int(a.items.count)
        case "isEmpty": return .bool(a.items.isEmpty)
        case "first": return a.items.first ?? .none
        case "last": return a.items.last ?? .none
        case "max":
            return method(name) { args, l in
                if let f = args.first {
                    var best: Value?
                    for item in a.items {
                        guard let current = best else { best = item; continue }
                        if try self.truth(self.call(f, [current, item], line: l), line: l) { best = item }
                    }
                    return best ?? .none
                }
                var best: Value?
                for item in a.items {
                    if let current = best, try self.lessThan(current, item, line: l) { best = item }
                    else if best == nil { best = item }
                }
                return best ?? .none
            }
        case "min":
            return method(name) { args, l in
                if let f = args.first {
                    var best: Value?
                    for item in a.items {
                        guard let current = best else { best = item; continue }
                        if try self.truth(self.call(f, [item, current], line: l), line: l) { best = item }
                    }
                    return best ?? .none
                }
                var best: Value?
                for item in a.items {
                    if let current = best, try self.lessThan(item, current, line: l) { best = item }
                    else if best == nil { best = item }
                }
                return best ?? .none
            }
        case "append": return method(name) { args, l in a.items.append(try self.copyValue(args[0])); return .void }
        case "insert":
            return method(name) { args, l in
                guard let first = args.first else { return .void }
                if args.count == 1 {
                    if a.isSet, a.items.contains(where: { self.valuesEqual($0, first) }) { return .void }
                    a.items.append(try self.copyValue(first))
                    return .void
                }
                let index = try self.intValue(args[1], line: l)
                guard index >= 0, index <= a.items.count else { throw RuntimeError(message: "Index out of range.", line: l) }
                a.items.insert(try self.copyValue(first), at: index)
                return .void
            }
        case "remove":
            return method(name) { args, l in
                let index = try self.intValue(args[0], line: l)
                guard index >= 0, index < a.items.count else { throw RuntimeError(message: "Index out of range.", line: l) }
                return a.items.remove(at: index)
            }
        case "removeLast":
            return method(name) { _, l in
                guard !a.items.isEmpty else { throw RuntimeError(message: "There is nothing to remove.", line: l) }
                return a.items.removeLast()
            }
        case "removeFirst":
            return method(name) { _, l in
                guard !a.items.isEmpty else { throw RuntimeError(message: "There is nothing to remove.", line: l) }
                return a.items.removeFirst()
            }
        case "contains":
            return method(name) { args, _ in .bool(a.items.contains { self.valuesEqual($0, args[0]) }) }
        case "union", "intersection", "subtracting":
            return method(name) { args, _ in
                guard case .array(let other) = args.first ?? .none else { return .array(ArrayRef(a.items)) }
                var out: [Value] = []
                switch name {
                case "union":
                    out = a.items
                    for item in other.items where !out.contains(where: { self.valuesEqual($0, item) }) { out.append(item) }
                case "intersection":
                    out = a.items.filter { item in other.items.contains { self.valuesEqual($0, item) } }
                default:
                    out = a.items.filter { item in !other.items.contains { self.valuesEqual($0, item) } }
                }
                return .array(ArrayRef(out))
            }
        case "sort":
            return method(name) { _, _ in
                a.items.sort { self.compare($0, $1) < 0 }
                return .void
            }
        case "joined":
            return method(name) { args, l in
                let separator = args.first.map { try? self.text($0, l) } ?? ""
                return .string(a.items.map(self.display).joined(separator: separator ?? ""))
            }
        case "map":
            return method(name) { args, l in
                let f = args[0]
                return .array(ArrayRef(try a.items.map { try self.call(f, [try self.copyValue($0)], line: l) }))
            }
        case "filter":
            return method(name) { args, l in
                let f = args[0]
                var out: [Value] = []
                for item in a.items where try self.truth(self.call(f, [try self.copyValue(item)], line: l), line: l) {
                    out.append(item)
                }
                return .array(ArrayRef(out))
            }
        case "reduce":
            return method(name) { args, l in
                let f = args[1]
                var result = args[0]
                for item in a.items {
                    result = try self.call(f, [result, try self.copyValue(item)], line: l)
                }
                return result
            }
        case "sorted":
            return method(name) { args, l in
                if args.isEmpty {
                    return .array(ArrayRef(try a.items.sorted { try self.lessThan($0, $1, line: l) }))
                }
                let f = args[0]
                let sorted = try a.items.sorted { lhs, rhs in
                    try self.truth(self.call(f, [try self.copyValue(lhs), try self.copyValue(rhs)], line: l), line: l)
                }
                return .array(ArrayRef(sorted))
            }
        case "reversed":
            return .array(ArrayRef(a.items.reversed()))
        case "suffix":
            return method(name) { args, l in
                let n = try self.intValue(args[0], line: l)
                return .array(ArrayRef(Array(a.items.suffix(max(0, n)))))
            }
        case "prefix":
            return method(name) { args, l in
                let n = try self.intValue(args[0], line: l)
                return .array(ArrayRef(Array(a.items.prefix(max(0, n)))))
            }
        case "enumerated":
            return .array(ArrayRef(a.items.enumerated().map { .array(ArrayRef([.int($0.offset), $0.element])) }))
        case "allSatisfy":
            return method(name) { args, l in
                let f = args[0]
                for item in a.items where try !self.truth(self.call(f, [try self.copyValue(item)], line: l), line: l) {
                    return .bool(false)
                }
                return .bool(true)
            }
        case "compactMap":
            return method(name) { args, l in
                let f = args[0]
                var out: [Value] = []
                for item in a.items {
                    let value = try self.call(f, [try self.copyValue(item)], line: l)
                    if case .none = value { continue }
                    out.append(value)
                }
                return .array(ArrayRef(out))
            }
        case "flatMap":
            return method(name) { args, l in
                let f = args[0]
                var out: [Value] = []
                for item in a.items {
                    let value = try self.call(f, [try self.copyValue(item)], line: l)
                    if case .array(let inner) = value { out.append(contentsOf: inner.items) }
                }
                return .array(ArrayRef(out))
            }
        default:
            throw RuntimeError(message: "An array has no member “\(name)” here.", line: line)
        }
    }

    private func dictionaryMember(_ d: DictRef, _ name: String, line: Int) throws -> Value {
        switch name {
        case "count": return .int(d.items.count)
        case "isEmpty": return .bool(d.items.isEmpty)
        case "keys": return .array(ArrayRef(d.items.keys.sorted().map { .string($0) }))
        case "values": return .array(ArrayRef(d.items.keys.sorted().map { d.items[$0]! }))
        case "mapValues":
            return method(name) { args, l in
                let f = args[0]
                var out: [String: Value] = [:]
                for (key, value) in d.items { out[key] = try self.call(f, [try self.copyValue(value)], line: l) }
                return .dictionary(DictRef(out))
            }
        case "filter":
            return method(name) { args, l in
                let f = args[0]
                var out: [String: Value] = [:]
                for (key, value) in d.items {
                    let pair = Value.instance(InstanceRef(typeName: "Dictionary.Element",
                                                          fields: ["key": .string(key), "value": try self.copyValue(value)]))
                    if try self.truth(self.call(f, [pair], line: l), line: l) { out[key] = value }
                }
                return .dictionary(DictRef(out))
            }
        case "map":
            return method(name) { args, l in
                let f = args[0]
                var out: [Value] = []
                for (key, value) in d.items {
                    let pair = Value.instance(InstanceRef(typeName: "Dictionary.Element",
                                                          fields: ["key": .string(key), "value": try self.copyValue(value)]))
                    out.append(try self.call(f, [pair], line: l))
                }
                return .array(ArrayRef(out))
            }
        default:
            throw RuntimeError(message: "A dictionary has no member “\(name)” here.", line: line)
        }
    }

    private func lessThan(_ a: Value, _ b: Value, line: Int) throws -> Bool {
        if case .instance(let x) = a, case .instance(let y) = b {
            var typeName: String? = x.typeName
            while let name = typeName, let decl = structures[name] {
                if let method = decl.staticMethods.first(where: { $0.name == "<" }) {
                    let function = Function(params: method.params, body: method.body, closure: globals)
                    let value = try invoke(function, [a, b], line: line, labels: [])
                    return try truth(value, line: line)
                }
                typeName = decl.superclass
            }
        }
        return compare(a, b) < 0
    }

    private func compare(_ a: Value, _ b: Value) -> Int {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.double(let x), .double(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        case (.int(let x), .double(let y)): return Double(x) == y ? 0 : (Double(x) < y ? -1 : 1)
        case (.double(let x), .int(let y)): return x == Double(y) ? 0 : (x < Double(y) ? -1 : 1)
        case (.string(let x), .string(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        default: return display(a) == display(b) ? 0 : (display(a) < display(b) ? -1 : 1)
        }
    }

    private func text(_ value: Value, _ line: Int) throws -> String {
        guard case .string(let s) = value else { throw RuntimeError(message: "This needs text.", line: line) }
        return s
    }

    // MARK: builtins

    private func installBuiltins() {
        globals.define("print", .function(Function(closure: globals, native: { args, _ in
            var separator = " "
            var terminator = "\n"
            var values: [Value] = []
            for arg in args { values.append(arg) }
            // The parser keeps labels, so the caller passes separator/terminator as ordinary trailing arguments.
            if values.count >= 3, case .string(let s) = values[values.count - 2], case .string(let t) = values[values.count - 1] {
                separator = s; terminator = t
                values.removeLast(2)
            }
            self.stdout += values.map(self.display).joined(separator: separator) + terminator
            if self.stdout.count > 200_000 { self.stdout = String(self.stdout.prefix(200_000)) }
            return .void
        })))

        globals.define("expect", .function(Function(closure: globals, native: { args, line in
            let ok = try self.truth(args.first ?? .bool(false), line: line)
            if !ok { self.expectFailed = true }
            return .void
        })))

        globals.define("abs", .function(Function(closure: globals, native: { args, line in
            switch args[0] {
            case .int(let n): return .int(abs(n))
            case .double(let d): return .double(abs(d))
            default: throw RuntimeError(message: "abs needs a number.", line: line)
            }
        })))

        globals.define("min", .function(Function(closure: globals, native: { args, line in
            guard args.count >= 2 else { throw RuntimeError(message: "min needs two values.", line: line) }
            return self.valuesEqual(args[0], args[1]) ? args[0] : (self.display(args[0]) < self.display(args[1]) ? args[0] : args[1])
        })))

        globals.define("max", .function(Function(closure: globals, native: { args, line in
            guard args.count >= 2 else { throw RuntimeError(message: "max needs two values.", line: line) }
            return self.valuesEqual(args[0], args[1]) ? args[0] : (self.display(args[0]) > self.display(args[1]) ? args[0] : args[1])
        })))

        globals.define("stride", .function(Function(closure: globals, native: { args, line in
            guard args.count >= 3 else { return .array(ArrayRef([])) }
            let start = try self.intValue(args[0], line: line)
            let end = try self.intValue(args[1], line: line)
            let step = try self.intValue(args[2], line: line)
            guard step != 0 else { return .array(ArrayRef([])) }
            var out: [Value] = []
            var n = start
            while step > 0 ? n <= end : n >= end {
                out.append(.int(n))
                n += step
                if out.count > 10_000 { break }
            }
            return .array(ArrayRef(out))
        })))

        for name in ["String", "Int", "Double", "Bool", "Array", "Optional", "Set"] {
            globals.define(name, .type(.builtin(name)))
        }

        globals.define("type", .function(Function(closure: globals, native: { args, _ in
            guard let value = args.first else { return .none }
            switch value {
            case .int: return .type(.builtin("Int"))
            case .double: return .type(.builtin("Double"))
            case .string: return .type(.builtin("String"))
            case .bool: return .type(.builtin("Bool"))
            case .array(let a): return .type(.builtin(a.isSet ? "Set" : "Array"))
            case .dictionary: return .type(.builtin("Dictionary"))
            case .enumeration(let e): return .type(.builtin(e.typeName))
            case .instance(let i): return .type(.builtin(i.typeName))
            default: return .type(.builtin("Optional"))
            }
        })))
    }
}
