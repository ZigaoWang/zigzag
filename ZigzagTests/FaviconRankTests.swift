import Foundation
import Testing
@testable import Zigzag

/// Which icons a page is asked for, in what order: the site's own first, its home-screen tile only apart from them.
struct FaviconRankTests {
    private let page = URL(string: "https://example.com/a/page")!

    @Test func ownIconsLeadLargestUsefulFirst() {
        let ranked = FaviconStore.rank(links: [
            ["rel": "icon", "href": "https://example.com/16.png", "sizes": "16x16"],
            ["rel": "icon", "href": "https://example.com/32.png", "sizes": "32x32"],
            ["rel": "icon", "href": "https://example.com/icon.svg", "type": "image/svg+xml"],
        ], pageURL: page)
        #expect(ranked.icons.map(\.lastPathComponent) == ["icon.svg", "32.png", "16.png"])
    }

    @Test func homeScreenIconsStayApart() {
        // A touch icon that doesn't say its size isn't taken for a 16px icon of the site's own.
        let ranked = FaviconStore.rank(links: [
            ["rel": "icon", "href": "https://example.com/favicon-16.png", "sizes": "16x16"],
            ["rel": "apple-touch-icon", "href": "https://example.com/touch.png"],
        ], pageURL: page)
        #expect(ranked.icons.map(\.lastPathComponent) == ["favicon-16.png"])
        #expect(ranked.touch.map(\.lastPathComponent) == ["touch.png"])
    }

    @Test func fallbacksOnlyWhenNothingIsDeclared() {
        let none = FaviconStore.rank(links: [], pageURL: page)
        #expect(none.icons.map(\.path) == ["/favicon.ico"])
        #expect(none.touch.map(\.path) == ["/apple-touch-icon.png"])
        let declared = FaviconStore.rank(links: [["rel": "icon", "href": "https://example.com/i.png"]], pageURL: page)
        #expect(!declared.icons.map(\.path).contains("/favicon.ico"))
    }
}

/// Icons a page lists, however its HTML is written, and how long a site with none is left alone.
struct FaviconFetchTests {
    @Test func linksWithoutQuotesAreRead() {
        let links = FaviconStore.iconLinks(in: #"<link rel=icon href=//www.google.com/i.ico><link href='/a.png' rel="shortcut icon">"#)
        #expect(links.map { $0["href"] } == ["//www.google.com/i.ico", "/a.png"])
    }

    @Test func retriesWaitLongerUpToADay() {
        let first = FaviconStore.retryWait(after: nil)
        #expect(first == 60)
        #expect(FaviconStore.retryWait(after: first) == 120)
        #expect(FaviconStore.retryWait(after: 20 * 3600) == 24 * 3600)
    }
}

struct FaviconSignInTests {
    @Test func aSignInElsewhereIsNotTheSite() throws {
        let calendar = try #require(URL(string: "https://calendar.google.com/calendar/"))
        #expect(FaviconStore.isSignIn(try #require(URL(string: "https://accounts.google.com/v3/signin/identifier")), from: calendar))
        let notion = try #require(URL(string: "https://www.notion.so/"))
        #expect(!FaviconStore.isSignIn(try #require(URL(string: "https://www.notion.com/")), from: notion))
        #expect(!FaviconStore.isSignIn(try #require(URL(string: "https://example.com/login")), from: try #require(URL(string: "https://example.com/"))))
    }
}
