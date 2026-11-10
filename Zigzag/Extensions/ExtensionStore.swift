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
/// Unpacked extensions (for developers) are read in place from the folder the person chose.
enum ExtensionStore {
    static let onePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private static let lastUpdateKey = "ExtensionsLastUpdateCheck"
    private static let removedKey = "RemovedExtensions"
    private static let developerModeKey = "ExtensionsDeveloperMode"

    static var root: URL { Paths.directory("Extensions") }
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

        fileprivate static let keys = ["version", "pendingVersion", "unpackedPath"]
    }

    static func package(_ id: String) -> Package? { read(Package.self, from: stateFile(for: id)) }

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
        guard var all = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else { return }
        for key in keys { all[key] = nil }
        guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        try? out.write(to: file, options: .atomic)
    }

    static func read<Record: Decodable>(_ type: Record.Type, from file: URL) -> Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Writes a record's own keys and leaves the file's others as they are: the package's record and the first
    /// profile's answers share one file, and neither writer knows the other's keys.
    static func write<Record: Encodable>(_ record: Record, keys: [String], to file: URL) {
        guard let data = try? JSONEncoder().encode(record),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var all = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        for key in keys { all[key] = fields[key] }
        guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        try? out.write(to: file, options: .atomic)
    }

    /// The untouched package for a version (the current one unless named).
    static func packageDirectory(for id: String, version: String? = nil) -> URL? {
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
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.filter { packageDirectory(for: $0) != nil }.sorted()
    }

    static func isUnpacked(_ id: String) -> Bool { package(id)?.unpackedPath != nil }
    static func needsApproval(_ id: String) -> Bool { package(id)?.pendingVersion != nil }

    /// The profiles that have this extension.
    static func profiles(with id: String) -> [Profile] { Profiles.shared.all.filter { $0.installs.hasRecord(id) } }

    /// Sites where every extension is off, whatever its own access says.
    private static let offSitesKey = "ExtensionsOffSites"
    static var extensionsOffSites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: offSitesKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: offSitesKey)
            guard #available(macOS 15.4, *) else { return }
            for profile in Profiles.shared.all {
                for id in profile.installs.installedIDs { profile.extensions.applySiteAccess(id) }
            }
        }
    }

    /// Removing an extension is remembered, so 1Password's automatic setup doesn't bring it back.
    private static var removedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: removedKey) }
    }

    /// Shows "Load Unpacked…" in Settings.
    static var developerMode: Bool {
        get { UserDefaults.standard.bool(forKey: developerModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: developerModeKey) }
    }

    // MARK: The Chrome Web Store

    static let webStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")!

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

    static var isOnePasswordAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") != nil
            || FileManager.default.fileExists(atPath: "/Applications/1Password.app")
    }

    /// WebKit keeps a service worker background's registration from one launch to the next, and on a later launch
    /// can bring it back without running its script: WebKit says the background loaded, but it never starts, and the
    /// extension's popup waits forever (1Password, from the second launch on). Chrome starts each worker afresh at
    /// launch. WebKit lists no data records for extensions' own origins, so their registrations come out of its
    /// registration files directly, before anything starts WebKit: only rows whose script is an extension's, so
    /// sites keep their workers and extensions keep what they stored. A layout WebKit has changed is left alone, and
    /// the extensions log says so, since backgrounds may then stop starting again.
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
        /// What to tell the person, in plain words.
        var message: String {
            switch self {
            case .download: String(localized: "Couldn’t download this extension. Check your connection and try again.", comment: "Shown when an extension couldn't be installed because its download failed.")
            case .verification: String(localized: "This extension’s package couldn’t be verified, so it wasn’t installed.", comment: "Shown when an extension couldn't be installed because its package didn't pass the signature check.")
            case .unpack: String(localized: "This extension’s package is damaged, so it wasn’t installed.", comment: "Shown when an extension couldn't be installed because its package is damaged.")
            case .notListed: String(localized: "This extension isn’t in the Chrome Web Store any more.", comment: "Shown when an extension couldn't be installed because the Chrome Web Store no longer has it. Chrome Web Store is Google's name.")
            case .unsupported: String(localized: "This extension doesn’t work in Zigzag yet.", comment: "Shown when an extension couldn't be installed because WebKit can't run it.")
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
            }
        }
    }

    /// A verified package, downloaded and unpacked but not installed yet: what the install sheet shows.
    @available(macOS 15.4, *)
    struct PreparedInstall {
        let id: String
        let version: String
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
        // A sound package WebKit still can't read (an app, a manifest it doesn't know) won't run here.
        guard let ext = try? await WKWebExtension(resourceBaseURL: package.folder) else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failure(.unsupported)
        }
        let report = ExtensionReport(extension: ext, manifest: manifest, id: id)
        return .success(PreparedInstall(id: id, version: package.version, folder: package.folder, extensionInfo: ext, report: report))
    }

    /// Installs a prepared package in a profile and loads it there. Returns its name.
    @available(macOS 15.4, *)
    static func finishInstall(_ prepared: PreparedInstall, in profile: Profile) async -> Result<String, InstallError> {
        let id = prepared.id
        let installs = profile.installs
        let isNew = !installs.hasRecord(id)
        guard store((prepared.folder, prepared.version), for: id) else { return .failure(.unpack) }
        save(Package(version: prepared.version), for: id)
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

    /// Adds an extension Zigzag already has the package of (another profile's) to a profile: on, with what it asks
    /// for approved afresh and nothing it stored elsewhere.
    @available(macOS 15.4, *)
    static func add(_ id: String, to profile: Profile) async {
        guard packageDirectory(for: id) != nil, !profile.installs.hasRecord(id) else { return }
        profile.installs.save(ExtensionInstalls.State(), for: id)
        profile.installs.newlyInstalled.insert(id)
        await profile.extensions.load(id)
        ExtensionCenter.changed.send()
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

    /// Loads an extension from a folder on disk, for testing one you're building. Its ID comes from the
    /// folder's path, the way Chrome does it, so reloading the same folder keeps its data.
    static func loadUnpacked(_ url: URL, in profile: Profile) async -> String? {
        guard #available(macOS 15.4, *),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        let id = CRXPackage.extensionID(Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16)))
        if !profile.installs.hasRecord(id) { profile.installs.newlyInstalled.insert(id) }
        save(Package(version: manifestVersion(in: url) ?? "0", unpackedPath: url.standardizedFileURL.path), for: id)
        // Loaded again from its folder, it starts as a new install would: on, with what it asks for approved afresh.
        profile.installs.save(ExtensionInstalls.State(), for: id)
        removedIDs.remove(id)
        let context = await profile.extensions.load(id)
        return context?.webExtension.displayName
    }

    /// Re-reads an unpacked extension's files, in every profile running it.
    static func reloadUnpacked(_ id: String) async {
        guard #available(macOS 15.4, *), isUnpacked(id) else { return }
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
            .init(name: "prodversion", value: "140.0"),
            .init(name: "acceptformat", value: "crx3"),
            .init(name: "x", value: "id=\(id)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url) else { return .failure(.download) }
        let status = (response as? HTTPURLResponse)?.statusCode
        // The store answers an ID it doesn't have with nothing at all.
        if status == 404 || status == 204 { return .failure(.notListed) }
        guard status == 200 else { return .failure(.download) }
        // Checking the signature over the whole package and unpacking it take a moment: off the main thread.
        return await Task.detached(priority: .userInitiated) { unpack(data, id: id) }.value
    }

    nonisolated private static func unpack(_ data: Data, id: String) -> Result<(folder: URL, version: String), InstallError> {
        guard let package = try? CRXPackage(data, expectedID: id) else { return .failure(.verification) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-ext-\(UUID().uuidString)")
        let zipFile = staging.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: zipFile) }
        do {
            try package.zip.write(to: zipFile)
            guard extract(zipFile, into: staging), let version = manifestVersion(in: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return .failure(.unpack)
            }
            return .success((staging, version))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
    }

    /// Unzips a package into a new folder, and keeps it only if every entry is a plain file or folder inside it: a
    /// link in the package (to a file elsewhere on the Mac) would let the extension read that file as its own.
    nonisolated static func extract(_ zipFile: URL, into folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipFile.path, folder.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0, holdsOnlyItsOwnFiles(folder) else {
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

    /// The current version's manifest.
    static func manifest(for id: String) -> [String: Any]? { packageDirectory(for: id).flatMap(manifest(in:)) }

    /// What the extension asked for in its own manifest (the package's, not the loaded copy's, which adds native
    /// messaging for Zigzag's bridge). Read once per version.
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
        guard let version = manifest(in: folder)?["version"] as? String, !version.isEmpty, !version.contains("/") else { return nil }
        return version
    }

    private static func removeVersions(of id: String, keeping keep: [String]) {
        let folder = versionsFolder(for: id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Updating

    /// Checks every installed extension for a new version, at most once a day.
    static func checkForUpdatesIfDue(force: Bool = false) async {
        let last = UserDefaults.standard.object(forKey: lastUpdateKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 24 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: lastUpdateKey)
        for id in packageIDs where !isUnpacked(id) { await updateIfNewer(id) }
    }

    /// Asks the store for the latest version only; downloads it when it's newer. An update that asks for
    /// nothing new replaces the running version; one that asks for more waits for approval.
    static func updateIfNewer(_ id: String) async {
        guard #available(macOS 15.4, *), let current = package(id), let latest = await latestVersion(of: id, current: current.version),
              isVersion(latest, newerThan: current.version), latest != current.pendingVersion else { return }
        guard case .success(let package) = await download(id), store(package, for: id),
              let old = packageDirectory(for: id), let new = packageDirectory(for: id, version: package.version) else { return }
        if asksForMore(new, than: old) {
            update(id) { $0.pendingVersion = package.version }
            ExtensionCenter.changed.send()
            return
        }
        await switchVersion(of: id, to: package.version)
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

    /// Makes a version current and reloads the extension with it, going back to the old one if it won't load.
    private static func switchVersion(of id: String, to version: String) async {
        guard #available(macOS 15.4, *), let previous = package(id)?.version else { return }
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
    }

    private static func latestVersion(of id: String, current: String) async -> String? {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            .init(name: "response", value: "updatecheck"),
            .init(name: "prodversion", value: "140.0"),
            .init(name: "acceptformat", value: "crx3"),
            .init(name: "x", value: "id=\(id)&v=\(current)&uc"),
        ]
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let xml = String(data: data, encoding: .utf8),
              let check = xml.range(of: "<updatecheck[^>]*>", options: .regularExpression) else { return nil }
        let tag = String(xml[check])
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
        func requested(_ folder: URL) -> Set<String> {
            guard let manifest = manifest(in: folder) else { return [] }
            let keys = ["permissions", "host_permissions", "optional_permissions", "optional_host_permissions"]
            return Set(keys.flatMap { manifest[$0] as? [String] ?? [] })
        }
        return !requested(new).isSubset(of: requested(old))
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
        /// What's known not to work, said before installing ("its popup").
        var knownIssue: String?
    }

    /// Replace `find` with `replace` in one of the extension's files. Skipped, and logged, if `find` isn't there
    /// (a newer version that changed), so an update never breaks on an old fix.
    struct Patch {
        let file: String
        let find: String
        let replace: String
    }

    /// Every extension gets the compatibility layer first; some get their own fixes on top.
    static func shim(for id: String) -> Shim? {
        var shim = shims[id] ?? Shim()
        // Errors reported first (a background that stops as it starts says why), then the bridge (real answers from
        // Zigzag), then stand-ins for what's still missing. Every background gets the WebSocket stand-in: one opened
        // the WebKit way freezes the extension's pages along with it (MyBib's popup never came up).
        shim.backgroundPrelude = diagnostics + ExtensionBridgeScript.source + "\n" + compatibility + "\n" + ExtensionBridgeScript.afterCompatibility + "\n" + webSocketShim + "\n" + (shim.backgroundPrelude ?? "")
        #if DEBUG
        // Testing builds say each background got past Zigzag's own scripts, so a quiet log means quiet, not broken.
        let started = "try { (globalThis.chrome || globalThis.browser).runtime.sendNativeMessage('\(diagnosticsHost)', { where: 'background', kind: 'started', text: 'ok' }); } catch (e) {}\n"
        shim.backgroundPrelude = errorRecorder + (shim.backgroundPrelude ?? "") + started
        #endif
        return shim
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
    ]

    static let tampermonkeyID = "dhdgffkkebhmkfjojejmpbldmpobfkfo"
    static let violentmonkeyID = "jinjaccalgkegednnccohejagnlnfdag"

    /// With Tampermonkey and Violentmonkey both on, opening a .user.js address has each put its own install page in
    /// the same tab, and the slower one wins: a different one from one time to the next. Tampermonkey, the one most
    /// people have, goes first: Violentmonkey's page is left out while the tab is still on a script's address or
    /// already on Tampermonkey's page. Anywhere else (its own "Install from URL") it opens as usual.
    static func leavesInstallToTampermonkey(_ extensionID: String, loading url: URL, tabURL: URL?, tampermonkeyOn: Bool) -> Bool {
        guard tampermonkeyOn, extensionID == violentmonkeyID, url.scheme == "webkit-extension", url.host() == violentmonkeyID,
              url.path() == "/confirm/index.html", let tabURL else { return false }
        if tabURL.scheme == "webkit-extension" { return tabURL.host() == tampermonkeyID }
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
    private static let tampermonkeyInlineCheckPatch = Patch(file: "content.js", find: #"var E;return L},Ss=function(e,t,n,o,s){"#,
                                                            replace: #"var E;return L},Zz=e=>{if(void 0===Zz.v){const d=e.ownerDocument||document,x=d.documentElement,k="data-zigzag-inline",p=d.createElement("script"),n=xo();n&&p.setAttribute("nonce",n),x.setAttribute(k,""),p.textContent="document.documentElement.removeAttribute('"+k+"')";try{e.appendChild(p),p.remove()}catch(e){}Zz.v=!x.hasAttribute(k),x.removeAttribute(k)}return Zz.v},Ss=function(e,t,n,o,s){"#)
    private static let tampermonkeyInlinePatch = Patch(file: "content.js", find: #"try{c.textContent=t,e.appendChild(c)}catch(e){r=e.message||e}"#,
                                                       replace: #"try{Zz(e)?(c.textContent=t,e.appendChild(c)):(0,eval)(t)}catch(e){r=e.message||e}"#)

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
    static func loadDirectory(for id: String, copyIn folder: URL) -> URL? {
        guard let package = packageDirectory(for: id), let state = self.package(id) else { return nil }
        let shim = ExtensionShims.shim(for: id)
        let prelude = shim?.backgroundPrelude
        let patches = shim?.patches ?? []
        guard prelude != nil || !patches.isEmpty else { return package }
        let overlay = overlayFolder(in: folder, version: state.version)
        // What this overlay was made from: rebuilt whenever the prelude, a patch or the language fill changes.
        let signature = (prelude ?? "") + patches.map { $0.file + $0.find + $0.replace }.joined() + languageFill
        let marker = overlay.appendingPathComponent("zigzag-profile.txt")
        if (try? String(contentsOf: marker, encoding: .utf8)) == signature { return overlay }
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
        fillLanguage(in: overlay)
        try? signature.write(to: marker, atomically: true, encoding: .utf8)
        return overlay
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
    private static func fillLanguage(in overlay: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: overlay, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where ["js", "mjs"].contains(file.pathExtension) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let filled = filled(text) else { continue }
            // A new file in place of the link, so the package's own stays exactly as it came.
            try? fm.removeItem(at: file)
            try? filled.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// A script with what it needs in front of it, or nil if it needs nothing. A dedicated worker gets no prelude, and
    /// a lock request from one kills the extension's process, so a script that names navigator.locks brings the
    /// stand-in with it; on a page or background that already has it, it does nothing.
    static func filled(_ text: String) -> String? {
        var fill = ""
        if text.contains("Symbol.dispose") || text.contains("Symbol.asyncDispose"), !text.hasPrefix(languageFill) { fill += languageFill }
        if text.contains("navigator.locks"), !text.contains(ExtensionBridgeScript.webLocksMark) { fill += "\n" + ExtensionBridgeScript.webLocks + "\n" }
        guard !fill.isEmpty else { return nil }
        for directive in ["\"use strict\";", "'use strict';"] where text.hasPrefix(directive) {
            return directive + fill + String(text.dropFirst(directive.count))
        }
        return fill + "\n" + text
    }

    /// A patched file is a real copy (the package's stays as it was); its link in the overlay is replaced.
    private static func apply(_ patches: [ExtensionShims.Patch], to file: String, in overlay: URL, from package: URL, id: String) {
        let source = package.appendingPathComponent(file), target = overlay.appendingPathComponent(file)
        guard var text = try? String(contentsOf: source, encoding: .utf8) else { return }
        for patch in patches {
            guard text.contains(patch.find) else {
                ExtensionLog.write("patch for \(id) in \(file) skipped: this version changed")
                continue
            }
            text = text.replacingOccurrences(of: patch.find, with: patch.replace)
        }
        try? FileManager.default.removeItem(at: target)
        try? text.write(to: target, atomically: true, encoding: .utf8)
    }

    private static func linkTree(from source: URL, to target: URL) -> Bool {
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

    private static func writeOverlayManifest(in overlay: URL, from package: URL, prelude: String) -> Bool {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String else { return false }
        // Manifests write the worker as "js/background.js" or "/js/background.js"; both mean the extension's root.
        let path = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
        let entry = (background["type"] as? String) == "module"
            ? "import './zigzag-prelude.js';\nimport './\(path)';\n"
            : "importScripts('zigzag-prelude.js', '\(path)');\n"
        background["service_worker"] = "zigzag-entry.js"
        manifest["background"] = background
        // The loaded copy may message Zigzag's own bridge (ExtensionBridge), which stands in for Chrome APIs WebKit
        // lacks. Real native hosts stay out of reach unless the extension asked for them itself (ExtensionHost).
        var permissions = manifest["permissions"] as? [String] ?? []
        if !permissions.contains("nativeMessaging") { permissions.append("nativeMessaging") }
        // User scripts are WebKit content scripts the extension registers (BridgeUserScripts), which takes "scripting";
        // Chrome's userScripts doesn't, so an extension that asked for userScripts may not have asked for it.
        if permissions.contains("userScripts"), !permissions.contains("scripting") { permissions.append("scripting") }
        manifest["permissions"] = permissions
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) else { return false }
        do {
            try out.write(to: overlay.appendingPathComponent("manifest.json"))
            try entry.write(to: overlay.appendingPathComponent("zigzag-entry.js"), atomically: true, encoding: .utf8)
            try prelude.write(to: overlay.appendingPathComponent("zigzag-prelude.js"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
