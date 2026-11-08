import Foundation
import CommonCrypto
import WebKit

/// Staying signed in after switching: the cookies another browser keeps on this Mac, read from its files and set
/// into Zigzag's own website data, so Google, GitHub and the rest don't ask you to sign in again. Only when you
/// choose it, only into the default store (never a private window's), and nothing about them leaves the Mac or is
/// written down anywhere else: values are never logged, only counted.
nonisolated enum SignInImporter {
    enum SameSite: Sendable, Equatable { case unset, none, lax, strict }

    /// One cookie as read, before it becomes an `HTTPCookie`. Printing it never shows its value.
    struct Cookie: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// ".github.com" for the site and its subdomains, "github.com" for that host alone.
        let domain: String
        let name: String
        let value: String
        let path: String
        /// Nil: a session cookie, gone when Zigzag quits.
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        let sameSite: SameSite

        var description: String { "Cookie(\(name) for \(domain))" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }

        /// What WebKit takes. A leading dot on the domain keeps it a domain cookie; without one, Foundation keeps
        /// it to that exact host, as the source had it.
        var httpCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain, .path: path.isEmpty ? "/" : path, .name: name, .value: value,
            ]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires { properties[.expires] = expires }
            // Foundation has no word for None: a cookie without a policy is sent everywhere, which is what None means.
            switch sameSite {
            case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
            case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
            case .none, .unset: break
            }
            return HTTPCookie(properties: properties)
        }

        /// The site it belongs to ("google.com" for ".mail.google.com"), for counting sites rather than cookies.
        var site: String {
            let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return PublicSuffix.registrableDomain(host) ?? host
        }
    }

    /// What one file gave: the cookies to bring, and how many were there but wouldn't open.
    struct Read: Sendable {
        var cookies: [Cookie] = []
        var unreadable = 0
    }

    enum Outcome: Sendable {
        case cookie(Cookie)
        /// Expired, or kept for one site inside another: left behind on purpose, not counted as a failure.
        case skipped
        case unreadable
    }

    /// Said gently, with nothing to fix: trying again wouldn't open them, and the sites themselves just ask you to
    /// sign in once more.
    static func problem(unreadable: Int, broughtAny: Bool, from browser: String) -> ImportProblem? {
        guard unreadable > 0 else { return nil }
        let message = broughtAny
            ? "A few of your sign-ins from \(browser) couldn’t come over, so some sites may ask you to sign in again."
            : "Your sign-ins from \(browser) couldn’t come over, so sites will ask you to sign in again."
        return ImportProblem(message: message, fix: .none)
    }

    // MARK: Chromium

    /// One row of Chromium's `cookies` table, as stored.
    struct ChromiumRow {
        var host: String
        var name: String
        var value = ""
        var encrypted = Data()
        var path = "/"
        /// Microseconds since 1601; 0 for a session cookie.
        var expiresUTC: Int64 = 0
        var secure = false
        var httpOnly = false
        /// -1 unspecified, 0 none, 1 lax, 2 strict.
        var sameSite: Int64 = -1
        var persistent = true
        /// Set for a partitioned (CHIPS) cookie: one kept for this site only inside that top-level site.
        var topFrameSiteKey = ""
    }

    /// The cookies in a Chromium profile: `Network/Cookies`, or `Cookies` in builds before Chrome 96.
    static func chromiumFile(in profile: URL) -> URL {
        let network = profile.appendingPathComponent("Network/Cookies")
        return FileManager.default.fileExists(atPath: network.path) ? network : profile.appendingPathComponent("Cookies")
    }

    /// Reads one Chromium cookie file through a private copy, so it works while the browser runs. Without a key
    /// (the browser never saved one), only cookies stored in the clear come over; the rest count as unreadable.
    static func chromium(at file: URL, key: Data?, now: Date = Date()) -> Read {
        guard FileManager.default.fileExists(atPath: file.path) else { return Read() }
        // There, but couldn't be copied or opened: say so rather than bring nothing quietly.
        guard let db = SQLiteReader(file) else { return Read(unreadable: 1) }
        var version = 0
        db.rows("SELECT value FROM meta WHERE key = 'version'") { version = Int($0.string(0)) ?? 0 }
        var columns = Set<String>()
        db.rows("PRAGMA table_info(cookies)") { columns.insert($0.string(1)) }
        guard columns.contains("host_key"), columns.contains("encrypted_value") else { return Read() }
        // Columns newer builds added; older ones read without them.
        func column(_ name: String, else fallback: String) -> String { columns.contains(name) ? name : fallback }
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly,
               \(column("samesite", else: "-1")), \(column("is_persistent", else: "expires_utc != 0")), \(column("top_frame_site_key", else: "''"))
        FROM cookies
        """
        var read = Read()
        db.rows(sql) { r in
            let row = ChromiumRow(host: r.string(0), name: r.string(1), value: r.string(2), encrypted: r.data(3), path: r.string(4),
                                  expiresUTC: r.int(5), secure: r.int(6) != 0, httpOnly: r.int(7) != 0, sameSite: r.int(8),
                                  persistent: r.int(9) != 0, topFrameSiteKey: r.string(10))
            switch chromiumCookie(row, key: key, version: version, now: now) {
            case .cookie(let cookie): read.cookies.append(cookie)
            case .skipped: break
            case .unreadable: read.unreadable += 1
            }
        }
        return read
    }

    /// One row, decrypted and checked. Session cookies come too: one still on disk is one the browser restores
    /// with your tabs, so you're signed in there now. Here it stays a session cookie and goes when Zigzag quits,
    /// as the site asked.
    static func chromiumCookie(_ row: ChromiumRow, key: Data?, version: Int, now: Date) -> Outcome {
        guard !row.host.isEmpty, !row.name.isEmpty else { return .skipped }
        // Partitioned cookies need a partition WebKit's public API can't set; set without one they'd be shared
        // across sites, which is exactly what they're not meant to be.
        guard row.topFrameSiteKey.isEmpty else { return .skipped }
        var expires: Date?
        if row.persistent {
            guard let date = ChromiumImporter.date(row.expiresUTC), date > now else { return .skipped }
            expires = date
        }
        let value: String
        if row.encrypted.isEmpty {
            value = row.value
        } else {
            guard let key, var plain = ChromiumImporter.decryptBytes(row.encrypted, key: key) else { return .unreadable }
            defer { plain.resetBytes(in: 0..<plain.count) }
            guard let stripped = stripDomainHash(plain, host: row.host, version: version), ChromiumImporter.isText(stripped) else { return .unreadable }
            value = String(decoding: stripped, as: UTF8.self)
        }
        let sameSite: SameSite = switch row.sameSite {
        case 0: .none
        case 1: .lax
        case 2: .strict
        default: .unset
        }
        return .cookie(Cookie(domain: row.host, name: row.name, value: value, path: row.path, expires: expires,
                              secure: row.secure, httpOnly: row.httpOnly, sameSite: sameSite))
    }

    /// Since version 24 of the cookie database, each value starts with the SHA-256 of its host, which ties it to
    /// that site. It must match: one that doesn't means the wrong key, or a value moved from another site.
    static func stripDomainHash(_ plain: Data, host: String, version: Int) -> Data? {
        guard version >= 24 else { return plain }
        guard plain.count >= Int(CC_SHA256_DIGEST_LENGTH), plain.prefix(Int(CC_SHA256_DIGEST_LENGTH)) == sha256(Data(host.utf8)) else { return nil }
        return Data(plain.dropFirst(Int(CC_SHA256_DIGEST_LENGTH)))
    }

    static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in _ = CC_SHA256(input.baseAddress, CC_LONG(data.count), out.baseAddress?.assumingMemoryBound(to: UInt8.self)) }
        }
        return digest
    }

    // MARK: Firefox

    /// One row of Firefox's `moz_cookies` table, as stored.
    struct FirefoxRow {
        var host: String
        var name: String
        var value = ""
        var path = "/"
        /// Seconds since 1970; newer builds store milliseconds.
        var expiry: Int64 = 0
        var secure = false
        var httpOnly = false
        /// 0 none, 1 lax, 2 strict.
        var sameSite: Int64 = 0
        /// Empty for the normal profile; set for a container, a private window, or a partitioned cookie.
        var originAttributes = ""
        var partitioned = false
    }

    /// Firefox and Zen keep cookies in the clear in `cookies.sqlite`; read through a private copy, as it's open.
    static func firefox(at file: URL, now: Date = Date()) -> Read {
        guard FileManager.default.fileExists(atPath: file.path) else { return Read() }
        guard let db = SQLiteReader(file) else { return Read(unreadable: 1) }
        var columns = Set<String>()
        db.rows("PRAGMA table_info(moz_cookies)") { columns.insert($0.string(1)) }
        guard columns.contains("host") else { return Read() }
        func column(_ name: String, else fallback: String) -> String { columns.contains(name) ? name : fallback }
        let sql = """
        SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(column("sameSite", else: "0")),
               \(column("originAttributes", else: "''")), \(column("isPartitionedAttributeSet", else: "0"))
        FROM moz_cookies
        """
        var read = Read()
        db.rows(sql) { r in
            let row = FirefoxRow(host: r.string(0), name: r.string(1), value: r.string(2), path: r.string(3), expiry: r.int(4),
                                 secure: r.int(5) != 0, httpOnly: r.int(6) != 0, sameSite: r.int(7),
                                 originAttributes: r.string(8), partitioned: r.int(9) != 0)
            if case .cookie(let cookie) = firefoxCookie(row, now: now) { read.cookies.append(cookie) }
        }
        return read
    }

    static func firefoxCookie(_ row: FirefoxRow, now: Date) -> Outcome {
        guard !row.host.isEmpty, !row.name.isEmpty else { return .skipped }
        // Only the everyday jar: containers and private windows are kept apart in Firefox on purpose.
        guard row.originAttributes.isEmpty, !row.partitioned else { return .skipped }
        // Anything past the year 5000 in seconds is really milliseconds.
        let seconds = row.expiry > 100_000_000_000 ? Double(row.expiry) / 1000 : Double(row.expiry)
        let expires = Date(timeIntervalSince1970: seconds)
        guard expires > now else { return .skipped }
        let sameSite: SameSite = switch row.sameSite {
        case 0: .none
        case 1: .lax
        case 2: .strict
        default: .unset
        }
        return .cookie(Cookie(domain: row.host, name: row.name, value: row.value, path: row.path, expires: expires,
                              secure: row.secure, httpOnly: row.httpOnly, sameSite: sameSite))
    }

    // MARK: Into Zigzag

    struct Applied: Sendable {
        /// Distinct sites with something brought over.
        var sites = 0
        var cookies = 0
        /// Already here for the same name, domain and path: Zigzag's own stays.
        var kept = 0
        var failed = 0
    }

    /// The same cookie whether or not its domain has a leading dot, so a host cookie here and a domain cookie
    /// coming in count as one.
    private struct Key: Hashable {
        let name: String, domain: String, path: String
        init(_ name: String, _ domain: String, _ path: String) {
            self.name = name
            self.domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            self.path = path.isEmpty ? "/" : path
        }
    }

    /// Sets the cookies into Zigzag's default store. A cookie Zigzag already has for the same name, domain and
    /// path stays as it is: if you've signed in here already, that session wins over an older one coming in.
    /// The same cookie twice (two profiles) comes over once, the first.
    @MainActor
    static func apply(_ cookies: [Cookie], to store: WKHTTPCookieStore) async -> Applied {
        var applied = Applied()
        var taken = Set(await store.allCookies().map { Key($0.name, $0.domain, $0.path) })
        let alreadyHere = taken
        var ready: [HTTPCookie] = []
        var sites = Set<String>()
        for cookie in cookies {
            let key = Key(cookie.name, cookie.domain, cookie.path)
            if alreadyHere.contains(key) { applied.kept += 1; continue }
            guard taken.insert(key).inserted else { continue }
            guard let http = cookie.httpCookie else { applied.failed += 1; continue }
            ready.append(http)
            sites.insert(cookie.site)
        }
        // In batches, letting the window draw between them: thousands of cookies at once would stall it.
        var index = 0
        while index < ready.count {
            let batch = Array(ready[index..<min(index + 400, ready.count)])
            index += batch.count
            if #available(macOS 26, *) {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in store.setCookies(batch) { done.resume() } }
            } else {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let left = Countdown(batch.count) { done.resume() }
                    for cookie in batch { store.setCookie(cookie) { left.tick() } }
                }
            }
            await Task.yield()
        }
        applied.cookies = ready.count
        applied.sites = sites.count
        return applied
    }

    /// Runs `done` once every one of `count` calls has come back.
    @MainActor
    private final class Countdown {
        private var left: Int
        private let done: () -> Void
        init(_ count: Int, done: @escaping () -> Void) {
            left = count
            self.done = done
            if count == 0 { done() }
        }
        func tick() {
            left -= 1
            if left == 0 { done() }
        }
    }
}
