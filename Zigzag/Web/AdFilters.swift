import CryptoKit
import Foundation
import JavaScriptCore
import Network
import os
import WebKit

/// The part of ad blocking WebKit's content blocker can't do: the scriptlets and per-site hiding in uBlock Origin's
/// filter lists, which is how every major blocker keeps YouTube's ads out. Ghostery's adblocker engine
/// (Resources/AdEngine) matches them; each page is handed what its own site needs as it starts to load (PageFilters).
///
/// The lists and the scriptlets come from their publishers, not with Zigzag: they're downloaded at launch and again as
/// they expire, kept when a download fails, and swapped in whole once the engine has taken them. So the lists' fixes
/// (YouTube's, most often) arrive within hours, without an update to Zigzag. The engine is MPL-2.0 and ships as its
/// own, unmodified file. The lists and the scriptlets (GPL-3.0) never ship in Zigzag: each Mac downloads them, as
/// every blocker's users do; a first launch has them a few seconds in.
///
/// Zigzag's own fixes for sites its blocking gets in the way of are a list too, "Zigzag fixes", in the same syntax:
/// site/filters/zigzag-fixes.txt, published at zigzagbrowser.com/filters/zigzag-fixes.txt with the website, and in the
/// app as the copy used until the first download comes (or while offline). It's downloaded, checked, kept and run as
/// uBlock Origin's lists are, so a site fix is a line there, not code. To add one: a line with the site and what it
/// needs (a scriptlet such as `example.com##+js(prevent-fetch, /blocked/path)`, a hiding rule, or an exception to the
/// lists before it such as `example.com#@#+js(...)`), its issue in a comment above it; deploy the site
/// (site/deploy.sh); every Zigzag has it within the list's "Expires" time (12 hours), pages from their next load, with
/// no release. Only what the engine takes reaches pages: scriptlets, exceptions and hiding for a named site. Letting
/// a blocked request through instead belongs in the content blocker's lists (scripts/update_blocklists.sh), which come
/// with releases.
///
/// What a list can do, then, whoever writes it (Zigzag's own included): name one of the scriptlets and hand it strings,
/// and hide elements with a style sheet. It brings no code of its own: a filter's arguments only ever reach a scriptlet
/// as strings (ad-engine.js, scriptFor), and a style sheet runs nothing. The code that runs in pages is the scriptlets',
/// and only a revision whose SHA-256 this release was built with is taken (`pinnedScriptletRevisions`): a download that
/// is anything else, the CDN's or someone's in between, is never used. Without a pinned copy the lists still hide what
/// they name and no scriptlet runs. scripts/pin-scriptlets.sh moves the pin to Ghostery's newest revision before a
/// release; release.sh warns when it isn't.
///
/// Some scriptlets uBlock Origin runs only from its own lists (`requiresTrust`, the trusted-* ones: they set cookies,
/// click, rewrite a page's scripts). Here too: a list that isn't uBlock Origin's, Zigzag's own included, has those
/// lines left out before the engine takes it (ad-engine.js, withoutTrustedScriptlets). And a hiding rule whose
/// selector holds `{`, `}`, `@` or `;` never reaches a style sheet, so a list can only hide, not write CSS of its own.
nonisolated enum AdFilterSources {
    struct List: Sendable {
        let id: String
        /// The publisher's addresses, in the order uBlock Origin itself tries them.
        let urls: [URL]
        /// The name of the copy in the app, used until a download has come (Zigzag's own list only).
        var bundled: String?
        /// The size below which a download is taken for a cut-off or error page. Zigzag's own list is short.
        var minimumSize = 1_000
        /// One of uBlock Origin's own lists, the only ones whose trusted-* scriptlets run.
        var trusted = false

        /// The copy in the app, if the list has one.
        var bundledData: Data? {
            bundled.flatMap { Bundle.main.url(forResource: $0, withExtension: "txt") }.flatMap { try? Data(contentsOf: $0) }
        }
    }

    private static func urls(_ strings: String...) -> [URL] { strings.compactMap(URL.init(string:)) }

    /// uBlock Origin's own lists, then Zigzag's. Quick fixes, where YouTube's fixes land first, comes from its source
    /// before the mirrors, which follow it by hours.
    static let lists: [List] = [
        List(id: "ublock-filters", urls: urls("https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt",
                                              "https://ublockorigin.pages.dev/filters/filters.min.txt",
                                              "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/filters.min.txt"), trusted: true),
        List(id: "ublock-quick-fixes", urls: urls("https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt",
                                                  "https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt",
                                                  "https://ublockorigin.pages.dev/filters/quick-fixes.min.txt",
                                                  "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/quick-fixes.min.txt"), trusted: true),
        List(id: "ublock-unbreak", urls: urls("https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt",
                                              "https://ublockorigin.pages.dev/filters/unbreak.min.txt",
                                              "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/unbreak.min.txt"), trusted: true),
        zigzagFixes,
    ]

    /// Zigzag's own site fixes, last, so they can make exceptions to the lists before them.
    static let zigzagFixes = List(id: "zigzag-fixes", urls: urls("https://zigzagbrowser.com/filters/zigzag-fixes.txt"),
                                  bundled: "zigzag-fixes", minimumSize: 100)

    /// uBlock Origin's scriptlets, as Ghostery publishes them for its engine: each version at an address named for its
    /// SHA-256, never changed once published.
    static func scriptlets(revision: String) -> URL {
        URL(string: "https://cdn.ghostery.com/adblocker/resources/ublock-resources-json/\(revision)/list.txt")!
    }

    /// A list as its publisher writes one: text that starts with its title, and more than a few lines of it.
    static func isList(_ data: Data, minimumSize: Int = 1_000) -> Bool {
        guard data.count > minimumSize, let head = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return head.hasPrefix("! Title:") || head.hasPrefix("[Adblock") && head.contains("! Title:")
    }

    /// How long a list says it stays fresh ("! Expires: 12 hours", "5 days"), kept between 6 hours and a day.
    static func lifetime(of data: Data) -> TimeInterval {
        let day: TimeInterval = 86_400
        guard let head = String(data: data.prefix(2_048), encoding: .utf8),
              let line = head.split(separator: "\n").first(where: { $0.hasPrefix("! Expires:") }) else { return day }
        let words = line.dropFirst("! Expires:".count).split(separator: " ")
        guard let count = words.first.flatMap({ Double($0) }) else { return day }
        let unit = words.dropFirst().first?.lowercased() ?? "days"
        let seconds = unit.hasPrefix("hour") ? count * 3_600 : count * day
        return min(max(seconds, 6 * 3_600), day)
    }

    /// The scriptlet revisions this release runs, newest first, by SHA-256: the code that runs in pages, so it's taken
    /// only as reviewed and released, never as whatever the CDN serves now. Set by scripts/pin-scriptlets.sh, which
    /// keeps the one before so a Mac with the last release's copy keeps using it until the new one has downloaded.
    static let pinnedScriptletRevisions: [String] = [
        "0b0a50a9dbf263c650e7a901a9f66523c1ee96b73f9d026791b9ea03cfc7a43d",
    ]

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Scriptlets whose SHA-256 is the revision they were asked for, and that read as the engine's resources.
    static func isScriptlets(_ data: Data, revision: String) -> Bool {
        guard sha256(data) == revision,
              let resources = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scriptlets = resources["scriptlets"] as? [[String: Any]] else { return false }
        return scriptlets.count >= 50
    }
}

