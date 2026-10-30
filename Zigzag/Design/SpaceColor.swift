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

    /// A color on the space wheel: `hue` around it (red at 0, as on any color wheel), `depth` from the middle, near
    /// white, out to the rim, deep. Mixed in OKLCH, so every hue at one depth is equally light: a yellow and a blue the
    /// same distance out weigh the same, and the window's mode can follow depth alone. Neutral drops the hue for
    /// white, grays and black.
    static func paint(hue: Double, depth: Double, neutral: Bool = false) -> NSColor {
        let d = min(max(depth, 0), 1)
        let lightness = 0.975 - 0.69 * d
        // A whisper of color in the middle, richest around halfway, a little quieter again in the deep.
        let rise = min(d / 0.5, 1)
        var chroma = neutral ? 0 : 0.02 + 0.13 * rise * rise * (3 - 2 * rise) - 0.03 * max(0, d - 0.65) / 0.35
        let angle = okHue(hue)
        // Some hues can't be that rich at that lightness on a screen: back off until it fits.
        var rgb = OKLab.rgb(l: lightness, a: chroma * cos(angle), b: chroma * sin(angle))
        while !OKLab.inGamut(rgb), chroma > 0.002 {
            chroma *= 0.94
            rgb = OKLab.rgb(l: lightness, a: chroma * cos(angle), b: chroma * sin(angle))
        }
        let c = rgb.map { OKLab.encode(min(max($0, 0), 1)) }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// A shade of a wheel hue with WCAG relative luminance `luminance`, for accents made from a space's color. Mixed
    /// in OKLCH like the window itself, so the hue you see stays put as it gets lighter or darker: shading by HSB
    /// numbers instead drifts it (deep blues go lavender and read as purple, oranges go brown). `chroma` is as
    /// colorful as it gets, eased off where the screen can't show that much at the lightness needed.
    static func shade(hue: Double, luminance target: Double, chroma: Double) -> NSColor {
        let angle = okHue(hue)
        var low = 0.0, high = 1.0
        var rgb = [0.0, 0.0, 0.0]
        for _ in 0..<28 {
            let lightness = (low + high) / 2
            var c = chroma
            rgb = OKLab.rgb(l: lightness, a: c * cos(angle), b: c * sin(angle))
            while !OKLab.inGamut(rgb), c > 0.002 {
                c *= 0.94
                rgb = OKLab.rgb(l: lightness, a: c * cos(angle), b: c * sin(angle))
            }
            let y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            if y < target { low = lightness } else { high = lightness }
        }
        let c = rgb.map { OKLab.encode(min(max($0, 0), 1)) }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// The OKLCH hue angle of a wheel hue, so the wheel keeps its familiar order: red, orange, yellow, green, blue.
    static func okHue(_ hue: Double) -> Double {
        let pure = NSColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1) + (hue < 0 ? 1 : 0)), saturation: 1, brightness: 1, alpha: 1)
            .usingColorSpace(.sRGB) ?? .red
        let lab = OKLab.lab(r: OKLab.decode(pure.redComponent), g: OKLab.decode(pure.greenComponent), b: OKLab.decode(pure.blueComponent))
        return atan2(lab.b, lab.a)
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

/// Björn Ottosson's OKLab, the perceptual space behind `SpaceColor.paint` and `SpaceColor.shade`.
enum OKLab {
    static func rgb(l: Double, a: Double, b: Double) -> [Double] {
        let l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return [4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1,
                -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1,
                -0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1]
    }

    static func lab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        let l1 = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m1 = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s1 = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l1 + 0.7936177850 * m1 - 0.0040720468 * s1,
                1.9779984951 * l1 - 2.4285922050 * m1 + 0.4505937099 * s1,
                0.0259040371 * l1 + 0.7827717662 * m1 - 0.8086757660 * s1)
    }

    static func inGamut(_ rgb: [Double]) -> Bool { rgb.allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 } }

    /// Linear light to sRGB, and back.
    static func encode(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    static func decode(_ x: CGFloat) -> Double { let x = Double(x); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}
