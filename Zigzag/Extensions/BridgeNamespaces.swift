import AppKit
import WebKit
import AVFoundation
import IOKit.pwr_mgt
import Network
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    private var store: HistoryStore { host.profile.history }

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
        store.onVisit = { [unowned self] url in
            guard host.bridge.isListened("history.onVisited"), let found = store.item(for: url) else { return }
            host.bridge.emit("history.onVisited", [Self.item(found)])
        }
        store.onRemove = { [unowned self] urls in
            host.bridge.emit("history.onVisitRemoved", [["allHistory": urls == nil, "urls": (urls ?? []).map(\.absoluteString)] as [String: Any]])
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        guard fn == "get" else { throw BridgeError.unsupported(Self.name, fn) }
        var seen = Set<String>(), sites: [[String: Any]] = []
        let favorites = Library.shared.favorites(in: host.profile.id).map { ($0.url, $0.title) }
        let visited = host.profile.history.mostVisited(limit: 20).map { ($0.url, $0.title) }
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    static let prefix = ExtensionNotificationKey.prefix

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "create", "update":
            // create(id?, options) or create(options); update(id, options).
            let id = args.string(0) ?? UUID().uuidString
            let options = args.first is String ? args.object(1) : args.object(0)
            let shown = await WebNotifications.shared.showForExtension(key: key(extensionID, id), extensionID: extensionID, name: host.displayName(for: extensionID),
                                                                       title: options.string("title") ?? "", message: options.string("message") ?? "",
                                                                       context: options.string("contextMessage"), silent: options["silent"] as? Bool == true)
            return fn == "create" ? id : shown
        case "clear":
            guard let id = args.string(0) else { return false }
            WebNotifications.shared.clearForExtension(keys: [key(extensionID, id)])
            return true
        case "getAll":
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let mine = key(extensionID, "")
            return Dictionary(uniqueKeysWithValues: delivered.map(\.request.identifier).filter { $0.hasPrefix(mine) }.map { (String($0.dropFirst(mine.count)), true) })
        case "getPermissionLevel":
            return "granted"
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    private func key(_ extensionID: String, _ id: String) -> String {
        ExtensionNotificationKey(profile: host.profile.isDefault ? nil : host.profile.id, extensionID: extensionID, id: id).string
    }

    /// macOS said it was clicked or swiped away: tell the extension that made it, in the profile it's in.
    static func answered(key: String, dismissed: Bool) {
        guard let key = ExtensionNotificationKey(key),
              let profile = Profiles.shared.all.first(where: { $0.id == key.profile ?? Profile.defaultID }) else { return }
        if dismissed {
            profile.extensions.bridge.emit("notifications.onClosed", [key.id, true], to: key.extensionID)
        } else {
            profile.extensions.bridge.emit("notifications.onClicked", [key.id], to: key.extensionID)
        }
    }

    func release(_ extensionID: String) {
        let mine = key(extensionID, "")
        Task { @MainActor in
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(mine) }
            WebNotifications.shared.clearForExtension(keys: delivered)
        }
    }
}

// MARK: - runtime.getContexts

/// `chrome.runtime.getContexts`: which of its pages an extension has open, as Chrome answers. Its background, its
/// offscreen page, its popup while showing, its side panel while open. Extensions ask before making an offscreen page
/// (Boost My Bass) or to see whether their popup is open. Every extension may ask about its own pages.
@available(macOS 15.4, *)
@MainActor
final class BridgeContexts: BridgeNamespace {
    static let name = "contexts"
    static let permission = ""
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        guard fn == "getContexts" else { throw BridgeError.unsupported(Self.name, fn) }
        guard let context = host.context(for: extensionID) else { return [Any]() }
        var found: [[String: Any]] = []
        let add = { (type: String, url: URL?) in
            let address = url?.absoluteString ?? ""
            let origin = url.flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""
            found.append(["contextType": type, "contextId": "\(type.lowercased())-\(found.count)", "tabId": -1, "windowId": -1,
                          "documentId": "\(type.lowercased())-\(extensionID)", "frameId": type == "BACKGROUND" ? -1 : 0,
                          "documentUrl": address, "documentOrigin": origin, "incognito": false])
        }
        let background = (context.webExtension.manifest["background"] as? [String: Any])?["service_worker"] as? String
        add("BACKGROUND", background.flatMap { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL })
        if let url = host.bridge.offscreen.pageURL(for: extensionID) { add("OFFSCREEN_DOCUMENT", url) }
        if let page = host.shownPopupPage(for: extensionID) { add("POPUP", URL(string: page, relativeTo: context.baseURL)?.absoluteURL) }
        for controller in WindowManager.shared.controllers where controller.root.showsSidePanel && host.showsSidePanel(of: extensionID, in: controller) {
            add("SIDE_PANEL", controller.root.sidePanel.webView?.url)
        }
        // Chrome's filter: each field given narrows the answer.
        let filter = args.object(0)
        if let types = filter["contextTypes"] as? [String] { found = found.filter { types.contains($0["contextType"] as? String ?? "") } }
        if let urls = filter["documentUrls"] as? [String] { found = found.filter { urls.contains($0["documentUrl"] as? String ?? "") } }
        if let origins = filter["documentOrigins"] as? [String] { found = found.filter { origins.contains($0["documentOrigin"] as? String ?? "") } }
        if filter["incognito"] as? Bool == true { found = [] }
        return found
    }
}

// MARK: - runtime.onInstalled

/// Whether the extension's `runtime.onInstalled` should say "install" (webkit-differences.js asks). WebKit says it each
/// time an extension is turned back on, which Chrome never does, and Tampermonkey then turns off every script it has
/// as planted. Zigzag knows what it installed this session; it says so once, to the start that follows.
@available(macOS 15.4, *)
@MainActor
final class BridgeRuntime: BridgeNamespace {
    static let name = "runtime"
    static let permission = ""
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        guard fn == "isNewInstall" else { throw BridgeError.unsupported(Self.name, fn) }
        return host.profile.installs.newlyInstalled.remove(extensionID) != nil
    }
}

// MARK: - Tab favicons

/// `favIconUrl` on the tabs `tabs.query` and `tabs.get` answer, which WebKit leaves out: Sound Booster's popup shows
/// each tab it boosts by its site's icon, and drew an empty square. Chrome gives it with the tab's address, so here
/// too: only for a tab open now, not private, whose address the extension may read. The icon is the one Zigzag
/// shows, as a small PNG data: URL, which any extension page can draw without fetching anything.
@available(macOS 15.4, *)
@MainActor
final class BridgeFavicons: BridgeNamespace {
    static let name = "favicons"
    static let permission = ""
    /// The side of the icon handed over, in pixels: Chrome's own are 16 pt, drawn sharp at 2x.
    static let side = 32

