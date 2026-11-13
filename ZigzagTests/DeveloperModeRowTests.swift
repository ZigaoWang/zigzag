import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Developer Mode on a tab's row (#141): which parts carry the chip on their icon, what pointing at one says, where
/// the chip sits, and that its color reads on every space.
struct DeveloperModeRowTests {
    @Test func aRowOfOnePageInDeveloperModeHasTheChip() {
        #expect(TabRowView.developerBadges(inMode: [true]) == [0])
        #expect(TabRowView.developerBadges(inMode: [false]) == [])
    }

    @Test func aRowOfSeveralPagesMarksEachPartInDeveloperMode() {
        #expect(TabRowView.developerBadges(inMode: [false, true]) == [1])
        #expect(TabRowView.developerBadges(inMode: [true, true]) == [0, 1])
        #expect(TabRowView.developerBadges(inMode: [true, false, false, true]) == [0, 3])
        #expect(TabRowView.developerBadges(inMode: [false, false, false]) == [])
    }

    @MainActor @Test func theTipSaysTheModeThenTheHostWithItsPortAndWithoutWWW() {
        #expect(TabRowView.developerTip(for: URL(string: "https://www.Example.com/docs?x=1")) == "Developer Mode\nexample.com")
        #expect(TabRowView.developerTip(for: URL(string: "http://localhost:3000/admin")) == "Developer Mode\nlocalhost:3000")
        #expect(TabRowView.developerTip(for: URL(string: "https://app.example.com:8443/")) == "Developer Mode\napp.example.com:8443")
        #expect(TabRowView.developerTip(for: URL(string: "http://[::1]:5173/")) == "Developer Mode\n[::1]:5173")
        #expect(TabRowView.developerTip(for: nil) == "Developer Mode")
        #expect(TabRowView.developerTip(for: URL(string: "file:///tmp/index.html")) == "Developer Mode")
    }

    /// On the icon's bottom-trailing corner, reaching a little past it, the same share of a favorite's larger icon and
    /// at every sidebar size: so the row never grows and the title never moves.
    @MainActor @Test func theChipSitsOnTheIconsCornerInsideTheRow() {
        for side: CGFloat in [14, 16, 18, 20, 22] {
            let chip = FaviconView.badgeFrame(side: side)
            #expect(chip.width == chip.height)
            #expect(chip.width >= side * 0.45 && chip.width <= side * 0.55)
            #expect(chip.maxX > side && chip.minY < 0)
            // Never more than a few points out, so it stays clear of the title and inside the row's own height.
            #expect(chip.maxX - side <= 3.5 && -chip.minY <= 3.5)
            #expect(chip.midX > side / 2 && chip.midY < side / 2)
        }
    }

    /// The chip takes the space's accent where that holds 3:1 against the frame, and the row's ink where it wouldn't:
    /// on every curated color, light and dark, and on custom colors from every part of the wheel and every depth.
    @MainActor @Test func theChipReadsOnEverySpace() {
        func resolved(_ color: NSColor, dark: Bool) -> NSColor {
            var out = color
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }
        var spaces = SpaceColor.allCases.map { SpaceInfo(name: $0.name, color: $0) }
        for step in 0..<12 {
            for depth in stride(from: 0.0, through: 1, by: 0.125) {
                var custom = SpaceInfo(name: "custom", color: .sky)
                custom.hue = Double(step) / 12
                custom.intensity = 1
                custom.brightness = depth
                spaces.append(custom)
            }
        }
        for space in spaces {
            let theme = Brand.Theme.of(space)
            // In the modes the window can be in on this space: white stays light, black dark, a set depth its own.
            let mode = space.readableAppearance
            for dark in [false, true] where mode == nil || (mode == "dark") == dark {
                let chip = resolved(theme.badge, dark: dark), frame = resolved(space.background, dark: dark)
                #expect(Brand.contrast(chip, frame) >= 3, "\(space.name) \(space.hue ?? -1) \(space.brightness ?? -1) \(dark)")
            }
        }
        // A curated color keeps its accent: the chip is the space's own color, not a fallback.
        for color in SpaceColor.allCases where !color.isNeutral {
            let theme = Brand.Theme.of(SpaceInfo(name: color.name, color: color))
            for dark in [false, true] {
                #expect(resolved(theme.badge, dark: dark) == resolved(theme.accent, dark: dark), "\(color.name) \(dark)")
            }
        }
        // See-through, over a desktop no one can know, it takes the titles' own ink.
        var glass = SpaceInfo(name: "glass", color: .lavender)
        glass.translucency = 0.8
        let theme = Brand.Theme.of(glass)
        for dark in [false, true] {
            #expect(resolved(theme.badge, dark: dark) == resolved(theme.rowInk, dark: dark), "see-through \(dark)")
        }
    }
}
