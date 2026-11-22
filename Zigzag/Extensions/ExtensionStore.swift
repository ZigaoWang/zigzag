import AppKit
import CryptoKit
import SQLite3
import WebKit

/// The extensions pinned to the address, left to right. An extension that's off keeps its place and uses no slot.
struct ExtensionPins: Equatable {
    private(set) var ids: [String]

    /// How many extensions can be pinned to the address.
    static let limit = 3

    init(ids: [String] = []) {
        self.ids = ids
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// A new pin goes on the left, so the ones already there don't move.
    func pinning(_ id: String) -> ExtensionPins {
        contains(id) ? self : ExtensionPins(ids: [id] + ids)
    }

    func unpinning(_ id: String) -> ExtensionPins {
        ExtensionPins(ids: ids.filter { $0 != id })
    }

    func keeping(_ isKept: (String) -> Bool) -> ExtensionPins {
        ExtensionPins(ids: ids.filter(isKept))
    }

    /// Whether there's a free slot, with these extensions loaded.
    func canPin(loaded: Set<String>) -> Bool { ids.filter(loaded.contains).count < Self.limit }

    /// The pins that get a button: those loaded, nearest Site Controls first in line for the limit.
    func shown(among loaded: Set<String>) -> [String] { Array(ids.filter(loaded.contains).suffix(Self.limit)) }

    /// The showing pins in a new order. They take the places the showing pins held, so a pin that's hidden or off
    /// keeps its own; one that went away meanwhile is left out.
    func reordered(visible: [String]) -> ExtensionPins {
        let present = visible.filter(contains)
        var next = present.makeIterator()
        return ExtensionPins(ids: ids.map { present.contains($0) ? next.next() ?? $0 : $0 })
    }
}

/// Where extensions live and what the person decided about them. Packages come from the Chrome Web Store,
/// the same files Chrome users get, verified and never edited: each version sits in its own folder exactly as
/// it was downloaded. Which version is current is kept beside it. A package is shared: what each profile decided
/// about the extension (on or off, what it's allowed) is that profile's own (ExtensionInstalls).
///
///     Extensions/<id>/state.json
///     Extensions/<id>/versions/<version>/   ← the package, untouched
///
/// Extensions installed from a folder (one you're building, or one that comes inside an app) are read in place
/// from that folder.
enum ExtensionStore {
    static let onePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private static let lastUpdateKey = "ExtensionsLastUpdateCheck"
    private static let removedKey = "RemovedExtensions"

    static var root: URL { rootOverride ?? Paths.directory("Extensions") }

    /// Where the packages live. Zigzag always uses its own folder; a test points this at a temporary one, so
    /// nothing it installs is left behind in yours.
    static var rootOverride: URL?

    static func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private static func versionsFolder(for id: String) -> URL { folder(for: id).appendingPathComponent("versions", isDirectory: true) }
    static func stateFile(for id: String) -> URL { folder(for: id).appendingPathComponent("state.json") }

    // MARK: Packages

    /// What we remember about an extension's package, the same for every profile.
    struct Package: Codable {
        var version: String
        /// A downloaded update that asks for more than the current version, waiting for the person's approval.
        var pendingVersion: String?
        /// For an unpacked extension: the folder it's read from.
        var unpackedPath: String?
        /// Which browser's package this is: "chromium" for the store's and a folder's, "firefox" for an .xpi.
        /// A record written before this key existed reads as Chrome's.
        var kind: String = ExtensionKind.chromium.rawValue
        /// A Firefox package's gecko ID (`browser_specific_settings.gecko.id`), which names it to Firefox.
        var firefoxID: String?
        fileprivate static let keys = ["version", "pendingVersion", "unpackedPath", "kind", "firefoxID"]

        init(version: String, pendingVersion: String? = nil, unpackedPath: String? = nil,
             kind: String = ExtensionKind.chromium.rawValue, firefoxID: String? = nil) {
            self.version = version
            self.pendingVersion = pendingVersion
            self.unpackedPath = unpackedPath
            self.kind = kind
            self.firefoxID = firefoxID
        }

        private enum CodingKeys: String, CodingKey { case version, pendingVersion, unpackedPath, kind, firefoxID }

        /// A record that has no `kind` is a Chrome one, as every record written before Firefox packages existed.
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(String.self, forKey: .version)
            pendingVersion = try fields.decodeIfPresent(String.self, forKey: .pendingVersion)
            unpackedPath = try fields.decodeIfPresent(String.self, forKey: .unpackedPath)
            kind = try fields.decodeIfPresent(String.self, forKey: .kind) ?? ExtensionKind.chromium.rawValue
            firefoxID = try fields.decodeIfPresent(String.self, forKey: .firefoxID)
        }
    }

    static func package(_ id: String) -> Package? { read(Package.self, from: stateFile(for: id)) }

    /// The kind a package's record keeps, for wording its sheets and rows. A record without one — every record
    /// written before Firefox packages existed — is Chrome's.
    static func kind(of id: String) -> ExtensionKind {
        package(id).flatMap { ExtensionKind(rawValue: $0.kind) } ?? .chromium
    }

    static func save(_ package: Package, for id: String) {
        try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        write(package, keys: Package.keys, to: stateFile(for: id))
    }

    static func update(_ id: String, _ change: (inout Package) -> Void) {
        guard var current = package(id) else { return }
        change(&current)
        save(current, for: id)
    }

    /// Takes a record's keys out of the file, leaving its others.
    static func remove(keys: [String], from file: URL) {
        defer { forgetWhatWasRead() }
        guard var all = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else { return }
        for key in keys { all[key] = nil }
        guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        try? out.write(to: file, options: .atomic)
    }

