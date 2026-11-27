import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A user agent kept for a site (#392): the choices, matching, what a page is sent, removal, storage and typed agents.
@MainActor
@Suite(.serialized)
struct SiteUserAgentsTests {
    private func withDefaults(_ body: () throws -> Void) throws {
        let suite = "zigzag-user-agent-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SiteUserAgents.defaults
        SiteUserAgents.defaults = defaults
        defer {
            SiteUserAgents.defaults = before
            defaults.removeScratchSuite(suite)
        }
        try body()
    }

    private let chrome = DeveloperState.UserAgent.chrome.string

    @Test func theChoicesAreDefaultSafariChromeFirefox() {
        #expect(SiteUserAgents.offered(with: nil) == [nil, .safari, .chrome, .firefox])
        #expect(SiteUserAgents.offered(with: .chrome) == [nil, .safari, .chrome, .firefox])
        #expect(SiteUserAgents.offered(with: .custom("Agent/1.0")) == [nil, .safari, .chrome, .firefox, .custom("Agent/1.0")])
        #expect(SiteUserAgents.offered(with: nil).map { $0?.title ?? SiteUserAgents.defaultTitle } == [SiteUserAgents.defaultTitle, "Safari", "Chrome", "Firefox"])
        // Safari's is Zigzag's own; the others name their browser on a Mac.
        #expect(SiteUserAgents.Choice.safari.string == WebKitSetup.userAgent)
        #expect(SiteUserAgents.Choice.chrome.string.contains("Macintosh") && SiteUserAgents.Choice.chrome.string.contains("Chrome/"))
        #expect(SiteUserAgents.Choice.firefox.string.contains("Macintosh") && SiteUserAgents.Choice.firefox.string.contains("Firefox/"))
    }

    @Test func aKeptChoiceIsSentFromTheFirstLoad() throws {
        try withDefaults {
            SiteUserAgents.set(.chrome, for: URL(string: "http://localhost:1/"))
            let tab = Tab(url: URL(string: "http://localhost:1/page"), spaceID: UUID())
            let webView = tab.ensureWebView()
            #expect(webView.customUserAgent == chrome)
            #expect(tab.userAgent(at: URL(string: "http://localhost:1/other")) == chrome)
            tab.close()
        }
    }

    @Test func aNewWindowStartsWithTheSitesChoice() throws {
        try withDefaults {
            SiteUserAgents.set(.firefox, forSite: "example.com")
            let made = WKWebView()
            SiteUserAgents.prepare(made, for: URL(string: "https://example.com/sign-in"))
            #expect(made.customUserAgent == DeveloperState.UserAgent.firefox.string)
            // Elsewhere it starts as Zigzag.
            let other = WKWebView()
            SiteUserAgents.prepare(other, for: URL(string: "https://example.org"))
            #expect((other.customUserAgent ?? "").isEmpty)
        }
    }

    @Test func aSiteCoversItsSubdomainsAndTheMostSpecificWins() throws {
        try withDefaults {
            SiteUserAgents.set(.firefox, for: URL(string: "https://www.example.com/a"))
            #expect(SiteUserAgents.choice(forSite: "example.com") == .firefox)
            #expect(SiteUserAgents.choice(for: URL(string: "https://example.com")) == .firefox)
            #expect(SiteUserAgents.choice(for: URL(string: "https://shop.example.com/b")) == .firefox)
            SiteUserAgents.set(.chrome, forSite: "shop.example.com")
            #expect(SiteUserAgents.choice(for: URL(string: "https://shop.example.com/b")) == .chrome)
            #expect(SiteUserAgents.choice(for: URL(string: "https://example.org")) == nil)
            // Default under the parent's choice is Zigzag's own, kept as Safari.
            SiteUserAgents.choose(nil, for: URL(string: "https://shop.example.com/b"), in: nil)
            #expect(SiteUserAgents.choice(forSite: "shop.example.com") == .safari)
            #expect(SiteUserAgents.agent(for: URL(string: "https://shop.example.com/b")) == WebKitSetup.userAgent)
            // Only web pages.
            #expect(SiteUserAgents.choice(for: URL(string: "zigzag://settings")) == nil)
        }
    }

    @Test func nothingChosenLeavesZigzagsOwn() throws {
        try withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let webView = tab.ensureWebView()
            #expect((webView.customUserAgent ?? "").isEmpty)
            #expect(tab.userAgent(at: URL(string: "https://example.com")) == nil)
            tab.close()
        }
    }

    @Test func removalRestoresTheDefault() throws {
        try withDefaults {
            let url = URL(string: "http://localhost:1/")
            SiteUserAgents.set(.chrome, for: url)
            let tab = Tab(url: url, spaceID: UUID())
            let webView = tab.ensureWebView()
            #expect(webView.customUserAgent == chrome)
            SiteUserAgents.choose(nil, for: url, in: tab)
            #expect(SiteUserAgents.sites.isEmpty)
            #expect(tab.userAgent(at: url) == nil)
            #expect((webView.customUserAgent ?? "").isEmpty)
            // Settings' ×.
            SiteUserAgents.set(.firefox, for: url)
            SiteUserAgents.forget(site: "localhost")
            #expect(SiteUserAgents.agent(for: url) == nil)
            tab.close()
        }
    }

    @Test func choicesReadBack() throws {
        try withDefaults {
            SiteUserAgents.set(.chrome, forSite: "example.com")
            SiteUserAgents.set(.custom("Agent/1.0"), forSite: "bank.com")
            let raw = SiteUserAgents.defaults.dictionary(forKey: "UserAgentSites") as? [String: String]
            #expect(raw == ["example.com": "chrome", "bank.com": "custom:Agent/1.0"])
            #expect(SiteUserAgents.all == ["example.com": .chrome, "bank.com": .custom("Agent/1.0")])
            for choice in SiteUserAgents.Choice.presets + [.custom("X")] { #expect(SiteUserAgents.Choice(stored: choice.stored) == choice) }
            // Something unknown is skipped, not misread.
            SiteUserAgents.defaults.set(["example.com": "chrome", "odd.com": "netscape"], forKey: "UserAgentSites")
            #expect(SiteUserAgents.all == ["example.com": .chrome])
            SiteUserAgents.forget(site: "example.com")
            #expect(SiteUserAgents.sites.isEmpty)
            SiteUserAgents.set(.firefox, forSite: "a.com")
            SiteUserAgents.forgetAll()
            #expect(SiteUserAgents.all.isEmpty)
        }
    }

    @Test func aTypedAgentIsTrimmedAndNeverEmpty() {
        #expect(SiteUserAgents.cleaned("  Agent/1.0 \n") == "Agent/1.0")
        #expect(SiteUserAgents.cleaned("Agent\n1.0") == "Agent 1.0")
        #expect(SiteUserAgents.cleaned("Agent\t1.0") == "Agent 1.0")
        #expect(SiteUserAgents.cleaned("   ") == nil)
        #expect(SiteUserAgents.cleaned("\n") == nil)
        #expect(SiteUserAgents.cleaned("Agent/1.0 (Mac…)") == nil)
        #expect(SiteUserAgents.cleaned(String(repeating: "a", count: SiteUserAgents.maxLength + 1)) == nil)
        #expect(SiteUserAgents.Choice(stored: "custom:   ") == nil)
        #expect(SiteUserAgents.Choice(stored: "custom: Agent ") == .custom("Agent"))
    }

    @Test func browserVersionsMoveOn() {
        let start = Date(timeIntervalSince1970: 1_795_219_200)
        #expect(DeveloperState.UserAgent.major(157, on: start) == 157)
        #expect(DeveloperState.UserAgent.major(157, on: start.addingTimeInterval(27 * 86_400)) == 157)
        #expect(DeveloperState.UserAgent.major(157, on: start.addingTimeInterval(28 * 86_400)) == 158)
        #expect(DeveloperState.UserAgent.major(157, on: start.addingTimeInterval(365 * 86_400)) == 170)
        // A clock set back never names an older one.
        #expect(DeveloperState.UserAgent.major(157, on: start.addingTimeInterval(-100 * 86_400)) == 157)
    }

    @Test func privateWindowsFollowKeptChoicesWithoutTheRow() throws {
        try withDefaults {
            var c = SitePanelRows.Context()
            #expect(SitePanelRows.rows(c).contains(.userAgent))
            c.isPrivate = true
            c.siteChoices = false
            #expect(!SitePanelRows.rows(c).contains(.userAgent))
            var page = SitePanelRows.Context()
            page.isWeb = false
            #expect(!SitePanelRows.rows(page).contains(.userAgent))
            var store = SitePanelRows.Context()
            store.userAgent = false
            #expect(!SitePanelRows.rows(store).contains(.userAgent))

            let url = URL(string: "http://localhost:1/")
            SiteUserAgents.set(.chrome, for: url)
            let tab = Tab(url: url, spaceID: UUID())
            tab.privateStore = .nonPersistent()
            let webView = tab.ensureWebView()
            #expect(webView.customUserAgent == chrome)
            // Nothing is kept from a private window.
            SiteUserAgents.choose(.firefox, for: url, in: tab)
            #expect(SiteUserAgents.all == ["localhost": .chrome])
            tab.close()
        }
    }

    @Test func theAddonsStoreIsStillAskedForAsFirefox() throws {
        try withDefaults {
            let store = try #require(URL(string: "https://addons.mozilla.org/en-US/firefox/"))
            SiteUserAgents.set(.chrome, for: store)
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            #expect(tab.userAgent(at: store) == DeveloperState.UserAgent.firefox.string)
            #expect(SiteUserAgents.agent(for: store) == DeveloperState.UserAgent.firefox.string)
            tab.close()
        }
    }
}
