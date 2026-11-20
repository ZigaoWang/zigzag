import AppKit
import WebKit

/// `chrome.downloads`, over Zigzag's own Downloads. What an extension starts shows in Downloads like any other file,
/// is fetched with your cookies as a page's would be, and lands in your Downloads folder (or where you choose, when
/// it asks to). An extension sees only its own profile's downloads, and private windows' only when allowed in them.
@available(macOS 15.4, *)
@MainActor
final class BridgeDownloads: BridgeNamespace {
    static let name = "downloads"
    static let permission = "downloads"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    private let manager = DownloadManager.shared
    /// Chrome's download IDs are numbers that last the session; each Zigzag download gets one when first seen.
    private var numbers: [UUID: Int] = [:]
    private var next = 1
    private var watching: SignalToken?
    /// Each download's state as last told, to say what changed.
    private var lastSeen: [UUID: [String: Any]] = [:]
    /// The fetcher for downloads no tab started: your normal cookies, never a private window's.
    private lazy var fetcher = WKWebView(frame: .zero, configuration: WebKitSetup.makeConfiguration(for: host.profile))
    /// A page of each extension's own, for a blob: download when it has no offscreen page open. WebKit lets only
    /// the origin that made a blob read it, and a page of Zigzag's has an origin of its own.
    private var originViews: [String: WKWebView] = [:]
    /// The loads of those pages still under way, so a second download waits for the page too.
    private var originLoads: [String: Task<Void, Never>] = [:]
    /// Blank page written into an extension's loaded copy for a blob download with no offscreen page open. It has no
    /// scripts: only its origin matters.
    private static let originPageFile = "zigzag-download.html"
    private static let originPage = "<!DOCTYPE html>\n<meta charset=\"utf-8\">\n"

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "download":
            return try await start(args.object(0), extensionID: extensionID)
        case "search":
            return try await search(args.object(0), for: extensionID).map(describe)
        case "pause", "resume", "cancel":
            guard let item = item(Int(saturating: args.number(0) ?? -1), for: extensionID) else { throw BridgeError("Invalid download id") }
            switch fn {
            case "pause": guard manager.canPause(item) else { throw BridgeError("Download can't be paused") }; manager.pause(item)
            case "resume": manager.resume(item)
            default: manager.cancel(item)
            }
            return nil
        case "erase":
            let gone = try await search(args.object(0), for: extensionID).filter { $0.state != .downloading }
            for item in gone { manager.remove(item) }
            return gone.compactMap { numbers[$0.id] }
        case "removeFile":
            guard let item = item(Int(saturating: args.number(0) ?? -1), for: extensionID), item.state == .finished, let file = item.destination else { throw BridgeError("Download must be complete") }
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            return nil
        case "open":
            guard host.bridge.allows("downloads.open", for: extensionID) else { throw BridgeError("Opening downloads needs the “downloads.open” permission") }
            // As in Chrome, only in answer to you: a click on the extension, or in its popup or pages, a moment ago.
            guard host.hasRecentGesture(extensionID) else { throw BridgeError("downloads.open() may only be called in response to a user gesture.") }
            guard let item = item(Int(saturating: args.number(0) ?? -1), for: extensionID), item.state == .finished else { throw BridgeError("Download must be complete") }
            manager.open(item)
            return nil
        case "show":
            guard let item = item(Int(saturating: args.number(0) ?? -1), for: extensionID) else { throw BridgeError("Invalid download id") }
            manager.reveal(item)
            return true
        case "showDefaultFolder":
            NSWorkspace.shared.open(DownloadManager.folder)
            return nil
        case "getFileIcon":
            guard let item = item(Int(saturating: args.number(0) ?? -1), for: extensionID), let file = item.destination else { throw BridgeError("Invalid download id") }
            let size = min(max(Int(saturating: args.object(1).number("size") ?? 32), 1), 256)
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: size, height: size)
            guard let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        case "setUiOptions", "setShelfEnabled", "acceptDanger":
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    // MARK: Starting

    /// Files each extension saved this session, by name; the only ones its "overwrite" may replace.
    private var savedByExtension: [String: Set<String>] = [:]

    /// Whether "overwrite" may replace `target`: nothing there, or a file this extension saved this session (`savedBefore`,
    /// standardized paths).
    nonisolated static func mayOverwrite(_ target: URL, savedBefore: Set<String>) -> Bool {
        !FileManager.default.fileExists(atPath: target.path) || savedBefore.contains(target.standardizedFileURL.path)
    }

    private func start(_ options: [String: Any], extensionID: String) async throws -> Int {
        guard let text = options.string("url"), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "data", "blob"].contains(scheme) else { throw BridgeError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = (options.string("method") ?? "GET").uppercased() == "POST" ? "POST" : "GET"
        if let body = options.string("body") { request.httpBody = Data(body.utf8) }
        for header in options["headers"] as? [[String: Any]] ?? [] {
            guard let name = header.string("name"), let value = header.string("value"), !Self.forbiddenHeaders.contains(name.lowercased()),
                  ExtensionWrite.mayBeSet(name, value) else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        // A name the extension gave: only a file name, inside Downloads (its folders, if it names some, are flattened).
        // "overwrite" only replaces this extension's own files; otherwise uniquify, so your files are kept.
        var destination: URL?
        if let name = options.string("filename").map(Self.safeName), !name.isEmpty {
            let target = DownloadManager.folder.appendingPathComponent(name)
            let overwrite = options.string("conflictAction") == "overwrite" && Self.mayOverwrite(target, savedBefore: savedByExtension[extensionID, default: []])
            destination = overwrite ? target : DownloadManager.uniqueDestination(for: name)
            if let destination { savedByExtension[extensionID, default: []].insert(destination.standardizedFileURL.path) }
        }
        if options["saveAs"] as? Bool == true, let window = WindowManager.shared.keyController?.window {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = destination?.lastPathComponent ?? (url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent)
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { throw BridgeError("Download canceled") }
            destination = chosen
        }
        let webView = try await downloadView(for: url, extensionID: extensionID)
        let window = WindowManager.shared.keyController?.window
        let download: WKDownload = await withCheckedContinuation { done in webView.startDownload(using: request) { done.resume(returning: $0) } }
        let item = manager.track(download, window: window, saveTo: destination)
        return number(for: item)
    }

    /// The view a download starts in: a blob: in a view on the origin that made it, the only one WebKit lets read it.
    private func downloadView(for url: URL, extensionID: String) async throws -> WKWebView {
        guard url.scheme?.lowercased() == "blob" else { return fetcher }
        guard Self.blobOwner(url) == extensionID else { throw BridgeError("Invalid URL") }
        guard let view = await originView(for: extensionID) else {
            throw BridgeError("Saving a blob needs a page of the extension's own to read it")
        }
        return view
    }

    /// A view on the extension's origin: its offscreen page when one is open, else a small blank page of its own kept
    /// for this. Nil when Zigzag has no writable copy of the extension.
    private func originView(for extensionID: String) async -> WKWebView? {
        if let open = host.bridge.offscreen.page(for: extensionID) { return open }
        if let kept = originViews[extensionID] {
            await originLoads[extensionID]?.value
            return kept
        }
        guard let context = host.context(for: extensionID), let configuration = context.webViewConfiguration,
              let directory = host.profile.installs.overlayDirectory(for: extensionID) else { return nil }
        let file = directory.appendingPathComponent(Self.originPageFile)
        if !FileManager.default.fileExists(atPath: file.path),
           (try? Self.originPage.write(to: file, atomically: true, encoding: .utf8)) == nil { return nil }
        guard let page = URL(string: Self.originPageFile, relativeTo: context.baseURL)?.absoluteURL else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        originViews[extensionID] = view
        let loaded = PageLoadWaiter()
        view.navigationDelegate = loaded
        view.load(URLRequest(url: page))
        let load = Task { await loaded.wait(seconds: 3) }
        originLoads[extensionID] = load
        await load.value
        originLoads[extensionID] = nil
        view.navigationDelegate = nil
        return view
    }

    /// The extension that made a blob: URL, as `blob:webkit-extension://<id>/…`. Nil for one a page made.
    nonisolated static func blobOwner(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "blob" else { return nil }
        let inner = String(url.absoluteString.dropFirst("blob:".count))
        guard let made = URL(string: inner), made.scheme?.lowercased() == "webkit-extension" else { return nil }
        return made.host()
    }

    /// Headers a page can't set either: they'd let an extension pass for someone else.
    private static let forbiddenHeaders: Set<String> = ["cookie", "cookie2", "host", "origin", "referer", "proxy-authorization", "authorization"]

    /// The last part of whatever path the extension gave, with nothing that could climb out of the folder.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
    }

    // MARK: Reading

    private func number(for item: DownloadItem) -> Int {
        if let known = numbers[item.id] { return known }
        numbers[item.id] = next
        next += 1
        return numbers[item.id]!
    }

    /// Whether an extension in this profile may see a download: one made in the same profile, and a private window's
    /// only when it's allowed in private windows (`seesPrivate`).
    static func sees(_ item: DownloadItem, in profile: UUID, seesPrivate: Bool = false) -> Bool {
        PrivateAccess.sees(isPrivate: item.isPrivate, allowed: seesPrivate) && item.profile == profile
    }

    /// The downloads this profile's extensions could see, newest first: private ones too, which only some may.
    private var visible: [DownloadItem] { manager.items.filter { Self.sees($0, in: host.profile.id, seesPrivate: true) } }

    /// The downloads this extension sees, newest first.
    private func visible(to extensionID: String) -> [DownloadItem] {
        let seesPrivate = host.seesPrivate(extensionID)
        return manager.items.filter { Self.sees($0, in: host.profile.id, seesPrivate: seesPrivate) }
    }

    private func item(_ number: Int, for extensionID: String) -> DownloadItem? {
        guard let id = numbers.first(where: { $0.value == number })?.key else { return nil }
        return visible(to: extensionID).first { $0.id == id }
    }

    private func search(_ query: [String: Any], for extensionID: String) async throws -> [DownloadItem] {
        var found = visible(to: extensionID)
        if let id = query.number("id").map(Int.init(saturating:)) { found = found.filter { number(for: $0) == id } }
        if let state = query.string("state") { found = found.filter { Self.state($0) == state } }
        if let url = query.string("url") { found = found.filter { $0.sourceURL?.absoluteString == url } }
        if let text = query.string("query") ?? (query["query"] as? [String])?.joined(separator: " ") {
            let words = text.lowercased().split(separator: " ").map(String.init)
            found = found.filter { item in words.allSatisfy { item.filename.lowercased().contains($0) || (item.sourceURL?.absoluteString.lowercased().contains($0) ?? false) } }
        }
        if let pattern = query.string("filenameRegex") {
            // Like Chrome, an invalid pattern is an error, not an empty list.
            guard Self.isValidPattern(pattern) else { throw BridgeError("Invalid filenameRegex") }
            guard let matched = await Self.matching(pattern, in: found.map { $0.destination?.path ?? $0.filename }) else {
                throw BridgeError("filenameRegex took too long")
            }
            found = matched.sorted().map { found[$0] }
        }
        if (query["orderBy"] as? [String])?.first == "startTime" { found.sort { $0.started < $1.started } }
        if let limit = query.number("limit").map(Int.init(saturating:)), limit > 0 { found = Array(found.prefix(limit)) }
        return found
    }

    /// Whether `filenameRegex` compiles.
    nonisolated static func isValidPattern(_ pattern: String) -> Bool { (try? NSRegularExpression(pattern: pattern)) != nil }

    /// Extension patterns can be catastrophic, so matching runs off the main thread and gives up after `timeout`. Returns
    /// matching indexes, or nil on timeout. Invalid patterns match nothing.
    nonisolated static func matching(_ pattern: String, in names: [String], timeout: TimeInterval = 1) async -> Set<Int>? {
        guard pattern.utf16.count <= 1_000 else { return [] }
        return await Task.detached(priority: .utility) { () -> Set<Int>? in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let deadline = Date(timeIntervalSinceNow: timeout)
            var found = Set<Int>()
            for (index, name) in names.enumerated() {
                var matched = false, late = false
                // Progress callbacks let a slow match stop partway.
                regex.enumerateMatches(in: name, options: [.reportProgress], range: NSRange(location: 0, length: name.utf16.count)) { result, _, stop in
                    if result != nil { matched = true; stop.pointee = true } else if Date() > deadline { late = true; stop.pointee = true }
                }
                if late || Date() > deadline { return nil }
                if matched { found.insert(index) }
            }
            return found
        }.value
    }

    private static func state(_ item: DownloadItem) -> String {
        switch item.state {
        case .downloading, .paused: return "in_progress"
        case .finished: return "complete"
        case .failed, .cancelled: return "interrupted"
        }
    }

    private func describe(_ item: DownloadItem) -> [String: Any] {
        var described: [String: Any] = [
            "id": number(for: item),
            "url": item.sourceURL?.absoluteString ?? "",
            "finalUrl": item.sourceURL?.absoluteString ?? "",
            "filename": item.destination?.path ?? item.filename,
            "state": Self.state(item),
            "paused": item.state == .paused,
            "canResume": item.state == .paused || (item.state == .failed && manager.canRetry(item)),
            "bytesReceived": item.completedBytes,
            "totalBytes": item.totalBytes > 0 ? item.totalBytes : -1,
            "fileSize": item.state == .finished ? item.totalBytes : -1,
            "exists": !item.fileIsMissing,
            "danger": "safe",
            "mime": "",
            "incognito": item.isPrivate,
            // Chrome gives these as ISO 8601 text, not milliseconds.
            "startTime": ISO8601DateFormatter().string(from: item.started),
        ]
        if let seconds = item.secondsLeft { described["estimatedEndTime"] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: seconds)) }
        if item.state == .cancelled { described["error"] = "USER_CANCELED" } else if item.state == .failed { described["error"] = "NETWORK_FAILED" }
        return described
    }

    // MARK: Events

    func startEvents() {
        guard watching == nil else { return }
        for item in visible { lastSeen[item.id] = describe(item) }
        watching = manager.changed.observe { [weak self] _ in self?.announceChanges() }
    }

    private func announceChanges() {
        let bridge = host.bridge
        let current = visible
        let ids = Set(current.map(\.id))
        for item in current {
            let now = describe(item)
            guard let was = lastSeen[item.id] else {
                lastSeen[item.id] = now
                bridge.emit("downloads.onCreated", [now], isPrivate: item.isPrivate)
                continue
            }
            lastSeen[item.id] = now
            var delta: [String: Any] = ["id": now["id"] ?? 0]
            for key in ["state", "paused", "filename", "totalBytes", "fileSize", "exists", "error", "canResume"] {
                let before = was[key].map { "\($0)" }, after = now[key].map { "\($0)" }
                if before != after { delta[key] = ["previous": was[key] ?? NSNull(), "current": now[key] ?? NSNull()] }
            }
            if delta.count > 1 { bridge.emit("downloads.onChanged", [delta], isPrivate: item.isPrivate) }
        }
        for (id, was) in lastSeen where !ids.contains(id) {
            lastSeen[id] = nil
            bridge.emit("downloads.onErased", [was["id"] ?? 0], isPrivate: was["incognito"] as? Bool == true)
        }
    }

    func release(_ extensionID: String) {
        originViews.removeValue(forKey: extensionID)?.stopLoading()
    }
}

/// Waits for the hidden page a blob download starts in to load, or to fail, or for a few seconds.
@MainActor
private final class PageLoadWaiter: NSObject, WKNavigationDelegate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait(seconds: Double) async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            waiting = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.finish()
            }
        }
    }

    private func finish() {
        finished = true
        waiting?.resume()
        waiting = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
}
