import AppKit

/// The curated set of space tints. One color per space colors the whole window frame.
/// Light values are pale enough for dark text, dark values deep enough for light text.
enum SpaceColor: String, Codable, CaseIterable {
    case snow, graphite, ink, sky, sage, sand, rose, lavender, mint, peach
    case slate, stone, smoke, azure, navy, seafoam, pine, fern, citron, coral, red, iris, pink
    case mist, dew, shell, orchid

    /// The space editor's glass (`look`): neutrals, the washes, then cool, then warm, then the violet and the pink.
    static let palette: [SpaceColor] = neutrals + washes + [.azure, .navy, .seafoam, .pine, .fern, .citron, .coral, .red, .iris, .pink]
    /// The neutral glasses, which lead the editor's row with white.
    static let neutrals: [SpaceColor] = [.slate, .stone, .smoke]
    /// Near-white glass with a faint tint, after white in the editor's row. New spaces don't get them.
    static let washes: [SpaceColor] = [.mist, .dew, .shell, .orchid]
    /// The order new spaces take them in: slate first, then each far from the one before.
    static let newSpaceOrder: [SpaceColor] = [.slate, .fern, .coral, .azure, .pine, .citron, .navy, .red, .seafoam, .iris, .smoke, .pink, .stone]
    /// The palette of the 0.9.4 betas, by the name each was saved under, and the color it reads as now.
    static let renamed: [String: SpaceColor] = [
        "lagoon": .slate, "sunset": .coral, "dusk": .navy, "citrus": .citron, "midnight": .navy, "petrol": .pine,
        "forest": .pine, "merlot": .red, "watermelon": .coral, "fuchsia": .pink, "volt": .fern, "lilac": .iris, "dune": .stone,
    ]
    /// A saved color's name, the betas' palette included; nil for one this version doesn't know.
    static func named(_ name: String) -> SpaceColor? { SpaceColor(rawValue: name) ?? renamed[name] }
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

    /// A palette color on clear glass. `hue` and `hue2` are wheel hues, `depth` and `tint` as `paint` takes them (tint
    /// past 1 for the lively ones, richer than a custom color goes), `seeThrough` the space's translucency. A new space
    /// follows the Mac between `day` and `night` depths; picked in the editor it keeps `depth`. `grain` and `texture`
    /// are its finish, as `SpaceInfo` keeps them; most have none.
    struct PaletteLook {
        let hue: Double
        let depth: Double
        let tint: Double
        var hue2: Double? = nil
        var depth2: Double? = nil
        let seeThrough: Double
        let day: Double
        let night: Double
        var grain: Double = 0
        var texture: String? = nil
    }

