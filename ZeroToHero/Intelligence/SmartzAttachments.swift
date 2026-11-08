// Photos and files for Smartz, in every Asteria app's chat. Photos go to the model as pictures. Files are read on the
// device and their words go with the message: PDFs, plain text and Markdown, code, CSV and JSON, RTF, web pages, and
// Word, Excel and PowerPoint documents (read straight from their ZIP, no other app needed). Nothing is uploaded
// anywhere else; a file's words stay on this device with the chat, so later questions about it still have it.
import Compression
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Something attached to a message before it's sent: a photo, or a document's words.
nonisolated public struct SmartzAttachment: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let image: CGImage?
    public let file: SmartzChatFile?

    public var isPhoto: Bool { image != nil }
}

/// A document's words, kept with the message on this device.
nonisolated public struct SmartzChatFile: Codable, Hashable, Sendable {
    public var name: String
    public var text: String
    /// Cut short to fit (the start is kept).
    public var trimmed: Bool

    /// How it reads in the prompt.
    var prompt: String {
        "[The file \"\(name)\"\(trimmed ? ", cut short to fit" : ""):]\n\(text)\n[End of \"\(name)\"]"
    }
}

nonisolated public enum SmartzFiles {
    public static let wordType = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
    public static let excelType = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
    public static let powerPointType = UTType("org.openxmlformats.presentationml.presentation") ?? .data
    public static let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

    /// What the file picker offers.
    public static let types: [UTType] = [.image, .pdf, .plainText, .text, .rtf, .html, .commaSeparatedText, .tabSeparatedText,
                                         .json, .xml, .sourceCode, .script, markdownType, wordType, excelType, powerPointType]

    /// The most of one document Smartz reads (about 10,000 words).
    public static let maxCharacters = 40_000
    /// The most attached to one message.
    public static let maxAttachments = 6

    nonisolated public enum Problem: LocalizedError {
        case unreadable(String), tooBig(String), empty(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Smartz can't read \"\(name)\". Try a PDF, a text file, or a Word, Excel or PowerPoint document."
            case .tooBig(let name): "\"\(name)\" is too big to attach (the limit is 30 MB)."
            case .empty(let name): "There are no words in \"\(name)\" for Smartz to read."
            }
        }
    }

    /// A file from the picker or a drop. Opens security-scoped files itself.
    public static func load(_ url: URL) throws -> SmartzAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 30_000_000 else { throw Problem.tooBig(name) }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return try attachment(data, name: name, type: type)
    }

    public static func attachment(_ data: Data, name: String, type: UTType) throws -> SmartzAttachment {
        if type.conforms(to: .image) {
            guard let image = picture(data) else { throw Problem.unreadable(name) }
            return SmartzAttachment(name: name, image: image, file: nil)
        }
        guard let words = text(data, type: type) else { throw Problem.unreadable(name) }
        let clean = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Problem.empty(name) }
        let trimmed = clean.count > maxCharacters
        return SmartzAttachment(name: name, image: nil, file: SmartzChatFile(name: name, text: trimmed ? String(clean.prefix(maxCharacters)) : clean, trimmed: trimmed))
    }

    /// A photo, at most 2,048 pixels on the long side (the model reads 1,568).
    public static func picture(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2_048,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A document's words, by its type.
    static func text(_ data: Data, type: UTType) -> String? {
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(data: data) else { return nil }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        if type.conforms(to: wordType) { return Office.word(data) }
        if type.conforms(to: excelType) { return Office.excel(data) }
        if type.conforms(to: powerPointType) { return Office.powerPoint(data) }
        if type.conforms(to: .rtf) { return rtf(data) }
        if type.conforms(to: .html) { return String(data: data, encoding: .utf8).map(Office.stripTags) }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) || type == .data {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        return nil
    }

    /// RTF's words: the text between the control words.
    static func rtf(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), raw.hasPrefix("{\\rtf") else { return nil }
        var text = raw.replacingOccurrences(of: "\\par", with: "\n").replacingOccurrences(of: "\\tab", with: "\t")
        text = text.replacingOccurrences(of: #"\{\\\*[^{}]*\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{\\(fonttbl|colortbl|stylesheet|info)[^{}]*(\{[^{}]*\}[^{}]*)*\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\[a-zA-Z]+-?\d* ?"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    /// Word, Excel and PowerPoint documents: ZIP archives of XML.
    nonisolated enum Office {
        static func word(_ data: Data) -> String? {
            guard let xml = Zip.entry("word/document.xml", in: data).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
            let marked = xml.replacingOccurrences(of: "</w:p>", with: "\n").replacingOccurrences(of: "<w:tab/>", with: "\t")
                .replacingOccurrences(of: "<w:br/>", with: "\n")
            return stripTags(marked)
        }

        static func powerPoint(_ data: Data) -> String? {
            let names = Zip.names(in: data).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { number(in: $0) < number(in: $1) }
            guard !names.isEmpty else { return nil }
            return names.enumerated().compactMap { index, name -> String? in
                guard let xml = Zip.entry(name, in: data).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
                let words = matches(#"<a:t>([^<]*)</a:t>"#, in: xml).map(entities).joined(separator: " ")
                return "Slide \(index + 1): \(words)"
            }.joined(separator: "\n")
        }

        static func excel(_ data: Data) -> String? {
            let shared = Zip.entry("xl/sharedStrings.xml", in: data).flatMap { String(data: $0, encoding: .utf8) }
                .map { xml in matches(#"<si>(.*?)</si>"#, in: xml).map { entities(stripTags($0)) } } ?? []
            let sheets = Zip.names(in: data).filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { number(in: $0) < number(in: $1) }
            guard !sheets.isEmpty else { return nil }
            var out: [String] = []
            for (index, name) in sheets.enumerated() {
                guard let xml = Zip.entry(name, in: data).flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
                out.append("Sheet \(index + 1):")
                for row in matches(#"<row[^>]*>(.*?)</row>"#, in: xml).prefix(2_000) {
                    let cells = matches(#"<c ([^>]*?)(?:/>|>(.*?)</c>)"#, in: row, group: 0).map { cell -> String in
                        let value = matches(#"<v>([^<]*)</v>"#, in: cell).first ?? matches(#"<t[^>]*>([^<]*)</t>"#, in: cell).first ?? ""
                        if cell.contains(#"t="s""#), let index = Int(value), shared.indices.contains(index) { return shared[index] }
                        return entities(value)
                    }
                    if !cells.allSatisfy(\.isEmpty) { out.append(cells.joined(separator: "\t")) }
                }
            }
            return out.joined(separator: "\n")
        }

        static func stripTags(_ text: String) -> String {
            var plain = text.replacingOccurrences(of: #"<(script|style)[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
            plain = plain.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            plain = plain.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            plain = plain.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            return entities(plain)
        }

        static func entities(_ text: String) -> String {
            text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
        }

        static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap { match in
                let index = min(group, match.numberOfRanges - 1)
                guard let found = Range(match.range(at: index), in: text) else { return group == 0 ? nil : "" }
                return String(text[found])
            }
        }

        static func number(in name: String) -> Int {
            Int(name.filter(\.isNumber)) ?? 0
        }
    }

    /// Just enough of a ZIP reader for Office documents: the central directory, and stored or deflated entries.
    nonisolated enum Zip {
        nonisolated struct Entry { let name: String; let method: UInt16; let compressed: Int; let size: Int; let offset: Int }

        static func entries(_ data: Data) -> [Entry] {
            let bytes = [UInt8](data)
            guard bytes.count > 22 else { return [] }
            // The end of central directory record, within the last 64 KB.
            var end = -1
            for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
            where bytes[index] == 0x50 && bytes[index + 1] == 0x4b && bytes[index + 2] == 0x05 && bytes[index + 3] == 0x06 {
                end = index
                break
            }
            guard end >= 0 else { return [] }
            let count = Int(le16(bytes, end + 10))
            var cursor = Int(le32(bytes, end + 16))
            var out: [Entry] = []
            for _ in 0..<count {
                guard cursor + 46 <= bytes.count, le32(bytes, cursor) == 0x0201_4b50 else { break }
                let method = le16(bytes, cursor + 10)
                let compressed = Int(le32(bytes, cursor + 20)), size = Int(le32(bytes, cursor + 24))
                let nameLength = Int(le16(bytes, cursor + 28)), extra = Int(le16(bytes, cursor + 30)), comment = Int(le16(bytes, cursor + 32))
                let offset = Int(le32(bytes, cursor + 42))
                guard cursor + 46 + nameLength <= bytes.count else { break }
                let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
                out.append(Entry(name: name, method: method, compressed: compressed, size: size, offset: offset))
                cursor += 46 + nameLength + extra + comment
            }
            return out
        }

        static func names(in data: Data) -> [String] { entries(data).map(\.name) }

        static func entry(_ name: String, in data: Data) -> Data? {
            guard let entry = entries(data).first(where: { $0.name == name }), entry.size <= 40_000_000 else { return nil }
            let bytes = [UInt8](data)
            let header = entry.offset
            guard header + 30 <= bytes.count, le32(bytes, header) == 0x0403_4b50 else { return nil }
            let start = header + 30 + Int(le16(bytes, header + 26)) + Int(le16(bytes, header + 28))
            guard start + entry.compressed <= bytes.count else { return nil }
            let body = Array(bytes[start..<(start + entry.compressed)])
            switch entry.method {
            case 0: return Data(body)
            case 8:
                var output = [UInt8](repeating: 0, count: max(entry.size, 1))
                let written = compression_decode_buffer(&output, output.count, body, body.count, nil, COMPRESSION_ZLIB)
                return written > 0 ? Data(output.prefix(written)) : nil
            default: return nil
            }
        }

        static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
    }
}
