// How an exercise is checked. On a Mac the learner's code goes to the real Swift compiler. On iPhone and iPad it goes
// to the on-device engine: a parser and evaluator for the teaching subset. No server, no network.
import Foundation

public nonisolated struct RunResult: Sendable {
    public struct TestResult: Sendable {
        public let text: String
        public let passed: Bool
        public init(text: String, passed: Bool) { self.text = text; self.passed = passed }
    }
    public struct CompilerError: Sendable, Hashable {
        public let line: Int?        // in the learner's code, from 1; nil when the problem is in the tests
        public let message: String
        public init(line: Int?, message: String) { self.line = line; self.message = message }
    }

    public var compiled = true
    public var errors: [CompilerError] = []
    public var output = ""
    public var crashed = false
    public var crashReason = ""
    public var timedOut = false
    public var tests: [TestResult] = []
    /// The code uses Swift this device cannot run. The lesson becomes an Xcode lab.
    public var unsupported = false

    public var passed: Bool { compiled && !timedOut && !crashed && !tests.isEmpty && tests.allSatisfy(\.passed) }

    public init(compiled: Bool = true, errors: [CompilerError] = [], output: String = "", crashed: Bool = false,
                crashReason: String = "", timedOut: Bool = false, tests: [TestResult] = [], unsupported: Bool = false) {
        self.compiled = compiled
        self.errors = errors
        self.output = output
        self.crashed = crashed
        self.crashReason = crashReason
        self.timedOut = timedOut
        self.tests = tests
        self.unsupported = unsupported
    }
}

public nonisolated protocol CodeRunner: Sendable {
    func check(_ lesson: Lesson, code: String) async throws -> RunResult
}

/// The regex checks a lesson writes for source and output. The same rules run on both platforms.
public nonisolated enum PatternMatch {
    public static func matches(_ pattern: String, in text: String) -> Bool {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

// MARK: - On device

/// Checks exercises with the teaching-subset interpreter. It never touches the network.
public nonisolated struct OnDeviceRunner: CodeRunner {
    public init() {}
    public func check(_ lesson: Lesson, code: String) async throws -> RunResult {
        var result = RunResult()
        var passed = Array(repeating: true, count: lesson.tests.count)

        for (i, test) in lesson.tests.enumerated() {
            for check in test.checks {
                switch check.kind {
                case .source: if !PatternMatch.matches(check.code, in: code) { passed[i] = false }
                case .nosource: if PatternMatch.matches(check.code, in: code) { passed[i] = false }
                default: break
                }
            }
        }

        let statements: [Stmt]
        do {
            statements = try Parser.parse(code)
        } catch let error as SourceError {
            result.compiled = false
            result.unsupported = error.unsupported
            result.errors = [.init(line: error.line, message: error.message)]
            result.tests = lesson.tests.map { .init(text: $0.text, passed: false) }
            return result
        }

        let interpreter = Interpreter()
        do {
            try interpreter.run(statements)
        } catch let error as SourceError {
            result.compiled = false
            result.unsupported = error.unsupported
            result.errors = [.init(line: error.line, message: error.message)]
            result.tests = lesson.tests.map { .init(text: $0.text, passed: false) }
            return result
        } catch let error as RuntimeError {
            if error.message.contains("ran for too long") {
                result.timedOut = true
            } else {
                result.crashed = true
                result.crashReason = error.description
            }
        } catch {
            result.crashed = true
            result.crashReason = error.localizedDescription
        }
        result.output = interpreter.output

        for (i, test) in lesson.tests.enumerated() {
            for check in test.checks {
                switch check.kind {
                case .output: if !PatternMatch.matches(check.code, in: result.output) { passed[i] = false }
                case .nooutput: if PatternMatch.matches(check.code, in: result.output) { passed[i] = false }
                case .swift:
                    do {
                        let checkStatements = try Parser.parse(check.code)
                        interpreter.resetExpectation()
                        try interpreter.run(checkStatements)
                        if interpreter.expectFailed { passed[i] = false }
                    } catch let error as SourceError where error.unsupported {
                        result.unsupported = true
                        passed[i] = false
                    } catch {
                        passed[i] = false
                    }
                case .source, .nosource: break
                }
            }
        }
        result.tests = zip(lesson.tests, passed).map { .init(text: $0.text, passed: $1) }
        return result
    }
}

// MARK: - The Mac's own compiler

#if os(macOS)
/// Runs exercises with the Swift compiler on this Mac.
public nonisolated struct LocalRunner: CodeRunner {
    public let toolchain: Toolchain
    public init(toolchain: Toolchain) { self.toolchain = toolchain }
    public func check(_ lesson: Lesson, code: String) async throws -> RunResult {
        await Runner.check(lesson, code: code, toolchain: toolchain)
    }
}

/// Where the Swift compiler is, and which version, or why it cannot be used.
public nonisolated struct Toolchain: Sendable {
    public let swiftc: String
    public let sdk: String
    public let version: String
    /// In the App Sandbox macOS will not run a program the app has just built, so the interpreter runs it instead.
    public var interpreter: String? = nil

    public var isRecentEnough: Bool { version.compare("6.2", options: .numeric) != .orderedAscending }

    public static var inSandbox: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    @concurrent
    public static func find() async -> Toolchain? {
        if inSandbox { return await findInSandbox() }
        guard (try? await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10))?.status == 0,
              let found = try? await Shell.run("/usr/bin/xcrun", ["--find", "swiftc"], timeout: 20), found.status == 0 else { return nil }
        let swiftc = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdkPath = try? await Shell.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], timeout: 20), sdkPath.status == 0,
              let v = try? await Shell.run(swiftc, ["--version"], timeout: 20) else { return nil }
        let sdk = sdkPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Toolchain(swiftc: swiftc, sdk: sdk, version: version(v.stdout + v.stderr))
    }

    @concurrent
    public static func findInSandbox() async -> Toolchain? {
        guard let selected = try? await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10), selected.status == 0 else { return nil }
        let dev = selected.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let xcode = (bin: dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin", sdk: dev + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        let tools = (bin: dev + "/usr/bin", sdk: dev + "/SDKs/MacOSX.sdk")
        let fm = FileManager.default
        guard let found = [xcode, tools].first(where: { fm.isExecutableFile(atPath: $0.bin + "/swift-frontend") && fm.fileExists(atPath: $0.sdk) }),
              let v = try? await Shell.run(found.bin + "/swiftc", ["--version"], timeout: 20) else { return nil }
        let toolchain = Toolchain(swiftc: found.bin + "/swiftc", sdk: found.sdk, version: version(v.stdout + v.stderr), interpreter: found.bin + "/swift-frontend")
        _ = await Runner.check(Lesson.warmUp, code: "print(1)", toolchain: toolchain, runTimeout: 120)
        return toolchain
    }

    private static func version(_ text: String) -> String {
        text.firstMatch(of: /Swift version (\d+\.\d+)/).map { String($0.1) } ?? "?"
    }
}

