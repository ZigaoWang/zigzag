import AppKit
import WebKit
import AVFoundation
import IOKit.pwr_mgt
import UserNotifications

// The smaller Chrome namespaces the bridge answers (ExtensionBridge). Each is the Chrome API's shape over what
// Zigzag or macOS already has; anything left out says so by name rather than doing nothing.

// MARK: - history

/// `chrome.history`, over Zigzag's own history. Private windows never record history, so none shows here.
@available(macOS 15.4, *)
@MainActor
final class BridgeHistory: BridgeNamespace {
    static let name = "history"
    static let permission = "history"
    private let store = HistoryStore.shared

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "search":
            let query = args.object(0)
            let limit = Int(query.number("maxResults") ?? 100)
            // Chrome's default reaches back a day when there's no start time.
            let start = query.date("startTime") ?? (query["startTime"] == nil ? Date(timeIntervalSinceNow: -86_400) : nil)
            return store.items(matching: query.string("text") ?? "", from: start, to: query.date("endTime"), limit: limit).map(Self.item)
        case "getVisits":
            guard let url = args.object(0).string("url").flatMap(URL.init(string:)), let found = store.item(for: url) else { return [Any]() }
            // Zigzag keeps a page's latest visit and how many, not each one: the latest stands for them.
            return [["id": String(found.id), "visitId": String(found.id), "visitTime": found.entry.lastVisit,
                     "referringVisitId": "0", "transition": "link"] as [String: Any]]
        case "addUrl":
            let details = args.object(0)
            guard let url = details.string("url").flatMap(URL.init(string:)), HistoryStore.shouldRecord(url) else { throw BridgeError("Not a web address") }
            store.recordVisit(url: url, title: details.string("title"))
            return nil
        case "deleteUrl":
            guard let url = args.object(0).string("url").flatMap(URL.init(string:)) else { throw BridgeError("Not a web address") }
            _ = store.remove([url])
            return nil
        case "deleteRange":
            let range = args.object(0)
            guard let start = range.date("startTime"), let end = range.date("endTime"), start <= end else { throw BridgeError("A start and end time are needed") }
            _ = store.remove(from: start, to: end)
            return nil
        case "deleteAll":
            _ = store.remove(since: nil)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func startEvents() {
        guard store.onVisit == nil else { return }
        store.onVisit = { url in
            guard ExtensionBridge.shared.isListened("history.onVisited"), let found = HistoryStore.shared.item(for: url) else { return }
            ExtensionBridge.shared.emit("history.onVisited", [Self.item(found)])
        }
        store.onRemove = { urls in
            ExtensionBridge.shared.emit("history.onVisitRemoved", [["allHistory": urls == nil, "urls": (urls ?? []).map(\.absoluteString)] as [String: Any]])
        }
    }

    private static func item(_ found: (id: Int64, entry: HistoryEntry)) -> [String: Any] {
        ["id": String(found.id), "url": found.entry.url.absoluteString, "title": found.entry.title,
         "lastVisitTime": found.entry.lastVisit, "visitCount": found.entry.visitCount, "typedCount": 0]
    }
}

// MARK: - topSites

/// `chrome.topSites`: your favorites first, then the pages you visit most.
@available(macOS 15.4, *)
@MainActor
final class BridgeTopSites: BridgeNamespace {
    static let name = "topSites"
    static let permission = "topSites"

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        guard fn == "get" else { throw BridgeError.unsupported(Self.name, fn) }
        var seen = Set<String>(), sites: [[String: Any]] = []
        let favorites = Library.shared.favorites.map { ($0.url, $0.title) }
        let visited = HistoryStore.shared.mostVisited(limit: 20).map { ($0.url, $0.title) }
        for (url, title) in favorites + visited where sites.count < 10 && seen.insert(url.absoluteString).inserted {
            sites.append(["url": url.absoluteString, "title": title])
        }
        return sites
    }
}

// MARK: - notifications

