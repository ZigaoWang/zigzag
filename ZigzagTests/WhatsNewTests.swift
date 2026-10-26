import Foundation
import Testing
@testable import Zigzag

/// The notes the app shows after an update, read from the same file the release uses.
@MainActor
struct WhatsNewTests {
    @Test func parsesSections() {
        let sections = WhatsNew.parse("## New\n- One\n- Two\n\n## Fixed\n- Three\n\nA closing line.\n")
        #expect(sections.map(\.title) == ["New", "Fixed"])
        #expect(sections.map(\.items) == [["One", "Two"], ["Three"]])
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
