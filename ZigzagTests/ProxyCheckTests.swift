import Foundation
import Testing
@testable import Zigzag

/// Telling a proxy on this Mac (Clash and the like) from the system's proxy settings, and what the error page says
/// when one is in the way.
struct ProxyCheckTests {
    private let clash: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
                                        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]

    @Test func aProxyOnThisMacIsFound() {
        #expect(ProxyCheck.localProxy(in: clash, scheme: "https") == "127.0.0.1:7890")
        #expect(ProxyCheck.localProxy(in: clash, scheme: "http") == "127.0.0.1:7890")
        #expect(ProxyCheck.localProxy(in: ["HTTPSEnable": true, "HTTPSProxy": "localhost", "HTTPSPort": 8080], scheme: "HTTPS") == "localhost:8080")
        #expect(ProxyCheck.localProxy(in: ["HTTPEnable": 1, "HTTPProxy": "::1", "HTTPPort": 7890], scheme: "http") == "[::1]:7890")
    }

    @Test func aProxyThatsOffOrElsewhereDoesntCount() {
        #expect(ProxyCheck.localProxy(in: [:], scheme: "https") == nil)
        #expect(ProxyCheck.localProxy(in: ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890], scheme: "https") == nil)
        #expect(ProxyCheck.localProxy(in: ["HTTPSEnable": 1, "HTTPSProxy": "proxy.corp.example", "HTTPSPort": 3128], scheme: "https") == nil)
        #expect(ProxyCheck.localProxy(in: ["HTTPSEnable": 1, "HTTPSProxy": "10.0.0.2", "HTTPSPort": 3128], scheme: "https") == nil)
        // Each scheme has its own proxy.
        #expect(ProxyCheck.localProxy(in: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890], scheme: "https") == nil)
        #expect(ProxyCheck.localProxy(in: clash, scheme: "file") == nil)
    }

    @Test func aSOCKSProxyCountsForBoth() {
        let socks: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891]
        #expect(ProxyCheck.localProxy(in: socks, scheme: "https") == "127.0.0.1:7891")
        #expect(ProxyCheck.localProxy(in: socks, scheme: "http") == "127.0.0.1:7891")
        #expect(ProxyCheck.localProxy(in: ["SOCKSEnable": 1, "SOCKSProxy": "socks.example", "SOCKSPort": 1080], scheme: "https") == nil)
    }

    @Test func theErrorPageNamesTheProxy() throws {
        let site = try #require(URL(string: "https://www.not-a-real-site-zz.com/"))
        let plain = try #require(URL(string: "http://www.not-a-real-site-zz.com/"))
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorBadServerResponse] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            let (title, message) = ErrorPage.describe(error, url: site, proxy: "127.0.0.1:7890")
            #expect(title == "Can’t open this site", "\(code)")
            #expect(message.contains("(127.0.0.1:7890)") && message.contains("proxy off") && message.hasSuffix("."), "\(code)")
            #expect(ErrorPage.describe(error, url: plain, proxy: "127.0.0.1:7890").0 == "Can’t open this site")
            // Without a proxy, nothing changes.
            #expect(ErrorPage.describe(error, url: site).0 != "Can’t open this site", "\(code)")
        }
        #expect(ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), url: site).0 == "Can’t connect securely")
        // Other problems, and a server on this Mac, keep their own words.
        #expect(ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), url: site, proxy: "127.0.0.1:7890").0 == "You’re offline")
        #expect(ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted), url: site, proxy: "127.0.0.1:7890").0 == "This connection isn’t private")
        let local = try #require(URL(string: "http://localhost:5173/"))
        #expect(ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), url: local, proxy: "127.0.0.1:7890").1.contains("running"))
        let page = ErrorPage.html(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), url: site, canGoBack: true,
                                  proceedLink: nil, proxy: "127.0.0.1:7890", style: "", nonce: "n")
        #expect(page.contains("127.0.0.1:7890") && page.contains(#"data-action="try-again""#) && page.contains(#"data-action="go-back""#))
    }

    @Test func anEmptyServerErrorIsABrokenPage() throws {
        let url = try #require(URL(string: "http://www.not-a-real-site-zz.com/"))
        func response(_ status: Int, length: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: length.map { ["Content-Length": $0] } ?? [:])!
        }
        let failure = try #require(ErrorPage.emptyServerFailure(response(502, length: "0")))
        #expect(ErrorPage.kind(of: failure, url: url) == .broken)
        #expect(failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL == url)
        #expect(ErrorPage.technical(failure, url: url).contains("502"))
        #expect(ErrorPage.emptyServerFailure(response(503, length: "0")) != nil)
        // A site's own error page, one of unknown length, or anything that isn't a server error, is shown as sent.
        #expect(ErrorPage.emptyServerFailure(response(502, length: "1234")) == nil)
        #expect(ErrorPage.emptyServerFailure(response(500, length: nil)) == nil)
        #expect(ErrorPage.emptyServerFailure(response(404, length: "0")) == nil)
        #expect(ErrorPage.emptyServerFailure(response(204, length: "0")) == nil)
        #expect(ErrorPage.emptyServerFailure(URLResponse(url: url, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)) == nil)
    }
}
