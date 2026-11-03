// A Swift code editor: a native text view with syntax colouring, four-space tabs and automatic indentation, and line
// numbers. Lines with compiler errors are marked. On iPhone and iPad a bar above the keyboard inserts the symbols
// Swift needs, which the software keyboard hides.
import SwiftUI
import Foundation

enum CodeLayout {
    /// The character index where a 1-based source line starts.
    static func location(ofLine line: Int, in text: NSString) -> Int {
        guard line > 1, text.length > 0 else { return 0 }
        var index = 0
        var number = 1
        while index < text.length, number < line {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if next <= index { break }
            index = next
            number += 1
        }
        return min(index, text.length)
    }

    /// The range of a 1-based source line, including its trailing newline when it has one.
    static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        guard text.length > 0, line >= 1 else { return nil }
        var index = 0
        var number = 1
        while index < text.length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            if number == line { return range }
            let next = NSMaxRange(range)
            if next <= index { return nil }
            index = next
            number += 1
        }
        return nil
    }
}

#if os(macOS)
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var errorLines: Set<Int> = []
    var fontSize: CGFloat = 14
    @Binding var scrollToLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // The text view grows down with its text and follows the scroll view's width
        let editor = SwiftTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = NSColor(Palette.editorBackground)
        editor.insertionPointColor = NSColor(Palette.gold)
        editor.textContainerInset = NSSize(width: 8, height: 12)
        editor.setAccessibilityLabel("Your Swift code")
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Palette.editorBackground)
        scroll.appearance = NSAppearance(named: .darkAqua)    // the editor is always dark
        scroll.clipsToBounds = true
        let ruler = LineNumberRuler(textView: editor)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        editor.string = text
        context.coordinator.colour(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            context.coordinator.colour(editor)
        } else if context.coordinator.fontSize != fontSize {
            context.coordinator.colour(editor)
        }
        if let ruler = scroll.verticalRulerView as? LineNumberRuler, ruler.errorLines != errorLines {
            ruler.errorLines = errorLines
            ruler.needsDisplay = true
        }
        if let line = scrollToLine, line != context.coordinator.revealedLine {
            context.coordinator.revealedLine = line
            context.coordinator.reveal(line, in: editor)
            let binding = $scrollToLine
            DispatchQueue.main.async {
                if binding.wrappedValue == line { binding.wrappedValue = nil }
            }
        }
        if scrollToLine == nil { context.coordinator.revealedLine = nil }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var fontSize: CGFloat = 0
        var revealedLine: Int?
        init(_ parent: CodeEditor) { self.parent = parent }

        func reveal(_ line: Int, in editor: NSTextView) {
            let location = CodeLayout.location(ofLine: line, in: editor.string as NSString)
            editor.setSelectedRange(NSRange(location: location, length: 0))
            editor.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        func textDidChange(_ note: Notification) {
            guard let editor = note.object as? NSTextView else { return }
            parent.text = editor.string
            colour(editor)
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func colour(_ editor: NSTextView) {
            fontSize = parent.fontSize
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .semibold)
            guard let storage = editor.textStorage else { return }
            let source = storage.string
            storage.beginEditing()
            let all = NSRange(location: 0, length: storage.length)
            storage.setAttributes([.font: font, .foregroundColor: NSColor(Palette.editorText)], range: all)
            for (range, token) in Highlighter.tokens(source) {
                let r = NSRange(range, in: source)
                if let c = Highlighter.color(token) { storage.addAttribute(.foregroundColor, value: NSColor(c), range: r) }
                if token == .keyword { storage.addAttribute(.font, value: bold, range: r) }
            }
            storage.endEditing()
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor(Palette.editorText)]
        }
    }
}