    private var encoded: [ObjectIdentifier: (image: NSImage, url: String)] = [:]
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        guard fn == "forPages", let asked = args.first as? [Any] else { throw BridgeError.unsupported(Self.name, fn) }
        guard let context = host.context(for: extensionID) else { return [] }
        let readsAll = context.hasPermission(.tabs)
        // Its own profile's tabs: the only ones it's told about.
        let open = WindowManager.shared.controllers.filter { !$0.tabManager.isPrivate }.flatMap(\.tabManager.allTabs).compactMap { tab -> OpenTab? in
            guard tab.profile === host.profile, let url = tab.webView?.url ?? tab.url else { return nil }
            return OpenTab(url: url.absoluteString, icon: tab.favicon, isPrivate: tab.isPrivate,
                           mayRead: readsAll || context.hasAccess(to: url, in: tab))
        }
        return Self.icons(for: asked.map { $0 as? String }, among: open).map { $0.flatMap(dataURL).map { $0 as Any } ?? NSNull() }
    }

    struct OpenTab {
        let url: String
        let icon: NSImage?
        let isPrivate: Bool
        let mayRead: Bool
    }

    /// The icon for each address asked about: an open tab's, when one shows it and the extension may read it. Never
    /// one from history or the icon cache, so asking can't tell where you've been.
    static func icons(for asked: [String?], among open: [OpenTab]) -> [NSImage?] {
        asked.map { url in
            guard let url else { return nil }
            return open.first { $0.url == url && !$0.isPrivate && $0.mayRead && $0.icon != nil }?.icon
        }
    }

    /// The icon as a PNG data: URL, kept while the tab's image is the same.
    private func dataURL(_ image: NSImage) -> String? {
        let key = ObjectIdentifier(image)
        if let kept = encoded[key], kept.image === image { return kept.url }
        guard let url = Self.dataURL(image, side: Self.side) else { return nil }
        if encoded.count > 200 { encoded.removeAll() }
        encoded[key] = (image, url)
        return url
    }

    static func dataURL(_ image: NSImage, side: Int) -> String? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

// MARK: - system.display

/// `chrome.system.display`: your screens' sizes and places, as Chrome reports them (from the top left of the main
/// screen, in points). Extensions read it to place a window of their own (Sound Booster does, as it starts).
@available(macOS 15.4, *)
@MainActor
final class BridgeDisplay: BridgeNamespace {
    static let name = "system.display"
    static let permission = "system.display"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "getInfo":
            let screens = NSScreen.screens
            let top = screens.first?.frame.maxY ?? 0
            let rect = { (frame: NSRect) -> [String: Any] in
                ["left": Int(frame.minX), "top": Int(top - frame.maxY), "width": Int(frame.width), "height": Int(frame.height)]
            }
            return screens.enumerated().map { index, screen -> [String: Any] in
                let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(index)
                let dpi = 72 * screen.backingScaleFactor
                return [
                    "id": String(number), "name": screen.localizedName, "mirroringSourceId": "", "mirroringDestinationIds": [String](),
                    "isPrimary": index == 0, "isInternal": CGDisplayIsBuiltin(number) != 0, "isEnabled": true, "isUnified": false,
                    "dpiX": dpi, "dpiY": dpi, "rotation": 0, "hasTouchSupport": false, "hasAccelerometerSupport": false,
                    "availableDisplayZoomFactors": [1], "displayZoomFactor": 1, "modes": [[String: Any]](),
                    "bounds": rect(screen.frame), "workArea": rect(screen.visibleFrame),
                    "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
                ]
            }
        case "getDisplayLayout":
            return [[String: Any]]()
        default:
            throw BridgeError.unsupported(Self.name, fn)
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
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
                guard self.host.bridge.isListened("idle.onStateChanged") else { self.timer?.invalidate(); self.timer = nil; return }
                let now = Self.state(threshold: self.interval)
                if now != self.last { self.last = now; self.host.bridge.emit("idle.onStateChanged", [now]) }
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance speaking, with the extension and the ID its script gave it for `onEvent`.
    private var speaking: [ObjectIdentifier: (extensionID: String, id: String)] = [:]