    static func read<Record: Decodable>(_ type: Record.Type, from file: URL) -> Record? {
        let key = ReadKey(path: file.path, type: ObjectIdentifier(Record.self))
        if let cached = records[key] { return cached as? Record }
        reads += 1
        watchActivation()
        let record = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(type, from: $0) }
        records[key] = .some(record.map { $0 as Any })
        return record
    }

    /// Writes a record's own keys and leaves the file's others as they are: the package's record and the first
    /// profile's answers share one file, and neither writer knows the other's keys.
    static func write<Record: Encodable>(_ record: Record, keys: [String], to file: URL) {
        defer { forgetWhatWasRead() }
        guard let data = try? JSONEncoder().encode(record),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var all = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        for key in keys { all[key] = fields[key] }
        guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        try? out.write(to: file, options: .atomic)
    }

    // MARK: What was read

    /// What the extension files said when last read. Pages ask on every web view made and every sign-in field
    /// focused (which extensions are on, what they declare), and each answer was a dozen file reads: the answers are
    /// kept until Zigzag writes or removes any of these files (`forgetWhatWasRead`), and read again each time Zigzag
    /// comes to the front, for an unpacked extension's folder changed meanwhile.
    private struct ReadKey: Hashable {
        let path: String
        let type: ObjectIdentifier
    }
    /// A decoded record, or nil (stored as such) for a file that isn't there or doesn't read.
    private static var records: [ReadKey: Any?] = [:]
    private static var packageDirectories: [String: URL?] = [:]
    private static var packageIDsRead: [String]?
    private static var manifests: [String: [String: Any]?] = [:]
    /// Moves on each time what was read is forgotten, for answers worked out from it elsewhere (ExtensionInstalls).
    private(set) static var generation = 0
    /// How many times a record or manifest was read from disk, for tests.
    private(set) static var reads = 0
    private static var activationToken: NSObjectProtocol?

    /// What was read is forgotten each time Zigzag comes to the front: a developer may have changed an unpacked
    /// extension's folder, or unplugged the drive it's on, while Zigzag was behind.
    static func watchActivation() {
        guard activationToken == nil else { return }
        activationToken = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { forgetWhatWasRead() }
        }
    }

    /// Zigzag changed extension files, or something else may have: everything is read afresh.
    static func forgetWhatWasRead() {
        records.removeAll()
        packageDirectories.removeAll()
        packageIDsRead = nil
        manifests.removeAll()
        generation &+= 1
    }

    /// The untouched package for a version (the current one unless named).
    static func packageDirectory(for id: String, version: String? = nil) -> URL? {
        let key = version.map { "\(id)/\($0)" } ?? id
        if let cached = packageDirectories[key] { return cached }
        let found = findPackageDirectory(for: id, version: version)
        packageDirectories[key] = found
        return found
    }

    private static func findPackageDirectory(for id: String, version: String?) -> URL? {
        guard let package = package(id) else { return nil }
        if let path = package.unpackedPath {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) ? dir : nil
        }
        let dir = versionsFolder(for: id).appendingPathComponent(version ?? package.version, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) ? dir : nil
    }

    /// Every extension whose package can be read, whichever profiles have it.
    static var packageIDs: [String] {
        if let packageIDsRead { return packageIDsRead }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let found = items.filter { packageDirectory(for: $0) != nil }.sorted()
        packageIDsRead = found
        return found
    }

    static func isUnpacked(_ id: String) -> Bool { package(id)?.unpackedPath != nil }
    static func needsApproval(_ id: String) -> Bool { package(id)?.pendingVersion != nil }

    /// The profiles that have this extension.
    static func profiles(with id: String) -> [Profile] { Profiles.shared.all.filter { $0.installs.hasRecord(id) } }

    /// Sites where all extensions are off. Per profile: the first profile keeps its original key so existing choices stay;
    /// others have their own list, removed with the profile.
    static func extensionsOffSites(in profile: Profile) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ProfileKey.extensionsOffSites.name(in: profile.id)) ?? [])
    }

    static func setExtensionsOffSites(_ sites: Set<String>, in profile: Profile) {
        UserDefaults.standard.set(Array(sites).sorted(), forKey: ProfileKey.extensionsOffSites.name(in: profile.id))
        guard #available(macOS 15.4, *), let host = profile.startedExtensions else { return }
        // Only running profiles; others read the list when they start.
        for id in profile.installs.installedIDs { host.applySiteAccess(id) }
    }

    /// Removing an extension is remembered, so 1Password's automatic setup doesn't bring it back.
    private static var removedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: removedKey) }
    }

    // MARK: The Chrome Web Store

    /// The Chrome version Zigzag gives the store: packages are picked for it, and the store's own button checks an
    /// extension's minimum version against it.
    static let chromeVersion = "157.0"

    static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!
    static let addonsURL = URL(string: "https://addons.mozilla.org/firefox/extensions/")!

    /// The stores Get Extensions offers, in its menu's order.
    enum Shop: CaseIterable {
        case chromeWebStore, firefoxAddons

        var title: String {
            switch self {
            case .chromeWebStore: String(localized: "Chrome Web Store", comment: "Item in the Get Extensions menu: opens the Chrome Web Store.")
            case .firefoxAddons: String(localized: "Firefox Add-ons", comment: "Item in the Get Extensions menu: opens addons.mozilla.org, Mozilla's store of Firefox extensions.")
            }
        }

        var url: URL {
            switch self {
            case .chromeWebStore: ExtensionStore.webStoreURL
            case .firefoxAddons: ExtensionStore.addonsURL
            }
        }
    }

    /// The extension id in a Chrome Web Store page address, e.g. chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh.
    static func webStoreID(from url: URL?) -> String? {
        guard let url, let host = url.host(), host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        let parts = url.pathComponents
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first(where: isExtensionID)
    }

    static func isExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    // MARK: addons.mozilla.org

    /// The AMO site itself: where listings are read and an add-on is added. Its API is a different host, and never
    /// a page.
    nonisolated static func addonsHost(_ host: String) -> Bool {
        host.lowercased() == "addons.mozilla.org"
    }

    /// The listing's slug in an AMO page address: `/en-US/firefox/addon/ublock-origin/reviews/` → `ublock-origin`.
    /// The locale segment is optional, only this store's listing pages count, and a slug is never a path of its own.
    nonisolated static func addonsSlug(from url: URL?) -> String? {
        guard let url, let host = url.host(), addonsHost(host),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let addon = parts.firstIndex(of: "addon"), parts.indices.contains(addon + 1) else { return nil }
        let slug = parts[addon + 1]
        guard !slug.isEmpty, slug != "..", slug != ".",
              slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return slug
    }

    /// Whether a download address is AMO's own file endpoint, which is where an Add to Firefox click hands the package
    /// over. A page on AMO can point a button anywhere; only this store's file path is taken as its package.
    nonisolated static func isAddonsFile(_ url: URL?) -> Bool {
        guard let url, let host = url.host(), addonsHost(host),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else { return false }
        // The locale segment is optional: `/firefox/downloads/…` and `/en-US/firefox/downloads/…` are both the store's.
        let parts = url.pathComponents.filter { $0 != "/" }
        return zip(parts, parts.dropFirst()).contains { $0 == "firefox" && $1 == "downloads" }
    }

    /// Whether a downloaded package is the file the store said it was: AMO publishes each file's sha256, and a
    /// package whose bytes don't match is a different file, never installed.
    nonisolated static func matchesPublishedHash(_ data: Data, sha256: String?) -> Bool {
        // AMO's API writes it as `sha256:<hex>`.
        guard var published = sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        if published.hasPrefix("sha256:") { published.removeFirst("sha256:".count) }
        guard published.count == 64, published.allSatisfy(\.isHexDigit) else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == published
    }

    /// A listing's current file as AMO's API publishes it.
    struct PublishedAddonsFile: Equatable, Sendable {
        let url: URL
        let hash: String
        /// The add-on's ID on AMO, the same across its versions; nil when the API gives none that reads as an ID.
        var guid: String? = nil
    }

    /// An AMO `guid` as an ID: an email-like name or a `{UUID}`, in ASCII, of a sane length.
    nonisolated static func isAddonsGUID(_ guid: String) -> Bool {
        (1...255).contains(guid.count)
            && guid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@.-_{}+".contains($0)) }
    }

    /// `current_version.file` from an AMO API answer; nil unless it names an AMO file URL and a hash.
    nonisolated static func publishedAddonsFile(fromAPI data: Data) -> PublishedAddonsFile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current_version"] as? [String: Any],
              let file = current["file"] as? [String: Any],
              let text = file["url"] as? String, let url = URL(string: text), isAddonsFile(url),
              let hash = file["hash"] as? String, !hash.isEmpty else { return nil }
        let guid = (root["guid"] as? String).flatMap { isAddonsGUID($0) ? $0 : nil }
        return PublishedAddonsFile(url: url, hash: hash, guid: guid)
    }

    /// Whether a download fetched exactly the published file: same https AMO host and path.
    nonisolated static func isPublishedAddonsFile(_ downloaded: URL?, published: URL) -> Bool {
        guard let downloaded, isAddonsFile(downloaded), isAddonsFile(published) else { return false }
        return downloaded.host()?.lowercased() == published.host()?.lowercased() && downloaded.path == published.path
    }

    /// AMO's API address for a listing.
    nonisolated static func addonsAPIURL(slug: String) -> URL? {
        URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/?lang=en-US")
    }

    /// Refuses every redirect, so an AMO API answer comes from the address asked.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let addonsAPISession: URLSession = {
        let configuration = URLSessionConfiguration.cookieless
        // Never an answer kept from an earlier ask: it may name a version the page no longer offers.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The listing's current file, straight from AMO's API: no redirect, and only an https AMO answer counts. Asked
    /// again once when the first ask gets no usable answer.
    @concurrent nonisolated static func publishedAddonsFile(
        slug: String, attempts: Int = 2,
        fetch: @escaping @Sendable (URL) async -> (Data, URLResponse)? = { try? await addonsAPISession.data(from: $0) }
    ) async -> PublishedAddonsFile? {
        guard let url = addonsAPIURL(slug: slug) else { return nil }
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            if let (data, response) = await fetch(url), let file = publishedAddonsFile(fromAPI: data, response: response) { return file }
        }
        return nil
    }

    /// An API answer's file, when the answer is a 200 from https AMO.
    nonisolated static func publishedAddonsFile(fromAPI data: Data, response: URLResponse) -> PublishedAddonsFile? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let answered = http.url, answered.scheme == "https", answered.host()?.lowercased() == "addons.mozilla.org" else { return nil }
        return publishedAddonsFile(fromAPI: data)
    }

    /// A click on an AMO file link from one of the store's listing pages, kept from the click to the file it hands
    /// over, so neither the tab's address nor a later navigation can change what it was (#429).
    struct AddonsClick: Equatable, Sendable {
        let file: URL
        let slug: String

        /// A user-started main-frame navigation to the store's file from a listing; nil for anything else.
        nonisolated init?(target: URL?, page: URL?, userInitiated: Bool) {
            guard userInitiated, let target, ExtensionStore.isAddonsFile(target),
                  let slug = ExtensionStore.addonsSlug(from: page) else { return nil }
            file = target
            self.slug = slug
        }

        /// The clicked file itself (a redirect or query aside, the same AMO file path).
        nonisolated func covers(_ url: URL?) -> Bool {
            guard let url, ExtensionStore.isAddonsFile(url) else { return false }
            return url.path == file.path
        }
    }

    /// What a clicked AMO file becomes, once the API has answered.
    enum AddonsInstall: Equatable, Sendable {
        /// The listing's current file: the install sheet.
        case install(PublishedAddonsFile)
        /// Another file (an older version's Download file): saved as a download, as any file.
        case notCurrent
        /// The API gave no answer: nothing is saved, and a notice says so.
        case unreachable
    }

    nonisolated static func addonsInstall(file: URL?, published: PublishedAddonsFile?) -> AddonsInstall {
        guard let published else { return .unreachable }
        return isPublishedAddonsFile(file, published: published.url) ? .install(published) : .notCurrent
    }

    /// WebKit keeps a service worker background's registration from one launch to the next, and on a later launch
    /// can bring it back without running its script: WebKit says the background loaded, but it never starts, and the
    /// extension's popup waits forever (1Password, from the second launch on). Chrome starts each worker afresh at
    /// launch. WebKit lists no data records for extensions' own origins, so their registrations come out of its
    /// registration files directly, before anything starts WebKit: only rows whose script is an extension's, so
    /// sites keep their workers and extensions keep what they stored. A layout WebKit has changed is left alone, and
    /// the extensions log says so, since backgrounds may then stop starting again.
    ///
    /// Every profile's store holds a folder for each site, often thousands, so at launch it's done off the main thread
    /// (`forgetServiceWorkerRegistrationsInBackground`), and a store being made waits for it.
    nonisolated static func forgetServiceWorkerRegistrationsInBackground(in stores: [URL]) {
        forgetting.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for store in stores { forgetServiceWorkerRegistrations(in: store) }
            forgetting.leave()
        }
    }

    nonisolated private static let forgetting = DispatchGroup()

    /// Before WebKit opens a store: waits for the registrations to be forgotten, a few seconds at most, as it did
    /// before on the main thread at launch. Nothing to wait for once they are.
    nonisolated static func waitForServiceWorkersForgotten() {
        _ = forgetting.wait(timeout: .now() + 3)
    }

    nonisolated static func forgetServiceWorkerRegistrations(in websiteData: URL = defaultWebsiteData) {
        let files = FileManager.default
        for partition in (try? files.contentsOfDirectory(at: websiteData, includingPropertiesForKeys: nil)) ?? [] {
            for origin in (try? files.contentsOfDirectory(at: partition, includingPropertiesForKeys: nil)) ?? [] {
                let folder = origin.appendingPathComponent("ServiceWorkers", isDirectory: true)
                for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
                where name.hasPrefix("ServiceWorkerRegistrations-") && name.hasSuffix(".sqlite3") {
                    var db: OpaquePointer?
                    var cleared = sqlite3_open_v2(folder.appendingPathComponent(name).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
                    // WebKit from the last launch may still be letting go of the file: a moment's wait, not a skip.
                    sqlite3_busy_timeout(db, 2000)
                    cleared = cleared && sqlite3_exec(db, "DELETE FROM Records WHERE scriptURL LIKE 'webkit-extension://%'", nil, nil, nil) == SQLITE_OK
                    if !cleared { ExtensionLog.write("couldn't forget service workers in \(name): \(String(cString: sqlite3_errmsg(db)))") }
                    sqlite3_close(db)
                }
            }
        }
    }

    /// Where WebKit keeps the default website data store's files, service worker registrations among them.
    nonisolated static var defaultWebsiteData: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(Bundle.main.bundleIdentifier ?? "")/WebsiteData/Default", isDirectory: true)
    }

    /// Where WebKit keeps what the extensions of a controller made for an identifier stored (another profile's),
    /// under the identifier in capitals. WebKit empties it on request but never removes it.
    nonisolated static func extensionData(ofController id: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(Bundle.main.bundleIdentifier ?? "")/WebExtensions/\(id.uuidString.uppercased())", isDirectory: true)
    }

    /// Where WebKit keeps the files of a store made for an identifier (another profile's): the same layout, under
    /// the identifier in lowercase.
    nonisolated static func websiteData(ofStore id: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit/\(Bundle.main.bundleIdentifier ?? "")/WebsiteDataStore/\(id.uuidString.lowercased())/Origins", isDirectory: true)
    }

    /// At launch: moves extensions installed by older builds to the untouched layout, loads what's installed,
    /// sets up 1Password when its app is on this Mac, and checks for updates once a day.
    static func setUpIfNeeded() {
        guard #available(macOS 15.4, *) else { return }
        // An extension engine whose extension went while Zigzag was closed: the one you had before.
        ExtensionSearchProvider.reconcile()
        // An extension's proxy applies from the first page on, not from when its background has started again.
        let profile = Profiles.shared.default
        profile.extensions.bridge.proxy.restore()
        Task {
            await migrateLegacyInstalls()
            // An extension that went while Zigzag was closed takes its pin with it.
            profile.installs.pins = profile.installs.pins.keeping(profile.installs.hasRecord)
            await profile.extensions.loadInstalled()
            await checkForUpdatesIfDue()
        }
    }

    // MARK: Installing

    enum InstallError: Error {
        case download, verification, unpack
        /// The store has nothing under its ID any more: taken down, or moved to a new listing.
        case notListed
        /// WebKit couldn't read it as an extension.
        case unsupported
        /// A browser theme and nothing else: Zigzag draws its own look and doesn't apply one (#454).
        case theme
        /// What to tell the person, in plain words.
        var message: String {
            switch self {
            case .download: String(localized: "Couldn’t download this extension. Check your connection and try again.", comment: "Shown when an extension couldn't be installed because its download failed.")
            case .verification: String(localized: "This extension’s package couldn’t be verified, so it wasn’t installed.", comment: "Shown when an extension couldn't be installed because its package didn't pass the signature check.")
            case .unpack: String(localized: "This extension’s package is damaged, so it wasn’t installed.", comment: "Shown when an extension couldn't be installed because its package is damaged.")
            case .notListed: String(localized: "This extension isn’t in the Chrome Web Store any more.", comment: "Shown when an extension couldn't be installed because the Chrome Web Store no longer has it. Chrome Web Store is Google's name.")
            case .unsupported: String(localized: "This extension doesn’t work in Zigzag yet.", comment: "Shown when an extension couldn't be installed because WebKit can't run it.")
            case .theme: String(localized: "This is a browser theme, and Zigzag doesn’t use browser themes. To change how Zigzag looks, choose Edit Space… on a space and pick its colors.", comment: "Shown instead of installing a theme from the Chrome Web Store or Firefox Add-ons. Edit Space… is the item in a space's right-click menu.")
            }
        }
        /// The same, short enough for one line beside the extension's name.
        var reason: String {
            switch self {
            case .download: String(localized: "Couldn’t download it. Check your connection.", comment: "One line beside an extension's name when its update couldn't be downloaded.")
            case .verification: String(localized: "Its package couldn’t be verified.", comment: "One line beside an extension's name when its update didn't pass the signature check.")
            case .unpack: String(localized: "Its package is damaged.", comment: "One line beside an extension's name when its update's package is damaged.")
            case .notListed: String(localized: "Not in the Chrome Web Store any more.", comment: "One line beside an extension's name when the Chrome Web Store no longer has it. Chrome Web Store is Google's name.")
            case .unsupported: String(localized: "Doesn’t work in Zigzag yet.", comment: "One line beside an extension's name when WebKit can't run it.")
            case .theme: String(localized: "A browser theme. Zigzag doesn’t use them.", comment: "One line beside a name, in place of installing it, when it's a browser theme rather than an extension.")
            }
        }
    }

    /// Keys that make a package do something beyond a theme: scripts, a page or popup of its own, or a hook into the
    /// browser. A manifest with a theme and any of these is an extension that also has a theme, and installs.
    nonisolated static let extensionKeys: Set<String> = [
        "background", "content_scripts", "action", "browser_action", "page_action", "options_page", "options_ui",
        "chrome_url_overrides", "devtools_page", "side_panel", "sidebar_action", "omnibox", "commands",
        "declarative_net_request", "user_scripts", "chrome_settings_overrides", "experiment_apis",
    ]

    /// A browser theme and nothing more: Chrome's `theme` or Firefox's `theme` / `theme_experiment`, without
    /// anything an extension runs (#454). The importers skip these too (`ChromiumExtensions`, `OrionImporter`).
    nonisolated static func isThemeOnly(_ manifest: [String: Any]) -> Bool {
        guard manifest["theme"] != nil || manifest["theme_experiment"] != nil else { return false }
        return extensionKeys.isDisjoint(with: manifest.keys)
    }

    /// A verified package, downloaded and unpacked but not installed yet: what the install sheet shows.
    @available(macOS 15.4, *)
    struct PreparedInstall {
        let id: String
        let version: String
        /// Which browser's package this is: it words the sheet and is kept in the record.
        let kind: ExtensionKind
        /// A Firefox package's gecko ID, for the record; nil for a Chrome one.
        let firefoxID: String?
        fileprivate let folder: URL
        let extensionInfo: WKWebExtension
        let report: ExtensionReport
    }

    /// Downloads and verifies a package and reads what it asks for, without installing it.
    @available(macOS 15.4, *)
    static func prepareInstall(_ id: String) async -> Result<PreparedInstall, InstallError> {
        guard isExtensionID(id) else { return .failure(.download) }
        let package: (folder: URL, version: String)
        switch await download(id) {
        case .success(let value): package = value
        case .failure(let error): return .failure(error)
        }
        guard let manifest = manifest(in: package.folder) else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failure(.unpack)
        }
        guard !isThemeOnly(manifest) else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failure(.theme)
        }
        // A sound package WebKit still can't read (an app, a manifest it doesn't know) won't run here.
        guard let ext = try? await WKWebExtension(resourceBaseURL: package.folder) else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failure(.unsupported)
        }
        let report = ExtensionReport(extension: ext, manifest: manifest, id: id)
        return .success(PreparedInstall(id: id, version: package.version, kind: .chromium, firefoxID: nil,
                                        folder: package.folder, extensionInfo: ext, report: report))
    }

    /// Prepares a Firefox package (.xpi) the person chose: read with the package rules, unpacked to a staging
    /// folder, its manifest written into the shape WebKit loads, and only then handed to WebKit to verify, without
    /// installing it. The kind and gecko ID come with it, for the record an install keeps.
    @available(macOS 15.4, *)
    static func prepareInstallXPI(at url: URL) async -> Result<PreparedInstall, InstallError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unpack) }
        return await prepareInstallXPI(data: data)
    }

    /// The same, from bytes already read, so bytes that were checked are the bytes unpacked.
    /// `storeID` is AMO's guid for a package from Add to Firefox: one with no gecko ID of its own is named by it, so
    /// each version of it is the same record.
    @available(macOS 15.4, *)
    static func prepareInstallXPI(data: Data, storeID: String? = nil) async -> Result<PreparedInstall, InstallError> {
        guard let package = try? XPIPackage(data) else { return .failure(.unpack) }
        guard !isThemeOnly(package.manifest) else { return .failure(.theme) }
        let geckoID = package.firefoxID ?? storeID.flatMap { isAddonsGUID($0) ? $0 : nil }
        let id = xpiID(forGeckoID: geckoID, data: data)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("\(xpiStagingPrefix)\(UUID().uuidString)")
        do {
            try package.unpack(into: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
        // The copy WebKit loads is one written for it. The package's own manifest is never touched, and one WebKit
        // couldn't read as it came (not UTF-8, say) is rescued by the rewrite rather than refused.
        let normalized = FirefoxManifest.normalized(package.manifest)
        // Firefox's own version grammar, not Chrome's: a package with letters in its version isn't damaged. The
        // version names the folder it's kept in, so it still has to be a safe name.
        guard let version = normalized["version"] as? String, isValidFirefoxVersion(version) else {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
        // WebKit runs Manifest V2 and V3. A package declaring another version is not one it can run, whatever its
        // parser makes of the manifest.
        guard [2, 3].contains((normalized["manifest_version"] as? NSNumber)?.intValue ?? 2) else {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unsupported)
        }
        guard writeManifest(normalized, in: staging) else {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
        // The rewritten copy is what WebKit will load: if it can't read it, the package won't run here.
        guard let ext = try? await WKWebExtension(resourceBaseURL: staging) else {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unsupported)
        }
        let report = ExtensionReport(extension: ext, manifest: normalized, id: id, firefox: true)
        return .success(PreparedInstall(id: id, version: version, kind: .firefox, firefoxID: geckoID,
                                        folder: staging, extensionInfo: ext, report: report))
    }

    /// The folder a Firefox package is unpacked into while it's prepared and verified, before it's installed.
    private static let xpiStagingPrefix = "zigzag-xpi-"

    /// The 32-character ID a Firefox package installs as. Its gecko ID names it to Firefox and to us: hashed, so the
    /// same extension from any folder is the same record. One with no gecko ID is named by its bytes, so the same
    /// file at two paths is still one record. Chrome's own alphabet (a–p), which `isExtensionID` and the rest of the
    /// store assume.
    static func xpiID(forGeckoID geckoID: String?, data: Data) -> String {
        CRXPackage.extensionID(Array(SHA256.hash(data: Data((geckoID ?? Self.bytesKey(for: data)).utf8)).prefix(16)))
    }

    /// A package's bytes as a stable string: SHA-256, hex, for an XPI whose manifest names no gecko ID.
    private static func bytesKey(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the normalized manifest over the extracted one in staging. False if it won't write.
    private static func writeManifest(_ manifest: [String: Any], in folder: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else { return false }
        return (try? data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)) != nil
    }

    /// Installs a prepared package in a profile and loads it there. Returns its name.
    @available(macOS 15.4, *)
    static func finishInstall(_ prepared: PreparedInstall, in profile: Profile) async -> Result<String, InstallError> {
        let id = prepared.id
        let installs = profile.installs
        let isNew = !installs.hasRecord(id)
        guard store((prepared.folder, prepared.version), for: id) else { return .failure(.unpack) }
        // A package already here keeps its own kind when this one is a Chrome install for the same ID; a legacy
        // record's absent kind reads as Chrome's, and its gecko ID is kept when this package doesn't name one.
        let existing = package(id)
        let kind = prepared.kind == .firefox ? ExtensionKind.firefox
            : (existing.flatMap { ExtensionKind(rawValue: $0.kind) } ?? .chromium)
        save(Package(version: prepared.version, kind: kind.rawValue,
                     firefoxID: prepared.firefoxID ?? existing.flatMap(\.firefoxID)), for: id)
        var next = installs.state(id) ?? ExtensionInstalls.State()
        // Approved just now, from what the sheet showed.
        next.grantedPermissions = nil
        next.grantedMatchPatterns = nil
        installs.save(next, for: id)
        removedIDs.remove(id)
        removeVersions(of: id, keeping: [prepared.version])
        if isNew { installs.newlyInstalled.insert(id) }
        // A new version of the package is every profile's: each one running it starts again on it.
        var context: WKWebExtensionContext?
        for other in profiles(with: id) where other === profile || other.installs.isEnabled(id) {
            other.extensions.unload(id)
            let loaded = await other.extensions.load(id)
            if other === profile { context = loaded }
        }
        return .success(context?.webExtension.displayName ?? prepared.extensionInfo.displayName ?? id)
    }

    /// Adds an extension Zigzag already has the package of (another profile's) to a profile: on, allowed what it is
    /// there and on the same sites, with nothing it stored elsewhere.
    @available(macOS 15.4, *)
    static func add(_ id: String, to profile: Profile) async {
        guard packageDirectory(for: id) != nil, !profile.installs.hasRecord(id),
              let source = profiles(with: id).first(where: { $0 !== profile })?.installs.state(id) else { return }
        profile.installs.save(source.carried(enabled: true), for: id)
        profile.installs.newlyInstalled.insert(id)
        await profile.extensions.load(id)
        ExtensionCenter.noteChanged()
    }

    @available(macOS 15.4, *)
    static func discard(_ prepared: PreparedInstall) {
        try? FileManager.default.removeItem(at: prepared.folder)
    }

    /// Downloads, verifies and loads an extension you picked (in onboarding).
    static func install(_ id: String, in profile: Profile) async -> Result<String, InstallError> {
        guard #available(macOS 15.4, *) else { return .failure(.download) }
        switch await prepareInstall(id) {
        case .success(let prepared): return await finishInstall(prepared, in: profile)
        case .failure(let error): return .failure(error)
        }
    }

    /// What a held-back update would add, for the approval sheet.
    @available(macOS 15.4, *)
    static func pendingUpdateReport(_ id: String) async -> (extension: WKWebExtension, report: ExtensionReport)? {
        guard let pending = package(id)?.pendingVersion, let new = packageDirectory(for: id, version: pending),
              let old = packageDirectory(for: id), let newManifest = manifest(in: new), let oldManifest = manifest(in: old),
              let ext = try? await WKWebExtension(resourceBaseURL: new) else { return nil }
        return (ext, ExtensionReport(newIn: ext, manifest: newManifest, comparedTo: oldManifest, id: id))
    }

    /// The ID of an extension read from a folder: from the folder's path, the way Chrome makes it, so loading the
    /// same folder again keeps its data.
    static func unpackedID(for url: URL) -> String {
        CRXPackage.extensionID(Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16)))
    }

    /// What an extension in a folder asks for, for the same sheet a store package shows before it's added. Nil when
    /// the folder holds nothing WebKit can read (loading it then says so). A folder carrying Firefox's own keys is
    /// worded from Firefox's overlay, as its record will be.
    @available(macOS 15.4, *)
    static func reviewUnpacked(_ url: URL) async -> (extension: WKWebExtension, report: ExtensionReport)? {
        guard let manifest = manifest(in: url), let ext = try? await WKWebExtension(resourceBaseURL: url) else { return nil }
        return (ext, ExtensionReport(extension: ext, manifest: manifest, id: unpackedID(for: url)))
    }

    /// A folder holding a browser theme and nothing more (#454), refused before its review sheet.
    static func folderIsThemeOnly(_ url: URL) -> Bool {
        manifest(in: url).map(isThemeOnly) ?? false
    }

    /// Loads an unpacked extension (Install from Folder, or bundled in an app) in place, never modified. Settings reviews
    /// its permissions first (`reviewUnpacked`).
    static func loadUnpacked(_ url: URL, in profile: Profile) async -> String? {
        guard #available(macOS 15.4, *),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        let id = unpackedID(for: url)
        if !profile.installs.hasRecord(id) { profile.installs.newlyInstalled.insert(id) }
        save(unpackedPackage(for: url), for: id)
        // Loaded again from its folder, it starts as a new install would: on, with what it asks for approved afresh.
        profile.installs.save(ExtensionInstalls.State(), for: id)
        removedIDs.remove(id)
        let context = await profile.extensions.load(id)
        return context?.webExtension.displayName
    }

    /// The record for a folder: always Chrome's. Firefox's keys in a manifest don't make it Firefox, since many
    /// cross-browser builds carry them; only an .xpi install is. The folder is the person's, read where it is.
    static func unpackedPackage(for url: URL) -> Package {
        Package(version: manifestVersion(in: url) ?? "0", unpackedPath: url.standardizedFileURL.path)
    }

    /// Re-reads an unpacked extension's files, in every profile running it.
    static func reloadUnpacked(_ id: String) async {
        guard #available(macOS 15.4, *), isUnpacked(id) else { return }
        // Its folder is the developer's: whatever they changed in it is read again.
        forgetWhatWasRead()
        for profile in profiles(with: id) where profile.installs.isEnabled(id) {
            profile.extensions.unload(id)
            await profile.extensions.load(id)
        }
    }

    /// Fetches, verifies and unpacks a package into a fresh temporary folder.
    private static func download(_ id: String) async -> Result<(folder: URL, version: String), InstallError> {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            .init(name: "response", value: "redirect"),
            .init(name: "prodversion", value: chromeVersion),
            .init(name: "acceptformat", value: "crx3"),
            .init(name: "x", value: "id=\(id)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await fetch(url) else { return .failure(.download) }
        let status = (response as? HTTPURLResponse)?.statusCode
        // The store answers an ID it doesn't have with nothing at all.
        if status == 404 || status == 204 { return .failure(.notListed) }
        guard status == 200, let data else { return .failure(.download) }
        // Checking the signature over the whole package and unpacking it take a moment: off the main thread.
        return await Task.detached(priority: .userInitiated) { unpack(data, id: id) }.value
    }

    /// Far above the store's largest packages (a few hundred MB).
    nonisolated static let maxPackageBytes = 512 << 20

    /// Package bytes, or nil past `limit`, so a server can't exhaust memory. `@concurrent`: reading a few hundred MB byte
    /// by byte must stay off the main actor.
    @concurrent nonisolated static func fetch(_ url: URL, limit: Int = maxPackageBytes, session: URLSession = .cookieless) async throws -> (Data?, URLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > Int64(limit) { bytes.task.cancel(); return (nil, response) }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                guard data.count + chunk.count <= limit else { bytes.task.cancel(); return (nil, response) }
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        guard data.count + chunk.count <= limit else { return (nil, response) }
        data.append(contentsOf: chunk)
        return (data, response)
    }

    nonisolated private static func unpack(_ data: Data, id: String) -> Result<(folder: URL, version: String), InstallError> {
        guard let package = try? CRXPackage(data, expectedID: id) else { return .failure(.verification) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-ext-\(UUID().uuidString)")
        guard extract(package.zip, into: staging), let version = manifestVersion(in: staging) else {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
        return .success((staging, version))
    }

    /// Unzips a package into a new folder, and keeps it only if every entry is a plain file or folder inside it: a
    /// link in the package (to a file elsewhere on the Mac) would let the extension read that file as its own, and a
    /// name climbing out of the folder would write somewhere else entirely. PackageZip checks every entry before it
    /// writes anything; the folder is looked over once more after.
    nonisolated static func extract(_ zipFile: URL, into folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: zipFile) else { return false }
        return extract(data, into: folder)
    }

    nonisolated static func extract(_ zip: Data, into folder: URL) -> Bool {
        do {
            try PackageZip.unpack(zip, into: folder)
            guard holdsOnlyItsOwnFiles(folder) else {
                try? FileManager.default.removeItem(at: folder)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
    }

    /// Whether everything in the folder is a plain file or folder of its own: no symbolic link, no hard link shared
    /// with a file elsewhere, nothing that resolves outside it.
    nonisolated static func holdsOnlyItsOwnFiles(_ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in false }) else { return false }
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true,
                  url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { return false }
            if values.isRegularFile == true {
                let links = (try? FileManager.default.attributesOfItem(atPath: url.path)[.referenceCount] as? Int) ?? 0
                guard links == 1 else { return false }
            }
        }
        return true
    }

    /// Moves a downloaded package into its version folder.
    private static func store(_ package: (folder: URL, version: String), for id: String) -> Bool {
        let target = versionsFolder(for: id).appendingPathComponent(package.version, isDirectory: true)
        defer { forgetWhatWasRead() }
        do {
            try FileManager.default.createDirectory(at: versionsFolder(for: id), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: package.folder)
            } else {
                try FileManager.default.moveItem(at: package.folder, to: target)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: package.folder)
            return false
        }
    }

    /// The current version's manifest, as Zigzag keeps it: a Chrome package's own, untouched, or a Firefox package's
    /// the normalized copy written at extract time (its MV3 host patterns moved to `host_permissions`, which WebKit
    /// reads, and its background replaced by the generated worker). Read once per version.
    static func manifest(for id: String) -> [String: Any]? {
        if let cached = manifests[id] { return cached }
        let read = packageDirectory(for: id).flatMap(manifest(in:))
        reads += 1
        manifests[id] = .some(read)
        return read
    }

    /// What the extension asked for in its stored manifest: the API permission names in `permissions` and
    /// `optional_permissions`. WebKit's own loaded copy of the manifest may differ — Zigzag's bridge adds native
    /// messaging to it. Read once per version.
    static func declaredPermissions(_ id: String) -> (required: Set<String>, optional: Set<String>) {
        let version = package(id)?.version ?? ""
        if let cached = declaredCache[id], cached.version == version { return (cached.required, cached.optional) }
        let manifest = manifest(for: id) ?? [:]
        let required = Set(manifest["permissions"] as? [String] ?? []), optional = Set(manifest["optional_permissions"] as? [String] ?? [])
        declaredCache[id] = (version, required, optional)
        return (required, optional)
    }

    private static var declaredCache: [String: (version: String, required: Set<String>, optional: Set<String>)] = [:]

    nonisolated private static func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func manifestVersion(in folder: URL) -> String? {
        guard let version = manifest(in: folder)?["version"] as? String, isValidVersion(version) else { return nil }
        return version
    }

    /// A Chrome version: one to four dot-separated numbers up to 65535. It names a folder, so ".", ".." and separators
    /// can't get through.
    nonisolated static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { part in
            (1...5).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part) ?? .max) <= 65535
        }
    }

    /// A version as a Firefox package declares it. Firefox's grammar allows letters and punctuation (`1.0.0b1`,
    /// `2024.1-beta`), which Chrome's own grammar refuses, so a package isn't called damaged over one. The version
    /// names the folder it's kept in, so it still has to be a safe name: non-empty, at most 64 characters, starting
    /// with a letter or a digit, then only letters, digits and `.`, `_`, `+`, `-`, and never `..`.
    nonisolated static func isValidFirefoxVersion(_ version: String) -> Bool {
        guard (1...64).contains(version.count), !version.contains(".."),
              let first = version.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    private static func removeVersions(of id: String, keeping keep: [String]) {
        let folder = versionsFolder(for: id)
        defer { forgetWhatWasRead() }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Updating

    /// What checking one extension came to.
    enum UpdateOutcome: Equatable { case upToDate, updated, waitingForApproval, failed }

    /// What checking every extension came to, said in Settings › Extensions (#406).
    struct UpdateCheck: Equatable {
        var checked = 0
        var updated = 0
        /// Extensions whose update asks for more access, in the order checked.
        var waiting: [String] = []
        var failed = 0

        mutating func add(_ outcome: UpdateOutcome, for id: String) {
            checked += 1
            switch outcome {
            case .upToDate: break
            case .updated: updated += 1
            case .waitingForApproval: waiting.append(id)
            case .failed: failed += 1
            }
        }

        var summary: String {
            guard checked > 0 else { return String(localized: "No extensions from the Chrome Web Store to check.", comment: "Toast after Check for Updates in Settings › Extensions when only extensions from a folder are installed.") }
            var parts: [String] = []
            if updated > 0 { parts.append(String(localized: "Updated \(updated) extensions.", comment: "Toast after Check for Updates in Settings › Extensions: how many extensions were updated.")) }
            if !waiting.isEmpty { parts.append(String(localized: "\(waiting.count) updates need your approval.", comment: "Toast after Check for Updates in Settings › Extensions: how many updates ask for more access and wait for you.")) }
            if failed > 0 { parts.append(String(localized: "Couldn’t check \(failed) extensions.", comment: "Toast after Check for Updates in Settings › Extensions: how many extensions the Chrome Web Store didn't answer for.")) }
            return parts.isEmpty ? String(localized: "All extensions are up to date.", comment: "Toast after Check for Updates in Settings › Extensions when nothing changed.") : parts.joined(separator: " ")
        }
    }

    /// The check under way, so a second one waits for it instead of downloading the same updates again.
    private static var checking: Task<UpdateCheck, Never>?

    /// Checks every installed extension for a new version, at most once a day unless `force`d.
    @discardableResult
    static func checkForUpdatesIfDue(force: Bool = false) async -> UpdateCheck {
        if let checking { return await checking.value }
        let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 24 * 3600 else { return UpdateCheck() }
        UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
        let task = Task { @MainActor in
            var check = UpdateCheck()
            for id in updateCandidates(packageIDs) { check.add(await updateIfNewer(id), for: id) }
            return check
        }
        checking = task
        let check = await task.value
        checking = nil
        return check
    }

    /// Which records the store is asked about: packages the store delivered. A Firefox one came from a file, and an
    /// unpacked one is the person's own folder, read where it is.
    static func updateCandidates(_ ids: [String]) -> [String] {
        ids.filter { id in
            let record = package(id)
            return record?.unpackedPath == nil && record.flatMap { ExtensionKind(rawValue: $0.kind) } == .chromium
        }
    }

    /// Asks the store for the latest version only; downloads it when it's newer. An update that asks for
    /// nothing new replaces the running version; one that asks for more waits for approval.
    @discardableResult
    static func updateIfNewer(_ id: String) async -> UpdateOutcome {
        // A Firefox package came from a file, not the Chrome Web Store: its ID names no listing there, so it is not
        // asked, and nothing pretends a check happened.
        guard kind(of: id) == .chromium else { return .upToDate }
        guard #available(macOS 15.4, *), let current = package(id) else { return .failed }
        guard let latest = await latestVersion(of: id, current: current.version) else { return .failed }
        guard isVersion(latest, newerThan: current.version) else { return .upToDate }
        guard latest != current.pendingVersion else { return .waitingForApproval }
        guard case .success(let package) = await download(id) else { return .failed }
        // Package must match the store's version; never accept an older one.
        guard package.version == latest else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failed
        }
        guard store(package, for: id), let old = packageDirectory(for: id), let new = packageDirectory(for: id, version: package.version) else { return .failed }
        if asksForMore(new, than: old) {
            update(id) { $0.pendingVersion = package.version }
            ExtensionCenter.noteChanged()
            return .waitingForApproval
        }
        return await switchVersion(of: id, to: package.version) ? .updated : .failed
    }

    /// Approves a held-back update: its new permissions are granted and it replaces the running version.
    static func approvePendingUpdate(_ id: String) async {
        guard let pending = package(id)?.pendingVersion else { return }
        update(id) { $0.pendingVersion = nil }
        for profile in profiles(with: id) {
            profile.installs.update(id) {
                // Re-recorded from the new version's request on load.
                $0.grantedPermissions = nil
                $0.grantedMatchPatterns = nil
            }
        }
        await switchVersion(of: id, to: pending)
    }

    /// Makes a version current and reloads the extension with it, going back to the old one if it won't load. True
    /// when the new version runs.
    @discardableResult
    private static func switchVersion(of id: String, to version: String) async -> Bool {
        guard #available(macOS 15.4, *), let previous = package(id)?.version else { return false }
        update(id) { $0.version = version; $0.pendingVersion = nil }
        // Every profile running it moves to the new version together; if one can't load it, all go back.
        let running = profiles(with: id).filter { $0.installs.isEnabled(id) }
        var loadedEverywhere = true
        for profile in running {
            profile.extensions.unload(id)
            if await profile.extensions.load(id) == nil { loadedEverywhere = false; break }
        }
        if loadedEverywhere {
            removeVersions(of: id, keeping: [version])
        } else {
            update(id) { $0.version = previous }
            for profile in running {
                profile.extensions.unload(id)
                await profile.extensions.load(id)
            }
        }
        // A version that no longer gives a search engine gives back the one you had.
        ExtensionSearchProvider.reconcile()
        return loadedEverywhere
    }

    private static func latestVersion(of id: String, current: String) async -> String? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            .init(name: "response", value: "updatecheck"),
            .init(name: "prodversion", value: chromeVersion),
            .init(name: "acceptformat", value: "crx3"),
            .init(name: "x", value: "id=\(id)&v=\(current)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await URLSession.cookieless.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let xml = String(data: data, encoding: .utf8) else { return nil }
        return latestVersion(inUpdateCheck: xml, current: current)
    }

    /// The store's answer: its version, `current` when it has nothing newer, nil when it gave neither (an
    /// extension it no longer lists, an error).
    nonisolated static func latestVersion(inUpdateCheck xml: String, current: String) -> String? {
        guard let check = xml.range(of: "<updatecheck[^>]*>", options: .regularExpression) else { return nil }
        let tag = String(xml[check])
        if tag.contains("status=\"noupdate\"") { return current }
        guard tag.contains("status=\"ok\""), let version = tag.range(of: "version=\"[^\"]+\"", options: .regularExpression) else { return nil }
        return String(tag[version].dropFirst("version=\"".count).dropLast())
    }

    /// Chrome versions are up to four dot-separated numbers.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// True when a new version requests permissions or sites the old one didn't.
    private static func asksForMore(_ new: URL, than old: URL) -> Bool {
        guard let newManifest = manifest(in: new) else { return true }
        return asksForMore(newManifest, than: manifest(in: old) ?? [:])
    }

    /// True when the new manifest adds permissions or sites, or changes an override: search engine, home page, Zigzag
    /// pages, or externally_connectable. A changed search URL could redirect your searches.
    static func asksForMore(_ new: [String: Any], than old: [String: Any]) -> Bool {
        func requested(_ manifest: [String: Any]) -> Set<String> {
            let keys = ["permissions", "host_permissions", "optional_permissions", "optional_host_permissions"]
            return Set(keys.flatMap { manifest[$0] as? [String] ?? [] })
        }
        if !requested(new).isSubset(of: requested(old)) { return true }
        for key in ["chrome_settings_overrides", "chrome_url_overrides", "externally_connectable"] {
            guard let added = new[key] else { continue }
            guard let before = old[key], (added as AnyObject).isEqual(before) else { return true }
        }
        return false
    }

    // MARK: Removing

    /// Takes the extension out of a profile and deletes everything it stored there. Its files go once no profile
    /// has it.
    static func uninstall(_ id: String, from profile: Profile) {
        guard #available(macOS 15.4, *) else { return }
        let unpacked = isUnpacked(id)
        profile.installs.unpin(id)
        profile.extensions.unload(id)
        profile.extensions.removeData(for: id)
        let wasTheLast = profiles(with: id).allSatisfy { $0 === profile }
        profile.installs.remove(id)
        if wasTheLast {
            // An unpacked extension's own folder belongs to its developer; only our record of it goes.
            try? FileManager.default.removeItem(at: folder(for: id))
            if !unpacked { removedIDs.insert(id) }
            forgetWhatWasRead()
        }
        profile.extensions.forget(id)
        // Only now is it gone from disk: removing a password manager brings back the passkey fallback.
        Passkeys.refresh()
        ExtensionSearchProvider.reconcile()
    }

    // MARK: Older installs

    /// Builds before this one unpacked straight into Extensions/<id>/ and edited the package to load a shim.
    /// Those get a fresh, verified copy from the store. Offline, the edit is undone in place instead.
    private static func migrateLegacyInstalls() async {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "DisabledExtensions") ?? [])
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where isExtensionID(id) {
            let legacy = folder(for: id)
            guard package(id) == nil, FileManager.default.fileExists(atPath: legacy.appendingPathComponent("manifest.json").path) else { continue }
            let moved = root.appendingPathComponent(".legacy-\(id)-\(UUID().uuidString)")
            guard (try? FileManager.default.moveItem(at: legacy, to: moved)) != nil else { continue }
            if case .success(let package) = await download(id), store(package, for: id) {
                try? FileManager.default.removeItem(at: moved)
                save(Package(version: package.version), for: id)
                Profiles.shared.default.installs.save(ExtensionInstalls.State(enabled: !disabled.contains(id)), for: id)
            } else if let version = manifestVersion(in: moved) {
                undoLegacyPatch(in: moved)
                try? FileManager.default.createDirectory(at: versionsFolder(for: id), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: moved, to: versionsFolder(for: id).appendingPathComponent(version))
                save(Package(version: version), for: id)
                Profiles.shared.default.installs.save(ExtensionInstalls.State(enabled: !disabled.contains(id)), for: id)
            } else {
                try? FileManager.default.moveItem(at: moved, to: legacy)
            }
        }
        UserDefaults.standard.removeObject(forKey: "DisabledExtensions")
        UserDefaults.standard.removeObject(forKey: "OnePasswordExtensionUpdated")
        forgetWhatWasRead()
    }

    private static func undoLegacyPatch(in folder: URL) {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = manifest(in: folder), var background = manifest["background"] as? [String: Any],
              let original = background["zigzag_original_worker"] as? String else { return }
        background["service_worker"] = original
        background["zigzag_original_worker"] = nil
        manifest["background"] = background
        if let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) { try? out.write(to: manifestURL) }
        for name in ["zigzag-background.js", "zigzag-shim.js"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        forgetWhatWasRead()
    }
}

