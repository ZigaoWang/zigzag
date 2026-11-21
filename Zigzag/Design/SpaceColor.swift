import AppKit

/// The curated set of space tints. One color per space colors the whole window frame.
/// Light values are pale enough for dark text, dark values deep enough for light text.
enum SpaceColor: String, Codable, CaseIterable {
    case snow, graphite, ink, sky, sage, sand, rose, lavender, mint, peach
    case lagoon, sunset, dusk, citrus, midnight, petrol, forest, merlot, watermelon, fuchsia, volt, lilac, seafoam, dune

    /// The space editor's glass (`look`): gradients, then deep and moody, vivid, and soft.
    static let palette: [SpaceColor] = [.lagoon, .sunset, .dusk, .citrus, .midnight, .petrol, .forest, .merlot, .watermelon, .fuchsia, .volt, .lilac, .seafoam, .dune]
    /// The order new spaces take them in: lagoon first, then each far from the one before.
    static let newSpaceOrder: [SpaceColor] = [.lagoon, .sunset, .forest, .fuchsia, .citrus, .midnight, .watermelon, .dusk, .seafoam, .merlot, .volt, .lilac, .petrol, .dune]
    /// The colors given out before the palette, in their order. Profiles and Arc imports still use them.
    static let legacy: [SpaceColor] = [.sky, .sage, .sand, .rose, .lavender, .mint, .peach]
    static let legacyAll: [SpaceColor] = [.snow, .graphite, .ink] + legacy

    /// The color a new space gets: the first of `order` that none has yet, else, once all are taken, the next of
    /// `fallback` in turn.
    static func next(unused used: [SpaceColor], from order: [SpaceColor] = newSpaceOrder, fallback: [SpaceColor]? = nil) -> SpaceColor {
        let taken = Set(used)
        let fallback = fallback ?? order
        return order.first { !taken.contains($0) } ?? fallback[used.count % fallback.count]
    }

    /// As colors were given out before the new palette: for profiles, and for working out what older spaces were made with.
    static func legacyNext(unused used: [SpaceColor], fallback: [SpaceColor] = legacyAll) -> SpaceColor {
        next(unused: used, from: legacy, fallback: fallback)
    }

    /// The color from before nearest this one around the wheel.
    var nearestLegacy: SpaceColor {
        guard !isNeutral, !Self.legacy.contains(self) else { return self }
        func distance(_ other: SpaceColor) -> Double { let d = abs(other.hue - hue); return min(d, 1 - d) }
        return Self.legacy.min { distance($0) < distance($1) } ?? .sky
    }

    /// The palette's looks on clear glass: hue and depth (0 light, 1 deep), and a second hue for a gradient. Deep ones
    /// keep the window dark and the rest light, day and night; nil for the colors from before.
    var paletteLook: (hue: Double, depth: Double, tint: Double, hue2: Double?, depth2: Double, seeThrough: Double)? {
        switch self {
        case .lagoon: (0.5, 0.91, 1, 0.6, 0.93, Tokens.Frame.paletteSeeThrough)
        case .sunset: (0.015, 0.36, 1, 0.8, 0.4, Tokens.Frame.vividSeeThrough)
        case .dusk: (0.72, 0.91, 1, 0.95, 0.91, Tokens.Frame.paletteSeeThrough)
        case .citrus: (0.22, 0.36, 1, 0.075, 0.36, Tokens.Frame.vividSeeThrough)
        case .midnight: (0.7, 0.92, 1, nil, 0.92, Tokens.Frame.paletteSeeThrough)
        case .petrol: (0.48, 0.92, 1, nil, 0.92, Tokens.Frame.paletteSeeThrough)
        case .forest: (0.38, 0.91, 1, nil, 0.91, Tokens.Frame.paletteSeeThrough)
        case .merlot: (0.94, 0.91, 1, nil, 0.91, Tokens.Frame.paletteSeeThrough)
        case .watermelon: (0.97, 0.38, 1, nil, 0.38, Tokens.Frame.vividSeeThrough)
        case .fuchsia: (0.87, 0.4, 1, nil, 0.4, Tokens.Frame.vividSeeThrough)
        case .volt: (0.22, 0.4, 1, nil, 0.4, Tokens.Frame.vividSeeThrough)
        case .lilac: (0.76, 0.12, 0.8, nil, 0.12, Tokens.Frame.paletteSeeThrough)
        case .seafoam: (0.45, 0.12, 0.8, nil, 0.12, Tokens.Frame.paletteSeeThrough)
        case .dune: (0.12, 0.16, 0.9, nil, 0.16, Tokens.Frame.paletteSeeThrough)
        default: nil
        }
    }

    /// Without a hue: pure white, gray and black. A gradient or a hue doesn't apply to them.
    var isNeutral: Bool { self == .snow || self == .graphite || self == .ink }

    /// A colour this version doesn't know (saved by a newer one) reads as graphite, rather than making the whole
    /// library unreadable.
    init(from decoder: Decoder) throws {
        self = SpaceColor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .graphite
    }