    init(host: ExtensionHost) {
        self.host = host
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
        host.bridge.emit("tts.utterance", [owner.id, event], to: owner.extensionID)
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    private var assertions: [String: IOPMAssertionID] = [:]

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "requestKeepAwake":
            release(extensionID)
            let type = args.string(0) == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            var id: IOPMAssertionID = 0
            let reason = "An extension in Zigzag (\(host.displayName(for: extensionID)))" as CFString
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    private var pages: [String: WKWebView] = [:]
    /// The extension's offscreen page's address, if it has one open (for runtime.getContexts).
    func pageURL(for extensionID: String) -> URL? { pages[extensionID]?.url }
    /// Off screen, but in a window: a page in no window counts as hidden, and WebKit pauses its sound.
    private var window: NSWindow?

    private func place(_ page: WKWebView) {
        if self.window == nil {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            // Never seen, wherever macOS puts it: a video going full screen brings windows onto its space, and this
            // one would show there as a white box. Clear, it still counts as shown, so the page's sound keeps playing.
            window.alphaValue = 0
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone, .stationary]
            window.orderBack(nil)
            self.window = window
        }
        // Behind every other window, it would count as covered up, and hidden all the same.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if page.responds(to: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(page.method(for: occlusion), to: SetBool.self)(page, occlusion, false)
        }
        window?.contentView?.addSubview(page)
    }

    private func remove(_ extensionID: String) {
        guard let page = pages.removeValue(forKey: extensionID) else { return }
        page.stopLoading()
        page.removeFromSuperview()
        if pages.isEmpty { window?.close(); window = nil }
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "createDocument":
            guard pages[extensionID] == nil else { throw BridgeError("Only a single offscreen document may be created.") }
            guard let context = host.context(for: extensionID), let configuration = context.webViewConfiguration,
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
            ExtensionLog.write("offscreen page for \(host.displayName(for: extensionID)) opened: \(url.lastPathComponent)")
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

// MARK: - extension fetch

/// WebKit leaves SameSite cookies out of extension fetches even with host access. Reads use a blank page at
/// the target origin; writes use a temporary native session to preserve the sender's Chrome extension Origin.
/// Both use the owning profile's cookies. Live host permission authorizes requests, with no vendor allowlist.
@available(macOS 15.4, *)
@MainActor
final class BridgeExtensionFetch: BridgeNamespace {
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    static let name = "extensionFetch"
    // Fetching with cookies needs host access, not the cookies API's separate permission to inspect them.
    static let permission = ""
    private let requests = ExtensionFetchRequests()

    /// As in Chrome: a site the extension asked for in its manifest (host permissions, optional ones, or its content
    /// scripts' matches) that it may reach now. Site access can grant a site it never asked for (a click on an
    /// extension set to "When you click it"), and that alone never brings the site's cookies.
    static func allows(_ url: URL, context: WKWebExtensionContext) -> Bool {
        ["http", "https"].contains(url.scheme ?? "") && url.host() != nil && url.user == nil && url.password == nil
            && context.webExtension.allRequestedMatchPatterns.union(context.webExtension.optionalPermissionMatchPatterns).contains { $0.matches(url) }
            && context.hasAccess(to: url)
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        if fn == "cancel", let text = args.string(0), let id = UUID(uuidString: text) {
            requests.cancel(id, extensionID: extensionID)
            return nil
        }
        guard fn == "fetch" else { throw BridgeError.unsupported(Self.name, fn) }
        let options = args.object(0)
        guard let requestID = options.string("requestID").flatMap(UUID.init(uuidString:)),
              let text = options.string("url"), let url = URL(string: text) else { throw BridgeError("Invalid extension request.") }
        let host = host
        guard let context = host.context(for: extensionID) else { throw BridgeError("The extension is no longer loaded.") }
        // Without host access, ordinary WebKit fetch decides what is available through the site's CORS policy.
        guard Self.allows(url, context: context) else { return ["fallback": true] }
        return try await requests.response(options, url: url, extensionID: extensionID, store: host.profile.store, requestID: requestID) {
            host.context(for: extensionID) === context && Self.allows(url, context: context)
        }
    }

    func release(_ extensionID: String) { requests.release(extensionID) }
}

/// One profile's in-flight requests. Kept apart from the host so transport tests use temporary stores without
/// creating persistent profiles; the bridge always supplies its own profile's store and live permission check.
@MainActor
final class ExtensionFetchRequests {
    private struct RequestKey: Hashable {
        let extensionID: String
        let id: UUID
    }
    private var pages: [RequestKey: WKWebView] = [:]
    private var writes: [RequestKey: Task<ExtensionWriteResponse, any Error>] = [:]
    // A cancel can arrive before its fetch message has started. Keep that decision briefly, with a fixed bound.
    private var cancelled: [RequestKey: Date] = [:]

    func response(_ options: [String: Any], url: URL, extensionID: String, store: WKWebsiteDataStore,
                  requestID id: UUID = UUID(), authorize: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> Any? {
        let key = RequestKey(extensionID: extensionID, id: id)
        if let when = cancelled.removeValue(forKey: key), when.timeIntervalSinceNow > -40 { throw BridgeError("Extension request cancelled.") }
        guard pages[key] == nil, writes[key] == nil else { throw BridgeError("Extension request is already running.") }
        let method = (options["method"] as? String ?? "GET").uppercased()
        if !["GET", "HEAD"].contains(method) {
            // A website-origin helper gives POST the wrong Origin. A short-lived native session preserves the
            // Chrome extension origin and uses only this profile's cookies, including server-side deletions.
            let request = try Self.writeRequest(options, url: url, extensionID: extensionID)
            // Only WebKit's cookie store stays on the main thread; the jar, the request and its body leave it.
            let task = Task {
                // The profile's proxy, set by an extension through chrome.proxy, carries these as it carries its pages.
                try await ExtensionWrite.send(request, cookies: await store.httpCookieStore.allCookies(), proxies: store.proxyConfigurations,
                                              authorize: authorize) { set, deleted in
                    for cookie in deleted { await store.httpCookieStore.deleteCookie(cookie) }
                    for cookie in set { await store.httpCookieStore.setCookie(cookie) }
                }
            }
            writes[key] = task
            defer { writes[key] = nil }
            return try await task.value.value
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
        // No extension controller, injected scripts, or remote document: only our own blank page and fetch below.
        let page = WKWebView(frame: .zero, configuration: configuration)
        pages[key] = page
        defer { pages[key] = nil; page.stopLoading() }
        let loaded = PageLoad()
        page.navigationDelegate = loaded
        let origin = url.deletingLastPathComponent().absoluteURL
        page.loadHTMLString("<!doctype html><title></title>", baseURL: origin)
        await loaded.wait(seconds: 10)
        // Site access can change while the blank page is being prepared.
        guard authorize() else { throw BridgeError("The extension can no longer access this URL.") }
        guard pages[key] != nil else { throw BridgeError("Extension request cancelled.") }
        return try await page.callAsyncJavaScript(Self.requestScript, arguments: ["options": options, "target": url.absoluteString], in: nil, contentWorld: .page)
    }

    /// What a write sends, read from the extension's message here so the rest can leave the main thread.
    private static func writeRequest(_ options: [String: Any], url: URL, extensionID: String) throws -> ExtensionWrite.Request {
        let method = (options["method"] as? String ?? "POST").uppercased()
        guard ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method),
              options["body"] == nil || options["body"] is NSNull || options["body"] is String else {
            throw BridgeError("Unsupported extension request.")
        }
        // Derived from the native-message sender, never a payload-supplied Origin or a website's origin.
        return ExtensionWrite.Request(url: url, method: method, body: (options["body"] as? String).map { Data($0.utf8) },
                                      headers: (options["headers"] as? [[String]] ?? []).filter { $0.count == 2 },
                                      cache: options["cache"] as? String, redirect: options["redirect"] as? String,
                                      origin: "chrome-extension://\(extensionID)")
    }

    static let requestScript = """
        const url = new URL(target);
        if (location.origin !== url.origin) throw new Error('Request page could not be loaded.');
        const method = (options.method || 'GET').toUpperCase();
        if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'].includes(method)
            || (options.body != null && typeof options.body !== 'string')) throw new Error('Unsupported extension request.');
        const headers = new Headers(options.headers || []);
        for (const name of ['cookie', 'cookie2', 'origin', 'referer', 'host']) headers.delete(name);
        const controller = new AbortController();
        globalThis.__zigzagFetchAbort = controller;
        const timeout = setTimeout(() => controller.abort(), 30000);
        try {
          const response = await fetch(url.href, {
            method, headers, body: options.body,
            credentials: 'include', cache: options.cache || 'default', mode: 'same-origin',
            redirect: options.redirect || 'follow', referrerPolicy: 'no-referrer', signal: controller.signal
          });
          const bytes = new Uint8Array(await response.arrayBuffer());
          let binary = '';
          for (let start = 0; start < bytes.length; start += 32768) binary += String.fromCharCode(...bytes.subarray(start, start + 32768));
          return { status: response.status, statusText: response.statusText, headers: [...response.headers.entries()],
                   body: btoa(binary), url: response.url, redirected: response.redirected };
        } finally { clearTimeout(timeout); delete globalThis.__zigzagFetchAbort; }
        """

    func cancel(_ id: UUID, extensionID: String) {
        let key = RequestKey(extensionID: extensionID, id: id)
        if let write = writes.removeValue(forKey: key) { write.cancel(); return }
        guard let page = pages.removeValue(forKey: key) else {
            cancelled = cancelled.filter { $0.value.timeIntervalSinceNow > -40 }
            if cancelled.count >= 256, let oldest = cancelled.min(by: { $0.value < $1.value })?.key { cancelled[oldest] = nil }
            cancelled[key] = Date()
            return
        }
        page.evaluateJavaScript("globalThis.__zigzagFetchAbort?.abort()", completionHandler: nil)
        // Navigation also cancels fetches; stopLoading alone only stops a document load.
        page.loadHTMLString("", baseURL: nil)
    }

    func release(_ extensionID: String) {
        for key in Array(pages.keys) + Array(writes.keys) where key.extensionID == extensionID { cancel(key.id, extensionID: extensionID) }
        cancelled = cancelled.filter { $0.key.extensionID != extensionID }
    }
}

/// A write's network part, away from the main thread: a short-lived session whose jar starts with the target's
/// cookies from the profile, and whose cookie changes go back to the profile's store, which is the main thread's.
nonisolated enum ExtensionWrite {
    struct Request: Sendable {
        let url: URL
        let method: String
        let body: Data?
        let headers: [[String]]
        let cache: String?
        let redirect: String?
        let origin: String
    }

    /// Cookies that go back to the profile: those the server set or changed, and those it deleted.
    typealias Apply = @MainActor @Sendable (_ set: [HTTPCookie], _ deleted: [HTTPCookie]) async -> Void

    @concurrent static func send(_ input: Request, cookies: [HTTPCookie], proxies: [ProxyConfiguration] = [],
                                 authorize: @escaping @MainActor @Sendable () -> Bool,
                                 apply: @escaping Apply) async throws -> ExtensionWriteResponse {
        let url = input.url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        configuration.proxyConfigurations = proxies
        let jar = configuration.httpCookieStorage!
        jar.cookieAcceptPolicy = .onlyFromMainDocumentDomain
        // Never use HTTPCookieStorage.shared. The temporary jar starts with cookies for this target only.
        let host = url.host()?.lowercased() ?? ""
        let scoped = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain == host || (domain.hasPrefix(".") && (host == String(domain.dropFirst()) || host.hasSuffix(domain)))
        }
        jar.setCookies(scoped, for: url, mainDocumentURL: url)
        try Task.checkCancellation()
        guard await authorize() else { throw BridgeError("The extension can no longer access this URL.") }
        let transfer = ExtensionWriteTransfer()
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = input.method
        request.httpBody = input.body
        switch input.cache {
        case "no-store", "reload": request.cachePolicy = .reloadIgnoringLocalCacheData
        case "no-cache": request.cachePolicy = .reloadRevalidatingCacheData
        case "force-cache": request.cachePolicy = .returnCacheDataElseLoad
        default: break
        }
        for header in input.headers {
            let name = header[0].lowercased()
            if ["cookie", "cookie2", "origin", "referer", "host", "content-length", "connection", "transfer-encoding"].contains(name)
                || name.hasPrefix("sec-") || name.hasPrefix("proxy-") { continue }
            request.setValue(header[1], forHTTPHeaderField: header[0])
        }
        request.setValue(input.origin, forHTTPHeaderField: "Origin")
        var redirected = false
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard await authorize() else { throw BridgeError("The extension can no longer access this URL.") }
            let before = jar.cookies ?? []
            let (data, raw) = try await transfer.run(request, in: session)
            try Task.checkCancellation()
            guard let response = raw as? HTTPURLResponse else { throw BridgeError("Invalid extension response.") }
            // CFNetwork applies all Set-Cookie fields (including Max-Age=0) to the isolated jar. Apply only its
            // delta back to WebKit, rather than replacing the profile's whole jar or restoring stale cookies.
            let after = jar.cookies ?? []
            func matches(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool { a.name == b.name && a.domain == b.domain && a.path == b.path }
            let deleted = before.filter { old in !after.contains { matches(old, $0) } }
            let set = after.filter { cookie in
                guard let old = before.first(where: { matches(cookie, $0) }) else { return true }
                return NSDictionary(dictionary: old.properties ?? [:]) != NSDictionary(dictionary: cookie.properties ?? [:])
            }
            if !set.isEmpty || !deleted.isEmpty { await apply(set, deleted) }
            let status = response.statusCode
            if [301, 302, 303, 307, 308].contains(status), let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: request.url)?.absoluteURL {
                guard input.redirect != "error", SiteOrigin.of(next) == SiteOrigin.of(url),
                      next.user == nil, next.password == nil else { throw BridgeError("Extension request redirect is not allowed.") }
                if status == 303 || ([301, 302].contains(status) && request.httpMethod == "POST") {
                    request.httpMethod = "GET"
                    request.httpBody = nil
                    for name in ["Content-Type", "Content-Encoding", "Content-Language", "Content-Location"] { request.setValue(nil, forHTTPHeaderField: name) }
                }
                request.url = next
                redirected = true
                continue
            }
            let headers = response.allHeaderFields.compactMap { key, value -> [String]? in
                let name = String(describing: key).lowercased()
                return ["set-cookie", "set-cookie2"].contains(name) ? nil : [name, String(describing: value)]
            }
            return ExtensionWriteResponse(status: status, headers: headers, body: data.base64EncodedString(),
                                          url: response.url?.absoluteString ?? url.absoluteString, redirected: redirected)
        }
        throw BridgeError("Too many extension request redirects.")
    }
}

