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
                         "github.com/?q=a", "github.com/#readme", "github.com:65536", "github.com:no", "github.com:-1", "github.com:",
                         "https://me@github.com", "ftp://github.com", "-bad.example", "bad-.example",
                         "exa_mple.com", "two..dots", "%67ithub.com", "999.1.2.3", String(repeating: "x", count: 64) + ".com"] {
                #expect(SiteRoutes.entry(from: text, match: mode) == nil)
            }
            #expect(SiteRoutes.entry(from: "WWW.Example.COM", match: mode) == (mode == .domain ? "example.com" : "www.example.com"))
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

    @Test func clickingTheRowEditsADraftAndShowsItsSwitch() throws {
        let spaces = [SpaceInfo(id: work, name: "Work", color: .sky), SpaceInfo(id: media, name: "Media", color: .sage)]
        var saved = SiteRoutes.Route(match: .path, site: "github.com/Org1", spaceID: work, isEnabled: false)
        let row = SiteRouteRow(saved)
        row.refresh(saved, spaces: spaces, number: 1)
        row.setWarning(nil)
        var saves = 0
        row.onSave = { update in
            saves += 1
            saved = update
            row.refresh(update, spaces: spaces, number: 1)
        }
        defer { row.onSave = nil }
        let toggle = try #require(row.subviews.compactMap { $0 as? Toggle }.first)
        let field = try #require(row.subviews.compactMap { $0 as? FilledField }.first)
        let match = try #require(row.subviews.compactMap { $0 as? DropdownButton }.first { $0 !== row.destination })
        let buttons = row.subviews.compactMap { $0 as? PillButton }
        let save = try #require(buttons.first { $0.title == String(localized: "Save") })
        let cancel = try #require(buttons.first { $0.title == String(localized: "Cancel") })
        #expect(toggle.isHidden && field.isHidden && buttons.allSatisfy(\.isHidden))
        let off = String(localized: "Off")
        #expect(row.alphaValue < 1 && row.accessibilityLabel()?.contains(off) == true)
        #expect(row.subviews.compactMap { $0 as? Label }.contains { !$0.isHidden && $0.stringValue.contains(off) })
        #expect(row.accessibilityPerformPress())
        #expect(!toggle.isHidden && !field.isHidden && !save.isHidden && !cancel.isHidden)
        #expect(field.stringValue == saved.site)
        field.stringValue = "github.com"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.isInvalid && !save.isEnabled)
        #expect(row.control(field.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(row.isEditing && saves == 0)
        #expect(toggle.accessibilityPerformPress())
        row.destination.selectedIndex = 1
        row.destination.onSelect?(1)
        match.selectedIndex = try #require(SiteRoutes.Match.allCases.firstIndex(of: .host))
        match.onSelect?(match.selectedIndex)
        #expect(!field.isInvalid && save.isEnabled)
        // Another library notification while typing must leave the draft intact.
        row.refresh(saved, spaces: spaces, number: 1)
        #expect(row.ruleForValidation.match == .host && row.ruleForValidation.spaceID == media)
        #expect(!saved.isEnabled && saves == 0)
        #expect(cancel.accessibilityPerformPress())
        #expect(!row.isEditing && !toggle.isOn && row.destination.selectedIndex == 0)
        #expect(row.accessibilityPerformPress())
        #expect(field.stringValue == "github.com/Org1")
        field.stringValue = "github.com/Org2"
        row.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        row.setWarning("Blocks rule 2.")
        #expect(save.isEnabled)
        #expect(save.accessibilityPerformPress())
        #expect(!row.isEditing && saves == 1 && saved.site == "github.com/Org2")
        #expect(row.searchText.contains(saved.site))
    }

    @Test func theRuleContextMenuEditsMovesAndTogglesTheSelectedRule() throws {
        let library = Library.shared
        let spaceID = try #require(library.spaces.first?.id)
        let rules = ["first", "middle", "last"].map { SiteRoutes.Route(match: .path, site: "context-menu.test/" + $0, spaceID: spaceID) }
        for rule in rules { library.saveRoute(rule) }
        defer { for rule in rules { library.removeRoute(rule.id) } }
        let rule = rules[1]
        let row = SiteRouteRow(rule)
        row.refresh(rule, spaces: library.spaces, number: 2)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try #require(row.menu(for: click))
        #expect(menu.items.first?.title == String(localized: "Edit"))
        let up = menu.indexOfItem(withTitle: String(localized: "Move Up"))
        #expect(up >= 0 && menu.indexOfItem(withTitle: String(localized: "Move Down")) == up + 1)
        menu.performActionForItem(at: 0)
        #expect(row.isEditing)
        let field = try #require(row.subviews.compactMap { $0 as? FilledField }.first)
        #expect(field.stringValue == rule.site)
        #expect(row.control(field.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        let order = library.siteRoutes.map(\.id)
        for (title, enabled) in [(String(localized: "Turn Off"), false), (String(localized: "Turn On"), true)] {
            let menu = try #require(row.menu(for: click))
            let index = menu.indexOfItem(withTitle: title)
            try #require(index >= 0)
            menu.performActionForItem(at: index)
            var expected = rule
            expected.isEnabled = enabled
            #expect(library.siteRoutes.first { $0.id == rule.id } == expected)
            #expect(library.siteRoutes.map(\.id) == order)
        }
    }

    @Test func theSpaceMenuKeepsItsFrameDuringInlineEditing() throws {
        let space = SpaceInfo(id: work, name: "Work", color: .sky)
        let rule = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        for width: CGFloat in [350, 800] {
            let row = SiteRouteRow(rule)
            row.refresh(rule, spaces: [space], number: 1)
            row.setWarning(nil)
            func layout() {
                row.frame.size = NSSize(width: width, height: row.height(for: width))
                row.layoutSubtreeIfNeeded()
            }
            layout()
            let menu = row.destination.frame
            #expect(menu.width > 0)
            #expect(row.accessibilityPerformPress())
            layout()
            #expect(row.destination.frame == menu)
            let field = try #require(row.subviews.compactMap { $0 as? FilledField }.first)
            #expect(field.frame.width > 0 && !field.frame.intersects(menu))
            let cancel = try #require(row.subviews.compactMap { $0 as? PillButton }.first { $0.title == String(localized: "Cancel") })
            #expect(cancel.accessibilityPerformPress())
            layout()
            #expect(row.destination.frame == menu)
        }
    }

    @Test func theSheetValidatesBeforeSavingAndCancelLeavesTheRuleAlone() throws {
        let library = Library.shared
        let original = SiteRoutes.Route(site: "", spaceID: try #require(library.spaces.first?.id))
        defer { library.removeRoute(original.id) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        let sheet = SiteRouteSheet.edit(original, in: host, isNew: true)
        let field = try #require(sheet.selfAndDescendants(of: FilledField.self).first)
        let toggle = try #require(sheet.selfAndDescendants(of: Toggle.self).first)
        let saveTitle = String(localized: "Save", comment: "Save a space rule.")
        let save = try #require(sheet.selfAndDescendants(of: PillButton.self).first { $0.title == saveTitle })
        field.stringValue = "example.test/org1"
        sheet.revalidate()
        #expect(field.isInvalid)
        #expect(!save.isEnabled)
        field.stringValue = "www.example.test"
        toggle.isOn = false
        sheet.revalidate()
        #expect(save.isEnabled)
        #expect(!library.siteRoutes.contains { $0.id == original.id })
        #expect(save.accessibilityPerformPress())
        let saved = try #require(library.siteRoutes.first { $0.id == original.id })
        #expect(saved.match == .domain && saved.site == "example.test" && !saved.isEnabled)
        let editing = SiteRouteSheet.edit(saved, in: host)
        let editField = try #require(editing.selfAndDescendants(of: FilledField.self).first)
        editField.stringValue = "other.test"
        let cancelTitle = String(localized: "Cancel", comment: "Button in a sheet that asks before doing something.")
        let cancel = try #require(editing.selfAndDescendants(of: PillButton.self).first { $0.title == cancelTitle })
        #expect(cancel.accessibilityPerformPress())
        #expect(library.siteRoutes.first { $0.id == saved.id } == saved)
    }

    @Test func recognizedRulesAndFuturePayloadsSurviveEditingAndRelaunch() throws {
        let known = SiteRoutes.Route(site: "example.test", spaceID: work)
        let other = SiteRoutes.Route(site: "other.test", spaceID: media)
        let encoder = JSONEncoder()
        let first = try JSONSerialization.jsonObject(with: encoder.encode(known))
        let last = try JSONSerialization.jsonObject(with: encoder.encode(other))
        let future: [String: Any] = ["match": "future-type", "payload": [true, NSNull(), ["priority": UInt64.max]] as [Any]]
        let fixture = try JSONSerialization.data(withJSONObject: [first, future, last])
        var list = try JSONDecoder().decode(SiteRoutes.StoredRules.self, from: fixture)
        #expect(list.rules == [known, other])
        list.rules[0].site = "changed.test"
        let saved = try JSONEncoder().encode(list)
        let items = try #require(JSONSerialization.jsonObject(with: saved) as? [NSDictionary])
        #expect(items[1] == future as NSDictionary)
        #expect(try JSONDecoder().decode(SiteRoutes.StoredRules.self, from: saved).rules == list.rules)

        let futureOnly = try JSONSerialization.data(withJSONObject: [future])
        let untouched = try JSONDecoder().decode(SiteRoutes.StoredRules.self, from: futureOnly)
        #expect(untouched.rules.isEmpty)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(untouched)) as? [NSDictionary]
        #expect(roundTrip == [future as NSDictionary])
    }

    @Test func aRuleThatCantBeReadIsKeptAndTheRestLoad() throws {
        let known = SiteRoutes.Route(site: "example.test", spaceID: work)
        let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known))
        let broken: [String: Any] = ["site": "no-match.test"]
        let fixture = try JSONSerialization.data(withJSONObject: [broken, first])
        let list = try JSONDecoder().decode(SiteRoutes.StoredRules.self, from: fixture)
        #expect(list.rules == [known])
        let items = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [NSDictionary])
        #expect(items.first == broken as NSDictionary)
    }

    @Test func portsAreAcceptedButDoNotRestrictTheRule() {
        for (input, site) in [("localhost:3000", "localhost"), ("https://github.com:443", "github.com"),
                              ("[::1]:8000", "[::1]")] {
            #expect(SiteRoutes.entry(from: input) == site)
        }
        #expect(SiteRoutes.entry(from: "localhost:3000/App", match: .path) == "localhost/App")
        let rule = SiteRoutes.Route(match: .path, site: "localhost/App", spaceID: work)
        #expect(SiteRoutes.route(for: url("http://localhost:8000/app/a"), in: [rule]) == rule)
        #expect(SiteRoutes.route(for: url("http://localhost:3000/apple"), in: [rule]) == nil)
        for input in ["[::1]:", "[::1]:abc", "[::1]:65536", "localhost:+3"] {
            #expect(SiteRoutes.entry(from: input) == nil)
        }
    }

    @Test func choosingASpaceReenablesOnlyTheEquivalentDomainRule() {
        let page = url("https://github.com/org1")
        let exact = SiteRoutes.Route(match: .host, site: "github.com", spaceID: work, isEnabled: false)
        let disabled = SiteRoutes.Route(site: "github.com", spaceID: media, isEnabled: false)
        let active = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        var expected = disabled
        expected.spaceID = personal
        expected.isEnabled = true
        #expect(SiteRoutes.assigning(page, site: "github.com", to: personal, in: [exact, disabled]) == expected)
        #expect(SiteRoutes.assigning(page, site: "github.com", to: personal, in: [disabled, active]).id == active.id)
        #expect(SiteRoutes.assigning(page, site: "github.com", to: personal, in: [exact]).id != exact.id)
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

    /// AI apps' pages: your routes are yours, so none sends one out, as from a private window.
    @Test func pagesNotGivenYourDataAreNeverRouted() {
        for arrival: SiteRoutes.Arrival in [.otherApp, .typed, .linkClick, .linkNewTab, .fromMini] {
            #expect(target("https://youtube.com/", arrival, place: .withoutYourData) == nil)
        }
    }

    @Test func miniAndAppsKeepTheirPages() {
        #expect(target("https://youtube.com/", .linkClick, place: .mini) == nil)
        #expect(target("https://youtube.com/", .typed, place: .mini) == nil)
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

    private func clickedLink(linkActivated: Bool = false, userInitiated: Bool = true, mainFrame: Bool = false,
                             frame: String? = "www.youtube.com", page: String? = "www.noemamag.com") -> Bool {
        SiteRoutes.newWindowIsClickedLink(linkActivated: linkActivated, userInitiated: userInitiated, fromMainFrame: mainFrame,
                                          frameHost: frame, pageHost: page)
    }

    @Test func anEmbedsClickedNewWindowIsRoutedLikeALink() {
        // YouTube's Watch on YouTube: a click in the embed that calls window.open.
        #expect(clickedLink())
        #expect(clickedLink(frame: "www.youtube-nocookie.com"))
        // A target="_blank" link you click, from any frame.
        #expect(clickedLink(linkActivated: true, mainFrame: true, frame: "www.noemamag.com"))
        #expect(clickedLink(linkActivated: true, frame: "www.noemamag.com"))
    }

    @Test func aPagesOwnPopUpKeepsItsOpener() {
        // The page's own window.open, or one from a frame on its own site.
        #expect(!clickedLink(mainFrame: true, frame: "www.noemamag.com"))
        #expect(!clickedLink(frame: "www.noemamag.com"))
        #expect(!clickedLink(frame: "cdn.noemamag.com"))
        #expect(!clickedLink(frame: nil))
        #expect(!clickedLink(page: nil))
        // Without your click, nothing counts.
        #expect(!clickedLink(userInitiated: false))
        #expect(!clickedLink(linkActivated: true, userInitiated: false))
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

    @Test func savedSpacesKeepOldListsForAnOlderZigzag() {
        let spaces = [SpaceInfo(id: media, name: "Media", color: .sky), SpaceInfo(id: work, name: "Work", color: .sky)]
        let rules = [SiteRoutes.Route(match: .domain, site: "youtube.com", spaceID: media),
                     SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work),
                     SiteRoutes.Route(match: .domain, site: "apple.com", spaceID: media),
                     SiteRoutes.Route(match: .domain, site: "off.test", spaceID: work, isEnabled: false)]
        let saved = SiteRoutes.withLegacySites(spaces, from: rules)
        #expect(saved.map(\.routedSites) == [["apple.com", "youtube.com"], nil])
        #expect(SiteRoutes.migrated(from: saved).map(\.site) == ["apple.com", "youtube.com"])
    }

    @Test func domainRulesDropWWW() {
        #expect(SiteRoutes.entry(from: "https://www.youtube.com/", match: .domain) == "youtube.com")
        #expect(SiteRoutes.entry(from: "www.youtube.com", match: .host) == "www.youtube.com")
    }

    @Test func matchesPathsOnSegmentBoundariesAndPreservesHostScope() {
        let rule = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        for suffix in ["/org1", "/org1/", "/Org1", "/ORG1/repo", "/org1/repo?q=open#readme"] {
            #expect(SiteRoutes.route(for: url("https://github.com" + suffix), in: [rule]) == rule)
        }
        for address in ["https://github.com/org10", "https://github.com/ORG10", "https://github.com/org1%2Frepo",
                        "https://gist.github.com/org1", "https://www.gist.github.com/org1"] {
            #expect(SiteRoutes.route(for: url(address), in: [rule]) == nil)
        }
        #expect(SiteRoutes.entry(from: "https://GitHub.com/org1/?q=a#x", match: .path) == rule.site)
        #expect(SiteRoutes.entry(from: "github.com", match: .path) == nil)
        #expect(SiteRoutes.entry(from: "https://name:password@example.com/path", match: .path) == nil)
        #expect(SiteRoutes.suggestedMatch(for: "github.com/org1") == .path)
    }

    @Test func aPathRuleCoversTheSitesWWWAddress() {
        let bare = SiteRoutes.Route(match: .path, site: "github.com/org1", spaceID: work)
        let www = SiteRoutes.Route(match: .path, site: "www.github.com/org1", spaceID: work)
        for rule in [bare, www] {
            #expect(SiteRoutes.route(for: url("https://github.com/org1/repo"), in: [rule]) == rule)
            #expect(SiteRoutes.route(for: url("https://www.github.com/ORG1"), in: [rule]) == rule)
            #expect(SiteRoutes.route(for: url("https://www.github.com/org10"), in: [rule]) == nil)
            #expect(SiteRoutes.route(for: url("https://gist.github.com/org1"), in: [rule]) == nil)
        }
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
            (.path, "example.com/A", .path, "example.com/a/b", true),
            (.path, "example.com/a", .path, "example.com/ab", false)
        ]
        let unrelated = SiteRoutes.Route(site: "unrelated.org", spaceID: media)
        for (earlier, a, later, b, covered) in pairs {
            let first = SiteRoutes.Route(match: earlier, site: a, spaceID: work)
            let last = SiteRoutes.Route(match: later, site: b, spaceID: work)
            let rules = [first, unrelated, last]
            let result = SiteRoutes.coverage(in: rules)
            #expect(result[0].blocks == (covered ? [2] : []))
            #expect(result[1].warning(in: rules) == nil)
            // Each warning names the other rule by its address: the list shows no numbers.
            #expect(result[0].warning(in: rules)?.contains(b) ?? !covered)
            #expect(result[2].warning(in: rules)?.contains(a) ?? !covered)
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

    @Test func matchHelpExplainsEachModeAndFieldHelpFollowsTheSelection() {
        let modes = SiteRoutes.Match.allCases
        #expect(modes == [.host, .domain, .path])
        let lines = SiteRouteSheet.matchHelpButton().toolTip?.components(separatedBy: "\n") ?? []
        #expect(lines.count == modes.count)
        for (mode, line) in zip(modes, lines) { #expect(line.hasPrefix("• " + mode.title)) }
        let field = FilledField(placeholder: "")
        var tips: Set<String> = []
        for mode in modes {
            mode.setInputHelp(on: field)
            #expect(field.field.toolTip?.contains(mode.inputHint) == true)
            #expect(field.field.toolTip == field.toolTip)
            tips.insert(field.toolTip ?? "")
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
