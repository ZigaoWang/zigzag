import AppKit
import WebKit
import os

/// Extension popups, one to a window.
enum ExtensionPopups {
    /// The popups that close as `opening` shows in `window`: every other one showing in that window, whichever
    /// extension it's from and whether it came from Site Controls, a pin or a shortcut. Other windows keep theirs.
    static func makingWay<Key: Hashable>(for opening: Key, in window: ObjectIdentifier?, among shown: [Key: ObjectIdentifier?]) -> [Key] {
        shown.compactMap { key, place in key != opening && place == window ? key : nil }
    }

    /// Inset from the window's edges for popups.
    static let windowMargin = Tokens.Space.x2

    /// X a popup `width` wide points at so it stays inside `room` minus `margin`: the anchor's middle if it fits, else
    /// shifted toward the page along `reach` (the anchor, or the address for a pinned button). Past `reach` it points just
    /// beyond its end; wider than the window, it's centered.
    static func pointingX(anchor: NSRect, reach: NSRect, width: CGFloat, room: NSRect, margin: CGFloat = windowMargin) -> CGFloat {
        let least = room.minX + margin + width / 2, most = room.maxX - margin - width / 2
        let wanted = least <= most ? min(max(anchor.midX, least), most) : room.midX
        // Keep the arrow off the rounded corners.
        let inset = min(reach.width / 2, Tokens.Space.x3)
        let along = min(max(wanted, reach.minX + inset), reach.maxX - inset)
        let fits = least > most || (along >= least - 0.5 && along <= most + 0.5)
        return fits ? along : wanted
    }

    /// Rect to show a popup `width` wide from: `rect` when it fits centered, else a sliver at `pointingX`, on `view` or past
    /// its end on the window's content (a popover's arrow must stay within its view). `reach` defaults to `rect`.
    @MainActor
    static func positioning(_ rect: NSRect, in view: NSView, reach: NSRect? = nil, width: CGFloat) -> (view: NSView, rect: NSRect) {
        guard width > 0, let content = view.window?.contentView else { return (view, rect) }
        let inWindow = view.convert(rect, to: nil), reachInWindow = view.convert(reach ?? rect, to: nil)
        let room = content.convert(content.bounds, to: nil)
        let x = pointingX(anchor: inWindow, reach: reachInWindow, width: width, room: room)
        guard abs(x - inWindow.midX) > 0.5 else { return (view, rect) }
        let sliver = NSRect(x: x - 0.5, y: inWindow.minY, width: 1, height: inWindow.height)
        let onView = view.convert(sliver, from: nil)
        if onView.minX >= view.bounds.minX, onView.maxX <= view.bounds.maxX {
            return (view, NSRect(x: onView.minX, y: rect.minY, width: onView.width, height: rect.height))
        }
        return (content, content.convert(sliver, from: nil))
    }
}

/// Extensions' items in a page's right-click menu. WebKit adds them to the page's menu by itself, for the extensions
/// that may act on the page, with what was clicked (a link, a selection, an image); Zigzag asks each extension for its
/// items too, for the others and to know whose item you chose. Each item goes in once: one WebKit put in is kept, and
/// the extension's own copy of it left out.
enum ExtensionMenuItems {
    struct Plan {
        /// Items to add, with whose they are.
        var added: [(id: String, item: NSMenuItem)] = []
        /// Items WebKit already put in the menu, with whose they are.
        var adopted: [(id: String, item: NSMenuItem)] = []
        /// Items WebKit put in that go: in a private tab, those of extensions not allowed there.
        var removed: [NSMenuItem] = []
    }

    /// Whether WebKit put this item in for an extension: the page's own items all carry WebKit's identifiers.
    static func isExtensionItem(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && !(item.identifier?.rawValue.hasPrefix("WKMenuItemIdentifier") ?? false)
    }

    /// The same item: the same title, with the same items under it.
    static func isSame(_ a: NSMenuItem, _ b: NSMenuItem) -> Bool {
        guard a.title == b.title, a.isSeparatorItem == b.isSeparatorItem else { return false }
        let left = a.submenu?.items ?? [], right = b.submenu?.items ?? []
        return left.count == right.count && zip(left, right).allSatisfy(isSame)
    }

    /// What to do with each extension's items, given what's in the menu already.
    static func plan(existing: [NSMenuItem], extensions: [(id: String, items: [NSMenuItem])], isPrivate: Bool) -> Plan {
        var plan = Plan()
        var candidates = existing.filter(isExtensionItem)
        for (id, items) in extensions {
            for item in items {
                if let index = candidates.firstIndex(where: { isSame($0, item) }) {
                    plan.adopted.append((id, candidates.remove(at: index)))
                } else if !plan.added.contains(where: { $0.id == id && isSame($0.item, item) }) {
                    plan.added.append((id, item))
                }
            }
        }
        // `extensions` are the ones allowed in a private tab; what's left is another's.
        if isPrivate { plan.removed = candidates }
        return plan
    }
}

/// Each extension's keep-awake port in a profile. A background that starts again opens a new one before WebKit
/// says the old one closed: that late word never drops the new one.
struct KeepAlivePorts<Port: AnyObject> {
    private var ports: [String: Port] = [:]
    mutating func opened(_ port: Port, for id: String) { ports[id] = port }
    mutating func closed(_ port: Port, for id: String) { if ports[id] === port { ports[id] = nil } }
    func port(for id: String) -> Port? { ports[id] }
}

/// Whether 1Password trusts Zigzag, from its helper's replies. Per app, not per profile.
/// `BrowserVerificationFailed` also comes while 1Password is slow to check the signature (launch, wake, locked), and a
/// single message can fail while another connection works. So it only counts when nothing trusted arrives for a few
/// seconds after; otherwise working setups kept showing the add-Zigzag note. Unknown reply types prove nothing.
struct OnePasswordTrust {
    enum Reply: Equatable {
        /// Turned away: Zigzag may not be in 1Password's list of browsers.
        case turnedAway
        /// Only a trusted browser gets these (lock state, new client, autofill).
        case connected
        /// Proves nothing: the app quit, went offline or couldn't be reached, or an unknown reply.
        case other
    }

    /// Reply types the helper sends only to trusted browsers, as observed.
    static let trustedTypes: Set<String> = ["Success", "ClientCreated", "LockStateChanged", "AutofillChangeEvent",
                                            "AutofillItemUpdated", "SecurityReviewEligibility"]
    /// Reply types sent whether trusted or not.
    static let neutralTypes: Set<String> = ["Offline", "AppQuit", "BrowserHelperNotRegistered", "MainAppNotRunning", "MainAppOpenTimeout",
                                            "CannotOpenMainApp", "LostConnectionToApp", "Error", "Failure"]

    /// How long a rejection waits for another connection to succeed before it's shown.
    static let grace: TimeInterval = 5

    /// The type in a helper reply's inner content.
    static func type(of message: Any) -> String? {
        let content = (message as? [String: Any])?["content"] as? [String: Any]
        return (content?["content"] as? [String: Any])?["type"] as? String
    }

    static func reply(_ type: String) -> Reply {
        if type == "BrowserVerificationFailed" { return .turnedAway }
        return trustedTypes.contains(type) ? .connected : .other
    }

    /// An unknown type, first seen this session; logged once.
    mutating func isNewUnknown(_ type: String) -> Bool {
        guard type != "BrowserVerificationFailed", !Self.trustedTypes.contains(type), !Self.neutralTypes.contains(type) else { return false }
        return unknownTypes.insert(String(type.prefix(64))).inserted
    }
    private var unknownTypes: Set<String> = []

    /// Something trusted arrived this session.
    private(set) var connected = false
    /// First rejection with nothing trusted since.
    private(set) var turnedAwayAt: Date?
    private var told = false

    mutating func heard(_ reply: Reply, at now: Date = Date()) {
        switch reply {
        case .connected:
            connected = true
            turnedAwayAt = nil
        case .turnedAway:
            // Once trusted this session, ignore rejections: working 1Password also rejects single messages while checking the
            // signature on wake or unlock, which caused false add-Zigzag notes. Removal shows after a relaunch.
            if !connected, turnedAwayAt == nil { turnedAwayAt = now }
        case .other:
            break
        }
    }

    /// Needs adding: rejected at least `grace` ago, nothing trusted since.
    func needsAdding(at now: Date = Date()) -> Bool {
        guard !connected, let turnedAwayAt else { return false }
        return now.timeIntervalSince(turnedAwayAt) >= Self.grace
    }

    /// Only the first time.
    mutating func tell(at now: Date = Date()) -> Bool {
        guard needsAdding(at: now), !told else { return false }
        told = true
        return true
    }
}

/// Runs browser extensions with WebKit's extension engine: Chrome Web Store extensions, and 1Password
/// set up for you, so they work the way they do in other browsers.
@available(macOS 15.4, *)
final class ExtensionHost: NSObject {
    /// Whose extensions these are.
    unowned let profile: Profile
    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    /// Fires when extensions load or their toolbar actions change.
    let changed = Signal<Void>()
    /// Answers the Chrome APIs WebKit doesn't have, for this profile's extensions.
    private(set) lazy var bridge = ExtensionBridge(host: self)
    /// Content scripts held back for reconnecting in a loop (ConnectGuard).
    private(set) lazy var storms = ExtensionStorms(host: self)
    /// The sandbox OldTwitter's request signing needs, outside its content scripts and the site's policy.
    private(set) lazy var oldTwitterSolver = OldTwitterSolver(host: self)
    /// Passes its two signals on to the ones views watch for any profile (ExtensionCenter).
    private var forwarding: [SignalToken] = []
    private var nativePorts: [ObjectIdentifier: NativeMessagingHost] = [:]
    /// The scripts every extension page of this profile gets, shared with the controller's pages.
    private(set) var pageScripts = WKUserContentController()
    /// The Firefox packages whose pages are marked as theirs.
    private var firefoxMarked: Set<String> = []
    /// When each extension last started helpers for a connection, to slow down one that keeps reconnecting.
    fileprivate var helperStarts: [String: [Date]] = [:]
    /// Where and when you last used each extension yourself, and last clicked or typed in a page: a note that its
    /// app is waiting on you shows only right after that, in that window.
    private var ownUses: [String: (window: WeakWindow, at: Date)] = [:]
    private var pageUse: (tab: WeakTab, at: Date)?
    /// The use each extension's app note last answered, so one use brings it up once.
    private var appNoticeUse: [String: Date] = [:]
    private struct WeakWindow { weak var value: BrowserWindowController? }
    private struct WeakTab { weak var value: Tab? }
    private var socketBridges: [ObjectIdentifier: WebSocketBridge] = [:]
    /// Each background's port for staying awake while its companion app is connected (ExtensionShims.nativeKeepAlive).
    private var keepAlivePorts = KeepAlivePorts<WKWebExtension.MessagePort>()

