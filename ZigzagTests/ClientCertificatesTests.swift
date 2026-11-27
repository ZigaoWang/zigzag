import Foundation
import Security
import Testing
import WebKit
@testable import Zigzag

/// Client certificates (#297): offered identities, kept choices, nothing kept in private windows. Uses a temp keychain.
@MainActor @Suite(.serialized)
struct ClientCertificatesTests {
    private func info(_ name: String, sha: String, from: Date? = nil, until: Date? = nil) -> ClientCertificates.Info {
        ClientCertificates.Info(name: name, issuer: "Test CA", validFrom: from, validUntil: until, sha256: sha)
    }

    @Test func decidesFromSessionThenKeptChoice() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = info("A", sha: "AA"), b = info("B", sha: "BB")
        #expect(ClientCertificates.decide(candidates: [], session: nil, kept: "AA", now: now) == .noMatch)
        #expect(ClientCertificates.decide(candidates: [a, b], session: nil, kept: nil, now: now) == .ask)
        #expect(ClientCertificates.decide(candidates: [a, b], session: nil, kept: "BB", now: now) == .use(1))
        // A kept identity that's gone or expired: ask again.
        #expect(ClientCertificates.decide(candidates: [a], session: nil, kept: "BB", now: now) == .ask)
        #expect(ClientCertificates.decide(candidates: [a, b], session: .identity(sha256: "AA"), kept: "BB", now: now) == .use(0))
        #expect(ClientCertificates.decide(candidates: [b], session: .identity(sha256: "AA"), kept: nil, now: now) == .ask)
        // Cancel holds briefly, then the site may ask again.
        #expect(ClientCertificates.decide(candidates: [a], session: .declined(until: now.addingTimeInterval(5)), kept: "AA", now: now) == .declined)
        #expect(ClientCertificates.decide(candidates: [a], session: .declined(until: now.addingTimeInterval(-5)), kept: "AA", now: now) == .use(0))
    }

    @Test func onlyCertificatesValidNowAreOffered() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClientCertificates.isValid(info("A", sha: "1", from: now.addingTimeInterval(-10), until: now.addingTimeInterval(10)), at: now))
        #expect(!ClientCertificates.isValid(info("A", sha: "1", until: now.addingTimeInterval(-1)), at: now))
        #expect(!ClientCertificates.isValid(info("A", sha: "1", from: now.addingTimeInterval(1)), at: now))
        #expect(ClientCertificates.isValid(info("A", sha: "1"), at: now))
    }

    @Test func aDroppedConnectionRightAfterAskingIsARefusal() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lost = NSURLErrorNetworkConnectionLost, failed = NSURLErrorSecureConnectionFailed
        #expect(ClientCertificates.isRefusal(code: lost, askedAt: now.addingTimeInterval(-2), now: now))
        #expect(ClientCertificates.isRefusal(code: failed, askedAt: now.addingTimeInterval(-2), now: now))
        #expect(!ClientCertificates.isRefusal(code: lost, askedAt: nil, now: now))
        #expect(!ClientCertificates.isRefusal(code: lost, askedAt: now.addingTimeInterval(-ClientCertificates.refusalWindow - 1), now: now))
        #expect(!ClientCertificates.isRefusal(code: NSURLErrorTimedOut, askedAt: now, now: now))
        let error = NSError(domain: NSURLErrorDomain, code: lost)
        let store = WKWebsiteDataStore.nonPersistent()
        #expect(ClientCertificates.explain(error, url: URL(string: "https://never-asked.example/"), store: store).code == lost)
    }

    @Test func queryNamesTheIssuersTheSiteAsksFor() {
        let dn = Data([0x30, 0x00])
        #expect(ClientCertificates.query(issuers: [dn])[kSecMatchIssuers] as? [Data] == [dn])
        #expect(ClientCertificates.query(issuers: [])[kSecMatchIssuers] == nil)
        #expect(ClientCertificates.query(issuers: nil)[kSecMatchIssuers] == nil)
        #expect(ClientCertificates.query(issuers: nil)[kSecClass] as? String == kSecClassIdentity as String)
    }

    /// Temp keychain: one identity from CA A, one from CA B, one expired from CA A.
    @Test func findsIdentitiesIssuedByWhomTheSiteNames() throws {
        let path = NSTemporaryDirectory() + "zigzag-client-certificates-\(UUID().uuidString).keychain-db"
        var keychain: SecKeychain?
        let password = "zigzag-test"
        try #require(SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain) == errSecSuccess)
        let made = try #require(keychain)
        defer {
            SecKeychainDelete(made)
            try? FileManager.default.removeItem(atPath: path)
        }
        for p12 in [Self.clientA, Self.clientB, Self.clientExpired] {
            let data = try #require(Data(base64Encoded: p12, options: .ignoreUnknownCharacters))
            var items: CFArray?
            let options: [CFString: Any] = [kSecImportExportPassphrase: "test", kSecImportExportKeychain: made]
            try #require(SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess)
        }
        let caA = try #require(Data(base64Encoded: Self.caA)), caB = try #require(Data(base64Encoded: Self.caB))
        let names = { (issuers: [Data]?) in ClientCertificates.find(issuers: issuers, searchList: [made]).map(\.info.name) }
        #expect(names([caA]) == ["Test Client A"])
        #expect(names([caB]) == ["Test Client B"])
        #expect(names([caA, caB]) == ["Test Client A", "Test Client B"])
        // No issuers named: every valid identity is offered.
        #expect(names(nil) == ["Test Client A", "Test Client B"])
        #expect(names([]) == ["Test Client A", "Test Client B"])
        #expect(names([Data([0x30, 0x00])]).isEmpty)
        let found = try #require(ClientCertificates.find(issuers: [caA], searchList: [made]).first)
        #expect(found.info.issuer == "Zigzag Test CA A")
        #expect(found.info.sha256.count == 95)
        let credential = ClientCertificates.credential(for: found)
        #expect(credential.identity != nil)
        #expect(credential.persistence == .forSession)
    }

    private func withDefaults(_ body: () throws -> Void) rethrows {
        let suite = "ClientCertificatesTests-\(UUID().uuidString)"
        let before = ClientCertificates.defaults
        ClientCertificates.defaults = UserDefaults(suiteName: suite)!
        defer {
            ClientCertificates.defaults.removeScratchSuite(suite)
            ClientCertificates.defaults = before
        }
        try body()
    }

    @Test func alwaysKeepsTheChoiceForTheHost() {
        withDefaults {
            let store = WKWebsiteDataStore.default()
            let a = info("Work ID", sha: "AA")
            ClientCertificates.noteChosen(a, host: "Login.Example.com", store: store, always: true)
            #expect(ClientCertificates.kept(host: "login.example.com") == .init(sha256: "AA", name: "Work ID"))
            #expect(ClientCertificates.sites == ["login.example.com"])
            #expect(ClientCertificates.sessionAnswer(host: "login.example.com", store: store) == .identity(sha256: "AA"))
            ClientCertificates.forget(site: "login.example.com")
            ClientCertificates.forgetSessions(site: "login.example.com")
            #expect(ClientCertificates.kept(host: "login.example.com") == nil)
            #expect(ClientCertificates.sessionAnswer(host: "login.example.com", store: store) == nil)
            // Without "always" it's session only.
            ClientCertificates.noteChosen(a, host: "intranet.example", store: store, always: false)
            #expect(ClientCertificates.kept(host: "intranet.example") == nil)
            #expect(ClientCertificates.sessionAnswer(host: "intranet.example", store: store) == .identity(sha256: "AA"))
            ClientCertificates.forgetSessions(site: "intranet.example")
        }
    }

    @Test func privateWindowsNeverKeepAChoice() {
        withDefaults {
            let privateStore = WKWebsiteDataStore.nonPersistent()
            let other = WKWebsiteDataStore.nonPersistent()
            ClientCertificates.noteChosen(info("Work ID", sha: "AA"), host: "login.example.com", store: privateStore, always: true)
            #expect(ClientCertificates.kept(host: "login.example.com") == nil)
            #expect(ClientCertificates.sites.isEmpty)
            #expect(ClientCertificates.defaults.dictionaryRepresentation()["ClientCertificateChoices"] == nil)
            // Per session: another window doesn't have it.
            #expect(ClientCertificates.sessionAnswer(host: "login.example.com", store: privateStore) == .identity(sha256: "AA"))
            #expect(ClientCertificates.sessionAnswer(host: "login.example.com", store: other) == nil)
            ClientCertificates.noteDeclined(host: "other.example", store: privateStore, now: Date(timeIntervalSince1970: 0))
            #expect(ClientCertificates.sessionAnswer(host: "other.example", store: privateStore) == .declined(until: Date(timeIntervalSince1970: ClientCertificates.declineHolds)))
        }
    }

    // Made with openssl: CA A and B subject names (DER) and three .p12 identities, password "test"; one expired in 2021, others valid to 2120.
    private static let caA = "MDExFDASBgNVBAoMC1ppZ3phZyBUZXN0MRkwFwYDVQQDDBBaaWd6YWcgVGVzdCBDQSBB"
    private static let caB = "MDExFDASBgNVBAoMC1ppZ3phZyBUZXN0MRkwFwYDVQQDDBBaaWd6YWcgVGVzdCBDQSBC"
    private static let clientA = """
        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
        """
    private static let clientB = """
        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
        """
    private static let clientExpired = """
        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
        XLE6BBA0VCuDQd0cgs6HSXhxQBhXAgIIAA==
        """
}