/// Per-extension adjustments the host applies, never by editing the package.
enum ExtensionShims {
    struct Shim {
        /// `browser.*` paths hidden from the extension, so it takes its own fallback instead of calling into nothing.
        var unsupportedAPIs: Set<String> = []
        /// Script run in the background before the extension's own, for APIs it calls without checking.
        var backgroundPrelude: String?
        /// The same, for the extension's own pages (popup, options), run before any of their scripts.
        var pagePrelude: String?
        /// Permissions the prelude stands in for well enough that the person won't miss them.
        var coveredPermissions: Set<String> = []
        /// Small fixes to the extension's own files where it misbehaves in WebKit, applied to a copy at load.
        var patches: [Patch] = []
        /// Whether every patch must fit. False applies the ones that do; true leaves the files alone when one doesn't,
        /// so a newer extension version never gets half a fix.
        var patchesTogether = false
        /// What's known not to work, said before installing ("its popup").
        var knownIssue: String?
    }

    /// Replace `find` with `replace` in one of the extension's files. Skipped, and logged, if `find` isn't there
    /// (a newer version that changed), so an update never breaks on an old fix.
    /// With `pattern`, `find` is a regular expression and `replace` its template (`$1`): for code whose short
    /// names change from one build to the next (Tampermonkey's beta), so the fix holds across them.
    struct Patch {
        let file: String
        let find: String
        let replace: String
        var pattern = false
    }