    var name: String {
        switch self {
        case .snow: String(localized: "White", comment: "Name of a curated space color, in the space editor.")
        case .graphite: String(localized: "Graphite", comment: "Name of a curated space color, in the space editor.")
        case .ink: String(localized: "Black", comment: "Name of a curated space color, in the space editor.")
        case .sky: String(localized: "Sky", comment: "Name of a curated space color, in the space editor.")
        case .sage: String(localized: "Sage", comment: "Name of a curated space color, in the space editor.")
        case .sand: String(localized: "Sand", comment: "Name of a curated space color, in the space editor.")
        case .rose: String(localized: "Rose", comment: "Name of a curated space color, in the space editor.")
        case .lavender: String(localized: "Lavender", comment: "Name of a curated space color, in the space editor.")
        case .mint: String(localized: "Mint", comment: "Name of a curated space color, in the space editor.")
        case .peach: String(localized: "Peach", comment: "Name of a curated space color, in the space editor.")
        case .lagoon: String(localized: "Lagoon", comment: "Name of a curated space color, in the space editor. Deep teal running into deep blue.")
        case .sunset: String(localized: "Sunset", comment: "Name of a curated space color, in the space editor. Coral running into violet.")
        case .dusk: String(localized: "Dusk", comment: "Name of a curated space color, in the space editor. Deep indigo running into deep rose.")
        case .citrus: String(localized: "Citrus", comment: "Name of a curated space color, in the space editor. Lime running into tangerine.")
        case .midnight: String(localized: "Midnight", comment: "Name of a curated space color, in the space editor. A deep midnight indigo.")
        case .petrol: String(localized: "Petrol", comment: "Name of a curated space color, in the space editor. A deep inky teal.")
        case .forest: String(localized: "Forest", comment: "Name of a curated space color, in the space editor. A deep forest green.")
        case .merlot: String(localized: "Merlot", comment: "Name of a curated space color, in the space editor. A deep red wine.")
        case .watermelon: String(localized: "Watermelon", comment: "Name of a curated space color, in the space editor. A bright pinkish red.")
        case .fuchsia: String(localized: "Fuchsia", comment: "Name of a curated space color, in the space editor. A hot magenta.")
        case .volt: String(localized: "Volt", comment: "Name of a curated space color, in the space editor. An electric lime green.")
        case .lilac: String(localized: "Lilac", comment: "Name of a curated space color, in the space editor. A soft lilac.")
        case .seafoam: String(localized: "Seafoam", comment: "Name of a curated space color, in the space editor. A soft mint green.")
        case .dune: String(localized: "Dune", comment: "Name of a curated space color, in the space editor. A soft sandy gold.")
        }
    }

    /// Where each curated color sits on the wheel (red at 0). Chosen so the set reads as a family: neighbors far
    /// enough apart to tell at a glance, none of them loud.
    private var wheelHue: Double? {
        switch self {
        case .snow, .graphite, .ink: nil
        case .sky: 0.585
        case .sage: 0.29
        case .sand: 0.11
        case .rose: 0.935
        case .lavender: 0.765
        case .mint: 0.46
        case .peach: 0.055
        case .lagoon: 0.5
        case .sunset: 0.015
        case .dusk: 0.72
        case .citrus: 0.22
        case .midnight: 0.7
        case .petrol: 0.48
        case .forest: 0.38
        case .merlot: 0.94
        case .watermelon: 0.97
        case .fuchsia: 0.87
        case .volt: 0.22
        case .lilac: 0.76
        case .seafoam: 0.45
        case .dune: 0.12
        }
    }

    /// The window frame color: for the hues, one soft lightness and one gentle chroma in OKLCH (`Tokens.Frame`), so
    /// every curated color weighs the same and any two of them sit well side by side; a deep, quiet tint of the same
    /// hue at night.
    var background: NSColor {
        switch self {
        // White and black are pure, day and night alike: the two you can count on to be exactly that.
        case .snow: return Tokens.Color.hex(0xFFFFFF)
        case .graphite: return Tokens.Color.dynamic(light: Tokens.Color.hex(0xE4E4E2), dark: Tokens.Color.hex(0x1F1F21))
        case .ink: return Tokens.Color.hex(0x000000)
        case _ where Self.palette.contains(self):
            // Only shown for a space given the color without its look: soft by day and deep at night.
            let h = wheelHue ?? 0.6
            return Tokens.Color.dynamic(light: Self.tone(hue: h, lightness: Tokens.Frame.paletteLightness, chroma: Tokens.Frame.paletteChroma),
                                        dark: Self.tone(hue: h, lightness: Tokens.Frame.paletteDarkLightness, chroma: Tokens.Frame.paletteDarkChroma))
        default:
            let h = wheelHue ?? 0.6
            // Blue reads louder than the others at the same chroma on a screen: sky is a step dustier.
            let k = self == .sky ? 0.78 : 1
            return Tokens.Color.dynamic(light: Self.tone(hue: h, lightness: Tokens.Frame.lightness, chroma: Tokens.Frame.chroma * k),
                                        dark: Self.tone(hue: h, lightness: Tokens.Frame.darkLightness, chroma: Tokens.Frame.darkChroma * k))
        }
    }