nonisolated struct ExtensionWriteResponse: Sendable {
    let status: Int
    let headers: [[String]]
    /// Base64, made off the main thread.
    let body: String
    let url: String
    let redirected: Bool

    var value: [String: Any] {
        ["status": status, "statusText": "", "headers": headers, "body": body, "url": url, "redirected": redirected]
    }
}

/// One write's response at a time. Redirects come back unfollowed, to be checked above after their cookies.
nonisolated private final class ExtensionWriteTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var done: CheckedContinuation<(Data, URLResponse), any Error>?

    func run(_ request: URLRequest, in session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    data = Data()
                    response = nil
                    done = continuation
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { self.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, data, response) = lock.withLock {
            defer { done = nil }
            return (done, self.data, self.response)
        }
        if let error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: (data, response)) }
        else { continuation?.resume(throwing: BridgeError("Invalid extension response.")) }
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host; super.init() }
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
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: WebKitSetup.makeConfiguration(for: host.profile))
        webView.navigationDelegate = self
        var window: NSWindow?
        if interactive {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            made.title = String(localized: "Sign In for \(host.displayName(for: extensionID))", comment: "Title of the window where an extension signs in to an account. The placeholder is the extension's name.")
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
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
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
        if let controller, controller.root.showsSidePanel, host.showsSidePanel(of: extensionID, in: controller) {
            hide(in: controller)
        } else {
            _ = open(extensionID, in: controller)
        }
        return true
    }

    @discardableResult
    func open(_ extensionID: String, in controller: BrowserWindowController?) -> Bool {
        guard let controller, !disabled.contains(extensionID), let path = path(for: extensionID),
              let context = host.context(for: extensionID), let configuration = context.webViewConfiguration,
              let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL, url.host() == context.baseURL.host() else { return false }
        let root = controller.root
        if root.showsSidePanel, host.showsSidePanel(of: extensionID, in: controller), root.sidePanel.webView?.url?.path == url.path { return true }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        let image = context.webExtension.icon(for: NSSize(width: 32, height: 32))
        root.sidePanel.show(webView, extensionID: extensionID, name: context.webExtension.displayName
                                ?? String(localized: "Extension", comment: "Name on an extension's side panel when the extension has none."), image: image)
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
        for controller in WindowManager.shared.controllers where host.showsSidePanel(of: extensionID, in: controller) { hide(in: controller) }
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
/// Zigzag's own (tab-capture.js). A streamed tab (YouTube), whose sound neither can reach, is heard where WebKit
/// plays it, only while it's the one page in Zigzag with sound (SharedSoundCapture). As in Chrome the tab goes quiet
/// while captured, and the extension plays it back if it wants. Only the tab you used the extension on (its button, menu item or shortcut), while it shows the same site,
/// never a private window's, and only while the popup or window of that use is open or soon after; a note says it's
/// listening, and it stops when the extension stops listening or goes away.
/// `getMediaStreamId` is the same, in two steps (Sound Booster): it names that tab, and the extension's
/// page then asks `getUserMedia` for that tab, within a few seconds, once.
@available(macOS 15.4, *)
@MainActor
final class BridgeTabCapture: NSObject, BridgeNamespace, WKScriptMessageHandler {
    static let name = "tabCapture"
    static let permission = "tabCapture"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host; super.init() }
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
        var world: WKContentWorld
        var script: String
        /// Its extension needs a moment to start listening after a capture begins.
        var started = Date()
        /// Whether the page's own sound has come through yet (streamed video gives Web Audio only silence).
        var heard = false
        /// Sound waiting for the extension's page to collect it (and, for a shared capture, word of it pausing or
        /// carrying on), and when it last did.
        var waiting: [Any] = []
        var lastRead = Date()
        var hasRead = false
        /// The extension's page that asked (its popup, its offscreen page): the capture is that page's, as in Chrome.
        var page = ""
        /// Which opening of the extension's popup was showing when it began.
        var opening = 0
        /// A streamed tab, heard where WebKit plays it while it's the only page with sound; and the site it showed
        /// when the capture began, which it ends on leaving.
        var shared: SharedSoundCapture?
        var origin: String?
        /// Its page's own sound gave only silence, and Zigzag is looking whether it's streamed.
        var switching = false
        /// Paused at some point (another page had sound), so carrying on again is worth a word.
        var paused = false
    }
    /// Each extension's popup openings, counted, so closing one ends only what that one started.
    private var openings: [String: Int] = [:]

    /// The extension's popup opened again: a new page, whose captures are its own.
    func popupOpened(_ extensionID: String) -> Int {
        openings[extensionID, default: 0] += 1
        return openings[extensionID]!
    }

    func currentOpening(_ extensionID: String) -> Int { openings[extensionID] ?? 0 }
    private var taps: [String: Tap] = [:]
    /// Tabs named by getMediaStreamId, waiting for the extension to ask for their sound.
    private struct Pending {
        let extensionID: String
        weak var tab: Tab?
        let origin: String?
        let expires: Date
    }
    private var pending: [String: Pending] = [:]
    /// Tabs whose capture is being set up.
    private var starting = Set<UUID>()
    /// Pages' content controllers given the message handler (in both worlds), only while a capture in one of their
    /// pages is live: at other times a page can't see it. Kept by controller, which a page's pop-ups share with it.
    private var listening: [ObjectIdentifier: WKUserContentController] = [:]

    func listen(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        guard listening.updateValue(controller, forKey: ObjectIdentifier(controller)) == nil else { return }
        controller.add(self, contentWorld: Self.world, name: "zigzagTap")
        controller.add(self, contentWorld: .page, name: "zigzagTap")
    }

    /// The handler goes from every page with no capture live, once none is being set up.
    func stopListeningWhereDone() {
        guard starting.isEmpty else { return }
        let live = Set(taps.values.compactMap { $0.webView.map { ObjectIdentifier($0.configuration.userContentController) } })
        for (key, controller) in listening where !live.contains(key) {
            controller.removeScriptMessageHandler(forName: "zigzagTap", contentWorld: Self.world)
            controller.removeScriptMessageHandler(forName: "zigzagTap", contentWorld: .page)
            listening[key] = nil
        }
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "getMediaStreamId":
            let (tab, _) = try invokedTab(for: extensionID)
            try ensureNotCaptured(tab, by: extensionID)
            pending = pending.filter { $0.value.expires > Date() }
            let id = UUID().uuidString
            pending[id] = Pending(extensionID: extensionID, tab: tab, origin: SiteOrigin.of(tab.webView?.url ?? tab.url), expires: Date().addingTimeInterval(10))
            return id
        case "capture":
            let options = args.object(0)
            guard options["audio"] as? Bool == true else { throw BridgeError("Zigzag can capture a tab's sound, not its picture") }
            let tab: Tab, controller: BrowserWindowController
            if let streamID = options.string("streamId") {
                // A tab getMediaStreamId named: good once, for a few seconds, for the extension it was given to.
                // Still on the site it was named on.
                guard let named = pending.removeValue(forKey: streamID), let namedTab = named.tab,
                      let owner = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === namedTab } }),
                      Self.namedStreamHolds(givenTo: named.extensionID, askedBy: extensionID, expires: named.expires, namedOrigin: named.origin,
                                            origin: SiteOrigin.of(namedTab.webView?.url ?? namedTab.url), isPrivate: owner.tabManager.isPrivate || namedTab.isPrivate)
                else { throw BridgeError("Invalid stream ID") }
                try ensureReachable(namedTab, in: owner, by: extensionID)
                (tab, controller) = (namedTab, owner)
            } else {
                (tab, controller) = try invokedTab(for: extensionID)
            }
            guard let webView = tab.webView else { throw BridgeError("Cannot capture a tab here") }
            try ensureNotCaptured(tab, by: extensionID)
            // Counted as captured from here: a second request while this one starts is refused, not run alongside.
            starting.insert(tab.id)
            // A capture that doesn't start takes the handler away again.
            defer {
                starting.remove(tab.id)
                stopListeningWhereDone()
            }
            listen(in: webView)
            let id = UUID().uuidString
            // The page's own Web Audio first: when it plays through that (YouTube does), its elements can't be tapped.
            var routed: Int?
            do { routed = try await webView.callAsyncJavaScript(Self.pageScript, arguments: ["tap": id, "stop": false], in: nil, contentWorld: .page) as? Int }
            catch { ExtensionLog.write("tab capture page half: \(error)") }
            let page = options.string("page") ?? ""
            if let routed, routed > 0 {
                taps[id] = Tap(extensionID: extensionID, webView: webView, tabID: tab.id, world: .page, script: Self.pageScript, page: page, opening: currentOpening(extensionID))
                ExtensionLog.write("tab capture for \(host.displayName(for: extensionID)): the page's own audio, \(routed) source(s)")
            } else {
                let result = try await webView.callAsyncJavaScript(Self.elementScript, arguments: ["tap": id, "stop": false], in: nil, contentWorld: Self.world) as? [String: Any]
                // Streamed sound (YouTube, most video sites) never reaches Web Audio, and nothing in the tab was
                // touched: it's heard where WebKit plays it, which plays other tabs and private windows too, so only
                // while this tab is the one page with sound.
                if result?["streamed"] as? Bool == true {
                    taps[id] = Tap(extensionID: extensionID, webView: webView, tabID: tab.id, world: Self.world, script: Self.elementScript, page: page, opening: currentOpening(extensionID))
                    ExtensionLog.write("tab capture for \(host.displayName(for: extensionID)): streamed, so WebKit's sound, only while this tab is the one with sound")
                    // Another page already has sound: it begins paused, and says so.
                    if !startShared(id) {
                        Toast.show(Self.pausedText(host.displayName(for: extensionID)), symbol: "pause.circle", duration: 3, in: controller)
                        return ["id": id, "tabId": tab.id.hashValue & 0x7fffffff]
                    }
                } else {
                    guard let elements = (result?["tapped"] as? NSNumber)?.intValue else { throw BridgeError("Play something in the tab first, then try again") }
                    taps[id] = Tap(extensionID: extensionID, webView: webView, tabID: tab.id, world: Self.world, script: Self.elementScript, page: page, opening: currentOpening(extensionID))
                    ExtensionLog.write("tab capture for \(host.displayName(for: extensionID)): \(elements) media element(s)")
                }
            }
            Toast.show(String(localized: "\(host.displayName(for: extensionID)) is listening to this tab", comment: "Toast when an extension starts hearing a tab's sound. The placeholder is the extension's name."), symbol: "waveform", duration: 3, in: controller)
            return ["id": id, "tabId": tab.id.hashValue & 0x7fffffff]
        case "read":
            // The page collects what's arrived since it last asked: steadier than pushing to it, since WebKit can
            // drop a page's port without telling it.
            // Gone (stopped, or its popup closed): nothing more to collect, quietly.
            guard let id = args.string(0), taps[id]?.extensionID == extensionID else { return nil }
            // A shared capture takes a fresh look at every page's sound before handing anything over.
            if taps[id]?.shared != nil { checkShared(id) }
            guard var tap = taps[id] else { return nil }
            let chunks = tap.waiting
            tap.waiting = []
            tap.lastRead = Date()
            tap.hasRead = true
            taps[id] = tap
            return chunks
        case "play":
            // What the extension plays while a shared capture hears the tab (WebKit's sound is muted meanwhile, as a
            // captured tab is in Chrome): played from Zigzag itself, so it's heard, and never captured again.
            guard let id = args.string(0), let source = args.string(1), let tap = taps[id], tap.extensionID == extensionID,
                  tap.shared?.isHearing == true, let rate = args.number(2), let pcm = args.string(3),
                  let data = Data(base64Encoded: pcm) else { return nil }
            let samples = data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
            NativeAudioOut.shared.feed(id + "|" + source, samples: samples, rate: rate)
            return nil
        case "stop":
            if let id = args.string(0), taps[id]?.extensionID == extensionID { stop(id) }
            return nil
        case "getCapturedTabs":
            return taps.values.filter { $0.extensionID == extensionID }.map { ["tabId": $0.tabID.hashValue & 0x7fffffff, "status": "active", "fullscreen": false] as [String: Any] }
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// The tab you used the extension on (its button, its menu item, its shortcut), while it still shows the site it
    /// showed then, and only while the popup or window of that use is open or a moment after. Never a private tab,
    /// nor a site the extension can't reach or where extensions are off.
    private func invokedTab(for extensionID: String) throws -> (Tab, BrowserWindowController) {
        guard let invocation = host.use.invocations[extensionID], let found = tab(invocation.tabID),
              host.use.mayCapture(extensionID, tabID: found.0.id, origin: SiteOrigin.of(found.0.webView?.url ?? found.0.url),
                                  popupShown: host.isPopupShown(for: extensionID),
                                  windowOpen: { id in PopupWindowController.all.contains { ObjectIdentifier($0) == id && $0.window?.isVisible == true } }) else {
            throw BridgeError("Extension has not been invoked for the current page (see activeTab permission).")
        }
        try ensureReachable(found.0, in: found.1, by: extensionID)
        return found
    }

    /// A tab the extension may hear: an everyday one, with its page, on a site its site access reaches.
    private func ensureReachable(_ tab: Tab, in controller: BrowserWindowController, by extensionID: String) throws {
        guard !controller.tabManager.isPrivate, !tab.isPrivate, let webView = tab.webView, let url = webView.url ?? tab.url,
              let context = host.context(for: extensionID) else { throw BridgeError("Cannot capture a tab here") }
        guard Self.siteAllows(url, offSites: ExtensionStore.extensionsOffSites,
                              hasAccess: context.hasAccess(to: url, in: tab), allSites: host.profile.installs.siteAccess(extensionID) == .all) else {
            throw BridgeError("Extension manifest must request permission to access this host.")
        }
    }

    /// Whether a stream ID from getMediaStreamId still names a tab to hear: asked for by the extension it was given to
    /// (from any of its pages, its offscreen one included, as Sound Booster does), within its few seconds, with the
    /// tab still on the site it was named on, and never a private one.
    static func namedStreamHolds(givenTo: String, askedBy: String, expires: Date, namedOrigin: String?, origin: String?,
                                 isPrivate: Bool, now: Date = Date()) -> Bool {
        givenTo == askedBy && expires > now && !isPrivate && namedOrigin != nil && origin == namedOrigin
    }

    /// Whether site settings let an extension capture a page there: never where extensions are off; else where it has
    /// access, or anywhere when you let it reach every site it asked for (Chrome's capture needs no host permission).
    static func siteAllows(_ url: URL, offSites: Set<String>, hasAccess: Bool, allSites: Bool) -> Bool {
        if let site = ContentBlocker.site(of: url), offSites.contains(where: { site == $0 || site.hasSuffix("." + $0) }) { return false }
        return hasAccess || allSites
    }

    /// As in Chrome, a tab is captured once at a time: a second capture is refused until the first stops (extensions
    /// expect this, and check before asking again). A capture whose page has gone, or whose extension stopped
    /// listening, no longer counts.
    /// Another extension refused this way is told so where you're looking, naming the one that has the tab: it
    /// would otherwise just seem broken.
    private func ensureNotCaptured(_ tab: Tab, by extensionID: String) throws {
        if starting.contains(tab.id) { throw BridgeError("Cannot capture a tab with an active stream.") }
        for (id, tap) in taps where tap.tabID == tab.id {
            // Its page collects every few hundredths of a second: one that's stopped (its popup closed) has ended,
            // as Chrome ends a closed popup's capture at once.
            let collecting = tap.hasRead ? Date().timeIntervalSince(tap.lastRead) < 0.3 : Date().timeIntervalSince(tap.started) < 5
            if tap.webView == nil || tap.webView !== tab.webView || !collecting {
                stop(id, because: "its page closed")
            } else {
                if tap.extensionID != extensionID, let controller = self.tab(tab.id)?.1 {
                    tellBusy(extensionID, holder: tap.extensionID, in: controller)
                }
                throw BridgeError("Cannot capture a tab with an active stream.")
            }
        }
    }

    static func busyText(_ name: String, holder: String) -> String {
        String(localized: "\(name) can’t listen to this tab while \(holder) is. Turn \(holder) off for this tab, then try again.",
               comment: "Toast when an extension asks to hear a tab another extension is already listening to; only one can at a time, as in Chrome. The first placeholder is the extension that asked, the other two the one listening, like Sound Booster.")
    }

    private func tellBusy(_ extensionID: String, holder: String, in controller: BrowserWindowController) {
        Toast.show(Self.busyText(host.displayName(for: extensionID), holder: host.displayName(for: holder)), symbol: "waveform", duration: 5, in: controller)
    }

    /// Whether the capture's extension still hears it. Just after a capture starts, its page is still saying it
    /// listens (its first samples can arrive before that does), so it counts as listening for a few seconds.
    private func isListening(_ tap: Tap) -> Bool {
        Date().timeIntervalSince(tap.started) < 5 || Date().timeIntervalSince(tap.lastRead) < 2
    }

    /// Keeps a chunk for the page to collect; never more than about a second, the oldest going first.
    private func keep(_ chunk: Any, for id: String) {
        guard var tap = taps[id] else { return }
        tap.waiting.append(chunk)
        // Sound goes, never word of a shared capture pausing or carrying on.
        while tap.waiting.filter({ $0 is [Any] }).count > 60, let oldest = tap.waiting.firstIndex(where: { $0 is [Any] }) {
            tap.waiting.remove(at: oldest)
        }
        taps[id] = tap
    }

    private func stop(_ id: String, because reason: String = "the extension stopped it") {
        guard let tap = taps.removeValue(forKey: id) else { return }
        ExtensionLog.write("tab capture for \(host.displayName(for: tap.extensionID)) ended after \(Int(Date().timeIntervalSince(tap.started))) s: \(reason)")
        // A shared capture's tap goes with it (WebKit's sound comes back), and so does what the extension played.
        tap.shared?.end()
        NativeAudioOut.shared.end(sourcesStartingWith: id)
        if !taps.values.contains(where: { $0.shared != nil }) { sharedTimer?.invalidate(); sharedTimer = nil }
        tap.webView?.callAsyncJavaScript(tap.script, arguments: ["tap": id, "stop": true], in: nil, in: tap.world, completionHandler: nil)
        stopListeningWhereDone()
    }

    private func tab(_ id: UUID) -> (Tab, BrowserWindowController)? {
        for controller in WindowManager.shared.controllers {
            if let tab = controller.tabManager.allTabs.first(where: { $0.id == id }) { return (tab, controller) }
        }
        return nil
    }

    /// Web Audio cannot capture some streamed or protected media. Failing here keeps the original tab's sound
    /// playing without exposing audio from other tabs through WebKit's shared GPU process.
    private func stopUnavailableCapture(_ id: String) {
        let tap = taps[id]
        stop(id, because: "audio cannot be captured within this tab")
        if let tap, let controller = tab(tap.tabID)?.1 { tellUnreachable(tap.extensionID, in: controller) }
    }

    /// Says where you're looking that the extension can't hear this tab, and why, instead of it seeming broken.
    private func tellUnreachable(_ extensionID: String, in controller: BrowserWindowController) {
        Toast.show(String(localized: "\(host.displayName(for: extensionID)) can’t hear this tab. Its sound is protected or can’t be reached.", comment: "Toast when an extension asks to hear a tab whose sound Zigzag can't hand it (protected video, or sound it can't reach). The placeholder is the extension's name."),
                   symbol: "waveform.slash", duration: 5, in: controller)
    }

    // MARK: A streamed tab, through WebKit's shared sound

    /// Looks at every shared capture's tab and every page's sound, often, while one is live: the tap must go the
    /// moment another page has sound, even when the extension isn't collecting.
    private var sharedTimer: Timer?

    static func pausedText(_ name: String) -> String {
        String(localized: "\(name) paused: another tab is playing", comment: "Toast when an extension hearing a streamed tab (YouTube) pauses because another tab, a private window or a video in Picture in Picture has sound; it carries on when that stops. The placeholder is the extension's name.")
    }

    /// Hears a streamed tab where WebKit plays it, guarded (SharedSoundCapture): the tap runs, muting WebKit's
    /// sound while the extension plays it back through Zigzag, only while the tab is the one page with sound.
    /// False when another page has sound already, so it begins paused.
    @discardableResult
    private func startShared(_ id: String) -> Bool {
        guard var tap = taps[id], let webView = tap.webView else { return false }
        let name = self.host.displayName(for: tap.extensionID)
        let host = self.host.context(for: tap.extensionID)?.baseURL.host()
        let shared = SharedSoundCapture(SoundSource.all(capturing: webView, extensionHost: host), now: SystemAudioTap.now()) { [weak webView] receive in
            let chunks = SharedSoundChunks(send: receive)
            chunks.report = { peak in
                ExtensionLog.write("tab capture for \(name): WebKit's sound over its first 3 s peaked at \(String(format: "%.2g", peak))\(peak == 0 ? " (silence: macOS may not be letting Zigzag hear it)" : "")")
            }
            #if DEBUG
            // Silence at the real pace, without macOS's capture, to test everything around it.
            if UserDefaults.standard.bool(forKey: "DebugFakeSystemAudio") { return FakeSharedTap(into: chunks) }
            #endif
            guard let webView else { throw SystemAudioTap.Failure.noAudioProcess }
            let system = SystemAudioTap()
            try system.start(pids: SystemAudioTap.audioProcesses(of: webView), muting: true) { samples, rate, captured in
                chunks.add(samples, rate: rate, capturedAt: captured)
            }
            return system
        }
        tap.shared = shared
        tap.origin = SiteOrigin.of(webView.url)
        let alone = shared.gate.aloneSince != nil
        tap.paused = !alone
        taps[id] = tap
        if sharedTimer == nil {
            let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkAllShared() } }
            RunLoop.main.add(timer, forMode: .common)
            sharedTimer = timer
        }
        if !alone { ExtensionLog.write("tab capture for \(name): paused from the start, another page has sound") }
        return alone
    }

    private func checkAllShared() {
        for id in taps.filter({ $0.value.shared != nil }).map(\.key) { checkShared(id) }
    }

    /// A fresh look at a shared capture: it ends when its tab closes, leaves the site, or its extension may no
    /// longer hear it or stops listening; it pauses the moment another page has sound, and carries on once the tab
    /// has been alone a moment. Then what's due goes to the extension, each buffer on this look.
    private func checkShared(_ id: String) {
        guard let tap = taps[id], let shared = tap.shared else { return }
        guard let webView = tap.webView, let (tab, controller) = tab(tap.tabID), tab.webView === webView else { stop(id, because: "its tab closed"); return }
        guard tap.origin != nil, SiteOrigin.of(webView.url) == tap.origin else { stop(id, because: "its tab went to another site"); return }
        guard (try? ensureReachable(tab, in: controller, by: tap.extensionID)) != nil else { stop(id, because: "it may no longer hear this site"); return }
        guard isListening(tap) else { stop(id, because: "it stopped listening"); return }
        let name = self.host.displayName(for: tap.extensionID)
        let now = SystemAudioTap.now()
        let host = self.host.context(for: tap.extensionID)?.baseURL.host()
        let change = shared.update(SoundSource.all(capturing: webView, extensionHost: host), now: now)
        if let failure = shared.failure {
            ExtensionLog.write("tab capture for \(name): hearing WebKit's sound failed: \(failure)")
            stopUnavailableCapture(id)
            return
        }
        switch change {
        case .paused:
            // The extension's page plays to the speakers again, and the tab is heard as usual.
            keep(["hearing": false], for: id)
            NativeAudioOut.shared.end(sourcesStartingWith: id)
            taps[id]?.paused = true
            ExtensionLog.write("tab capture for \(name): paused, another page has sound")
            Toast.show(Self.pausedText(name), symbol: "pause.circle", duration: 3, in: controller)
        case .resumed:
            // What the extension plays goes through Zigzag, since WebKit's sound is muted while the tap runs.
            keep(["hearing": true], for: id)
            ExtensionLog.write("tab capture for \(name): hearing the tab, the only one with sound")
            if tap.paused {
                taps[id]?.paused = false
                Toast.show(String(localized: "\(name) is listening to this tab", comment: "Toast when an extension starts hearing a tab's sound. The placeholder is the extension's name."), symbol: "waveform", duration: 3, in: controller)
            }
        case nil:
            break
        }
        let wallNow = Date().timeIntervalSince1970 * 1000
        for chunk in shared.take(now: now) {
            keep([chunk.rate, chunk.pcm, wallNow - (now - chunk.until) * 1000, true] as [Any], for: id)
        }
    }

    private static let streamedCheck = "return [...document.querySelectorAll('video, audio')].some((element) => !element.paused && (element.currentSrc || '').startsWith('blob:'));"

    /// The page's own Web Audio gave only silence while the tab plays. Streamed sound is heard where WebKit plays it
    /// instead, guarded; anything else (protected video) is out of reach, and you're told so.
    private func fallBackToShared(_ id: String) {
        guard var tap = taps[id], tap.shared == nil, !tap.switching, let webView = tap.webView else { return }
        tap.switching = true
        taps[id] = tap
        Task { @MainActor [weak self] in
            let streamed = (try? await webView.callAsyncJavaScript(Self.streamedCheck, arguments: [:], in: nil, contentWorld: Self.world)) as? Bool == true
            guard let self, var tap = self.taps[id], tap.webView === webView else { return }
            guard streamed else { self.stopUnavailableCapture(id); return }
            // The page's sound goes back the way it was; the tap quiets the tab instead.
            webView.callAsyncJavaScript(tap.script, arguments: ["tap": id, "stop": true], in: nil, in: tap.world, completionHandler: nil)
            tap.world = Self.world
            tap.script = Self.elementScript
            tap.switching = false
            self.taps[id] = tap
            let name = self.host.displayName(for: tap.extensionID)
            ExtensionLog.write("tab capture for \(name): the page's own audio is silent and streamed, so WebKit's sound, only while this tab is the one with sound")
            if !self.startShared(id), let controller = self.tab(tap.tabID)?.1 {
                Toast.show(Self.pausedText(name), symbol: "pause.circle", duration: 3, in: controller)
            }
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let id = body["tap"] as? String, let pcm = body["pcm"] as? String,
                  let rate = body["rate"] as? Double else { return }
            let at = body["at"] as? Double ?? 0
            var level = body["level"] as? Double ?? 1
            #if DEBUG
            // Testing the switch on a page whose sound Web Audio can hear: as if it couldn't.
            if UserDefaults.standard.bool(forKey: "DebugAssumeSilentCapture") { level = 0 }
            #endif
            // Only from the half that's listening, in the tab it's listening to.
            guard var tap = taps[id], tap.shared == nil, !tap.switching, tap.webView === message.webView, tap.world == message.world else { return }
            // The extension stopped listening (its popup closed): the tap goes too, and the tab's sound comes back.
            guard isListening(tap) else { stop(id, because: "it stopped listening"); return }
            if level > 0.0001, !tap.heard { tap.heard = true; taps[id]?.heard = true }
            // A second of silence while the tab is playing sound: the page's sound is out of Web Audio's reach.
            if !tap.heard, Date().timeIntervalSince(tap.started) > 1.2, tab(tap.tabID)?.0.isPlayingAudio == true {
                fallBackToShared(id)
                return
            }
            keep([rate, pcm, at, false], for: id)
        }
    }

    /// The extension's popup closed (or opens again as a new page): its captures end with it, as in Chrome.
    func popupClosed(_ extensionID: String, page: String, opening: Int) {
        for (id, tap) in taps where tap.extensionID == extensionID && tap.page == page && tap.opening == opening {
            stop(id, because: "its popup closed")
        }
    }

    func release(_ extensionID: String) {
        for (id, tap) in taps where tap.extensionID == extensionID { stop(id, because: "the extension went away") }
        pending = pending.filter { $0.value.extensionID != extensionID }
    }
}

#if DEBUG
/// Silence at the real pace, on a queue of its own, as the system tap would send it, without macOS's capture
/// (DebugFakeSystemAudio): to test everything around a shared capture.
nonisolated private final class FakeSharedTap: SharedSoundCapture.Tap, @unchecked Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: .global())

    init(into chunks: SharedSoundChunks) {
        let silence = [Float](repeating: 0, count: 480)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { silence.withUnsafeBufferPointer { chunks.add($0, rate: 48000, capturedAt: SystemAudioTap.now() - 0.01) } }
        timer.resume()
    }

    func stop() { timer.cancel() }
}
#endif
