import Foundation
import Testing
@testable import Zigzag

/// The page shown in place of one that didn't load: which kind of problem each error is, what it offers, how it
/// names the site, and that nothing a site or the system says can get out of its text.
struct ErrorPageTests {
    private func error(_ code: Int, _ domain: String = NSURLErrorDomain, description: String? = nil) -> NSError {
        NSError(domain: domain, code: code, userInfo: description.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
    }

    private let site = URL(string: "https://www.star-history.com/#zigzag")!

    @Test func eachErrorIsItsKindOfProblem() throws {
        let cases: [(NSError, ErrorPage.Kind)] = [
            (error(NSURLErrorNotConnectedToInternet), .offline), (error(NSURLErrorNetworkConnectionLost), .offline),
            (error(NSURLErrorCannotFindHost), .notFound), (error(NSURLErrorDNSLookupFailed), .notFound),
            (error(NSURLErrorCannotConnectToHost), .refused), (error(NSURLErrorTimedOut), .timedOut),
            (error(NSURLErrorSecureConnectionFailed), .secureFailed),
            (error(NSURLErrorServerCertificateUntrusted), .certificate), (error(NSURLErrorServerCertificateHasBadDate), .certificate),
            (error(NSURLErrorServerCertificateNotYetValid), .certificate), (error(NSURLErrorServerCertificateHasUnknownRoot), .certificate),
            (error(NSURLErrorClientCertificateRequired), .clientCertificate), (error(NSURLErrorHTTPTooManyRedirects), .redirects),
            (error(NSURLErrorBadServerResponse), .broken), (error(NSURLErrorBadURL), .badAddress),
            (error(NSURLErrorFileDoesNotExist), .missingFile), (error(NSURLErrorNoPermissionsToReadFile), .unreadableFile),
            (error(NSURLErrorResourceUnavailable), .unavailable), (error(-99999), .other),
            (error(103, "WebKitErrorDomain"), .port), (error(101, "WebKitErrorDomain"), .badAddress),
            (error(104, "WebKitErrorDomain"), .blocked), (error(105, "WebKitErrorDomain"), .filtered),
            (error(1, ErrorPage.crashDomain), .stopped), (error(7, "SomeOtherDomain"), .other),
        ]
        for (error, kind) in cases { #expect(ErrorPage.kind(of: error, url: site) == kind, "\(error.domain) \(error.code)") }
        let gone = try #require(URL(string: "webkit-extension://abc/welcome.html"))
        #expect(ErrorPage.kind(of: error(NSURLErrorResourceUnavailable), url: gone) == .extensionGone)
    }

    @Test func eachKindHasItsOwnDrawing() {
        let drawings = Set([ErrorPage.Kind.offline, .notFound, .refused, .timedOut, .secureFailed, .certificate, .clientCertificate,
                            .redirects, .broken, .missingFile, .unreadableFile, .blocked, .extensionGone, .stopped, .other]
            .map(ErrorPage.symbol(for:)))
        #expect(drawings.count == 15)
        for kind in ErrorPage.Kind.allCases {
            let svg = ErrorPage.symbol(for: kind)
            #expect(svg.hasPrefix("<svg") && svg.contains(#"aria-hidden="true""#))
        }
        // Only the certificate warning is drawn in the warning color.
        #expect(ErrorPage.Kind.allCases.filter { ErrorPage.symbol(for: $0).contains("warning") } == [.certificate])
    }

    @Test func actionsFitTheProblem() {
        #expect(ErrorPage.actions(for: .notFound, canGoBack: false) == [.tryAgain])
        #expect(ErrorPage.actions(for: .notFound, canGoBack: true) == [.tryAgain, .goBack])
        #expect(ErrorPage.actions(for: .offline, canGoBack: true) == [.tryAgain, .goBack])
        #expect(ErrorPage.actions(for: .stopped, canGoBack: false) == [.reload])
        // Going back is the safe choice on a certificate warning, so it leads.
        #expect(ErrorPage.actions(for: .certificate, canGoBack: true) == [.goBack, .tryAgain])
        #expect(ErrorPage.actions(for: .certificate, canGoBack: false) == [.tryAgain])
        // Trying again can't open a closed port or bring back an extension.
        #expect(ErrorPage.actions(for: .port, canGoBack: false).isEmpty)
        #expect(ErrorPage.actions(for: .extensionGone, canGoBack: true) == [.goBack])
    }

    @Test func titlesLeaveTheSiteToItsOwnLine() {
        for kind in ErrorPage.Kind.allCases where kind != .extensionGone {
            let failure = cases[kind] ?? error(-99999)
            let (title, message) = ErrorPage.describe(failure, url: site)
            #expect(!title.contains("star-history") && !message.contains("star-history"), "\(kind)")
            #expect(!title.isEmpty && message.hasSuffix("."), "\(kind)")
        }
    }

    private var cases: [ErrorPage.Kind: NSError] {
        [.offline: error(NSURLErrorNotConnectedToInternet), .notFound: error(NSURLErrorCannotFindHost), .refused: error(NSURLErrorCannotConnectToHost),
         .timedOut: error(NSURLErrorTimedOut), .secureFailed: error(NSURLErrorSecureConnectionFailed),
         .certificate: error(NSURLErrorServerCertificateUntrusted), .clientCertificate: error(NSURLErrorClientCertificateRequired),
         .redirects: error(NSURLErrorHTTPTooManyRedirects), .broken: error(NSURLErrorBadServerResponse), .badAddress: error(NSURLErrorBadURL),
         .port: error(103, "WebKitErrorDomain"), .blocked: error(104, "WebKitErrorDomain"), .filtered: error(105, "WebKitErrorDomain"),
         .missingFile: error(NSURLErrorFileDoesNotExist), .unreadableFile: error(NSURLErrorNoPermissionsToReadFile),
         .unavailable: error(NSURLErrorResourceUnavailable), .stopped: error(1, ErrorPage.crashDomain)]
    }

    @Test func aServerOnThisMacIsntCalledDown() throws {
        let local = try #require(URL(string: "http://127.0.0.1:1/"))
        let refused = error(NSURLErrorCannotConnectToHost)
        #expect(ErrorPage.isOnThisMac(local))
        #expect(ErrorPage.isOnThisMac(try #require(URL(string: "http://localhost:5173/"))))
        #expect(ErrorPage.isOnThisMac(try #require(URL(string: "http://[::1]:8080/"))))
        #expect(!ErrorPage.isOnThisMac(site))
        #expect(ErrorPage.describe(refused, url: local).1.contains("running"))
        #expect(ErrorPage.describe(refused, url: site).1.contains("down"))
    }

    @Test func theSiteIsNamedWhole() throws {
        #expect(ErrorPage.siteName(for: site) == "www.star-history.com")
        #expect(ErrorPage.siteName(for: try #require(URL(string: "http://127.0.0.1:1/"))) == "127.0.0.1:1")
        #expect(ErrorPage.siteName(for: try #require(URL(string: "http://[::1]:8080/"))) == "[::1]:8080")
        #expect(ErrorPage.siteName(for: URL(fileURLWithPath: "/tmp/Shanghai Guide.pdf")) == "Shanghai Guide.pdf")
        #expect(ErrorPage.siteName(for: try #require(URL(string: "webkit-extension://abc/page.html"))) == nil)
        // An absurdly long host loses its middle, keeping the end that says whose it is.
        let long = try #require(URL(string: "https://" + String(repeating: "a", count: 80) + ".preview.example-deploys.app/"))
        let name = try #require(ErrorPage.siteName(for: long))
        #expect(name.count == 56)
        #expect(name.hasPrefix("aaaa") && name.hasSuffix(".preview.example-deploys.app") && name.contains("…"))
    }

    @Test func nothingGetsOutOfItsText() {
        #expect(ErrorPage.escape(#"<script>"a" & 'b'</script>"#) == "&lt;script&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/script&gt;")
        let hostile = URL(string: "https://example.com/%3Cscript%3Ealert(1)%3C/script%3E?q=%22%3E%3Cimg")!
        let failure = error(NSURLErrorCannotFindHost, description: #"<img src=x onerror="alert(1)">"#)
        let page = ErrorPage.html(error: failure, url: hostile, canGoBack: true, proceedLink: nil, style: "", nonce: "n0nce")
        #expect(!page.contains("<img"))
        #expect(page.contains("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"))
        // One script, allowed by its nonce; nothing loads from anywhere.
        #expect(page.components(separatedBy: "<script").count == 2)
        #expect(page.contains(#"<script nonce="n0nce">"#) && page.contains("script-src 'nonce-n0nce'") && page.contains("default-src 'none'"))
        #expect(!page.contains("http://") && !page.contains("src=\"http"))
        #expect(page.contains(#"data-action="try-again""#) && page.contains(#"data-action="go-back""#))
    }

    @Test func onlyACertificateWarningOffersAWayThrough() throws {
        let url = try #require(URL(string: "https://router.local:8443/"))
        let link = try #require(CertificateExceptions.proceedLink(for: url, nonce: "abc"))
        let warning = ErrorPage.html(error: error(NSURLErrorServerCertificateHasUnknownRoot), url: url, canGoBack: false, proceedLink: link,
                                     style: "", nonce: "n")
        #expect(warning.contains(#"class="anyway" href="zigzag-proceed://router.local:8443/?zigzag-nonce=abc""#))
        #expect(warning.contains("router"))
        let plain = ErrorPage.html(error: error(NSURLErrorCannotFindHost), url: url, canGoBack: false, proceedLink: nil, style: "", nonce: "n")
        #expect(!plain.contains(#"class="anyway""#) && !plain.contains(CertificateExceptions.scheme))
    }

    @Test func technicalDetailsSayWhatTheSystemSaid() {
        let text = ErrorPage.technical(error(NSURLErrorCannotFindHost, description: "A server with the specified hostname could not be found."), url: site)
        #expect(text == "A server with the specified hostname could not be found.\nNSURLErrorDomain -1003\nhttps://www.star-history.com/#zigzag")
    }

    @Test func onlyComingBackOnlineRetries() {
        var gate = OfflineRetry.Gate()
        // Online from the first word: nothing changed, so nothing reloads in a loop.
        let retries = [true, false, false, true, true].map { gate.note(online: $0) }
        // Only the network coming back after being gone.
        #expect(retries == [false, false, false, true, false])
    }
}
