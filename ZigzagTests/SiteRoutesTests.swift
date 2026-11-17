import Foundation
import Testing
@testable import Zigzag

/// Sites that always open in a space (#286): which site a page is, which listed site covers it, which ways of getting
/// to a page are routed and which aren't, and what removing a space does to its sites.
@MainActor
struct SiteRoutesTests {
    private let media = UUID()
    private let work = UUID()
    private let personal = UUID()

    private func url(_ text: String) -> URL { URL(string: text)! }

    private var routes: [SiteRoutes.Route] {
        [.init(site: "youtube.com", spaceID: media), .init(site: "music.youtube.com", spaceID: personal), .init(site: "github.com", spaceID: work)]
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

    @Test func theMostSpecificSiteWins() {
        #expect(SiteRoutes.route(for: url("https://www.youtube.com/"), in: routes)?.spaceID == media)
        #expect(SiteRoutes.route(for: url("https://m.youtube.com/"), in: routes)?.spaceID == media)
        #expect(SiteRoutes.route(for: url("https://music.youtube.com/"), in: routes)?.spaceID == personal)
        #expect(SiteRoutes.route(for: url("https://gist.github.com/x"), in: routes)?.spaceID == work)
        #expect(SiteRoutes.route(for: url("https://example.com/"), in: routes) == nil)
    }

    @Test func whatYouTypeIntoAddSite() {
        #expect(SiteRoutes.entry(from: "youtube.com") == "youtube.com")
        #expect(SiteRoutes.entry(from: " https://www.youtube.com/feed ") == "youtube.com")
        #expect(SiteRoutes.entry(from: "*.github.com") == "github.com")
        #expect(SiteRoutes.entry(from: "WWW.Example.COM") == "example.com")
        #expect(SiteRoutes.entry(from: "") == nil)
        #expect(SiteRoutes.entry(from: "two words") == nil)
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
        // Open in Zigzag, from Zigzag Mini, is routed.
        #expect(target("https://youtube.com/", .fromMini, place: .mini) == media)
    }

    @Test func aSignInALinkSendsYouToStaysPut() {
        #expect(target("https://github.com/login/oauth/authorize?client_id=1", .linkClick) == nil)
        #expect(target("https://github.com/x?redirect_uri=https%3A%2F%2Fexample.com", .linkNewTab) == nil)
        #expect(target("https://github.com/login", .linkClick) == nil)
        // Typed, it's where you said.
        #expect(target("https://github.com/login", .typed) == work)
        #expect(target("https://github.com/zigzag", .linkClick) == work)
    }

    // MARK: Keeping them

    private func spaces() -> [SpaceInfo] {
        [SpaceInfo(id: personal, name: "Personal", color: .sky), SpaceInfo(id: media, name: "Media", color: .sky),
         SpaceInfo(id: work, name: "Work", color: .sky)]
    }

    @Test func aSiteIsKeptByOneSpace() {
        var list = SiteRoutes.setting("youtube.com", to: media, in: spaces())
        #expect(SiteRoutes.routes(in: list) == [.init(site: "youtube.com", spaceID: media)])
        list = SiteRoutes.setting("youtube.com", to: work, in: list)
        #expect(SiteRoutes.routes(in: list) == [.init(site: "youtube.com", spaceID: work)])
        list = SiteRoutes.setting("youtube.com", to: nil, in: list)
        #expect(SiteRoutes.routes(in: list).isEmpty)
        #expect(list.allSatisfy { $0.routedSites == nil })
    }

    @Test func aRemovedSpaceTakesItsSitesWithIt() {
        var list = SiteRoutes.setting("youtube.com", to: media, in: spaces())
        list = SiteRoutes.setting("github.com", to: work, in: list)
        list.removeAll { $0.id == media }
        let left = SiteRoutes.routes(in: list)
        #expect(left == [.init(site: "github.com", spaceID: work)])
        // Its site opens in any space again.
        #expect(SiteRoutes.target(for: url("https://youtube.com/"), arrival: .otherApp, from: personal, place: .browser, routes: left) == nil)
    }

    @Test func routesAreSavedWithTheirSpace() throws {
        let list = SiteRoutes.setting("youtube.com", to: media, in: spaces())
        let data = try JSONEncoder().encode(list)
        let read = try JSONDecoder().decode([SpaceInfo].self, from: data)
        #expect(SiteRoutes.routes(in: read) == [.init(site: "youtube.com", spaceID: media)])
        // A library from before routes reads with none.
        let old = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"{"id":"\#(media.uuidString)","name":"Media","color":"sky","bookmarks":[]}"#.utf8))
        #expect(old.routedSites == nil)
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
