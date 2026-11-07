// Asteria 26: aqua on night, heavy for highlights, an aqua-violet-heavy gradient for Smartz.
// RULE: tinted text keeps 4.5:1. Pure aqua on white is 1.3:1, so light appearance uses deep aqua #00826B.
// SF Pro for everything a person reads; Asteria Pixel for the word "Asteria" only.
// Multiplatform: no UIKit or AppKit type leaks out of this file.
import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Palette {
    /// Asteria sea: deep aqua in light appearance so symbols keep 3:1 on white, sea #00C9A7 in dark.
    static let sea = Color(light: 0x00826B, dark: 0x00C9A7)
    /// Asteria aqua, exactly.
    static let seaBright = Color(hex: 0x00FFD3)
    /// Deep aqua: fills that carry white text.
    static let seaDeep = Color(hex: 0x00826B)
    /// Asteria heavy, exactly: milestones, trophies, the cursor.
    static let gold = Color(hex: 0xFF0058)
    static let goldDeep = Color(hex: 0xE0004E)
    static let violet = Color(hex: 0x7A5CFF)
    /// Asteria night.
    static let night = Color(hex: 0x05080F)
    /// Starlight cream.
    static let cream = Color(hex: 0xE9FBF7)
    /// Smartz moments: aqua into violet into heavy.
    static let intelligence = LinearGradient(colors: [Color(hex: 0x00FFD3), Color(hex: 0x7A5CFF), Color(hex: 0xFF0058)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let alert = Color(hex: 0xC4432D)
    static let pass = Color(light: 0x2F7A3E, dark: 0x4CAF7A)
    /// Heavy for small emphasis, at 4.5:1 in both appearances.
    static let emphasis = Color(light: 0xE0004E, dark: 0xFF3D7F)
    /// The accent for text and small symbols: deep aqua (4.8:1 on white) in light, pure aqua in dark.
    static let seaText = Color(light: 0x00826B, dark: 0x00FFD3)
    static let alertText = Color(light: 0xB23A26, dark: 0xFF9B85)
    /// Text and symbols on an accent fill: white on deep aqua, near-black on pure aqua.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x00140F)

    // The editor is always dark, like Xcode's default, on Asteria night.
    static let editorBackground = Color(hex: 0x0A1220)
    static let editorText = Color(hex: 0xE9FBF7)
    /// The console under the editor, a step darker.
    static let consoleBackground = Color(hex: 0x05080F)
}

/// Accents a person can choose. Each has a darker light-mode value and a brighter dark-mode value, so tinted text
/// keeps 4.5:1 contrast in both appearances. Stored in iCloud key-value storage, so every device matches.
enum AccentChoice: String, CaseIterable, Identifiable {
    case sea, heavy, lagoon, gold, coral, violet, forest, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sea: "Asteria"
        default: rawValue.capitalized
        }
    }

    /// (light appearance, dark appearance)
    private var hexes: (UInt32, UInt32) {
        switch self {
        case .sea: (0x00826B, 0x00FFD3)
        case .heavy: (0xE0004E, 0xFF3D7F)
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

/// The label of a prominent button sits on the accent fill, so it uses `onAccent`. On the Mac an inactive window draws
/// prominent buttons without the fill, and there the label goes back to the normal text colour.
struct OnAccentLabel: ViewModifier {
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #else
    private let appearsActive = true
    #endif
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(appearsActive && isEnabled ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
    }
}

extension View {
    func onAccentLabel() -> some View { modifier(OnAccentLabel()) }
}
