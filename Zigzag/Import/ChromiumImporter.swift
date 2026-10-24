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
        return names.map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInstalled(_ browser: Browser) -> Bool { !profiles(of: browser).isEmpty }

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
        if choice.contains(.passwords) {
            switch safeStorageKey(browser) {
            case .success(let key):
                for profile in profiles {
                    for file in ["Login Data", "Login Data For Account"] {
                        batch.logins += logins(at: profile.appendingPathComponent(file), key: key)
                    }
                }
            case .failure(.denied):
                batch.problems.append(ImportProblem(message: "\(browser.name)'s passwords stayed locked. When macOS asks, choose Allow (or Always Allow).", fix: .retry))
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

    enum KeyError: Error { case denied, missing }

    /// The browser's "Safe Storage" secret, turned into its AES key. Asks macOS, which asks the person.
    static func safeStorageKey(_ browser: Browser) -> Result<Data, KeyError> {
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
        return SecretString(data: output.prefix(moved))
    }

    /// Chromium time: microseconds since 1601-01-01.
    static func date(_ micros: Int64) -> Date? {
        micros > 0 ? Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600) : nil
    }

    private static func logins(at file: URL, key: Data) -> [ImportBatch.Login] {
        guard FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) else { return [] }
        var result: [ImportBatch.Login] = []
        // Rows marked "never save" are choices, not logins.
        db.rows("SELECT origin_url, username_value, password_value, date_created FROM logins WHERE blacklisted_by_user = 0") { row in
            guard let url = URL(string: row.string(0)), let password = decrypt(row.data(2), key: key), !password.isEmpty else { return }
            result.append(ImportBatch.Login(url: url, username: row.string(1), password: password, created: date(row.int(3))))
        }
        return result
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
