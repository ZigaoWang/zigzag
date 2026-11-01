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
}
