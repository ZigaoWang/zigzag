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
    /// Off screen, but in a window: a page in no window counts as hidden, and WebKit pauses its sound.
    private var host: NSWindow?

    private func place(_ page: WKWebView) {
        if host == nil {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.orderBack(nil)
            host = window
        }
        // Behind every other window, it would count as covered up, and hidden all the same.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if page.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(page.method(for: occlusion), to: SetBool.self)(page, occlusion, false)
        }
        host?.contentView?.addSubview(page)
    }

    private func remove(_ extensionID: String) {
        guard let page = pages.removeValue(forKey: extensionID) else { return }
        page.stopLoading()
        page.removeFromSuperview()
        if pages.isEmpty { host?.close(); host = nil }
    }

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
            place(page)
            // As in Chrome, done once the page has loaded and its scripts listen: extensions message it right away.
            let loaded = PageLoad()
            page.navigationDelegate = loaded
            page.load(URLRequest(url: url))
            await loaded.wait(seconds: 10)
            page.navigationDelegate = nil
            return nil
        case "closeDocument":
            guard pages[extensionID] != nil else { throw BridgeError("No current offscreen document.") }
            remove(extensionID)
            return nil
        case "hasDocument":
            return pages[extensionID] != nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    func release(_ extensionID: String) {
        remove(extensionID)
    }
}

/// Waits for a hidden page to finish loading (or fail, or take too long).
@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
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

// MARK: - sidePanel

/// `chrome.sidePanel`: the extension's page docked on the window's right (ExtensionSidePanelView), opened by its
/// toolbar button when it asks for that, or by `open()` after a click. Options apply to every tab; Zigzag doesn't keep
/// a panel per tab.
@available(macOS 15.4, *)
@MainActor
final class BridgeSidePanel: BridgeNamespace {
    static let name = "sidePanel"
    static let permission = "sidePanel"
    private var paths: [String: String] = [:]
    private var disabled: Set<String> = []
    private var opensOnClick: Set<String> = []

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "setOptions":
            let options = args.object(0)
            if let path = options.string("path") { paths[extensionID] = path }
            if let enabled = options["enabled"] as? Bool {
                if enabled { disabled.remove(extensionID) } else { disabled.insert(extensionID); close(extensionID) }
            }
            return nil
        case "getOptions":
            var options: [String: Any] = ["enabled": !disabled.contains(extensionID)]
            if let path = path(for: extensionID) { options["path"] = path }
            return options
        case "setPanelBehavior":
            if let click = args.object(0)["openPanelOnActionClick"] as? Bool {
                if click { opensOnClick.insert(extensionID) } else { opensOnClick.remove(extensionID) }
            }
            return nil
        case "getPanelBehavior":
            return ["openPanelOnActionClick": opensOnClick.contains(extensionID)]
        case "open":
            // Chrome lets a panel open only in answer to something you did; a click on the extension leads here.
            guard Date().timeIntervalSince(UndoClock.lastPageInput) < 5 || Date().timeIntervalSince(lastClick) < 5 else {
                throw BridgeError("`sidePanel.open()` may only be called in response to a user gesture.")
            }
            guard open(extensionID, in: WindowManager.shared.keyController) else { throw BridgeError("No active side panel for the extension") }
            return nil
        case "close":
            close(extensionID)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    private var lastClick = Date.distantPast

