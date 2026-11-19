import AppKit
import Testing
@testable import Zigzag

/// Sites that always open in a space (#286): site matching, coverage, which arrivals route, and removing a space.
@MainActor
struct SiteRoutesTests {
    private let media = UUID()
    private let work = UUID()
    private let personal = UUID()

    private func url(_ text: String) -> URL { URL(string: text)! }

    private var routes: [SiteRoutes.Route] {
        [.init(site: "music.youtube.com", spaceID: personal), .init(site: "youtube.com", spaceID: media), .init(site: "github.com", spaceID: work)]
    }

    private func target(_ address: String, _ arrival: SiteRoutes.Arrival, from: UUID? = nil, place: SiteRoutes.Place = .browser) -> UUID? {
        SiteRoutes.target(for: url(address), arrival: arrival, from: from ?? personal, place: place, routes: routes)
    }

    // MARK: Matching

    @Test func aPageSiteIsItsHostWithoutWWW() {
        #expect(SiteRoutes.site(of: url("https://www.YouTube.com/watch?v=1")) == "youtube.com")
        #expect(SiteRoutes.site(of: url("http://m.youtube.com./")) == "m.youtube.com")
        #expect(SiteRoutes.site(of: url("https://localhost:3000/")) == "localhost")
        #expect(SiteRoutes.site(of: url("file:///tmp/a.html")) == nil)
        #expect(SiteRoutes.site(of: url("about:blank")) == nil)
        #expect(SiteRoutes.site(of: nil) == nil)
    }

    @Test func aSiteCoversItsSubdomainsOnly() {
        #expect(SiteRoutes.covers("youtube.com", "youtube.com"))
        #expect(SiteRoutes.covers("youtube.com", "m.youtube.com"))
        #expect(!SiteRoutes.covers("youtube.com", "notyoutube.com"))
        #expect(!SiteRoutes.covers("m.youtube.com", "youtube.com"))
    }

    @Test func orderedDomainRules() {
        #expect(SiteRoutes.route(for: url("https://www.youtube.com/"), in: routes)?.spaceID == media)
        #expect(SiteRoutes.route(for: url("https://m.youtube.com/"), in: routes)?.spaceID == media)
        #expect(SiteRoutes.route(for: url("https://music.youtube.com/"), in: routes)?.spaceID == personal)
        #expect(SiteRoutes.route(for: url("https://gist.github.com/x"), in: routes)?.spaceID == work)
        #expect(SiteRoutes.route(for: url("https://example.com/"), in: routes) == nil)
    }

    @Test func hostnameFieldsAcceptWebOriginsAndRejectAnythingMoreSpecific() {
        for mode: SiteRoutes.Match in [.host, .domain] {
            for text in ["github.com", " https://GitHub.com/ ", "HTTP://GitHub.com."] {
                #expect(SiteRoutes.entry(from: text, match: mode) == "github.com")
            }
            for text in ["", "two words", "*.github.com", "github.com/org1", "https://github.com/org1",
                         "github.com/?q=a", "github.com/#readme", "github.com:443", "github.com:",
                         "https://me@github.com", "ftp://github.com", "-bad.example", "bad-.example",
                         "exa_mple.com", "two..dots", "%67ithub.com", "999.1.2.3", String(repeating: "x", count: 64) + ".com"] {
                #expect(SiteRoutes.entry(from: text, match: mode) == nil)
            }
            #expect(SiteRoutes.entry(from: "WWW.Example.COM", match: mode) == "www.example.com")
            #expect(SiteRoutes.entry(from: "bücher.example", match: mode) == "xn--bcher-kva.example")
            #expect(SiteRoutes.entry(from: "http://[::1]/", match: mode) == "[::1]")
            #expect(SiteRoutes.entry(from: "localhost", match: mode) == "localhost")
        }
    }

