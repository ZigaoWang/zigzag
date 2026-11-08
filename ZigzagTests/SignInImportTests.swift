import Foundation
import Testing
import SQLite3
@testable import Zigzag

/// Bringing over the sites you're signed in to. The encrypted values were made outside Zigzag (Python's PBKDF2 and
/// openssl) with a made-up Safe Storage secret, so these check Chromium's real scheme; nothing here reads the
/// Keychain or a real browser.
struct SignInImportTests {
    static let secret = Data("fake-safe-storage".utf8)
    static var key: Data { ChromiumImporter.deriveKey(secret) }
    /// SHA-256(".example.org") + "session-value-42", as cookie database version 24 and later store it.
    static let hashed = "02425421c0286fd9b19438bfc9f97f6d0264a34db753d5c8ad3584e419892588c58e09c70bcaac22242a91332eb8079980d9dcf51948a499a7a5de7ec6568da3"
    /// "plain-old-value", as versions before 24 store it.
    static let unhashed = "fd7028d758d7d4af167290738fe23978"
    static let now = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    /// 2030-01-01 in microseconds since 1601.
    static let in2030: Int64 = 13_537_929_600_000_000

    static func v10(_ hex: String) -> Data { Data("v10".utf8) + bytes(hex) }

    func cookie(_ outcome: SignInImporter.Outcome) -> SignInImporter.Cookie? {
        if case .cookie(let cookie) = outcome { cookie } else { nil }
    }

    func isUnreadable(_ outcome: SignInImporter.Outcome) -> Bool { if case .unreadable = outcome { true } else { false } }
    func isSkipped(_ outcome: SignInImporter.Outcome) -> Bool { if case .skipped = outcome { true } else { false } }

    @Test func derivesTheKey() {
        #expect(Self.key.map { String(format: "%02x", $0) }.joined() == "ef617c22cf2b29075bf1cbcb83a900c5")
    }

    @Test func decryptsAndStripsTheHostHash() throws {
        let row = SignInImporter.ChromiumRow(host: ".example.org", name: "sid", encrypted: Self.v10(Self.hashed), expiresUTC: Self.in2030)
        let read = try #require(cookie(SignInImporter.chromiumCookie(row, key: Self.key, version: 24, now: Self.now)))
        #expect(read.value == "session-value-42")
        #expect(read.expires == ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
    }

    /// The hash is only there from version 24: before it the whole value is the cookie, and from it a value
    /// without the right hash (another host's, or none) doesn't come over.
    @Test func hashPrefixFollowsTheDatabaseVersion() throws {
        var row = SignInImporter.ChromiumRow(host: ".example.org", name: "sid", encrypted: Self.v10(Self.unhashed), expiresUTC: Self.in2030)
        #expect(cookie(SignInImporter.chromiumCookie(row, key: Self.key, version: 23, now: Self.now))?.value == "plain-old-value")
        #expect(isUnreadable(SignInImporter.chromiumCookie(row, key: Self.key, version: 24, now: Self.now)))
        row.encrypted = Self.v10(Self.hashed)
        // Read as an old database, the hash's bytes would be part of the value: not text, so not brought over.
        #expect(isUnreadable(SignInImporter.chromiumCookie(row, key: Self.key, version: 23, now: Self.now)))
        row.host = ".example.com"
        #expect(isUnreadable(SignInImporter.chromiumCookie(row, key: Self.key, version: 24, now: Self.now)))
        #expect(SignInImporter.stripDomainHash(Data("short".utf8), host: "a.b", version: 24) == nil)
    }

    @Test func theWrongKeyOrNoKeyIsUnreadable() {
        let row = SignInImporter.ChromiumRow(host: ".example.org", name: "sid", encrypted: Self.v10(Self.hashed), expiresUTC: Self.in2030)
        #expect(isUnreadable(SignInImporter.chromiumCookie(row, key: ChromiumImporter.deriveKey(Data("wrong".utf8)), version: 24, now: Self.now)))
        #expect(isUnreadable(SignInImporter.chromiumCookie(row, key: nil, version: 24, now: Self.now)))
        // An old unencrypted value needs no key.
        let clear = SignInImporter.ChromiumRow(host: "example.org", name: "pref", value: "dark", expiresUTC: Self.in2030)
        #expect(cookie(SignInImporter.chromiumCookie(clear, key: nil, version: 24, now: Self.now))?.value == "dark")
    }