    /// The page to show: what the extension set, else its manifest's.
    private func path(for extensionID: String) -> String? {
        if let set = paths[extensionID] { return set }
        return (ExtensionStore.manifest(for: extensionID)?["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    /// A click on the extension's button: opens or closes its panel when that's what the click is for (it asked, or
    /// it has a panel and no popup). False leaves the click to WebKit.
    func handleClick(_ extensionID: String, hasPopup: Bool, in controller: BrowserWindowController?) -> Bool {
        lastClick = Date()
        guard !disabled.contains(extensionID), path(for: extensionID) != nil,
              opensOnClick.contains(extensionID) || !hasPopup else { return false }
        if let controller, controller.root.showsSidePanel, controller.root.sidePanel.extensionID == extensionID {
            hide(in: controller)
        } else {
            _ = open(extensionID, in: controller)
        }
        return true
    }

    @discardableResult
    func open(_ extensionID: String, in controller: BrowserWindowController?) -> Bool {
        guard let controller, !disabled.contains(extensionID), let path = path(for: extensionID),
              let context = ExtensionHost.shared.context(for: extensionID), let configuration = context.webViewConfiguration,
              let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL, url.host() == context.baseURL.host() else { return false }
        let root = controller.root
        if root.showsSidePanel, root.sidePanel.extensionID == extensionID, root.sidePanel.webView?.url?.path == url.path { return true }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        let image = context.webExtension.icon(for: NSSize(width: 32, height: 32))
        root.sidePanel.show(webView, extensionID: extensionID, name: context.webExtension.displayName ?? "Extension", image: image)
        root.sidePanel.onClose = { [weak self, weak controller] in if let controller { self?.hide(in: controller) } }
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true) {
            root.showsSidePanel = true
            root.layoutSubtreeIfNeeded()
        }
        return true
    }

    private func hide(in controller: BrowserWindowController) {
        controller.root.showsSidePanel = false
        controller.root.sidePanel.clear()
    }

    private func close(_ extensionID: String) {
        for controller in WindowManager.shared.controllers where controller.root.sidePanel.extensionID == extensionID { hide(in: controller) }
    }

    func release(_ extensionID: String) {
        close(extensionID)
        paths[extensionID] = nil
        opensOnClick.remove(extensionID)
        disabled.remove(extensionID)
    }
}

// MARK: - tabCapture

/// `chrome.tabCapture.capture({ audio: true })`: the sound of the tab you're on, for an extension you've clicked
/// (Shazam, a recorder). Zigzag taps the page's sound and streams the samples to the extension, which plays them into
/// a normal MediaStream. Two halves: the page's own Web Audio when it uses it (Resources/Extensions/
/// tab-capture-page.js, over the routes audio-routes.js noted), else its media elements, from a script world of
/// Zigzag's own (tab-capture.js). As in Chrome the tab goes quiet while captured, and the extension plays it back if
/// it wants. Only the tab in front, never a private window's, and only while the extension's popup is open or soon
/// after you click it; a note says it's listening, and it stops when the extension stops listening or goes away.
/// `getMediaStreamId` is the same, in two steps (Sound Booster): it names the tab in front, and the extension's
/// page then asks `getUserMedia` for that tab, within a few seconds, once.
@available(macOS 15.4, *)
@MainActor
final class BridgeTabCapture: NSObject, BridgeNamespace, WKScriptMessageHandler {
    static let name = "tabCapture"
    static let permission = "tabCapture"
    private static let world = WKContentWorld.world(name: "zigzag-tab-capture")
    private static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    private static let elementScript = resource("tab-capture")
    private static let pageScript = resource("tab-capture-page")
    /// For pages, at their start, while an extension that can capture tabs is installed (WebKitSetup).
    static let routesScript = WKUserScript(source: resource("audio-routes"), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private struct Tap {
        let extensionID: String
        weak var webView: WKWebView?
        let tabID: UUID
        /// Which half is listening: the page's Web Audio, or its media elements.
        let world: WKContentWorld
        let script: String
    }
    private var taps: [String: Tap] = [:]
    /// Tabs named by getMediaStreamId, waiting for the extension to ask for their sound.
    private struct Pending {
        let extensionID: String
        weak var tab: Tab?
        let expires: Date
    }
    private var pending: [String: Pending] = [:]
    /// Web views given the message handler (in both worlds), so it's added once each.
    private var handled = Set<ObjectIdentifier>()

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "getMediaStreamId":
            let (tab, _) = try frontTab(for: extensionID)
            pending = pending.filter { $0.value.expires > Date() }
            let id = UUID().uuidString
            pending[id] = Pending(extensionID: extensionID, tab: tab, expires: Date().addingTimeInterval(10))
            return id
        case "capture":
            let options = args.object(0)
            guard options["audio"] as? Bool == true else { throw BridgeError("Zigzag can capture a tab's sound, not its picture") }
            let host = ExtensionHost.shared
            let tab: Tab, controller: BrowserWindowController
            if let streamID = options.string("streamId") {
                // A tab getMediaStreamId named: good once, for a few seconds, for the extension it was given to.
                guard let named = pending.removeValue(forKey: streamID), named.extensionID == extensionID, named.expires > Date(),
                      let namedTab = named.tab, let owner = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === namedTab } }),
                      !owner.tabManager.isPrivate else { throw BridgeError("Invalid stream ID") }
                (tab, controller) = (namedTab, owner)
            } else {
                (tab, controller) = try frontTab(for: extensionID)
            }
            guard let webView = tab.webView else { throw BridgeError("Cannot capture a tab here") }
            for (id, tap) in taps where tap.extensionID == extensionID { stop(id) }
            if handled.insert(ObjectIdentifier(webView)).inserted {
                webView.configuration.userContentController.add(self, contentWorld: Self.world, name: "zigzagTap")
                webView.configuration.userContentController.add(self, contentWorld: .page, name: "zigzagTap")
            }
            let id = UUID().uuidString
            // The page's own Web Audio first: when it plays through that (YouTube does), its elements can't be tapped.
            let routed = try? await webView.callAsyncJavaScript(Self.pageScript, arguments: ["tap": id, "stop": false], in: nil, contentWorld: .page) as? Int
            if let routed, routed > 0 {
                taps[id] = Tap(extensionID: extensionID, webView: webView, tabID: tab.id, world: .page, script: Self.pageScript)
            } else {
                let elements = try await webView.callAsyncJavaScript(Self.elementScript, arguments: ["tap": id, "stop": false], in: nil, contentWorld: Self.world) as? Int
                guard let elements, elements >= 0 else { throw BridgeError("Play something in the tab first, then try again") }
                taps[id] = Tap(extensionID: extensionID, webView: webView, tabID: tab.id, world: Self.world, script: Self.elementScript)
            }
            Toast.show("\(host.displayName(for: extensionID)) is listening to this tab", symbol: "waveform", duration: 3, in: controller)
            return ["id": id, "tabId": tab.id.hashValue & 0x7fffffff]
        case "stop":
            if let id = args.string(0), taps[id]?.extensionID == extensionID { stop(id) }
            return nil
        case "getCapturedTabs":
            return taps.values.filter { $0.extensionID == extensionID }.map { ["tabId": $0.tabID.hashValue & 0x7fffffff, "status": "active", "fullscreen": false] as [String: Any] }
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// The tab in front, for an extension you've just used: its popup is open, or you clicked it a moment ago.
    private func frontTab(for extensionID: String) throws -> (Tab, BrowserWindowController) {
        let host = ExtensionHost.shared
        guard host.isPopupShown(for: extensionID) || Date().timeIntervalSince(host.lastActionClick(extensionID)) < 120 else {
            throw BridgeError("Extension has not been invoked for the current page (see activeTab permission).")
        }
        guard let controller = WindowManager.shared.keyController, !controller.tabManager.isPrivate,
              let tab = controller.tabManager.selectedTab, tab.webView != nil else { throw BridgeError("Cannot capture a tab here") }
        return (tab, controller)
    }

    private func stop(_ id: String) {
        guard let tap = taps.removeValue(forKey: id) else { return }
        tap.webView?.callAsyncJavaScript(tap.script, arguments: ["tap": id, "stop": true], in: nil, in: tap.world, completionHandler: nil)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["tap"] as? String, let pcm = body["pcm"] as? String,
              let rate = body["rate"] as? Double else { return }
        let world = message.world
        MainActor.assumeIsolated {
            // Only from the half that's listening, in the tab it's listening to.
            guard let tap = taps[id], tap.webView === message.webView, tap.world == world else { return }
            // The extension stopped listening (its popup closed): the tap goes too, and the tab's sound comes back.
            guard ExtensionBridge.shared.isListened("tabCapture.chunk") else { stop(id); return }
            ExtensionBridge.shared.emit("tabCapture.chunk", [id, rate, pcm], to: tap.extensionID)
        }
    }

    func release(_ extensionID: String) {
        for (id, tap) in taps where tap.extensionID == extensionID { stop(id) }
        pending = pending.filter { $0.value.extensionID != extensionID }
    }
}
