// A lesson: reading with quizzes and checklists, or a code lesson with the editor, tests and console.
import SwiftUI
import AppIntents
import ZeroToHeroKit
#if os(iOS)
import UIKit
#endif

struct LessonView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson

    var body: some View {
        Group {
            if lesson.hasCode && (DeviceSupport.isRunnable(lesson.id) || model.hasCompiler) {
                CodeLessonView(lesson: lesson)
            } else if lesson.hasCode {
                LabLessonView(lesson: lesson)
            } else {
                ReadingLessonView(lesson: lesson)
            }
        }
        .userActivity("technology.asteria.zerotohero.lesson", element: lesson.id) { id, activity in
            activity.title = lesson.title
            activity.userInfo = ["lesson": id]
            activity.isEligibleForHandoff = true
            // "This lesson" for Siri and Apple Intelligence: the screen is about this entity.
            activity.appEntityIdentifier = EntityIdentifier(for: LessonEntity.self, identifier: id)
        }
    }
}

extension Lesson.Kind {
    var tint: Color {
        switch self {
        case .quiz: Palette.gold
        case .lab, .project, .workshop: Palette.sea
        case .xcode: Palette.emphasis
        case .lesson: .secondary
        }
    }
}

struct KindBadge: View {
    let kind: Lesson.Kind
    var body: some View {
        Text(kind.label.uppercased())
            .font(.reading(.caption2, weight: .bold)).tracking(0.8)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(kind.tint.opacity(0.15), in: .capsule)
            .foregroundStyle(kind.tint)
    }
}

struct LessonHeader: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    private var compact: Bool { widthClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let place = model.course.module(of: lesson.id) {
                Text("\(place.chapter.title)  ›  \(place.module.title)")
                    .font(.reading(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                KindBadge(kind: lesson.type)
                if model.store.isDone(lesson.id) {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly).foregroundStyle(Palette.sea).font(.title3)
                        .accessibilityLabel("Done")
                }
            }
            Text(lesson.title)
                .font(.reading(compact ? .title : .largeTitle, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("About \(lesson.minutes) minutes")
                .font(.reading(.caption)).foregroundStyle(.secondary)
        }
    }
}

struct LessonFooter: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson

    var body: some View {
        let neighbours = model.course.neighbours(of: lesson.id)
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 4)
            if let next = neighbours.next {
                Button { model.open(next) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NEXT LESSON").font(.reading(.caption2, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                            Text(next.title).font(.reading(.callout, weight: .semibold)).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glassProminent)
            }
            if let previous = neighbours.previous {
                Button { model.open(previous) } label: {
                    Label("Previous: \(previous.title)", systemImage: "chevron.left").lineLimit(1)
                }
                .buttonStyle(.borderless)
                .font(.reading(.callout))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Reading lessons

struct ReadingLessonView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson
    @State private var showReview = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    private var compact: Bool { widthClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LessonHeader(lesson: lesson)
                BlocksView(blocks: lesson.description)
                if !lesson.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your task").font(.reading(.title3, weight: .semibold))
                        BlocksView(blocks: lesson.instructions)
                    }
                    .padding(16)
                    .background(Palette.sea.opacity(0.07), in: .rect(cornerRadius: 16))
                }
                if !lesson.checklist.isEmpty { ChecklistView(lesson: lesson) }
                if !lesson.questions.isEmpty { QuizView(lesson: lesson) }
                if lesson.checklist.isEmpty && lesson.questions.isEmpty && !model.store.isDone(lesson.id) {
                    Button("Mark as read") { model.store.complete(lesson.id); model.say("Lesson done") }
                        .buttonStyle(.glassProminent)
                }
                if model.store.isDone(lesson.id) {
                    HStack(spacing: 12) {
                        Image(systemName: "apple.intelligence").symbol().foregroundStyle(Palette.sea)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review this lesson").font(.reading(.callout, weight: .semibold))
                            Text("A short recap and three questions, written on this device.")
                                .font(.reading(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review") { showReview = true }.buttonStyle(.glass)
                    }
                    .padding(14)
                    .background(Palette.sea.opacity(0.07), in: .rect(cornerRadius: 14))
                }
                LessonFooter(lesson: lesson)
            }
            .padding(compact ? 18 : 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showReview) { LessonReviewSheet(lesson: lesson).appTint() }
    }
}

struct ChecklistView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson

