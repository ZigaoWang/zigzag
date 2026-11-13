import CryptoKit
import Foundation
import JavaScriptCore
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
nonisolated enum AdFilterSources {
    struct List: Sendable {
        let id: String
        /// The publisher's addresses, in the order uBlock Origin itself tries them.
        let urls: [URL]
        /// The name of the copy in the app, used until a download has come (Zigzag's own list only).
        var bundled: String?
        /// The size below which a download is taken for a cut-off or error page. Zigzag's own list is short.
        var minimumSize = 1_000

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
                                              "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/filters.min.txt")),
        List(id: "ublock-quick-fixes", urls: urls("https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt",
                                                  "https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt",
                                                  "https://ublockorigin.pages.dev/filters/quick-fixes.min.txt",
                                                  "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/quick-fixes.min.txt")),
        List(id: "ublock-unbreak", urls: urls("https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt",
                                              "https://ublockorigin.pages.dev/filters/unbreak.min.txt",
                                              "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/filters/unbreak.min.txt")),
        zigzagFixes,
    ]

    /// Zigzag's own site fixes, last, so they can make exceptions to the lists before them.
    static let zigzagFixes = List(id: "zigzag-fixes", urls: urls("https://zigzagbrowser.com/filters/zigzag-fixes.txt"),
                                  bundled: "zigzag-fixes", minimumSize: 100)

    /// uBlock Origin's scriptlets, as Ghostery publishes them for its engine: an index naming each version by its
    /// SHA-256, and the versions themselves, which never change.
    static let scriptletsIndex = URL(string: "https://cdn.ghostery.com/adblocker/resources/ublock-resources-json/metadata.json")!
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

    /// The newest revision in the scriptlets' index, if it reads as one.
    static func latestRevision(in data: Data) -> String? {
        guard let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = (index["revisions"] as? [String])?.last,
              revision.count == 64, revision.allSatisfy(\.isHexDigit) else { return nil }
        return revision.lowercased()
    }

    /// Scriptlets whose SHA-256 is the revision they were asked for, and that read as the engine's resources.
    static func isScriptlets(_ data: Data, revision: String) -> Bool {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == revision,
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

    init(directory: URL, session: URLSession? = nil) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["User-Agent": "Zigzag"]
            return URLSession(configuration: configuration)
        }()
    }

    // MARK: Files

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private var scriptletsFile: URL { file("scriptlets.json") }
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

    /// The downloaded lists and scriptlets as they are now (Zigzag's own list from the app until it's downloaded), or
    /// nil while one is missing.
    private func inputs() -> (lists: [String], scriptlets: String, checksum: String)? {
        var lists: [String] = []
        var hash = SHA256()
        for list in AdFilterSources.lists {
            guard let data = (try? Data(contentsOf: listFile(list.id))) ?? list.bundledData, let text = String(data: data, encoding: .utf8) else { return nil }
            lists.append(text)
            hash.update(data: data)
        }
        guard let data = try? Data(contentsOf: scriptletsFile), let scriptlets = String(data: data, encoding: .utf8) else { return nil }
        hash.update(data: data)
        return (lists, scriptlets, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

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
            let result = api?.invokeMethod("build", withArguments: [inputs.lists, inputs.scriptlets, inputs.checksum])?.toString()
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
        if due("scriptlets", scriptletsFile) {
            let known = fetched["scriptlets"]
            if let (index, response) = await get(AdFilterSources.scriptletsIndex, etag: known?.etag, lastModified: known?.lastModified) {
                let hasFile = FileManager.default.fileExists(atPath: scriptletsFile.path)
                if response.statusCode == 304, known != nil, hasFile {
                    fetched["scriptlets"]?.checked = now
                } else if response.statusCode == 200, let revision = AdFilterSources.latestRevision(in: index) {
                    var stored = hasFile && known?.revision == revision
                    if !stored, let (data, answer) = await get(AdFilterSources.scriptlets(revision: revision), etag: nil, lastModified: nil),
                       answer.statusCode == 200, AdFilterSources.isScriptlets(data, revision: revision),
                       (try? data.write(to: scriptletsFile, options: .atomic)) != nil {
                        stored = true
                        changed = true
                    }
                    if stored {
                        fetched["scriptlets"] = Fetched(url: AdFilterSources.scriptletsIndex.absoluteString, etag: response.value(forHTTPHeaderField: "ETag"),
                                                        lastModified: response.value(forHTTPHeaderField: "Last-Modified"), checked: now,
                                                        lifetime: 86_400, revision: revision)
                    }
                }
            }
        }
        writeFetched(fetched)
        if changed { state.withLock { $0.updated = now } }
        return changed
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
