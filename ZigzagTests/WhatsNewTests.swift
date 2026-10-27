import Foundation
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
