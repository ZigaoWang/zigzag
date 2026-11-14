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

/// Which icon a tab wears as a new page commits in it.
struct TabIconOnCommitTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func anotherSiteDropsTheLastOnesIcon() {
        // YouTube, then a page with no icon of its own: never YouTube's icon over it.
        #expect(!Tab.keepsIcon(from: url("https://www.youtube.com/watch?v=x"), to: url("http://127.0.0.1:8917/video.html")))
        #expect(!Tab.keepsIcon(from: url("https://example.com/"), to: url("https://example.org/")))
    }

    @Test func theSameSiteKeepsItsIcon() {
        #expect(Tab.keepsIcon(from: url("https://www.youtube.com/"), to: url("https://youtube.com/watch?v=x")))
        #expect(Tab.keepsIcon(from: url("https://example.com/a"), to: url("https://EXAMPLE.com/b")))
    }

    @Test func theFirstPageKeepsTheIconItWasRestoredWith() {
        #expect(Tab.keepsIcon(from: nil, to: url("https://example.com/")))
    }
}

/// Icons are fetched for every profile from one place, so never with cookies: a jar shared by those fetches would let
/// a site tie one profile's visit to another's.
@MainActor
struct FaviconSessionTests {
    @Test func iconsAreFetchedWithoutCookies() {
        let configuration = FaviconStore.makeSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }

    /// Suggestions and notification icons go through `.cookieless`: `.ephemeral` alone keeps a site's cookies in
    /// memory and sends them back for as long as Zigzag runs.
    @Test func cookielessKeepsNoneEvenInMemory() {
        let configuration = URLSessionConfiguration.cookieless
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(URLSessionConfiguration.ephemeral.httpCookieStorage != nil)
    }
}

/// A page picks its icon links, and Zigzag fetches them itself: only from the web or the page, never this Mac's files,
/// never this Mac or its network for a page on the web, and never more than an icon's worth of bytes.
@Suite(.serialized)
@MainActor
struct FaviconSourceTests {
    nonisolated final class Server: URLProtocol, @unchecked Sendable {
        /// Address to (status, Location or nil, body size).
        nonisolated(unsafe) static var answers: [String: (Int, String?, Int)] = [:]
        nonisolated(unsafe) static var asked: [URL] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            Self.asked.append(url)
            let (status, location, size) = Self.answers[url.absoluteString] ?? (404, nil, 0)
            let headers = location.map { ["Location": $0] } ?? [:]
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            if let location, let next = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In pieces, as a stream would come.
            var sent = 0
            while sent < size {
                let piece = min(256_000, size - sent)
                client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: piece))
                sent += piece
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private let page = URL(string: "https://example.com/")!

    private func configuration() -> URLSessionConfiguration {
        let configuration = FaviconStore.makeConfiguration()
        configuration.protocolClasses = [Server.self]
        return configuration
    }

    @Test func onlyWebAndPageIconsAreRanked() {
        let ranked = FaviconStore.rank(links: [
            ["rel": "icon", "href": "file:///etc/hosts", "sizes": "64x64"],
            ["rel": "icon", "href": "file:///dev/zero"],
            ["rel": "icon", "href": "ftp://example.com/i.png"],
            ["rel": "icon", "href": "data:image/png;base64,AAAA"],
            ["rel": "icon", "href": "https://example.com/i.png"],
        ], pageURL: page)
        #expect(Set(ranked.icons.compactMap(\.scheme)) == ["data", "https"])
        #expect(ranked.icons.count == 2)
        // A page that isn't on the web has no usual addresses to look at.
        let file = FaviconStore.rank(links: [], pageURL: URL(string: "file://host/a.html")!)
        #expect(file.icons.isEmpty && file.touch.isEmpty)
    }

    @Test func fileAndOtherSchemesAreNeverFetched() async {
        #expect(await !FaviconStore.mayFetch(URL(string: "file:///etc/hosts")!, for: page))
        #expect(await !FaviconStore.mayFetch(URL(string: "file:///dev/zero")!, for: URL(string: "http://localhost:3000/")!))
        #expect(await FaviconStore.download(URL(string: "file:///etc/hosts")!, for: page, configuration: configuration()) == nil)
    }

    @Test func aPageOnTheWebGetsNoIconFromThisMacOrItsNetwork() async {
        for address in ["http://127.0.0.1/i.png", "http://localhost/i.png", "http://192.168.1.1/favicon.ico", "http://[::1]/i.png", "http://printer.local/i.png"] {
            #expect(await !FaviconStore.mayFetch(URL(string: address)!, for: page), "\(address)")
        }
        #expect(await FaviconStore.mayFetch(URL(string: "https://93.184.216.34/i.png")!, for: page))
        // A page that is itself there may have its icon there too.
        #expect(await FaviconStore.mayFetch(URL(string: "http://localhost:3000/favicon.ico")!, for: URL(string: "http://localhost:3000/")!))
        #expect(await FaviconStore.mayFetch(URL(string: "http://192.168.1.1/favicon.ico")!, for: URL(string: "http://192.168.1.1/")!))
    }

    @Test func aRedirectIsCheckedAsTheIconItself() async {
        Server.asked = []
        Server.answers = [
            "https://93.184.216.34/to-lan.png": (302, "http://192.168.1.1/secret", 0),
            "http://192.168.1.1/secret": (200, nil, 100),
            "https://93.184.216.34/moved.png": (301, "https://93.184.216.35/i.png", 0),
            "https://93.184.216.35/i.png": (200, nil, 100),
        ]
        #expect(await FaviconStore.download(URL(string: "https://93.184.216.34/to-lan.png")!, for: page, configuration: configuration()) == nil)
        #expect(!Server.asked.contains { $0.host() == "192.168.1.1" })
        #expect(await FaviconStore.download(URL(string: "https://93.184.216.34/moved.png")!, for: page, configuration: configuration())?.count == 100)
    }

    @Test func anIconPastTheLimitIsGivenUp() async {
        Server.answers = [
            "https://93.184.216.34/huge.ico": (200, nil, FaviconStore.maxIconBytes + 1_000),
            "https://93.184.216.34/fine.ico": (200, nil, 4_000),
        ]
        #expect(await FaviconStore.download(URL(string: "https://93.184.216.34/huge.ico")!, for: page, configuration: configuration()) == nil)
        #expect(await FaviconStore.download(URL(string: "https://93.184.216.34/fine.ico")!, for: page, configuration: configuration())?.count == 4_000)
    }
}

extension FaviconRankTests {
    /// Behind a proxy in fake-IP mode every name resolves to 198.18.x.x; icons by name still load, while addresses
    /// written as private ones are still refused.
    @Test func iconsAreJudgedByTheirAddressAsWrittenNotByDNS() {
        #expect(IconAddress.mayFetchByName(URL(string: "https://github.githubassets.com/favicon.svg")!))
        #expect(IconAddress.mayFetchByName(URL(string: "https://www.theguardian.com/favicon.ico")!))
        #expect(!IconAddress.mayFetchByName(URL(string: "http://198.18.0.16/i.png")!))
        #expect(!IconAddress.mayFetchByName(URL(string: "http://localhost/i.png")!))
        #expect(!IconAddress.mayFetchByName(URL(string: "file:///etc/hosts")!))
    }
}