    init(profile: Profile) {
        self.profile = profile
        // Under the profile's own identifier: what its extensions store (chrome.storage, their rules) is kept apart
        // from any other profile's copy of the same extension.
        let configuration = WKWebExtensionController.Configuration(identifier: profile.id)
        // Both, and the same store: the first is what extensions' cookie calls read, the second is where their own
        // pages and background keep localStorage and IndexedDB. Two controllers never share a store, since WebKit
        // clears a store of extension data its controller doesn't know.
        configuration.defaultWebsiteDataStore = profile.store
        configuration.webViewConfiguration.websiteDataStore = profile.store
        // What extensions' requests tell servers is what Zigzag is, as its network traffic shows: a server that checks
        // (shazam.com's) turns away one that claims Chrome but doesn't look it. Their own code still reads Chrome
        // (bridge.js), since several choose their code path from navigator.userAgent.
        configuration.webViewConfiguration.applicationNameForUserAgent = WebKitSetup.applicationNameForUserAgent
        // Profiles' page preludes reach every extension page through the shared configuration; each runs only on
        // its own extension's pages, before their scripts.
        // Set before the compatibility layer, which reads it to add Firefox's runtime members.
        let firefoxIDs = ExtensionShims.firefoxIDs.filter(ExtensionStore.isExtensionID)
        for id in firefoxIDs {
            configuration.webViewConfiguration.userContentController.addUserScript(Self.firefoxMarker(id))
        }
        pageScripts = configuration.webViewConfiguration.userContentController
        firefoxMarked = Set(firefoxIDs)
        // The compatibility layer on every extension page too (popups, options), before their own scripts.
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(source: "if (location.protocol === 'webkit-extension:') {\n\(ExtensionBridgeScript.source)\n\(ExtensionShims.compatibility)\n\(ExtensionBridgeScript.afterCompatibility)\n}",
                         injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Chrome gives extension pages its system font (and a smaller base size) unless they set their own; many
        // popups rely on it and would otherwise fall to WebKit's default serif. Zero specificity, first in the
        // document, so any style of the extension's own wins.
        let fonts = """
            if (location.protocol === 'webkit-extension:') {
              const style = document.createElement('style');
              style.textContent = ':where(body) { font-family: system-ui, sans-serif; font-size: 75%; }';
              document.documentElement.prepend(style);
            }
            """
        configuration.webViewConfiguration.userContentController.addUserScript(
            WKUserScript(source: fonts, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for (id, source) in ExtensionShims.pagePreludes {
            let guarded = "if (location.host === '\(id)') {\n\(source)\n}"
            configuration.webViewConfiguration.userContentController.addUserScript(
                WKUserScript(source: guarded, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        forwarding = [changed.observe { ExtensionCenter.noteChanged() }, popupsChanged.observe { ExtensionCenter.popupsChanged.send() }]
        watchGestures()
        watchPopupVisibility()
        watchRemovedGrants()
    }

    // MARK: Loading

    /// Brings up a profile's extensions the first time something in it needs them, as the first profile's are at
    /// launch: a proxy one of them set applies from the first page, then each that's on is loaded.
    func start() {
        bridge.proxy.restore()
        Task {
            // An extension that went while this profile wasn't in use takes its pin with it.
            profile.installs.pins = profile.installs.pins.keeping(profile.installs.hasRecord)
            await loadInstalled()
        }
    }

    /// Every installed extension, on or off, for Settings. Filled in as they are read at launch.
    private(set) var installed: [String: WKWebExtension] = [:]

    /// Loads every installed extension that's turned on, and reads the rest for Settings. Safe to call again:
    /// what's already loaded stays as it is.
    func loadInstalled() async {
        for id in profile.installs.installedIDs {
            if profile.installs.isEnabled(id) {
                await load(id)
            } else if installed[id] == nil, let dir = ExtensionStore.packageDirectory(for: id),
                      let ext = try? await WKWebExtension(resourceBaseURL: dir) {
                installed[id] = ext
                changed.send()
            }
        }
        finishedLoading = true
    }

    /// Everything installed has been loaded since launch: from here on a pin appearing is something happening.
    private(set) var finishedLoading = false

    func context(for id: String) -> WKWebExtensionContext? { contexts.first { $0.uniqueIdentifier == id } }

    /// Marks a Firefox package's pages, once, for firefox-polyfill.js: before it at setup, after it for one installed
    /// later, which its setter still takes.
    func addFirefoxMarker(_ id: String) {
        guard ExtensionStore.isExtensionID(id), firefoxMarked.insert(id).inserted else { return }
        pageScripts.addUserScript(Self.firefoxMarker(id))
    }

    private static func firefoxMarker(_ id: String) -> WKUserScript {
        WKUserScript(source: "if (location.host === '\(id)') { globalThis.__zigzagFirefoxPackage = true; }",
                     injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// OldTwitter's challenge call, in this web view's extension world, when the extension is on. A private page gets
    /// it only when OldTwitter may run there.
    func attachOldTwitterSolver(to configuration: WKWebViewConfiguration, isPrivate: Bool) {
        guard let id = profile.installs.installedIDs.first(where: {
                  OldTwitterSolver.isOldTwitter(id: $0, manifest: ExtensionStore.manifest(for: $0) ?? [:])
              }),
              profile.installs.state(id)?.enabled == true else { return }
        oldTwitterSolver.attach(to: configuration, extensionID: id, isPrivate: isPrivate)
    }

    /// The extension, loaded in this profile, that the page at this address is one of.
    func context(forPage url: URL?) -> WKWebExtensionContext? {
        guard let url, url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)
    }

    /// Stops an extension: its buttons, scripts and background page go away.
    /// Whether an extension's popup is showing now (some APIs act while it's open, as in Chrome).
    func isPopupShown(for id: String) -> Bool {
        openPopups.values.contains { $0.extensionID == id && $0.popover.isShown }
    }

    #if DEBUG
    var debugShownPopovers: [NSPopover] { openPopups.values.map(\.popover).filter(\.isShown) }
    #endif

    /// The page of the popup an extension is showing, if it is.
    func shownPopupPage(for id: String) -> String? {
        openPopups.values.first { $0.extensionID == id && $0.popover.isShown }?.page
    }

    /// Live popup URL (with query) while shown; also its `runtime.getContexts` identity. `shownPopupPage` is the path only,
    /// for tab capture.
    func shownPopup(for id: String) -> WKWebView? {
        openPopups.values.first { $0.extensionID == id && $0.popover.isShown }?.webView
    }

    /// Whether you can see an extension's popup in this window: its pinned button there shows as active.
    func isPopupOnScreen(_ id: String, in window: NSWindow?) -> Bool {
        openPopups.values.contains { $0.extensionID == id && $0.window === window && $0.isOnScreen }
    }

    /// Closes the extension popups showing in a window, when another of Zigzag's panels opens in their place or a
    /// pinned button is picked up.
    func closePopups(in window: NSWindow?) {
        close(openPopups.values.filter { $0.window === window })
    }

    private func closePopups(for id: String) {
        close(openPopups.values.filter { $0.extensionID == id })
    }

    private func closeOtherPopups(than popover: NSPopover, in window: NSWindow?) {
        let shown = openPopups.filter { $0.value.popover.isShown }.mapValues { $0.window.map(ObjectIdentifier.init) }
        let away = ExtensionPopups.makingWay(for: ObjectIdentifier(popover), in: window.map(ObjectIdentifier.init), among: shown)
        close(away.compactMap { openPopups[$0] })
    }

    private func close(_ popups: [OpenPopup]) {
        for popup in popups where popup.popover.isShown {
            if let action = popup.action { action.closePopup() } else { popup.popover.close() }
        }
    }

    /// A popup you can see keeps the slid-out sidebar it opened from out until it closes.
    func holdsSidebar(in window: NSWindow?) -> Bool {
        openPopups.values.contains { $0.window === window && $0.isOnScreen }
    }

    /// Whether an extension's popup in this window closed since this press began: pressing elsewhere in a window
    /// closes a popup before the click lands, and that click shouldn't open it again. Asking the clock of the event
    /// itself, it holds whichever order the close and the press arrive in.
    func popupClosed(_ id: String, in window: NSWindow?, since press: NSEvent) -> Bool {
        (popupClosedAt[PopupPlace(id, window)] ?? -1) >= press.timestamp
    }

    /// Popups opened from pinned buttons follow them when the field changes.
    func repositionPinPopups(of controller: BrowserWindowController) {
        for popup in openPopups.values where popup.fromPin && popup.window === controller.window && popup.popover.isShown {
            let anchor = controller.popupAnchor(forPin: popup.extensionID)
            // Track the button so later popup resizes stay anchored to it.
            let key = ObjectIdentifier(popup.popover)
            if anchor.view === controller.sidebar.address, popupPlaces[key]?.view === anchor.view {
                popupPlaces[key]?.rect = anchor.rect
                keepInWindow(popup.popover)
            }
        }
    }

    /// When each extension's button was last clicked.
    private var actionClicks: [String: Date] = [:]
    func lastActionClick(_ id: String) -> Date { actionClicks[id] ?? .distantPast }

    /// Last tabs.update per extension. Downie's button sends the tab to its app link, so the tab count doesn't change.
    private var tabLoads: [String: Date] = [:]
    func noteTabLoad(_ id: String) { tabLoads[id] = Date() }

    /// Whether an action click did nothing (no popup, side panel, new tab or tabs.update), so the options page opens.
    static func clickShowedNothing(clickedAt: Date, popupShown: Bool, sidePanelShown: Bool, tabsBefore: Int, tabsNow: Int, tabLoadedAt: Date?) -> Bool {
        if popupShown || sidePanelShown || tabsNow != tabsBefore { return false }
        if let tabLoadedAt, tabLoadedAt >= clickedAt { return false }
        return true
    }

    /// What you last did with each extension: the tab you used it on, and when you last touched its own pages. Some
    /// APIs act only in answer to that (tab capture, opening a download, asking for more access), as in Chrome.
    private(set) var use = ExtensionUse()
    private var gestureMonitor: Any?
    private var menuObserver: NSObjectProtocol?
    /// The extension and tab behind each extension item in a page's right-click menu, to note the one you choose.
    private let menuOwners = NSMapTable<NSMenuItem, MenuOwner>.weakToStrongObjects()
    private final class MenuOwner {
        let id: String
        weak var tab: Tab?
        init(id: String, tab: Tab) { self.id = id; self.tab = tab }
    }

    /// You used the extension on a tab: by its button, its item in the page's menu or its shortcut.
    func noteInvocation(_ id: String, tab: Tab?) {
        noteOwnUse(id, in: tab.flatMap { WindowManager.shared.window(of: $0) })
        guard let tab, PrivateAccess.sees(isPrivate: tab.isPrivate, allowed: seesPrivate(id)) else { use.touched(id); return }
        use.invoked(id, tabID: tab.id, origin: SiteOrigin.of(tab.webView?.url ?? tab.url))
    }

    /// Whether you did something with the extension a moment ago: clicked it, or clicked or typed in one of its pages.
    func hasRecentGesture(_ id: String) -> Bool { use.hasGesture(id) }

    private func noteOwnUse(_ id: String, in window: BrowserWindowController?) {
        ownUses[id] = (WeakWindow(value: window ?? WindowManager.shared.keyController), Date())
    }

    /// The window to point at `id`'s app in while a connection that began at `since` waits: only when you used the
    /// extension, or a sign-in field in a page, around then (`CompanionAppNotice`). Answers at most once per use.
    fileprivate func windowForAppNotice(_ id: String, waitingSince since: Date, found: @escaping (BrowserWindowController) -> Void) {
        let now = Date()
        if let mark = ownUses[id], let window = mark.window.value, appNoticeUse[id] != mark.at,
           CompanionAppNotice.follows(use: mark.at, waitingSince: since, now: now) {
            appNoticeUse[id] = mark.at
            found(window)
            return
        }
        // A page click or key counts when it left a sign-in field focused, or 1Password's menu in the page (#387).
        guard let page = pageUse, let tab = page.tab.value, let webView = tab.webView, appNoticeUse[id] != page.at,
              CompanionAppNotice.follows(use: page.at, waitingSince: since, now: now) else { return }
        appNoticeUse[id] = page.at
        webView.evaluateJavaScript(CompanionAppNotice.fieldFocusedScript, in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, value as? Bool == true,
                  let window = WindowManager.shared.window(of: tab) else { return }
            found(window)
        }
    }

    /// A click or key in one of an extension's own pages (its popup, its window, its side panel, its options) is
    /// you using it. A page's script can't make these.
    /// A popup hidden or back in sight neither opens nor closes, but its button should show it.
    private func watchPopupVisibility() {
        popupOcclusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.openPopups.values.contains(where: { $0.popover.contentViewController?.view.window === window }) else { return }
                self.popupsChanged.send()
            }
        }
    }

    private func watchGestures() {
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // Ignore key repeats.
            if let self, ExtensionUse.isGesture(event.type, isRepeat: event.type == .keyDown && event.isARepeat) {
                if let id = self.extensionPage(under: event) {
                    self.use.touched(id)
                    let window = WindowManager.shared.controller(for: event.window) ?? WindowManager.shared.controller(for: event.window?.parent)
                    self.noteOwnUse(id, in: window)
                } else if let tab = self.webPage(under: event) {
                    self.use.pageGesture(on: tab.webView?.url?.host() ?? tab.url?.host())
                    self.pageUse = (WeakTab(value: tab), Date())
                }
            }
            return event
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: .main) { [weak self] note in
            // Menus send their actions on the main thread, where this runs.
            nonisolated(unsafe) let chosen = note.userInfo?["MenuItem"] as? NSMenuItem
            MainActor.assumeIsolated {
                guard let item = chosen else { return }
                guard let self, let owner = self.menuOwners.object(forKey: item) else { return }
                self.noteInvocation(owner.id, tab: owner.tab)
            }
        }
    }

    private func webView(under event: NSEvent) -> WKWebView? {
        guard let window = event.window else { return nil }
        var view: NSView? = event.type == .keyDown ? window.firstResponder as? NSView : window.contentView?.hitTest(event.locationInWindow)
        while let current = view, !(current is WKWebView) { view = current.superview }
        return view as? WKWebView
    }

    /// The page in this profile's tabs that got the click or key. A private tab only while an extension here runs there.
    private func webPage(under event: NSEvent) -> Tab? {
        guard let page = webView(under: event) as? BrowserWebView, let tab = page.owner else { return nil }
        if tab.isPrivate { return runsInPrivate && tab.profile === profile ? tab : nil }
        return page.configuration.websiteDataStore === profile.store ? tab : nil
    }

    /// A page click or key counts for an extension once its content script reported it (`ExtensionUse.carriesPageGesture`).
    func hasCarriedPageGesture(_ id: String, contentMessage: (hosts: [String], age: TimeInterval)?) -> Bool {
        guard let contentMessage else { return false }
        let now = Date()
        return use.carriesPageGesture(messageHosts: contentMessage.hosts, messageAt: now.addingTimeInterval(-contentMessage.age), now: now)
    }

    private func extensionPage(under event: NSEvent) -> String? {
        let view = webView(under: event)
        // The same extension can be open in another profile at the same address: only this profile's page counts here.
        guard let page = view, page.configuration.websiteDataStore === profile.store,
              let url = page.url, url.scheme == "webkit-extension", let id = url.host(), context(for: id) != nil else { return nil }
        return id
    }

    /// The page an extension puts in place of a new tab (`chrome_url_overrides.newtab`), as in Chrome: the most
    /// recently loaded one that asks, while it's on. Nil keeps Zigzag's own command bar.
    func newTabOverride() -> URL? {
        for context in contexts.reversed() {
            guard let overrides = ExtensionStore.manifest(for: context.uniqueIdentifier)?["chrome_url_overrides"] as? [String: Any],
                  let path = overrides["newtab"] as? String,
                  let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL, url.host() == context.baseURL.host() else { continue }
            return url
        }
        return nil
    }

    /// The extension's name, for saying who's asking (a keep-awake, a notification).
    func displayName(for id: String) -> String {
        context(for: id)?.webExtension.displayName ?? installed[id]?.displayName ?? String(localized: "an extension", comment: "Stands in for an extension's name when it has none, inside a sentence like “an extension is listening to this tab”.")
    }

    func unload(_ id: String) {
        guard let context = context(for: id) else { return }
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        // Its companion-app helpers end with it, whether or not WebKit closed their ports.
        NativeMessagingHost.terminateAll(for: id, of: self)
        bridge.release(id)
        if oldTwitterSolver.extensionID == id { oldTwitterSolver.release() }
        use.forget(id)
        Passkeys.refresh()
        changed.send()
    }

    /// Stops every extension and deletes what each stored here, when the profile is removed.
    func shutDown() async {
        for context in contexts { unload(context.uniqueIdentifier) }
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types)
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
        controller.delegate = nil
        // What it watched app-wide goes with it.
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
        for observer in [menuObserver, popupOcclusionObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        gestureMonitor = nil
        menuObserver = nil
        popupOcclusionObserver = nil
    }

    /// Deletes what an extension stored (its storage, registered scripts, rule cache), for removal.
    func removeData(for id: String) {
        controller.fetchDataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes) { [weak self] records in
            let mine = records.filter { $0.uniqueIdentifier == id }
            guard !mine.isEmpty else { return }
            self?.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: mine) {}
        }
    }

    /// Drops a removed extension from the list.
    func forget(_ id: String) {
        unload(id)
        installed[id] = nil
        changed.send()
    }

    @discardableResult
    func load(_ id: String) async -> WKWebExtensionContext? {
        if let existing = context(for: id) { return existing }
        guard profile.installs.isEnabled(id), let directory = await profile.installs.loadDirectory(for: id) else { return nil }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: directory)
            // Asked for twice at once (the profile's extensions starting as one is added): the first to finish stands.
            if let existing = context(for: id) { return existing }
            // Turned off while it was being read.
            guard profile.installs.isEnabled(id) else { return nil }
            installed[id] = ext
            let context = WKWebExtensionContext(for: ext)
            // The store ID, so runtime.id matches Chrome's and storage persists across launches.
            context.uniqueIdentifier = id
            // A fixed address, so its pages (settings, dashboards) still open after a relaunch.
            if let base = URL(string: "webkit-extension://\(id)/") { context.baseURL = base }
            context.unsupportedAPIs = ExtensionShims.shim(for: id)?.unsupportedAPIs ?? []
            #if DEBUG
            context.isInspectable = true
            #endif
            restoreGrants(for: context, extension: ext)
            context.hasAccessToPrivateData = profile.installs.allowsPrivate(id)
            try controller.load(context)
            contexts.append(context)
            // OldTwitter's request signing: pages made before it was installed or started again get its call too.
            if OldTwitterSolver.isOldTwitter(id: id, manifest: ExtensionStore.manifest(for: id) ?? [:]) {
                oldTwitterSolver.attach(toOpenPagesOf: id)
            }
            // Installed since the profile's pages were set up: its pages are marked from their next load.
            if ExtensionStore.kind(of: id) == .firefox { addFirefoxMarker(id) }
            // Its user scripts, in every web view, from their next page.
            bridge.userScripts.refresh()
            announceExistingWindows(to: context)
            Passkeys.refresh()
            changed.send()
            // A background that won't start leaves its popup waiting with nothing in the log; it says why here. One
            // with no background isn't asked: WebKit answers that twice, which brought Zigzag down.
            if ext.hasBackgroundContent {
                Task { [weak self] in
                    do { try await context.loadBackgroundContent() } catch {
                        ExtensionLog.write("background for \(self?.displayName(for: id) ?? id) didn't start: \(error.localizedDescription)")
                    }
                }
            }
            return context
        } catch {
            debugLog("Extension \(id) failed to load: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Permissions

    /// Grants what the person approved. Until the install sheet exists, installing approves what the
    /// extension asks for; that approval is recorded once and restored from then on.
    ///
    /// The permissions Zigzag's bridge answers (history, a proxy, user scripts) aren't WebKit's, so WebKit leaves them
    /// out of what an extension requests; they're granted alongside, from the package's own manifest, and recorded with
    /// the rest. From then on only what was recorded is granted. A manifest that later asks for more (an extension read
    /// from a folder, inside an app or from Install from Folder, can change its files at any time) gets nothing more
    /// until the person allows it, in the same sheet an update that wants more access shows (`askForNewAccess`).
    private func restoreGrants(for context: WKWebExtensionContext, extension ext: WKWebExtension) {
        let id = context.uniqueIdentifier
        let declared = ExtensionStore.declaredPermissions(id).required
        var state = profile.installs.state(id)
        // A record from before the bridge's permissions were kept in it: what it was always given, taken once.
        if var known = state, let granted = known.grantedPermissions, known.bridgeRecorded != true {
            known.grantedPermissions = Self.migratedGrants(Set(granted), declared: declared, fromFolder: ExtensionStore.isUnpacked(id)).sorted()
            known.bridgeRecorded = true
            profile.installs.save(known, for: id)
            state = known
        }
        // Old records got webRequestBlocking with webRequest without recording it; add it once instead of asking again.
        if var known = state, let granted = known.grantedPermissions,
           let carried = Self.carryingBlocking(granted, declared: declared) {
            known.grantedPermissions = carried
            profile.installs.save(known, for: id)
            state = known
        }
        let asked = Self.askedPermissions(requested: Set(ext.requestedPermissions.map(\.rawValue)), declared: declared)
        let permissions = Set(state?.grantedPermissions ?? Array(asked)).map(WKWebExtension.Permission.init(rawValue:))
        let patterns = state?.grantedMatchPatterns.map { Set($0.compactMap { try? WKWebExtension.MatchPattern(string: $0) }) } ?? ext.allRequestedMatchPatterns
        for permission in permissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        // For Zigzag's own bridge; ExtensionHost keeps real native hosts to extensions that asked for them.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        // userScripts.execute goes through WebKit's scripting API (BridgeUserScripts), so being allowed user scripts brings it.
        if permissions.contains(WKWebExtension.Permission(rawValue: BridgeUserScripts.permission)) {
            context.setPermissionStatus(.grantedExplicitly, for: .scripting)
        }
        for pattern in patterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        if state?.grantedPermissions == nil { saveGrants(of: context, approving: asked) }
        applySiteAccess(to: context)
        let wanted = asked.subtracting(profile.installs.state(id)?.grantedPermissions ?? [])
        if !wanted.isEmpty { askForNewAccess(wanted, for: context) }
    }

    /// Adds webRequestBlocking to a record with webRequest when the manifest asks for it; nil when unchanged.
    static func carryingBlocking(_ granted: [String], declared: Set<String>) -> [String]? {
        guard declared.contains("webRequestBlocking"), granted.contains("webRequest"), !granted.contains("webRequestBlocking") else { return nil }
        return (granted + ["webRequestBlocking"]).sorted()
    }

    /// The permissions Zigzag grants every extension for its own needs (its bridge's native messaging; scripting for
    /// user scripts). Granted, they say nothing of what the person approved, so a record holds them only as approved.
    static let zigzagGranted: Set<String> = [WKWebExtension.Permission.nativeMessaging.rawValue, WKWebExtension.Permission.scripting.rawValue]

    /// What an extension asks the person for: what WebKit reads in its loaded copy (which also asks for Zigzag's own
    /// two), with those two only as its package's own manifest asks, and the permissions the bridge answers, which
    /// WebKit leaves out.
    static func askedPermissions(requested: Set<String>, declared: Set<String>) -> Set<String> {
        requested.subtracting(zigzagGranted)
            .union(declared.intersection(zigzagGranted))
            .union(declared.intersection(ExtensionBridgeScript.granted))
    }

    /// A record from before the bridge's permissions were kept: those its manifest asks for are added, as they were
    /// always given, and Zigzag's own two, recorded then whatever was asked, stay only as the manifest asks.
    /// `declared` is the approved manifest (a store package's copy in Zigzag's folder). A folder extension's may have
    /// changed (`fromFolder`): nothing is added, extra permissions are asked about, and Zigzag's own two stay while the
    /// manifest still asks for them.
    static func migratedGrants(_ granted: Set<String>, declared: Set<String>, fromFolder: Bool = false) -> Set<String> {
        let kept = granted.subtracting(zigzagGranted)
        if fromFolder { return kept.union(granted.intersection(zigzagGranted).intersection(declared)) }
        return kept
            .union(declared.intersection(zigzagGranted))
            .union(declared.intersection(ExtensionBridgeScript.granted))
    }

    /// Asked once per load, when a window is there to ask in. Not allowed, the extension runs without it, and is asked
    /// again the next time it loads.
    private func askForNewAccess(_ wanted: Set<String>, for context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        ExtensionLog.write("\(context.webExtension.displayName ?? id) now asks for \(wanted.sorted()); held until allowed")
        Task { @MainActor [weak self, weak context] in
            for _ in 0..<120 {
                guard let self, let context, self.context(for: id) === context else { return }
                if !ExtensionSheet.isShowing,
                   let window = WindowManager.shared.keyController.flatMap({ $0.tabManager.isPrivate ? nil : $0 }) ?? self.openWindows.first {
                    self.presentNewAccess(wanted, for: context, in: window)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func presentNewAccess(_ wanted: Set<String>, for context: WKWebExtensionContext, in window: BrowserWindowController) {
        let ext = context.webExtension
        let content = ExtensionSheet.Content(
            icon: ext.icon(for: NSSize(width: 40, height: 40)),
            title: ext.displayName.map { String(localized: "\($0) wants more access", comment: "Title of the sheet shown when an extension asks for more access. The name is the extension's.") }
                ?? String(localized: "This extension wants more access", comment: "Title of the sheet shown when an extension with no name asks for more access."),
            subtitle: String(localized: "Its files changed and now ask for more. Until you allow it, it runs without it.", comment: "Under the title of the sheet shown when an extension read from a folder (one that comes inside an app, or added from a folder) changed its files to ask for more access."),
            heading: String(localized: "It would also be able to", comment: "Heading over the list of what an extension could also do, in the sheet shown when it asks for more access."),
            report: ExtensionReport(requesting: wanted, id: context.uniqueIdentifier),
            confirm: String(localized: "Allow", comment: "Button in the sheet shown when an extension asks for more access: gives it."),
            cancel: String(localized: "Not Now", comment: "Button that leaves an extension's update waiting."))
        ExtensionSheet.present(content, in: window, onConfirm: { [weak self, weak context] in
            guard let self, let context, self.context(for: context.uniqueIdentifier) === context else { return }
            for permission in wanted { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission)) }
            if wanted.contains(BridgeUserScripts.permission) { context.setPermissionStatus(.grantedExplicitly, for: .scripting) }
            self.saveGrants(of: context, approving: wanted)
        })
    }

    // MARK: Private windows

    /// Allowed into private windows or kept out: it starts again, as in Chrome, so it holds nothing from before.
    func applyPrivateAccess(_ id: String) {
        guard context(for: id) != nil else { changed.send(); return }
        unload(id)
        Task { await load(id) }
    }

    /// Whether an extension here is allowed in private windows: only then are they told to WebKit at all.
    var runsInPrivate: Bool { contexts.contains { $0.hasAccessToPrivateData } }

    /// Whether this extension may see private windows' tabs, downloads and pages.
    func seesPrivate(_ id: String) -> Bool { context(for: id)?.hasAccessToPrivateData ?? false }

    // MARK: Site access

    func applySiteAccess(_ id: String) {
        guard let context = context(for: id) else { return }
        let before = Self.access(of: context)
        applySiteAccess(to: context)
        // WebKit keeps the content scripts and background's cross-site access it had: with less access it starts again.
        if Self.narrowed(from: before, to: Self.access(of: context)) {
            ExtensionLog.write("\(displayName(for: id)) has less site access; starting it again")
            unload(id)
            Task { await load(id) }
            return
        }
        bridge.userScripts.refresh()
        changed.send()
    }

    /// `permissions.remove` takes back what was allowed when it asked: forgotten in the record too, so it stays gone.
    private func watchRemovedGrants() {
        let names = [WKWebExtensionContext.grantedPermissionsWereRemovedNotification, WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification]
        removedGrantObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated {
                    let context = note.object as? WKWebExtensionContext
                    let permissions = (note.userInfo?[WKWebExtensionContext.NotificationUserInfoKey.permissions] as? Set<WKWebExtension.Permission>)?.map(\.rawValue) ?? []
                    let patterns = (note.userInfo?[WKWebExtensionContext.NotificationUserInfoKey.matchPatterns] as? Set<WKWebExtension.MatchPattern>)?.map(\.string) ?? []
                    // After Zigzag's own changes, which clear site grants and make them again.
                    DispatchQueue.main.async { [weak self, weak context] in
                        self?.forgetRemoved(permissions: Set(permissions), patterns: Set(patterns), of: context)
                    }
                }
            }
        }
    }

    private func forgetRemoved(permissions: Set<String>, patterns: Set<String>, of context: WKWebExtensionContext?) {
        guard let context, self.context(for: context.uniqueIdentifier) === context, let state = profile.installs.state(context.uniqueIdentifier) else { return }
        let forgotten = Self.removedGrants(permissions: permissions, patterns: patterns, recorded: state,
                                           granted: (Set(context.grantedPermissions.keys.map(\.rawValue)), Set(context.grantedPermissionMatchPatterns.keys.map(\.string))))
        guard !forgotten.permissions.isEmpty || !forgotten.patterns.isEmpty else { return }
        profile.installs.update(context.uniqueIdentifier) {
            $0.grantedPermissions = $0.grantedPermissions?.filter { !forgotten.permissions.contains($0) }
            $0.grantedMatchPatterns = $0.grantedMatchPatterns?.filter { !forgotten.patterns.contains($0) }
            let requested = ($0.requestedMatchPatterns ?? []).filter { !forgotten.patterns.contains($0) }
            $0.requestedMatchPatterns = requested.isEmpty ? nil : requested
        }
    }

    /// What a removal takes from the record: permissions you're asked about, and sites allowed when it asked, that
    /// are still not granted. Zigzag's own changes take nothing else (activeTab, site access).
    static func removedGrants(permissions: Set<String>, patterns: Set<String>, recorded: ExtensionInstalls.State,
                              granted: (permissions: Set<String>, patterns: Set<String>)) -> (permissions: Set<String>, patterns: Set<String>) {
        let asked = permissions.intersection(ExtensionReport.askedPermissions).intersection(recorded.grantedPermissions ?? []).subtracting(granted.permissions)
        let sites = patterns.intersection(recorded.requestedMatchPatterns ?? []).subtracting(granted.patterns)
        return (asked, sites)
    }

    typealias SiteGrants = (granted: Set<String>, denied: Set<String>)

    static func access(of context: WKWebExtensionContext) -> SiteGrants {
        (Set(context.grantedPermissionMatchPatterns.keys.map(\.string)), Set(context.deniedPermissionMatchPatterns.keys.map(\.string)))
    }

    /// Whether a site granted before isn't now. A newly denied site needs no restart: WebKit stops injecting there.
    static func narrowed(from before: SiteGrants, to after: SiteGrants) -> Bool {
        !before.granted.isSubset(of: after.granted)
    }

    /// Turns the approved site patterns into what the person chose: every approved site, no site until a click gives
    /// it the tab it's on, or only sites they listed. Sites where extensions are off are denied to all.
    private func applySiteAccess(to context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let state = profile.installs.state(id)
        let approved = (state?.grantedMatchPatterns ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        let requested = (state?.requestedMatchPatterns ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        Self.applySiteAccess(state?.siteAccess, approved: approved, sites: profile.installs.accessSites(id), requested: requested,
                             offSites: ExtensionStore.extensionsOffSites(in: profile).union(profile.installs.offSites(id)),
                             approvesActiveTab: state?.grantedPermissions?.contains(WKWebExtension.Permission.activeTab.rawValue) ?? false,
                             to: context)
    }

    static func applySiteAccess(_ access: ExtensionInstalls.SiteAccess?, approved: [WKWebExtension.MatchPattern], sites: [String],
                                requested: [WKWebExtension.MatchPattern] = [], offSites: Set<String>, approvesActiveTab: Bool,
                                to context: WKWebExtensionContext) {
        // Forget earlier decisions first (clearing one pattern can clear an overlapping one), then make the current ones.
        for pattern in context.grantedPermissionMatchPatterns.keys { context.setPermissionStatus(.unknown, for: pattern) }
        for pattern in context.deniedPermissionMatchPatterns.keys { context.setPermissionStatus(.unknown, for: pattern) }
        for pattern in siteAccessPatterns(access, approved: approved, optional: context.webExtension.optionalPermissionMatchPatterns, sites: sites) + requested {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for site in offSites {
            for pattern in patterns(for: site) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
        // On Click: a click gives the tab's site through activeTab, which WebKit drops when the tab leaves it.
        if access == .click {
            context.setPermissionStatus(.grantedExplicitly, for: .activeTab)
        } else if !approvesActiveTab {
            context.setPermissionStatus(.unknown, for: .activeTab)
        }
    }

    /// The sites a site access choice grants (nil: never chosen). Chosen, "On All Sites" adds the optional host permissions too.
    /// "On Click" grants none: a click gives only the tab it's on.
    static func siteAccessPatterns(_ access: ExtensionInstalls.SiteAccess?, approved: [WKWebExtension.MatchPattern],
                                   optional: Set<WKWebExtension.MatchPattern>, sites: [String]) -> [WKWebExtension.MatchPattern] {
        switch access {
        case nil: approved
        case .all: approved + optional.filter { !approved.contains($0) }
        case .click: []
        case .sites: sites.flatMap(patterns(for:))
        }
    }

    /// Whether a click (or the extension's shortcut or menu item) gives it the tab's site, as Chrome's activeTab does.
    /// Under "On Click", Zigzag allows activeTab itself, so one that never asked for it gets only sites it asked for.
    func grantsTabOnGesture(_ context: WKWebExtensionContext, url: URL?) -> Bool {
        let id = context.uniqueIdentifier
        guard profile.installs.siteAccess(id) == .click,
              profile.installs.state(id)?.grantedPermissions?.contains(WKWebExtension.Permission.activeTab.rawValue) != true else { return true }
        return Self.asksFor(url, in: context.webExtension)
    }

    /// Whether a site is one the extension asked for: its host permissions, optional ones, or content scripts' matches.
    static func asksFor(_ url: URL?, in ext: WKWebExtension) -> Bool {
        guard let url else { return false }
        return ext.allRequestedMatchPatterns.union(ext.optionalPermissionMatchPatterns).contains { $0.matches(url) }
    }

    /// Asks for sites only as optional and has none yet, so "On All Sites" isn't its state until chosen.
    func asksForSitesOnlyOptionally(_ id: String) -> Bool {
        guard let context = context(for: id), profile.installs.state(id)?.siteAccess == nil else { return false }
        return (profile.installs.state(id)?.grantedMatchPatterns ?? []).isEmpty && !context.webExtension.optionalPermissionMatchPatterns.isEmpty
    }

    /// A site and its subdomains, over http and https, with a trailing dot too (bank.com. is bank.com).
    static func patterns(for site: String) -> [WKWebExtension.MatchPattern] {
        ["*://\(site)/*", "*://*.\(site)/*", "*://\(site)./*", "*://*.\(site)./*"].compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    /// Records what the extension is granted. WebKit keeps the bridge's permissions among the granted ones, so they're
    /// recorded with the rest; Zigzag's own two only as the person approved them (`approving`, or an earlier record).
    fileprivate func saveGrants(of context: WKWebExtensionContext, approving: Set<String> = []) {
        defer { bridge.userScripts.refresh() }
        let before = Set(profile.installs.state(context.uniqueIdentifier)?.grantedPermissions ?? [])
        var granted = Set(context.grantedPermissions.keys.map(\.rawValue))
        // The activeTab "On Click" lends isn't an approval.
        if profile.installs.siteAccess(context.uniqueIdentifier) == .click, !before.union(approving).contains(WKWebExtension.Permission.activeTab.rawValue) {
            granted.remove(WKWebExtension.Permission.activeTab.rawValue)
        }
        let permissions = Self.recordedGrants(granted, before: before, approving: approving).sorted()
        // Per-site grants come from site access, not approval; only an "all sites" extension's grants are its approvals.
        guard profile.installs.siteAccess(context.uniqueIdentifier) == .all || profile.installs.state(context.uniqueIdentifier)?.grantedMatchPatterns == nil else {
            profile.installs.update(context.uniqueIdentifier) {
                $0.grantedPermissions = permissions
                $0.bridgeRecorded = true
            }
            return
        }
        let patterns = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        profile.installs.update(context.uniqueIdentifier) {
            $0.grantedPermissions = permissions
            $0.grantedMatchPatterns = patterns
            $0.bridgeRecorded = true
        }
    }

    static func recordedGrants(_ granted: Set<String>, before: Set<String>, approving: Set<String>) -> Set<String> {
        granted.subtracting(zigzagGranted.subtracting(before).subtracting(approving))
    }

    /// Real native hosts (a companion app) only for an extension the person allowed native messaging. Zigzag grants
    /// it to every extension for its own bridge, so WebKit's grant can't tell; what was recorded can.
    private func mayUseNativeHosts(_ context: WKWebExtensionContext) -> Bool {
        profile.installs.approves(WKWebExtension.Permission.nativeMessaging.rawValue, for: context.uniqueIdentifier)
    }

    private func announceExistingWindows(to context: WKWebExtensionContext) {
        for window in WindowManager.shared.controllers where !window.tabManager.isPrivate || runsInPrivate {
            controller.didOpenWindow(window)
            // Shared-tab windows (#162) list the same tabs; report each in the window it's in.
            for tab in window.tabManager.allTabs where tab.extensionHost === self && window.holds(tab) {
                tab.toldTo = self
                controller.didOpenTab(tab)
            }
        }
        if let key = WindowManager.shared.keyController, !key.tabManager.isPrivate || runsInPrivate { controller.didFocusWindow(key) }
    }

    // MARK: Toolbar actions

    struct ActionItem {
        let context: WKWebExtensionContext
        let icon: NSImage?
        let label: String
        /// Short text the extension shows on its button (a count, "ON").
        let badge: String
        /// Set when the extension can't work until the person does something.
        let attention: Attention?
        var id: String { context.uniqueIdentifier }
    }

    /// In a private tab, only those allowed in private windows: as in Chrome's incognito, the rest don't run there.
    func actions(for tab: Tab?) -> [ActionItem] {
        running(in: tab).compactMap { actionItem($0, for: tab) }
    }

    /// The extensions with a button in the address, left to right. Only their icons are drawn.
    func pinnedActions(for tab: Tab?) -> [ActionItem] {
        profile.installs.pins.shown(among: Set(running(in: tab).map(\.uniqueIdentifier))).compactMap { id in
            context(for: id).flatMap { actionItem($0, for: tab) }
        }
    }

    /// Whether an extension with a button here can't work until the person does something.
    func needsAttention(for tab: Tab?) -> Bool {
        running(in: tab).contains { attention[$0.uniqueIdentifier] != nil && $0.action(for: tab) != nil }
    }

    /// The extensions that run in this tab: all of them, or in a private tab those allowed there.
    private func running(in tab: Tab?) -> [WKWebExtensionContext] {
        contexts.filter { PrivateAccess.sees(isPrivate: tab?.isPrivate == true, allowed: $0.hasAccessToPrivateData) }
    }

    /// Each button's icon as last drawn, until WebKit says that button changed: drawing one renders it.
    /// In the appearance it was drawn for, since an extension may give dark mode its own icon.
    private let actionIcons = NSMapTable<WKWebExtension.Action, DrawnIcon>.weakToStrongObjects()
    private final class DrawnIcon {
        let image: NSImage?
        let appearance: NSAppearance.Name
        init(image: NSImage?, appearance: NSAppearance.Name) { self.image = image; self.appearance = appearance }
    }

    private func actionItem(_ context: WKWebExtensionContext, for tab: Tab?) -> ActionItem? {
        guard let action = context.action(for: tab) else { return nil }
        let appearance = NSApp.effectiveAppearance.name
        let icon: NSImage?
        if let drawn = actionIcons.object(forKey: action), drawn.appearance == appearance {
            icon = drawn.image
        } else {
            icon = action.icon(for: NSSize(width: 32, height: 32))
            actionIcons.setObject(DrawnIcon(image: icon, appearance: appearance), forKey: action)
        }
        return ActionItem(context: context, icon: icon, label: action.label,
                          badge: action.badgeText, attention: attention[context.uniqueIdentifier])
    }

    /// Extensions' items in a page's right-click menu, once each; in a private tab, only allowed ones'. WebKit puts them in the
    /// page's menu itself, so an item already there is kept (and noted as the extension's) rather than added again:
    /// adding every extension's items a second time showed Bitwarden's twice (#186).
    func addMenuItems(for tab: Tab, to menu: NSMenu) {
        let ours = running(in: tab).map { (id: $0.uniqueIdentifier, items: $0.menuItems(for: tab)) }
        let plan = ExtensionMenuItems.plan(existing: menu.items, extensions: ours, isPrivate: tab.isPrivate)
        plan.removed.forEach(menu.removeItem)
        for (id, item) in plan.adopted + plan.added {
            let owner = MenuOwner(id: id, tab: tab)
            var queue = [item]
            while let item = queue.popLast() {
                menuOwners.setObject(owner, forKey: item)
                queue += item.submenu?.items ?? []
            }
        }
        guard !plan.added.isEmpty else { return }
        menu.addItem(.separator())
        plan.added.forEach { menu.addItem($0.item) }
    }

    /// A click waiting for WebKit to ask for the popup: which window it belongs to, and whether a pinned button
    /// opened it. WebKit also asks by itself, when a page does, and then there's no request. WebKit may never ask, so
    /// a request only counts while its window is still the one you're in.
    private struct PopupRequest {
        let extensionID: String
        let fromPin: Bool
        weak var controller: BrowserWindowController?
    }
    private var popupRequest: PopupRequest?
    private static var onePasswordTrust = OnePasswordTrust()
    private var popupShownAt: Date?
    static let log = Logger(subsystem: "wang.zigao.zigzag", category: "extensions")
    weak var lastAction: WKWebExtension.Action?
    /// A popup showing. Kept here rather than asked of WebKit: asking an action for its popup makes WebKit build one
    /// (a hidden page that runs) when there isn't one.
    private struct OpenPopup {
        let extensionID: String
        weak var action: WKWebExtension.Action?
        let popover: NSPopover
        let page: String?
        /// Live popup URL (with query) and its runtime.getContexts identity. `page` is the path, which tab capture keys on.
        let webView: WKWebView?
        /// The window it opened from; the popover's own view is in a window of its own.
        weak var window: NSWindow?
        let fromPin: Bool

        /// Open and in sight: `popover.isShown` stays true for a popup another window or a prompt has hidden.
        var isOnScreen: Bool {
            guard popover.isShown, let own = popover.contentViewController?.view.window else { return false }
            return own.isVisible && own.occlusionState.contains(.visible)
        }

        /// Whether it's this tab's popup. One with no tab of its own is the extension's shared one.
        func belongs(to tab: Tab?) -> Bool {
            guard let owner = action?.associatedTab else { return true }
            return owner === tab
        }
    }
    /// Which extension's popup, in which window.
    private struct PopupPlace: Hashable {
        let extensionID: String
        let window: ObjectIdentifier?
        init(_ extensionID: String, _ window: NSWindow?) {
            self.extensionID = extensionID
            self.window = window.map(ObjectIdentifier.init)
        }
    }
    /// One for each popover: an extension can have one showing per tab.
    private var openPopups: [ObjectIdentifier: OpenPopup] = [:]
    /// When a popup last started closing in each place, on the clock events use.
    private var popupClosedAt: [PopupPlace: TimeInterval] = [:]
    private var popupOcclusionObserver: NSObjectProtocol?
    private var removedGrantObservers: [NSObjectProtocol] = []
    /// A popup opened or closed.
    let popupsChanged = Signal<Void>()
    /// Watches each open popup closing, to end what it started (endCapturesWhenClosed).
    private var popupCloseObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// Popup sizes, observed: the page sizes itself after showing, and a wider popup moves to stay in the window.
    private var popupSizeWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// Where `popover` shows from to stay inside the window: `rect` on `view`, shifted toward the page when too wide to
    /// center (sidebar address near the edge). A pinned button's popup may point anywhere along its address.
    private func keptInWindow(_ popover: NSPopover, _ rect: NSRect, of view: NSView) -> (view: NSView, rect: NSRect) {
        let reach = view is AddressView ? view.bounds : rect
        return ExtensionPopups.positioning(rect, in: view, reach: reach.union(rect), width: popover.contentSize.width)
    }

    /// Shows `popover` from `rect` on `view`, inside the window, and keeps it there on resize. Its size is known once
    /// shown, so it's moved before it draws.
    private func show(_ popover: NSPopover, from rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        let key = ObjectIdentifier(popover)
        popupPlaces[key] = PopupAnchor(view: view, rect: rect, shownOn: view)
        keepInWindow(popover)
        popupSizeWatches[key] = popover.observe(\.contentSize, options: [.new]) { [weak self] popover, _ in
            MainActor.assumeIsolated { self?.keepInWindow(popover) }
        }
    }

    /// The requested anchor and the view it's shown from now.
    private struct PopupAnchor {
        weak var view: NSView?
        var rect: NSRect
        weak var shownOn: NSView?
    }
    private var popupPlaces: [ObjectIdentifier: PopupAnchor] = [:]

    private func keepInWindow(_ popover: NSPopover) {
        let key = ObjectIdentifier(popover)
        guard popover.isShown, let anchor = popupPlaces[key], let view = anchor.view, view.window != nil else { return }
        let place = keptInWindow(popover, anchor.rect, of: view)
        if place.view === anchor.shownOn {
            if place.rect != popover.positioningRect { popover.positioningRect = place.rect }
        } else {
            // Needs (or no longer needs) the room past the anchor's end: show again.
            popover.show(relativeTo: place.rect, of: place.view, preferredEdge: .maxY)
            popupPlaces[key]?.shownOn = place.view
        }
    }

    /// Extensions whose popup opened a window of their own before the popup was even shown (Sound Booster).
    private var popupReplacedByWindow: [String: Date] = [:]

    /// The extension's button pressed, from Site Controls or (`fromPin`) its pinned button in the address.
    func performAction(_ item: ActionItem, tab: Tab?, in controller: BrowserWindowController, fromPin: Bool = false) {
        // In a private window, only one allowed there is handed the tab or given its site.
        guard PrivateAccess.sees(isPrivate: tab?.isPrivate == true || controller.tabManager.isPrivate, allowed: item.context.hasAccessToPrivateData) else { return }
        popupRequest = nil
        // Its own popup always opens; if it still needs a step only you can do (1Password trusting Zigzag), a
        // short note says so, with the way there.
        if let attention = item.attention {
            let open: (title: String, run: () -> Void)? = attention.appBundleID.map { id in
                (attention.buttonTitle, {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                })
            }
            Toast.show(String(localized: "\(attention.title): in its settings, choose Browser, then Add Browser", comment: "Toast when an extension needs a step in its own app. The placeholder is a title like “Connect 1Password to Zigzag”. Browser and Add Browser are names in 1Password's settings."), symbol: "exclamationmark.triangle",
                       action: open, duration: 6, in: controller)
        }
        // "On Click": the click gives it this tab's site until the tab leaves it or closes (activeTab).
        if profile.installs.siteAccess(item.id) == .click, let tab { item.context.userGesturePerformed(in: tab) }
        // A click always does something: if the extension has no popup at all and opens no page, its options page
        // opens instead. One with a popup is left alone, however long it takes: a locked 1Password is slow, not broken.
        popupShownAt = nil
        let tabsBefore = WindowManager.shared.openTabs.count
        let context = item.context
        let hasPopup = context.action(for: tab)?.presentsPopup ?? false
        ExtensionLog.write("click \(context.webExtension.displayName ?? "?") popup=\(hasPopup)")
        // Its popup already open: the click closes it, as in Chrome. One open but out of sight (hidden when another
        // window or a prompt came up) would leave every click doing nothing: it's closed and opened again. So is
        // another tab's, left up after switching: this press is for the tab you're on.
        if hasPopup, let open = openPopups.values.first(where: { $0.extensionID == item.id && $0.window === controller.window && $0.popover.isShown }) {
            // Either way that opening is over: on screen the click closes it; out of sight a new one replaces it.
            if let page = open.page {
                let capture = bridge.tabCapture
                capture.popupClosed(item.id, page: page, opening: capture.currentOpening(item.id))
            }
            if open.isOnScreen {
                close([open])
                if open.belongs(to: tab) { return }
            }
        }
        // From Site Controls or anywhere else in the window, what was open steps aside for what's opening.
        controller.closeFloatingPanels()
        actionClicks[item.id] = Date()
        noteInvocation(item.id, tab: tab)
        // Its side panel, when that's what its button opens.
        if bridge.sidePanel.handleClick(item.id, hasPopup: hasPopup, in: controller) { return }
        // A new opening of its popup starts here: its page runs (and may capture the tab) before it's shown.
        if hasPopup {
            _ = bridge.tabCapture.popupOpened(item.id)
            popupRequest = PopupRequest(extensionID: item.id, fromPin: fromPin, controller: controller)
        }
        context.performAction(for: tab)
        if hasPopup {
            // WebKit keeps its own note that the popup is up, and won't ask to show it again until that's cleared: a
            // popup hidden by another window or a prompt leaves the note behind. No popup soon after the click
            // means that's what happened: cleared, and asked once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.popupShownAt == nil, let action = context.action(for: tab) else { return }
                ExtensionLog.write("popup for \(context.webExtension.displayName ?? "?") didn't come up; asking again")
                action.closePopup()
                context.performAction(for: tab)
            }
            return
        }
        let clickedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            // Opening a side panel counts as doing something, and so does tabs.update: Downie sends the tab to its app link (#239).
            let sidePanelShown = WindowManager.shared.controllers.contains { $0.root.showsSidePanel && $0.root.sidePanel.extensionID == item.id }
            let tabsNow = WindowManager.shared.openTabs.count
            guard Self.clickShowedNothing(clickedAt: clickedAt, popupShown: self.popupShownAt != nil, sidePanelShown: sidePanelShown,
                                          tabsBefore: tabsBefore, tabsNow: tabsNow, tabLoadedAt: self.tabLoads[item.id]) else { return }
            // This profile's copy of its options, in a space on this profile, never in a private window.
            let key = WindowManager.shared.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
            guard let options = context.optionsPageURL, let controller = key ?? self.openWindows.first,
                  let space = controller.tabManager.space(for: self.profile) else { return }
            ExtensionLog.write("click did nothing; opening its options")
            controller.tabManager.newTab(url: options, spaceID: space)
        }
    }

    /// action.openPopup() from an extension page framed on a site (FramedExtensionPopups): from the pinned button or the
    /// address. Nil on success, else a Chrome-style error.
    func openPopup(_ extensionID: String, from tab: Tab) -> String? {
        guard let context = context(for: extensionID), tab.isSeen(by: context),
              let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.tab(with: tab.id) === tab }),
              PrivateAccess.sees(isPrivate: controller.tabManager.isPrivate, allowed: context.hasAccessToPrivateData) else { return "No active browser window." }
        guard context.action(for: tab)?.presentsPopup == true else { return "Extension does not have a popup on the active tab." }
        ExtensionLog.write("openPopup \(context.webExtension.displayName ?? "?") from its frame")
        controller.closeFloatingPanels()
        popupRequest = PopupRequest(extensionID: extensionID, fromPin: true, controller: controller)
        context.performAction(for: tab)
        return nil
    }

    // MARK: Needing attention

    /// Something only the person can fix, shown as a "!" on the extension's button.
    struct Attention: Equatable {
        let title: String
        let message: String
        let buttonTitle: String
        /// The app to open to fix it.
        let appBundleID: String?
    }

    private(set) var attention: [String: Attention] = [:]

    fileprivate func setAttention(_ value: Attention?, for id: String) {
        guard attention[id] != value else { return }
        attention[id] = value
        changed.send()
    }

    /// Native-messaging replies are read for one thing: an app saying it doesn't trust this browser yet.
    /// 1Password says so in its first message; other apps would need their own reading here.
    fileprivate func nativeHostReplied(_ message: Any, for id: String) {
        guard id == ExtensionStore.onePasswordID, let type = OnePasswordTrust.type(of: message) else { return }
        if type != "Success" { ExtensionLog.write("1Password app replied: \(type)") }
        if Self.onePasswordTrust.isNewUnknown(type) { ExtensionLog.write("1Password reply type \(type) isn't known; not taken as trusted") }
        let reply = OnePasswordTrust.reply(type)
        let wasConnected = Self.onePasswordTrust.connected
        Self.onePasswordTrust.heard(reply)
        switch reply {
        case .connected:
            // Trusted: no add-Zigzag note in any profile this session.
            guard !wasConnected else { return }
            for profile in Profiles.shared.all {
                profile.startedExtensions?.setAttention(nil, for: id)
            }
        case .turnedAway:
            if wasConnected {
                ExtensionLog.write("1Password turned one connection away after another got through; not asking to add Zigzag")
                return
            }
            // Wait: a success on another connection means 1Password was just slow.
            DispatchQueue.main.asyncAfter(deadline: .now() + OnePasswordTrust.grace + 0.1) { [weak self] in
                self?.askToAddIfStillTurnedAway(for: id)
            }
        case .other:
            break
        }
    }

    /// Rejected with nothing trusted since: Zigzag isn't trusted yet.
    private func askToAddIfStillTurnedAway(for id: String) {
        guard Self.onePasswordTrust.needsAdding() else { return }
        setAttention(Attention(
            title: String(localized: "Connect 1Password to Zigzag", comment: "Title of the note shown from the 1Password extension's button until the 1Password app trusts Zigzag."),
            message: String(localized: "1. In 1Password, open Settings › Browser.\n2. Click Add Browser and choose Zigzag.\n3. Come back and click 1Password again.\n\n1Password only works with browsers it trusts, so this is a one-time step.", comment: "Steps in the note from the 1Password extension's button. Keep each step on its own line starting with its number and a period (1. 2. 3.); the line after the blank line is a note. Settings › Browser and Add Browser are names in 1Password."),
            buttonTitle: String(localized: "Open 1Password", comment: "Button that opens the 1Password app. 1Password is a product name."), appBundleID: "com.1password.1password"), for: id)
        // Shown once a session, instead of a 1Password spinner that never ends.
        if let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first,
           Self.onePasswordTrust.tell() {
            Toast.show(String(localized: "1Password doesn’t trust Zigzag yet. In 1Password, go to Settings › Browser › Add Browser and choose Zigzag.", comment: "Toast when the 1Password app turns Zigzag away. Settings › Browser › Add Browser are names in 1Password; match 1Password's own translation."),
                       symbol: "exclamationmark.triangle", action: (String(localized: "Open 1Password", comment: "Button that opens the 1Password app. 1Password is a product name."), {
                           if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                               NSWorkspace.shared.openApplication(at: app, configuration: .init())
                           }
                       }), duration: 15, in: controller)
        }
    }

    /// A companion app isn't installed. Logged only: as in Chrome, the extension handles it. Often optional (Bitwarden,
    /// Better Passwords, #248).
    fileprivate func companionAppMissing(for context: WKWebExtensionContext) {
        ExtensionLog.write("\(context.webExtension.displayName ?? context.uniqueIdentifier) asked for a companion app that isn't installed")
    }

    // MARK: Event fan-out from our model

    // Private tabs are told only while an extension here is allowed in private windows; WebKit keeps them from the rest.
    private func tells(_ tab: Tab) -> Bool { !tab.isPrivate || runsInPrivate }
    func tabOpened(_ tab: Tab) { if tells(tab) { controller.didOpenTab(tab) } }
    func tabClosed(_ tab: Tab, windowClosing: Bool = false) {
        if tells(tab) { controller.didCloseTab(tab, windowIsClosing: windowClosing) }
    }
    func tabActivated(_ tab: Tab, previous: Tab?) {
        guard tells(tab) else { return }
        // The tab you left is only news to the extensions that knew it.
        controller.didActivateTab(tab, previousActiveTab: previous?.extensionHost === self ? previous : nil)
    }
    func tabMoved(_ tab: Tab, from index: Int, in window: BrowserWindowController) {
        guard tells(tab), !window.tabManager.isPrivate || runsInPrivate else { return }
        controller.didMoveTab(tab, from: index, in: window)
    }
    func tabChanged(_ tab: Tab, _ change: Tab.Change) {
        guard tells(tab) else { return }
        switch change {
        // An address or sound is told at once, after what was waiting for that tab, so the order is as it happened.
        case .url: tellChanges(of: tab, adding: [.URL])
        case .audio: tellChanges(of: tab, adding: [.playingAudio, .muted])
        // A page that ticks its title (a timer, an unread count) told every extension every second: a title is told a
        // quarter of a second later, with whatever else changed meanwhile, and loading at the next turn.
        case .title: holdChange([.title], of: tab, for: 0.25)
        case .loading: holdChange([.loading], of: tab, for: 0)
        default: break
        }
    }

    private struct HeldChanges {
        weak var tab: Tab?
        var properties: WKWebExtension.TabChangedProperties
    }
    private var heldChanges: [ObjectIdentifier: HeldChanges] = [:]
    private let heldChangesTold = Coalescer()

    private func holdChange(_ properties: WKWebExtension.TabChangedProperties, of tab: Tab, for delay: TimeInterval) {
        heldChanges[ObjectIdentifier(tab), default: HeldChanges(tab: tab, properties: [])].properties.formUnion(properties)
        heldChangesTold.schedule(after: delay) { [weak self] in self?.tellHeldChanges() }
    }

    private func tellChanges(of tab: Tab, adding properties: WKWebExtension.TabChangedProperties) {
        let held = heldChanges.removeValue(forKey: ObjectIdentifier(tab))?.properties ?? []
        controller.didChangeTabProperties(held.union(properties), for: tab)
    }

    private func tellHeldChanges() {
        let held = heldChanges
        heldChanges.removeAll()
        for change in held.values {
            // A tab that closed or went to another profile meanwhile: nothing more about it here.
            guard let tab = change.tab, !tab.isClosed, tab.extensionHost === self else { continue }
            controller.didChangeTabProperties(change.properties, for: tab)
        }
    }
    // Private windows are told only while an extension here is allowed in them, and listed only to those.
    func windowOpened(_ window: BrowserWindowController) {
        guard !window.tabManager.isPrivate || runsInPrivate else { return }
        controller.didOpenWindow(window)
        // As in Chrome, there's always a current window while one is open, even with Zigzag behind another app:
        // extensions ask for its tabs as they start (Honey, LastPass) and stop when there's none.
        if NSApp.keyWindow == nil || NSApp.keyWindow?.windowController === window { controller.didFocusWindow(window) }
    }

    // Sign-in popups: a window with one tab, opened, changed, focused and closed like any other.
    func popupOpened(_ popup: PopupWindowController) {
        controller.didOpenWindow(popup)
        controller.didOpenTab(popup.tab)
        controller.didFocusWindow(popup)
        controller.didActivateTab(popup.tab, previousActiveTab: nil)
    }
    func popupChanged(_ popup: PopupWindowController, _ change: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(change, for: popup.tab)
    }
    func popupFocused(_ popup: PopupWindowController) { controller.didFocusWindow(popup) }
    func popupClosed(_ popup: PopupWindowController) {
        controller.didCloseTab(popup.tab, windowIsClosing: true)
        controller.didCloseWindow(popup)
    }
    // Zigzag Mini windows: a window with its one tab, like a sign-in popup. Its tab is a real one, so its changes are told
    // as any tab's are.
    func miniOpened(_ mini: MiniWindowController) {
        guard tells(mini.tab) else { return }
        controller.didOpenWindow(mini)
        controller.didOpenTab(mini.tab)
        controller.didFocusWindow(mini)
        controller.didActivateTab(mini.tab, previousActiveTab: nil)
    }
    func miniFocused(_ mini: MiniWindowController) { if tells(mini.tab) { controller.didFocusWindow(mini) } }
    func miniClosed(_ mini: MiniWindowController) { if tells(mini.tab) { controller.didCloseWindow(mini) } }
    func windowClosed(_ window: BrowserWindowController) {
        guard !window.tabManager.isPrivate || runsInPrivate else { return }
        controller.didCloseWindow(window)
    }
    /// A private window in front reads as no window focused, but to those allowed there.
    func windowFocused(_ window: BrowserWindowController?) {
        controller.didFocusWindow(window?.tabManager.isPrivate == true && !runsInPrivate ? nil : window)
    }

    /// Everyday windows, where what an extension opens goes.
    private var openWindows: [BrowserWindowController] { WindowManager.shared.controllers.filter { !$0.tabManager.isPrivate } }

    /// The windows this extension may see: private ones only when it's allowed in them.
    private func openWindows(for context: WKWebExtensionContext) -> [BrowserWindowController] {
        WindowManager.shared.controllers.filter { PrivateAccess.sees(isPrivate: $0.tabManager.isPrivate, allowed: context.hasAccessToPrivateData) }
    }

    /// Keyboard shortcuts declared by extensions (1Password's fill shortcut). In a private window, only allowed ones'.
    func performCommand(for event: NSEvent) -> Bool {
        let window = event.window?.windowController as? BrowserWindowController
        let inPrivate = window?.tabManager.isPrivate == true
        for context in contexts where PrivateAccess.sees(isPrivate: inPrivate, allowed: context.hasAccessToPrivateData) && context.performCommand(for: event) {
            noteInvocation(context.uniqueIdentifier, tab: window?.tabManager.selectedTab)
            return true
        }
        return false
    }
}

/// When a note that an extension's app is waiting on you may show: the connection has waited `patience`, and you
/// used the extension in the `useWindow` before it began or while it waits. Background connects never show it.
enum CompanionAppNotice {
    static let patience: TimeInterval = 6
    static let useWindow: TimeInterval = 10

    static func follows(use: Date, waitingSince: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(waitingSince) >= patience else { return false }
        guard use >= waitingSince.addingTimeInterval(-useWindow), use <= now else { return false }
        return now.timeIntervalSince(use) <= useWindow + patience
    }

    /// Whether the page's focus is where 1Password fills: a sign-in or password field, or its own menu in the page.
    /// A search box or any other field doesn't count.
    static let fieldFocusedScript = """
    (() => {
      \(Autofill.signInCheck)
      let e = document.activeElement;
      while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
      if (!e) return false;
      if (e.tagName === 'INPUT' && e.type === 'password') return true;
      if (signIn(e)) return true;
      if (e.tagName === 'IFRAME' && (e.getAttribute('src') || '').startsWith('webkit-extension://')) return true;
      return e.tagName.toLowerCase().startsWith('com-1password');
    })()
    """
}

/// What you last did with each extension, for the APIs Chrome lets act only in answer to you: the tab you used it on
/// (and that tab's origin then), the window it opened in answer, and when you last clicked or typed in its pages.
struct ExtensionUse {
    struct Invocation: Equatable {
        let tabID: UUID
        let origin: String?
        let at: Date
        /// Its own window, opened right after the click.
        var window: ObjectIdentifier?
    }

    /// How long a click or key counts as a gesture, as Chrome's transient activation.
    static let gestureWindow: TimeInterval = 5
    /// How long after you use it an extension may start capturing the tab, without its popup or window open.
    static let captureWindow: TimeInterval = 15

    /// How long a page click or key carries over to an extension's background, like Chrome's transient activation.
    static let pageGestureWindow: TimeInterval = 1

    private(set) var invocations: [String: Invocation] = [:]
    private var gestures: [String: Date] = [:]
    /// Last page click or key, and its page's host.
    private var lastPageGesture: (host: String?, at: Date)?

    mutating func pageGesture(on host: String?, at date: Date = Date()) { lastPageGesture = (host?.lowercased(), date) }

    /// Whether a call answering a content script message (from `messageHosts`, sent at `messageAt`) carries a user gesture:
    /// within `pageGestureWindow`, same host, message sent after it. Page scripts can send the message but can't make the
    /// click.
    func carriesPageGesture(messageHosts: [String], messageAt: Date, now: Date = Date()) -> Bool {
        guard let gesture = lastPageGesture, let host = gesture.host, !host.isEmpty else { return false }
        let since = now.timeIntervalSince(gesture.at)
        guard since >= 0, since < Self.pageGestureWindow else { return false }
        // Message sent after the click (with clock slack) and not in the future.
        guard messageAt >= gesture.at.addingTimeInterval(-0.05), messageAt <= now.addingTimeInterval(0.05) else { return false }
        return messageHosts.contains { $0.lowercased() == host }
    }

    mutating func invoked(_ id: String, tabID: UUID, origin: String?, at date: Date = Date()) {
        invocations[id] = Invocation(tabID: tabID, origin: origin, at: date)
        gestures[id] = date
    }

    mutating func touched(_ id: String, at date: Date = Date()) { gestures[id] = date }

    /// A click or non-repeat key press, as Chrome's transient activation counts them.
    static func isGesture(_ type: NSEvent.EventType, isRepeat: Bool) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown: true
        case .keyDown: !isRepeat
        default: false
        }
    }

    mutating func openedWindow(_ id: String, _ window: ObjectIdentifier) { invocations[id]?.window = window }

    mutating func forget(_ id: String) {
        invocations[id] = nil
        gestures[id] = nil
    }

    func hasGesture(_ id: String, now: Date = Date()) -> Bool {
        guard let at = gestures[id] else { return false }
        return now >= at && now.timeIntervalSince(at) < Self.gestureWindow
    }

    /// Whether the extension may capture this tab now: the one you used it on, still showing the same origin, while
    /// the popup or window of that use is open or for a short while after.
    func mayCapture(_ id: String, tabID: UUID, origin: String?, popupShown: Bool, windowOpen: (ObjectIdentifier) -> Bool,
                    now: Date = Date()) -> Bool {
        guard let invocation = invocations[id], invocation.tabID == tabID, let origin, invocation.origin == origin else { return false }
        if popupShown || invocation.window.map(windowOpen) == true { return true }
        return now >= invocation.at && now.timeIntervalSince(invocation.at) < Self.captureWindow
    }
}

// MARK: - Controller delegate

@available(macOS 15.4, *)
extension ExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        // The focused window first, as extensions expect; sign-in popups count too.
        // A browser window shows spaces of several profiles, so every profile's extensions have it, each seeing
        // their own tabs there. A sign-in popup or a Zigzag Mini is one page: only its own profile's have it.
        let popups: [any WKWebExtensionWindow] = PopupWindowController.all.filter(isOurs) + MiniWindowController.all.filter(isOurs)
        let windows: [any WKWebExtensionWindow] = openWindows(for: extensionContext)
        let key: (any WKWebExtensionWindow)? = PopupWindowController.key.flatMap { isOurs($0) ? $0 : nil } ?? MiniWindowController.key.flatMap { isOurs($0) ? $0 : nil }
        return key.map { key in [key] + windows + popups.filter { $0 !== key } } ?? windows + popups
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        if let popup = PopupWindowController.key { return isOurs(popup) ? popup : nil }
        if let mini = MiniWindowController.key { return isOurs(mini) ? mini : nil }
        return WindowManager.shared.keyController.flatMap { PrivateAccess.sees(isPrivate: $0.tabManager.isPrivate, allowed: extensionContext.hasAccessToPrivateData) ? $0 : nil }
    }

    private func isOurs(_ popup: PopupWindowController) -> Bool {
        !popup.isPrivate && popup.webView.configuration.websiteDataStore === profile.store
    }

    private func isOurs(_ mini: MiniWindowController) -> Bool { mini.tab.extensionHost === self }

    /// Whether the side panel a window shows is this profile's copy of an extension's, not another profile's copy
    /// of the same one.
    func showsSidePanel(of id: String, in controller: BrowserWindowController) -> Bool {
        controller.root.sidePanel.extensionID == id && controller.root.sidePanel.webView?.configuration.websiteDataStore === profile.store
    }

    /// What an extension hears when it asks for a tab or window and its profile has no space to open it in.
    private static let noSpace = NSError(domain: "app.zigzag.extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: "This profile has no space to open a page in"])
    /// What an extension not allowed in private windows hears when it asks for one.
    private static let notInPrivate = NSError(domain: "app.zigzag.extensions", code: 2, userInfo: [NSLocalizedDescriptionKey: "This extension isn't allowed in private windows"])

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        // Into a private window only when it names one, which only an extension allowed there can; else everyday browsing.
        let key = WindowManager.shared.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        let named = (configuration.window as? BrowserWindowController).flatMap {
            PrivateAccess.sees(isPrivate: $0.tabManager.isPrivate, allowed: extensionContext.hasAccessToPrivateData) ? $0 : nil
        }
        let window = named ?? key ?? openWindows.last
            ?? WindowManager.shared.restoreIfNoWindows() ?? WindowManager.shared.newWindow(showCommandBar: false)
        // In a space on this profile: the page is the extension's, with this profile's sign-ins. A profile with no
        // space yet has nowhere to put it: better not opened than opened in another profile.
        guard let space = window.tabManager.space(for: profile) else { completionHandler(nil, Self.noSpace); return }
        let tab = window.tabManager.newTab(url: configuration.url, spaceID: space, select: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // A small window of the extension's own page (a volume control), as Chrome opens it, not a whole browser window.
        if configuration.windowType == .popup, configuration.tabURLs.count <= 1, !configuration.shouldBePrivate {
            let url = configuration.tabURLs.first.map(Tab.extensionPageAddress) ?? extensionContext.baseURL
            let pageConfiguration = url.host() == extensionContext.baseURL.host() ? extensionContext.webViewConfiguration : nil
            let popup = PopupWindowController.openForExtension(url: url, configuration: pageConfiguration ?? WebKitSetup.makeConfiguration(for: profile),
                                                               frame: configuration.frame, parent: WindowManager.shared.keyController?.window)
            // In Chrome the popup that asked closes as the window takes focus; the window is where it continues.
            // Its popup page often opens the window before Zigzag has shown the popup at all: then it isn't shown.
            if configuration.shouldBeFocused == false {
                WindowManager.shared.keyController?.window?.makeKeyAndOrderFront(nil)
            } else if isPopupShown(for: extensionContext.uniqueIdentifier) {
                closePopups(for: extensionContext.uniqueIdentifier)
            } else if Date().timeIntervalSince(lastActionClick(extensionContext.uniqueIdentifier)) < 3 {
                popupReplacedByWindow[extensionContext.uniqueIdentifier] = Date()
            }
            // Opened in answer to a click: while it's open, it carries on that use, on the tab you clicked it on.
            if Date().timeIntervalSince(lastActionClick(extensionContext.uniqueIdentifier)) < 3 {
                use.openedWindow(extensionContext.uniqueIdentifier, ObjectIdentifier(popup))
            }
            completionHandler(popup, nil)
            return
        }
        if configuration.shouldBePrivate {
            guard extensionContext.hasAccessToPrivateData else { completionHandler(nil, Self.notInPrivate); return }
            let space = WindowManager.shared.keyController?.tabManager.space(for: profile) ?? Library.shared.spaces(in: profile.id).first?.id
            let window = WindowManager.shared.newWindow(url: configuration.tabURLs.first, spaceID: space, showCommandBar: false, isPrivate: true)
            for url in configuration.tabURLs.dropFirst() { window.tabManager.newTab(url: url, spaceID: space, select: false) }
            completionHandler(window, nil)
            return
        }
        // The saved session comes back first, or the new window's first save would replace it.
        WindowManager.shared.restoreIfNoWindows()
        guard let space = WindowManager.shared.keyController?.tabManager.space(for: profile) ?? Library.shared.spaces(in: profile.id).first?.id else {
            completionHandler(nil, Self.noSpace)
            return
        }
        let window = WindowManager.shared.newWindow(url: configuration.tabURLs.first, spaceID: space, showCommandBar: false)
        for url in configuration.tabURLs.dropFirst() { window.tabManager.newTab(url: url, spaceID: space, select: false) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        // Never in a private window, where extensions don't run: their options page would be a blank one there.
        let key = WindowManager.shared.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        guard let url = extensionContext.optionsPageURL, let window = key ?? openWindows.first else { completionHandler(nil); return }
        guard let space = window.tabManager.space(for: profile) else { completionHandler(Self.noSpace); return }
        window.tabManager.newTab(url: url, spaceID: space, title: extensionContext.webExtension.displayName)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        // What Chrome grants quietly is granted; the rest only if you allow it, asked only in answer to something you
        // just did with the extension, as Chrome requires. Allowed is kept; not allowed holds until Zigzag quits.
        let (asked, quiet) = Self.sort(permissions)
        // Record what the user allowed as theirs, including Zigzag's own two (native messaging, scripting).
        let finish = { (granted: Set<WKWebExtension.Permission>, approved: Bool) in
            completionHandler(granted, nil)
            DispatchQueue.main.async { self.saveGrants(of: extensionContext, approving: approved ? Set(granted.map(\.rawValue)) : []) }
        }
        guard !asked.isEmpty else { finish(permissions, false); return }
        guard hasRecentGesture(extensionContext.uniqueIdentifier), !ExtensionSheet.isShowing,
              let window = WindowManager.shared.keyController.flatMap({ $0.tabManager.isPrivate ? nil : $0 }) ?? openWindows.first else {
            ExtensionLog.write("\(extensionContext.webExtension.displayName ?? "extension") asked for \(asked.map(\.rawValue).sorted()) without a click; not granted")
            finish(quiet, false)
            return
        }
        let content = Self.moreAccessSheet(for: extensionContext, report: ExtensionReport(requesting: Set(asked.map(\.rawValue)), id: extensionContext.uniqueIdentifier))
        ExtensionSheet.present(content, in: window, onConfirm: { [weak self] in
            // Sites asked for in the same request are asked about next, still in answer to that click.
            self?.use.touched(extensionContext.uniqueIdentifier)
            finish(permissions, true)
        }, onCancel: { finish(quiet, false) })
    }

    /// The sheet that asks before an extension gets more than it has (`permissions.request`).
    static func moreAccessSheet(for context: WKWebExtensionContext, report: ExtensionReport) -> ExtensionSheet.Content {
        let ext = context.webExtension
        return ExtensionSheet.Content(
            icon: ext.icon(for: NSSize(width: 40, height: 40)),
            title: ext.displayName.map { String(localized: "\($0) wants more access", comment: "Title of the sheet shown when an extension asks for more access. The name is the extension's.") }
                ?? String(localized: "This extension wants more access", comment: "Title of the sheet shown when an extension with no name asks for more access."),
            subtitle: String(localized: "Allow it only if it needs this for what you just asked it to do.", comment: "Under the title of the sheet shown when an extension asks for more access."),
            heading: String(localized: "It would also be able to", comment: "Heading over the list of what an extension could also do, in the sheet shown when it asks for more access."),
            report: report,
            confirm: String(localized: "Allow", comment: "Button in the sheet shown when an extension asks for more access: gives it."),
            cancel: String(localized: "Don’t Allow", comment: "Button in the sheet shown when an extension asks for more access: refuses it."))
    }

    /// The permissions asked for that need your say, and those granted without asking.
    static func sort(_ permissions: Set<WKWebExtension.Permission>) -> (asked: Set<WKWebExtension.Permission>, quiet: Set<WKWebExtension.Permission>) {
        let asked = permissions.filter { ExtensionReport.askedPermissions.contains($0.rawValue) }
        return (asked, permissions.subtracting(asked))
    }

    /// A page it wants to reach gets only what your site access already gives it.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let granted = Array(extensionContext.grantedPermissionMatchPatterns.keys)
        let denied = Array(extensionContext.deniedPermissionMatchPatterns.keys)
        completionHandler(urls.filter { url in
            granted.contains { $0.matches(url) } && !denied.contains { $0.matches(url) }
        }, nil)
    }

    /// Sites asked for with `permissions.request`: those your site access covers are granted, the others only if you
    /// allow them, asked only in answer to something you just did with the extension, as Chrome requires. Allowed is kept.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let ext = extensionContext.webExtension
        let granted = Array(extensionContext.grantedPermissionMatchPatterns.keys), denied = Array(extensionContext.deniedPermissionMatchPatterns.keys)
        let within = Self.patternsWithinAccess(matchPatterns, granted: granted, denied: denied)
        let asked = Self.patternsToAsk(matchPatterns.subtracting(within), declared: Array(ext.allRequestedMatchPatterns.union(ext.optionalPermissionMatchPatterns)),
                                       denied: denied)
        guard !asked.isEmpty else { completionHandler(within, nil); return }
        let id = extensionContext.uniqueIdentifier
        guard hasRecentGesture(id), !ExtensionSheet.isShowing,
              let window = WindowManager.shared.keyController.flatMap({ $0.tabManager.isPrivate ? nil : $0 }) ?? openWindows.first else {
            ExtensionLog.write("\(ext.displayName ?? "extension") asked for \(asked.map(\.string).sorted()) without a click; not granted")
            completionHandler(within, nil)
            return
        }
        let report = ExtensionReport(requesting: [], patterns: asked.map(\.string), id: id)
        ExtensionSheet.present(Self.moreAccessSheet(for: extensionContext, report: report), in: window, onConfirm: { [weak self, weak extensionContext] in
            completionHandler(within.union(asked), nil)
            DispatchQueue.main.async {
                guard let self, let extensionContext, self.context(for: id) === extensionContext else { return }
                self.profile.installs.update(id) {
                    $0.requestedMatchPatterns = Array(Set(($0.requestedMatchPatterns ?? []) + asked.map(\.string))).sorted()
                }
            }
        }, onCancel: { completionHandler(within, nil) })
    }

    /// The requested patterns worth asking about: within what the extension declared, and not inside a site where
    /// extensions are off.
    static func patternsToAsk(_ requested: Set<WKWebExtension.MatchPattern>, declared: [WKWebExtension.MatchPattern],
                              denied: [WKWebExtension.MatchPattern]) -> Set<WKWebExtension.MatchPattern> {
        requested.filter { pattern in
            declared.contains { $0.matches(pattern) }
                && !denied.contains { $0.matches(pattern) }
        }
    }

    /// The requested patterns that a pattern already granted covers in full, and that no denied one touches.
    static func patternsWithinAccess(_ requested: Set<WKWebExtension.MatchPattern>, granted: [WKWebExtension.MatchPattern],
                                     denied: [WKWebExtension.MatchPattern]) -> Set<WKWebExtension.MatchPattern> {
        requested.filter { pattern in
            granted.contains { $0.matches(pattern) }
                && !denied.contains { $0.matches(pattern, options: .matchBidirectionally) }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        // Only buttons draw an action: the list of extensions (Settings) is the same as it was.
        actionIcons.removeObject(forKey: action)
        ExtensionCenter.actionUpdated.send(action.associatedTab as? Tab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        lastAction = action
        popupShownAt = Date()
        // Answering the click that asked for it, or (no request) a page asking by itself.
        let request = popupRequest?.extensionID == context.uniqueIdentifier ? popupRequest : nil
        if request != nil { popupRequest = nil }
        ExtensionLog.write("popup \(context.webExtension.displayName ?? "?") has=\(action.popupPopover != nil)")
        guard let popover = action.popupPopover else { completionHandler(nil); return }
        if let replaced = popupReplacedByWindow.removeValue(forKey: context.uniqueIdentifier), Date().timeIntervalSince(replaced) < 3 {
            action.closePopup()
            completionHandler(nil)
            return
        }
        // Asked for from a sign-in popup (1Password's "Unlock" in a field there, or its shortcut): it opens over that
        // popup. From the window behind, it would be out of sight and close at the first click back in the popup.
        if let popup = (action.associatedTab as? PopupTab)?.popup ?? PopupWindowController.key, popup.window?.isVisible == true {
            endCapturesWhenClosed(popover, action: action, extensionID: context.uniqueIdentifier, window: popup.window, fromPin: false)
            popup.showExtensionPopover(popover)
            popover.contentViewController?.view.window?.makeKey()
            popupsChanged.send()
            completionHandler(nil)
            return
        }
        // Asked by the page (1Password's "Unlock" button) rather than a click, it comes from the address bar of the
        // window you're in; a private one only for an extension allowed there.
        let seen = { (window: BrowserWindowController) in PrivateAccess.sees(isPrivate: window.tabManager.isPrivate, allowed: context.hasAccessToPrivateData) }
        let controller = request?.controller.flatMap { seen($0) ? $0 : nil }
            ?? ([WindowManager.shared.keyController].compactMap { $0 } + WindowManager.shared.controllers).first(where: seen)
        let fromPin = request?.fromPin == true && request?.controller === controller
        guard let place = controller?.popupAnchor(forPin: fromPin ? context.uniqueIdentifier : nil), place.view.window != nil else {
            completionHandler(NSError(domain: "Zigzag", code: 2, userInfo: [NSLocalizedDescriptionKey: "No window to show the popup in"]))
            return
        }
        // A popup takes the place of an open panel, as a panel takes a popup's.
        controller?.closeFloatingPanels()
        popover.behavior = .semitransient
        // One popup to a window: another extension's steps aside, however this one was asked for.
        closeOtherPopups(than: popover, in: place.view.window)
        endCapturesWhenClosed(popover, action: action, extensionID: context.uniqueIdentifier, window: place.view.window, fromPin: fromPin)
        show(popover, from: place.rect, of: place.view)
        // Key, as in Chrome: WebKit sends the pointer's moves only to a key window's page, so tooltips and hover need it (#277).
        popover.contentViewController?.view.window?.makeKey()
        popupsChanged.send()
        completionHandler(nil)
    }

    /// However a popup closes (a click elsewhere, its button, the page itself), a tab capture it made ends with it,
    /// as in Chrome, where closing the popup ends its page.
    private func endCapturesWhenClosed(_ popover: NSPopover, action: WKWebExtension.Action, extensionID: String, window: NSWindow?, fromPin: Bool) {
        let key = ObjectIdentifier(popover)
        popupCloseObservers.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver)
        // Read now, while WebKit is showing it: asked for after it closes, WebKit would make a new popup page to answer.
        let view = action.popupWebView
        let page = view?.url?.path
        openPopups[key] = OpenPopup(extensionID: extensionID, action: action, popover: popover, page: page, webView: view, window: window, fromPin: fromPin)
        let opening = bridge.tabCapture.currentOpening(extensionID)
        let place = PopupPlace(extensionID, window)
        // Saved first responder: the field, not AppKit's field editor.
        let responder = window?.firstResponder
        let focused = ((responder as? NSText)?.isFieldEditor == true ? (responder as? NSText)?.delegate as? NSView : responder as? NSView)
            .flatMap { $0.window === window ? $0 : nil }
        let closing = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: popover, queue: .main) { [weak self, weak popover, weak window] _ in
            MainActor.assumeIsolated {
                self?.popupClosedAt[place] = ProcessInfo.processInfo.systemUptime
                // Return key status to the opener unless you moved to another window.
                let popupWindow = popover?.contentViewController?.view.window
                if let window, window.isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === popupWindow {
                    window.makeKey()
                }
            }
        }
        let closed = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self, weak popover, weak window, weak focused] _ in
            MainActor.assumeIsolated {
                // WebKit shows the same popover again for a new opening; a late notice for the last one is passed over.
                guard popover?.isShown != true else { return }
                // Restore the page or field focus unless something else in the window took it.
                if let window, let focused, focused.window === window, (window.firstResponder as? NSView)?.window !== window {
                    window.makeFirstResponder(focused)
                }
                self?.popupCloseObservers.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver)
                self?.popupSizeWatches[key] = nil
                self?.popupPlaces[key] = nil
                self?.openPopups[key] = nil
                self?.popupsChanged.send()
                guard let page else { return }
                self?.bridge.tabCapture.popupClosed(extensionID, page: page, opening: opening)
            }
        }
        popupCloseObservers[key] = [closing, closed]
    }

    // MARK: Native messaging (the extension talking to the 1Password app)

    /// Its companion app is still connected: its background answers on its keep-awake port, which WebKit counts as
    /// the background being busy, so it isn't stopped for being quiet (Chrome never stops one with an app connected).
    fileprivate func keepBackgroundAwake(_ id: String) {
        keepAlivePorts.port(for: id)?.sendMessage(1, completionHandler: nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        if applicationIdentifier == ExtensionShims.diagnosticsHost {
            let report = message as? [String: Any]
            let line = ((report?["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
            ExtensionLog.write("\(extensionContext.webExtension.displayName ?? "extension") [\(report?["where"] ?? "?")] \(report?["kind"] ?? "?"): \(line)")
            replyHandler(nil, nil)
            return
        }
        if applicationIdentifier == ExtensionBridge.hostName {
            bridge.handle(message, from: extensionContext, reply: replyHandler)
            return
        }
        // A companion app only for an extension that asked for native messaging itself; the loaded copy's grant is
        // for Zigzag's bridge alone.
        guard mayUseNativeHosts(extensionContext),
              let host = NativeMessagingHost(name: applicationIdentifier, context: extensionContext, owner: self) else {
            companionAppMissing(for: extensionContext)
            replyHandler(nil, NativeMessagingHost.notFound)
            return
        }
        host.sendOnce(message, reply: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // A WebSocket for a background, which WebKit can't open there itself (see WebSocketBridge).
        if port.applicationIdentifier == WebSocketBridge.host {
            guard ExtensionShims.usesWebSocketShim(manifest: ExtensionStore.manifest(for: extensionContext.uniqueIdentifier)) else {
                completionHandler(NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native host"]))
                return
            }
            let key = ObjectIdentifier(port)
            socketBridges[key] = WebSocketBridge(port: port, extensionID: extensionContext.uniqueIdentifier,
                                                 proxies: profile.store.proxyConfigurations,
                                                 mayConnect: { [weak extensionContext] url in
                                                     extensionContext.map { WebSocketBridge.allows(url, context: $0) } ?? false
                                                 }) { [weak self] in
                self?.socketBridges[key] = nil
            }
            completionHandler(nil)
            return
        }
        if port.applicationIdentifier == ExtensionShims.keepAliveHost {
            let id = extensionContext.uniqueIdentifier
            keepAlivePorts.opened(port, for: id)
            port.disconnectHandler = { [weak self, weak port] _ in
                if let self, let port { self.keepAlivePorts.closed(port, for: id) }
            }
            completionHandler(nil)
            return
        }
        if port.applicationIdentifier == ExtensionBridge.hostName {
            bridge.connect(port, for: extensionContext)
            completionHandler(nil)
            return
        }
        guard mayUseNativeHosts(extensionContext),
              let host = NativeMessagingHost(name: port.applicationIdentifier, context: extensionContext, owner: self) else {
            companionAppMissing(for: extensionContext)
            completionHandler(NativeMessagingHost.notFound)
            return
        }
        let key = ObjectIdentifier(port)
        nativePorts[key] = host
        host.connect(port) { [weak self] in self?.nativePorts[key] = nil }
        completionHandler(nil)
    }
}

// MARK: - Our tabs and windows, as extensions see them

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    /// The window the tab's in: its own host when that window holds it (most often), else a look through them all.
    /// Asked for every tab each time an extension lists tabs, so the quick answer comes first.
    private var windowController: BrowserWindowController? {
        if let host = host as? BrowserWindowController, host.tabManager.tab(with: id) === self { return host }
        return WindowManager.shared.controllers.first { $0.tabManager.tab(with: id) === self }
    }

    /// Whether this context's extensions are the tab's own profile's, and for a private tab, allowed in private windows.
    func isSeen(by context: WKWebExtensionContext) -> Bool {
        PrivateAccess.sees(isPrivate: isPrivate, allowed: context.hasAccessToPrivateData) && context.webExtensionController === profile.startedExtensions?.controller
    }

    /// The Zigzag Mini it's the page of, while it is.
    private var miniWindow: MiniWindowController? { (host as? MiniWindowController).flatMap { $0.tab === self ? $0 : nil } }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { miniWindow ?? windowController }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        // Counted among `tabs(for:)`.
        guard let window = windowController else { return 0 }
        return window.tabManager.extensionPlace(of: self, seenBy: Tab.seers(context)) { $0.isSeen(by: context) && window.holds($0) } ?? 0
    }
    /// The profile a context's extensions run with; it decides which tabs it sees.
    static func seers(_ context: WKWebExtensionContext) -> ObjectIdentifier {
        context.webExtensionController.map(ObjectIdentifier.init) ?? ObjectIdentifier(context)
    }
    // A private tab that reaches an extension not allowed there tells it nothing: no page, title or address.
    // Nor does a tab on another profile: its page isn't one this context's extensions may reach.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { isSeen(by: context) ? webView : nil }
    // Nor does a tab that has moved to another profile, to an extension of the one it left that still holds it.
    func title(for context: WKWebExtensionContext) -> String? { isHidden(from: context) ? nil : displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { isHidden(from: context) ? nil : url }
    private func isHidden(from context: WKWebExtensionContext) -> Bool {
        !PrivateAccess.sees(isPrivate: isPrivate, allowed: context.hasAccessToPrivateData) || isAnotherProfiles(context)
    }
    /// Whether the extension asking runs in a profile this tab isn't in.
    private func isAnotherProfiles(_ context: WKWebExtensionContext) -> Bool {
        guard let controller = context.webExtensionController else { return false }
        return controller !== profile.startedExtensions?.controller
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        if miniWindow != nil { return true }
        guard let window = windowController else { return false }
        if window.tabManager.selectedTab === self { return true }
        // With none of its tabs in the space in front, the one `activeTab(for:)` gives, so a query finds it too.
        guard window.tabManager.selectedTab.map({ !$0.isSeen(by: context) }) ?? true else { return false }
        return (window.activeTab(for: context) as? Tab) === self
    }
    func isPinned(for context: WKWebExtensionContext) -> Bool { bookmarkID != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        PrivateAccess.sees(isPrivate: isPrivate, allowed: context.hasAccessToPrivateData)
            && profile.startedExtensions?.grantsTabOnGesture(context, url: webView?.url ?? url) == true
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        miniWindow?.window?.makeKeyAndOrderFront(nil)
        if miniWindow == nil { windowController?.tabManager.select(self) }
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // Answered as done, not refused: Violentmonkey opens its page in a new tab when this one won't take it.
        let tampermonkeyOn = ExtensionShims.tampermonkeyIDs.contains { profile.extensions.context(for: $0) != nil }
        if ExtensionShims.leavesInstallToTampermonkey(context.uniqueIdentifier, loading: url, tabURL: webView?.url ?? self.url,
                                                        tampermonkeyOn: tampermonkeyOn) {
            completionHandler(nil)
            return
        }
        profile.extensions.noteTabLoad(context.uniqueIdentifier)
        load(url)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        miniWindow?.window?.close()
        if miniWindow == nil { windowController?.tabManager.close(self) }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        fromOrigin ? reloadFromOrigin() : reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // The page's own history only: an extension going back never closes the tab, as in Chrome.
        webView?.goBack(); completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward(); completionHandler(nil)
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        setMuted(muted); completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension BrowserWindowController: WKWebExtensionWindow {
    // A private window is listed only to an extension allowed there; to any other, its tabs stay unseen.
    // An extension sees the tabs of its own profile: the window may be showing a space on another.
    /// Every space's, as in Chrome every tab in a window is listed, not only the space in front's.
    /// With shared tabs (#162), only the ones in this window; an extension sees each tab in one window (where it's shown
    /// or last was).
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard !hides(from: context) else { return [] }
        return tabManager.extensionTabs(seenBy: Tab.seers(context)) { $0.isSeen(by: context) && self.holds($0) }
    }

    /// The tab you're on if it's on the extension's profile; else the one you left selected in a space that is,
    /// since Chrome's extensions expect a window to have an active tab.
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard !hides(from: context) else { return nil }
        if let tab = tabManager.selectedTab, tab.isSeen(by: context) { return tab }
        return Library.shared.spaces.lazy.compactMap { self.tabManager.selectedTab(in: $0.id) }.first { $0.isSeen(by: context) }
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }
    /// WebKit keeps a private window, its tabs and their events from extensions not allowed there.
    func isPrivate(for context: WKWebExtensionContext) -> Bool { tabManager.isPrivate }
    private func hides(from context: WKWebExtensionContext) -> Bool {
        !PrivateAccess.sees(isPrivate: tabManager.isPrivate, allowed: context.hasAccessToPrivateData)
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}

// MARK: - Native messaging host

/// Speaks Chrome's native messaging protocol (length-prefixed JSON over stdio) with a helper app,
/// using the same host manifests Chrome uses. This is how the 1Password extension reaches the 1Password app.
/// One helper per connection or one-off message, as in Chrome, and each one ends with it: a helper left running
/// keeps the app awake and can bring up its unlock window for no reason you can see.
@available(macOS 15.4, *)
final class NativeMessagingHost {
    private let executable: URL
    private let origin: String
    let extensionID: String
    /// This connection already pointed at its app.
    private var pointedAtApp = false
    /// Every helper running, kept alive here until it ends, so quitting Zigzag or turning the extension off
    /// ends them too instead of leaving them running.
    private static var running: [ObjectIdentifier: NativeMessagingHost] = [:]
    /// The profile's extensions it was started for: the same extension in another profile has helpers of its own.
    private weak var owner: ExtensionHost?
    /// A one-off message gets this long for its answer; a locked app waiting on you can take a while.
    private static let replyTimeout: TimeInterval = 60
    /// How often a connected app keeps its extension's background awake: well inside the two quiet minutes after
    /// which WebKit stops one.
    static let keepAwakeInterval: TimeInterval = 30

    static func terminateAll() {
        for host in Array(running.values) { host.finish() }
    }

    static func terminateAll(for id: String, of owner: ExtensionHost) {
        for host in Array(running.values) where host.extensionID == id && host.owner === owner { host.finish() }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var finished = false
    private var onMessage: ((Any) -> Void)?
    private var onExit: (() -> Void)?

    init?(name: String?, context: WKWebExtensionContext, owner: ExtensionHost) {
        self.owner = owner
        let id = context.uniqueIdentifier
        guard let name, let manifest = Self.manifest(named: name), let host = Self.host(in: manifest, for: id) else { return nil }
        executable = host.executable
        origin = host.origin
        extensionID = id
    }

    /// Chrome's error for a missing host. Extensions match it to tell "not installed" from a failure (Better Passwords, #248).
    static var notFound: NSError { NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."]) }

    /// Chrome's rule for a host's name: lowercase words of letters, digits and underscores, joined by dots. Anything
    /// else (a slash, "..") could reach a file outside the hosts folder.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: "\\A[a-z0-9_]+(\\.[a-z0-9_]+)*\\z", options: .regularExpression) != nil
    }

    /// The helper to run and the origin to hand it, as Chrome would: only when the manifest lists this extension's
    /// origin exactly, and its path is an absolute path to a program. Nil means no host for this extension.
    static func host(in manifest: [String: Any], for id: String) -> (executable: URL, origin: String)? {
        let origin = "chrome-extension://\(id)/"
        guard let allowed = manifest["allowed_origins"] as? [String], allowed.contains(origin),
              let path = manifest["path"] as? String, path.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return (executable, origin)
    }

    static func manifest(named name: String) -> [String: Any]? {
        guard isValidName(name) else { return nil }
        #if DEBUG
        // A test copy (ZIGZAG_DATA_DIR) never reaches the helpers of the apps on this Mac (1Password, Apple's
        // Passwords): only hosts in its own data folder, and none at all with ZIGZAG_BLOCK_NATIVE_MESSAGING=1.
        let env = ProcessInfo.processInfo.environment
        if env["ZIGZAG_BLOCK_NATIVE_MESSAGING"] == "1" { return nil }
        if let data = env["ZIGZAG_DATA_DIR"], !data.isEmpty {
            let file = URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("NativeMessagingHosts/\(name).json")
            guard let bytes = try? Data(contentsOf: file) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        #endif
        return manifest(named: name, in: searchFolders(home: FileManager.default.homeDirectoryForCurrentUser))
    }

    /// Where Chromium browsers keep their hosts, in the order looked in. An app writes its manifest only for the
    /// browsers it finds on the Mac (1Password: Chrome and its Beta, Dev and Canary, Edge and its channels, Vivaldi,
    /// Arc), so someone without Chrome still has one in another browser's folder.
    static func searchFolders(home: URL) -> [URL] {
        [
            "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium",
            "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary",
            "BraveSoftware/Brave-Browser", "Vivaldi", "Vivaldi Snapshot", "Arc/User Data",
        ].map { home.appendingPathComponent("Library/Application Support/\($0)/NativeMessagingHosts", isDirectory: true) }
            + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)]
    }

    /// The first manifest for the host in these folders.
    static func manifest(named name: String, in dirs: [URL]) -> [String: Any]? {
        guard isValidName(name) else { return nil }
        for dir in dirs {
            let file = dir.appendingPathComponent("\(name).json")
            if let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    /// Starts the helper; `onMessage` and `onExit` are set first. Until it ends, `running` keeps this alive.
    private func start() -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = [origin]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Writing to a helper that already quit fails quietly instead of killing Zigzag with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Closed: stop listening. Left in place, the handler fires again at once, forever, and keeps a core busy.
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    // Its output closing comes after its last message, so no answer is lost to the ending.
                    if data.isEmpty { self.finish(); return }
                    self.buffer.append(data)
                    for message in self.drainMessages() where !self.finished { self.onMessage?(message) }
                }
            }
        }
        // Normally its output closing ends it; this covers a helper whose output outlives it.
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.finish() } }
        }
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        Self.running[ObjectIdentifier(self)] = self
        return true
    }

    /// Ends the helper and says so, once.
    private func finish() {
        guard !finished else { return }
        finished = true
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        Self.running[ObjectIdentifier(self)] = nil
        let exit = onExit
        onMessage = nil
        onExit = nil
        exit?()
    }

    private func drainMessages() -> [Any] {
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) { messages.append(object) }
        }
        return messages
    }

    private func write(_ message: Any?) {
        guard let input, let message,
              let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try? input.write(contentsOf: frame)
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Zigzag", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// One message, one answer, as Chrome's sendNativeMessage: the helper ends after its first reply, or when it
    /// gives up, or after a while with no answer. The extension always hears back exactly once.
    func sendOnce(_ message: Any, reply: @escaping (Any?, (any Error)?) -> Void) {
        let id = extensionID
        var replied = false
        let answer: (Any?, (any Error)?) -> Void = { response, error in
            guard !replied else { return }
            replied = true
            reply(response, error)
        }
        onMessage = { [weak self] response in
            self?.owner?.nativeHostReplied(response, for: id)
            answer(response, nil)
            self?.finish()
        }
        onExit = { answer(nil, Self.failure("Native host has exited.")) }
        guard start() else {
            onMessage = nil
            onExit = nil
            answer(nil, Self.failure("Failed to start native messaging host."))
            return
        }
        write(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyTimeout) { [weak self] in
            guard let self, !self.finished else { return }
            ExtensionLog.write("native host for \(id) gave no answer to a one-off message")
            answer(nil, Self.failure("Native host did not reply."))
            self.finish()
        }
    }

    /// A connection that keeps reconnecting (a restarting background, an app that keeps hanging up) waits a little
    /// longer each time, instead of starting helper after helper. Only helpers that really started count, and one
    /// that answers clears the slate, so an extension retrying while it waits is never locked out.
    private func delayBeforeStarting() -> TimeInterval {
        let now = Date()
        let recent = (owner?.helperStarts[extensionID] ?? []).filter { now.timeIntervalSince($0) < 30 }
        owner?.helperStarts[extensionID] = recent
        return recent.count < 3 ? 0 : min(Double(recent.count - 2) * 2, 15)
    }

    func connect(_ port: WKWebExtension.MessagePort, onClose: @escaping () -> Void) {
        let id = extensionID
        // Which profile's copy, for telling two copies' helpers apart in the log.
        let place = owner.map { "\(id) in profile \($0.profile.id.uuidString.prefix(4))" } ?? id
        var received = 0
        var sent = 0
        // What the extension says before the helper is up waits for it.
        var waiting: [Any] = []
        onMessage = { [weak owner] message in
            received += 1
            if received == 1 { owner?.helperStarts[id] = nil }
            owner?.nativeHostReplied(message, for: id)
            port.sendMessage(message, completionHandler: nil)
        }
        onExit = {
            ExtensionLog.write("native host for \(place) ended after \(sent) sent, \(received) received")
            port.disconnect()
            onClose()
        }
        port.messageHandler = { [weak self] message, _ in
            guard let self, let message, !self.finished else { return }
            sent += 1
            if self.process == nil { waiting.append(message) } else { self.write(message) }
        }
        // The extension hung up: its helper ends with it, as in Chrome.
        port.disconnectHandler = { [weak self] _ in self?.finish() }

        let begin = { [weak self] in
            guard let self, !self.finished else { return }
            let started = self.start()
            if started { self.owner?.helperStarts[id, default: []].append(Date()) }
            ExtensionLog.write("native host for \(place) started=\(started) pid=\(self.process?.processIdentifier ?? 0)")
            guard started else { self.finish(); return }
            waiting.forEach { self.write($0) }
            waiting = []
            self.pointAtAppIfWaiting(received: { received }, sent: { sent })
            self.keepBackgroundAwake()
        }
        let delay = delayBeforeStarting()
        if delay > 0 {
            ExtensionLog.write("native host for \(id) reconnecting quickly; starting in \(Int(delay))s")
            // Kept alive while it waits; the extension hanging up meanwhile ends it before a helper starts.
            Self.running[ObjectIdentifier(self)] = self
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { begin() }
        } else {
            begin()
        }
    }

    /// While the helper runs, its extension's background stays awake, as in Chrome.
    private func keepBackgroundAwake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepAwakeInterval) { [weak self] in
            guard let self, !self.finished, self.process != nil else { return }
            self.owner?.keepBackgroundAwake(self.extensionID)
            self.keepBackgroundAwake()
        }
    }

    /// No answer yet usually means the app is waiting on you in its own window (unlock, or allow Zigzag the
    /// first time). Keep the connection open, never cut it, and point at that window once, only when you just used
    /// the extension: a connect from its background on its own (start, wake, reconnect) never shows it.
    private func pointAtAppIfWaiting(received: @escaping () -> Int, sent: @escaping () -> Int, since: Date = Date(), again: Bool = false) {
        let id = extensionID
        DispatchQueue.main.asyncAfter(deadline: .now() + (again ? 1 : CompanionAppNotice.patience)) { [weak self] in
            guard let self, !self.finished, !self.pointedAtApp, received() == 0, self.process?.isRunning == true else { return }
            if !again { ExtensionLog.write("native host for \(id) waiting on the app after \(sent()) sent") }
            guard id == ExtensionStore.onePasswordID else { return }
            self.owner?.windowForAppNotice(id, waitingSince: since) { [weak self] controller in
                guard let self, !self.finished, !self.pointedAtApp, received() == 0 else { return }
                self.pointedAtApp = true
                self.pointAtApp(in: controller)
            }
            // Checked again each second while it waits, for a use that comes later.
            self.pointAtAppIfWaiting(received: received, sent: sent, since: since, again: true)
        }
    }

    private func pointAtApp(in controller: BrowserWindowController) {
        ExtensionLog.write("native host for \(extensionID) pointing at the app after a use")
        Toast.show(String(localized: "1Password is waiting for you in its app. Unlock it, or allow Zigzag if it asks.", comment: "Toast when the 1Password extension waits on the 1Password app."),
                   symbol: "lock.open", action: (String(localized: "Open 1Password", comment: "Button that opens the 1Password app. 1Password is a product name."), {
                       if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                           NSWorkspace.shared.openApplication(at: app, configuration: .init())
                       }
                   }), duration: 10, in: controller)
    }
}

