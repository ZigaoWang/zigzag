import AppKit
import Testing
@testable import Zigzag

/// Increase Contrast (#105): every token with a stronger version takes it, in light and dark, and stays exactly as it
/// was without it.
@MainActor
@Suite(.serialized)
struct ContrastTokensTests {
    /// Each token as it was before Increase Contrast: its color and alpha by day, then at night.
    static let normal: [(String, NSColor, UInt32, CGFloat, UInt32, CGFloat)] = [
        ("Color.textPrimary", Tokens.Color.textPrimary, 0x000000, 0.86, 0xFFFFFF, 0.92),
        ("Color.textSecondary", Tokens.Color.textSecondary, 0x000000, 0.54, 0xFFFFFF, 0.56),
        ("Color.textTertiary", Tokens.Color.textTertiary, 0x000000, 0.45, 0xFFFFFF, 0.42),
        ("Color.icon", Tokens.Color.icon, 0x000000, 0.62, 0xFFFFFF, 0.66),
        ("Color.chromeIcon", Tokens.Color.chromeIcon, 0x000000, 0.72, 0xFFFFFF, 0.78),
        ("Color.hoverFill", Tokens.Color.hoverFill, 0x000000, 0.05, 0xFFFFFF, 0.06),
        ("Color.pressedFill", Tokens.Color.pressedFill, 0x000000, 0.09, 0xFFFFFF, 0.10),
        ("Color.selectedFill", Tokens.Color.selectedFill, 0x000000, 0.09, 0xFFFFFF, 0.11),
        ("Color.selectedHoverFill", Tokens.Color.selectedHoverFill, 0x000000, 0.11, 0xFFFFFF, 0.13),
        ("Color.selectedEdge", Tokens.Color.selectedEdge, 0x000000, 0.06, 0xFFFFFF, 0.06),
        ("Color.chromeFill", Tokens.Color.chromeFill, 0x000000, 0.05, 0xFFFFFF, 0.07),
        ("Color.chromeHover", Tokens.Color.chromeHover, 0x000000, 0.075, 0xFFFFFF, 0.10),
        ("Color.chromeEdge", Tokens.Color.chromeEdge, 0x000000, 0.08, 0xFFFFFF, 0.08),
        ("Color.glassFill", Tokens.Color.glassFill, 0xFFFFFF, 0.32, 0xFFFFFF, 0.06),
        ("Color.glassHover", Tokens.Color.glassHover, 0xFFFFFF, 0.5, 0xFFFFFF, 0.1),
        ("Color.glassEdge", Tokens.Color.glassEdge, 0xFFFFFF, 0.55, 0xFFFFFF, 0.08),
        ("Color.openEdge", Tokens.Color.openEdge, 0x000000, 0.16, 0xFFFFFF, 0.2),
        ("Color.highlight", Tokens.Color.highlight, 0x000000, 0.07, 0xFFFFFF, 0.09),
        ("Color.fieldFill", Tokens.Color.fieldFill, 0x000000, 0.045, 0xFFFFFF, 0.06),
        ("Color.controlEdge", Tokens.Color.controlEdge, 0x000000, 0.12, 0xFFFFFF, 0.1),
        ("Color.separator", Tokens.Color.separator, 0x000000, 0.08, 0xFFFFFF, 0.08),
        ("Color.cardEdge", Tokens.Color.cardEdge, 0x000000, 0.07, 0xFFFFFF, 0.07),
        ("Color.panelEdge", Tokens.Color.panelEdge, 0x000000, 0.09, 0xFFFFFF, 0.10),
        ("Color.surfaceGroupEdge", Tokens.Color.surfaceGroupEdge, 0x000000, 0.08, 0xFFFFFF, 0.06),
        ("Color.keyCapFill", Tokens.Color.keyCapFill, 0x000000, 0.04, 0xFFFFFF, 0.07),
        ("Color.keyCapEdge", Tokens.Color.keyCapEdge, 0x000000, 0.1, 0xFFFFFF, 0.1),
        ("Color.progress", Tokens.Color.progress, 0x000000, 0.28, 0xFFFFFF, 0.32),
        ("Switch.track", Tokens.Switch.track, 0x000000, 0.075, 0xFFFFFF, 0.16),
        ("Switch.trackHover", Tokens.Switch.trackHover, 0x000000, 0.095, 0xFFFFFF, 0.19),
        ("Switch.trackPressed", Tokens.Switch.trackPressed, 0x000000, 0.115, 0xFFFFFF, 0.22),
        ("Switch.edge", Tokens.Switch.edge, 0x000000, 0.06, 0xFFFFFF, 0.08),
        ("Switch.knobEdge", Tokens.Switch.knobEdge, 0x000000, 0.11, 0x000000, 0.3),
        ("Chrome.card", Tokens.Chrome.card, 0xFFFFFF, 0.96, 0xFFFFFF, 0.18),
        ("Chrome.cardHover", Tokens.Chrome.cardHover, 0xFFFFFF, 1, 0xFFFFFF, 0.21),
        ("Chrome.cardEdge", Tokens.Chrome.cardEdge, 0x000000, 0.035, 0xFFFFFF, 0.035),
        ("Chrome.hover", Tokens.Chrome.hover, 0x000000, 0.06, 0xFFFFFF, 0.065),
        ("Chrome.quietHover", Tokens.Chrome.quietHover, 0x000000, 0.035, 0xFFFFFF, 0.04),
        ("Chrome.pressed", Tokens.Chrome.pressed, 0x000000, 0.10, 0xFFFFFF, 0.10),
        ("Chrome.field", Tokens.Chrome.field, 0xFFFFFF, 0.45, 0xFFFFFF, 0.065),
        ("Chrome.fieldHover", Tokens.Chrome.fieldHover, 0xFFFFFF, 0.62, 0xFFFFFF, 0.095),
        ("Chrome.fieldPressed", Tokens.Chrome.fieldPressed, 0xFFFFFF, 0.52, 0xFFFFFF, 0.08),
        ("Chrome.key", Tokens.Chrome.key, 0xFFFFFF, 0.5, 0xFFFFFF, 0.07),
        ("Chrome.keyEdge", Tokens.Chrome.keyEdge, 0x000000, 0.07, 0xFFFFFF, 0.09),
        ("Chrome.openEdge", Tokens.Chrome.openEdge, 0x000000, 0.035, 0xFFFFFF, 0.03),
    ]

