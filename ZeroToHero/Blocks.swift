// Lesson text, drawn from blocks. Inline Markdown: bold, italics, `code`, links.
import SwiftUI
import ZeroToHeroKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline Markdown as styled text; plain text if it cannot be parsed.
func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

struct BlocksView: View {
    let blocks: [Block]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

struct BlockView: View {
    let block: Block

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(markdown(text))
                .font(.reading(level <= 2 ? .title2 : .title3, weight: .semibold))
                .padding(.top, 6)
        case .paragraph(let text):
            Text(markdown(text)).font(.reading(.body)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        case .code(_, let code):
            CodeBlock(code: code)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(.reading(.body, weight: .semibold))
                            .foregroundStyle(ordered ? Palette.emphasis : .secondary)
                            .monospacedDigit()
                            .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                        Text(markdown(item)).font(.reading(.body)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .note(let kind, let blocks):
            NoteView(kind: kind, blocks: blocks)
        case .quote(let blocks):
            HStack(spacing: 12) {
                Capsule().fill(Palette.sea.opacity(0.5)).frame(width: 3)
                BlocksView(blocks: blocks).foregroundStyle(.secondary)
            }
        case .table(let head, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                TableView(head: head, rows: rows)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Swift").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 14).padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlighter.attributed(code))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Palette.editorText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(Palette.editorBackground, in: .rect(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

struct NoteView: View {
    let kind: String
    let blocks: [Block]

    var tint: Color {
        switch kind {
        case "Tip": Palette.gold
        case "Warning": Palette.alert
        case "Apple Developer Program": Palette.sea
        default: Palette.sea
        }
    }
    var icon: String {
        switch kind {
        case "Tip": "lightbulb"
        case "Warning": "exclamationmark.triangle"
        case "Apple Developer Program": "apple.logo"
        default: "info.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).symbol().foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind).font(.reading(.headline, weight: .semibold))
                BlocksView(blocks: blocks)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.28)))
    }
}

struct TableView: View {
    let head: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                ForEach(Array(head.enumerated()), id: \.offset) { _, h in
                    Text(markdown(h)).font(.reading(.callout, weight: .semibold))
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(markdown(cell)).font(.reading(.callout)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }
}
