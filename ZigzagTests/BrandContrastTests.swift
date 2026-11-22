import AppKit
import Testing
@testable import Zigzag

/// The primary button's text has to be readable in every space color, in light and dark.
@MainActor
struct BrandContrastTests {
    func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    func check(_ theme: Brand.Theme, _ label: String) {
        for dark in [false, true] {
            let ratio = Brand.contrast(resolved(theme.accent, dark: dark), resolved(theme.onAccent, dark: dark))
            #expect(ratio >= 4.5, "\(label) \(dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
        }
    }

    @Test func everyCuratedSpaceColor() {
        for color in SpaceColor.allCases {
            check(color == .graphite || color == .sky ? .navy : Brand.Theme(hue: color.hue), color.name)
        }
        check(.navy, "Navy")
    }

    @Test func accentsKeepTheSpacesHue() {
        // Whatever the space's color, its accent looks like that color in both appearances, not a neighbor's.
        for degrees in stride(from: 0.0, to: 360, by: 10) {
            let wanted = SpaceColor.okHue(degrees / 360)
            for dark in [false, true] {
                let accent = resolved(Brand.Theme(hue: degrees / 360).accent, dark: dark)
                let lab = OKLab.lab(r: OKLab.decode(accent.redComponent), g: OKLab.decode(accent.greenComponent), b: OKLab.decode(accent.blueComponent))
                let got = atan2(lab.b, lab.a)
                let off = abs(remainder(got - wanted, 2 * .pi)) * 180 / .pi
                #expect(off < 4, "\(degrees)° \(dark ? "dark" : "light"): off by \(Int(off))°")
            }
        }
    }

    @Test func everyHue() {
        for step in 0..<72 { check(Brand.Theme(hue: Double(step) / 72), "hue \(step * 5)°") }
    }

    @Test func accentStandsOffItsSurface() {
        // Selection and markers sit on the window and card backgrounds: the accent must still show (3:1, non-text).
        for step in 0..<36 {
            let theme = Brand.Theme(hue: Double(step) / 36)
            #expect(Brand.contrast(resolved(theme.accent, dark: false), resolved(Tokens.Color.formBackground, dark: false)) >= 3)
            #expect(Brand.contrast(resolved(theme.accent, dark: true), resolved(Tokens.Color.formBackground, dark: true)) >= 3)
        }
    }

    @Test func spaceInkPassesOnItsOwnFrame() {
        // Whatever a space's color, its row and quiet inks read at AA on its frame, or fall back to the plain text.
        var spaces = SpaceColor.allCases.map { SpaceInfo(name: $0.name, color: $0) }
        for depth in stride(from: 0.0, through: 1, by: 0.1) {
            var custom = SpaceInfo(name: "custom", color: .sky)
            custom.hue = 0.3
            custom.brightness = depth
            spaces.append(custom)
        }
        for space in spaces {
            let theme = Brand.Theme.of(space)
            for dark in [false, true] {
                let frame = resolved(space.background, dark: dark)
                for (ink, plain) in [(theme.rowInk, Tokens.Color.textPrimary), (theme.quietInk, Tokens.Color.textSecondary)] {
                    let shown = resolved(ink, dark: dark), plainShown = resolved(plain, dark: dark)
                    let isPlain = shown.redComponent == plainShown.redComponent && shown.alphaComponent == plainShown.alphaComponent
                    #expect(isPlain || Brand.contrast(shown, frame) >= 4.5, "\(space.name) \(space.brightness ?? -1) \(dark)")
                }
            }
        }
        // The curated colors all keep their ink in both modes.
        for color in SpaceColor.allCases where !color.isNeutral {
            let theme = Brand.Theme.of(SpaceInfo(name: color.name, color: color))
            for dark in [false, true] {
                #expect(resolved(theme.rowInk, dark: dark).alphaComponent == 1, "\(color.name) \(dark)")
            }
        }
    }

    /// `top` (alpha times `alpha`) composited over opaque `ground`.
    func over(_ top: NSColor, _ ground: NSColor, alpha: CGFloat = 1) -> NSColor {
        let a = top.alphaComponent * alpha
        return NSColor(srgbRed: top.redComponent * a + ground.redComponent * (1 - a), green: top.greenComponent * a + ground.greenComponent * (1 - a),
                       blue: top.blueComponent * a + ground.blueComponent * (1 - a), alpha: 1)
    }