public nonisolated enum Runner {
    public static let prelude = """
    #if canImport(Darwin)
    import Darwin
    setvbuf(stdout, nil, _IOLBF, 0)
    #endif

    """
    public static var preludeLines: Int { prelude.components(separatedBy: "\n").count - 1 }

    public static func program(code: String, tests: [LessonTest], nonce: String) -> (source: String, firstLine: Int, testStart: Int) {
        var blocks: [String] = []
        for (i, test) in tests.enumerated() {
            for check in test.checks where check.kind == .swift {
                let body = check.code.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
                blocks.append("""
                do {
                    var __mnPass = true
                    func expect(_ condition: @autoclosure () throws -> Bool) { do { if try !condition() { __mnPass = false } } catch { __mnPass = false } }
                \(body)
                    print("\\u{1E}\(nonce) \(i) \\(__mnPass ? 1 : 0)")
                }
                """)
            }
        }
        let learner = code.replacingOccurrences(of: "\r", with: "")
        let testStart = preludeLines + learner.components(separatedBy: "\n").count + 2
        let source = prelude + learner + "\n\n// MARK: the lesson's tests\n" + blocks.joined(separator: "\n") + "\n"
        return (source, preludeLines + 1, testStart)
    }

    @concurrent
    public static func check(_ lesson: Lesson, code: String, toolchain: Toolchain, runTimeout: Double = 8) async -> RunResult {
        var result = RunResult()
        var passed = Array(repeating: true, count: lesson.tests.count)
        var swiftLeft = lesson.tests.map { $0.checks.filter { $0.kind == .swift }.count }

        for (i, test) in lesson.tests.enumerated() {
            for check in test.checks {
                if check.kind == .source, !PatternMatch.matches(check.code, in: code) { passed[i] = false }
                if check.kind == .nosource, PatternMatch.matches(check.code, in: code) { passed[i] = false }
            }
        }

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let built = program(code: code, tests: lesson.tests, nonce: nonce)
        let dir = FileManager.default.temporaryDirectory.appending(path: "zero-to-hero-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try built.source.write(to: dir.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        } catch {
            result.compiled = false
            result.errors = [.init(line: nil, message: "Could not write a temporary file: \(error.localizedDescription)")]
            result.tests = lesson.tests.map { .init(text: $0.text, passed: false) }
            return result
        }

        let settings = ["-sdk", toolchain.sdk, "-swift-version", "6", "-default-isolation", "MainActor",
                        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-Onone", "-module-name", "Lesson"]
        let run: Shell.Output?
        if let interpreter = toolchain.interpreter {
            let out = try? await Shell.run(interpreter, ["-frontend", "-interpret", "main.swift"] + settings, in: dir, timeout: runTimeout + 12)
            if let out, out.status != 0, !out.timedOut, out.stderr.contains(": error: ") {
                return failedToCompile(lesson, built: built, stderr: out.stderr, timedOut: false, passed: passed, swiftLeft: swiftLeft)
            }
            run = out
        } else {
            let compile = try? await Shell.run(toolchain.swiftc, settings + ["-o", "program", "main.swift"], in: dir, timeout: 60)
            let program = dir.appending(path: "program")
            guard let compile, compile.status == 0, FileManager.default.fileExists(atPath: program.path) else {
                return failedToCompile(lesson, built: built, stderr: compile?.stderr ?? "The compiler could not be started.",
                                       timedOut: compile?.timedOut ?? false, passed: passed, swiftLeft: swiftLeft)
            }
            run = try? await Shell.run(program.path, [], in: dir, timeout: runTimeout)
        }

        var shown: [Substring] = []
        for line in (run?.stdout ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\u{1E}\(nonce) ") {
                let parts = line.split(separator: " ")
                if parts.count == 3, let i = Int(parts[1]), i < passed.count {
                    swiftLeft[i] -= 1
                    if parts[2] != "1" { passed[i] = false }
                }
            } else {
                shown.append(line)
            }
        }
        result.output = shown.joined(separator: "\n").trimmingCharacters(in: .newlines)
        result.timedOut = run?.timedOut ?? false
        result.crashed = !result.timedOut && (run?.status ?? 1) != 0
        if result.crashed { result.crashReason = crashReason(run?.stderr ?? "") }

        for (i, test) in lesson.tests.enumerated() {
            if swiftLeft[i] > 0 { passed[i] = false }
            for check in test.checks {
                if check.kind == .output, !PatternMatch.matches(check.code, in: result.output) { passed[i] = false }
                if check.kind == .nooutput, PatternMatch.matches(check.code, in: result.output) { passed[i] = false }
            }
        }
        result.tests = zip(lesson.tests, passed).map { .init(text: $0.text, passed: $1) }
        return result
    }

    private static func failedToCompile(_ lesson: Lesson, built: (source: String, firstLine: Int, testStart: Int), stderr: String,
                                        timedOut: Bool, passed: [Bool], swiftLeft: [Int]) -> RunResult {
        var result = RunResult(), passed = passed
        result.compiled = false
        result.timedOut = timedOut
        result.errors = compilerErrors(stderr, firstLine: built.firstLine, testStart: built.testStart)
        for (i, test) in lesson.tests.enumerated() where swiftLeft[i] > 0 || test.checks.contains(where: { $0.kind == .output || $0.kind == .nooutput }) {
            passed[i] = false
        }
        result.tests = zip(lesson.tests, passed).map { .init(text: $0.text, passed: $1) }
        return result
    }

    public nonisolated static func compilerErrors(_ stderr: String, firstLine: Int, testStart: Int) -> [RunResult.CompilerError] {
        var out: [RunResult.CompilerError] = []
        for line in stderr.split(separator: "\n") {
            guard let m = line.firstMatch(of: /main\.swift:(\d+):(\d+): error: (.*)/), let n = Int(m.1) else { continue }
            out.append(n >= testStart ? .init(line: nil, message: "The tests could not use your code: " + m.3)
                                      : .init(line: n - firstLine + 1, message: String(m.3)))
        }
        if out.isEmpty, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.init(line: nil, message: stderr.split(separator: "\n").suffix(3).joined(separator: " ")))
        }
        return Array(out.prefix(12))
    }

    public nonisolated static func crashReason(_ stderr: String) -> String {
        if let m = stderr.firstMatch(of: /Fatal error: ([^\n]*)/) { return String(m.1) }
        return "Your program stopped unexpectedly."
    }
}

/// Runs a command and collects its output, stopping it after a timeout.
public nonisolated enum Shell {
    public struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data(), resumed = false
    }

    public nonisolated static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil, timeout: Double) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "USER", "LANG", "TMPDIR", "DEVELOPER_DIR"] { env[key] = ProcessInfo.processInfo.environment[key] }
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = Box(), limit = 256 * 1024
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            box.lock.withLock { if box.out.count < limit { box.out.append(d) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            box.lock.withLock { if box.err.count < limit { box.err.append(d) } }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
            let timedOut = Box()
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output: Output = box.lock.withLock {
                    box.out.append(restOut); box.err.append(restErr)
                    return Output(status: p.terminationStatus, stdout: String(decoding: box.out, as: UTF8.self),
                                  stderr: String(decoding: box.err, as: UTF8.self), timedOut: timedOut.lock.withLock { timedOut.resumed })
                }
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.lock.withLock { timedOut.resumed = true }
                kill(pid, SIGKILL)
            }
        }
    }
}
#endif
