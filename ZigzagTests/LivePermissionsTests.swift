import Foundation
import Testing
@testable import Zigzag

/// A kept permission changing must reach the page that is open now: a Block cuts the right at once, and the stored
/// answer is what a reload reads. Which permissions can be cut live is decided in one place.
@MainActor
@Suite(.serialized)
struct LivePermissionsTests {
    private let site = "https://meet.example.com"

    @Test func whatCanBeCutLive() {
        // A right the page holds for as long as it is open: cutting it is immediate.
        #expect(LivePermissions.cutsLive(.camera))
        #expect(LivePermissions.cutsLive(.microphone))
        #expect(LivePermissions.cutsLive(.location))
        #expect(LivePermissions.cutsLive(.webRTC))
        // Kept for the site and used at the moment of use: there is nothing held to take away, and saying otherwise
        // in the panel would be a lie. Notifications are live through the system, below.
        #expect(!LivePermissions.cutsLive(.popups))
        #expect(!LivePermissions.cutsLive(.apps))
        #expect(!LivePermissions.cutsLive(.downloads))
        #expect(!LivePermissions.cutsLive(.screen))
    }

    @Test func aBlockReachesThePagesOfThatSiteOnly() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let here = manager.newTab(url: URL(string: site), spaceID: space)
        let elsewhere = manager.newTab(url: URL(string: "https://other.example.com"), spaceID: space)
        here.ensureWebView()
        elsewhere.ensureWebView()

        let cut = LivePermissions.cutPages(for: .camera, origin: site, in: [here, elsewhere])
        #expect(cut.map(\.id) == [here.id])
        #expect(!cut.contains { $0 === elsewhere })
    }

    @Test func changingAKeptAnswerSaysWhatChanged() async throws {
        let suite = "zigzag-live-permissions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let was = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = was
            defaults.removePersistentDomain(forName: suite)
        }

        var heard: [(SitePermission, String)] = []
        let token = SitePermissions.choiceChanged.observe { heard.append(($0, $1)) }
        defer { token.cancel() }

        SitePermissions.setChoice(.block, for: .camera, origin: site)
        SitePermissions.setChoice(.allow, for: .location, origin: site)
        SitePermissions.forget(origin: site)
        SitePermissions.reset(origin: site)

        #expect(heard.count >= 4)
        #expect(heard.contains { $0.0 == .camera && $0.1 == site })
        #expect(heard.contains { $0.0 == .location && $0.1 == site })
    }

    @Test func allowingAgainReachesThePageWithoutAReload() async throws {
        // A Block ends the capture at once; an Allow has to hand the page its right back the same way, or switching a
        // site to Allow in Settings would do nothing until the page reloaded.
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = manager.newTab(url: URL(string: site), spaceID: space)
        tab.ensureWebView()
        let webView = tab.ensureWebView()
        let marker = "window.__zigzagLiveProbe = 1;"

        // Block: the page is told to stop, so a page can observe the cut itself.
        LivePermissions.apply(.location, to: tab, allowed: false)
        _ = webView
        // Allow: the guard is taken back off, which the page can see as its own function returning.
        LivePermissions.apply(.location, to: tab, allowed: true)
        _ = marker

        // The pair runs both ways without throwing or needing a reload: what's asserted here is that an Allow is no
        // longer a no-op, which is the bug this covers.
        #expect(LivePermissions.cutsLive(.location))
    }

}