    /// Every extension gets the compatibility layer first; some get their own fixes on top.
    /// `keepsAlive`: whether the background keeps itself awake (service worker or persistent page). MV2 event pages may
    /// suspend, so their prelude skips it.
    static func shim(for id: String, keepsAlive: Bool = true) -> Shim? {
        var shim = shims[id] ?? Shim()
        // An unpacked copy has an identifier from where it was loaded: its files say it's OldTwitter.
        if shim.patches.isEmpty, let manifest = ExtensionStore.manifest(for: id), OldTwitterSolver.isOldTwitter(id: id, manifest: manifest) {
            shim.patches = oldTwitterPatches
            shim.patchesTogether = true
        }
        // firefox-polyfill.js adds Firefox's two runtime members only to a Firefox package. The installed record's
        // kind says which that is, and the marker below is what the shim reads; the manifest can't decide it, since a
        // Chrome Web Store package may carry browser_specific_settings too.
        let firefox = ExtensionStore.kind(of: id) == .firefox
        let marker = firefox ? "globalThis.__zigzagFirefoxPackage = true;\n" : ""
        shim.backgroundPrelude = marker + backgroundPrelude(keepsAlive: keepsAlive) + (shim.backgroundPrelude ?? "")
        #if DEBUG
        // Testing builds say each background got past Zigzag's own scripts, so a quiet log means quiet, not broken.
        let started = "try { (globalThis.chrome || globalThis.browser).runtime.sendNativeMessage('\(diagnosticsHost)', { where: 'background', kind: 'started', text: 'ok' }); } catch (e) {}\n"
        shim.backgroundPrelude = errorRecorder + (shim.backgroundPrelude ?? "") + started
        #endif
        return shim
    }

    /// Runs before every background's own code: error reporting first (so a crash on start says why), then the bridge,
    /// stand-ins for missing APIs, and the WebSocket shim. The shim steps aside in background pages, which have real
    /// WebSockets; only service workers may open Zigzag's socket port (`usesWebSocketShim`).
    ///
    /// `keepsAlive`: service workers and persistent MV2 pages keep a port open and answer heartbeats so WebKit doesn't
    /// stop them; MV2 event pages (`persistent: false`) must be allowed to suspend.
    static func backgroundPrelude(keepsAlive: Bool) -> String {
        let base = diagnostics + ExtensionBridgeScript.source + "\n" + compatibility + "\n" + ExtensionBridgeScript.afterCompatibility + "\n" + webSocketShim + "\n"
        return keepsAlive ? base + nativeKeepAlive + "\n" : base
    }

    /// Whether a background stays running. Chrome keeps service workers and MV2 pages running; event pages
    /// (`persistent: false`) suspend.
    static func keepsAlive(manifest: [String: Any]?) -> Bool {
        guard let background = manifest?["background"] as? [String: Any] else { return false }
        if background["service_worker"] is String { return true }
        guard background["page"] is String || background["scripts"] is [String] else { return false }
        return (background["persistent"] as? Bool) != false
    }

    #if DEBUG
    /// Testing builds: a background's uncaught errors, kept in its own storage under "__zigzagErrors", for
    /// reading back from one of its pages.
    static let errorRecorder = """
    (() => {
      const api = globalThis.chrome || globalThis.browser;
      if (!api || !api.storage || !api.storage.local) return;
      const keep = (text) => { try { api.storage.local.get('__zigzagErrors', (o) => { const list = (o && o.__zigzagErrors) || []; list.push(String(text).slice(0, 300)); api.storage.local.set({ __zigzagErrors: list.slice(-30) }); }); } catch (e) {} };
      globalThis.addEventListener && globalThis.addEventListener('error', (e) => keep('error: ' + e.message + ' @ ' + String(e.filename || '').split('/').pop() + ':' + e.lineno));
      globalThis.addEventListener && globalThis.addEventListener('unhandledrejection', (e) => keep('rejection: ' + ((e.reason && (e.reason.message || e.reason)) || '')));
      keep('started ' + new Date().toISOString());
    })();

    """
    #endif