    @Test func disablingARuleReleasesItsMatchesAndSurvivesReload() throws {
        var host = SiteRoutes.Route(match: .host, site: "github.com", spaceID: work)
        let path = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: personal)
        let page = url("https://github.com/org1/repo")
        #expect(SiteRoutes.blocker(for: path, in: [host, path]) == 0)
        host.isEnabled = false
        let rules = try JSONDecoder().decode([SiteRoutes.Route].self, from: JSONEncoder().encode([host, path]))
        #expect(SiteRoutes.route(for: page, in: rules) == path)
        #expect(SiteRoutes.blocker(for: path, in: rules) == nil)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        old.removeValue(forKey: "isEnabled")
        let legacy = try JSONDecoder().decode(SiteRoutes.Route.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.isEnabled)
        #expect(SiteRoutes.route(for: page, in: [legacy, path]) == legacy)
    }

    @Test func addressFieldValidatesWhileTypingAndOnlySavesOnCommit() {
        let space = SpaceInfo(id: work, name: "Work", color: .sky)
        let saved = SiteRoutes.Route(match: .host, site: "example.com", spaceID: work)
        let row = SiteRouteRow(saved)
        row.refresh(saved, spaces: [space], number: 1, isNew: false)
        var changes: [SiteRoutes.Route] = []
        row.onSave = { changes.append($0) }
        let edit = Notification(name: NSControl.textDidChangeNotification, object: row.address.field)
        row.address.stringValue = "https://github.com/org1"
        row.controlTextDidChange(edit)
        #expect(row.address.isInvalid)
        row.controlTextDidEndEditing(edit)
        #expect(changes.isEmpty)
        #expect(row.address.stringValue == "https://github.com/org1")

        // Saving an unrelated change in Settings keeps the invalid draft and its error visible.
        row.refresh(saved, spaces: [space], number: 2, isNew: false)
        #expect(row.address.stringValue == "https://github.com/org1")
        row.match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: .path)!
        row.match.onSelect?(row.match.selectedIndex)
        #expect(changes.last?.site == "github.com/org1")
        #expect(changes.last?.match == .path)
        #expect(!row.address.isInvalid)

        row.refresh(saved, spaces: [space], number: 1, isNew: false)
        row.match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: .host)!
        row.address.stringValue = "HTTPS://GitHub.com/"
        row.controlTextDidChange(edit)
        #expect(row.address.stringValue == "HTTPS://GitHub.com/")
        row.controlTextDidEndEditing(edit)
        #expect(changes.last?.site == "github.com")
        #expect(row.address.stringValue == "github.com")
    }

    @Test func inlineLabelsFollowTheirFieldsAtBothWidthsAndExplainTheSelectedMatch() throws {
        let saved = SiteRoutes.Route(match: .host, site: "example.com", spaceID: work)
        let row = SiteRouteRow(saved)
        row.refresh(saved, spaces: [SpaceInfo(id: work, name: "Work", color: .sky)], number: 1, isNew: false)
        let hostname = String(localized: "Hostname", comment: "Label above a space rule that takes only a hostname.")
        let fields: [(String, NSView)] = [
            (String(localized: "Enabled", comment: "Label above a space rule's switch."), row.enabled),
            (String(localized: "Match", comment: "Space rule match type."), row.match),
            (hostname, row.address),
            (String(localized: "Open in", comment: "Destination space for a rule."), row.destination)
        ]
        for width: CGFloat in [800, 350] {
            row.frame.size = NSSize(width: width, height: row.height(for: width))
            row.layoutSubtreeIfNeeded()
            for (name, field) in fields {
                let label = try #require(row.subviews.compactMap { $0 as? Label }.first { $0.stringValue == name })
                #expect(label.frame.minX + Label.inset == field.frame.minX)
                #expect(label.frame.maxY <= field.frame.minY)
                #expect(label.frame.width >= label.inkWidth)
            }
            if width == 350 { #expect(row.address.frame.minY > row.match.frame.maxY) }
        }
        #expect(row.address.field.accessibilityLabel() == hostname)
        let i = try #require(SiteRoutes.Match.allCases.firstIndex(of: .path))
        row.match.selectedIndex = i
        row.match.onSelect?(i)
        #expect(row.address.field.accessibilityLabel() == String(localized: "Host and path", comment: "Label above an address that matches a host and path."))
        #expect(row.address.isInvalid)
    }

    @Test func newInlineRulesKeepTheirDestinationAndEnabledStateUntilTheAddressIsReady() {
        let a = SpaceInfo(id: work, name: "Work", color: .sky), b = SpaceInfo(id: media, name: "Media", color: .sage)
        let draft = SiteRoutes.Route(match: .path, site: "", spaceID: work)
        let row = SiteRouteRow(draft)
        row.refresh(draft, spaces: [a, b], number: 1, isNew: true)
        var changes: [SiteRoutes.Route] = []
        row.onSave = { changes.append($0) }
        row.enabled.onChange?(false)
        row.destination.onSelect?(1)
        row.address.stringValue = "github.com/org2"
        row.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(changes.last == SiteRoutes.Route(id: draft.id, match: .path, site: "github.com/org2", spaceID: media, isEnabled: false))
    }

    // MARK: Deciding

    @Test func whatYouDoYourselfIsRouted() {
        for arrival: SiteRoutes.Arrival in [.otherApp, .typed, .linkClick, .linkNewTab] {
            #expect(target("https://youtube.com/watch", arrival) == media)
        }
    }

    @Test func whatThePageDoesOnItsOwnIsNot() {
        for arrival: SiteRoutes.Arrival in [.pageOnItsOwn, .backForward, .reload] {
            #expect(target("https://youtube.com/watch", arrival) == nil)
        }
    }

    @Test func aPageAlreadyInItsSpaceOpensAsUsual() {
        #expect(target("https://youtube.com/", .linkClick, from: media) == nil)
        #expect(target("https://youtube.com/", .otherApp, from: media) == nil)
        #expect(target("https://example.com/", .otherApp) == nil)
    }

    @Test func privateWindowsAreNeverRouted() {
        for arrival: SiteRoutes.Arrival in [.otherApp, .typed, .linkClick, .linkNewTab, .fromMini] {
            #expect(target("https://youtube.com/", arrival, place: .privateWindow) == nil)
        }
    }

    @Test func miniPeekAndAppsKeepTheirPages() {
        #expect(target("https://youtube.com/", .linkClick, place: .mini) == nil)
        #expect(target("https://youtube.com/", .typed, place: .mini) == nil)
        #expect(target("https://youtube.com/", .linkClick, place: .peek) == nil)
        #expect(target("https://youtube.com/", .linkClick, place: .webApp) == nil)
        // Open in Zigzag from Mini is routed.
        #expect(target("https://youtube.com/", .fromMini, place: .mini) == media)
    }

    @Test func aSignInALinkSendsYouToStaysPut() {
        #expect(target("https://github.com/login/oauth/authorize?client_id=1", .linkClick) == nil)
        #expect(target("https://github.com/x?redirect_uri=https%3A%2F%2Fexample.com", .linkNewTab) == nil)
        #expect(target("https://github.com/login", .linkClick) == nil)
        // Typed: stays where you typed.
        #expect(target("https://github.com/login", .typed) == work)
        #expect(target("https://github.com/zigzag", .linkClick) == work)
    }

    // MARK: Keeping them

    @Test func legacyDomainsMigrateInStoredOrderWithSubdomainsFirst() throws {
        var general = SpaceInfo(id: media, name: "General", color: .sky)
        general.routedSites = ["another.test", "example.com"]
        var specific = SpaceInfo(id: work, name: "Work", color: .sky)
        specific.routedSites = ["code.example.com"]
        let rules = SiteRoutes.migrated(from: [general, specific])
        // The old lists let the most specific site win, so the subdomain moves above its parent.
        #expect(rules.map(\.site) == ["another.test", "code.example.com", "example.com"])
        #expect(rules.map(\.spaceID) == [media, work, media])
        #expect(rules.allSatisfy { $0.match == .domain && $0.isEnabled })
        #expect(SiteRoutes.route(for: url("https://www.code.example.com"), in: rules)?.spaceID == work)
        #expect(SiteRoutes.route(for: url("https://example.com"), in: rules)?.spaceID == media)
        #expect(SiteRoutes.coverage(in: rules).allSatisfy { $0.blockedBy == nil })
        #expect(try JSONDecoder().decode([SiteRoutes.Route].self, from: JSONEncoder().encode(rules)) == rules)
    }

    @Test func matchesPathsOnSegmentBoundariesAndPreservesHostScope() {
        let rule = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        for suffix in ["/org1", "/org1/", "/org1/repo?q=open#readme"] {
            #expect(SiteRoutes.route(for: url("https://github.com" + suffix), in: [rule]) == rule)
        }
        for address in ["https://github.com/org10", "https://github.com/Org1", "https://github.com/org1%2Frepo",
                        "https://gist.github.com/org1", "https://www.github.com/org1"] {
            #expect(SiteRoutes.route(for: url(address), in: [rule]) == nil)
        }
        #expect(SiteRoutes.entry(from: "https://GitHub.com/org1/?q=a#x", match: .path) == rule.site)
        #expect(SiteRoutes.entry(from: "github.com", match: .path) == nil)
        #expect(SiteRoutes.entry(from: "https://name:password@example.com/path", match: .path) == nil)
        #expect(SiteRoutes.suggestedMatch(for: "github.com/org1") == .path)
    }

    @Test func reorderingChangesWinnerAndWarningsTogether() {
        let one = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        let two = SiteRoutes.Route(match: .path, site: "github.com/org2", spaceID: media)
        let fallback = SiteRoutes.Route(match: .host, site: "github.com", spaceID: personal)
        var rules = [one, two, fallback]
        let address = url("https://github.com/org2/pull/42")
        #expect(SiteRoutes.route(for: address, in: rules) == two)
        #expect(SiteRoutes.blocker(for: fallback, in: rules) == nil)
        SiteRoutes.move(fallback.id, before: one.id, in: &rules)
        #expect(SiteRoutes.route(for: address, in: rules) == fallback)
        #expect(SiteRoutes.blocker(for: two, in: rules) == 0)
        #expect(SiteRoutes.target(for: address, arrival: .typed, from: personal, place: .browser, routes: rules) == nil)
        SiteRoutes.move(fallback.id, before: nil, in: &rules)
        #expect(SiteRoutes.blocker(for: two, in: rules) == nil)
        #expect(SiteRoutes.route(for: address, in: rules) == two)
    }

    @Test func onlyCompleteCoverageWarns() {
        let host = SiteRoutes.Route(match: .host, site: "example.com", spaceID: work)
        let domain = SiteRoutes.Route(match: .domain, site: "example.com", spaceID: work)
        let child = SiteRoutes.Route(match: .path, site: "docs.example.com/a", spaceID: personal)
        let deeper = SiteRoutes.Route(match: .path, site: "docs.example.com/a/b", spaceID: media)
        #expect(!host.includes(domain))
        #expect(!host.includes(child))
        #expect(domain.includes(child))
        #expect(child.includes(deeper))
        #expect(!deeper.includes(child))
    }

    @Test func warningsIdentifyBothRowsAcrossEveryMatchType() {
        typealias Match = SiteRoutes.Match
        let pairs: [(Match, String, Match, String, Bool)] = [
            (.host, "example.com", .host, "example.com", true),
            (.host, "example.com", .host, "docs.example.com", false),
            (.host, "example.com", .domain, "example.com", false),
            (.host, "example.com", .path, "example.com/a", true),
            (.domain, "example.com", .host, "docs.example.com", true),
            (.domain, "example.com", .domain, "docs.example.com", true),
            (.domain, "example.com", .domain, "notexample.com", false),
            (.domain, "example.com", .path, "docs.example.com/a", true),
            (.path, "example.com/a", .host, "example.com", false),
            (.path, "example.com/a", .domain, "example.com", false),
            (.path, "example.com/a", .path, "example.com/a", true),
            (.path, "example.com/a", .path, "example.com/a/b", true),
            (.path, "example.com/a", .path, "example.com/ab", false)
        ]
        let unrelated = SiteRoutes.Route(site: "unrelated.org", spaceID: media)
        for (earlier, a, later, b, covered) in pairs {
            let first = SiteRoutes.Route(match: earlier, site: a, spaceID: work)
            let last = SiteRoutes.Route(match: later, site: b, spaceID: work)
            let result = SiteRoutes.coverage(in: [first, unrelated, last])
            #expect(result[0].blocks == (covered ? [2] : []))
            #expect(result[1].warning == nil)
            #expect(result[2].blockedBy == (covered ? 0 : nil))
        }
    }

    @Test func firstEnabledCoveringRuleListsAllTheRowsItBlocks() {
        var first = SiteRoutes.Route(match: .domain, site: "example.com", spaceID: work)
        let second = SiteRoutes.Route(match: .host, site: "docs.example.com", spaceID: media)
        let third = SiteRoutes.Route(match: .path, site: "docs.example.com/a", spaceID: personal)
        let fourth = SiteRoutes.Route(match: .path, site: "example.com/a", spaceID: work, isEnabled: false)
        #expect(SiteRoutes.coverage(in: [first, second, third, fourth]) == [
            .init(blocks: [1, 2]), .init(blockedBy: 0), .init(blockedBy: 0), .init()
        ])
        first.isEnabled = false
        #expect(SiteRoutes.coverage(in: [first, second, third, fourth]) == [
            .init(), .init(blocks: [2]), .init(blockedBy: 1), .init()
        ])
    }

    @Test func aDraftUpdatesCoverageBeforeTheAddressIsSaved() {
        let saved = SiteRoutes.Route(match: .host, site: "example.com", spaceID: work)
        let later = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: personal)
        let row = SiteRouteRow(saved)
        var coverage: [SiteRoutes.Coverage] = []
        row.onDraftChange = { coverage = SiteRoutes.coverage(in: [row.ruleForValidation, later]) }
        row.address.stringValue = "github.com"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(coverage.first?.blocks == [1])
        row.address.stringValue = "github.com/org1"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(row.address.isInvalid)
        #expect(row.ruleForValidation == saved)
        #expect(coverage.last?.blockedBy == nil)
        row.onDraftChange = nil
    }

    @Test func matchHelpExplainsEachModeAndFieldHelpFollowsTheSelection() {
        let modes = SiteRoutes.Match.allCases
        #expect(modes == [.host, .domain, .path])
        let lines = SiteRouteSheet.matchHelpButton().toolTip?.components(separatedBy: "\n") ?? []
        #expect(lines.count == modes.count)
        for (mode, line) in zip(modes, lines) { #expect(line.hasPrefix("• " + mode.title)) }
        let row = SiteRouteRow(.init(site: "github.com", spaceID: work))
        var tips: Set<String> = []
        for (index, mode) in modes.enumerated() {
            row.match.selectedIndex = index
            row.match.onSelect?(index)
            #expect(row.address.field.toolTip?.contains(mode.inputHint) == true)
            #expect(row.address.field.toolTip == row.address.toolTip)
            tips.insert(row.address.field.toolTip ?? "")
        }
        #expect(tips.count == 3)
    }

    // MARK: Site Controls

    @Test func openInIsOfferedWithMoreThanOneSpace() {
        var c = SitePanelRows.Context()
        #expect(!SitePanelRows.rows(c).contains(.openIn))
        c.manySpaces = true
        #expect(SitePanelRows.rows(c).last == .openIn)
        c.isPrivate = true
        #expect(!SitePanelRows.rows(c).contains(.openIn))
        c.isPrivate = false
        c.isWeb = false
        #expect(!SitePanelRows.rows(c).contains(.openIn))
    }
}
