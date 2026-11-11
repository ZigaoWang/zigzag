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
        ("Switch.track", Tokens.Switch.track, 0x000000, 0.075, 0x000000, 0.32),
        ("Switch.trackHover", Tokens.Switch.trackHover, 0x000000, 0.095, 0x000000, 0.36),
        ("Switch.trackPressed", Tokens.Switch.trackPressed, 0x000000, 0.115, 0x000000, 0.4),
        ("Switch.edge", Tokens.Switch.edge, 0x000000, 0.06, 0xFFFFFF, 0.06),
        ("Switch.knobEdge", Tokens.Switch.knobEdge, 0x000000, 0.11, 0x000000, 0.3),
        ("Chrome.card", Tokens.Chrome.card, 0xFFFFFF, 0.96, 0xFFFFFF, 0.18),
        ("Chrome.cardHover", Tokens.Chrome.cardHover, 0xFFFFFF, 1, 0xFFFFFF, 0.21),
        ("Chrome.cardEdge", Tokens.Chrome.cardEdge, 0x000000, 0.035, 0xFFFFFF, 0.035),
        ("Chrome.hover", Tokens.Chrome.hover, 0xFFFFFF, 0.38, 0xFFFFFF, 0.05),
        ("Chrome.quietHover", Tokens.Chrome.quietHover, 0xFFFFFF, 0.22, 0xFFFFFF, 0.03),
        ("Chrome.pressed", Tokens.Chrome.pressed, 0xFFFFFF, 0.28, 0xFFFFFF, 0.035),
        ("Chrome.field", Tokens.Chrome.field, 0xFFFFFF, 0.45, 0xFFFFFF, 0.065),
        ("Chrome.fieldHover", Tokens.Chrome.fieldHover, 0xFFFFFF, 0.62, 0xFFFFFF, 0.095),
        ("Chrome.fieldPressed", Tokens.Chrome.fieldPressed, 0xFFFFFF, 0.52, 0xFFFFFF, 0.08),
        ("Chrome.key", Tokens.Chrome.key, 0xFFFFFF, 0.5, 0xFFFFFF, 0.07),
        ("Chrome.keyEdge", Tokens.Chrome.keyEdge, 0x000000, 0.07, 0xFFFFFF, 0.09),
        ("Chrome.openEdge", Tokens.Chrome.openEdge, 0x000000, 0.1, 0xFFFFFF, 0.16),
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
