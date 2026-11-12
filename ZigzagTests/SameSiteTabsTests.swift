import Foundation
import Testing
@testable import Zigzag

/// Next to Tabs from the Same Site (#188): a new tab goes after the tabs already open from its site, in their group,
/// and goes where the choice before it said when no tab is from that site.
@Suite(.serialized) @MainActor struct SameSiteTabsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func node(_ id: UUID, _ parent: UUID? = nil) -> TabTree.Node { TabTree.Node(id: id, parent: parent) }

    // MARK: What one site is

    @Test func aSiteIsItsRegistrableDomain() {
        #expect(TabManager.site(of: URL(string: "https://mail.google.com/mail/u/0")) == "google.com")
        #expect(TabManager.site(of: URL(string: "https://docs.google.com/")) == "google.com")
        #expect(TabManager.site(of: URL(string: "https://news.bbc.co.uk/")) == "bbc.co.uk")
        // Someone else's site on a shared host isn't the same site.
        #expect(TabManager.site(of: URL(string: "https://alice.github.io/")) != TabManager.site(of: URL(string: "https://bob.github.io/")))
        // No registrable domain: the host itself.
        #expect(TabManager.site(of: URL(string: "http://localhost:3000/")) == "localhost")
        #expect(TabManager.site(of: URL(string: "http://192.168.1.4/")) == "192.168.1.4")
        // Not a website.
        #expect(TabManager.site(of: URL(string: "file:///Users/me/a.html")) == nil)
        #expect(TabManager.site(of: nil) == nil)
    }

    // MARK: Where it goes

    @Test func itGoesAfterTheLastTabFromItsSite() {
        let nodes = [node(a), node(b), node(c), node(d)]
        let sites = [a: "github.com", b: "apple.com", c: "github.com", d: "apple.com"]
        let place = TabTree.besideSameSite("github.com", sites: sites, opener: nil, in: nodes)
        #expect(place?.index == 3)
        #expect(place?.parent == nil)
    }

    @Test func noTabFromItsSiteLeavesItToTheOtherChoice() {
        let nodes = [node(a), node(b)]
        #expect(TabTree.besideSameSite("github.com", sites: [a: "apple.com"], opener: nil, in: nodes) == nil)
        #expect(TabTree.besideSameSite("github.com", sites: [:], opener: nil, in: []) == nil)
    }

    @Test func itJoinsTheGroupItsSiteIsIn() {
        // a, under it b (github) and c; d on its own.
        let nodes = [node(a), node(b, a), node(c, a), node(d)]
        let sites = [a: "apple.com", b: "github.com", c: "apple.com", d: "apple.com"]
        let place = TabTree.besideSameSite("github.com", sites: sites, opener: nil, in: nodes)
        #expect(place?.index == 2)
        #expect(place?.parent == a)
    }

    @Test func itGoesAfterWhatIsUnderTheTab() {
        // b (github) has c under it: the new tab goes after c, beside b, not between b and its tab.
        let nodes = [node(a), node(b), node(c, b), node(d)]
        let sites = [a: "apple.com", b: "github.com", c: "apple.com", d: "apple.com"]
        let place = TabTree.besideSameSite("github.com", sites: sites, opener: nil, in: nodes)
        #expect(place?.index == 3)
        #expect(place?.parent == nil)
    }

    @Test func fromATabOfItsSiteItGoesAfterThatRun() {
        // Opened from a: after b, the github tab right after it, not after e at the end.
        let nodes = [node(a), node(b), node(c), node(d), node(e)]
        let sites = [a: "github.com", b: "github.com", c: "apple.com", e: "github.com"]
        let place = TabTree.besideSameSite("github.com", sites: sites, opener: a, in: nodes)
        #expect(place?.index == 2)
        // From a tab of another site: after the last github tab.
        #expect(TabTree.besideSameSite("github.com", sites: sites, opener: c, in: nodes)?.index == 5)
    }

    @Test func placingKeepsEveryGroupWhole() {
        let nodes = [node(a), node(b, a), node(c, b), node(d, a), node(e)]
        let sites = [a: "x.com", b: "y.com", c: "z.com", d: "y.com", e: "x.com"]
        for site in ["x.com", "y.com", "z.com"] {
            let place = try! #require(TabTree.besideSameSite(site, sites: sites, opener: nil, in: nodes))
            #expect(TabTree.canInsert(at: place.index, parent: place.parent, in: nodes))
            var placed = nodes
            placed.insert(node(UUID(), place.parent), at: place.index)
            #expect(TabTree.repaired(placed) == placed)
        }
    }

    // MARK: The setting

    @Test func choosingItRemembersThePlaceBefore() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "NewTabPlace"), defaults.object(forKey: "NewTabPlaceOtherwise"))
        defer {
            defaults.set(saved.0, forKey: "NewTabPlace")
            defaults.set(saved.1, forKey: "NewTabPlaceOtherwise")
        }
        TabManager.newTabPlace = .bottom
        #expect(TabManager.otherNewTabPlace == .bottom)
        TabManager.newTabPlace = .sameSite
        #expect(TabManager.newTabPlace == .sameSite)
        #expect(TabManager.otherNewTabPlace == .bottom)
        // Chosen again, it keeps the place from before it, not itself.
        TabManager.newTabPlace = .sameSite
        #expect(TabManager.otherNewTabPlace == .bottom)
        defaults.removeObject(forKey: "NewTabPlaceOtherwise")
        #expect(TabManager.otherNewTabPlace == .next)
    }

    /// The setting on, with `otherwise` for a site with no tabs open, for one test.
    private func sameSite(otherwise: String, _ body: (TabManager, UUID) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "NewTabPlace"), defaults.object(forKey: "NewTabPlaceOtherwise"))
        defer {
            defaults.set(saved.0, forKey: "NewTabPlace")
            defaults.set(saved.1, forKey: "NewTabPlaceOtherwise")
        }
        defaults.set("sameSite", forKey: "NewTabPlace")
        defaults.set(otherwise, forKey: "NewTabPlaceOtherwise")
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        try body(manager, space)
    }

    private func page(_ url: String, in space: UUID) -> Tab { Tab(url: URL(string: url), spaceID: space) }

    @Test func aLinkGoesWithItsSitesTabs() {
        sameSite(otherwise: "top") { manager, space in
            let github = page("https://github.com/a", in: space), apple = page("https://www.apple.com/", in: space)
            let docs = page("https://docs.github.com/", in: space)
            manager.adopt([github, apple, docs], in: space)
            // From apple.com, a github.com link: after docs.github.com, the last github tab.
            let opened = manager.newTab(url: nil, spaceID: space, select: false, opener: apple, site: URL(string: "https://gist.github.com/b"))
            #expect(manager.tabs(in: space).map(\.id) == [github.id, apple.id, docs.id, opened.id])
            // A site with no tabs open: where the choice before said, on top.
            let other = manager.newTab(url: nil, spaceID: space, select: false, site: URL(string: "https://example.org/"))
            #expect(manager.tabs(in: space).first === other)
            // A tab with no page yet (⌘T's): the same.
            let empty = manager.newTab(url: nil, spaceID: space, select: false)
            #expect(manager.tabs(in: space).first === empty)
        }
    }

    @Test func pinnedPagesAndOtherSpacesDontCount() {
        sameSite(otherwise: "bottom") { manager, space in
            let apple = page("https://www.apple.com/", in: space)
            manager.adopt([apple], in: space)
            // A pinned github.com page is the sidebar's: a github link doesn't go beside it.
            manager.adoptBookmarkTab(page("https://github.com/pinned", in: space), bookmarkID: UUID())
            // Nor beside a github tab in another space.
            let elsewhere = UUID()
            manager.adopt([page("https://github.com/x", in: elsewhere)], in: elsewhere)
            let opened = manager.newTab(url: nil, spaceID: space, select: false, site: URL(string: "https://github.com/y"))
            #expect(manager.tabs(in: space).map(\.id) == [apple.id, opened.id])
            #expect(manager.tabs(in: elsewhere).count == 1)
        }
    }

    @Test func itJoinsTheGroupOfItsSitesTab() {
        sameSite(otherwise: "top") { manager, space in
            let parent = page("https://www.apple.com/", in: space), child = page("https://github.com/a", in: space)
            let after = page("https://www.apple.com/mac", in: space)
            child.parentID = parent.id
            manager.adopt([parent, child, after], in: space)
            let opened = manager.newTab(url: nil, spaceID: space, select: false, site: URL(string: "https://github.com/b"))
            #expect(manager.tabs(in: space).map(\.id) == [parent.id, child.id, opened.id, after.id])
            #expect(opened.parentID == parent.id)
        }
    }
}
