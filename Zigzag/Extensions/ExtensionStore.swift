import AppKit
import CryptoKit
import WebKit

/// Where extensions live and what the person decided about them. Packages come from the Chrome Web Store,
/// the same files Chrome users get, verified and never edited: each version sits in its own folder exactly as
/// it was downloaded. What's ours (on or off, granted permissions, which version is current) is kept beside it.
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
    private static func stateFile(for id: String) -> URL { folder(for: id).appendingPathComponent("state.json") }

    // MARK: State

    /// What we remember about one installed extension.
    struct State: Codable {
        var version: String
        var enabled = true
        /// Permissions and site patterns the person approved. Nil until the first load records them.
        var grantedPermissions: [String]?
        var grantedMatchPatterns: [String]?
        /// A downloaded update that asks for more than the current version, waiting for the person's approval.
        var pendingVersion: String?
        /// For an unpacked extension: the folder it's read from.
        var unpackedPath: String?
        /// Shown as a button by the address. Nil means the default: pinned.
        var pinned: Bool?
        /// Where it may read and change pages. Nil means the default: everywhere it was approved for.
        var siteAccess: SiteAccess?
        /// For `.sites`: the sites it may use ("github.com"), and for `.click`, the ones clicked on so far.
        var accessSites: [String]?
    }

    enum SiteAccess: String, Codable {
        /// Every site it was approved for.
        case all
        /// Only a site where the person clicked its button.
        case click
        /// Only the sites the person listed.
        case sites
    }

    static func state(_ id: String) -> State? {
        guard let data = try? Data(contentsOf: stateFile(for: id)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func save(_ state: State, for id: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        try? data.write(to: stateFile(for: id), options: .atomic)
    }

    static func update(_ id: String, _ change: (inout State) -> Void) {
        guard var current = state(id) else { return }
        change(&current)
        save(current, for: id)
    }

    /// The untouched package for a version (the current one unless named).
    static func packageDirectory(for id: String, version: String? = nil) -> URL? {
        guard let state = state(id) else { return nil }
        if let path = state.unpackedPath {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) ? dir : nil
        }
        let dir = versionsFolder(for: id).appendingPathComponent(version ?? state.version, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) ? dir : nil
    }

    static var installedIDs: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.filter { packageDirectory(for: $0) != nil }.sorted()
    }

    static func isInstalled(_ id: String) -> Bool { packageDirectory(for: id) != nil }
    static func isEnabled(_ id: String) -> Bool { state(id)?.enabled ?? false }
    static func isUnpacked(_ id: String) -> Bool { state(id)?.unpackedPath != nil }
    static func needsApproval(_ id: String) -> Bool { state(id)?.pendingVersion != nil }
    static func isPinned(_ id: String) -> Bool { state(id)?.pinned ?? true }
    static func siteAccess(_ id: String) -> SiteAccess { state(id)?.siteAccess ?? .all }
    static func accessSites(_ id: String) -> [String] { state(id)?.accessSites ?? [] }

    static func setSiteAccess(_ id: String, _ access: SiteAccess, sites: [String]? = nil) {
        guard #available(macOS 15.4, *) else { return }
        update(id) {
            $0.siteAccess = access
            if let sites { $0.accessSites = sites } else if access == .all { $0.accessSites = nil }
        }
        ExtensionHost.shared.applySiteAccess(id)
    }

    /// Sites where every extension is off, whatever its own access says.
    private static let offSitesKey = "ExtensionsOffSites"
    static var extensionsOffSites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: offSitesKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: offSitesKey)
            guard #available(macOS 15.4, *) else { return }
            for id in installedIDs { ExtensionHost.shared.applySiteAccess(id) }
        }
    }

    static func setPinned(_ id: String, _ pinned: Bool) {
        guard #available(macOS 15.4, *) else { return }
        update(id) { $0.pinned = pinned }
        ExtensionHost.shared.changed.send()
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

    /// At launch: moves extensions installed by older builds to the untouched layout, loads what's installed,
    /// sets up 1Password when its app is on this Mac, and checks for updates once a day.
    static func setUpIfNeeded() {
        guard #available(macOS 15.4, *) else { return }
        Task {
            await migrateLegacyInstalls()
            await ExtensionHost.shared.loadInstalled()
            await checkForUpdatesIfDue()
        }
    }

    // MARK: Installing

    enum InstallError: Error {
        case download, verification, unpack
        /// What to tell the person, in plain words.
        var message: String {
            switch self {
            case .download: "Couldn’t download this extension. Check your connection and try again."
            case .verification: "This extension’s package couldn’t be verified, so it wasn’t installed."
            case .unpack: "This extension’s package is damaged, so it wasn’t installed."
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
        guard let ext = try? await WKWebExtension(resourceBaseURL: package.folder), let manifest = manifest(in: package.folder) else {
            try? FileManager.default.removeItem(at: package.folder)
            return .failure(.unpack)
        }
        let report = ExtensionReport(extension: ext, manifest: manifest, id: id)
        return .success(PreparedInstall(id: id, version: package.version, folder: package.folder, extensionInfo: ext, report: report))
    }

    /// Installs a prepared package and loads it. Returns its name.
    @available(macOS 15.4, *)
    static func finishInstall(_ prepared: PreparedInstall) async -> Result<String, InstallError> {
        let id = prepared.id
        guard store((prepared.folder, prepared.version), for: id) else { return .failure(.unpack) }
        var next = state(id) ?? State(version: prepared.version)
        next.version = prepared.version
        next.pendingVersion = nil
        next.unpackedPath = nil
        // Approved just now, from what the sheet showed.
        next.grantedPermissions = nil
        next.grantedMatchPatterns = nil
        save(next, for: id)
        removedIDs.remove(id)
        removeVersions(of: id, keeping: [prepared.version])
        ExtensionHost.shared.unload(id)
        let context = await ExtensionHost.shared.load(id)
        return .success(context?.webExtension.displayName ?? prepared.extensionInfo.displayName ?? id)
    }

    @available(macOS 15.4, *)
    static func discard(_ prepared: PreparedInstall) {
        try? FileManager.default.removeItem(at: prepared.folder)
    }

    /// Downloads, verifies and loads an extension you picked (in onboarding).
    static func install(_ id: String) async -> Result<String, InstallError> {
        guard #available(macOS 15.4, *) else { return .failure(.download) }
        switch await prepareInstall(id) {
        case .success(let prepared): return await finishInstall(prepared)
        case .failure(let error): return .failure(error)
        }
    }

    /// What a held-back update would add, for the approval sheet.
    @available(macOS 15.4, *)
    static func pendingUpdateReport(_ id: String) async -> (extension: WKWebExtension, report: ExtensionReport)? {
        guard let pending = state(id)?.pendingVersion, let new = packageDirectory(for: id, version: pending),
              let old = packageDirectory(for: id), let newManifest = manifest(in: new), let oldManifest = manifest(in: old),
              let ext = try? await WKWebExtension(resourceBaseURL: new) else { return nil }
        return (ext, ExtensionReport(newIn: ext, manifest: newManifest, comparedTo: oldManifest, id: id))
    }

    /// Loads an extension from a folder on disk, for testing one you're building. Its ID comes from the
    /// folder's path, the way Chrome does it, so reloading the same folder keeps its data.
    static func loadUnpacked(_ url: URL) async -> String? {
        guard #available(macOS 15.4, *),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        let id = CRXPackage.extensionID(Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16)))
        save(State(version: manifestVersion(in: url) ?? "0", unpackedPath: url.standardizedFileURL.path), for: id)
        removedIDs.remove(id)
        let context = await ExtensionHost.shared.load(id)
        return context?.webExtension.displayName
    }

    /// Re-reads an unpacked extension's files.
    static func reloadUnpacked(_ id: String) async {
        guard #available(macOS 15.4, *), isUnpacked(id) else { return }
        ExtensionHost.shared.unload(id)
        await ExtensionHost.shared.load(id)
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
        guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(.download) }
        guard let package = try? CRXPackage(data, expectedID: id) else { return .failure(.verification) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-ext-\(UUID().uuidString)")
        let zipFile = staging.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: zipFile) }
        do {
            try package.zip.write(to: zipFile)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipFile.path, staging.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0, let version = manifestVersion(in: staging) else {
                try? FileManager.default.removeItem(at: staging)
                return .failure(.unpack)
            }
            return .success((staging, version))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.unpack)
        }
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

    private static func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func manifestVersion(in folder: URL) -> String? {
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
        for id in installedIDs where !isUnpacked(id) { await updateIfNewer(id) }
    }

    /// Asks the store for the latest version only; downloads it when it's newer. An update that asks for
    /// nothing new replaces the running version; one that asks for more waits for approval.
    static func updateIfNewer(_ id: String) async {
        guard #available(macOS 15.4, *), let current = state(id), let latest = await latestVersion(of: id, current: current.version),
              isVersion(latest, newerThan: current.version), latest != current.pendingVersion else { return }
        guard case .success(let package) = await download(id), store(package, for: id),
              let old = packageDirectory(for: id), let new = packageDirectory(for: id, version: package.version) else { return }
        if asksForMore(new, than: old) {
            update(id) { $0.pendingVersion = package.version }
            ExtensionHost.shared.changed.send()
            return
        }
        await switchVersion(of: id, to: package.version)
    }

    /// Approves a held-back update: its new permissions are granted and it replaces the running version.
    static func approvePendingUpdate(_ id: String) async {
        guard let pending = state(id)?.pendingVersion else { return }
        update(id) {
            $0.pendingVersion = nil
            // Re-recorded from the new version's request on load.
            $0.grantedPermissions = nil
            $0.grantedMatchPatterns = nil
        }
        await switchVersion(of: id, to: pending)
    }

    /// Makes a version current and reloads the extension with it, going back to the old one if it won't load.
    private static func switchVersion(of id: String, to version: String) async {
        guard #available(macOS 15.4, *), let previous = state(id)?.version else { return }
        update(id) { $0.version = version; $0.pendingVersion = nil }
        guard isEnabled(id) else { removeVersions(of: id, keeping: [version]); return }
        ExtensionHost.shared.unload(id)
        if await ExtensionHost.shared.load(id) != nil {
            removeVersions(of: id, keeping: [version])
        } else {
            update(id) { $0.version = previous }
            await ExtensionHost.shared.load(id)
        }
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

    /// Takes the extension out of Zigzag and deletes its files and everything it stored.
    static func uninstall(_ id: String) {
        guard #available(macOS 15.4, *) else { return }
        let unpacked = isUnpacked(id)
        ExtensionHost.shared.unload(id)
        ExtensionHost.shared.removeData(for: id)
        // An unpacked extension's own folder belongs to its developer; only our record of it goes.
        try? FileManager.default.removeItem(at: folder(for: id))
        if !unpacked { removedIDs.insert(id) }
        ExtensionHost.shared.forget(id)
    }

    static func setEnabled(_ id: String, _ enabled: Bool) {
        guard #available(macOS 15.4, *), isEnabled(id) != enabled else { return }
        update(id) { $0.enabled = enabled }
        if enabled {
            Task { await ExtensionHost.shared.load(id) }
        } else {
            ExtensionHost.shared.unload(id)
        }
    }

    // MARK: Older installs

    /// Builds before this one unpacked straight into Extensions/<id>/ and edited the package to load a shim.
    /// Those get a fresh, verified copy from the store. Offline, the edit is undone in place instead.
    private static func migrateLegacyInstalls() async {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: "DisabledExtensions") ?? [])
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where isExtensionID(id) {
            let legacy = folder(for: id)
            guard state(id) == nil, FileManager.default.fileExists(atPath: legacy.appendingPathComponent("manifest.json").path) else { continue }
            let moved = root.appendingPathComponent(".legacy-\(id)-\(UUID().uuidString)")
            guard (try? FileManager.default.moveItem(at: legacy, to: moved)) != nil else { continue }
            if case .success(let package) = await download(id), store(package, for: id) {
                try? FileManager.default.removeItem(at: moved)
                save(State(version: package.version, enabled: !disabled.contains(id)), for: id)
            } else if let version = manifestVersion(in: moved) {
                undoLegacyPatch(in: moved)
                try? FileManager.default.createDirectory(at: versionsFolder(for: id), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: moved, to: versionsFolder(for: id).appendingPathComponent(version))
                save(State(version: version, enabled: !disabled.contains(id)), for: id)
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

/// Per-extension adjustments the host applies, never by editing the package (see EXTENSIONS.md).
enum ExtensionProfile {
    struct Profile {
        /// `browser.*` paths hidden from the extension, so it takes its own fallback instead of calling into nothing.
        var unsupportedAPIs: Set<String> = []
        /// Script run in the background before the extension's own, for APIs it calls without checking.
        var backgroundPrelude: String?
        /// The same, for the extension's own pages (popup, options), run before any of their scripts.
        var pagePrelude: String?
        /// Permissions the prelude stands in for well enough that the person won't miss them.
        var coveredPermissions: Set<String> = []
    }

    static func profile(for id: String) -> Profile? { profiles[id] }

    /// Every page prelude, by extension ID.
    static var pagePreludes: [(id: String, source: String)] { profiles.compactMap { id, profile in profile.pagePrelude.map { (id, $0) } } }

    private static let profiles: [String: Profile] = [
        ExtensionStore.onePasswordID: Profile(backgroundPrelude: diagnostics + onePasswordPrelude, pagePrelude: diagnostics,
                                              coveredPermissions: ["management", "privacy", "idle"]),
        "nngceckbapebfimnlniiiahkandclblb": Profile(backgroundPrelude: bitwardenPrelude, pagePrelude: bitwardenPrelude, coveredPermissions: ["idle"]),
    ]

    /// Reports the extension's uncaught errors, failed promises and console errors to Zigzag's extensions log,
    /// through a native host only Zigzag answers. Only error text, cut short; never the extension's data.
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
        try { const sent = api.runtime.sendNativeMessage('\(diagnosticsHost)', { kind, where, text: String(value).slice(0, 400) }); if (sent && sent.catch) sent.catch(() => {}); } catch (e) {}
      };
      globalThis.addEventListener && globalThis.addEventListener('error', (e) => report('error', (e.message || '') + ' @ ' + String(e.filename || '').split('/').pop() + ':' + (e.lineno || 0)));
      globalThis.addEventListener && globalThis.addEventListener('unhandledrejection', (e) => report('rejection', text(e.reason)));
      const original = console.error;
      console.error = function (...args) { report('console.error', args.map(text).filter(Boolean).join(' ')); return original.apply(this, args); };
      const warn = console.warn;
      console.warn = function (...args) { report('console.warn', args.map(text).filter(Boolean).join(' ')); return warn.apply(this, args); };
      // How WebAssembly loads: what, how big, how long, and whether it worked.
      if (globalThis.WebAssembly) {
        for (const name of ['instantiate', 'instantiateStreaming', 'compile', 'compileStreaming']) {
          const original = WebAssembly[name];
          if (typeof original !== 'function') continue;
          WebAssembly[name] = function (source, ...rest) {
            const started = Date.now();
            const what = source && source.byteLength !== undefined ? source.byteLength + ' bytes' : (source && source.url) || (source instanceof Promise ? 'response' : typeof source);
            report('wasm', name + ' start ' + what);
            const result = original.call(this, source, ...rest);
            Promise.resolve(result).then(() => report('wasm', name + ' ok in ' + (Date.now() - started) + 'ms'),
                                         (e) => report('wasm', name + ' FAILED in ' + (Date.now() - started) + 'ms: ' + text(e)));
            return result;
          };
        }
      } else {
        report('wasm', 'WebAssembly is missing here');
      }
      // Network, as host and path only (no query, no bodies): what it asked for, and what came back.
      const place = (u) => { try { const x = new URL(String(u && u.url || u), location.href); return x.host + x.pathname.slice(0, 60); } catch (e) { return '?'; } };
      if (globalThis.fetch) {
        const fetched = globalThis.fetch;
        globalThis.fetch = function (input, init) {
          const started = Date.now(), at = place(input);
          if (!at.startsWith('aeblfdkh')) report('fetch', 'start ' + at);
          const result = fetched.call(this, input, init);
          result.then((r) => { if (!at.startsWith('aeblfdkh') || !r.ok) report('fetch', r.status + ' ' + at + ' in ' + (Date.now() - started) + 'ms'); },
                      (e) => report('fetch', 'FAILED ' + at + ' in ' + (Date.now() - started) + 'ms: ' + text(e)));
          return result;
        };
      }
      if (globalThis.WebSocket) {
        const Socket = globalThis.WebSocket;
        globalThis.WebSocket = function (url, protocols) {
          const socket = protocols === undefined ? new Socket(url) : new Socket(url, protocols);
          const at = place(url);
          report('socket', 'open ' + at);
          socket.addEventListener('open', () => report('socket', 'connected ' + at));
          socket.addEventListener('error', () => report('socket', 'error ' + at));
          socket.addEventListener('close', (e) => report('socket', 'closed ' + at + ' code ' + e.code));
          return socket;
        };
        globalThis.WebSocket.prototype = Socket.prototype;
        Object.assign(globalThis.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
      }
      // Local databases: whether opening one works, and whether a request ever finishes.
      if (globalThis.indexedDB) {
        const open = indexedDB.open.bind(indexedDB);
        indexedDB.open = function (name, version) {
          const request = version === undefined ? open(name) : open(name, version);
          const started = Date.now(), label = 'indexedDB.open ' + String(name).slice(0, 40);
          let done = false;
          const timer = setTimeout(() => { if (!done) report('waiting', label + ' has not opened after 3s'); }, 3000);
          request.addEventListener('success', () => { done = true; clearTimeout(timer); report('db', label + ' ok in ' + (Date.now() - started) + 'ms'); });
          request.addEventListener('error', () => { done = true; clearTimeout(timer); report('db', label + ' FAILED: ' + text(request.error)); });
          request.addEventListener('blocked', () => report('db', label + ' blocked by another connection'));
          return request;
        };
      } else {
        report('db', 'indexedDB is missing here');
      }
      if (globalThis.navigator && !navigator.locks) report('api', 'navigator.locks is missing here');
      if (globalThis.caches === undefined) report('api', 'caches is missing here');
      // Browser API calls that never answer stall an extension silently: name any still waiting after 3 seconds.
      const watch = (path, target) => {
        if (!target || typeof target !== 'object') return;
        for (const key of Object.keys(Object.getPrototypeOf(target) || {}).concat(Object.keys(target))) {
          let value;
          try { value = target[key]; } catch (e) { continue; }
          if (typeof value === 'function' && !key.startsWith('on') && !/^[A-Z]/.test(key)) {
            try {
              target[key] = function (...args) {
                const result = value.apply(this, args);
                if (result && typeof result.then === 'function') {
                  let settled = false;
                  const started = Date.now();
                  const timer = setTimeout(() => { if (!settled) report('waiting', path + '.' + key + ' has not answered after 3s'); }, 3000);
                  result.then(() => { settled = true; clearTimeout(timer); if (Date.now() - started > 3000) report('waiting', path + '.' + key + ' answered after ' + (Date.now() - started) + 'ms'); },
                              (e) => { settled = true; clearTimeout(timer); report('api', path + '.' + key + ' failed: ' + text(e)); });
                }
                return result;
              };
            } catch (e) {}
          }
        }
      };
      for (const name of ['runtime', 'tabs', 'windows', 'scripting', 'action', 'alarms', 'permissions', 'contextMenus', 'declarativeNetRequest', 'webNavigation', 'cookies', 'i18n', 'commands', 'offscreen']) {
        try { watch(name, api[name]); } catch (e) {}
      }
      for (const area of ['local', 'session', 'sync']) { try { watch('storage.' + area, api.storage && api.storage[area]); } catch (e) {} }
      report('started', '');
    })();

    """

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
    /// The folder WebKit loads. Usually the untouched package itself. An extension whose profile needs a
    /// background prelude gets a sibling folder of hard links to the same files, plus a manifest that runs
    /// the prelude first. The package keeps its exact bytes either way.
    static func loadDirectory(for id: String) -> URL? {
        guard let package = packageDirectory(for: id), let state = state(id) else { return nil }
        guard let prelude = ExtensionProfile.profile(for: id)?.backgroundPrelude else { return package }
        let overlay = folder(for: id).appendingPathComponent("loaded", isDirectory: true).appendingPathComponent(state.version, isDirectory: true)
        let marker = overlay.appendingPathComponent("zigzag-prelude.js")
        if (try? String(contentsOf: marker, encoding: .utf8)) == prelude { return overlay }
        try? FileManager.default.removeItem(at: overlay.deletingLastPathComponent())
        guard linkTree(from: package, to: overlay), writeOverlayManifest(in: overlay, from: package, prelude: prelude) else { return package }
        return overlay
    }

    private static func linkTree(from source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil,
              let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for case let item as URL in enumerator {
            let relative = String(item.path.dropFirst(source.path.count + 1))
            guard relative != "manifest.json" else { continue }
            let destination = target.appendingPathComponent(relative)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if (try? fm.linkItem(at: item, to: destination)) == nil {
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
