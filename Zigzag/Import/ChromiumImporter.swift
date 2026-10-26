import os
import AppKit
import CommonCrypto
import Security

/// Chrome and the browsers built on it: Arc, Edge, Brave, Dia, Vivaldi, Opera. They share one layout:
/// profiles listed in `Local State`, and in each profile `Login Data` (passwords), `Bookmarks` and `History`.
///
/// Passwords are encrypted with a key kept in the login keychain as "<Browser> Safe Storage". Reading it shows
/// macOS's own prompt ("Zigzag wants to use … Chrome Safe Storage"), so the person always decides.
nonisolated enum ChromiumImporter {
    struct Browser: Sendable, Hashable {
        let name: String
        let bundleID: String
        /// Under ~/Library/Application Support.
        let root: String
        let keychainService: String
        let keychainAccount: String
        /// One profile's folder ("Profile 1"), when importing a single profile; nil means all of them.
        var profile: String? = nil
        /// That profile's name as the browser shows it ("Work").
        var profileName: String? = nil

        func only(_ folder: String, named display: String) -> Browser {
            var copy = self
            copy.profile = folder
            copy.profileName = display
            return copy
        }
    }

    static let browsers: [Browser] = [
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", root: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        Browser(name: "Chrome", bundleID: "com.google.Chrome", root: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        Browser(name: "Dia", bundleID: "company.thebrowser.dia", root: "Dia/User Data", keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
        Browser(name: "Edge", bundleID: "com.microsoft.edgemac", root: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        Browser(name: "Brave", bundleID: "com.brave.Browser", root: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", root: "Vivaldi", keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera", root: "com.operasoftware.Opera", keychainService: "Opera Safe Storage", keychainAccount: "Opera"),
    ]

    static func rootURL(of browser: Browser) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(browser.root, isDirectory: true)
    }

    /// Profile folders, from `Local State` (falling back to "Default").
    static func profiles(of browser: Browser) -> [URL] {
        let root = rootURL(of: browser)
        var names: [String] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            names = cache.keys.sorted()
        }
        if names.isEmpty { names = ["Default"] }
        if let only = browser.profile { names = names.filter { $0 == only } }
        return names.map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInstalled(_ browser: Browser) -> Bool { !profiles(of: browser).isEmpty }

    /// Each profile's folder and the name the browser shows for it, in the order the browser lists them.
    static func profileNames(of browser: Browser) -> [(folder: String, name: String)] {
        let root = rootURL(of: browser)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
        let found: [(String, String, String?)] = order.compactMap { folder in
            guard let info = cache[folder] as? [String: Any],
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path) else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (folder, name, email)
        }
        // Two profiles with the same name ("Wang" and "Wang"): tell them apart by their account, else their folder.
        let counts = Dictionary(grouping: found, by: \.1).mapValues(\.count)
        return found.map { folder, name, email in
            guard counts[name, default: 0] > 1 else { return (folder, name) }
            return (folder, "\(name) (\(email ?? folder))")
        }
    }

    // MARK: Reading

    struct Choice: OptionSet, Sendable {
        let rawValue: Int
        static let passwords = Choice(rawValue: 1)
        static let bookmarks = Choice(rawValue: 2)
        static let history = Choice(rawValue: 4)
    }

    static func read(_ browser: Browser, _ choice: Choice) -> ImportBatch {
        var batch = ImportBatch()
        let profiles = profiles(of: browser)
        // macOS protects some browsers' data (Chrome, Edge, Brave) from other apps, with no prompt; say so.
        let files = profiles.flatMap { profile in ["Login Data", "Bookmarks", "History"].map { profile.appendingPathComponent($0) } }
        if files.contains(where: { FileManager.default.fileExists(atPath: $0.path) && !FileManager.default.isReadableFile(atPath: $0.path) })
            || (profiles.isEmpty && FileManager.default.fileExists(atPath: rootURL(of: browser).path)) {
            batch.problems.append(ImportProblem(message: "macOS keeps \(browser.name)’s data private until you allow it. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on \(browser.name), then try again.", fix: .fullDiskAccess))
            return batch
        }
        if choice.contains(.passwords) {
            switch safeStorageKey(browser) {
            case .success(let key):
                var unreadable = 0
                for profile in profiles {
                    for file in ["Login Data", "Login Data For Account"] {
                        let read = logins(at: profile.appendingPathComponent(file), key: key)
                        batch.logins += read.logins
                        unreadable += read.unreadable
                    }
                }
                // Never a quiet zero: passwords that are there but wouldn't open are said, with a way to try again.
                if unreadable > 0 {
                    let message = batch.logins.isEmpty
                        ? "Zigzag couldn’t open \(browser.name)’s passwords. Quit \(browser.name), then try again."
                        : "\(unreadable) \(unreadable == 1 ? "password" : "passwords") from \(browser.name) couldn’t be opened. Quit \(browser.name), then try again."
                    batch.problems.append(ImportProblem(message: message, fix: .retry, retries: 1))
                }
            case .failure(.denied):
                batch.problems.append(ImportProblem(message: "\(browser.name)’s passwords stayed locked. Click Try Again, type your Mac’s password when macOS asks, and click Always Allow.", fix: .retry, retries: 1))
            case .failure(.missing):
                break  // No passwords saved there: nothing to say.
            }
        }
        if choice.contains(.bookmarks) {
            for profile in profiles { batch.bookmarks += bookmarks(at: profile.appendingPathComponent("Bookmarks")) }
        }
        if choice.contains(.history) {
            for profile in profiles { batch.history += history(at: profile.appendingPathComponent("History")) }
        }
        return batch
    }

    /// How much a browser holds, without reading any password.
    static func counts(_ browser: Browser) -> (passwords: Int, bookmarks: Int, history: Int) {
        var passwords = 0, history = 0
        for profile in profiles(of: browser) {
            for file in ["Login Data", "Login Data For Account"] {
                guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(file).path), let db = SQLiteReader(profile.appendingPathComponent(file)) else { continue }
                db.rows("SELECT count(*) FROM logins WHERE blacklisted_by_user = 0") { passwords += Int($0.int(0)) }
            }
            if FileManager.default.fileExists(atPath: profile.appendingPathComponent("History").path), let db = SQLiteReader(profile.appendingPathComponent("History")) {
                db.rows("SELECT count(*) FROM urls WHERE hidden = 0") { history += Int($0.int(0)) }
            }
        }
        let bookmarks = profiles(of: browser).map { self.bookmarks(at: $0.appendingPathComponent("Bookmarks")).count }.reduce(0, +)
        return (passwords, bookmarks, history)
    }

    enum KeyError: Error { case denied, missing }

    /// Keys already unlocked this session, in memory only and for a few minutes, so importing several profiles
    /// of one browser asks macOS once, not once per profile.
    private static let unlocked = OSAllocatedUnfairLock(initialState: [String: (key: Data, at: Date)]())

    /// The browser's "Safe Storage" secret, turned into its AES key. Asks macOS, which asks the person.
    static func safeStorageKey(_ browser: Browser) -> Result<Data, KeyError> {
        if let kept = unlocked.withLock({ $0[browser.keychainService] }), Date().timeIntervalSince(kept.at) < 600 { return .success(kept.key) }
        let result = askForKey(browser)
        if case .success(let key) = result { unlocked.withLock { $0[browser.keychainService] = (key, Date()) } }
        return result
    }

    private static func askForKey(_ browser: Browser) -> Result<Data, KeyError> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: browser.keychainService,
            kSecAttrAccount: browser.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let secret = result as? Data else { return .failure(.missing) }
            return .success(deriveKey(secret))
        case errSecItemNotFound: return .failure(.missing)
        default: return .failure(.denied)
        }
    }

    /// Chromium on macOS: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16 bytes.
    static func deriveKey(_ secret: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let keyCount = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secretBytes.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyCount)
                }
            }
        }
        return key
    }

    /// A `v10` value: AES-128-CBC with an IV of sixteen spaces, PKCS#7 padding.
    static func decrypt(_ value: Data, key: Data) -> SecretString? {
        guard value.count > 3, value.prefix(3) == Data("v10".utf8) else { return nil }
        let ciphertext = value.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, ciphertext.count, out.baseAddress, outputCount, &moved)
                    }
                }
            }
        }
        defer { output.resetBytes(in: 0..<output.count) }
        guard status == kCCSuccess else { return nil }
        // The wrong key can still end in valid padding, giving bytes that aren't a password; a real one is text.
        let plain = output.prefix(moved)
        guard isText(plain) else { return nil }
        return SecretString(data: plain)
    }

    /// Valid UTF-8 with no control characters, checked byte by byte so the password never becomes a String.
    static func isText(_ bytes: Data) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// Chromium time: microseconds since 1601-01-01.
    static func date(_ micros: Int64) -> Date? {
        micros > 0 ? Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600) : nil
    }

    /// The logins in one password file, and how many have a password that wouldn't decrypt.
    static func logins(at file: URL, key: Data) -> (logins: [ImportBatch.Login], unreadable: Int) {
        guard FileManager.default.fileExists(atPath: file.path) else { return ([], 0) }
        guard let db = SQLiteReader(file) else {
            // There, but couldn't be copied or opened: every password in it counts as not brought over.
            return ([], 1)
        }
        var result: [ImportBatch.Login] = []
        var withPassword = 0
        // Sign-ins with no password of their own (passkeys, "Sign in with Google") have an empty value.
        db.rows("SELECT count(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0") { withPassword = Int($0.int(0)) }
        // Rows marked "never save" are choices, not logins. Newer Chrome also says when each password changed;
        // older builds don't have that column, so those are read without it.
        func read(_ withChanged: Bool) {
            let columns = "origin_url, username_value, password_value, date_created" + (withChanged ? ", date_password_modified" : "")
            db.rows("SELECT \(columns) FROM logins WHERE blacklisted_by_user = 0") { row in
                guard let url = URL(string: row.string(0)), let password = decrypt(row.data(2), key: key), !password.isEmpty else { return }
                var login = ImportBatch.Login(url: url, username: row.string(1), password: password, created: date(row.int(3)))
                if withChanged { login.changed = date(row.int(4)) }
                result.append(login)
            }
        }
        read(true)
        if result.isEmpty { read(false) }
        return (result, max(0, withPassword - result.count))
    }

    private static func bookmarks(at file: URL) -> [ImportBatch.Bookmark] {
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var result: [ImportBatch.Bookmark] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let string = node["url"] as? String, let url = URL(string: string),
               url.scheme == "http" || url.scheme == "https" {
                result.append(ImportBatch.Bookmark(url: url, title: node["name"] as? String ?? url.host() ?? string))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        // The bookmarks bar first, as it appears in the browser.
        for name in ["bookmark_bar", "other", "synced"] { if let root = roots[name] as? [String: Any] { walk(root) } }
        return result
    }

    private static func history(at file: URL) -> [(URL, String, Int, Date)] {
        guard FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) else { return [] }
        var result: [(URL, String, Int, Date)] = []
        db.rows("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 50000") { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url), let date = date(row.int(3)) else { return }
            result.append((url, row.string(1), Int(row.int(2)), date))
        }
        return result
    }
}