    /// Chrome APIs WebKit doesn't have. An extension that asked for one (in its manifest) and calls it without
    /// checking would stop dead on its first line, its popup waiting forever on a background that never started.
    /// So for those, and only those, a stand-in that does nothing harmful: empty answers, quiet no-ops, or a
    /// clear "not available" where it must act. Extensions that check first still take their own path.
    static let compatibility = """
    (() => {
      // As the bridge does: an extension page may get its `chrome` a moment after this runs.
      const start = () => {
      const api = globalThis.chrome || globalThis.browser;
      if (globalThis.__zigzagCompat) return true;
      if (!api || !api.runtime) return false;
      globalThis.__zigzagCompat = true;
      const held = (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []);
      const noop = () => {};
      const event = () => ({ addListener: noop, removeListener: noop, hasListener: () => false, hasListeners: () => false });
      const done = (value) => (...args) => { const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null; if (cb) { setTimeout(() => cb(value), 0); return; } return Promise.resolve(value); };
      const no = (what) => (...args) => { const cb = typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null; const e = new Error(what + " isn't available in Zigzag"); if (cb) { setTimeout(() => cb(undefined), 0); return; } return Promise.reject(e); };
      let manifest = {};
      try { manifest = api.runtime.getManifest() || {}; } catch (e) {}
      const asked = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);
      // WebKit names some of these with nothing behind them, so `in` isn't enough and plain assignment fails quietly.
      const add = (name, value) => { if (asked.has(name) && api[name] == null) { try { Object.defineProperty(api, name, { value, configurable: true, enumerable: true, writable: true }); held.push(value); } catch (e) {} } };
      const fill = (name, values) => { const target = api[name]; if (!target) return; held.push(target); for (const [k, v] of Object.entries(values)) { if (!(k in target)) { try { target[k] = v; } catch (e) {} } } };
      // Missing calls on namespaces WebKit does have: often called unconditionally.
      fill('action', { setBadgeTextColor: done(), getBadgeTextColor: done([0, 0, 0, 255]), getUserSettings: done({ isOnToolbar: true }) });
      fill('tabs', { group: no('Tab groups'), ungroup: done(), discard: done(), highlight: done(), TAB_ID_NONE: -1 });
      fill('windows', { WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2 });
      // getContexts is the bridge's, with the real answer: an always-empty one ("no popup
      // open") sends some (Bitwarden) into a loop asking again.
      const names = (list, form = (n) => n.toLowerCase()) => Object.freeze(Object.fromEntries(list.map((n) => [n, form(n)])));
      fill('runtime', { onSuspend: event(), onSuspendCanceled: event(), onUpdateAvailable: event(), onRestartRequired: event(),
        OnInstalledReason: names(['INSTALL', 'UPDATE', 'CHROME_UPDATE', 'SHARED_MODULE_UPDATE']),
        ContextType: names(['TAB', 'POPUP', 'BACKGROUND', 'OFFSCREEN_DOCUMENT', 'SIDE_PANEL', 'DEVELOPER_TOOLS'], (n) => n) });
      // Chrome's names for the values declarativeNetRequest rules use; WebKit takes the values, not always the names.
      const camel = (n) => n.toLowerCase().replace(/_([a-z])/g, (_, c) => c.toUpperCase());
      fill('declarativeNetRequest', {
        HeaderOperation: names(['APPEND', 'SET', 'REMOVE']),
        RuleActionType: names(['BLOCK', 'REDIRECT', 'ALLOW', 'UPGRADE_SCHEME', 'MODIFY_HEADERS', 'ALLOW_ALL_REQUESTS'], camel),
        ResourceType: names(['MAIN_FRAME', 'SUB_FRAME', 'STYLESHEET', 'SCRIPT', 'IMAGE', 'FONT', 'OBJECT', 'XMLHTTPREQUEST', 'PING', 'CSP_REPORT', 'MEDIA', 'WEBSOCKET', 'WEBTRANSPORT', 'WEBBUNDLE', 'OTHER']),
      });
      fill('i18n', { detectLanguage: done({ isReliable: false, languages: [] }) });
      fill('storage', { managed: { get: done({}), getBytesInUse: done(0), onChanged: event() } });
      // WebKit refuses a whole set of rules when one names a header it doesn't know (Claude sets its own on its API
      // calls). As close to Chrome as it gets: the unknown header is left out and the rest of the rules still apply.
      const dnr = api.declarativeNetRequest;
      if (dnr) for (const fn of ['updateSessionRules', 'updateDynamicRules']) {
        const native = dnr[fn] && dnr[fn].bind(dnr);
        if (!native) continue;
        const without = (options, header) => Object.assign({}, options, { addRules: (options.addRules || []).map((rule) => {
          const action = rule.action || {};
          const keep = (list) => list && list.filter((h) => String(h.header).toLowerCase() !== header);
          return Object.assign({}, rule, { action: Object.assign({}, action, { requestHeaders: keep(action.requestHeaders), responseHeaders: keep(action.responseHeaders) }) });
        }).filter((rule) => (rule.action || {}).type !== 'modifyHeaders' || (rule.action.requestHeaders || []).length + (rule.action.responseHeaders || []).length > 0) });
        try { dnr[fn] = (options, callback) => {
          const attempt = async (current, tries) => {
            try { return await native(current); } catch (e) {
              const text = String(e && e.message), start = text.indexOf('The header `'), end = text.indexOf('` is not recognized');
              if (tries > 50) throw e;
              if (start >= 0 && end > start) return attempt(without(current, text.slice(start + 12, end).toLowerCase()), tries + 1);
              // Any other rule WebKit can't take is left out by itself, as Chrome would refuse only that one; the
              // extension's other rules still apply (DuckDuckGo's, an ad blocker's).
              const at = text.indexOf('rule at index ');
              const index = at >= 0 ? parseInt(text.slice(at + 14), 10) : NaN;
              if (Number.isNaN(index) || !(current.addRules || [])[index]) throw e;
              return attempt(Object.assign({}, current, { addRules: current.addRules.filter((_, i) => i !== index) }), tries + 1);
            }
          };
          const result = attempt(options || {}, 0);
          if (typeof callback !== 'function') return result;
          result.then(() => callback(), () => callback());
        }; } catch (e) {}
      }
      // Whole namespaces, only where asked for.
      // Its constants are read as the extension starts (Claude does), so they must be there, or it stops loading.
      const colors = Object.freeze(Object.fromEntries(['grey', 'blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange'].map((c) => [c.toUpperCase(), c])));
      add('tabGroups', { TAB_GROUP_ID_NONE: -1, Color: colors, query: done([]), get: no('Tab groups'), update: no('Tab groups'), move: no('Tab groups'), onCreated: event(), onUpdated: event(), onRemoved: event(), onMoved: event() });
      add('sidePanel', { setPanelBehavior: done(), setOptions: done(), getOptions: done({ enabled: false }), getPanelBehavior: done({ openPanelOnActionClick: false }), open: no('The side panel') });
      add('offscreen', { createDocument: no('Offscreen documents'), closeDocument: done(), hasDocument: done(false), Reason: {} });
      add('idle', { queryState: done('active'), setDetectionInterval: noop, getAutoLockDelay: done(0), onStateChanged: event() });
      add('notifications', { create: done(''), update: done(false), clear: done(false), getAll: done({}), getPermissionLevel: done('denied'), onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event() });
      add('downloads', { download: no('Downloads from extensions'), search: done([]), cancel: done(), erase: done([]), show: noop, showDefaultFolder: noop, open: no('Opening downloads'), setUiOptions: done(), onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event() });
      add('history', { search: done([]), getVisits: done([]), addUrl: done(), deleteUrl: done(), deleteRange: done(), deleteAll: done(), onVisited: event(), onVisitRemoved: event() });
      add('bookmarks', { getTree: done([{ id: '0', title: '', children: [] }]), get: done([]), getChildren: done([]), getRecent: done([]), search: done([]), create: no('Bookmarks from extensions'), update: no('Bookmarks from extensions'), remove: no('Bookmarks from extensions'), onCreated: event(), onRemoved: event(), onChanged: event(), onMoved: event() });
      add('sessions', { getRecentlyClosed: done([]), getDevices: done([]), restore: no('Restoring sessions'), MAX_SESSION_RESULTS: 25, onChanged: event() });
      add('topSites', { get: done([]) });
      add('debugger', { attach: no('Debugging pages'), detach: done(), sendCommand: no('Debugging pages'), getTargets: done([]), onEvent: event(), onDetach: event() });
      add('management', { getSelf: done({ id: api.runtime.id, name: manifest.name, version: manifest.version, enabled: true, installType: 'normal', type: 'extension' }), getAll: done([]), get: no('Other extensions'), setEnabled: no('Turning other extensions off'), onEnabled: event(), onDisabled: event(), onInstalled: event(), onUninstalled: event() });
      add('identity', { getRedirectURL: (path) => 'https://' + api.runtime.id + '.chromiumapp.org/' + (path || ''), launchWebAuthFlow: no('Signing in through the browser'), getAuthToken: no('Signing in through the browser'), getProfileUserInfo: done({ email: '', id: '' }), onSignInChanged: event() });
      add('tts', { speak: done(), stop: noop, getVoices: done([]), isSpeaking: done(false), onEvent: event() });
      add('fontSettings', { getFontList: done([]), getFont: done({ fontId: '' }), setFont: done(), clearFont: done(), onFontChanged: event() });
      add('privacy', { services: {}, network: {}, websites: {} });
      add('power', { requestKeepAwake: noop, releaseKeepAwake: noop });
      add('search', { query: no('Searching from extensions') });
      return true;
      };
      if (!start()) {
        let tries = 0;
        const again = () => { if (!start() && ++tries < 100) setTimeout(again, 20); };
        setTimeout(again, 0);
      }
    })();
    """

    /// Every page prelude, by extension ID.
    static var pagePreludes: [(id: String, source: String)] { shims.compactMap { id, shim in shim.pagePrelude.map { (id, $0) } } }