/// `chrome.notifications`, shown by macOS under Zigzag, titled with the extension's name. A click opens nothing on
/// its own; it tells the extension, which decides (most open a tab).
@available(macOS 15.4, *)
@MainActor
final class BridgeNotifications: BridgeNamespace {
    static let name = "notifications"
    static let permission = "notifications"
    static let prefix = "ext|"

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "create", "update":
            // create(id?, options) or create(options); update(id, options).
            let id = args.string(0) ?? UUID().uuidString
            let options = args.first is String ? args.object(1) : args.object(0)
            let shown = await WebNotifications.shared.showForExtension(key: Self.key(extensionID, id), extensionID: extensionID,
                                                                       title: options.string("title") ?? "", message: options.string("message") ?? "",
                                                                       context: options.string("contextMessage"), silent: options["silent"] as? Bool == true)
            return fn == "create" ? id : shown
        case "clear":
            guard let id = args.string(0) else { return false }
            WebNotifications.shared.clearForExtension(keys: [Self.key(extensionID, id)])
            return true
        case "getAll":
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let mine = Self.key(extensionID, "")
            return Dictionary(uniqueKeysWithValues: delivered.map(\.request.identifier).filter { $0.hasPrefix(mine) }.map { (String($0.dropFirst(mine.count)), true) })
        case "getPermissionLevel":
            return "granted"
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    static func key(_ extensionID: String, _ id: String) -> String { "\(prefix)\(extensionID)|\(id)" }

    /// macOS said it was clicked or swiped away: tell the extension that made it.
    static func answered(key: String, dismissed: Bool) {
        let parts = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if dismissed {
            ExtensionBridge.shared.emit("notifications.onClosed", [parts[1], true], to: parts[0])
        } else {
            ExtensionBridge.shared.emit("notifications.onClicked", [parts[1]], to: parts[0])
        }
    }

    func release(_ extensionID: String) {
        let mine = Self.key(extensionID, "")
        Task { @MainActor in
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(mine) }
            WebNotifications.shared.clearForExtension(keys: delivered)
        }
    }
}

// MARK: - idle

/// `chrome.idle`: active, idle (no input for the interval) or locked, from macOS. Watched only while an extension
/// listens for changes.
@available(macOS 15.4, *)
@MainActor
final class BridgeIdle: BridgeNamespace {
    static let name = "idle"
    static let permission = "idle"
    private var interval: Double = 60
    private var timer: Timer?
    private var last = "active"

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "queryState": return Self.state(threshold: max(15, args.number(0) ?? 60))
        case "setDetectionInterval": interval = max(15, args.number(0) ?? 60); return nil
        case "getAutoLockDelay": return 0
        default: throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func startEvents() {
        guard timer == nil else { return }
        last = Self.state(threshold: interval)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard ExtensionBridge.shared.isListened("idle.onStateChanged") else { self.timer?.invalidate(); self.timer = nil; return }
                let now = Self.state(threshold: self.interval)
                if now != self.last { self.last = now; ExtensionBridge.shared.emit("idle.onStateChanged", [now]) }
            }
        }
    }

    static func state(threshold: Double) -> String {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return quiet >= threshold ? "idle" : "active"
    }
}

// MARK: - tts