    private var ticks: Set<Int> { model.store.ticks(for: lesson.id) }
    private var allTicked: Bool { ticks.count == lesson.checklist.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(lesson.type == .project ? "Your project" : "On your Mac", systemImage: "checklist")
                .font(.reading(.title3, weight: .semibold))
            ForEach(Array(lesson.checklist.enumerated()), id: \.offset) { index, item in
                Toggle(isOn: Binding(get: { ticks.contains(index) || model.store.isDone(lesson.id) },
                                     set: { _ in model.store.toggle(tick: index, for: lesson.id) })) {
                    Text(markdown(item)).font(.reading(.body)).fixedSize(horizontal: false, vertical: true)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            }
            if lesson.questions.isEmpty && !model.store.isDone(lesson.id) {
                Button("Mark as done") { model.store.complete(lesson.id); model.say("Lesson done") }
                    .buttonStyle(.glassProminent)
                    .disabled(!allTicked)
            } else if !lesson.questions.isEmpty && !model.store.isDone(lesson.id) {
                Text("Tick these off, then answer the questions below to finish.")
                    .font(.reading(.callout)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 18))
    }
}

struct QuizView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson
    @State private var picks: [Int: Int] = [:]
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(lesson.type == .quiz ? "Questions" : "Check your understanding")
                .font(.reading(.title3, weight: .semibold))
            ForEach(Array(lesson.questions.enumerated()), id: \.offset) { qi, question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(markdown("\(qi + 1). " + question.question))
                        .font(.reading(.headline)).fixedSize(horizontal: false, vertical: true)
                    if !question.detail.isEmpty { BlocksView(blocks: question.detail) }
                    ForEach(Array(question.answers.enumerated()), id: \.offset) { ai, answer in
                        answerRow(qi, ai, answer)
                    }
                    if checked, let pick = picks[qi] {
                        let right = question.answers[pick].correct
                        Text(markdown((right ? "**Right.** " : "**Not quite.** ") + question.why))
                            .foregroundStyle(right ? Palette.seaText : Palette.alertText)
                            .font(.reading(.callout))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(model.store.isDone(lesson.id) ? "Check again" : "Check my answers", action: check)
                    .buttonStyle(.glassProminent)
                    .disabled(picks.count < lesson.questions.count)
                if checked, allRight {
                    Label("All right.", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.pass)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 18))
    }

