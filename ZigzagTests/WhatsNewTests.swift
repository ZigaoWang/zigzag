import AppKit
import Testing
@testable import Zigzag

/// The notes the app shows after an update, read from the same file the release uses.
@MainActor
struct WhatsNewTests {
    @Test func parsesThisVersionOnly() {
        let log = """
        # Changelog

        ## [1.1.0] - 2026-11-01

        ### New
        - One
        - Two

        ### Fixed
        - Three

        ## [1.0.0] - 2026-10-01

        ### New
        - Old
        """
        let sections = WhatsNew.parse(log, version: "1.1.0")
        #expect(sections.map(\.title) == ["New", "Fixed"])
        #expect(sections.map(\.items) == [["One", "Two"], ["Three"]])
        #expect(WhatsNew.parse(log, version: "1.0.0").map(\.items) == [["Old"]])
        // A version with no notes shows none, rather than another version's.
        #expect(WhatsNew.parse(log, version: "1.1").isEmpty)
    }

    /// Every build carries notes for its own version: a release without them can't go out.
    @Test func iconLinksAreReadFromAPage() {
        let html = #"<head><link rel="icon" type="image/png" href="https://cdn.x.com/f.png" sizes="96x96"/><link rel="stylesheet" href="a.css"><LINK REL='apple-touch-icon' HREF='/t.png'></head>"#
        let links = FaviconStore.iconLinks(in: html)
        #expect(links.count == 2)
        #expect(links.first?["href"] == "https://cdn.x.com/f.png" && links.first?["sizes"] == "96x96")
        #expect(links.last?["rel"] == "apple-touch-icon")
    }

    @Test func customSearchNeedsAPlaceForTheWords() {
        #expect(SearchEngine.isValidTemplate("https://example.com/search?q=%s"))
        #expect(!SearchEngine.isValidTemplate("https://example.com/search"))
        #expect(!SearchEngine.isValidTemplate("javascript:alert(%s)"))
    }

    @Test func unknownSearchEngineKeepsTheLibrary() throws {
        let engine = try JSONDecoder().decode([SearchEngine].self, from: Data(#"["notanengine","kagi"]"#.utf8))
        #expect(engine == [.google, .kagi])
    }

    @Test func linksReadAsPlainWords() {
        #expect(WhatsNew.plain("Spaces can have an icon. ([#1](https://x/1), [#7](https://x/7))") == "Spaces can have an icon.")
        #expect(WhatsNew.plain("See the [release notes](https://x) page.") == "See the release notes page.")
    }

    @Test func shippedNotesAreThere() {
        #expect(!WhatsNew.sections.isEmpty)
    }
}

/// Light or dark text follows what actually reads on a space's colors.
@MainActor
struct ReadableAppearanceTests {
    private func space(_ hue: Double, _ depth: Double, to hue2: Double? = nil, _ depth2: Double? = nil) -> SpaceInfo {
        var s = SpaceInfo(name: "Test", color: .sky)
        s.hue = hue; s.brightness = depth; s.hue2 = hue2; s.brightness2 = depth2
        return s
    }

    @Test func lightAndDeepColors() {
        #expect(space(0.6, 0.1).readableAppearance == "light")
        #expect(space(0.6, 0.9).readableAppearance == "dark")
    }

    @Test func gradientJudgedAtItsHarderEnd() {
        // Deep green into pale orange: white text would vanish on the pale end, so it's light.
        #expect(space(0.25, 0.54, to: 0.06, 0.09).readableAppearance == "light")
    }

    @Test func followsTheMacUntilChosen() {
        var s = SpaceInfo(name: "Test", color: .sky)
        s.appearance = nil
        #expect(s.readableAppearance == nil)
    }
}

/// Spaces saved before 0.4, with white, grays and black as their own kind and see-through as glass, look the same
/// after the update.
@MainActor
struct SpaceLookUpgradeTests {
    private func decode(_ fields: String) throws -> SpaceInfo {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","bookmarks":[],"# + fields + "}"
        return try JSONDecoder().decode(SpaceInfo.self, from: Data(json.utf8)).upgraded
    }

    /// sRGB components of a color, resolved in light or dark.
    private func rgba(_ color: NSColor, dark: Bool = false) -> [Double] {
        var out: [Double] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
        }
        return out
    }

    /// What the frame shows laid over a backdrop of plain `white`.
    private func over(_ color: [Double], _ white: Double) -> [Double] {
        color.prefix(3).map { $0 * color[3] + white * (1 - color[3]) }
    }

    private func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.004) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func colorsStayAsTheyWere() throws {
        let space = try decode(#""color":"sky","hue":0.57,"brightness":0.22,"hue2":0.95,"brightness2":0.4"#)
        #expect(space.tint == nil && space.translucency == nil && !space.isSeeThrough)
        #expect(close(rgba(space.background), rgba(SpaceColor.paint(hue: 0.57, depth: 0.22))))
        #expect(close(rgba(space.background2!), rgba(SpaceColor.paint(hue: 0.95, depth: 0.4))))
    }

    @Test func graysBecomeNoTint() throws {
        let space = try decode(#""color":"graphite","brightness":0.3"#)
        #expect(space.tint == 0 && space.isNeutral)
        // Before: the gray of OKLab lightness 0.975 - 0.69 × depth.
        let gray = OKLab.encode(pow(0.975 - 0.69 * 0.3, 3))
        #expect(close(rgba(space.background), [gray, gray, gray, 1]))
        let swatch = 0.86 - 0.56 * 0.3
        #expect(close(rgba(space.swatch), [swatch, swatch, swatch, 1]))
        // Following the Mac, a gray keeps its curated colors.
        let automatic = try decode(#""color":"snow""#)
        #expect(close(rgba(automatic.background), rgba(SpaceColor.snow.background)))
        #expect(close(rgba(automatic.background, dark: true), rgba(SpaceColor.snow.background, dark: true)))
    }

    @Test func glassBecomesSeeThroughAtItsShade() throws {
        for shade in [0.15, 0.5, 0.8] {
            let space = try decode(#""color":"sky","hue":0.6,"glass":true,"brightness":\#(shade)"#)
            #expect(space.glass == nil && space.isSeeThrough && space.isNeutral)
            // Before: white to black with the shade, at half, over the frosted desktop.
            let old = [1 - shade, 1 - shade, 1 - shade, 0.5]
            let new = rgba(space.frameColor)
            for backdrop in [0.0, 0.5, 1.0] { #expect(close(over(new, backdrop), over(old, backdrop), 0.01)) }
        }
    }

    @Test func automaticGlassStaysWhiteByDayAndBlackAtNight() throws {
        let space = try decode(#""color":"rose","glass":true"#)
        #expect(space.brightness == nil && space.isSeeThrough)
        #expect(close(rgba(space.frameColor), [1, 1, 1, 0.5]))
        #expect(close(rgba(space.frameColor, dark: true), [0, 0, 0, 0.5]))
    }

    @Test func tintThinsTowardGray() {
        var space = SpaceInfo(name: "Test", color: .sky)
        space.hue = 0.6
        space.brightness = 0.4
        space.tint = 0
        let gray = rgba(space.background)
        #expect(abs(gray[0] - gray[1]) < 0.004 && abs(gray[1] - gray[2]) < 0.004)
        space.tint = 0.5
        let half = rgba(space.background)
        #expect(half[2] > half[0] + 0.02)
    }
}