/// `chrome.tts`, spoken by macOS's own voices. One voice speaks at a time, as in Chrome.
@available(macOS 15.4, *)
@MainActor
final class BridgeSpeech: NSObject, BridgeNamespace, AVSpeechSynthesizerDelegate {
    static let name = "tts"
    static let permission = "tts"
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance speaking, with the extension and the ID its script gave it for `onEvent`.
    private var speaking: [ObjectIdentifier: (extensionID: String, id: String)] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "speak":
            guard let text = args.string(0), !text.isEmpty else { return nil }
            let options = args.object(1)
            if options["enqueue"] as? Bool != true { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: String(text.prefix(32_768)))
            // Chrome's rate 1 is normal speech; AVSpeech's normal sits at its own default.
            let rate = options.number("rate") ?? 1
            utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
            utterance.pitchMultiplier = Float(min(max(options.number("pitch") ?? 1, 0.5), 2))
            utterance.volume = Float(min(max(options.number("volume") ?? 1, 0), 1))
            if let name = options.string("voiceName"), let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) {
                utterance.voice = voice
            } else if let lang = options.string("lang") {
                utterance.voice = AVSpeechSynthesisVoice(language: lang)
            }
            if let id = options.string("__utterance") {
                speaking[ObjectIdentifier(utterance)] = (extensionID, id)
                kept[ObjectIdentifier(utterance)] = utterance
            }
            synthesizer.speak(utterance)
            return nil
        case "stop", "pause", "resume":
            if fn == "stop" { synthesizer.stopSpeaking(at: .immediate) }
            else if fn == "pause" { synthesizer.pauseSpeaking(at: .word) }
            else { synthesizer.continueSpeaking() }
            return nil
        case "isSpeaking":
            return synthesizer.isSpeaking
        case "getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map { ["voiceName": $0.name, "lang": $0.language, "remote": false,
                                                               "eventTypes": ["start", "end", "word", "interrupted", "cancelled"]] as [String: Any] }
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func release(_ extensionID: String) {
        if speaking.values.contains(where: { $0.extensionID == extensionID }) { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func report(_ utterance: AVSpeechUtterance, _ type: String, charIndex: Int? = nil) {
        guard let owner = speaking[ObjectIdentifier(utterance)] else { return }
        var event: [String: Any] = ["type": type]
        if let charIndex { event["charIndex"] = charIndex }
        ExtensionBridge.shared.emit("tts.utterance", [owner.id, event], to: owner.extensionID)
        if ["end", "interrupted", "cancelled"].contains(type) {
            speaking[ObjectIdentifier(utterance)] = nil
            kept[ObjectIdentifier(utterance)] = nil
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u); MainActor.assumeIsolated { if let u = self.utterance(key) { report(u, "start") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u); MainActor.assumeIsolated { if let u = self.utterance(key) { report(u, "end") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u); MainActor.assumeIsolated { if let u = self.utterance(key) { report(u, "interrupted") } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u), index = range.location
        MainActor.assumeIsolated { if let u = self.utterance(key) { report(u, "word", charIndex: index) } }
    }

    /// The utterance still kept for a delegate call, found by identity (the delegate hears from AVFoundation's queue).
    private var kept: [ObjectIdentifier: AVSpeechUtterance] = [:]
    private func utterance(_ key: ObjectIdentifier) -> AVSpeechUtterance? { kept[key] }
}

// MARK: - power

/// `chrome.power`: keeps the Mac (and, for "display", its screen) awake while an extension asks, through a macOS
/// power assertion named for it, so Activity Monitor and `pmset -g assertions` say who's holding it.
@available(macOS 15.4, *)
@MainActor
final class BridgePower: BridgeNamespace {
    static let name = "power"
    static let permission = "power"
    private var assertions: [String: IOPMAssertionID] = [:]

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "requestKeepAwake":
            release(extensionID)
            let type = args.string(0) == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            var id: IOPMAssertionID = 0
            let reason = "An extension in Zigzag (\(ExtensionHost.shared.displayName(for: extensionID)))" as CFString
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertions[extensionID] = id
            }
            return nil
        case "releaseKeepAwake":
            release(extensionID)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func release(_ extensionID: String) {
        if let id = assertions.removeValue(forKey: extensionID) { IOPMAssertionRelease(id) }
    }
}

// MARK: - offscreen

/// `chrome.offscreen`: one hidden page of the extension's own, as Chrome gives, for work a background can't do
/// itself (playing audio, parsing a page, the clipboard). It's a real extension page, so it has the extension's APIs
/// and talks to the background with `runtime.sendMessage`. Never shown, and gone when the extension is.
@available(macOS 15.4, *)
@MainActor
final class BridgeOffscreen: BridgeNamespace {
    static let name = "offscreen"
    static let permission = "offscreen"
    private var pages: [String: WKWebView] = [:]

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "createDocument":
            guard pages[extensionID] == nil else { throw BridgeError("Only a single offscreen document may be created.") }
            guard let context = ExtensionHost.shared.context(for: extensionID), let configuration = context.webViewConfiguration,
                  let path = args.object(0).string("url"), let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
                  url.scheme == context.baseURL.scheme, url.host() == context.baseURL.host() else {
                throw BridgeError("The offscreen document must be one of the extension's own pages")
            }
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            pages[extensionID] = page
            page.load(URLRequest(url: url))
            return nil
        case "closeDocument":
            guard let page = pages.removeValue(forKey: extensionID) else { throw BridgeError("No current offscreen document.") }
            page.stopLoading()
            return nil
        case "hasDocument":
            return pages[extensionID] != nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func release(_ extensionID: String) {
        pages.removeValue(forKey: extensionID)?.stopLoading()
    }
}

// MARK: - identity

/// `chrome.identity.launchWebAuthFlow`: an extension's "Sign in with…" in a small window of its own, with your
/// usual cookies, as Chrome does it. When the sign-in sends the window to the extension's redirect address
/// (`https://<id>.chromiumapp.org/…`), the window closes and the extension gets that address, with its code or
/// token. Never with `interactive: false` unless no click is needed. `getAuthToken` (Chrome's own Google account
/// sign-in) has no Zigzag equivalent and says so.
@available(macOS 15.4, *)
@MainActor
final class BridgeIdentity: NSObject, BridgeNamespace, WKNavigationDelegate, NSWindowDelegate {
    static let name = "identity"
    static let permission = "identity"
    private struct Flow {
        let extensionID: String
        let window: NSWindow?
        let webView: WKWebView
        let finish: (Result<URL, BridgeError>) -> Void
    }
    private var flows: [ObjectIdentifier: Flow] = [:]

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "launchWebAuthFlow":
            let details = args.object(0)
            guard let text = details.string("url"), let url = URL(string: text), Self.isAllowedStart(url) else { throw BridgeError("Authorization page could not be loaded.") }
            let result = await withCheckedContinuation { done in start(url, interactive: details["interactive"] as? Bool == true, extensionID: extensionID) { done.resume(returning: $0) } }
            return try result.get().absoluteString
        case "getRedirectURL":
            return "https://\(extensionID).chromiumapp.org/" + (args.string(0) ?? "")
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// Sign-in pages are secure pages. Testing builds also take a local server, to try a flow without a real provider.
    static func isAllowedStart(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? "")
        #else
        return false
        #endif
    }

    private func start(_ url: URL, interactive: Bool, extensionID: String, finish: @escaping (Result<URL, BridgeError>) -> Void) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: WebKitSetup.makeConfiguration())
        webView.navigationDelegate = self
        var window: NSWindow?
        if interactive {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            made.title = "Sign In for \(ExtensionHost.shared.displayName(for: extensionID))"
            made.subtitle = url.host() ?? ""
            made.contentView = webView
            made.isReleasedWhenClosed = false
            made.delegate = self
            if let parent = WindowManager.shared.keyController?.window {
                made.setFrameOrigin(NSPoint(x: parent.frame.midX - 240, y: parent.frame.midY - 320))
            } else {
                made.center()
            }
            made.makeKeyAndOrderFront(nil)
            window = made
        }
        flows[ObjectIdentifier(webView)] = Flow(extensionID: extensionID, window: window, webView: webView, finish: finish)
        webView.load(URLRequest(url: url))
        // Without a window, the flow has a few seconds to reach the redirect on its own.
        if !interactive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.end(webView, .failure(BridgeError("User interaction required.")))
            }
        }
    }

    private func end(_ webView: WKWebView, _ result: Result<URL, BridgeError>) {
        guard let flow = flows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        webView.stopLoading()
        flow.window?.delegate = nil
        flow.window?.close()
        flow.finish(result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let flow = flows[ObjectIdentifier(webView)], let url = action.request.url else { return .allow }
        // The extension's own redirect address, exactly: never stops on another site that happens to look like it.
        if url.scheme == "https", url.host()?.lowercased() == "\(flow.extensionID).chromiumapp.org" {
            end(webView, .success(url))
            return .cancel
        }
        return .allow
    }

    /// A server's redirect to the address, too, in case it arrives without its own navigation decision.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let flow = flows[ObjectIdentifier(webView)], let url = webView.url, url.scheme == "https",
              url.host()?.lowercased() == "\(flow.extensionID).chromiumapp.org" else { return }
        end(webView, .success(url))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { end(webView, .failure(BridgeError("Authorization page could not be loaded."))) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let flow = flows.values.first(where: { $0.window === window }) else { return }
        end(flow.webView, .failure(BridgeError("The user did not approve access.")))
    }

    func release(_ extensionID: String) {
        for flow in flows.values where flow.extensionID == extensionID { end(flow.webView, .failure(BridgeError("The extension was turned off."))) }
    }
}