/// What one document is handed: scriptlets that run beside the page's own scripts, scriptlets that run apart from
/// them, and a style sheet hiding what the lists name on its site.
nonisolated struct AdInjection: Sendable, Equatable {
    var page: [String] = []
    var isolated: [String] = []
    var styles = ""
    var isEmpty: Bool { page.isEmpty && isolated.isEmpty && styles.isEmpty }
}

/// The engine, its lists and their updates. Matching runs on a queue of its own; building from new lists runs on
/// another, in a context of its own, so pages are never kept waiting while the lists change.
nonisolated final class AdEngine: @unchecked Sendable {
    static let shared = AdEngine(directory: Paths.directory("Ad Filters"))

    let directory: URL
    /// The scriptlet revisions taken, newest first (AdFilterSources.pinnedScriptletRevisions).
    let pinnedRevisions: [String]
    private let session: URLSession
    private let queue = DispatchQueue(label: "app.zigzag.ad-engine", qos: .userInitiated)
    private let building = DispatchQueue(label: "app.zigzag.ad-engine.build", qos: .utility)
    /// The context pages are matched in. Used on `queue` only.
    private var context: JSContext?
    private var cache: [String: AdInjection] = [:]

    struct Status: Sendable {
        /// Counts up each time a new set of lists is taken, so pages loaded before it get the new one on their next load.
        var generation = 0
        var ready = false
        var filters = 0
        var scriptlets = 0
        var builtIn: TimeInterval = 0
        var loadedIn: TimeInterval = 0
        var updated: Date?
        var lastError: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: Status())
    var status: Status { state.withLock { $0 } }

    /// Called on the main thread when a new set of lists is in use.
    var onChange: (@Sendable () -> Void)?

    /// Gets one pinned scriptlet revision, or nil when it can't be had now (offline, the CDN down). What it brings is
    /// taken only if it hashes to the revision.
    typealias ScriptletFetcher = @Sendable (_ revision: String) async -> Data?
    /// Starts watching for the network to come back, calling the closure each time it does, until what it returns
    /// goes.
    typealias NetworkWatcher = (_ cameBack: @escaping @Sendable () -> Void) -> AnyObject

    private let fetchScriptlets: ScriptletFetcher
    private let watchNetwork: NetworkWatcher
    /// How long to wait before asking again for pinned scriptlets that didn't come, by try; the last repeats.
    private let retryDelays: [TimeInterval]

    init(directory: URL, session: URLSession? = nil, pinnedRevisions: [String] = AdFilterSources.pinnedScriptletRevisions,
         fetchScriptlets: ScriptletFetcher? = nil, watchNetwork: NetworkWatcher? = nil,
         retryDelays: [TimeInterval] = [5, 15, 60, 300, 900]) {
        self.directory = directory
        self.pinnedRevisions = pinnedRevisions
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["User-Agent": "Zigzag"]
            return URLSession(configuration: configuration)
        }()
        self.session = session
        self.fetchScriptlets = fetchScriptlets ?? { revision in
            guard let (data, response) = try? await session.data(from: AdFilterSources.scriptlets(revision: revision)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        self.watchNetwork = watchNetwork ?? { ScriptletNetworkWatch(cameBack: $0) }
        self.retryDelays = retryDelays.isEmpty ? [900] : retryDelays
        adoptLegacyScriptlets()
    }

    // MARK: Files

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    /// Each pinned revision downloaded, in a file of its own named for it: one a release has moved on from stays
    /// until the new one is here, and a Mac back on an older release finds its revision still there.
    private var scriptletsDirectory: URL { file("Scriptlets") }
    func scriptletsFile(revision: String) -> URL { scriptletsDirectory.appendingPathComponent(revision + ".json") }
    /// Where releases before the per-revision files kept the one copy.
    private var legacyScriptletsFile: URL { file("scriptlets.json") }
    private func listFile(_ id: String) -> URL { file(id + ".txt") }
    private var engineFile: URL { file("engine.bin") }
    private var engineInfoFile: URL { file("engine.json") }
    private var stateFile: URL { file("state.json") }

    /// What each download last brought: its validators, so the next asks only for what changed, and when.
    struct Fetched: Codable, Sendable {
        var url: String
        var etag: String?
        var lastModified: String?
        var checked: Date
        var lifetime: TimeInterval
        var revision: String?
    }

    private func readFetched() -> [String: Fetched] {
        guard let data = try? Data(contentsOf: stateFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Fetched].self, from: data)) ?? [:]
    }

    private func writeFetched(_ fetched: [String: Fetched]) {
        if let data = try? JSONEncoder().encode(fetched) { try? data.write(to: stateFile, options: .atomic) }
    }

    /// The engine's resources with no scriptlets, for while no pinned copy is here.
    static let noScriptlets = #"{"scriptlets":[],"redirects":[]}"#

    /// The newest pinned revision kept here, checked again as it's read: a copy left from before pinning, one a
    /// release no longer pins, or one changed on disk is never used.
    private func pinnedScriptlets() -> (revision: String, data: Data)? {
        for revision in pinnedRevisions {
            if let data = try? Data(contentsOf: scriptletsFile(revision: revision)), AdFilterSources.sha256(data) == revision {
                return (revision, data)
            }
        }
        return nil
    }

    /// The one copy an earlier release kept: into its revision's file if it's one this release pins. It goes either way.
    private func adoptLegacyScriptlets() {
        guard let data = try? Data(contentsOf: legacyScriptletsFile) else { return }
        let revision = AdFilterSources.sha256(data)
        if pinnedRevisions.contains(revision) { _ = install(data, revision: revision) }
        try? FileManager.default.removeItem(at: legacyScriptletsFile)
    }

    /// Keeps a downloaded revision in its own file, and of the others no more than the two last kept.
    private func install(_ data: Data, revision: String) -> Bool {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: scriptletsDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: scriptletsFile(revision: revision), options: .atomic)) != nil else { return false }
        let others = ((try? fileManager.contentsOfDirectory(at: scriptletsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent != revision + ".json" && !pinnedRevisions.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { modified($0) > modified($1) }
        for old in others.dropFirst(2) { try? fileManager.removeItem(at: old) }
        return true
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The downloaded lists and scriptlets as they are now (Zigzag's own list from the app until it's downloaded), or
    /// nil while a list is missing. Without pinned scriptlets the lists are used with none.
    private func inputs() -> (lists: [String], trusted: [Bool], scriptlets: String, checksum: String)? {
        var lists: [String] = []
        var hash = SHA256()
        // How the lists are read, so an engine saved by a release that read them otherwise is built again.
        hash.update(data: Data(Self.readingRevision.utf8))
        for list in AdFilterSources.lists {
            guard let data = (try? Data(contentsOf: listFile(list.id))) ?? list.bundledData, let text = String(data: data, encoding: .utf8) else { return nil }
            lists.append(text)
            hash.update(data: data)
        }
        let data = pinnedScriptlets()?.data ?? Data(Self.noScriptlets.utf8)
        guard let scriptlets = String(data: data, encoding: .utf8) else { return nil }
        hash.update(data: data)
        return (lists, AdFilterSources.lists.map(\.trusted), scriptlets, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Changed whenever ad-engine.js changes what it keeps of the lists.
    private static let readingRevision = "trusted-lists-1"

    // MARK: Starting

    /// Takes the lists Zigzag has, ready-built if this engine built them before, then checks for newer ones.
    func start() {
        queue.async { [self] in
            let started = Date()
            guard let context = makeContext() else { return }
            self.context = context
            let version = context.evaluateScript("ZigzagAdEngine.version()")?.toInt32() ?? -1
            if let inputs = inputs(), let info = try? Data(contentsOf: engineInfoFile),
               let saved = try? JSONDecoder().decode(EngineInfo.self, from: info),
               saved.version == version, saved.checksum == inputs.checksum,
               let bytes = try? Data(contentsOf: engineFile), load(bytes, into: context) {
                adopt(filters: saved.filters, scriptlets: saved.scriptlets, loadedIn: Date().timeIntervalSince(started), builtIn: nil)
            } else {
                rebuild()
            }
        }
        // Without this release's newest pinned scriptlets (the copy here is a release's before), they're asked for
        // now, on their own, rather than behind the lists or not until the next update.
        ensureScriptlets()
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: building)
        timer.schedule(deadline: .now() + 3_600, repeating: 3_600, leeway: .seconds(300))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    private struct EngineInfo: Codable {
        var version: Int32
        var checksum: String
        var filters: Int
        var scriptlets: Int
    }

    private func makeContext() -> JSContext? {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        for name in ["ad-engine", "ghostery-adblocker"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(source, withSourceURL: url)
        }
        return context.evaluateScript("typeof ZigzagAdEngine.build")?.toString() == "function" ? context : nil
    }

    private func load(_ bytes: Data, into context: JSContext) -> Bool {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 16)
        bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, buffer, bytes.count,
                                                                { bytes, _ in bytes?.deallocate() }, nil, &exception),
              exception == nil else { buffer.deallocate(); return false }
        context.exception = nil
        context.objectForKeyedSubscript("ZigzagAdEngine").invokeMethod("load", withArguments: [JSValue(jsValueRef: array, in: context) as Any])
        return context.exception == nil
    }

    /// Builds from the lists on disk in a context of its own, then hands the result to the one pages are matched in.
    /// A set of lists the engine can't take leaves the one in use as it was.
    private func rebuild() {
        building.async { [self] in
            guard let inputs = inputs(), let builder = makeContext() else { return }
            let started = Date()
            builder.exception = nil
            let api = builder.objectForKeyedSubscript("ZigzagAdEngine")
            let result = api?.invokeMethod("build", withArguments: [inputs.lists, inputs.scriptlets, inputs.checksum, inputs.trusted])?.toString()
            if let error = builder.exception?.toString() {
                state.withLock { $0.lastError = "Couldn't build: \(error)" }
                return
            }
            guard let serialized = api?.invokeMethod("serialize", withArguments: []), let bytes = Self.bytes(of: serialized, in: builder),
                  let counts = result.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Int] }) else { return }
            let builtIn = Date().timeIntervalSince(started)
            let version = builder.evaluateScript("ZigzagAdEngine.version()")?.toInt32() ?? -1
            let info = EngineInfo(version: version, checksum: inputs.checksum, filters: counts["filters"] ?? 0, scriptlets: counts["scriptlets"] ?? 0)
            try? bytes.write(to: engineFile, options: .atomic)
            if let data = try? JSONEncoder().encode(info) { try? data.write(to: engineInfoFile, options: .atomic) }
            queue.async { [self] in
                let loading = Date()
                if context == nil { context = makeContext() }
                guard let context, load(bytes, into: context) else { return }
                adopt(filters: info.filters, scriptlets: info.scriptlets, loadedIn: Date().timeIntervalSince(loading), builtIn: builtIn)
            }
        }
    }

    private static func bytes(of value: JSValue, in context: JSContext) -> Data? {
        let ref = context.jsGlobalContextRef
        guard let object = JSValueToObject(ref, value.jsValueRef, nil),
              let pointer = JSObjectGetTypedArrayBytesPtr(ref, object, nil) else { return nil }
        let count = JSObjectGetTypedArrayByteLength(ref, object, nil)
        return count > 0 ? Data(bytes: pointer, count: count) : nil
    }

    /// On `queue`: a new set of lists in use.
    private func adopt(filters: Int, scriptlets: Int, loadedIn: TimeInterval, builtIn: TimeInterval?) {
        cache = [:]
        state.withLock {
            $0.generation += 1
            $0.ready = true
            $0.filters = filters
            $0.scriptlets = scriptlets
            $0.loadedIn = loadedIn
            if let builtIn { $0.builtIn = builtIn }
            $0.lastError = nil
        }
        let onChange = onChange
        DispatchQueue.main.async { onChange?() }
    }

    // MARK: Matching

    /// What a document at this address is handed. Nothing while no lists are in use yet.
    func injection(for url: URL) async -> AdInjection {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: match(url)) }
        }
    }

    private func match(_ url: URL) -> AdInjection {
        guard let host = url.host()?.lowercased(), let context, status.ready else { return AdInjection() }
        if let cached = cache[host] { return cached }
        // Scriptlets go by host, so one answer serves every page of it.
        let answer = context.objectForKeyedSubscript("ZigzagAdEngine").invokeMethod("page", withArguments: ["https://\(host)/"])?.toString()
        var injection = AdInjection()
        if let data = answer?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            injection.page = json["page"] as? [String] ?? []
            injection.isolated = json["isolated"] as? [String] ?? []
            injection.styles = json["styles"] as? String ?? ""
        }
        if cache.count > 200 { cache = [:] }
        cache[host] = injection
        return injection
    }

    // MARK: Updating

    private let refreshing = OSAllocatedUnfairLock(initialState: false)
    private var timer: DispatchSourceTimer?

    /// Downloads whatever has expired (all of it, the first time) and builds from it if anything changed. `start`
    /// looks every hour, so a Mac that slept through an update time catches up when it wakes.
    func refresh(force: Bool = false) {
        guard refreshing.withLock({ busy in defer { busy = true }; return !busy }) else { return }
        Task.detached(priority: .utility) { [self] in
            let changed = await update(force: force)
            refreshing.withLock { $0 = false }
            if changed { rebuild() }
        }
    }

    /// Returns whether a list or the scriptlets changed on disk.
    func update(force: Bool = false) async -> Bool {
        var fetched = readFetched()
        var changed = false
        let now = Date()
        func due(_ id: String, _ file: URL) -> Bool {
            guard !force, let last = fetched[id], FileManager.default.fileExists(atPath: file.path) else { return true }
            return now.timeIntervalSince(last.checked) >= last.lifetime
        }
        for list in AdFilterSources.lists where due(list.id, listFile(list.id)) {
            for url in list.urls {
                let known = fetched[list.id].flatMap { $0.url == url.absoluteString ? $0 : nil }
                guard let (data, response) = await get(url, etag: known?.etag, lastModified: known?.lastModified) else { continue }
                if response.statusCode == 304, known != nil, FileManager.default.fileExists(atPath: listFile(list.id).path) {
                    fetched[list.id]?.checked = now
                    break
                }
                guard response.statusCode == 200, AdFilterSources.isList(data, minimumSize: list.minimumSize) else { continue }
                if (try? Data(contentsOf: listFile(list.id))) != data {
                    guard (try? data.write(to: listFile(list.id), options: .atomic)) != nil else { continue }
                    changed = true
                }
                fetched[list.id] = Fetched(url: url.absoluteString, etag: response.value(forHTTPHeaderField: "ETag"),
                                           lastModified: response.value(forHTTPHeaderField: "Last-Modified"), checked: now,
                                           lifetime: AdFilterSources.lifetime(of: data))
                break
            }
        }
        // Unless they're being asked for already, or will be again shortly (ensureScriptlets).
        if force || !withRetry({ $0.running || $0.pending != nil }), await updateScriptlets() { changed = true }
        writeFetched(fetched)
        if changed { state.withLock { $0.updated = now } }
        return changed
    }

    // MARK: Pinned scriptlets

    /// Whether this release's newest pinned revision is missing here (an older pinned copy may still be in use).
    var needsScriptlets: Bool {
        guard let newest = pinnedRevisions.first else { return false }
        return pinnedScriptlets()?.revision != newest
    }

    private struct Retry {
        var attempt = 0
        var pending: DispatchWorkItem?
        var watch: AnyObject?
        /// Whether ensureScriptlets is asking now; it decides itself when to ask again.
        var running = false
        /// The fetch running now; the next one waits for it, so one revision is never downloaded twice at once.
        var last: Task<Bool, Never>?
    }
    private let retryLock = NSLock()
    private var retryState = Retry()
    private func withRetry<T>(_ body: (inout Retry) -> T) -> T { retryLock.withLock { body(&retryState) } }

    /// Fetches the pinned scriptlets now if they're missing, and builds with them once they're here.
    func ensureScriptlets() {
        guard needsScriptlets, withRetry({ state in defer { state.running = true }; return !state.running }) else { return }
        Task.detached(priority: .utility) { [self] in
            if await updateScriptlets() { rebuild() }
        }
    }

    /// Downloads the pinned revisions newer than the one here, newest first, and returns whether one came. Each never
    /// changes, so there's nothing to look up: it's downloaded once, and kept only if it hashes to its pin. Failing
    /// that, an older pinned copy stays in use, and it's asked for again: after a while, longer each time, and as
    /// soon as the network comes back.
    func updateScriptlets() async -> Bool {
        let task = withRetry { state -> Task<Bool, Never> in
            let previous = state.last
            let task = Task.detached(priority: .utility) { [self] () -> Bool in
                _ = await previous?.value
                return await fetchNewerScriptlets()
            }
            state.last = task
            return task
        }
        return await task.value
    }

    private func fetchNewerScriptlets() async -> Bool {
        guard needsScriptlets else { stopRetrying(); return false }
        let have = pinnedScriptlets()?.revision
        var installed = false
        for revision in pinnedRevisions.prefix(while: { $0 != have }) {
            guard let data = await fetchScriptlets(revision), AdFilterSources.isScriptlets(data, revision: revision),
                  install(data, revision: revision) else { continue }
            installed = true
            break
        }
        if needsScriptlets {
            withRetry { $0.running = false }
            retryLater()
        } else {
            stopRetrying()
        }
        return installed
    }

    private func retryLater() {
        let work = DispatchWorkItem { [weak self] in self?.retried() }
        let start = withRetry { state -> (delay: TimeInterval, watch: Bool)? in
            guard state.pending == nil else { return nil }
            let delay = retryDelays[min(state.attempt, retryDelays.count - 1)]
            state.attempt += 1
            state.pending = work
            return (delay, state.watch == nil)
        }
        guard let start else { return }
        building.asyncAfter(deadline: .now() + start.delay, execute: work)
        if start.watch {
            let watch = watchNetwork { [weak self] in self?.networkCameBack() }
            withRetry { if $0.pending != nil, $0.watch == nil { $0.watch = watch } }
        }
    }

    private func retried() {
        withRetry { $0.pending = nil }
        ensureScriptlets()
    }

    /// Back online: asked for at once, and the waits start short again.
    private func networkCameBack() {
        let pending = withRetry { state -> DispatchWorkItem? in
            defer { state.pending = nil; state.attempt = 0 }
            return state.pending
        }
        pending?.cancel()
        ensureScriptlets()
    }

    private func stopRetrying() {
        // The watch goes outside the lock: letting it go stops it.
        let (pending, watch) = withRetry { state -> (DispatchWorkItem?, AnyObject?) in
            defer { state.pending = nil; state.attempt = 0; state.watch = nil; state.running = false }
            return (state.pending, state.watch)
        }
        pending?.cancel()
        _ = watch
    }

    private func get(_ url: URL, etag: String?, lastModified: String?) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    /// When the lists in use were last downloaded, from what each download recorded.
    var listsChecked: Date? { readFetched().values.map(\.checked).max() }
}

