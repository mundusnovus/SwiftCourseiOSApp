// Asteria's colours and type. SF Pro for everything a person reads; Asteria Pixel for the word "Asteria" only.
// Multiplatform: no UIKit or AppKit type leaks out of this file.
import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Palette {
    static let sea = Color(hex: 0x1C8C9E)
    static let seaBright = Color(hex: 0x3BB3C3)
    static let seaDeep = Color(hex: 0x116674)
    static let gold = Color(hex: 0xE9B04B)
    static let goldDeep = Color(hex: 0xA8761A)
    static let night = Color(hex: 0x0C1A2B)
    static let cream = Color(hex: 0xFBF1DC)
    static let alert = Color(hex: 0xC4432D)
    static let pass = Color(hex: 0x4CAF7A)
    /// Gold for small emphasis. Gold deep on light surfaces keeps 4.5:1 contrast.
    static let emphasis = Color(light: 0xA8761A, dark: 0xE9B04B)
    /// Sea and alert for text and small symbols. Plain `sea` (#1C8C9E) is 3.9:1 on white, under the 4.5:1 bar.
    static let seaText = Color(light: 0x116674, dark: 0x3BB3C3)
    static let alertText = Color(light: 0xB23A26, dark: 0xFF9B85)

    // The editor is always dark, like Xcode's default.
    static let editorBackground = Color(hex: 0x0E1B20)
    static let editorText = Color(hex: 0xDFE6EA)
}

/// Accents a person can choose. Each has a darker light-mode value and a brighter dark-mode value, so tinted text
/// keeps 4.5:1 contrast in both appearances. Stored in iCloud key-value storage, so every device matches.
enum AccentChoice: String, CaseIterable, Identifiable {
    case sea, lagoon, gold, coral, violet, forest, graphite

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    private var hexes: (UInt32, UInt32) {
        switch self {
        case .sea: (0x116674, 0x3BB3C3)
        case .lagoon: (0x1D5FA8, 0x5EA8F2)
        case .gold: (0x8A5F10, 0xE9B04B)
        case .coral: (0xB23A26, 0xF07F69)
        case .violet: (0x6A43B5, 0xAE8CF0)
        case .forest: (0x2F7A3E, 0x6FCB82)
        case .graphite: (0x4A5560, 0xA7B2BD)
        }
    }

    var color: Color { Color(light: hexes.0, dark: hexes.1) }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    nonisolated init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
        }
        let l = components(light), d = components(dark)
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

/// Registers Asteria Pixel. Look it up by PostScript name, never by family: a family lookup can fail silently and fall
/// back to the system font.
enum BrandFont {
    static let postScriptName = "AsteriaPixel-Regular"

    static let isRegistered: Bool = {
        if CTFontCreateWithName(postScriptName as CFString, 12, nil).postScriptName == postScriptName { return true }
        guard let url = Bundle.main.url(forResource: "AsteriaPixel-Regular", withExtension: "ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCreateWithName(postScriptName as CFString, 12, nil).postScriptName == postScriptName
    }()
}

private extension CTFont {
    var postScriptName: String { CTFontCopyPostScriptName(self) as String }
}

extension Font {
    /// Asteria Pixel, for the word "Asteria" and nothing else. Fixed size on purpose: it is a logo, not reading text.
    static func asteria(_ size: CGFloat) -> Font {
        BrandFont.isRegistered ? .custom(BrandFont.postScriptName, fixedSize: size) : .system(size: size, weight: .semibold)
    }

    /// SF Pro, the system font, for everything a person reads. Text styles follow Dynamic Type.
    static func reading(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }
}

extension Image {
    /// Call BEFORE `.foregroundStyle`, because it returns `some View`.
    func symbol() -> some View {
        symbolRenderingMode(.hierarchical)
    }
}

/// "Asteria" in Asteria Pixel and the product word in SF Pro.
struct Wordmark: View {
    var product = "Zero to Hero"
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            Text("Asteria").font(.asteria(size))
            Text(product).font(.system(size: size * 0.82, weight: .semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asteria \(product)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Applies the person's chosen accent to a sheet or window that would otherwise use the system accent.
struct AppTint: ViewModifier {
    @AppStorage("accent") private var accentRaw = AccentChoice.sea.rawValue

    func body(content: Content) -> some View {
        content.tint((AccentChoice(rawValue: accentRaw) ?? .sea).color)
    }
}

extension View {
    func appTint() -> some View { modifier(AppTint()) }
}

/// A frosted card for grouped content that floats over the page. Not for every row.
struct GlassCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: 20))
    }
}

/// The small coloured tile that marks a chapter or a badge.
struct IconTile: View {
    let symbol: String
    var tint: Color = Palette.sea

    var body: some View {
        Image(systemName: symbol)
            .symbol()
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