    /// A palette color's dot: its own color at the look's depth, a step lighter.
    private var paletteSwatch: NSColor? {
        paletteLook.map { SpaceColor.paint(hue: $0.hue, depth: 0.35 + 0.45 * $0.depth, tint: $0.tint) }
    }

    /// A wheel hue at an OKLCH lightness and chroma, eased off where a screen can't show that much color.
    static func tone(hue: Double, lightness: Double, chroma: Double) -> NSColor {
        let angle = okHue(hue)
        var c = chroma
        var rgb = OKLab.rgb(l: lightness, a: c * cos(angle), b: c * sin(angle))
        while !OKLab.inGamut(rgb), c > 0.002 {
            c *= 0.94
            rgb = OKLab.rgb(l: lightness, a: c * cos(angle), b: c * sin(angle))
        }
        let e = rgb.map { OKLab.encode(min(max($0, 0), 1)) }
        return NSColor(srgbRed: e[0], green: e[1], blue: e[2], alpha: 1)
    }

    /// Any hue, at the same tuned lightness as the curated tints, so every choice looks right in both modes.
    static let defaultIntensity = 0.4

    static func background(hue: Double, intensity: Double = defaultIntensity) -> NSColor {
        let t = min(max(intensity, 0), 1)
        // At the default strength, exactly a curated color's softness; stronger or fainter around it.
        let k = 0.4 + 1.5 * t
        return Tokens.Color.dynamic(light: tone(hue: hue, lightness: Tokens.Frame.lightness, chroma: Tokens.Frame.chroma * k),
                                    dark: tone(hue: hue, lightness: Tokens.Frame.darkLightness, chroma: Tokens.Frame.darkChroma * k))
    }

    /// A space's color: `hue` (red at 0, as on any color wheel), `depth` from near white (0) to deep (1), and `tint`,
    /// how much of the hue it has, from none (white, a gray or black at that depth) to all of it. Mixed in OKLCH, so
    /// every hue at one depth is equally light: a yellow and a blue at the same depth weigh the same, and the window's
    /// mode can follow depth alone.
    static func paint(hue: Double, depth: Double, tint: Double = 1) -> NSColor {
        let d = min(max(depth, 0), 1)
        // Soft through the middle; the very ends of the range run out to pure white and true black, so the lightest
        // and darkest a space can be are exactly that.
        let lightness: Double
        if d < 0.04 { lightness = 1 - (1 - 0.94740) * d / 0.04 }
        else if d > 0.9 { lightness = 0.354 * (1 - d) / 0.1 }
        else { lightness = 0.975 - 0.69 * d }
        // A whisper of color when pale, richest around halfway, a little quieter again in the deep.
        let rise = min(d / 0.5, 1)
        let most = 0.02 + 0.13 * rise * rise * (3 - 2 * rise) - 0.03 * max(0, d - 0.65) / 0.35
        // The color fades out into true black at the very end, as it does into white at the other.
        var chroma = most * min(max(tint, 0), 1) * min(1, lightness / 0.12) * min(1, (1 - lightness) / 0.04)
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

    /// The depth whose gray is this white (0 black, 1 white), as near as depths reach: how see-through spaces from
    /// before 0.4, washed in plain white to black, keep their shade.
    static func depth(ofWhite white: Double) -> Double {
        let lightness = cbrt(OKLab.decode(CGFloat(min(max(white, 0), 1))))
        // `paint`'s lightness, run backward, ends and all.
        if lightness > 0.9474 { return min(max(0.04 * (1 - lightness) / (1 - 0.9474), 0), 0.04) }
        if lightness < 0.354 { return min(max(1 - 0.1 * lightness / 0.354, 0.9), 1) }
        return min(max((0.975 - lightness) / 0.69, 0), 1)
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
        if let wheelHue { return wheelHue }
        let c = (swatch.usingColorSpace(.sRGB) ?? swatch)
        return Double(c.hueComponent)
    }

    /// A stronger version of the color, for small swatches and the space dot: the same hue, deeper and richer.
    var swatch: NSColor {
        switch self {
        case .snow: return Tokens.Color.dynamic(light: Tokens.Color.hex(0xFFFFFF), dark: Tokens.Color.hex(0xF2F2F7))
        case .graphite: return Tokens.Color.dynamic(light: Tokens.Color.hex(0x8E8E93), dark: Tokens.Color.hex(0x98989D))
        case .ink: return Tokens.Color.dynamic(light: Tokens.Color.hex(0x1C1C1E), dark: Tokens.Color.hex(0x000000))
        case _ where Self.palette.contains(self):
            return paletteSwatch ?? .gray
        default:
            let h = wheelHue ?? 0.6
            return Tokens.Color.dynamic(light: Self.tone(hue: h, lightness: 0.7, chroma: 0.105),
                                        dark: Self.tone(hue: h, lightness: 0.76, chroma: 0.095))
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
