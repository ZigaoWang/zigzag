import AppKit
import Testing
@testable import Zigzag

/// How Site Controls lays out its actions: one row when the names fit, even rows otherwise, never one alone.
@MainActor
struct SitePanelTests {
    /// The names' widths: with room around them, and whole but snug.
    private let comfortable: CGFloat = 63, tightest: CGFloat = 55

    private func rows(_ count: Int, _ width: CGFloat) -> [Int] {
        SitePanel.actionRows(count: count, width: width, comfortable: comfortable, tightest: tightest)
    }

    @Test func allOnOneRowWhenTheyFit() {
        for count in 2...5 {
            #expect(rows(count, comfortable * CGFloat(count)) == [count])
        }
    }

    /// The narrowest sidebar (a 176pt lane) used to leave Reader alone on a third row.
    @Test func fiveInANarrowPanelAreThreeOverTwo() {
        #expect(rows(5, 176) == [3, 2])
        #expect(rows(5, 200) == [3, 2])
        #expect(rows(5, 268) == [3, 2])
    }

    @Test func noActionSitsAloneUnderTheOthers() {
        for count in 2...5 {
            for width in stride(from: CGFloat(110), through: 340, by: 2) {
                let layout = rows(count, width)
                #expect(layout.reduce(0, +) == count)
                // Every row as full as the first, or one shorter, and the shorter ones last.
                #expect(layout == layout.sorted(by: >))
                #expect(layout.first! - layout.last! <= 1)
                if layout.count > 1 { #expect(layout.last! > 1, "count \(count) width \(width): \(layout)") }
            }
        }
    }

    @Test func fewerActionsWhenSomeAreHidden() {
        // Translate or Reader gone: four, three, two.
        #expect(rows(4, 176) == [2, 2])
        #expect(rows(3, 176) == [3])
        #expect(rows(2, 176) == [2])
        // Narrow enough for two to a row: two over two, and three keep one row snugly rather than two over one.
        #expect(rows(4, 130) == [2, 2])
        #expect(rows(3, 170) == [3])
    }

    @Test func tooNarrowForAnyNameStillLaysOut() {
        #expect(rows(5, 40) == [3, 2])
        #expect(rows(3, 40) == [3])
        #expect(rows(1, 40) == [1])
        #expect(rows(0, 200) == [])
    }
}
