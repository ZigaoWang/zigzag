import CommonCrypto
import CryptoKit
import Foundation

/// Firefox and browsers built on it (Zen). Profiles come from `profiles.ini`; passwords from `logins.json`,
/// encrypted with a key kept in `key4.db`; bookmarks and history from `places.sqlite`.
///
/// Without a primary password the key opens with an empty one, so nothing needs asking. With one, the person
/// types it and it's used once, in memory.
nonisolated enum FirefoxImporter {
    struct Browser: Sendable, Hashable {
        let name: String
        let bundleID: String
        /// Under ~/Library/Application Support.
        let root: String
    }

    static let browsers: [Browser] = [
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", root: "Firefox"),
        Browser(name: "Zen", bundleID: "app.zen-browser.zen", root: "zen"),
    ]

    static func rootURL(of browser: Browser) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(browser.root, isDirectory: true)
    }

    /// Profile folders with data in them, the one the browser opens first.
    static func profiles(of browser: Browser) -> [URL] {
        let root = rootURL(of: browser)
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var paths: [String] = []
        var installDefaults: [String] = []
        var section = ""
        for line in ini.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { section = line; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            if section.hasPrefix("[Install"), key == "Default" { installDefaults.append(value) }
            if section.hasPrefix("[Profile"), key == "Path" { paths.append(value) }
        }
        // The [Install…] default is the profile the browser actually uses; it goes first.
        let ordered = installDefaults + paths.filter { !installDefaults.contains($0) }
        return ordered.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
    }

    static func isInstalled(_ browser: Browser) -> Bool { !profiles(of: browser).isEmpty }

    static func read(_ browser: Browser, _ choice: ChromiumImporter.Choice, primaryPassword: String = "") -> ImportBatch {
        var batch = ImportBatch()
        for profile in profiles(of: browser) {
            if choice.contains(.passwords) { readLogins(browser, profile, primaryPassword, into: &batch) }
            if choice.contains(.bookmarks) { batch.bookmarks += bookmarks(at: profile.appendingPathComponent("places.sqlite")) }
            if choice.contains(.history) { batch.history += history(at: profile.appendingPathComponent("places.sqlite")) }
        }
        return batch
    }

    /// How much a browser holds, without reading any password.
    static func counts(_ browser: Browser) -> (passwords: Int, bookmarks: Int, history: Int) {
        var passwords = 0, bookmarks = 0, history = 0
        for profile in profiles(of: browser) {
            if let data = try? Data(contentsOf: profile.appendingPathComponent("logins.json")),
               let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                passwords += (file["logins"] as? [Any])?.count ?? 0
            } else if FileManager.default.fileExists(atPath: profile.appendingPathComponent("logins.db").path),
                      let db = SQLiteReader(profile.appendingPathComponent("logins.db")) {
                db.rows("SELECT (SELECT count(*) FROM loginsL WHERE is_deleted = 0) + (SELECT count(*) FROM loginsM WHERE is_deleted = 0)") { passwords += Int($0.int(0)) }
            }
            let places = profile.appendingPathComponent("places.sqlite")
            if let db = SQLiteReader(places) {
                db.rows("SELECT count(*) FROM moz_bookmarks WHERE type = 1") { bookmarks += Int($0.int(0)) }
                db.rows("SELECT count(*) FROM moz_places WHERE last_visit_date IS NOT NULL") { history += Int($0.int(0)) }
            }
        }
        return (passwords, bookmarks, history)
    }

    // MARK: Passwords

    private static func readLogins(_ browser: Browser, _ profile: URL, _ primaryPassword: String, into batch: inout ImportBatch) {
        let json = profile.appendingPathComponent("logins.json")
        if let data = try? Data(contentsOf: json), let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let logins = file["logins"] as? [[String: Any]], !logins.isEmpty {
            switch key(in: profile, primaryPassword: primaryPassword) {
            case .failure(.primaryPassword):
                if !batch.problems.contains(where: { $0.fix == .primaryPassword }) {
                    let message = primaryPassword.isEmpty ? "\(browser.name) has a primary password. Type it to bring its passwords over."
                        : "That isn’t \(browser.name)’s primary password. Check it and try again."
                    batch.problems.append(ImportProblem(message: message, fix: .primaryPassword))
                }
            case .failure(.unreadable):
                batch.problems.append(ImportProblem(message: "\(browser.name)'s passwords are in a format Zigzag can't read. Export them from \(browser.name)'s Passwords page as a CSV file, then choose it here.", fix: .exportFromApplePasswords))
            case .success(let key):
                for login in logins {
                    guard let host = login["hostname"] as? String, let url = URL(string: host),
                          let user = (login["encryptedUsername"] as? String).flatMap({ decryptField($0, key: key) }),
                          let password = (login["encryptedPassword"] as? String).flatMap({ decryptField($0, key: key) }), !password.isEmpty else { continue }
                    let created = (login["timeCreated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    var imported = ImportBatch.Login(url: url, username: user.withUnsafeString { $0 }, password: password, created: created)
                    imported.changed = (login["timePasswordChanged"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    batch.logins.append(imported)
                }
            }
            return
        }
        // Newer builds keep logins in a database with a different scheme. Say so rather than guess.
        let db = profile.appendingPathComponent("logins.db")
        if FileManager.default.fileExists(atPath: db.path), let reader = SQLiteReader(db) {
            var count: Int64 = 0
            reader.rows("SELECT (SELECT count(*) FROM loginsL WHERE is_deleted = 0) + (SELECT count(*) FROM loginsM WHERE is_deleted = 0)") { count = $0.int(0) }
            if count > 0 {
                batch.problems.append(ImportProblem(message: "\(browser.name) keeps its \(count) passwords in a newer format Zigzag can't read yet. Export them from \(browser.name)'s Passwords page as a CSV file, then choose it here.", fix: .exportFromApplePasswords))
            }
        }
    }

    enum KeyError: Error { case primaryPassword, unreadable }

    /// The key that encrypts each login, unwrapped from key4.db.
    static func key(in profile: URL, primaryPassword: String) -> Result<Data, KeyError> {
        guard let db = SQLiteReader(profile.appendingPathComponent("key4.db")) else { return .failure(.unreadable) }
        var globalSalt = Data(), check = Data()
        db.rows("SELECT item1, item2 FROM metaData WHERE id = 'password'") { globalSalt = $0.data(0); check = $0.data(1) }
        guard !globalSalt.isEmpty, !check.isEmpty else { return .failure(.unreadable) }
        // If the check value doesn't come out as "password-check", the primary password is missing or wrong. Each
        // profile has its own: one without any opens with an empty one, whatever was typed for another.
        let opens = { (password: String) in decryptPBE(check, globalSalt: globalSalt, password: password)?.prefix(14) == Data("password-check".utf8) }
        guard let password = ["", primaryPassword].first(where: opens) else { return .failure(.primaryPassword) }
        var wrapped = Data()
        db.rows("SELECT a11 FROM nssPrivate") { if wrapped.isEmpty { wrapped = $0.data(0) } }
        guard let key = decryptPBE(wrapped, globalSalt: globalSalt, password: password) else { return .failure(.unreadable) }
        return .success(key)
    }

    /// NSS's PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC), as used by key4.db since Firefox 72.
    static func decryptPBE(_ der: Data, globalSalt: Data, password: String) -> Data? {
        guard let root = NSSDER.parse(der), root.children.count == 2,
              let algorithm = root.children.first, let ciphertext = root.children.last?.bytes,
              algorithm.children.first?.oid == "1.2.840.113549.1.5.13",
              let params = algorithm.children.dropFirst().first, params.children.count == 2 else { return nil }
        let kdf = params.children[0], cipher = params.children[1]
        guard kdf.children.first?.oid == "1.2.840.113549.1.5.12", let kdfParams = kdf.children.dropFirst().first,
              let salt = kdfParams.children.first?.bytes, kdfParams.children.count >= 2,
              let iterations = kdfParams.children[1].integer,
              cipher.children.first?.oid == "2.16.840.1.101.3.4.1.42", let ivTail = cipher.children.dropFirst().first?.bytes else { return nil }
        let keyLength = kdfParams.children.count >= 3 ? (kdfParams.children[2].integer ?? 32) : 32
        // From a file on disk: numbers out of any sensible range mean it's damaged, never a reason to crash or stall.
        guard (1...10_000_000).contains(iterations), (16...64).contains(keyLength) else { return nil }
        let base = Data(Insecure.SHA1.hash(data: globalSalt + Data(password.utf8)))
        let key = pbkdf2SHA256(password: base, salt: salt, iterations: iterations, length: keyLength)
        // NSS stores 14 bytes of the IV and the DER prefix of an OCTET STRING (04 0e) supplies the rest.
        let iv = ivTail.count == 16 ? ivTail : Data([0x04, 0x0e]) + ivTail
        return crypt(CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, data: ciphertext)
    }

    /// A logins.json field: base64 DER of (key id, algorithm with IV, ciphertext); 3DES or AES-256.
    static func decryptField(_ base64: String, key: Data) -> SecretString? {
        guard let der = Data(base64Encoded: base64), let root = NSSDER.parse(der), root.children.count == 3,
              let algorithm = root.children[1].children.first?.oid, let iv = root.children[1].children.dropFirst().first?.bytes,
              let ciphertext = root.children[2].bytes else { return nil }
        let plain: Data?
        switch algorithm {
        case "1.2.840.113549.3.7": plain = key.count >= 24 ? crypt(CCAlgorithm(kCCAlgorithm3DES), key: key.prefix(24), iv: iv, data: ciphertext) : nil
        case "2.16.840.1.101.3.4.1.42": plain = key.count >= 32 ? crypt(CCAlgorithm(kCCAlgorithmAES), key: key.prefix(32), iv: iv, data: ciphertext) : nil
        default: plain = nil
        }
        return plain.map { SecretString(data: $0) }
    }

    private static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var out = Data(count: length)
        _ = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         o.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return out
    }

    private static func crypt(_ algorithm: CCAlgorithm, key: Data, iv: Data, data: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                        d.baseAddress, data.count, o.baseAddress, outCount, &moved)
            } } }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    // MARK: Bookmarks and history

    private static func bookmarks(at file: URL) -> [ImportBatch.Bookmark] {
        guard FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) else { return [] }
        var result: [ImportBatch.Bookmark] = []
        db.rows("SELECT p.url, b.title FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1 ORDER BY b.parent, b.position") { row in
            guard let url = URL(string: row.string(0)), url.scheme == "http" || url.scheme == "https" else { return }
            let title = row.string(1)
            result.append(ImportBatch.Bookmark(url: url, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title))
        }
        return result
    }

    private static func history(at file: URL) -> [(URL, String, Int, Date)] {
        guard FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) else { return [] }
        var result: [(URL, String, Int, Date)] = []
        db.rows("SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE hidden = 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 50000") { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url), row.int(3) > 0 else { return }
            result.append((url, row.string(1), Int(row.int(2)), Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000)))
        }
        return result
    }
}

