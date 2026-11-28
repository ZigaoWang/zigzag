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

/// Site Controls reads top down (#384): the site and its connection, the actions, This Site's everyday switches with
/// what the site asked for, the lines into the other pages, and the extensions last; what's set once is on More for
/// This Site, where each control still works.
@MainActor
@Suite(.serialized)
struct SitePanelLayoutTests {
    private let url = URL(string: "https://layout-384.example.com/page")!

    /// Each kept choice the panel can change, in a scratch store for the test.
    private func withStores(_ body: () throws -> Void) throws {
        let suite = "zigzag-site-panel-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = (SitePermissions.defaults, KeepAwake.defaults, SiteUserAgents.defaults)
        SitePermissions.defaults = defaults
        KeepAwake.defaults = defaults
        SiteUserAgents.defaults = defaults
        SitePermissions.forgetAsked()
        defer {
            (SitePermissions.defaults, KeepAwake.defaults, SiteUserAgents.defaults) = before
            SitePermissions.forgetAsked()
            defaults.removeScratchSuite(suite)
        }
        try body()
    }

    private func panel(touch: Bool = false) throws -> SitePanel {
        let tab = Tab(url: url, title: "Example", spaceID: UUID())
        let panel = try #require(SitePanel.forTesting(tab: tab, touch: touch))
        panel.frame = NSRect(x: 0, y: 0, width: SitePanel.width, height: 900)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    @Test func theFirstPageReadsTopDown() throws {
        try withStores {
            let panel = try panel()
            defer { panel.close() }
            let order = panel.debugState["order"] as? [String] ?? []
            #expect(order == ["site", "connection", "This Site", "Permissions", "More for This Site"])
            let rows = panel.debugState["rows"] as? [String] ?? []
            // Compatibility mode last, for a site that breaks.
            #expect(rows.last == "\(SitePanel.compatibilityTitle): off")
            #expect(rows.contains("Ad blocking: on"))
            #expect(rows.contains { $0.hasPrefix("Dark page: ") })
        }
    }

    @Test func theRareChoicesAreOnTheirOwnPage() throws {
        try withStores {
            let panel = try panel()
            defer { panel.close() }
            let rows = panel.debugState["rows"] as? [String] ?? []
            let more = panel.debugState["more"] as? [String] ?? []
            #expect(more.contains("Keep tabs awake: off"))
            #expect(more.contains { $0.hasPrefix("\(SiteUserAgents.title): ") })
            #expect(!rows.contains { $0.hasPrefix("Keep tabs awake") || $0.hasPrefix(SiteUserAgents.title) })
            // Its line opens it, with a way back.
            #expect((panel.debugState["links"] as? [String] ?? []).contains(SitePanel.moreTitle))
            panel.debugPage("morepage")
            #expect(panel.page == .more)
            panel.show(.main)
            #expect(panel.page == .main)
        }
    }

    @Test func eachControlOnMoreStillWorks() throws {
        try withStores {
            let panel = try panel()
            defer { panel.close() }
            panel.debugPage("morepage")
            panel.debugChooseRow("1 Keep tabs awake")
            #expect(KeepAwake.isOn(for: url))
            panel.debugChooseRow("0 Keep tabs awake")
            #expect(!KeepAwake.isOn(for: url))
            panel.debugChooseRow("1 \(SiteUserAgents.title)")
            #expect(SiteUserAgents.choice(for: url) == SiteUserAgents.Choice.presets.first)
            panel.debugChooseRow("0 \(SiteUserAgents.title)")
            #expect(SiteUserAgents.choice(for: url) == nil)
        }
    }

    /// What the site asked for is on the first page too, and a choice there is the one the Permissions page shows.
    @Test func anAskedPermissionIsOnTheFirstPageToo() throws {
        try withStores {
            let origin = try #require(SiteOrigin.of(url))
            let before = try panel()
            #expect(!(before.debugState["rows"] as? [String] ?? []).contains { $0.hasPrefix(SitePermission.camera.title) })
            before.close()
            SitePermissions.noteAsked(.camera, origin: origin, isPrivate: false)
            let panel = try panel()
            defer { panel.close() }
            let camera = SitePermission.camera.title
            #expect((panel.debugState["rows"] as? [String] ?? []).contains { $0.hasPrefix(camera + ":") })
            let allow = try #require(SitePermission.camera.choices.firstIndex(of: .allow))
            panel.debugChooseRow("\(allow) \(camera)")
            #expect(SitePermissions.choice(.camera, origin: origin) == .allow)
            let shown = panel.debugState["permissions"] as? [String] ?? []
            let mainRow = (panel.debugState["rows"] as? [String] ?? []).first { $0.hasPrefix(camera + ":") }
            #expect(mainRow != nil && shown.contains(mainRow!))
        }
    }

    /// Opened by a finger, its rows into pages are 44 points tall, as This Site's are.
    @Test func aFingerGetsTallRows() throws {
        try withStores {
            let touched = try panel(touch: true)
            #expect(PanelLinkRow.height == TouchTargets.size)
            #expect(ConnectionLine.height == TouchTargets.size)
            #expect(PanelRow.height >= TouchTargets.size)
            touched.close()
            let clicked = try panel()
            defer { clicked.close() }
            #expect(PanelLinkRow.height == Tokens.Page.rowHeight)
        }
    }
}
