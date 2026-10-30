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
}