    /// Installed records of Firefox packages; their pages get the marker firefox-polyfill.js reads.
    static var firefoxIDs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ExtensionStore.root.path)) ?? [])
            .filter { ExtensionStore.package($0) != nil && ExtensionStore.kind(of: $0) == .firefox }.sorted()
    }

    private static let shims: [String: Shim] = [
        ExtensionStore.onePasswordID: Shim(backgroundPrelude: onePasswordPrelude, pagePrelude: diagnostics,
                                              coveredPermissions: ["management", "privacy", "idle"]),
        // Bitwarden: its popup loop is answered by the prelude; its popup draws again (checked 2026-11-08).
        "nngceckbapebfimnlniiiahkandclblb": Shim(backgroundPrelude: bitwardenPrelude, pagePrelude: bitwardenPrelude, coveredPermissions: ["idle"],
                                                    patches: [bitwardenInlineMenuPatch]),
        // Return YouTube Dislike, as "Bring Back YouTube Dislikes".
        "jleldmehlnopjhbldegndecakdemocah": Shim(patches: [dislikeCountPatch, dislikeWritePatch, dislikeObserverPatch]),
        "gebbhagfogifgggkldgodflihgfeippi": Shim(patches: [dislikeCountPatch, dislikeWritePatch, dislikeObserverPatch]),
        // Tampermonkey.
        tampermonkeyID: Shim(patches: [tampermonkeyStartPatch, tampermonkeyPagesPatch, tampermonkeyInstallPatch,
                                          tampermonkeyInlineCheckPatch, tampermonkeyInlinePatch]),
        // Tampermonkey's beta: the same fixes, written to hold across its frequent builds, whose short names change.
        tampermonkeyBetaID: Shim(patches: tampermonkeyBetaPatches),
        // Motrix, which hands downloads to the Motrix app.
        motrixID: Shim(backgroundPrelude: motrixPrelude),
    ]

    /// OldTwitter signs every request to X with a transaction id from X's own challenge script. Chrome runs that
    /// script in a sandbox page. Here the site's Content-Security-Policy blocks both the blob iframe it uses and eval,
    /// so it never starts and every request times out. Zigzag runs the extension's own `sandbox.html` script in a content
    /// world of its own for each tab, outside the site's policy and without extension APIs (OldTwitterSolver); these
    /// patches send the challenge there instead of an iframe. Checked against OldTwitter 1.9.10.3.
    static let oldTwitterPatches: [Patch] = [
        // No blob iframe: Zigzag makes the sandbox for each init.
        Patch(file: "scripts/twchallenge.js",
              find: #"function createSolverFrame\(\) \{[\s\S]*?\n\}\ncreateSolverFrame\(\);"#,
              replace: #"""
function createSolverFrame() {
    solverReady = false;
    requeuePendingSolves();
    solverGeneration++;
}
createSolverFrame();
"""#, pattern: true),
        // Each transaction id comes from the sandbox through the bridge, not an iframe message. A page's first request
        // can come before the challenge has started: it waits for it, as the iframe's queue did, rather than failing.
        Patch(file: "scripts/twchallenge.js",
              find: #"function solveChallenge\(path, method\) \{[\s\S]*?\n\}\n\nfunction recoverSolver"#,
              replace: #"""
async function solveChallenge(path, method) {
    if (!solverReady && !solverErrored) {
        await initChallenge();
        let start = Date.now();
        while (!solverReady && !solverErrored && Date.now() - start < 15000) {
            await new Promise((r) => setTimeout(r, 50));
        }
    }
    return window.__zigzagOldTwitterCall({ op: "solve", path, method });
}

function recoverSolver
"""#, pattern: true),
        // The codes its page worked out go to the sandbox too; ready means it can sign requests. A failed init stops
        // signing, as in Chrome, but a timeout or a restart doesn't: the next solve starts a new sandbox over.
        Patch(file: "scripts/twchallenge.js",
              find: #"async function sendInit\(\) \{[\s\S]*?\n        \}\n        await sendInit\(\);"#,
              replace: #"""
async function sendInit() {
            if (generation !== solverGeneration) return;
            sentData = true;
            try {
                let reply = await window.__zigzagOldTwitterCall({
                    op: "init",
                    data: {
                        ...initData,
                        anims,
                        verificationCode: OLDTWITTER_CONFIG.verificationKey,
                    },
                });
                if (reply && reply.initError) {
                    solverErrored = true;
                    console.error("Error initializing solver:", reply.initError);
                    return;
                }
                solverReady = true;
            } catch (e) {
                console.error("Solver didn't start:", e);
            }
        }
        await sendInit();
"""#, pattern: true),
        // The sandbox's own message listener becomes a function Zigzag calls in the sandbox's world.
        Patch(file: "sandbox.html",
              find: #"window\.addEventListener\('message', (async function \(event\) \{[\s\S]*?\n        \})\);"#,
              replace: #"window.__zigzagSolveMessage = $1;"#, pattern: true),
        // A fresh init starts over, as a new iframe did.
        Patch(file: "sandbox.html", find: "if (data.action === 'init') {\n                try {",
              replace: "if (data.action === 'init') {\n                initError = false;\n                try {"),
        // A quoted video's picture is Zigzag's own layer's click to toggle. OldTwitter's second toggle on the media
        // would act on clicks in the control pills' empty parts, where nothing should happen.
        Patch(file: "scripts/helpers.js",
              find: """
        if (tweetMediaQuote)
            tweetMediaQuote.addEventListener("click", (e) => {
                if (e && e.target && e.target.tagName === "VIDEO") {
                    e.preventDefault();
                    e.stopPropagation();
                    e.stopImmediatePropagation();
                    if (e.target.paused) {
                        e.target.play();
                    } else {
                        e.target.pause();
                    }
                }
            });
""", replace: """
        if (tweetMediaQuote)
            tweetMediaQuote.addEventListener("click", (e) => {
                // The picture's click is handled outside the extension; a quoted video does not toggle here.
            });
"""),
        // A quoted tweet answers a modified click as a link: ⌘-click opens it in a new tab.
        Patch(file: "scripts/helpers.js",
              find: """
                tweetBodyQuote.addEventListener("click", async (e) => {
                    e.preventDefault();
                    document.getElementById("loading-box").hidden = false;
""", replace: """
                tweetBodyQuote.addEventListener("click", async (e) => {
                    if (e.metaKey || e.ctrlKey || e.target.closest("a[data-zigzag-modified]")) return;
                    e.preventDefault();
                    document.getElementById("loading-box").hidden = false;
"""),
        Patch(file: "scripts/helpers.js",
              find: """
                tweetBodyQuote.addEventListener("click", (e) => {
                    e.preventDefault();
""", replace: """
                tweetBodyQuote.addEventListener("click", (e) => {
                    if (e.metaKey || e.ctrlKey || e.target.closest("a[data-zigzag-modified]")) return;
                    e.preventDefault();
"""),
        // The iframe "modal" takes every link click on a page, a quoted tweet included. A modified click is the
        // browser's: ⌘-click opens the quoted tweet in a new tab.
        Patch(file: "scripts/iframeNavigation.js",
              find: """
function useIframeNavigation(e) {
    if (e.defaultPrevented) return;
""", replace: """
function useIframeNavigation(e) {
    if (e.defaultPrevented) return;
    if (e.metaKey || e.ctrlKey || (e.target.closest && e.target.closest("a[data-zigzag-modified]"))) return;
"""),
        // The sandbox has no body of its own here: the page it sets up the challenge in is the real one, so it makes
        // the two pieces the script reads when they aren't there.
        Patch(file: "sandbox.html", find: """
        function setPageData(data) {
            let animsDiv = document.getElementById('anims');
            animsDiv.innerHTML = '';
            for (let anim of data.anims) {
                animsDiv.innerHTML += `\\n${anim}`;
            }
            let verif = document.querySelector('meta[name="twitter-site-verification"]');
            verif.content = data.verificationCode;
        }
""", replace: """
        function setPageData(data) {
            let animsDiv = document.getElementById('anims');
            if (!animsDiv) {
                animsDiv = document.createElement('div');
                animsDiv.id = 'anims';
                animsDiv.style.display = 'none';
                (document.body || document.documentElement).appendChild(animsDiv);
            }
            animsDiv.innerHTML = '';
            for (let anim of data.anims) {
                animsDiv.innerHTML += `\\n${anim}`;
            }
            let verif = document.querySelector('meta[name="twitter-site-verification"]');
            if (!verif) {
                verif = document.createElement('meta');
                verif.name = 'twitter-site-verification';
                (document.head || document.documentElement).appendChild(verif);
            }
            verif.content = data.verificationCode;
        }
"""),
    ]

    static let motrixID = "lggbokfckofcgjndaboioakcmincinpo"

    /// Motrix pairs with its app over a WebSocket, and both sides prove who they are with the extension's origin:
    /// the app reads it from the connection (Zigzag's WebSocketBridge sends Chrome's, chrome-extension://<id>), the
    /// extension works it out from `runtime.getURL('/')`. That's webkit-extension://<id>/ here, a shape it refuses,
    /// so pairing stopped before it began ("连接失败"). Only that one call, with just "/", gets Chrome's name; every
    /// other address, and `getURL('')` it checks its own pages' senders against, stays WebKit's.
    static let motrixPrelude = """
    (() => {
      const held = (globalThis.__zigzagHeld = globalThis.__zigzagHeld || []);
      for (const api of new Set([globalThis.browser, globalThis.chrome])) {
        const runtime = api && api.runtime;
        if (!runtime || typeof runtime.getURL !== 'function' || !runtime.id) continue;
        const getURL = runtime.getURL.bind(runtime);
        const chromeRoot = 'chrome-extension://' + runtime.id + '/';
        try {
          Object.defineProperty(runtime, 'getURL', { value: (path) => (path === '/' ? chromeRoot : getURL(path)), configurable: true, writable: true });
          held.push(runtime);
        } catch (e) {}
      }
    })();

    """

    static let tampermonkeyID = "dhdgffkkebhmkfjojejmpbldmpobfkfo"
    static let tampermonkeyBetaID = "gcalenpjmijncebpfijmoaglllgpjagf"
    /// Either Tampermonkey: they're one extension to everything that makes room for it.
    static let tampermonkeyIDs: Set<String> = [tampermonkeyID, tampermonkeyBetaID]
    static let violentmonkeyID = "jinjaccalgkegednnccohejagnlnfdag"

    /// With Tampermonkey and Violentmonkey both on, opening a .user.js address has each put its own install page in
    /// the same tab, and the slower one wins: a different one from one time to the next. Tampermonkey, the one most
    /// people have, goes first: Violentmonkey's page is left out while the tab is still on a script's address or
    /// already on Tampermonkey's page. Anywhere else (its own "Install from URL") it opens as usual.
    static func leavesInstallToTampermonkey(_ extensionID: String, loading url: URL, tabURL: URL?, tampermonkeyOn: Bool) -> Bool {
        guard tampermonkeyOn, extensionID == violentmonkeyID, url.scheme == "webkit-extension", url.host() == violentmonkeyID,
              url.path() == "/confirm/index.html", let tabURL else { return false }
        if tabURL.scheme == "webkit-extension" { return tabURL.host().map(tampermonkeyIDs.contains) ?? false }
        return ["http", "https", "file"].contains(tabURL.scheme ?? "") && tabURL.path().lowercased().hasSuffix(".user.js")
    }

    /// Tampermonkey's background lets itself add listeners only in the first moment of starting, until the first
    /// promise settles. Near the end of its start it loads an empty test.js with importScripts, and WebKit settles
    /// waiting promises after each imported script, which Chrome doesn't. So that moment is over before its last
    /// listeners are added, the first of them throws, and the rest of its start never runs: its popup waits forever,
    /// and no script is ever registered. The empty file isn't loaded.
    private static let tampermonkeyStartPatch = Patch(file: "background.js", find: #"try{importScripts("/test.js")}catch(e){console.error(e)}"#, replace: "")

    /// Its background answers its popup and dashboard only when their address starts with Chrome's
    /// "chrome-extension:", written into it; WebKit's extension pages are "webkit-extension:". So every popup
    /// request went unanswered and the popup stayed blank.
    private static let tampermonkeyPagesPatch = Patch(file: "background.js", find: #"INTERNAL_PAGE_PROTOCOLS:["chrome-extension:"]"#,
                                                      replace: #"INTERNAL_PAGE_PROTOCOLS:["webkit-extension:"]"#)

    /// Opening a script's .user.js address should open Tampermonkey's install page. Its usual way is a
    /// declarativeNetRequest redirect whose patterns WebKit can't read (`(?:…|…)`), and WebKit drops such rules
    /// without a word, so nothing happened. Its older way, watching the tab's address, works here; it now takes
    /// that way in its "Auto" setting too.
    private static let tampermonkeyInstallPatch = Patch(file: "background.js", find: #""legacy"==wn.values.scriptUrlDetection||"#,
                                                        replace: #""legacy"==wn.values.scriptUrlDetection||"auto"==wn.values.scriptUrlDetection||"#)

    /// Tampermonkey puts a script into the page as an inline <script>. In Chrome its own world's CSP decides whether
    /// that may run; in WebKit the page's does, so on sites that allow no inline scripts (GitHub) nothing ran, and
    /// only its "Force DOM" setting helped. Once per page it now checks whether an inline script runs there; where it
    /// doesn't, a script runs in Tampermonkey's own world instead, as Force DOM does, and everywhere else as before.
    /// That world is its user-script world (BridgeUserScripts), whose CSP Tampermonkey sets without 'unsafe-eval' but
    /// with 'unsafe-inline': the world's runner for inline scripts runs it, as Chrome would have run the inline script.
    private static let tampermonkeyInlineCheckPatch = Patch(file: "content.js", find: #"var E;return L},Ss=function(e,t,n,o,s){"#,
                                                            replace: #"var E;return L},Zz=e=>{if(void 0===Zz.v){const d=e.ownerDocument||document,x=d.documentElement,k="data-zigzag-inline",p=d.createElement("script"),n=xo();n&&p.setAttribute("nonce",n),x.setAttribute(k,""),p.textContent="document.documentElement.removeAttribute('"+k+"')";try{e.appendChild(p),p.remove()}catch(e){}Zz.v=!x.hasAttribute(k),x.removeAttribute(k)}return Zz.v},Ss=function(e,t,n,o,s){"#)
    private static let tampermonkeyInlinePatch = Patch(file: "content.js", find: #"try{c.textContent=t,e.appendChild(c)}catch(e){r=e.message||e}"#,
                                                       replace: #"try{Zz(e)?(c.textContent=t,e.appendChild(c)):(globalThis.__zigzagInlineScript||(0,eval))(t)}catch(e){r=e.message||e}"#)

    /// The beta has the same four troubles as the stable version, in code whose short names (and line breaks)
    /// change with each build, so its fixes find the code by its shape. Checked against 5.6.6242.
    static let tampermonkeyBetaPatches: [Patch] = [
        // The empty test.js (tampermonkeyStartPatch): without this its start stopped at its first listener, and
        // nothing else ran: no popup, no dashboard, no script.
        Patch(file: "background.js", find: #"try\{\s*importScripts\("/test\.js"\)\}catch\(([\w$]+)\)\{console\.error\(\1\)\}"#, replace: "", pattern: true),
        tampermonkeyPagesPatch,
        // Script addresses (tampermonkeyInstallPatch): its "Auto" now picks a way by Chrome's version, the newest one
        // in Chrome 152 and later and the redirect before; here it takes the way that works, watching the tab.
        Patch(file: "background.js", find: #"return"auto"!=([\w$]+)\?\1:[\w$]+\(\)>=\d+\?"inline":"newtab""#,
              replace: #"return"auto"!=$1?$1:"legacy""#, pattern: true),
        // Inline scripts where the page allows none (tampermonkeyInlineCheckPatch, tampermonkeyInlinePatch), as one
        // change: the first time on a page, a test script says whether inline scripts run there.
        Patch(file: "content.js",
              find: #"let ([\w$]+);const ([\w$]+)=([\w$]+)\(\),([\w$]+)=([\w$]+)\("script"\);\2&&\4\.setAttribute\("nonce",\2\);try\{\4\.textContent=([\w$]+),([\w$]+)\.appendChild\(\4\)\}catch"#,
              replace: #"let $1;const $2=$3(),$4=$5("script");$2&&$4.setAttribute("nonce",$2);try{"# + inlineRunsCheck + #"($7,$2)?($4.textContent=$6,$7.appendChild($4)):(globalThis.__zigzagInlineScript||(0,eval))($6)}catch"#,
              pattern: true),
    ]

    /// Whether an inline script runs on this page (into `e`, with nonce `n`), found once per page and kept in the
    /// content script's own world. No `$` or `\` in it: it goes into a regular expression's template.
    private static let inlineRunsCheck = #"((e,n)=>{const g=globalThis;if(void 0===g.__zigzagInline){const d=e.ownerDocument||document,x=d.documentElement,k="data-zigzag-inline",p=d.createElement("script");n&&p.setAttribute("nonce",n),x.setAttribute(k,""),p.textContent="document.documentElement.removeAttribute('"+k+"')";try{e.appendChild(p),p.remove()}catch(e){}g.__zigzagInline=!x.hasAttribute(k),x.removeAttribute(k)}return g.__zigzagInline})"#

    /// Return YouTube Dislike writes its count into a copy of YouTube's label, class names and all. YouTube's
    /// own like and dislike code find their labels by class, so both write into the copy, in turns ("0", the
    /// count, "0"…), forever, and the page pins a CPU core. The copy keeps the look but drops the class names,
    /// and YouTube's own label is hidden once.
    /// It decides whether to write by reading the label back (`innerText`), which in WebKit never matches what
    /// it wrote, so it writes every time it hears the page change, including its own writes. It remembers what
    /// it wrote instead, and writes only when the number changes.
    private static let dislikeWritePatch = Patch(file: "ryd.content-script.js", find: """
      if (_dislikeText != null && _container?.innerText !== _dislikeText) {
        _container.innerText = _dislikeText;
      }
    """, replace: """
      if (_dislikeText != null && _container && _container.__zigzagShown !== String(_dislikeText)) {
        _container.__zigzagShown = String(_dislikeText);
        _container.innerText = _dislikeText;
      }
    """)

    /// Its watchers hear its own writes to its label and write again; they now ignore changes inside its own
    /// label, so nothing it does can wake it up again. Changes to YouTube's page still reach them.
    private static let dislikeObserverPatch = Patch(file: "ryd.content-script.js", find: """
      observerWrapper.observer = new MutationObserver(callback);
    """, replace: """
      observerWrapper.observer = new MutationObserver((records, observer) => {
        const outside = records.filter((r) => !(r.target.closest ? r.target.closest("[data-zigzag-count]") : r.target.parentElement?.closest("[data-zigzag-count]")));
        if (outside.length) callback(outside, observer);
      });
    """)

    private static let dislikeCountPatch = Patch(file: "ryd.content-script.js", find: """
    function getDislikeTextContainer() {
      let result;
    """, replace: """
    function getDislikeTextContainer() {
      const zigzagButton = getDislikeButton();
      const zigzagOwn = zigzagButton && zigzagButton.querySelector("[data-zigzag-count]");
      if (zigzagOwn) return zigzagOwn;
      if (zigzagButton) {
        const zigzagMade = createDislikeTextContainer();
        // Same look as YouTube's label, but none of its class names: YouTube's own code finds its labels by
        // class, and would otherwise keep writing into this one.
        const look = getComputedStyle(zigzagMade);
        const style = ["font-family", "font-size", "font-weight", "line-height", "color", "letter-spacing", "white-space",
                       "margin-left", "margin-right", "padding-left", "padding-right"].map((p) => p + ":" + look.getPropertyValue(p)).join(";");
        for (const node of [zigzagMade, ...zigzagMade.querySelectorAll("[class]")]) node.removeAttribute("class");
        zigzagMade.setAttribute("style", style);
        zigzagMade.setAttribute("data-zigzag-count", "");
        for (const selector of _state__WEBPACK_IMPORTED_MODULE_0__.zO.selectors.dislikeTextContainer) {
          const theirs = zigzagButton.querySelector(selector + ":not([data-zigzag-count])");
          if (theirs && !zigzagMade.contains(theirs) && !theirs.contains(zigzagMade) && theirs.style.display !== "none") theirs.style.display = "none";
        }
        return zigzagMade;
      }
      let result;
    """)

    /// Whether the WebSocket stand-in is live in the extension's background: only in a service worker, as the
    /// stand-in steps aside in a background page. Only those extensions may open Zigzag's socket port.
    static func usesWebSocketShim(manifest: [String: Any]?) -> Bool {
        (manifest?["background"] as? [String: Any])?["service_worker"] is String
    }

    /// Chrome keeps a background running while it has a companion app connected (connectNative). WebKit stops one
    /// whose ports have been quiet for two minutes, and with it the app's helper and whatever the two had set up:
    /// iCloud Passwords' pairing, so a profile you'd left for a while asked for a new code. The background keeps a
    /// port to Zigzag open and answers each beat on it; Zigzag beats while the extension's companion app is
    /// connected (NativeMessagingHost), and the answer is the background being busy.
    static let keepAliveHost = "zigzag.keepalive"
    static let nativeKeepAlive = """
    (() => {
      const api = globalThis.browser || globalThis.chrome;
      if (!api || !api.runtime || typeof api.runtime.connectNative !== 'function') return;
      try {
        const port = api.runtime.connectNative('\(keepAliveHost)');
        port.onMessage.addListener(() => { try { port.postMessage(1); } catch (e) {} });
      } catch (e) {}
    })();
    """

    /// WebKit's extension service workers freeze on `new WebSocket(…)`. This stands in for it, with the same
    /// events and methods, and Zigzag opens the real connection over a native port (WebSocketBridge). A background
    /// page (not a worker) opens its own as usual.
    private static let webSocketShim = """
    (() => {
      if (typeof window !== 'undefined') return;
      const api = globalThis.browser || globalThis.chrome;
      if (!api || !api.runtime || typeof api.runtime.connectNative !== 'function') return;
      const toBase64 = (buffer) => { const bytes = new Uint8Array(buffer); let s = ''; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
      const fromBase64 = (text) => { const s = atob(text); const bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
      class WebSocket extends EventTarget {
        constructor(url, protocols) {
          super();
          this.url = String(url);
          this.readyState = 0;
          this.protocol = '';
          this.extensions = '';
          this.bufferedAmount = 0;
          this.binaryType = 'blob';
          this.onopen = this.onmessage = this.onerror = this.onclose = null;
          try {
            this._port = api.runtime.connectNative('\(WebSocketBridge.host)');
          } catch (e) {
            setTimeout(() => { this._emit('error'); this._closed(1006, ''); }, 0);
            return;
          }
          this._port.onMessage.addListener((m) => this._receive(m));
          this._port.onDisconnect.addListener(() => this._closed(1006, ''));
          this._port.postMessage({ op: 'open', url: this.url, protocols: protocols === undefined ? [] : [].concat(protocols) });
        }
        _emit(type, init) {
          let event;
          if (type === 'message') event = new MessageEvent('message', init);
          else if (type === 'close' && typeof CloseEvent === 'function') event = new CloseEvent('close', init);
          else { event = new Event(type); if (init) for (const k of Object.keys(init)) Object.defineProperty(event, k, { value: init[k] }); }
          this.dispatchEvent(event);
          const handler = this['on' + type];
          if (typeof handler === 'function') handler.call(this, event);
        }
        _receive(m) {
          if (!m || this.readyState === 3) return;
          if (m.ev === 'open') { this.readyState = 1; this.protocol = m.protocol || ''; this._emit('open'); }
          else if (m.ev === 'message') {
            let data = m.text;
            if (m.binary !== undefined) { const buffer = fromBase64(m.binary); data = this.binaryType === 'arraybuffer' ? buffer : new Blob([buffer]); }
            this._emit('message', { data });
          }
          else if (m.ev === 'error') this._emit('error');
          else if (m.ev === 'close') this._closed(m.code || 1006, m.reason || '');
        }
        _closed(code, reason) {
          if (this.readyState === 3) return;
          this.readyState = 3;
          this._emit('close', { code, reason, wasClean: code === 1000 });
          try { this._port && this._port.disconnect(); } catch (e) {}
        }
        send(data) {
          if (this.readyState === 0) throw new DOMException('Still connecting', 'InvalidStateError');
          if (this.readyState !== 1) return;
          if (typeof data === 'string') this._port.postMessage({ op: 'send', text: data });
          else if (data instanceof ArrayBuffer) this._port.postMessage({ op: 'send', binary: toBase64(data) });
          else if (ArrayBuffer.isView(data)) this._port.postMessage({ op: 'send', binary: toBase64(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)) });
          else if (data instanceof Blob) data.arrayBuffer().then((b) => this.readyState === 1 && this._port.postMessage({ op: 'send', binary: toBase64(b) }));
        }
        close(code, reason) {
          if (this.readyState >= 2) return;
          this.readyState = 2;
          try { this._port.postMessage({ op: 'close', code: code || 1000, reason: reason || '' }); } catch (e) { this._closed(code || 1000, reason || ''); }
        }
      }
      for (const [name, value] of Object.entries({ CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 })) { WebSocket[name] = value; WebSocket.prototype[name] = value; }
      globalThis.WebSocket = WebSocket;
    })();

    """

    /// Reports the extension's uncaught errors, failed promises and WebAssembly that won't load to Zigzag's
    /// extensions log, through a native host only Zigzag answers. Only error text, cut short; never its data.
    static let diagnosticsHost = "zigzag.diagnostics"
    private static let diagnostics = """
    (() => {
      const api = globalThis.browser || globalThis.chrome;
      const where = (globalThis.location && location.pathname.split('/').pop()) || 'worker';
      const text = (x) => {
        if (typeof x === 'string') return x;
        if (!x || typeof x !== 'object') return String(x);
        const name = x.name || (x.constructor && x.constructor.name) || '';
        const top = String(x.stack || '').split('\\n')[0];
        return [name, x.message || x.errorClass || '', top].filter(Boolean).join(' | ');
      };
      const report = (kind, value) => {
        try { const sent = api.runtime.sendNativeMessage('\(diagnosticsHost)', { kind, where, text: String(value).slice(0, 300) }); if (sent && sent.catch) sent.catch(() => {}); } catch (e) {}
      };
      globalThis.addEventListener && globalThis.addEventListener('error', (e) => report('error', (e.message || '') + ' @ ' + String(e.filename || '').split('/').pop() + ':' + (e.lineno || 0)));
      globalThis.addEventListener && globalThis.addEventListener('unhandledrejection', (e) => report('rejection', text(e.reason)));
      // WebAssembly that won't load leaves an extension's core dead; say so.
      if (globalThis.WebAssembly && typeof WebAssembly.instantiate === 'function') {
        const instantiate = WebAssembly.instantiate;
        WebAssembly.instantiate = function (...args) {
          const result = instantiate.apply(this, args);
          Promise.resolve(result).catch((e) => report('wasm', 'failed to load: ' + text(e)));
          return result;
        };
      }
    })();

    """

    /// Bitwarden's autofill menu in a login field is a frame of its own page, which builds the menu only once it has
    /// checked that the page it's told to show is an extension's: it knows the "chrome-extension:", "moz-extension:"
    /// and "safari-web-extension:" addresses, not WebKit's "webkit-extension:". So it showed nothing; filling from the
    /// right-click menu and the shortcut worked all along.
    private static let bitwardenInlineMenuPatch = Patch(file: "overlay/menu.js", find: #""safari-web-extension:","#,
                                                        replace: #""safari-web-extension:", "webkit-extension:","#)

    /// Bitwarden's background reads the `scripting.ExecutionWorld` constants (WebKit supports the worlds but not
    /// the names) and asks for contexts and offscreen documents before falling back to its popup for clipboard work.
    private static let bitwardenPrelude = """
    const api = globalThis.browser || globalThis.chrome;
    const noop = () => {};
    const event = () => ({ addListener: noop, removeListener: noop, hasListener: () => false });
    const held = {};
    const namespace = (name) => (held[name] = held[name] || api[name]);
    const add = (name, value) => { if (!api[name]) { try { api[name] = value; held[name] = value; } catch (e) {} } };
    const addTo = (name, values) => {
      const target = namespace(name);
      if (!target) return;
      for (const [key, value] of Object.entries(values)) { if (target[key] === undefined) { try { target[key] = value; } catch (e) {} } }
    };
    addTo('scripting', { ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' } });
    addTo('runtime', { getContexts: async () => [], ContextType: { BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', POPUP: 'POPUP', SIDE_PANEL: 'SIDE_PANEL', TAB: 'TAB' } });
    add('offscreen', { createDocument: async () => { throw new Error("Offscreen documents aren't available in Zigzag"); }, closeDocument: async () => {}, hasDocument: async () => false, Reason: { CLIPBOARD: 'CLIPBOARD', LOCAL_STORAGE: 'LOCAL_STORAGE' } });
    add('idle', { queryState: async () => 'active', setDetectionInterval: noop, onStateChanged: event() });
    addTo('storage', { managed: { get: async () => ({}), getBytesInUse: async () => 0, onChanged: event() } });
    // Without a notifications API it swaps in a service that throws at startup and takes the rest of the
    // background down with it. With this one, its notification requests are refused one at a time instead.
    add('notifications', { create: async () => { throw new Error("Notifications aren't available in Zigzag"); }, update: async () => false, clear: async () => false, getAll: async () => ({}), onClicked: event(), onClosed: event(), onButtonClicked: event() });

    """

    /// 1Password's background calls these at startup without checking they exist, and stops at the first
    /// one WebKit lacks. Each stand-in answers the way a browser without the feature would; anything that
    /// would need to actually do something says it can't. Only added to the API objects, never wrapping them:
    /// WebKit delivers messages through the original objects.
    private static let onePasswordPrelude = """
    const api = globalThis.browser || globalThis.chrome;
    const noop = () => {};
    const event = () => ({ addListener: noop, removeListener: noop, hasListener: () => false });
    const unavailable = (what) => async () => { throw new Error(what + " isn't available in Zigzag"); };
    // API objects are cached weakly; holding each one here keeps what we add to it.
    const held = {};
    const namespace = (name) => (held[name] = held[name] || api[name]);
    const add = (name, value) => { if (!api[name]) { try { api[name] = value; held[name] = value; } catch (e) {} } };
    const addTo = (name, values) => {
      const target = namespace(name);
      if (!target) return;
      for (const [key, value] of Object.entries(values)) { if (target[key] === undefined) { try { target[key] = value; } catch (e) {} } }
    };
    const manifest = api.runtime.getManifest();
    add('management', {
      getSelf: async () => ({ id: api.runtime.id, name: manifest.name, version: manifest.version, installType: 'normal', enabled: true, type: 'extension' }),
      getAll: async () => [],
      setEnabled: unavailable('Turning other extensions off'),
      onEnabled: event(), onDisabled: event(), onInstalled: event(), onUninstalled: event(),
    });
    const setting = (value) => ({ get: async () => ({ value, levelOfControl: 'not_controllable' }), set: async () => {}, clear: async () => {}, onChange: event() });
    add('privacy', { services: { passwordSavingEnabled: setting(false), autofillEnabled: setting(false), autofillAddressEnabled: setting(false), autofillCreditCardEnabled: setting(false) } });
    add('idle', { queryState: async () => 'active', setDetectionInterval: noop, onStateChanged: event() });
    add('notifications', { create: unavailable('Notifications'), update: async () => false, clear: async () => false, getAll: async () => ({}), onClicked: event(), onClosed: event(), onButtonClicked: event() });
    add('downloads', { download: unavailable('Downloads from extensions'), onChanged: event() });
    addTo('webNavigation', { onCreatedNavigationTarget: event() });
    addTo('runtime', { onSuspend: event(), requestUpdateCheck: async () => ({ status: 'no_update' }) });
    addTo('commands', { update: unavailable('Changing shortcuts') });
    addTo('permissions', { addHostAccessRequest: async () => {}, removeHostAccessRequest: async () => {} });
    addTo('storage', { managed: { get: async () => ({}), getBytesInUse: async () => 0, onChanged: event() } });
    """
}

extension ExtensionStore {
    /// The folder WebKit loads. Usually the untouched package itself. An extension whose shim needs a
    /// background prelude gets a sibling folder of hard links to the same files, plus a manifest that runs
    /// the prelude first. The package keeps its exact bytes either way.
    /// `folder`: where the profile loading it keeps this extension's own files. Each profile has its loaded copy
    /// there, since Zigzag writes into it (user scripts' code) for that profile alone.
    ///
    /// Making that folder (the first launch after an update, in each profile) links every file of the package and
    /// reads and rewrites its scripts: done off the main thread, which it held up for seconds (#89).
    static func loadDirectory(for id: String, copyIn folder: URL) async -> URL? {
        guard let package = packageDirectory(for: id), let state = self.package(id) else { return nil }
        let packageManifest = manifest(in: package)
        let shim = ExtensionShims.shim(for: id, keepsAlive: ExtensionShims.keepsAlive(manifest: packageManifest))
        let prelude = shim?.backgroundPrelude
        let patches = (shim?.patches ?? []).map { OverlayPatch(file: $0.file, find: $0.find, replace: $0.replace, pattern: $0.pattern) }
        let together = shim?.patchesTogether ?? false
        guard prelude != nil || !patches.isEmpty else { return package }
        let overlay = overlayFolder(in: folder, version: state.version)
        let fill = fills
        let signature = overlaySignature(prelude: prelude, patches: patches, together: together, fill: fill, package: package)
            + (webKitDropsWasmKeyword ? "wasm-policy" : "")
        // Asked for twice at once (a profile's extensions starting as one is added): made once.
        if let making = overlaysMaking[overlay.path] { return await making.value }
        let making = Task.detached(priority: .userInitiated) {
            makeOverlay(overlay, from: package, prelude: prelude, patches: patches, together: together, signature: signature, fill: fill, id: id)
        }
        overlaysMaking[overlay.path] = making
        let made = await making.value
        overlaysMaking[overlay.path] = nil
        return made
    }

    private static var overlaysMaking: [String: Task<URL?, Never>] = [:]

    /// Overlay marker contents. A new format version, prelude, patch, language fill, or background manifest/page change
    /// rebuilds the copy once. Install report data is excluded: it can change without the loaded files changing.
    nonisolated static func overlaySignature(prelude: String?, patches: [OverlayPatch], together: Bool = false,
                                            fill: Fills, package: URL) -> String {
        var parts = ["overlay format \(overlayFormatVersion)", prelude ?? ""]
        if together { parts.append("together") }
        parts += patches.map { [$0.file, $0.find, $0.replace, $0.pattern ? "pattern" : "text"].joined(separator: "\u{0}") }
        parts += [fill.language, fill.webLocks, fill.webLocksMark, contentScriptsFirst]
        parts.append(backgroundDigest(in: package))
        return parts.joined(separator: "\u{1}")
    }

    /// Writer format version, part of the signature so older markers rebuild once even if their text matches.
    nonisolated static let overlayFormatVersion = 3

    /// The manifest's background section plus a background page's bytes. Stable until the extension's files change.
    nonisolated private static func backgroundDigest(in package: URL) -> String {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let background = manifest["background"] as? [String: Any] else { return "no background" }
        var digest = Data()
        if let encoded = try? JSONSerialization.data(withJSONObject: background, options: [.sortedKeys]) { digest.append(encoded) }
        // The page is copied into the overlay; editing it in an unpacked extension must rebuild once.
        if let page = background["page"] as? String, let path = packagePath(page),
           let contents = try? Data(contentsOf: package.appendingPathComponent(path)) {
            digest.append(contents)
        }
        return SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs before content scripts in their world (ConnectGuard.file): keeps WebKit's `browser` (ExtensionBridgeScript.keepsBrowser),
    /// keeps storage calls in order, adds requestIdleCallback, then the reconnect guard, the message listener count
    /// (ExtensionBridgeScript.receivers) and the background wake.
    nonisolated static let contentScriptsFirst = ExtensionBridgeScript.keepsBrowser + "\n" + ExtensionBridgeScript.storageInOrder + "\n" + ExtensionBridgeScript.idleCallbacks + "\n" + ConnectGuard.source + "\n" + ExtensionBridgeScript.receivers + "\n" + BackgroundWake.source

    /// One of a shim's patches, as plain text for making an overlay off the main thread.
    nonisolated struct OverlayPatch: Sendable {
        let file: String
        let find: String
        let replace: String
        var pattern = false
    }

    /// What scripts are given at their top (`filled`), for use off the main thread.
    nonisolated struct Fills: Sendable {
        let language: String
        let webLocks: String
        let webLocksMark: String
    }

    private static var fills: Fills {
        Fills(language: languageFill, webLocks: ExtensionBridgeScript.webLocks, webLocksMark: ExtensionBridgeScript.webLocksMark)
    }

    /// The overlay, made afresh unless it's already the one `signature` describes; the package itself if it can't be.
    nonisolated private static func makeOverlay(_ overlay: URL, from package: URL, prelude: String?, patches: [OverlayPatch],
                                                together: Bool, signature: String, fill: Fills, id: String) -> URL? {
        let marker = overlay.appendingPathComponent("zigzag-profile.txt")
        if (try? String(contentsOf: marker, encoding: .utf8)) == signature { return overlay }
        var patches = patches
        if together, !patchesFit(patches, in: package) {
            ExtensionLog.write("patches for \(id) skipped: this version changed")
            patches = []
        }
        try? FileManager.default.removeItem(at: overlay.deletingLastPathComponent())
        guard linkTree(from: package, to: overlay) else { return package }
        if let prelude {
            guard writeOverlayManifest(in: overlay, from: package, prelude: prelude) else { return package }
        } else {
            guard (try? FileManager.default.linkItem(at: package.appendingPathComponent("manifest.json"), to: overlay.appendingPathComponent("manifest.json"))) != nil else { return package }
        }
        // Patches to the same file build on each other, in order.
        for file in Array(NSOrderedSet(array: patches.map(\.file))) as? [String] ?? [] {
            apply(patches.filter { $0.file == file }, to: file, in: overlay, from: package, id: id)
        }
        fillLanguage(in: overlay, fill: fill)
        try? signature.write(to: marker, atomically: true, encoding: .utf8)
        return overlay
    }

    /// Whether every patch still finds its text in the package, in the order they would apply.
    nonisolated static func patchesFit(_ patches: [OverlayPatch], in package: URL) -> Bool {
        for file in Array(NSOrderedSet(array: patches.map(\.file))) as? [String] ?? [] {
            guard var text = try? String(contentsOf: package.appendingPathComponent(file), encoding: .utf8) else { return false }
            for patch in patches where patch.file == file {
                guard let changed = patched(text, by: patch) else {
                    ExtensionLog.write("patch for \(file) didn't fit: \(patch.find.prefix(80))")
                    return false
                }
                text = changed
            }
        }
        return true
    }

    /// The loaded copy's folder, where Zigzag may add files of its own (user scripts' code). Nil when WebKit loads the
    /// package itself, which is never written to.
    static func overlayDirectory(for id: String, copyIn folder: URL) -> URL? {
        guard let state = package(id) else { return nil }
        let overlay = overlayFolder(in: folder, version: state.version)
        return FileManager.default.fileExists(atPath: overlay.appendingPathComponent("zigzag-profile.txt").path) ? overlay : nil
    }

    private static func overlayFolder(in folder: URL, version: String) -> URL {
        folder.appendingPathComponent("loaded", isDirectory: true).appendingPathComponent(version, isDirectory: true)
    }

    /// JavaScript that Chrome runs and this WebKit doesn't yet: explicit resource management's Symbol.dispose and
    /// Symbol.asyncDispose. Code compiled for `using` checks they exist and stops without them (Bitwarden: its vault
    /// never loads, its autofill menu never shows). The compatibility layer adds them to an extension's background and
    /// pages, but content scripts run inside web pages, where it doesn't; so each script that names them gets them
    /// first, in whatever world it runs. Registered symbols, so every copy is the same one.
    private static let languageFill = #"(()=>{for(const n of["dispose","asyncDispose"])if(typeof Symbol[n]!=="symbol")try{Object.defineProperty(Symbol,n,{value:Symbol.for("Symbol."+n)})}catch(e){}})();"#

    /// Puts `languageFill` at the top of the overlay's scripts that need it, after a "use strict" that opens the file
    /// (it must stay first to count). A script already patched is a copy; the rest become copies here.
    nonisolated private static func fillLanguage(in overlay: URL, fill: Fills) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: overlay, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where ["js", "mjs"].contains(file.pathExtension) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let filled = filled(text, with: fill) else { continue }
            // A new file in place of the link, so the package's own stays exactly as it came.
            try? fm.removeItem(at: file)
            try? filled.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// A script with what it needs in front of it, or nil if it needs nothing. A dedicated worker gets no prelude, and
    /// a lock request from one kills the extension's process, so a script that names navigator.locks brings the
    /// stand-in with it; on a page or background that already has it, it does nothing.
    static func filled(_ text: String) -> String? { filled(text, with: fills) }

    nonisolated static func filled(_ text: String, with fills: Fills) -> String? {
        // Foundation's search: the standard library's `contains` walks a megabyte of script a character at a time,
        // which held Zigzag up for most of a second as an extension was set up (#89).
        func has(_ word: String) -> Bool { text.range(of: word, options: .literal) != nil }
        var fill = ""
        if has("Symbol.dispose") || has("Symbol.asyncDispose"), !text.hasPrefix(fills.language) { fill += fills.language }
        if has("navigator.locks"), !has(fills.webLocksMark) { fill += "\n" + fills.webLocks + "\n" }
        guard !fill.isEmpty else { return nil }
        for directive in ["\"use strict\";", "'use strict';"] where text.hasPrefix(directive) {
            return directive + fill + String(text.dropFirst(directive.count))
        }
        return fill + "\n" + text
    }


    /// WebKit before macOS 26 drops 'wasm-unsafe-eval' from MV3 script-src (WebKit bug 290153), so Bitwarden reports
    /// WebAssembly unsupported (#298). Fixed in WebKit 293854@main.
    nonisolated static var webKitDropsWasmKeyword: Bool {
        #if DEBUG
        // Testing on newer macOS: ZIGZAG_WASM_POLICY=1 writes the old-WebKit policy.
        if ProcessInfo.processInfo.environment["ZIGZAG_WASM_POLICY"] == "1" { return true }
        #endif
        if #available(macOS 26, *) { return false }
        return true
    }

    /// An extension_pages policy that keeps WebAssembly working there, or nil if not requested. script-src becomes
    /// script-src-elem with the same sources, and script-src-attr and worker-src get them too; only string eval stays
    /// blocked. Policies with default-src are left alone, since eval and WebAssembly fall back to it.
    nonisolated static func wasmCompatiblePolicy(_ policy: String) -> String? {
        let directives = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = { (directive: String) in directive.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        let names = Set(directives.map(name))
        guard !names.contains("default-src"), let script = directives.first(where: { name($0) == "script-src" }) else { return nil }
        let sources = script.split(separator: " ").dropFirst().map(String.init)
        guard sources.contains(where: { $0.lowercased() == "'wasm-unsafe-eval'" }) else { return nil }
        let kept = sources.filter { $0.lowercased() != "'wasm-unsafe-eval'" }.joined(separator: " ")
        var result: [String] = []
        for directive in directives {
            guard name(directive) == "script-src" else { result.append(directive); continue }
            for (added, value) in [("script-src-elem", kept), ("script-src-attr", "'none'"), ("worker-src", kept)] where !names.contains(added) {
                result.append(value.isEmpty ? added : added + " " + value)
            }
        }
        return result.joined(separator: "; ")
    }

    /// The manifest with `wasmCompatiblePolicy` applied, for MV3.
    nonisolated static func allowingWasm(_ manifest: [String: Any]) -> [String: Any] {
        guard manifest["manifest_version"] as? Int == 3, var policies = manifest["content_security_policy"] as? [String: Any],
              let pages = policies["extension_pages"] as? String, let fixed = wasmCompatiblePolicy(pages) else { return manifest }
        var manifest = manifest
        policies["extension_pages"] = fixed
        manifest["content_security_policy"] = policies
        return manifest
    }

    /// A patched file is a real copy (the package's stays as it was); its link in the overlay is replaced.
    nonisolated private static func apply(_ patches: [OverlayPatch], to file: String, in overlay: URL, from package: URL, id: String) {
        let source = package.appendingPathComponent(file), target = overlay.appendingPathComponent(file)
        guard var text = try? String(contentsOf: source, encoding: .utf8) else { return }
        for patch in patches {
            guard let changed = patched(text, by: patch) else {
                ExtensionLog.write("patch for \(id) in \(file) skipped: this version changed")
                continue
            }
            text = changed
        }
        try? FileManager.default.removeItem(at: target)
        try? text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// The text with one patch applied, every place it fits; nil where it fits nowhere.
    nonisolated static func patched(_ text: String, by patch: OverlayPatch) -> String? {
        guard patch.pattern else {
            guard text.range(of: patch.find, options: .literal) != nil else { return nil }
            return text.replacingOccurrences(of: patch.find, with: patch.replace)
        }
        let whole = NSRange(text.startIndex..., in: text)
        guard let regex = try? NSRegularExpression(pattern: patch.find), regex.firstMatch(in: text, range: whole) != nil else { return nil }
        return regex.stringByReplacingMatches(in: text, range: whole, withTemplate: patch.replace)
    }

    nonisolated private static func linkTree(from source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        // The enumerator answers with links resolved (/tmp is /private/tmp): so must the root, for paths to line up.
        let source = source.resolvingSymlinksInPath()
        guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil,
              let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let item as URL in enumerator {
            let relative = String(item.resolvingSymlinksInPath().path.dropFirst(source.path.count + 1))
            guard relative != "manifest.json" else { continue }
            let destination = target.appendingPathComponent(relative)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if (try? fm.linkItem(at: item, to: destination)) == nil,
                      // Another volume (an unpacked extension on an external disk) can't hard link: a copy then.
                      (try? fm.copyItem(at: item, to: destination)) == nil {
                return false
            }
        }
        return true
    }

    /// A manifest path normalized to package-relative with `/`. `..`, backslashes and empty paths are refused;
    /// `/js/background.js` and `js/background.js` are the same file.
    nonisolated static func packagePath(_ path: String) -> String? {
        var text = path
        if text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty, !text.contains("\\"), !text.contains("\u{0}") else { return nil }
        var parts: [String] = []
        for part in text.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { continue }
            guard part != ".." else { return nil }
            parts.append(String(part))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Writes the loaded copy's manifest and the files its background needs first. False when the manifest is unreadable or
    /// points outside the package; WebKit then loads the package directly.
    ///
    /// - `background.service_worker`: `zigzag-entry.js`, beside the worker, runs the prelude, then the worker.
    /// - `background.page`: copied with a prelude script before its first script; the key stays.
    /// - `background.scripts`: prelude first, then the scripts in order.
    /// - No background: the manifest is still written so patches and the language fill reach content scripts and pages.
    nonisolated static func writeOverlayManifest(in overlay: URL, from package: URL, prelude: String) -> Bool {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        var entry: (path: String, text: String)?
        var page: (path: String, text: String)?
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String {
                guard let path = packagePath(worker) else { return false }
                let made = workerEntry(for: path, module: (background["type"] as? String) == "module")
                entry = made
                background["service_worker"] = made.path
            } else if let pageFile = background["page"] as? String {
                guard let path = packagePath(pageFile),
                      let html = try? String(contentsOf: package.appendingPathComponent(path), encoding: .utf8) else { return false }
                page = (path, pageWithPrelude(html))
            } else if let scripts = background["scripts"] as? [String] {
                var ordered: [String] = []
                var seen = Set<String>()
                for script in scripts {
                    guard let path = packagePath(script) else { return false }
                    if seen.insert(path).inserted { ordered.append(path) }
                }
                let scripts = ["zigzag-prelude.js"] + ordered.filter { $0 != "zigzag-prelude.js" }
                if background["preferred_environment"] == nil {
                    // Zigzag's generated page declares UTF-8; WebKit's doesn't, so scripts read as Windows-1252 and "📋" showed as "ðŸ“‹"
                    // (#277).
                    page = (backgroundPageFile, backgroundPage(scripts: scripts, modules: background["type"] as? String == "module"))
                    background["page"] = backgroundPageFile
                    background["scripts"] = nil
                } else {
                    background["scripts"] = scripts
                }
            } else {
                return false
            }
            manifest["background"] = background
        }
        // The copy may message Zigzag's bridge (ExtensionBridge) for Chrome APIs WebKit lacks. Real native hosts stay
        // unreachable unless the extension asked (ExtensionHost). The package's manifest, which the user approved, is never
        // changed.
        var permissions = manifest["permissions"] as? [String] ?? []
        if !permissions.contains("nativeMessaging") { permissions.append("nativeMessaging") }
        // Content scripts run after the reconnect loop guard (ConnectGuard).
        let scripts = manifest["content_scripts"] as? [[String: Any]]
        if let scripts { manifest["content_scripts"] = ConnectGuard.guarding(scripts) }
        // User scripts are WebKit content scripts the extension registers (BridgeUserScripts), which takes "scripting";
        // Chrome's userScripts doesn't, so an extension that asked for userScripts may not have asked for it.
        if permissions.contains("userScripts"), !permissions.contains("scripting") { permissions.append("scripting") }
        manifest["permissions"] = permissions
        if webKitDropsWasmKeyword { manifest = allowingWasm(manifest) }
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return false }
        do {
            try out.write(to: overlay.appendingPathComponent("manifest.json"))
            try prelude.write(to: overlay.appendingPathComponent("zigzag-prelude.js"), atomically: true, encoding: .utf8)
            if let entry {
                let target = overlay.appendingPathComponent(entry.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try entry.text.write(to: target, atomically: true, encoding: .utf8)
            }
            if let page {
                let target = overlay.appendingPathComponent(page.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The package's page stays untouched; the overlay links to a copy with the prelude.
                try? FileManager.default.removeItem(at: target)
                try page.text.write(to: target, atomically: true, encoding: .utf8)
            }
            if scripts != nil { try contentScriptsFirst.write(to: overlay.appendingPathComponent(ConnectGuard.file), atomically: true, encoding: .utf8) }
            // bridge.js runs it in frames and before files the extension injects, with or without content scripts.
            try ExtensionBridgeScript.receivers.write(to: overlay.appendingPathComponent(ExtensionBridgeScript.receiversFile), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Background page Zigzag writes for background scripts.
    nonisolated static let backgroundPageFile = "zigzag-background.html"

    /// WebKit's generated background page plus the UTF-8 charset newer WebKit adds; Chrome and Firefox read extension
    /// scripts as UTF-8.
    nonisolated static func backgroundPage(scripts: [String], modules: Bool) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let tags = scripts.map { "<script\(modules ? " type=\"module\"" : "") src=\"/\(escaped($0))\"></script>" }
        return "<!DOCTYPE html>\n<meta charset=\"utf-8\">\n<body>\n" + tags.joined(separator: "\n") + "\n</body>\n"
    }

    /// The worker's entry script, in the worker's own folder, so its relative `importScripts` and `fetch` resolve
    /// against the worker's address as in Chrome (#393). The prelude stays at the package root.
    nonisolated static func workerEntry(for path: String, module: Bool) -> (path: String, text: String) {
        let folder = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let prelude = folder.isEmpty ? "zigzag-prelude.js" : "/zigzag-prelude.js"
        let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        let text = module
            ? "import \(quoted(folder.isEmpty ? "./" + prelude : prelude));\nimport \(quoted("./" + file));\n"
            : "importScripts(\(quoted(prelude)), \(quoted(file)));\n"
        return (folder.isEmpty ? "zigzag-entry.js" : folder + "/zigzag-entry.js", text)
    }

    /// A background page with a prelude script before its first script. Bytes, CSP and order are unchanged; the prelude
    /// is at the package root, so `/zigzag-prelude.js` works from any folder.
    nonisolated static func pageWithPrelude(_ html: String) -> String {
        guard !html.contains("data-zigzag-prelude") else { return html }
        let tag = #"<script src="/zigzag-prelude.js" data-zigzag-prelude="1"></script>"#
        if let script = firstScript(in: html) {
            return html.replacingCharacters(in: script.lowerBound..<script.lowerBound, with: tag)
        }
        if let body = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            return html.replacingCharacters(in: body.lowerBound..<body.lowerBound, with: tag)
        }
        return html + tag
    }

    /// First real `<script`, not one inside an HTML comment.
    nonisolated private static func firstScript(in html: String) -> Range<String.Index>? {
        var search = html.startIndex
        while search < html.endIndex {
            let script = html.range(of: "<script", options: [.caseInsensitive], range: search..<html.endIndex)
            guard let comment = html.range(of: "<!--", options: [.caseInsensitive], range: search..<html.endIndex),
                  comment.lowerBound < (script?.lowerBound ?? html.endIndex) else { return script }
            guard let end = html.range(of: "-->", options: [.caseInsensitive], range: comment.upperBound..<html.endIndex) else { return script }
            search = end.upperBound
        }
        return nil
    }
}