    /// A color as drawn by day or at night, with Increase Contrast forced on or off whatever the Mac says.
    func resolved(_ color: NSColor, dark: Bool, high: Bool) -> NSColor {
        let saved = Tokens.Contrast.debugOverride
        defer { Tokens.Contrast.debugOverride = saved }
        Tokens.Contrast.debugOverride = high
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// `color` laid over `ground`, opaque.
    func over(_ color: NSColor, _ ground: NSColor) -> NSColor {
        let a = color.alphaComponent
        return NSColor(srgbRed: color.redComponent * a + ground.redComponent * (1 - a),
                       green: color.greenComponent * a + ground.greenComponent * (1 - a),
                       blue: color.blueComponent * a + ground.blueComponent * (1 - a), alpha: 1)
    }

    /// A space's frame by day and at night (sky), where the chrome's washes, edges and quiet words sit.
    func frame(dark: Bool) -> NSColor { resolved(SpaceColor.sky.background, dark: dark, high: false) }

    @Test func normalIsUnchanged() {
        for (name, color, light, lightAlpha, dark, darkAlpha) in Self.normal {
            for isDark in [false, true] {
                let got = resolved(color, dark: isDark, high: false)
                let want = Tokens.Color.hex(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
                let same = abs(got.redComponent - want.redComponent) < 0.001 && abs(got.greenComponent - want.greenComponent) < 0.001
                    && abs(got.blueComponent - want.blueComponent) < 0.001 && abs(got.alphaComponent - want.alphaComponent) < 0.001
                #expect(same, "\(name) \(isDark ? "dark" : "light") changed: \(got)")
            }
        }
    }

    @Test func everyTokenIsStrongerInHighContrast() {
        for (name, color, _, lightAlpha, _, _) in Self.normal {
            for dark in [false, true] {
                let ground = frame(dark: dark)
                let before = Brand.contrast(over(resolved(color, dark: dark, high: false), ground), ground)
                let after = Brand.contrast(over(resolved(color, dark: dark, high: true), ground), ground)
                // Only a card already pure white by day can't go further.
                let atLimit = !dark && name == "Chrome.cardHover" && lightAlpha == 1
                if atLimit {
                    #expect(after >= before, "\(name) light")
                } else {
                    #expect(after > before, "\(name) \(dark ? "dark" : "light"): \(before) to \(after)")
                }
            }
        }
    }

    @Test func quietTextPassesAAInHighContrast() {
        // Secondary and tertiary words on every surface they sit on: pages, panels, Settings, groups and the frame.
        let grounds = [Tokens.Color.surface, Tokens.Color.panelBackground, Tokens.Color.formBackground, Tokens.Color.surfaceGroup]
        for dark in [false, true] {
            for text in [Tokens.Color.textSecondary, Tokens.Color.textTertiary, Tokens.Color.icon] {
                for ground in grounds.map({ resolved($0, dark: dark, high: true) }) + [frame(dark: dark)] {
                    let ratio = Brand.contrast(over(resolved(text, dark: dark, high: true), ground), ground)
                    #expect(ratio >= 4.5, "\(dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    @Test func spaceInksDeepenInHighContrast() {
        for color in SpaceColor.allCases where !color.isNeutral {
            let theme = Brand.Theme.of(SpaceInfo(name: color.name, color: color))
            for dark in [false, true] {
                let ground = frame(dark: dark)
                for ink in [theme.rowInk, theme.quietInk] {
                    let before = Brand.contrast(resolved(ink, dark: dark, high: false), ground)
                    let after = Brand.contrast(resolved(ink, dark: dark, high: true), ground)
                    #expect(after >= before, "\(color.name) \(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// CIELAB lightness of an opaque sRGB color.
    func lightness(_ c: NSColor) -> Double {
        let y = 0.2126 * OKLab.decode(c.redComponent) + 0.7152 * OKLab.decode(c.greenComponent) + 0.0722 * OKLab.decode(c.blueComponent)
        return y > 216.0 / 24389 ? 116 * cbrt(y) - 16 : y * 24389 / 27
    }

    /// Light frames: white, the curated colors, the Sky and Paper looks, a barely tinted one. Dark: the curated colors
    /// at night, black, the Espresso and Slate looks.
    var lightFrames: [(String, NSColor)] {
        [("white", SpaceColor.paint(hue: 0, depth: 0, tint: 0)), ("pale", SpaceColor.paint(hue: 0.6, depth: 0.01, tint: 0.3)),
         ("paper", SpaceColor.paint(hue: 0.11, depth: 0.1, tint: 0.55)), ("sky look", SpaceColor.paint(hue: 0.6, depth: 0.04, tint: 0.6)),
         ("sky look end", SpaceColor.paint(hue: 0.6, depth: 0.34, tint: 0.6))]
            + SpaceColor.allCases.filter { $0 != .ink }.map { ($0.name, resolved($0.background, dark: false, high: false)) }
    }

    var darkFrames: [(String, NSColor)] {
        [("black", SpaceColor.paint(hue: 0, depth: 1, tint: 0)), ("espresso", SpaceColor.paint(hue: 0.07, depth: 0.8, tint: 0.45)),
         ("espresso end", SpaceColor.paint(hue: 0.07, depth: 0.93, tint: 0.45)), ("slate", SpaceColor.paint(hue: 0.62, depth: 0.76, tint: 0.35)),
         ("slate end", SpaceColor.paint(hue: 0.62, depth: 0.9, tint: 0.35))]
            + SpaceColor.allCases.filter { $0 != .snow }.map { ($0.name, resolved($0.background, dark: true, high: false)) }
    }

    /// Hover and pressed show on every space, white and black included, by about as much on each; pressed shows more
    /// than hover, and the selected card stands apart from both.
    @Test func hoverShowsOnEverySpace() {
        for dark in [false, true] {
            for (name, frame) in dark ? darkFrames : lightFrames {
                func step(_ wash: NSColor) -> Double { abs(lightness(over(resolved(wash, dark: dark, high: false), frame)) - lightness(frame)) }
                let hover = step(Tokens.Chrome.hover), pressed = step(Tokens.Chrome.pressed), quiet = step(Tokens.Chrome.quietHover)
                let card = lightness(over(resolved(Tokens.Chrome.card, dark: dark, high: false), frame))
                let hovered = lightness(over(resolved(Tokens.Chrome.hover, dark: dark, high: false), frame))
                let what = "\(name) \(dark ? "dark" : "light"): hover \(String(format: "%.1f", hover)) pressed \(String(format: "%.1f", pressed)) quiet \(String(format: "%.1f", quiet))"
                #expect((3.5...8).contains(hover), "\(what)")
                #expect(pressed > hover + 1.5, "\(what)")
                #expect(quiet >= 2 && quiet < hover, "\(what)")
                #expect(abs(card - hovered) > 4, "\(what) card \(String(format: "%.1f", card))")
            }
        }
    }

    /// A button's hover and press reach their contrast on every space, black and white included, measured on that
    /// space or with none given; pressed shows more than hover.
    @Test func buttonWashShowsOnEverySpace() {
        for dark in [false, true] {
            for (name, frame) in dark ? darkFrames : lightFrames {
                for grounds in [[frame], []] {
                    let hover = Brand.contrast(over(resolved(Tokens.Chrome.buttonWash(pressed: false, on: grounds), dark: dark, high: false), frame), frame)
                    let pressed = Brand.contrast(over(resolved(Tokens.Chrome.buttonWash(pressed: true, on: grounds), dark: dark, high: false), frame), frame)
                    let what = "\(name) \(dark ? "dark" : "light") \(grounds.isEmpty ? "unknown" : "known"): \(hover) \(pressed)"
                    #expect(hover >= (grounds.isEmpty ? 1.15 : 1.19), "\(what)")
                    #expect(pressed > hover + 0.1, "\(what)")
                }
            }
        }
    }

    /// The off switch track is lighter than the page at night, as in macOS.
    @Test func offSwitchStandsOutAtNight() {
        for ground in [Tokens.Color.surface, Tokens.Color.formBackground, Tokens.Color.panelBackground] {
            let page = resolved(ground, dark: true, high: false)
            let track = over(resolved(Tokens.Switch.track, dark: true, high: false), page)
            #expect(track.brightnessComponent > page.brightnessComponent)
            #expect(Brand.contrast(track, page) >= 1.3, "\(String(format: "%.2f", Brand.contrast(track, page))):1")
        }
    }

    @Test func panelWashIsOpaqueInHighContrast() {
        for dark in [false, true] {
            #expect(resolved(Tokens.Color.panelWash, dark: dark, high: true).alphaComponent == 1)
        }
    }

    @Test func plainAppearancesFollowTheSetting() {
        // AppKit hands out its high-contrast appearances only while the Mac's setting is on, so the setting decides.
        let saved = Tokens.Contrast.debugOverride
        defer { Tokens.Contrast.debugOverride = saved }
        Tokens.Contrast.debugOverride = false
        #expect(!Tokens.Contrast.isHigh(NSAppearance(named: .aqua)!))
        #expect(!Tokens.Contrast.isHigh(NSAppearance(named: .darkAqua)!))
        Tokens.Contrast.debugOverride = true
        #expect(Tokens.Contrast.isHigh(NSAppearance(named: .aqua)!))
        #expect(Tokens.Contrast.isHigh(NSAppearance(named: .darkAqua)!))
    }
}