    @Test func skipsExpiredAndPartitionedButKeepsSessionCookies() throws {
        let expired = SignInImporter.ChromiumRow(host: "example.org", name: "old", value: "x", expiresUTC: 13_411_699_200_000_000)
        #expect(isSkipped(SignInImporter.chromiumCookie(expired, key: nil, version: 24, now: Self.now)))
        let partitioned = SignInImporter.ChromiumRow(host: "embed.example", name: "p", value: "x", expiresUTC: Self.in2030, topFrameSiteKey: "https://example.org")
        #expect(isSkipped(SignInImporter.chromiumCookie(partitioned, key: nil, version: 24, now: Self.now)))
        let session = SignInImporter.ChromiumRow(host: "example.org", name: "s", value: "x", expiresUTC: 0, persistent: false)
        let read = try #require(cookie(SignInImporter.chromiumCookie(session, key: nil, version: 24, now: Self.now)))
        #expect(read.expires == nil)
        #expect(read.httpCookie?.isSessionOnly == true)
    }

    @Test func mapsToHTTPCookie() throws {
        // A month from now in Chromium time: Foundation caps any cookie at 400 days, as browsers do.
        let soon = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 30 * 86_400).rounded())
        let micros = Int64((soon.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let row = SignInImporter.ChromiumRow(host: ".example.org", name: "sid", value: "v", path: "/app", expiresUTC: micros,
                                             secure: true, httpOnly: true, sameSite: 1)
        let domain = try #require(cookie(SignInImporter.chromiumCookie(row, key: nil, version: 24, now: Date()))?.httpCookie)
        #expect(domain.domain == ".example.org")
        #expect(domain.path == "/app")
        #expect(domain.isSecure)
        #expect(domain.isHTTPOnly)
        #expect(domain.sameSitePolicy == .sameSiteLax)
        #expect(abs(domain.expiresDate?.timeIntervalSince(soon) ?? 99) < 1)
        #expect(domain.isSessionOnly == false)

        let host = SignInImporter.ChromiumRow(host: "www.example.org", name: "pref", value: "v", path: "", expiresUTC: Self.in2030, sameSite: 2)
        let hostOnly = try #require(cookie(SignInImporter.chromiumCookie(host, key: nil, version: 24, now: Self.now))?.httpCookie)
        // No leading dot: that host alone, as the source kept it.
        #expect(hostOnly.domain == "www.example.org")
        #expect(hostOnly.path == "/")
        #expect(!hostOnly.isSecure)
        #expect(!hostOnly.isHTTPOnly)
        #expect(hostOnly.sameSitePolicy == .sameSiteStrict)

        for none in [Int64(0), -1] {
            let open = SignInImporter.ChromiumRow(host: "example.org", name: "n", value: "v", expiresUTC: Self.in2030, secure: true, sameSite: none)
            #expect(cookie(SignInImporter.chromiumCookie(open, key: nil, version: 24, now: Self.now))?.httpCookie?.sameSitePolicy == nil)
        }
    }

    @Test func neverPrintsTheValue() throws {
        let row = SignInImporter.ChromiumRow(host: ".example.org", name: "sid", value: "very-secret-token", expiresUTC: Self.in2030)
        let read = try #require(cookie(SignInImporter.chromiumCookie(row, key: nil, version: 24, now: Self.now)))
        #expect(!"\(read)".contains("very-secret-token"))
        #expect(!String(reflecting: read).contains("very-secret-token"))
        var dumped = ""
        dump(read, to: &dumped)
        #expect(!dumped.contains("very-secret-token"))
    }

    @Test func countsSitesNotSubdomains() {
        func site(_ domain: String) -> String {
            SignInImporter.Cookie(domain: domain, name: "a", value: "", path: "/", expires: nil, secure: false, httpOnly: false, sameSite: .unset).site
        }
        #expect(site(".mail.google.com") == "google.com")
        #expect(site("news.bbc.co.uk") == "bbc.co.uk")
        #expect(site("127.0.0.1") == "127.0.0.1")
    }

    // MARK: Firefox

    @Test func readsFirefoxRows() throws {
        // Seconds, and milliseconds as newer Firefox stores them: both 2030-01-01.
        for expiry in [Int64(1_893_456_000), 1_893_456_000_000] {
            let row = SignInImporter.FirefoxRow(host: ".example.org", name: "sid", value: "v", expiry: expiry, secure: true, httpOnly: true, sameSite: 2)
            let read = try #require(cookie(SignInImporter.firefoxCookie(row, now: Self.now)))
            #expect(read.expires == ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
            #expect(read.sameSite == .strict)
            #expect(read.httpCookie?.isHTTPOnly == true)
        }
        let expired = SignInImporter.FirefoxRow(host: "example.org", name: "a", expiry: 1_700_000_000)
        #expect(isSkipped(SignInImporter.firefoxCookie(expired, now: Self.now)))
        let container = SignInImporter.FirefoxRow(host: "example.org", name: "a", expiry: 1_893_456_000, originAttributes: "^userContextId=1")
        #expect(isSkipped(SignInImporter.firefoxCookie(container, now: Self.now)))
        let partitioned = SignInImporter.FirefoxRow(host: "example.org", name: "a", expiry: 1_893_456_000, partitioned: true)
        #expect(isSkipped(SignInImporter.firefoxCookie(partitioned, now: Self.now)))
    }

    // MARK: Files

    @Test func readsAChromiumCookieFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Cookies")
        try Self.sqlite(file, """
        CREATE TABLE meta (key TEXT, value TEXT);
        INSERT INTO meta VALUES ('version', '24');
        CREATE TABLE cookies (creation_utc INTEGER, host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
            path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, last_access_utc INTEGER, has_expires INTEGER,
            is_persistent INTEGER, priority INTEGER, samesite INTEGER, source_scheme INTEGER, source_port INTEGER);
        INSERT INTO cookies VALUES (0, '.example.org', '', 'sid', '', X'763130\(Self.hashed)', '/', \(Self.in2030), 1, 1, 0, 1, 1, 1, 1, 2, 443);
        INSERT INTO cookies VALUES (0, '.example.org', '', 'bad', '', X'763130\(String(repeating: "ab", count: 48))', '/', \(Self.in2030), 1, 1, 0, 1, 1, 1, 1, 2, 443);
        INSERT INTO cookies VALUES (0, 'example.org', '', 'old', 'x', X'', '/', 13411699200000000, 0, 0, 0, 1, 1, 1, -1, 2, 443);
        INSERT INTO cookies VALUES (0, 'embed.example', 'https://example.org', 'chips', 'x', X'', '/', \(Self.in2030), 1, 0, 0, 1, 1, 1, 0, 2, 443);
        INSERT INTO cookies VALUES (0, 'example.org', '', 'tab', 'x', X'', '/', 0, 0, 0, 0, 0, 0, 1, -1, 2, 443);
        """)
        let read = SignInImporter.chromium(at: file, key: Self.key, now: Self.now)
        #expect(read.cookies.map(\.name) == ["sid", "tab"])
        #expect(read.cookies.first?.value == "session-value-42")
        #expect(read.unreadable == 1)
        // The private copy it read from is gone.
        let left = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
        #expect(!left.contains { $0.lastPathComponent.hasPrefix("zigzag-import-") && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Cookies").path) })
    }

    @Test func findsTheCookieFileOfNewAndOldProfiles() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SignInImporter.chromiumFile(in: folder).lastPathComponent == "Cookies")
        #expect(!SignInImporter.chromiumFile(in: folder).path.contains("Network"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Network"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Network/Cookies").path, contents: Data())
        #expect(SignInImporter.chromiumFile(in: folder).path.hasSuffix("Network/Cookies"))
    }

    @Test func readsAFirefoxCookieFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cookies.sqlite")
        try Self.sqlite(file, """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT, host TEXT,
            path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER, isHttpOnly INTEGER,
            inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0, isPartitionedAttributeSet INTEGER DEFAULT 0);
        INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, isSecure, isHttpOnly, sameSite) VALUES ('', 'sid', 'v1', '.example.org', '/', 1893456000, 1, 1, 1);
        INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, isSecure, isHttpOnly, sameSite) VALUES ('^userContextId=2', 'sid', 'v2', '.example.org', '/', 1893456000, 1, 1, 1);
        INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, isSecure, isHttpOnly, sameSite) VALUES ('', 'gone', 'v3', 'example.org', '/', 1600000000, 0, 0, 0);
        """)
        let read = SignInImporter.firefox(at: file, now: Self.now)
        #expect(read.cookies.map(\.value) == ["v1"])
        #expect(read.cookies.first?.sameSite == .lax)
        #expect(read.unreadable == 0)
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-signin-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func sqlite(_ file: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}
