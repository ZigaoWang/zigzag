import AppKit

/// The curated set of space tints. One color per space colors the whole window frame.
/// Light values are pale enough for dark text, dark values deep enough for light text.
enum SpaceColor: String, Codable, CaseIterable {
    case graphite, sky, sage, sand, rose, lavender, mint, peach

    var name: String {
        switch self {
        case .graphite: "Graphite"
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
        case .graphite: (0xE6E6E8, 0x1D1D20)
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
    static func background(hue: Double) -> NSColor {
        Tokens.Color.dynamic(light: NSColor(hue: hue, saturation: 0.13, brightness: 0.95, alpha: 1),
                             dark: NSColor(hue: hue, saturation: 0.32, brightness: 0.17, alpha: 1))
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
        case .graphite: Tokens.Color.dynamic(light: Tokens.Color.hex(0x8E8E93), dark: Tokens.Color.hex(0x98989D))
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