/// Four-space tabs, and new lines keep the indentation (one level more after an opening bracket).
final class SwiftTextView: NSTextView {
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString, caret = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: max(0, caret - 1) < text.length ? caret : max(0, caret - 1), length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        if let last = before.trimmingCharacters(in: .whitespaces).last, "{([".contains(last) { indent += "    " }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // typing "}" on a line of only spaces removes one level of indentation
        if let s = string as? String, s == "}" {
            let text = self.string as NSString, caret = selectedRange().location
            let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
            if before.count >= 4, before.allSatisfy({ $0 == " " }) {
                super.insertText(String(before.dropLast(4)) + "}", replacementRange: NSRange(location: lineStart, length: caret - lineStart))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }
}

/// Line numbers beside the editor; lines with errors are drawn in red.
final class LineNumberRuler: NSRulerView {
    var errorLines: Set<Int> = []
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Views no longer clip to their bounds by default: fill only the ruler, or it paints over the code
        NSColor(Palette.editorBackground).setFill()
        rect.intersection(bounds).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = text.substring(to: chars.location).components(separatedBy: "\n").count
        var index = chars.location
        let font = NSFont.monospacedDigitSystemFont(ofSize: (textView.font?.pointSize ?? 14) * 0.85, weight: .regular)
        let inset = textView.textContainerInset.height
        func draw(_ n: Int, at y: CGFloat) {
            let colour = errorLines.contains(n) ? NSColor(Palette.alert) : NSColor.secondaryLabelColor.withAlphaComponent(0.6)
            let label = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y - visible.minY + inset + 1), withAttributes: attrs)
        }
        while index < NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            draw(line, at: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
            index = NSMaxRange(lineRange)
            line += 1
        }
        if text.length == 0 || text.hasSuffix("\n") {   // the empty last line
            let y = text.length == 0 ? 0 : layout.extraLineFragmentRect.minY
            draw(line, at: y)
        }
    }
}

#else
import UIKit

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var errorLines: Set<Int> = []
    var fontSize: CGFloat = 15
    @Binding var scrollToLine: Int?
    var onRun: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SwiftEditorView {
        let view = SwiftEditorView()
        view.textView.delegate = context.coordinator
        context.coordinator.editor = view
        context.coordinator.parent = self
        view.textView.text = text
        context.coordinator.colour(view.textView)
        return view
    }

    func updateUIView(_ view: SwiftEditorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.editor = view
        view.symbolBar.onSymbol = { coordinator.insert($0) }
        view.symbolBar.onRun = { coordinator.parent.onRun() }
        view.symbolBar.onDone = { view.textView.resignFirstResponder() }
        view.gutter.errorLines = errorLines
        view.gutter.fontSize = fontSize

        let current = view.textView.text ?? ""
        if current != text {
            // Setting the text fires textViewDidChange. Colouring from there toggles undo registration, and
            // UITextUndoManager crashes if that toggle is nested inside another one. Replace the text first, then colour once.
            coordinator.replacing = true
            view.textView.text = text
            coordinator.replacing = false
            coordinator.colour(view.textView)
        } else if coordinator.appliedFont != fontSize || coordinator.appliedErrors != errorLines {
            coordinator.colour(view.textView)
        }

        if let line = scrollToLine, line != coordinator.revealedLine {
            coordinator.revealedLine = line
            coordinator.reveal(line, in: view.textView)
            let binding = $scrollToLine
            DispatchQueue.main.async {
                if binding.wrappedValue == line { binding.wrappedValue = nil }
            }
        }
        if scrollToLine == nil { coordinator.revealedLine = nil }
        view.gutter.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SwiftEditorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 220)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var editor: SwiftEditorView?
        var appliedFont: CGFloat = -1
        var appliedErrors: Set<Int> = []
        var revealedLine: Int?
        var replacing = false
        private var colouring = false

        init(_ parent: CodeEditor) { self.parent = parent }

        func insert(_ string: String) {
            guard let textView = editor?.textView else { return }
            if !textView.isFirstResponder { textView.becomeFirstResponder() }
            textView.insertText(string)
        }

        func reveal(_ line: Int, in textView: UITextView) {
            let location = CodeLayout.location(ofLine: line, in: (textView.text ?? "") as NSString)
            let range = NSRange(location: location, length: 0)
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
            editor?.gutter.setNeedsDisplay()
        }

        func textViewDidChange(_ view: UITextView) {
            guard !colouring, !replacing else { return }
            parent.text = view.text ?? ""
            if view.markedTextRange == nil { colour(view) }
            editor?.gutter.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            editor?.gutter.setNeedsDisplay()
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            if view.markedTextRange != nil { return true }
            if string == "\n" {
                let text = (view.text ?? "") as NSString
                let loc = min(range.location, text.length)
                let lineStart = text.lineRange(for: NSRange(location: loc, length: 0)).location
                let before = text.substring(with: NSRange(location: lineStart, length: loc - lineStart))
                return !replace(in: view, range: range, with: "\n" + Self.indent(of: before))
            }
            if string == "\t" {
                return !replace(in: view, range: range, with: "    ")
            }
            if string == "}", range.length == 0 {
                let text = (view.text ?? "") as NSString
                let loc = min(range.location, text.length)
                let lineStart = text.lineRange(for: NSRange(location: loc, length: 0)).location
                let before = text.substring(with: NSRange(location: lineStart, length: loc - lineStart))
                if before.count >= 4, before.allSatisfy({ $0 == " " }) {
                    let dedent = NSRange(location: lineStart, length: loc - lineStart)
                    return !replace(in: view, range: dedent, with: String(before.dropLast(4)) + "}")
                }
            }
            return true
        }

        func colour(_ view: UITextView) {
            guard !colouring, view.markedTextRange == nil else { return }
            appliedFont = parent.fontSize
            appliedErrors = parent.errorLines
            let storage = view.textStorage
            let font = UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let bold = UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .semibold)
            let selected = view.selectedRange
            let source = storage.string
            let undo = view.undoManager
            undo?.disableUndoRegistration()
            colouring = true
            storage.beginEditing()
            if storage.length > 0 {
                storage.setAttributes([.font: font, .foregroundColor: UIColor(Palette.editorText)], range: NSRange(location: 0, length: storage.length))
                for (range, token) in Highlighter.tokens(source) {
                    let r = NSRange(range, in: source)
                    guard NSMaxRange(r) <= storage.length else { continue }
                    if let c = Highlighter.color(token) { storage.addAttribute(.foregroundColor, value: UIColor(c), range: r) }
                    if token == .keyword { storage.addAttribute(.font, value: bold, range: r) }
                }
                let background = UIColor(Palette.alert).withAlphaComponent(0.16)
                let ns = source as NSString
                for line in parent.errorLines {
                    guard let range = CodeLayout.range(ofLine: line, in: ns), NSMaxRange(range) <= storage.length else { continue }
                    storage.addAttribute(.backgroundColor, value: background, range: range)
                }
            }
            storage.endEditing()
            colouring = false
            undo?.enableUndoRegistration()
            let end = min(NSMaxRange(selected), storage.length)
            let start = min(selected.location, end)
            view.selectedRange = NSRange(location: start, length: end - start)
            view.typingAttributes = [.font: font, .foregroundColor: UIColor(Palette.editorText)]
            editor?.gutter.fontSize = parent.fontSize
            editor?.gutter.errorLines = parent.errorLines
            editor?.gutter.setNeedsDisplay()
        }

        private static func indent(of linePrefix: String) -> String {
            var indent = String(linePrefix.prefix { $0 == " " || $0 == "\t" })
            if let last = linePrefix.trimmingCharacters(in: .whitespaces).last, "{([".contains(last) {
                indent += "    "
            }
            return indent
        }

        /// Replaces `range` and returns whether the text view accepted it.
        private func replace(in view: UITextView, range: NSRange, with text: String) -> Bool {
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: view.beginningOfDocument, offset: NSMaxRange(range)),
                  let textRange = view.textRange(from: start, to: end) else { return false }
            view.replace(textRange, withText: text)
            return true
        }
    }
}