    /// The palette's looks: nil for the colors from before. Light tints of clear glass by day, all but Smoke and Navy.
    var paletteLook: PaletteLook? {
        switch self {
        case .slate: PaletteLook(hue: 0.5689, depth: 0.09, tint: 0.29, seeThrough: 0.7, day: 0.09, night: 0.94)
        case .stone: PaletteLook(hue: 0.126, depth: 0.07, tint: 0.28, seeThrough: 0.7, day: 0.07, night: 0.94, grain: 0.5, texture: "linen")
        case .smoke: PaletteLook(hue: 0.58, depth: 0.95, tint: 0.2, seeThrough: 0.7, day: 0.95, night: 0.95, grain: 0.5)
        case .azure: PaletteLook(hue: 0.5499, depth: 0.16, tint: 1.4, seeThrough: 0.7, day: 0.16, night: 0.94)
        case .navy: PaletteLook(hue: 0.6066, depth: 0.93, tint: 1, hue2: 0.7088, depth2: 0.95, seeThrough: 0.7, day: 0.18, night: 0.94)
        case .seafoam: PaletteLook(hue: 0.483, depth: 0.1, tint: 1.1, seeThrough: 0.7, day: 0.1, night: 0.94)
        case .pine: PaletteLook(hue: 0.4551, depth: 0.2, tint: 1.3, seeThrough: 0.7, day: 0.2, night: 0.94)
        case .fern: PaletteLook(hue: 0.3105, depth: 0.16, tint: 1.4, seeThrough: 0.7, day: 0.16, night: 0.94)
        case .citron: PaletteLook(hue: 0.1447, depth: 0.1, tint: 1.5, seeThrough: 0.7, day: 0.1, night: 0.1)
        case .coral: PaletteLook(hue: 0.0634, depth: 0.14, tint: 1.4, hue2: 0.03, depth2: 0.17, seeThrough: 0.7, day: 0.14, night: 0.14, grain: 0.35)
        case .red: PaletteLook(hue: 0.9808, depth: 0.18, tint: 1.5, seeThrough: 0.7, day: 0.18, night: 0.94)
        case .iris: PaletteLook(hue: 0.7425, depth: 0.14, tint: 1.35, hue2: 0.7627, depth2: 0.17, seeThrough: 0.7, day: 0.14, night: 0.94)
        case .pink: PaletteLook(hue: 0.9005, depth: 0.14, tint: 1.35, seeThrough: 0.7, day: 0.14, night: 0.94)
        case .mist: PaletteLook(hue: 0.6, depth: 0.05, tint: 1, seeThrough: 0.76, day: 0.05, night: 0.95)
        case .dew: PaletteLook(hue: 0.42, depth: 0.05, tint: 1, seeThrough: 0.76, day: 0.05, night: 0.95)
        case .shell: PaletteLook(hue: 0.075, depth: 0.05, tint: 1, seeThrough: 0.76, day: 0.05, night: 0.96)
        case .orchid: PaletteLook(hue: 0.8, depth: 0.05, tint: 1, seeThrough: 0.76, day: 0.05, night: 0.95)
        default: nil
        }
    }

    /// The look the 0.9.4 betas gave each palette color, before its clear glass: a space saved in one takes the new
    /// one (`SpaceInfo.upgraded`).
    var earlierLook: PaletteLook? {
        switch self {
        case .slate: PaletteLook(hue: 0.5689, depth: 0.16, tint: 0.28, seeThrough: 0.55, day: 0.16, night: 0.93)
        case .stone: PaletteLook(hue: 0.126, depth: 0.16, tint: 0.1, seeThrough: 0.55, day: 0.16, night: 0.93)
        case .smoke: PaletteLook(hue: 0.58, depth: 0.92, tint: 0.18, seeThrough: 0.45, day: 0.92, night: 0.92)
        case .azure: PaletteLook(hue: 0.5499, depth: 0.32, tint: 1.1, seeThrough: 0.5, day: 0.32, night: 0.92)
        case .navy: PaletteLook(hue: 0.6066, depth: 0.92, tint: 1, hue2: 0.7088, depth2: 0.94, seeThrough: 0.45, day: 0.3, night: 0.92)
        case .seafoam: PaletteLook(hue: 0.483, depth: 0.14, tint: 0.85, seeThrough: 0.55, day: 0.14, night: 0.93)
        case .pine: PaletteLook(hue: 0.4551, depth: 0.92, tint: 1, seeThrough: 0.45, day: 0.3, night: 0.92)
        case .fern: PaletteLook(hue: 0.3105, depth: 0.34, tint: 1.1, seeThrough: 0.5, day: 0.34, night: 0.92)
        case .citron: PaletteLook(hue: 0.1447, depth: 0.18, tint: 1.4, seeThrough: 0.5, day: 0.18, night: 0.18)
        case .coral: PaletteLook(hue: 0.0634, depth: 0.28, tint: 1.25, hue2: 0.03, depth2: 0.315, seeThrough: 0.5, day: 0.28, night: 0.28)
        case .red: PaletteLook(hue: 0.9808, depth: 0.76, tint: 1.35, seeThrough: 0.35, day: 0.76, night: 0.86)
        case .iris: PaletteLook(hue: 0.7425, depth: 0.28, tint: 1.15, hue2: 0.7627, depth2: 0.315, seeThrough: 0.5, day: 0.28, night: 0.92)
        case .pink: PaletteLook(hue: 0.9005, depth: 0.28, tint: 1.15, seeThrough: 0.5, day: 0.28, night: 0.92)
        case .mist: PaletteLook(hue: 0.6, depth: 0.07, tint: 0.9, seeThrough: 0.4, day: 0.07, night: 0.95)
        case .dew: PaletteLook(hue: 0.42, depth: 0.07, tint: 0.8, seeThrough: 0.4, day: 0.07, night: 0.95)
        case .shell: PaletteLook(hue: 0.075, depth: 0.07, tint: 0.9, seeThrough: 0.4, day: 0.07, night: 0.97)
        case .orchid: PaletteLook(hue: 0.8, depth: 0.07, tint: 0.8, seeThrough: 0.4, day: 0.07, night: 0.95)
        default: nil
        }
    }