/// Just enough DER to read NSS's structures: sequences, OIDs, integers, octet strings.
nonisolated struct NSSDER {
    let tag: UInt8
    let value: Data
    let children: [NSSDER]

    var bytes: Data? { tag == 0x04 ? value : nil }
    var integer: Int? {
        guard tag == 0x02, value.count <= 8 else { return nil }
        return value.reduce(0) { $0 << 8 | Int($1) }
    }
    var oid: String? {
        guard tag == 0x06, let first = value.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var current = 0
        for byte in value.dropFirst() {
            current = current << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { parts.append(current); current = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    static func parse(_ data: Data) -> NSSDER? {
        var index = data.startIndex
        return read(data, &index)
    }

    private static func read(_ data: Data, _ index: inout Data.Index) -> NSSDER? {
        guard index < data.endIndex else { return nil }
        let tag = data[index]
        index += 1
        guard index < data.endIndex else { return nil }
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, data.endIndex - index >= count else { return nil }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(data[index]); index += 1 }
        }
        guard data.endIndex - index >= length else { return nil }
        let value = data.subdata(in: index..<(index + length))
        index += length
        var children: [NSSDER] = []
        if tag & 0x20 != 0 {  // constructed: SEQUENCE, SET
            var inner = value.startIndex
            while inner < value.endIndex, let child = read(value, &inner) { children.append(child) }
        }
        return NSSDER(tag: tag, value: value, children: children)
    }
}