    @Test func disabledControlsStillRead() {
        // Disabled controls keep text at 3:1 or better, light and dark, on panels and pages.
        for dark in [false, true] {
            for ground in [Tokens.Color.panelBackground, Tokens.Color.formBackground] {
                let bg = resolved(ground, dark: dark)
                // Text-only buttons use the disabled ink, not faded.
                let words = over(resolved(Tokens.Color.textDisabled, dark: dark), bg)
                #expect(Brand.contrast(words, bg) >= 3, "quiet \(dark) \(bg)")
                // Filled buttons fade as a whole to `Opacity.disabled`.
                let fill = over(resolved(Tokens.Color.controlFill, dark: dark), bg)
                let ink = over(resolved(Tokens.Color.textPrimary, dark: dark), fill)
                let shownFill = over(fill, bg, alpha: Tokens.Opacity.disabled), shownInk = over(ink, bg, alpha: Tokens.Opacity.disabled)
                #expect(Brand.contrast(shownInk, shownFill) >= 3, "plain \(dark) \(bg): \(Brand.contrast(shownInk, shownFill))")
            }
        }
        // A disabled quiet button isn't faded on top of the ink.
        let quiet = PillButton(title: "Use Default Colors", style: .quiet)
        quiet.isEnabled = false
        let label = quiet.subviews.compactMap { $0 as? Label }.first
        for dark in [false, true] {
            #expect(resolved(label?.textColor ?? .clear, dark: dark) == resolved(Tokens.Color.textDisabled, dark: dark))
        }
        #expect(quiet.alphaValue == 1)
        let text = TextButton(title: "Use Default Colors")
        text.isEnabled = false
        #expect(text.alphaValue == 1)
        #expect(text.subviews.compactMap { $0 as? Label }.allSatisfy { $0.alphaValue == 1 && $0.textColor == Tokens.Color.textDisabled })
    }

    @Test func aTintedButtonsTextReadsOnItsTint() {
        // Tinted prominent buttons pick readable text; white on the pale night accent was 2.6:1.
        for step in 0..<36 {
            let accent = Brand.Theme(hue: Double(step) / 36).accent
            let button = PillButton(title: "Allow", style: .prominent)
            button.tint = accent
            let label = button.subviews.compactMap { $0 as? Label }.first
            for dark in [false, true] {
                let ink = resolved(label?.textColor ?? .clear, dark: dark), fill = resolved(accent, dark: dark)
                let ratio = Brand.contrast(ink, fill)
                #expect(ratio >= 4.5, "hue \(step * 10)° \(dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
            }
        }
        // Other fills pick white or deep ink, whichever contrasts more.
        for fill in [NSColor.systemBlue, .systemRed, Brand.ribbon, Brand.navy, .white, .black] {
            for dark in [false, true] {
                let f = resolved(fill, dark: dark), ink = resolved(Brand.ink(on: fill), dark: dark)
                #expect(Brand.contrast(ink, f) >= Brand.contrast(.white, f) - 0.001, "\(f) \(dark)")
            }
        }
        #expect(Brand.contrast(resolved(Brand.ink(on: Brand.ribbon), dark: false), Brand.ribbon) >= 4.5)
        #expect(Brand.contrast(resolved(Brand.ink(on: Brand.navy), dark: true), Brand.navy) >= 4.5)
    }

    /// `ink` composited over `ground`.
    private func over(_ ink: NSColor, _ ground: NSColor) -> NSColor {
        let i = ink.usingColorSpace(.sRGB)!, g = ground.usingColorSpace(.sRGB)!
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b + (a - b) * i.alphaComponent }
        return NSColor(srgbRed: mix(i.redComponent, g.redComponent), green: mix(i.greenComponent, g.greenComponent),
                       blue: mix(i.blueComponent, g.blueComponent), alpha: 1)
    }

    /// Disabled Back and Skip in the welcome window stay 3:1 on its blue, including the lit corner.
    @Test func disabledTextInItsOwnColorStaysReadable() {
        let ink = Brand.ribbon.withAlphaComponent(0.75)
        let button = TextButton(title: "Back", font: Tokens.Font.body(.medium))
        button.textColor = ink
        button.isEnabled = false
        for dark in [false, true] {
            let deep = resolved(Brand.Theme.brand.deep, dark: dark)
            let lit = deep.blended(withFraction: 0.12, of: .white)!
            let disabled = resolved(TextButton.disabledInk(ink), dark: dark)
            #expect(resolved(button.label.textColor!, dark: dark) == disabled)
            for ground in [deep, lit] {
                let off = Brand.contrast(over(disabled, ground), ground), on = Brand.contrast(over(ink, ground), ground)
                #expect(off >= 3, "\(dark ? "dark" : "light"): \(String(format: "%.2f", off)):1 against \(String(format: "%.2f", on)):1")
                #expect(off < on - 0.5)
            }
        }
    }

    /// The welcome's Back and Skip as pill buttons: their own ink, faded the same readable way when disabled.
    @Test func aQuietPillInItsOwnColorFadesReadably() {
        let ink = Brand.ribbon.withAlphaComponent(0.75)
        let button = PillButton(title: "Back", style: .quiet)
        button.customInk = ink
        #expect(button.debugInk == ink)
        button.isEnabled = false
        for dark in [false, true] {
            #expect(resolved(button.debugInk!, dark: dark) == resolved(TextButton.disabledInk(ink), dark: dark))
        }
    }
}
