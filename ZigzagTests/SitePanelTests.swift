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

    /// The panel's margins count from a row's ink: a dropdown's box, or the caps and baseline of its words.
    @Test func rowSlackCountsFromTheInk() {
        let dropdown = PanelRow.choice("Open in", options: ["Any Space"], selected: 0) { _ in }
        #expect(dropdown.topSlack == (PanelRow.height - Tokens.Page.controlHeight) / 2)
        #expect(dropdown.bottomSlack == (PanelRow.height - Tokens.Page.controlHeight) / 2)
        let toggle = PanelRow.toggle("Ad blocking", on: true, status: { _ in "On for this site" }) { _ in }
        #expect(toggle.bottomSlack > 0 && toggle.bottomSlack <= (PanelRow.height - Tokens.Metric.toggleSize.height) / 2)
        let link = PanelLinkRow("Permissions", goes: true) {}
        #expect(link.topSlack > 0 && link.bottomSlack > 0)
        #expect(link.topSlack + link.bottomSlack < PanelLinkRow.height - Tokens.TypeSize.body / 2)
    }
}

/// Site Controls says when it closes, so Settings' list of sites shows what was chosen in it.
@MainActor
struct SitePanelClosingTests {
    @Test func closingSaysSo() throws {
        let tab = Tab(url: try #require(URL(string: "https://example.com/")), title: "Example", spaceID: UUID())
        let panel = try #require(SitePanel.forTesting(tab: tab))
        var heard = 0
        let token = SitePanel.closed.observe { heard += 1 }
        defer { token.cancel() }
        panel.close()
        #expect(heard == 1)
    }
}