/// The text view, its line-number gutter and the symbol bar, as one view so SwiftUI gives the editor a real height
/// instead of the height of every line of code.
final class SwiftEditorView: UIView {
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textView: UITextView
    let gutter = LineNumberView()
    let symbolBar = SymbolBar()

    override init(frame: CGRect) {
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textStorage = storage
        layoutManager = layout
        textView = UITextView(frame: .zero, textContainer: container)
        super.init(frame: frame)

        backgroundColor = UIColor(Palette.editorBackground)
        clipsToBounds = true
        textView.backgroundColor = UIColor(Palette.editorBackground)
        textView.tintColor = UIColor(Palette.gold)
        textView.keyboardAppearance = .dark
        textView.overrideUserInterfaceStyle = .dark
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.keyboardType = .asciiCapable
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.automaticallyAdjustsScrollIndicatorInsets = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 48, bottom: 24, right: 10)
        textView.accessibilityLabel = "Your Swift code"
        textView.inputAccessoryView = symbolBar

        gutter.editor = self
        gutter.isUserInteractionEnabled = false
        gutter.backgroundColor = UIColor(Palette.editorBackground)
        gutter.isOpaque = true
        gutter.contentMode = .redraw
        textView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        addSubview(gutter)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.setNeedsDisplay()
    }
}

/// Source line numbers beside the code. Lines the compiler marked are drawn in red.
final class LineNumberView: UIView {
    weak var editor: SwiftEditorView?
    var errorLines: Set<Int> = []
    var fontSize: CGFloat = 15

    override func draw(_ rect: CGRect) {
        guard let editor else { return }
        let textView = editor.textView
        let layout = editor.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        UIColor(Palette.editorBackground).setFill()
        UIBezierPath(rect: bounds.intersection(rect)).fill()
        UIColor.white.withAlphaComponent(0.08).setFill()
        UIBezierPath(rect: CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)).fill()