    /// Without a hue: pure white, gray and black. A gradient or a hue doesn't apply to them.
    var isNeutral: Bool { self == .snow || self == .graphite || self == .ink }

    /// A colour this version doesn't know (saved by a newer one) reads as graphite, rather than making the whole
    /// library unreadable.
    init(from decoder: Decoder) throws {
        self = SpaceColor.named(try decoder.singleValueContainer().decode(String.self)) ?? .graphite
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
        case .slate: String(localized: "Slate", comment: "Name of a curated space color, in the space editor. A clear, barely cool gray glass.")
        case .stone: String(localized: "Stone", comment: "Name of a curated space color, in the space editor. A clear, barely warm gray glass.")
        case .smoke: String(localized: "Smoke", comment: "Name of a curated space color, in the space editor. A deep smoked graphite glass.")
        case .azure: String(localized: "Azure", comment: "Name of a curated space color, in the space editor. A clear sky blue.")
        case .navy: String(localized: "Navy", comment: "Name of a curated space color, in the space editor. A deep navy blue.")
        case .seafoam: String(localized: "Seafoam", comment: "Name of a curated space color, in the space editor. A soft mint green.")
        case .pine: String(localized: "Pine", comment: "Name of a curated space color, in the space editor. A deep pine green.")
        case .fern: String(localized: "Fern", comment: "Name of a curated space color, in the space editor. A fresh leaf green.")
        case .citron: String(localized: "Citron", comment: "Name of a curated space color, in the space editor. A pale lemon yellow.")
        case .coral: String(localized: "Coral", comment: "Name of a curated space color, in the space editor. A warm coral orange.")
        case .red: String(localized: "Red", comment: "Name of a curated space color, in the space editor. A true red.")
        case .iris: String(localized: "Iris", comment: "Name of a curated space color, in the space editor. A blue violet.")
        case .pink: String(localized: "Pink", comment: "Name of a curated space color, in the space editor. A clear pink.")
        case .mist: String(localized: "Mist", comment: "Name of a curated space color, in the space editor. A near-white glass with a faint cool blue tint.")
        case .dew: String(localized: "Dew", comment: "Name of a curated space color, in the space editor. A near-white glass with a faint mint green tint.")
        case .shell: String(localized: "Shell", comment: "Name of a curated space color, in the space editor. A near-white glass with a faint warm peach tint, like a seashell.")
        case .orchid: String(localized: "Orchid", comment: "Name of a curated space color, in the space editor. A near-white glass with a faint lilac tint.")
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
        default: paletteLook?.hue
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
    /// how much of the hue it has, from none (white, a gray or black at that depth) to all of it, and up to `maxTint`. Mixed in OKLCH, so
    /// every hue at one depth is equally light: a yellow and a blue at the same depth weigh the same, and the window's
    /// mode can follow depth alone.
    /// The richest tint a space takes: the palette's lively colors go past a custom color's 1.
    static let maxTint = 1.5

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
        var chroma = most * min(max(tint, 0), maxTint) * min(1, lightness / 0.12) * min(1, (1 - lightness) / 0.04)
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