/// A few lines about extensions, in every build, for finding out why one isn't working: what was clicked, whether
/// a popup opened, how many messages a companion app sent. Never what any message said.
enum ExtensionLog {
    /// Written off the main thread, one line at a time, so a chatty extension never stalls the app or wakes the disk.
    nonisolated private static let queue = DispatchQueue(label: "app.zigzag.extension-log", qos: .utility)
    /// The last line and how often it's been said in a row: a line repeating within a minute is written once.
    nonisolated(unsafe) private static var last: (line: String, at: Date)?
    /// The file stays small: past this size it starts over.
    nonisolated private static let limit = 1_000_000
    /// Max line length. Lines include extension-supplied text, so cap it to keep one from filling the log or faking lines.
    nonisolated static let lineLimit = 500

    /// One line, control characters as spaces, cut at `lineLimit`.
    nonisolated static func entry(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        // Count as we go: String's scalar count walks from the start each time.
        var count = 0
        for scalar in line.unicodeScalars {
            guard count < lineLimit else { return String(scalars) + "…" }
            count += 1
            scalars.append(scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : scalar)
        }
        return String(scalars)
    }

    nonisolated static func write(_ line: String) {
        let line = entry(line)
        let now = Date()
        queue.async {
            if let last, last.line == line, now.timeIntervalSince(last.at) < 60 { return }
            last = (line, now)
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Library/Logs/Zigzag Dev" : "Library/Logs/Zigzag", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("extensions.log")
            let text = Data("\(now) \(line)\n".utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size < limit, let handle = try? FileHandle(forWritingTo: url) {
                // The throwing calls: the old ones raise an exception a full disk can't recover from.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: text)
                try? handle.close()
            } else {
                try? text.write(to: url)
            }
        }
    }
}

/// Debug builds write a plain log next to the app's data; release builds stay silent.
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "\(Date()) \(message())\n"
    let url = Paths.support.appendingPathComponent("debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}