        let font = UIFont.monospacedDigitSystemFont(ofSize: max(10, fontSize * 0.85), weight: .regular)
        let ns = (textView.text ?? "") as NSString
        let inset = textView.textContainerInset.top
        let offset = textView.contentOffset.y

        func drawNumber(_ n: Int, y: CGFloat) {
            guard y < bounds.height + 24, y + font.lineHeight > -24 else { return }
            let colour = errorLines.contains(n) ? UIColor(Palette.alert) : UIColor.secondaryLabel.withAlphaComponent(0.85)
            let label = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: bounds.width - size.width - 8, y: y + 1), withAttributes: attrs)
        }

        if ns.length == 0 {
            drawNumber(1, y: inset - offset)
            return
        }
        var index = 0
        var line = 1
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(line, y: fragment.minY + inset - offset)
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
            line += 1
        }
        if ns.hasSuffix("\n") {
            drawNumber(line, y: layout.extraLineFragmentRect.minY + inset - offset)
        }
    }
}

/// Symbols the iPhone keyboard buries, plus Run, kept above the keyboard while the code is being edited.
final class SymbolBar: UIView {
    var onSymbol: (String) -> Void = { _ in }
    var onRun: () -> Void = {}
    var onDone: () -> Void = {}

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let runButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let hairline = UIView()

    static let keys: [(insert: String, title: String, label: String)] = [
        ("    ", "Tab", "Indent"),
        ("{", "{", "Open brace"),
        ("}", "}", "Close brace"),
        ("(", "(", "Open parenthesis"),
        (")", ")", "Close parenthesis"),
        ("[", "[", "Open bracket"),
        ("]", "]", "Close bracket"),
        ("\"", "\"", "Straight quote"),
        ("=", "=", "Equals"),
        ("<", "<", "Less than"),
        (">", ">", "Greater than"),
        (":", ":", "Colon"),
        (".", ".", "Dot"),
        (",", ",", "Comma"),
        ("_", "_", "Underscore"),
        ("/", "/", "Slash"),
        ("*", "*", "Star"),
        ("&", "&", "Ampersand"),
        ("|", "|", "Vertical bar"),
        ("!", "!", "Exclamation"),
        ("?", "?", "Question mark"),
        ("@", "@", "At"),
        ("#", "#", "Hash"),
        ("-", "-", "Minus"),
        ("+", "+", "Plus"),
    ]

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(Palette.editorBackground)
        overrideUserInterfaceStyle = .dark

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        for key in Self.keys { stack.addArrangedSubview(keyButton(key)) }

        var runConfig = UIButton.Configuration.filled()
        runConfig.title = "Run"
        runConfig.baseBackgroundColor = UIColor(Palette.sea)
        runConfig.baseForegroundColor = .white
        runConfig.cornerStyle = .capsule
        runConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        runButton.configuration = runConfig
        runButton.accessibilityLabel = "Run your code"
        runButton.addAction(UIAction { [weak self] _ in self?.onRun() }, for: .touchUpInside)
        addSubview(runButton)

        var doneConfig = UIButton.Configuration.plain()
        doneConfig.title = "Done"
        doneConfig.baseForegroundColor = UIColor(Palette.gold)
        doneButton.configuration = doneConfig
        doneButton.accessibilityLabel = "Hide the keyboard"
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone() }, for: .touchUpInside)
        addSubview(doneButton)

        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        addSubview(hairline)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        doneButton.sizeToFit()
        runButton.sizeToFit()
        let doneWidth = max(doneButton.bounds.width, 56)
        let runWidth = max(runButton.bounds.width, 58)
        doneButton.frame = CGRect(x: bounds.width - doneWidth - 4, y: 6, width: doneWidth, height: bounds.height - 12)
        runButton.frame = CGRect(x: doneButton.frame.minX - runWidth - 4, y: 6, width: runWidth, height: bounds.height - 12)
        scroll.frame = CGRect(x: 0, y: 0, width: max(0, runButton.frame.minX - 4), height: bounds.height)
    }

    private func keyButton(_ key: (insert: String, title: String, label: String)) -> UIButton {
        var config = UIButton.Configuration.plain()
        var title = AttributedString(key.title)
        title.font = .system(size: 16, weight: .medium, design: .monospaced)
        config.attributedTitle = title
        config.baseForegroundColor = UIColor(Palette.editorText)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.label
        let insert = key.insert
        button.addAction(UIAction { [weak self] _ in self?.onSymbol(insert) }, for: .touchUpInside)
        return button
    }
}
#endif