    private func answerRow(_ qi: Int, _ ai: Int, _ answer: Question.Answer) -> some View {
        Button { picks[qi] = ai; checked = false } label: {
            HStack(spacing: 10) {
                Image(systemName: picks[qi] == ai ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picks[qi] == ai ? Palette.sea : Color.secondary)
                Text(markdown(answer.text))
                    .font(.reading(.body))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(11)
            .contentShape(.rect)
            .background(background(qi, ai), in: .rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picks[qi] == ai ? .isSelected : [])
    }

    private var allRight: Bool {
        lesson.questions.indices.allSatisfy { index in
            picks[index].map { lesson.questions[index].answers[$0].correct } ?? false
        }
    }

    private func background(_ qi: Int, _ ai: Int) -> Color {
        guard checked, picks[qi] == ai else { return Color.primary.opacity(0.04) }
        return lesson.questions[qi].answers[ai].correct ? Palette.sea.opacity(0.16) : Palette.alert.opacity(0.16)
    }

    private func check() {
        checked = true
        guard allRight else { model.say("Have another look at the ones marked."); return }
        if !lesson.checklist.isEmpty && model.store.ticks(for: lesson.id).count < lesson.checklist.count && !model.store.isDone(lesson.id) {
            model.say("All right. Tick off the checklist too.")
            return
        }
        model.store.complete(lesson.id)
        model.say("Lesson done")
    }
}

// MARK: - Xcode labs

/// A code lesson the on-device engine does not check yet. It still teaches, shows the tests, and is honest about where
/// the code has to run.
struct LabLessonView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    private var compact: Bool { widthClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LessonHeader(lesson: lesson)
                BlocksView(blocks: lesson.description)
                if !lesson.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your task").font(.reading(.title3, weight: .semibold))
                        BlocksView(blocks: lesson.instructions)
                    }
                    .padding(16)
                    .background(Palette.sea.opacity(0.07), in: .rect(cornerRadius: 16))
                }
                if let seed = lesson.seed, !seed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Starting code").font(.reading(.headline, weight: .semibold))
                        CodeBlock(code: seed)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("This one runs in Xcode", systemImage: "hammer")
                        .font(.reading(.headline, weight: .semibold))
                    Text("The full Swift compiler needs a Mac. Open this lesson in Xcode, write the code, and check it against the tests below. Then come back and mark it done.")
                        .font(.reading(.callout)).foregroundStyle(.secondary)
                    if !lesson.tests.isEmpty {
                        TestsList(tests: lesson.tests, results: nil)
                    }
                }
                .padding(16)
                .background(Palette.gold.opacity(0.1), in: .rect(cornerRadius: 16))
                if !lesson.checklist.isEmpty { ChecklistView(lesson: lesson) }
                if !lesson.questions.isEmpty { QuizView(lesson: lesson) }
                if !model.store.isDone(lesson.id) && lesson.questions.isEmpty && lesson.checklist.isEmpty {
                    Button("Mark as done") { model.store.complete(lesson.id); model.say("Lesson done") }
                        .buttonStyle(.glassProminent)
                }
                LessonFooter(lesson: lesson)
            }
            .padding(compact ? 18 : 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Code lessons

struct CodeLessonView: View {
    @Environment(AppModel.self) private var model
    let lesson: Lesson
    @AppStorage("editorFontSize") private var fontSize = 14.0

    @State private var code = ""
    @State private var result: RunResult?
    @State private var running = false
    @State private var problem: String?
    @State private var hintsShown = 0
    @State private var showingCode = false
    @State private var scrollLine: Int?
    @State private var showCoach = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var widthClass
    #endif

    private var compact: Bool {
        #if os(iOS)
        widthClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            HSplitView {
                instructions.frame(minWidth: 340, idealWidth: 460)
                workspace().frame(minWidth: 420)
            }
            #else
            GeometryReader { geo in
                if geo.size.width >= 780 {
                    HStack(spacing: 0) {
                        instructions.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        workspace().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Show", selection: $showingCode) {
                            Text("Lesson").tag(false)
                            Text("Code").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        if showingCode {
                            workspace(stacked: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            instructions.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            #endif
        }
        .onAppear {
            code = model.store.code(for: lesson)
            #if DEBUG
            if let index = Demo.arguments.firstIndex(of: "-codefile"), Demo.arguments.indices.contains(index + 1),
               let text = try? String(contentsOfFile: Demo.arguments[index + 1], encoding: .utf8) {
                code = text
            }
            #endif
        }
        .task {
            #if DEBUG
            if Demo.arguments.contains("-run") {
                try? await Task.sleep(for: .milliseconds(600))
                run()
            }
            #endif
        }
        .sheet(isPresented: $showCoach) { CodeCoachSheet(lesson: lesson, code: code, result: result).appTint() }
        .onChange(of: code) { _, new in model.store.setCode(new, for: lesson.id) }
        #if os(macOS)
        .focusedSceneValue(\.runAction, RunAction(run: run))
        .focusedSceneValue(\.resetAction, ResetAction(reset: reset))
        #endif
    }

    private var instructions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LessonHeader(lesson: lesson)
                BlocksView(blocks: lesson.description)
                if !lesson.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your task").font(.reading(.title3, weight: .semibold))
                        BlocksView(blocks: lesson.instructions)
                    }
                    .padding(16)
                    .background(Palette.sea.opacity(0.07), in: .rect(cornerRadius: 16))
                }
                TestsList(tests: lesson.tests, results: result?.tests)
                if !lesson.hints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<hintsShown, id: \.self) { index in
                            Label {
                                Text(markdown(lesson.hints[index])).font(.reading(.callout))
                            } icon: {
                                Image(systemName: "lightbulb").foregroundStyle(Palette.gold)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.gold.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        if hintsShown < lesson.hints.count {
                            Button("Get a hint", systemImage: "lightbulb") {
                                withAnimation { hintsShown += 1 }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                LessonFooter(lesson: lesson)
            }
            .padding(compact ? 16 : 28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func workspace(stacked: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("main.swift")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Palette.editorText.opacity(0.7))
                Spacer(minLength: 8)
                Button("Reset", action: reset).buttonStyle(.borderless).fixedSize()
                Button(action: run) {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .fixedSize()
                .buttonStyle(.glassProminent)
                .tint(Palette.sea)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(running)
                .help("Run your code and check it (⌘↩)")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.editorBackground)
            .environment(\.colorScheme, .dark)

            #if os(iOS)
            CodeEditor(text: $code, errorLines: Set(result?.errors.compactMap(\.line) ?? []),
                       fontSize: fontSize, scrollToLine: $scrollLine, onRun: run)
            #else
            CodeEditor(text: $code, errorLines: Set(result?.errors.compactMap(\.line) ?? []),
                       fontSize: fontSize, scrollToLine: $scrollLine)
            #endif

            ConsoleView(result: result, running: running, problem: problem,
                        showsTests: stacked || compact, compact: compact) { line in
                showingCode = true
                scrollLine = line
            }
            .frame(minHeight: compact ? 90 : 150, idealHeight: compact ? 130 : 220, maxHeight: compact ? 180 : 290)

            if let result, !result.passed, !result.unsupported {
                Button { showCoach = true } label: {
                    Label(result.compiled ? "Why doesn't it pass? Ask the coach" : "Explain this error with Apple Intelligence",
                          systemImage: "apple.intelligence")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Palette.editorBackground)
                .environment(\.colorScheme, .dark)
            }

            if result?.passed == true {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { passedLabel; Spacer(); reviewButton; nextButton }
                    VStack(alignment: .leading, spacing: 8) { passedLabel; HStack { reviewButton; nextButton } }
                }
                .padding(12)
                .background(Palette.editorBackground)
                .environment(\.colorScheme, .dark)
            }
        }
        .background(Palette.editorBackground)
    }

    private var passedLabel: some View {
        Label("Every test passes. Lesson done.", systemImage: "checkmark.seal.fill")
            .foregroundStyle(Palette.pass).font(.reading(.callout, weight: .semibold))
    }

    private var reviewButton: some View {
        Button("Review my code", systemImage: "apple.intelligence") { showCoach = true }
            .buttonStyle(.glass)
    }

    @ViewBuilder private var nextButton: some View {
        if let next = model.course.neighbours(of: lesson.id).next {
            Button { model.open(next) } label: { Label("Next lesson", systemImage: "arrow.right") }
                .buttonStyle(.glassProminent)
                .help(next.title)
        }
    }

    private func run() {
        guard !running else { return }
        showingCode = true
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        running = true
        problem = nil
        let lesson = lesson, code = code
        Task {
            let checked = await model.check(lesson, code: code)
            result = checked
            if checked.unsupported {
                problem = "This exercise uses Swift that the on-device engine does not run. Open it in Xcode on a Mac, or read the tests and check your code against them."
            }
            if let line = checked.errors.compactMap(\.line).first { scrollLine = line }
            if checked.passed {
                model.store.complete(lesson.id)
                model.say("Lesson done")
            }
            running = false
        }
    }

    private func reset() {
        code = lesson.seed ?? ""
        model.store.resetCode(for: lesson.id)
        result = nil
        problem = nil
    }
}

struct TestsList: View {
    let tests: [LessonTest]
    let results: [RunResult.TestResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tests").font(.reading(.title3, weight: .semibold))
            ForEach(Array(tests.enumerated()), id: \.offset) { index, test in
                let passed = results.map { index < $0.count && $0[index].passed }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: passed == nil ? "circle" : (passed == true ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .symbol()
                        .foregroundStyle(passed == nil ? Color.secondary : (passed == true ? Palette.seaText : Palette.alertText))
                    Text(markdown(test.text)).font(.reading(.callout)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(passed == nil ? "Not run yet" : (passed == true ? "Passed" : "Failed"))
            }
        }
    }
}

struct ConsoleView: View {
    let result: RunResult?
    let running: Bool
    let problem: String?
    var showsTests = false
    var compact = false
    let onLine: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONSOLE")
                .font(.reading(.caption2, weight: .bold)).tracking(1)
                .foregroundStyle(Palette.editorText.opacity(0.5))
                .padding(.horizontal, 14).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(Color(hex: 0x0A1418))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if let problem {
            Text(problem).foregroundStyle(Color(hex: 0xFF9B85))
        } else if running {
            Text("Compiling and running your code…").foregroundStyle(.secondary)
        } else if let result {
            if !result.compiled {
                Text(result.timedOut ? "Checking took too long." : (result.unsupported ? "This needs Xcode on a Mac." : "Your code did not compile:"))
                    .foregroundStyle(Color(hex: 0xFF9B85))
                ForEach(result.errors, id: \.self) { errorLine($0) }
            } else {
                if !result.output.isEmpty { Text(result.output) }
                if result.timedOut {
                    Text("Your program ran for too long and was stopped. Is there a loop that never ends?")
                        .foregroundStyle(Color(hex: 0xFF9B85))
                } else if result.crashed {
                    Text("Your program crashed: \(result.crashReason)").foregroundStyle(Color(hex: 0xFF9B85))
                }
                if result.output.isEmpty && !result.timedOut && !result.crashed {
                    Text("(Nothing was printed.)").foregroundStyle(.secondary)
                }
                if showsTests {
                    ForEach(Array(result.tests.enumerated()), id: \.offset) { _, test in
                        Text((test.passed ? "Passed  " : "Failed  ") + test.text)
                            .foregroundStyle(test.passed ? Palette.pass : Color(hex: 0xFF9B85))
                    }
                }
                if result.passed {
                    Text("Every test passes.").foregroundStyle(Palette.pass).padding(.top, 6)
                }
            }
        } else {
            Text(compact ? "Press Run to check your code." : "Press Run (⌘↩) to check your code.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func errorLine(_ error: RunResult.CompilerError) -> some View {
        let message = (error.line.map { "line \($0): " } ?? "") + error.message
        if let line = error.line {
            Button { onLine(line) } label: {
                Text(message)
                    .foregroundStyle(Color(hex: 0xFF9B85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Error on line \(line). \(error.message)")
        } else {
            Text(message).foregroundStyle(Color(hex: 0xFF9B85))
        }
    }
}

// MARK: - Menu commands

#if os(macOS)
struct LessonCommands: Commands {
    let model: AppModel
    @FocusedValue(\.runAction) private var runAction
    @FocusedValue(\.resetAction) private var resetAction

    var body: some Commands {
        CommandMenu("Lesson") {
            Button("Run") { runAction?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(runAction == nil)
            Button("Reset Code") { resetAction?.reset() }
                .disabled(resetAction == nil)
            Divider()
            Button("Previous Lesson") { model.go(by: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Lesson") { model.go(by: 1) }.keyboardShortcut("]", modifiers: .command)
            Button("Continue Where I Left Off") { model.open(model.nextLesson) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Course Home") { model.open(nil) }.keyboardShortcut("h", modifiers: [.command, .shift])
        }
    }
}
#endif

struct RunAction { let run: () -> Void }
struct ResetAction { let reset: () -> Void }
struct RunActionKey: FocusedValueKey { typealias Value = RunAction }
struct ResetActionKey: FocusedValueKey { typealias Value = ResetAction }

extension FocusedValues {
    var runAction: RunAction? {
        get { self[RunActionKey.self] }
        set { self[RunActionKey.self] = newValue }
    }
    var resetAction: ResetAction? {
        get { self[ResetActionKey.self] }
        set { self[ResetActionKey.self] = newValue }
    }
}
