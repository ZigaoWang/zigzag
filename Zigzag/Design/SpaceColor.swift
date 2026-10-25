import AppKit

/// The curated set of space tints. One color per space colors the whole window frame.
/// Light values are pale enough for dark text, dark values deep enough for light text.
enum SpaceColor: String, Codable, CaseIterable {
    case snow, graphite, ink, sky, sage, sand, rose, lavender, mint, peach

    /// Without a hue: pure white, gray and black. A gradient or a hue doesn't apply to them.
    var isNeutral: Bool { self == .snow || self == .graphite || self == .ink }

    /// A colour this version doesn't know (saved by a newer one) reads as graphite, rather than making the whole
    /// library unreadable.
    init(from decoder: Decoder) throws {
        self = SpaceColor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .graphite
    }

    var name: String {
        switch self {
        case .snow: "White"
        case .graphite: "Graphite"
        case .ink: "Black"
        case .sky: "Sky"
        case .sage: "Sage"
        case .sand: "Sand"
        case .rose: "Rose"
        case .lavender: "Lavender"
        case .mint: "Mint"
        case .peach: "Peach"
        }
    }

    private var pair: (light: UInt32, dark: UInt32) {
        switch self {
        case .snow: (0xFFFFFF, 0x2C2C2E)
        case .graphite: (0xE6E6E8, 0x1D1D20)
        case .ink: (0x1C1C1E, 0x000000)
        case .sky: (0xDAE5F2, 0x18212D)
        case .sage: (0xDDE7DA, 0x1A231B)
        case .sand: (0xEDE4D5, 0x262118)
        case .rose: (0xF0DCE0, 0x2A1C20)
        case .lavender: (0xE3DEF1, 0x211D2D)
        case .mint: (0xD7EAE6, 0x162523)
        case .peach: (0xF3DECF, 0x2B1F17)
        }
    }

    /// The window frame color.
    var background: NSColor {
        Tokens.Color.dynamic(light: Tokens.Color.hex(pair.light), dark: Tokens.Color.hex(pair.dark))
    }

    /// Any hue, at the same tuned lightness as the curated tints, so every choice looks right in both modes.
    static let defaultIntensity = 0.4

    static func background(hue: Double, intensity: Double = defaultIntensity) -> NSColor {
        let t = min(max(intensity, 0), 1)
        return Tokens.Color.dynamic(light: NSColor(hue: hue, saturation: 0.04 + 0.26 * t, brightness: 0.96 - 0.04 * t, alpha: 1),
                                    dark: NSColor(hue: hue, saturation: 0.12 + 0.45 * t, brightness: 0.15 + 0.06 * t, alpha: 1))
    }

    /// One color, whatever the system's mode: how vivid, and how light or dark (0 lightest, 1 darkest).
    /// Neutral drops the hue for white, grays and black.
    static func fixed(hue: Double, intensity: Double, brightness: Double, neutral: Bool) -> NSColor {
        let t = min(max(intensity, 0), 1), b = min(max(brightness, 0), 1)
        let saturation = neutral ? 0 : (0.04 + 0.26 * t) * (1 - b) + (0.12 + 0.45 * t) * b + 0.12 * t * sin(.pi * b)
        let value = neutral ? 1 - 0.93 * b : (0.97 - 0.05 * t) * (1 - b) + (0.13 + 0.06 * t) * b
        return NSColor(hue: hue, saturation: saturation, brightness: value, alpha: 1)
    }

    static func swatch(hue: Double) -> NSColor {
        Tokens.Color.dynamic(light: NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1),
                             dark: NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1))
    }

    /// The hue of this tint, for placing it on the slider.
    var hue: Double {
        let c = (swatch.usingColorSpace(.sRGB) ?? swatch)
        return Double(c.hueComponent)
    }

    /// A saturated version used for small swatches and the space dot.
    var swatch: NSColor {
        switch self {
        case .snow: Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF), dark: Tokens.Color.hex(0xF2F2F7))
        case .graphite: Tokens.Color.dynamic(light: Tokens.Color.hex(0x8E8E93), dark: Tokens.Color.hex(0x98989D))
        case .ink: Tokens.Color.dynamic(light: Tokens.Color.hex(0x1C1C1E), dark: Tokens.Color.hex(0x000000))
        case .sky: Tokens.Color.dynamic(light: Tokens.Color.hex(0x5B8FD0), dark: Tokens.Color.hex(0x6E9EDB))
        case .sage: Tokens.Color.dynamic(light: Tokens.Color.hex(0x6E9A6A), dark: Tokens.Color.hex(0x7DAA78))
        case .sand: Tokens.Color.dynamic(light: Tokens.Color.hex(0xB89A64), dark: Tokens.Color.hex(0xC6A970))
        case .rose: Tokens.Color.dynamic(light: Tokens.Color.hex(0xC9707F), dark: Tokens.Color.hex(0xD6808F))
        case .lavender: Tokens.Color.dynamic(light: Tokens.Color.hex(0x8A78C4), dark: Tokens.Color.hex(0x9887D2))
        case .mint: Tokens.Color.dynamic(light: Tokens.Color.hex(0x4FA595), dark: Tokens.Color.hex(0x5DB4A3))
        case .peach: Tokens.Color.dynamic(light: Tokens.Color.hex(0xD58A5C), dark: Tokens.Color.hex(0xE0976A))
        }
    }
}
