import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A certificate let through on the warning page: bound to itself, for a while, never without one or for an HSTS site, and said to be not secure.
@MainActor
struct CertificateTrustTests {
    @Test func anExceptionIsForItsCertificateOnly() {
        let store = WKWebsiteDataStore.nonPersistent()
        let leaf = Data([1, 2, 3, 4]), other = Data([9, 9, 9])
        // Never without a certificate: empty data would stand for any.
        #expect(!CertificateExceptions.allow("router.local", certificate: nil, in: store))
        #expect(!CertificateExceptions.allow("router.local", certificate: Data(), in: store))
        #expect(!CertificateExceptions.allows("router.local", leaf: other, in: store))
        #expect(!CertificateExceptions.hasException(for: "router.local", in: store))
        #expect(CertificateExceptions.allow("Router.Local", certificate: leaf, in: store))
        #expect(CertificateExceptions.allows("router.local", leaf: leaf, in: store))
        #expect(!CertificateExceptions.allows("router.local", leaf: other, in: store))
        #expect(!CertificateExceptions.allows("router.local", leaf: nil, in: store))
        #expect(!CertificateExceptions.allows("router.local", leaf: Data(), in: store))
        #expect(!CertificateExceptions.allows("other.local", leaf: leaf, in: store))
        // Another store (a private window) has its own.
        #expect(!CertificateExceptions.allows("router.local", leaf: leaf, in: WKWebsiteDataStore.nonPersistent()))
    }

    @Test func anExceptionRunsOut() {
        let store = WKWebsiteDataStore.nonPersistent()
        let leaf = Data([7, 7, 7])
        let then = Date(timeIntervalSinceNow: -CertificateExceptions.lifetime - 1)
        CertificateExceptions.allow("nas.local", certificate: leaf, in: store, now: then)
        #expect(!CertificateExceptions.hasException(for: "nas.local", in: store))
        #expect(!CertificateExceptions.allows("nas.local", leaf: leaf, in: store))
        CertificateExceptions.allow("nas.local", certificate: leaf, in: store)
        #expect(CertificateExceptions.allows("nas.local", leaf: leaf, in: store))
        #expect(!CertificateExceptions.allows("nas.local", leaf: leaf, in: store, now: Date(timeIntervalSinceNow: CertificateExceptions.lifetime + 1)))
    }

    @Test func noWayPastWithoutACertificateOrForHSTS() {
        #expect(CertificateExceptions.mayOffer(certificate: Data([1]), strictTransport: false))
        #expect(!CertificateExceptions.mayOffer(certificate: nil, strictTransport: false))
        #expect(!CertificateExceptions.mayOffer(certificate: Data(), strictTransport: false))
        #expect(!CertificateExceptions.mayOffer(certificate: Data([1]), strictTransport: true))
        let url = URL(string: "https://bank.example/")!
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let page = ErrorPage.html(error: failure, url: url, canGoBack: false, proceedLink: nil, noWayPast: .strictTransport, style: "", nonce: "n")
        #expect(!page.contains(#"class="anyway""#) && !page.contains(CertificateExceptions.scheme))
        #expect(page.contains(ErrorPage.escape(ErrorPage.NoWayPast.strictTransport.text)))
        let unread = ErrorPage.html(error: failure, url: url, canGoBack: false, proceedLink: nil, noWayPast: .noCertificate, style: "", nonce: "n")
        #expect(unread.contains(ErrorPage.escape(ErrorPage.NoWayPast.noCertificate.text)))
    }

    @Test func readsStrictTransportHeaders() {
        #expect(StrictTransport.parse("max-age=31536000; includeSubDomains") == .init(maxAge: 31_536_000, includesSubdomains: true))
        #expect(StrictTransport.parse("max-age=\"600\"") == .init(maxAge: 600, includesSubdomains: false))
        #expect(StrictTransport.parse(" includeSubDomains ; max-age=0 ; preload") == .init(maxAge: 0, includesSubdomains: true))
        #expect(StrictTransport.parse("max-age=99999999999999999999999")?.maxAge == 2 * 365 * 24 * 60 * 60)
        for bad in ["", "includeSubDomains", "max-age=", "max-age=-1", "max-age=1e9", "max-age=10; max-age=20", "max-age=+5"] {
            #expect(StrictTransport.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func knowsHSTSHosts() {
        let store = WKWebsiteDataStore.nonPersistent()
        // Whole top-level domains are HSTS in every browser.
        #expect(StrictTransport.isKnown("my.app", in: store))
        #expect(StrictTransport.isKnown("deep.sub.example.dev", in: nil))
        #expect(!StrictTransport.isKnown("router.local", in: store))
        #expect(!StrictTransport.isKnown("192.168.1.1", in: store))
        StrictTransport.note("example.com", policy: .init(maxAge: 600, includesSubdomains: false), in: store)
        #expect(StrictTransport.isKnown("EXAMPLE.com", in: store))
        #expect(!StrictTransport.isKnown("www.example.com", in: store))
        StrictTransport.note("example.org", policy: .init(maxAge: 600, includesSubdomains: true), in: store)
        #expect(StrictTransport.isKnown("a.b.example.org", in: store))
        #expect(!StrictTransport.isKnown("example.org", in: WKWebsiteDataStore.nonPersistent()))
        #expect(!StrictTransport.isKnown("example.org", in: store, now: Date(timeIntervalSinceNow: 601)))
        // max-age=0 takes it back.
        StrictTransport.note("example.com", policy: .init(maxAge: 0, includesSubdomains: false), in: store)
        #expect(!StrictTransport.isKnown("example.com", in: store))
    }

    @Test func strictTransportComesOnlyOverATrustedConnection() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        func response(_ url: String) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: "HTTP/1.1",
                                         headerFields: ["Strict-Transport-Security": "max-age=600"]))
        }
        StrictTransport.note(try response("http://plain.example/"), in: store)
        #expect(!StrictTransport.isKnown("plain.example", in: store))
        // Sent over a certificate let through on the warning: ignored, as RFC 6797 says.
        CertificateExceptions.allow("let-through.example", certificate: Data([1]), in: store)
        StrictTransport.note(try response("https://let-through.example/"), in: store)
        #expect(!StrictTransport.isKnown("let-through.example", in: store))
        StrictTransport.note(try response("https://secure.example/"), in: store)
        #expect(StrictTransport.isKnown("secure.example", in: store))
    }

    @Test func siteControlsSayALetThroughCertificateIsNotSecure() {
        let excepted = SitePanel.connection(scheme: "https", onlySecureContent: true, certificateException: true)
        #expect(excepted.value == SitePanel.notSecure && excepted.warns && excepted.reason != nil)
        let secure = SitePanel.connection(scheme: "https", onlySecureContent: true, certificateException: false)
        #expect(secure.value != SitePanel.notSecure && !secure.warns && secure.reason == nil)
        #expect(secure.value == "Secure connection")
        #expect(SitePanel.connection(scheme: "https", onlySecureContent: false, certificateException: false).warns)
        // Zigzag's own warning page in place of the site: no certificate, never secure.
        let warning = SitePanel.connection(scheme: "https", onlySecureContent: true, certificateException: false, hasCertificate: false)
        #expect(warning.value == SitePanel.notSecure && warning.warns)
        let plain = SitePanel.connection(scheme: "http", onlySecureContent: false, certificateException: false)
        #expect(plain.value == SitePanel.notSecure && plain.reason == nil)
    }
}
