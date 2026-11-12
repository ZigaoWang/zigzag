import Foundation
import Testing
@testable import Zigzag

/// A sleeping tab's mark is a ring of even dashes, and what it says when you point at it is why it sleeps and about how
/// much memory that gave back (#140).
@MainActor struct AsleepMarkTests {
    private let mb: UInt64 = 1 << 20

    @Test func dashesDivideTheCircleExactly() {
        for side in [16.0, 18, 22, 24, 28] {
            let ring = side + 2 * (FaviconView.asleepStyle.gap + FaviconView.asleepStyle.lineWidth / 2)
            let circumference = CGFloat.pi * ring
            let even = FaviconView.evenDashes(circumference: circumference, dash: FaviconView.asleepStyle.dash, space: FaviconView.asleepStyle.space)
            #expect(abs(CGFloat(even.count) * (even.dash + even.space) - circumference) < 0.0001)
            // Dash and gap keep their proportion, and stay close to the size asked for.
            #expect(abs(even.dash / even.space - FaviconView.asleepStyle.dash / FaviconView.asleepStyle.space) < 0.0001)
            #expect(abs((even.dash + even.space) - (FaviconView.asleepStyle.dash + FaviconView.asleepStyle.space)) < 0.2)
        }
    }

    @Test func theRingClearsTheIconsCorners() {
        // The ring's inner edge is at least a point out from the smaller icon's rounded corner.
        let style = FaviconView.asleepStyle
        let side = Tokens.Sidebar.favicon, radius = Tokens.Radius.small - 1
        let corner = (side * style.iconScale / 2 - radius) * 2.squareRoot() + radius
        #expect(side / 2 + style.gap - corner >= 1)
        // And thin: a hairline at 2x, never the old chunky dots.
        #expect(style.lineWidth <= 1)
    }

    @Test func aSmallCircleStillGetsSomeDashes() {
        let even = FaviconView.evenDashes(circumference: 3, dash: 1.6, space: 1.4)
        #expect(even.count == 4)
        #expect(abs(4 * (even.dash + even.space) - 3) < 0.0001)
    }

    @Test func aTabsShareIsTheProcessSplitOverItsTabs() {
        #expect(SleepMemory.share(footprint: 600 * mb, tabsSharing: 3) == 200 * mb)
        #expect(SleepMemory.share(footprint: 180 * mb, tabsSharing: 1) == 180 * mb)
        // Counted after it left the list, or not at all: still its own process's memory.
        #expect(SleepMemory.share(footprint: 180 * mb, tabsSharing: 0) == 180 * mb)
    }

    @Test func noFigureWhenTheProcessDidNotSay() {
        #expect(SleepMemory.share(footprint: nil, tabsSharing: 2) == nil)
        #expect(SleepMemory.share(footprint: 0, tabsSharing: 2) == nil)
    }

    @Test func sizesAreRoundedAsTheyAreOnlyAbout() {
        #expect(SleepMemory.formatted(180 * mb + 300_000) == "180 MB")
        #expect(SleepMemory.formatted(183 * mb + 700_000) == "184 MB")
        #expect(SleepMemory.formatted(12 * mb) == "12 MB")
        #expect(SleepMemory.formatted(200_000) == "1 MB")
        #expect(SleepMemory.formatted(1_210 * mb) == "1.2 GB")
    }

    @Test func theNoteSaysWhyAndWhatItFreed() {
        #expect(SleepMemory.note(forEnergy: false, freed: 180 * mb) == "Asleep to save memory. Freed about 180 MB.")
        #expect(SleepMemory.note(forEnergy: true, freed: 180 * mb) == "Asleep to save energy. Freed about 180 MB.")
    }

    @Test func withoutAFigureTheNoteOnlySaysWhy() {
        #expect(SleepMemory.note(forEnergy: false, freed: nil) == "Asleep to save memory.")
        #expect(SleepMemory.note(forEnergy: true, freed: nil) == "Asleep to save energy.")
    }

    @Test func anAwakeTabSaysNothing() {
        #expect(Tab(url: URL(string: "https://example.com"), spaceID: UUID()).asleepNote == nil)
    }
}