/// Tells the ad engine when the Mac comes back online, while it waits for scriptlets that couldn't download: only a
/// change from offline to online, not the watch's first word on how things are.
nonisolated final class ScriptletNetworkWatch: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasOffline = false

    init(cameBack: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "app.zigzag.ad-engine.network", qos: .utility)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status != .satisfied { wasOffline = true; return }
            guard wasOffline else { return }
            wasOffline = false
            cameBack()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

/// Puts what the engine has for a site into a web view's page scripts before a document of that site starts: each
/// scriptlet on its own, so one that fails leaves the others running, and each only where the document's host is the
/// one it was made for. A web view keeps the scripts of the page it shows and of that page's frames only, so a site's
/// scriptlets aren't read by every page after it; a new set of lists, a site you allow ads on, or blocking turned off
/// clears them too.
enum PageFilters {
    /// Where the scriptlets that keep apart from a page's own scripts run, and the hiding.
    static let world = WKContentWorld.world(name: "ZigzagAdFilters")
    private static let mark = "/* zigzag ad filters */"
    /// A page with frames from more hosts than this starts over with the frames it loads next.
    private static let maxHosts = 16

    private final class Installed {
        var generation = -1
        var page: String?
        var hosts: Set<String> = []
    }
    private static let installed = NSMapTable<WKUserContentController, Installed>.weakToStrongObjects()

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// The hosts a set of page scripts has filters for, for the debug bridge.
    static func hosts(in controller: WKUserContentController) -> Set<String> { installed.object(forKey: controller)?.hosts ?? [] }

