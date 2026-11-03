// Colours Swift code: the same tokens and colours as Asteria Learn's editor (MundusNovusLearn/src/markdown.mjs).
import SwiftUI

nonisolated enum Highlighter {
    enum Token: Sendable { case keyword, string, number, comment, type, call, attribute, plain }

    static let keywords: Set<String> = Set(("actor any associatedtype async await break case catch class consume continue convenience default defer deinit " +
        "didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout " +
        "internal is isolated lazy let mutating nil nonisolated nonmutating open operator optional override package postfix precedencegroup " +
        "prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws " +
        "true try typealias unowned var weak where while willSet borrowing consuming sending").split(separator: " ").map(String.init))

    static func color(_ token: Token) -> Color? {
        switch token {
        case .keyword: Color(hex: 0xff7ab2)
        case .string: Color(hex: 0xff8170)
        case .number: Color(hex: 0xd9c97c)
        case .comment: Color(hex: 0x7f8c98)
        case .type: Color(hex: 0x5dd8ff)
        case .call: Color(hex: 0x67b7a4)
        case .attribute: Color(hex: 0xfd8f3f)
        case .plain: nil
        }
    }

    /// The source cut into (range, token) pieces, in order, covering all of it.
    static func tokens(_ source: String) -> [(Range<String.Index>, Token)] {
        var out: [(Range<String.Index>, Token)] = []
        var i = source.startIndex
        func take(_ regex: Regex<Substring>, as token: Token) -> Bool {
            guard let m = source[i...].prefixMatch(of: regex), !m.range.isEmpty else { return false }
            out.append((m.range, token)); i = m.range.upperBound; return true
        }
        while i < source.endIndex {
            if take(/\/\/[^\n]*/, as: .comment) { continue }
            if take(/\/\*[\s\S]*?(?:\*\/|$)/, as: .comment) { continue }
            if take(/"""[\s\S]*?(?:"""|$)/, as: .string) { continue }
            if take(/"(?:[^"\\\n]|\\.)*"?/, as: .string) { continue }
            if take(/(?:0x[0-9a-fA-F_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:e[+-]?\d+)?)/, as: .number) { continue }
            if take(/[@#][A-Za-z_]\w*/, as: .attribute) { continue }
            if let m = source[i...].prefixMatch(of: /[A-Za-z_]\w*/) {
                let word = String(m.output)
                let after = source[m.range.upperBound...].drop { $0 == " " }
                let token: Token = keywords.contains(word) ? .keyword : word.first!.isUppercase ? .type : after.first == "(" ? .call : .plain
                out.append((m.range, token)); i = m.range.upperBound; continue
            }
            let next = source.index(after: i)
            out.append((i..<next, .plain)); i = next
        }
        return out
    }

    /// For SwiftUI `Text`: the code with colours.
    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        for (range, token) in tokens(source) {
            var piece = AttributedString(String(source[range]))
            if let c = color(token) { piece.foregroundColor = c }
            if token == .keyword { piece.font = .system(.body, design: .monospaced).weight(.semibold) }
            result += piece
        }
        return result
    }
}
