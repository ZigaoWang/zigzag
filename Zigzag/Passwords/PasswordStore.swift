import AppKit
import LocalAuthentication
import Security

/// Where a password belongs: the exact scheme, host and port it was saved on. Autofill only ever offers a
/// password on the same origin.
nonisolated struct Origin: Hashable, Sendable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int?

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        // The default port is the same origin as no port.
        let port = url.port
        self.port = (port == 443 && scheme == "https") || (port == 80 && scheme == "http") ? nil : port
    }

    init(scheme: String, host: String, port: Int?) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    var description: String { port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)" }
    /// What a person calls the site: "github.com".
    var displayName: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    var url: URL? { URL(string: description) }
    /// Whether a login saved here may fill on `page`: the same origin, or an old http login on the same site's
    /// secure page (never the other way round).
    func fills(on page: Origin) -> Bool {
        self == page || (scheme == "http" && page.scheme == "https" && host == page.host && port == nil && page.port == nil)
    }
}

/// One saved login. The password stays in the Keychain until it's needed for filling, revealing or copying.
nonisolated struct Credential: Identifiable, Hashable, Sendable {
    let id: UUID
    var origin: Origin
    var username: String
    var title: String
    var notes: String
    var otpAuth: String
    var created: Date
    var modified: Date
    var lastUsed: Date?

    static func == (a: Credential, b: Credential) -> Bool { a.id == b.id && a.modified == b.modified }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The only code that touches saved passwords. Each login is an internet-password item in Zigzag's own
/// group of the data protection keychain, synced through iCloud Keychain unless the person turns that off.
/// Listing reads only the details (site, username, dates); the password is read one at a time, on demand.
actor PasswordStore {
    static let shared = PasswordStore()

    static let accessGroup = "432GL3WKY2.app.zigzag.passwords"
    /// "Never save for this site" choices, kept with the passwords so they sync too.
    private static let neverService = "app.zigzag.never-save"

    /// Tests use their own label so they never see or touch the person's passwords.
    private let label: String
    private let synchronizable: Bool

    init(label: String = "Zigzag", synchronizable: Bool = UserDefaults.standard.object(forKey: "PasswordsSyncWithICloud") as? Bool ?? true) {
        self.label = label
        self.synchronizable = synchronizable
    }

    enum Failure: Error { case keychain(OSStatus), notFound }

    /// Fires on the main thread when saved passwords change.
    nonisolated static let didChange = Notification.Name("ZigzagPasswordsDidChange")

    // MARK: Reading

    /// Every saved login's details, newest first. No passwords.
    func all() throws -> [Credential] {
        var query = baseQuery()
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { throw Failure.keychain(status) }
        return items.compactMap(Self.credential(from:)).sorted { $0.modified > $1.modified }
    }

    /// Logins saved for exactly this origin.
    func credentials(for origin: Origin) throws -> [Credential] {
        try all().filter { $0.origin == origin }
    }

    /// The password of one login.
    func password(for id: UUID) throws -> SecretString {
        var query = try itemQuery(for: id)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw status == errSecItemNotFound ? Failure.notFound : Failure.keychain(status) }
        return SecretString(data: data)
    }

    // MARK: Writing

    /// Saves a login, or updates the password of the one already saved for this origin and username.
    @discardableResult
    func save(origin: Origin, username: String, password: SecretString, title: String? = nil, notes: String = "", otpAuth: String = "",
              created: Date = Date()) throws -> Credential {
        if var existing = try credentials(for: origin).first(where: { $0.username == username }) {
            existing.modified = Date()
            if let title { existing.title = title }
            if !notes.isEmpty { existing.notes = notes }
            if !otpAuth.isEmpty { existing.otpAuth = otpAuth }
            try update(existing, password: password)
            return existing
        }
        let credential = Credential(id: UUID(), origin: origin, username: username, title: title ?? origin.displayName,
                                    notes: notes, otpAuth: otpAuth, created: created, modified: Date(), lastUsed: nil)
        var item = attributes(for: credential)
        item[kSecValueData] = password.data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        notify()
        return credential
    }

    /// Changes a login's details, and its password when one is given.
    func update(_ credential: Credential, password: SecretString? = nil) throws {
        var changes = attributes(for: credential)
        for key in [kSecClass, kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrSynchronizable] { changes[key] = nil }
        if let password { changes[kSecValueData] = password.data }
        let status = SecItemUpdate(try itemQuery(for: credential.id) as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        notify()
    }

    /// Adds an imported login without looking anything up first (the importer already knows what's here) and
    /// without announcing it: the importer announces the whole batch once.
    @discardableResult
    func addImported(origin: Origin, username: String, password: SecretString, notes: String, otpAuth: String,
                     created: Date, modified: Date) throws -> Credential {
        let credential = Credential(id: UUID(), origin: origin, username: username, title: origin.displayName,
                                    notes: notes, otpAuth: otpAuth, created: created, modified: modified, lastUsed: nil)
        var item = attributes(for: credential)
        item[kSecValueData] = password.data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return credential
    }

    /// Replaces an imported login's password, quietly, for the same reason.
    func replaceImported(_ credential: Credential, password: SecretString) throws {
        var changes = attributes(for: credential)
        for key in [kSecClass, kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrSynchronizable] { changes[key] = nil }
        changes[kSecValueData] = password.data
        let status = SecItemUpdate(try itemQuery(for: credential.id) as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Tells everyone listening that passwords changed, once, after a batch.
    func announceChanges() { notify() }

    func markUsed(_ id: UUID) throws {
        guard var credential = try all().first(where: { $0.id == id }) else { return }
        credential.lastUsed = Date()
        try update(credential)
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(try itemQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        notify()
    }

    // MARK: Never for this site

    func neverSaves(on origin: Origin) -> Bool {
        var query = neverQuery(origin)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setNeverSave(_ never: Bool, on origin: Origin) {
        let query = neverQuery(origin)
        SecItemDelete(query as CFDictionary)
        guard never else { return }
        var item = query
        item[kSecAttrSynchronizable] = synchronizable
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        item[kSecValueData] = Data()
        SecItemAdd(item as CFDictionary, nil)
    }

    func neverSaveSites() -> [Origin] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.neverService + "." + label,
                                      kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: Self.accessGroup,
                                      kSecAttrSynchronizable: kSecAttrSynchronizableAny]
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount] as? String).flatMap { Origin(URL(string: $0)) } }
    }

    /// Removes everything this store's label owns. Tests use it to clean up after themselves.
    func deleteAll() {
        var query = baseQuery()
        query[kSecMatchLimit] = nil
        SecItemDelete(query as CFDictionary)
        let never: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.neverService + "." + label,
                                      kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: Self.accessGroup,
                                      kSecAttrSynchronizable: kSecAttrSynchronizableAny]
        SecItemDelete(never as CFDictionary)
    }

    // MARK: Keychain plumbing

    private func baseQuery() -> [CFString: Any] {
        [kSecClass: kSecClassInternetPassword,
         kSecUseDataProtectionKeychain: true,
         kSecAttrAccessGroup: Self.accessGroup,
         kSecAttrLabel: label,
         kSecAttrSynchronizable: kSecAttrSynchronizableAny]
    }

    private func neverQuery(_ origin: Origin) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: Self.neverService + "." + label,
         kSecAttrAccount: origin.description,
         kSecUseDataProtectionKeychain: true,
         kSecAttrAccessGroup: Self.accessGroup,
         kSecAttrSynchronizable: kSecAttrSynchronizableAny]
    }

    private func itemQuery(for id: UUID) throws -> [CFString: Any] {
        // The ID lives in the item's comment, so one item can be found without reading any password.
        var query = baseQuery()
        query[kSecAttrComment] = id.uuidString
        return query
    }

    private struct Details: Codable {
        var title: String
        var notes: String
        var otpAuth: String
        var created: Date
        var modified: Date
        var lastUsed: Date?
    }

    private func attributes(for credential: Credential) -> [CFString: Any] {
        let details = Details(title: credential.title, notes: credential.notes, otpAuth: credential.otpAuth,
                              created: credential.created, modified: credential.modified, lastUsed: credential.lastUsed)
        var item: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessGroup: Self.accessGroup,
            kSecAttrSynchronizable: synchronizable,
            // Readable while the Mac is unlocked; required for sync, and never needs Touch ID to fill.
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
            kSecAttrLabel: label,
            kSecAttrComment: credential.id.uuidString,
            kSecAttrServer: credential.origin.host,
            kSecAttrProtocol: credential.origin.scheme == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
            kSecAttrAccount: credential.username,
            // Title, notes and dates, as JSON; internet-password items have no generic attribute.
            kSecAttrDescription: (try? JSONEncoder().encode(details)).flatMap { String(data: $0, encoding: .utf8) } ?? "",
        ]
        if let port = credential.origin.port { item[kSecAttrPort] = port }
        return item
    }

    private static func credential(from item: [CFString: Any]) -> Credential? {
        guard let comment = item[kSecAttrComment] as? String, let id = UUID(uuidString: comment),
              let host = item[kSecAttrServer] as? String else { return nil }
        let scheme = (item[kSecAttrProtocol] as? String) == (kSecAttrProtocolHTTP as String) ? "http" : "https"
        let port = (item[kSecAttrPort] as? Int).flatMap { $0 == 0 ? nil : $0 }
        let details = (item[kSecAttrDescription] as? String).flatMap { try? JSONDecoder().decode(Details.self, from: Data($0.utf8)) }
        let origin = Origin(scheme: scheme, host: host, port: port)
        return Credential(id: id, origin: origin, username: item[kSecAttrAccount] as? String ?? "",
                          title: details?.title ?? origin.displayName, notes: details?.notes ?? "", otpAuth: details?.otpAuth ?? "",
                          created: details?.created ?? (item[kSecAttrCreationDate] as? Date ?? Date()),
                          modified: details?.modified ?? (item[kSecAttrModificationDate] as? Date ?? Date()),
                          lastUsed: details?.lastUsed)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

/// Touch ID (or the Mac's password) before a password is shown, copied or exported. Filling never asks.
enum PasswordAuthentication {
    /// The last successful check, so one unlock covers the Passwords window for a while, even after it's closed.
    /// It ends when the Mac sleeps or locks, whether or not the window is open.
    @MainActor private static var unlockedUntil: Date? { didSet { if unlockedUntil != nil { watchForSleep() } } }
    @MainActor private static var sleepObservers: [Any] = []

    /// Once, on the first unlock: sleep, the screen sleeping or another user switching in locks again.
    @MainActor private static func watchForSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lock() }
            })
        }
    }

    @MainActor static var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    @MainActor static func lock() { unlockedUntil = nil }

    /// How long an unlock lasts after its last use.
    static let unlockDuration: TimeInterval = 15 * 60

    #if DEBUG
    /// For the debug bridge only: stands in for Touch ID so the Passwords window can be checked by script.
    @MainActor static func unlockForTesting() { unlockedUntil = Date().addingTimeInterval(120) }
    #endif

    /// Asks for Touch ID with a reason in plain words ("show your password for github.com").
    @MainActor static func authenticate(_ reason: String, keepUnlockedFor seconds: TimeInterval = 0) async -> Bool {
        if seconds > 0, isUnlocked {
            // Using it keeps it open: the time counts from the last use, not from when it was unlocked.
            unlockedUntil = max(unlockedUntil ?? .distantPast, Date().addingTimeInterval(seconds))
            return true
        }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok, seconds > 0 { unlockedUntil = Date().addingTimeInterval(seconds) }
        return ok
    }
}