    /// Readies the filters for a document at `url`: the page itself (`mainFrame`) or one of its frames.
    static func prepare(_ controller: WKUserContentController, for url: URL, mainFrame: Bool, wanted: Bool, engine: AdEngine = .shared) async {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(), !host.isEmpty else { return }
        guard wanted else { clear(controller); return }
        let record = installed.object(forKey: controller) ?? {
            let record = Installed()
            installed.setObject(record, forKey: controller)
            return record
        }()
        let generation = engine.status.generation
        // A new set of lists, or a page on another host: the scripts for the page before it go.
        if record.generation != generation || mainFrame && record.page != host {
            clear(controller)
            record.generation = generation
        }
        if mainFrame { record.page = host }
        guard !record.hosts.contains(host) else { return }
        let injection = await engine.injection(for: url)
        // Something changed while the engine was asked (a clear, the same host from a frame): the newest answer stands.
        guard record.generation == generation, !record.hosts.contains(host) else { return }
        if record.hosts.count >= maxHosts { clear(controller) }
        record.hosts.insert(host)
        scripts(for: injection, host: host).forEach(controller.addUserScript)
    }

    /// Takes Zigzag's filters out of a set of page scripts, leaving the others as they were.
    static func clear(_ controller: WKUserContentController) {
        installed.object(forKey: controller)?.hosts = []
        installed.object(forKey: controller)?.page = nil
        OwnScripts.remove(from: controller, where: isOurs)
    }

    static func scripts(for injection: AdInjection, host: String) -> [WKUserScript] {
        let name = (try? JSONSerialization.data(withJSONObject: [host])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        func script(_ body: String, in world: WKContentWorld) -> WKUserScript {
            WKUserScript(source: "\(mark)\nif (location.hostname === \(name)) {\n\(body)\n}",
                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        }
        var scripts = injection.page.map { script($0, in: .page) } + injection.isolated.map { script($0, in: world) }
        if !injection.styles.isEmpty, let css = (try? JSONSerialization.data(withJSONObject: [injection.styles])).flatMap({ String(data: $0, encoding: .utf8) }) {
            scripts.append(script("""
            const style = document.createElement('style');
            style.textContent = \(css)[0];
            const add = () => (document.head || document.documentElement).appendChild(style);
            if (document.documentElement) add(); else document.addEventListener('readystatechange', add, { once: true });
            """, in: world))
        }
        return scripts
    }
}
