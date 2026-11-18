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

    /// `StrictTransport.listed` does a byte search: the list must be byte-sorted, one per line, no CR (see .gitattributes).
    @Test func thePreloadListIsSortedByteByByte() throws {
        let url = try #require(Bundle.main.url(forResource: "hsts_preload", withExtension: "txt"))
        let data = try Data(contentsOf: url)
        #expect(!data.contains(0x0D))
        #expect(data.last == 0x0A)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        #expect(lines.count > 1_000)
        #expect(!lines.contains { $0.isEmpty })
        let unsorted = zip(lines, lines.dropFirst()).first { !$0.lexicographicallyPrecedes($1) }
        #expect(unsorted == nil, "\(unsorted.map { String(decoding: $0.0, as: UTF8.self) + " ≥ " + String(decoding: $0.1, as: UTF8.self) } ?? "")")
    }

    @Test func knowsThePreloadList() {
        #expect(StrictTransport.isPreloadLoaded)
        // Every line is found, nothing in between.
        let list = Data("=alone.example\nb.example\ncovers.example\nz.example\n".utf8)
        for line in ["=alone.example", "b.example", "covers.example", "z.example"] { #expect(StrictTransport.listed(line, in: list)) }
        for line in ["a.example", "alone.example", "c.example", "covers.exampl", "covers.examplex", "zz.example", "=b.example", ""] {
            #expect(!StrictTransport.listed(line, in: list))
        }
        #expect(StrictTransport.isPreloaded("www.google.com") || StrictTransport.isPreloaded("accounts.google.com"))
        #expect(!StrictTransport.isPreloaded("not-a-real-site-zigzag.example"))
        // One name includes subdomains, one doesn't.
        #expect(StrictTransport.isKnown("github.com", in: nil))
        #expect(StrictTransport.isKnown("gist.github.com", in: nil))
        #expect(StrictTransport.isKnown("paypal.com", in: nil))
        #expect(StrictTransport.isKnown("PayPal.com.", in: nil))
        #expect(!StrictTransport.isKnown("not-on-the-list.paypal.com", in: nil))
        #expect(!StrictTransport.isKnown("zigzag-not-preloaded.example", in: nil))
        #expect(!StrictTransport.isKnown("github.com.evil.example", in: nil))
    }

    @Test func aProfileKeepsItsHSTSHostsAcrossLaunches() throws {
        let store = WKWebsiteDataStore.default()
        StrictTransport.forget(in: store)
        StrictTransport.note("kept.example", policy: .init(maxAge: 600, includesSubdomains: true), in: store)
        StrictTransport.note("gone.example", policy: .init(maxAge: 600, includesSubdomains: false), in: store, now: Date(timeIntervalSinceNow: -700))
        StrictTransport.settle()
        // Reloaded as on next launch.
        StrictTransport.reload()
        #expect(StrictTransport.isKnown("www.kept.example", in: store))
        #expect(!StrictTransport.isKnown("gone.example", in: store))
        // Private windows never write.
        let privateStore = WKWebsiteDataStore.nonPersistent()
        StrictTransport.note("private.example", policy: .init(maxAge: 600, includesSubdomains: false), in: privateStore)
        StrictTransport.settle()
        #expect(StrictTransport.isKnown("private.example", in: privateStore))
        #expect(!StrictTransport.isKnown("private.example", in: store))
        // Clearing site data removes it on disk too.
        WebsiteData.forgetConnections(in: store, site: "kept.example")
        StrictTransport.settle()
        StrictTransport.reload()
        #expect(!StrictTransport.isKnown("kept.example", in: store))
        let file = try #require(StrictTransport.file("default"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Many HSTS headers on one page coalesce into one delayed write.
    @Test func manyHSTSHeadersMakeOneWrite() throws {
        let store = WKWebsiteDataStore.default()
        StrictTransport.forget(in: store)
        StrictTransport.settle()
        let file = try #require(StrictTransport.file("default"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        for index in 0..<20 {
            StrictTransport.note("frame\(index).example", policy: .init(maxAge: 600, includesSubdomains: false), in: store)
        }
        // Known immediately, written after the delay (or on quit).
        #expect(StrictTransport.isKnown("frame7.example", in: store))
        StrictTransport.disk.sync {}
        #expect(!FileManager.default.fileExists(atPath: file.path))
        StrictTransport.settle()
        #expect(FileManager.default.fileExists(atPath: file.path))
        StrictTransport.reload()
        #expect(StrictTransport.isKnown("frame19.example", in: store))
        StrictTransport.forget(in: store)
        StrictTransport.settle()
    }

    @Test func clearingSiteDataForgetsExceptions() {
        let store = WKWebsiteDataStore.nonPersistent()
        CertificateExceptions.allow("nas.example.com", certificate: Data([1]), in: store)
        CertificateExceptions.allow("router.local", certificate: Data([2]), in: store)
        StrictTransport.note("example.com", policy: .init(maxAge: 600, includesSubdomains: false), in: store)
        WebsiteData.forgetConnections(in: store, site: "example.com")
        #expect(!CertificateExceptions.hasException(for: "nas.example.com", in: store))
        #expect(CertificateExceptions.hasException(for: "router.local", in: store))
        #expect(!StrictTransport.isKnown("example.com", in: store))
        WebsiteData.forgetConnections(in: store)
        #expect(!CertificateExceptions.hasException(for: "router.local", in: store))
    }

    @Test func aPageOnAnExceptionStaysNotSecureWhenItRunsOut() {
        let store = WKWebsiteDataStore.nonPersistent()
        let leaf = Data([5, 5, 5])
        CertificateExceptions.allow("nas.local", certificate: leaf, in: store, now: Date(timeIntervalSinceNow: -CertificateExceptions.lifetime - 1))
        // New loads are refused, but an already loaded page stays marked.
        #expect(!CertificateExceptions.allows("nas.local", leaf: leaf, in: store))
        #expect(CertificateExceptions.wasTrusted("NAS.local", leaf: leaf, in: store))
        #expect(!CertificateExceptions.wasTrusted("nas.local", leaf: Data([6]), in: store))
        CertificateExceptions.forget(in: store)
        #expect(!CertificateExceptions.wasTrusted("nas.local", leaf: leaf, in: store))
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

/// Certificate warning reasons: WebKit uses one code for most failures, so the certificate is inspected.
@MainActor
struct CertificateProblemTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    private func facts(names: [String] = ["example.com"], from: TimeInterval = -30, until: TimeInterval = 30, selfSigned: Bool = false,
                       trusted: Bool? = true) -> ErrorPage.CertificateFacts {
        ErrorPage.CertificateFacts(validFrom: Self.now.addingTimeInterval(from * Self.day), validUntil: Self.now.addingTimeInterval(until * Self.day),
                                   names: names, selfSigned: selfSigned, issuerTrusted: trusted)
    }

    private func problem(_ facts: ErrorPage.CertificateFacts, host: String = "example.com") -> ErrorPage.CertificateProblem {
        ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: facts, host: host, now: Self.now)
    }

    @Test func eachProblemIsToldApart() {
        // expired.badssl.com.
        #expect(problem(facts(until: -2)) == .expired(Self.now.addingTimeInterval(-2 * Self.day)))
        #expect(problem(facts(from: 3)) == .notYetValid(Self.now.addingTimeInterval(3 * Self.day)))
        // wrong.host.badssl.com: *.badssl.com covers one label only.
        #expect(problem(facts(names: ["*.badssl.com", "badssl.com"]), host: "wrong.host.badssl.com") == .wrongHost("*.badssl.com"))
        // self-signed.badssl.com and untrusted-root.badssl.com.
        #expect(problem(facts(selfSigned: true, trusted: false)) == .selfSigned)
        #expect(problem(facts(trusted: false)) == .untrustedIssuer)
        // Nothing specific found: unknown.
        #expect(problem(facts()) == .unknown)
        // Wrong host takes precedence over dates.
        #expect(problem(facts(names: ["other.example"], until: -2)) == .wrongHost("other.example"))
    }

    @Test func withoutTheCertificateTheCodeDecides() {
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateHasBadDate, facts: nil, host: "a.example") == .expired(nil))
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateNotYetValid, facts: nil, host: "a.example") == .notYetValid(nil))
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateHasUnknownRoot, facts: nil, host: "a.example") == .untrustedIssuer)
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: nil, host: "a.example") == .unknown)
        // Unknown reason doesn't blame the address.
        #expect(!ErrorPage.certificateReason(.unknown).contains("different address"))
    }

    @Test func namesCoverTheirHosts() {
        #expect(ErrorPage.certificateNames(["Example.COM."], cover: "example.com"))
        #expect(ErrorPage.certificateNames(["*.badssl.com"], cover: "expired.badssl.com"))
        #expect(!ErrorPage.certificateNames(["*.badssl.com"], cover: "wrong.host.badssl.com"))
        #expect(!ErrorPage.certificateNames(["*.badssl.com"], cover: "badssl.com"))
        #expect(!ErrorPage.certificateNames(["*.com"], cover: "example.com"))
        #expect(!ErrorPage.certificateNames(["example.com"], cover: "example.com.evil.example"))
    }

    /// Test self-signed certificate for router.example and *.router.example, valid until 2126.
    static let routerCertificate = "MIIBuDCCAV2gAwIBAgIUPrec49i1x+2YGiJypUG4pmJW6OUwCgYIKoZIzj0EAwIwGTEXMBUGA1UEAwwOcm91dGVyLmV4YW1wbGUwIBcNMjYxMTE0MTgwNjI1WhgPMjEyNjEwMjExODA2MjVaMBkxFzAVBgNVBAMMDnJvdXRlci5leGFtcGxlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEbLEEz9qdxFzCf3pJ12sWRzP0f6v/2u/QcNU/eCRJtIDXgxFUEOtNBGf/rknU5mquto4fXMbceSynCsa00DO+4aOBgDB+MB0GA1UdDgQWBBQy4SrtvuTIzFlDDFyArbn0IOG4YzAfBgNVHSMEGDAWgBQy4SrtvuTIzFlDDFyArbn0IOG4YzAPBgNVHRMBAf8EBTADAQH/MCsGA1UdEQQkMCKCDnJvdXRlci5leGFtcGxlghAqLnJvdXRlci5leGFtcGxlMAoGCCqGSM49BAMCA0kAMEYCIQC21V1N7QvFT70kTfiFqnn6wl6HyMbVA7Cl0EsACf0hkwIhALMb256boj0ZFZmSloeA+TuyWQ0++J3FPoA+VdB9ApAV"

    @Test func aCertificateIsRead() throws {
        let data = try #require(Data(base64Encoded: Self.routerCertificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        #expect(CertificateDetails.dnsNames(of: certificate) == ["router.example", "*.router.example"])
        let facts = try #require(ErrorPage.certificateFacts(of: [certificate]))
        #expect(facts.selfSigned && facts.issuerTrusted == false)
        #expect(facts.names == ["router.example", "*.router.example"])
        let until = try #require(facts.validUntil)
        #expect(Calendar(identifier: .gregorian).component(.year, from: until) == 2126)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: facts, host: "nas.router.example", now: now) == .selfSigned)
        // Self-signed is reported for any host, since anyone can name any host.
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: facts, host: "192.168.1.1", now: now) == .selfSigned)
        var signed = facts
        signed.selfSigned = false
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: signed, host: "192.168.1.1", now: now) == .wrongHost("router.example"))
        // The SecTrust from WebKit's error gives the same result.
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "router.example" as CFString), &trust)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                            userInfo: [NSURLErrorFailingURLPeerTrustErrorKey: try #require(trust)])
        #expect(ErrorPage.certificateFacts(of: error) == facts)
        let page = ErrorPage.html(error: error, url: URL(string: "https://router.example/")!, canGoBack: false, proceedLink: nil, style: "", nonce: "n")
        #expect(page.contains(ErrorPage.escape(ErrorPage.certificateReason(.selfSigned))))
    }

    /// Test self-signed certificate for router.local with IP SANs 192.168.1.1 and fd00::1, valid until 2126.
    static let addressedCertificate = "MIIBpzCCAU6gAwIBAgIUGeZA8ikvkexD6f+4Ht6cLd0Eow0wCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwMcm91dGVyLmxvY2FsMCAXDTI2MTExNDIyMTMxOFoYDzIxMjYxMDIxMjIxMzE4WjAXMRUwEwYDVQQDDAxyb3V0ZXIubG9jYWwwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT+FYMBW6/UJfAkaG24/biEBCwlQGdAxhRtg+0df3M/7XxCBgX7aIZ2ODhEjLW5B4nWg0aIUh2/TuIVCOdseZPHo3YwdDAdBgNVHQ4EFgQUKUS89MkUDX2t7B4ef8rdsp1Y8EswHwYDVR0jBBgwFoAUKUS89MkUDX2t7B4ef8rdsp1Y8EswDwYDVR0TAQH/BAUwAwEB/zAhBgNVHREEGjAYhwTAqAEBhxD9AAAAAAAAAAAAAAAAAAABMAoGCCqGSM49BAMCA0cAMEQCIGD6cgWlWoalnZcswYRxrl0p7qFjOWP8LVWC7iolInWYAiADzodBoweOui0Cz50lgk/QBFydDBGn8PoXaJCJR6O9Cw=="

    /// An IP SAN covers that address.
    @Test func aCertificateForAnAddressCoversIt() throws {
        let data = try #require(Data(base64Encoded: Self.addressedCertificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        #expect(CertificateDetails.ipAddresses(of: certificate).count == 2)
        let facts = try #require(ErrorPage.certificateFacts(of: [certificate], checkingIssuer: false))
        #expect(facts.names == ["router.local"])
        #expect(facts.issuerTrusted == nil)
        #expect(ErrorPage.certificate(facts, covers: "192.168.1.1"))
        #expect(ErrorPage.certificate(facts, covers: "[fd00::1]"))
        #expect(ErrorPage.certificate(facts, covers: "router.local"))
        #expect(!ErrorPage.certificate(facts, covers: "192.168.1.2"))
        #expect(!ErrorPage.certificate(facts, covers: "nas.local"))
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: facts, host: "192.168.1.1", now: now) == .selfSigned)
        // Not self-signed: the named address decides.
        var signed = facts
        signed.selfSigned = false
        signed.issuerTrusted = false
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: signed, host: "192.168.1.1", now: now) == .untrustedIssuer)
        #expect(ErrorPage.certificateProblem(code: NSURLErrorServerCertificateUntrusted, facts: signed, host: "192.168.1.2", now: now) == .wrongHost("router.local"))
        // Issuer trust, checked separately off the main thread.
        #expect(ErrorPage.issuerTrusted([certificate], validFrom: facts.validFrom, validUntil: facts.validUntil) == false)
    }

    /// The error page renders before the issuer check and updates after.
    @Test func theWarningDoesntWaitOnTheIssuer() throws {
        let data = try #require(Data(base64Encoded: Self.routerCertificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        let facts = try #require(ErrorPage.certificateFacts(of: [certificate], checkingIssuer: false))
        #expect(facts.issuerTrusted == nil && facts.selfSigned)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                            userInfo: ["NSErrorPeerCertificateChainKey": [certificate]])
        let page = ErrorPage.html(error: error, url: URL(string: "https://router.example/")!, canGoBack: false, proceedLink: nil, style: "", nonce: "n0")
        #expect(page.contains(#"<p class="why" id="why" data-page="n0">"#))
    }

    @Test func aFingerprintBreaksAfterItsColons() {
        let fingerprint = (0..<32).map { String(format: "%02X", $0 * 7 % 256) }.joined(separator: ":")
        let lines = CertificateDetails.fingerprintLines(fingerprint, perLine: 8).components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { !$0.hasPrefix(":") })
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(":") && $0.split(separator: ":").count == 8 })
        #expect(lines.joined() == fingerprint)
        #expect(CertificateDetails.fingerprintLines(fingerprint, perLine: 32) == fingerprint)
        #expect(CertificateDetails.fingerprintLines(fingerprint, perLine: 16).components(separatedBy: "\n").count == 2)
    }
}
