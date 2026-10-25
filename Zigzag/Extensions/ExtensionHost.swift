import AppKit
import WebKit
import os

/// Runs browser extensions with WebKit's extension engine: Chrome Web Store extensions, and 1Password
/// set up for you, so they work the way they do in other browsers.
@available(macOS 15.4, *)
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    /// Fires when extensions load or their toolbar actions change.
    let changed = Signal<Void>()
    private var nativePorts: [ObjectIdentifier: NativeMessagingHost] = [:]

    private override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "6F1E2D6A-5B0C-4C1B-9E1A-2A7B5D3C9E10")!)
        // Extensions here are Chrome Web Store builds, and several choose their code path from the user agent:
        // told "Safari", they take a Safari branch that expects Safari's own plumbing and stops. Their own pages
        // and backgrounds say what they were built for; web pages are unaffected.
        configuration.webViewConfiguration.applicationNameForUserAgent = "Chrome/140.0.0.0 Safari/537.36"
        // Profiles' page preludes reach every extension page through the shared configuration; each runs only on
        // its own extension's pages, before their scripts.
        for (id, source) in ExtensionProfile.pagePreludes {
            let guarded = "if (location.host === '\(id)') {\n\(source)\n}"
            configuration.webViewConfiguration.userContentController.addUserScript(
                WKUserScript(source: guarded, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: Loading

    /// Every installed extension, on or off, for Settings. Filled in as they are read at launch.
    private(set) var installed: [String: WKWebExtension] = [:]

    /// Loads every installed extension that's turned on, and reads the rest for Settings. Safe to call again:
    /// what's already loaded stays as it is.
    func loadInstalled() async {
        for id in ExtensionStore.installedIDs {
            if ExtensionStore.isEnabled(id) {
                await load(id)
            } else if installed[id] == nil, let dir = ExtensionStore.packageDirectory(for: id),
                      let ext = try? await WKWebExtension(resourceBaseURL: dir) {
                installed[id] = ext
                changed.send()
            }
        }
    }

    func context(for id: String) -> WKWebExtensionContext? { contexts.first { $0.uniqueIdentifier == id } }

    /// Stops an extension: its buttons, scripts and background page go away.
    func unload(_ id: String) {
        guard let context = context(for: id) else { return }
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        changed.send()
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
        guard let directory = ExtensionStore.loadDirectory(for: id) else { return nil }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: directory)
            installed[id] = ext
            let context = WKWebExtensionContext(for: ext)
            // The store ID, so runtime.id matches Chrome's and storage persists across launches.
            context.uniqueIdentifier = id
            // A fixed address, so its pages (settings, dashboards) still open after a relaunch.
            if let base = URL(string: "webkit-extension://\(id)/") { context.baseURL = base }
            context.unsupportedAPIs = ExtensionProfile.profile(for: id)?.unsupportedAPIs ?? []
            #if DEBUG
            context.isInspectable = true
            #endif
            restoreGrants(for: context, extension: ext)
            try controller.load(context)
            contexts.append(context)
            announceExistingWindows(to: context)
            changed.send()
            context.loadBackgroundContent { _ in }
            return context
        } catch {
            debugLog("Extension \(id) failed to load: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Permissions

    /// Grants what the person approved. Until the install sheet exists, installing approves what the
    /// extension asks for; that approval is recorded once and restored from then on.
    private func restoreGrants(for context: WKWebExtensionContext, extension ext: WKWebExtension) {
        let state = ExtensionStore.state(context.uniqueIdentifier)
        let permissions = state?.grantedPermissions.map { Set($0.map(WKWebExtension.Permission.init(rawValue:))) } ?? ext.requestedPermissions
        let patterns = state?.grantedMatchPatterns.map { Set($0.compactMap { try? WKWebExtension.MatchPattern(string: $0) }) } ?? ext.allRequestedMatchPatterns
        for permission in permissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in patterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        if state?.grantedPermissions == nil { saveGrants(of: context) }
        applySiteAccess(to: context)
    }

    // MARK: Site access

    func applySiteAccess(_ id: String) {
        guard let context = context(for: id) else { return }
        applySiteAccess(to: context)
        changed.send()
    }

    /// Turns the approved site patterns into what the person chose: every approved site, only sites they
    /// clicked the extension on, or only sites they listed. Sites where extensions are off are denied to all.
    private func applySiteAccess(to context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let approved = (ExtensionStore.state(id)?.grantedMatchPatterns ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        let access = ExtensionStore.siteAccess(id)
        // Forget earlier decisions first (clearing one pattern can clear an overlapping one), then make the current ones.
        for pattern in context.grantedPermissionMatchPatterns.keys { context.setPermissionStatus(.unknown, for: pattern) }
        for pattern in context.deniedPermissionMatchPatterns.keys { context.setPermissionStatus(.unknown, for: pattern) }
        if access == .all {
            for pattern in approved { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        } else {
            for site in ExtensionStore.accessSites(id) {
                for pattern in Self.patterns(for: site) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            }
        }
        for site in ExtensionStore.extensionsOffSites {
            for pattern in Self.patterns(for: site) { context.setPermissionStatus(.deniedExplicitly, for: pattern) }
        }
    }

    /// A site and its subdomains, over http and https.
    static func patterns(for site: String) -> [WKWebExtension.MatchPattern] {
        ["*://\(site)/*", "*://*.\(site)/*"].compactMap { try? WKWebExtension.MatchPattern(string: $0) }
    }

    fileprivate func saveGrants(of context: WKWebExtensionContext) {
        let permissions = context.grantedPermissions.keys.map(\.rawValue).sorted()
        // Per-site grants come from site access, not approval; only an "all sites" extension's grants are its approvals.
        guard ExtensionStore.siteAccess(context.uniqueIdentifier) == .all || ExtensionStore.state(context.uniqueIdentifier)?.grantedMatchPatterns == nil else {
            ExtensionStore.update(context.uniqueIdentifier) { $0.grantedPermissions = permissions }
            return
        }
        let patterns = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        ExtensionStore.update(context.uniqueIdentifier) {
            $0.grantedPermissions = permissions
            $0.grantedMatchPatterns = patterns
        }
    }

    private func announceExistingWindows(to context: WKWebExtensionContext) {
        for window in WindowManager.shared.controllers {
            controller.didOpenWindow(window)
            for tab in window.tabManager.allTabs { controller.didOpenTab(tab) }
        }
        if let key = WindowManager.shared.keyController { controller.didFocusWindow(key) }
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

    func actions(for tab: Tab?) -> [ActionItem] {
        contexts.compactMap { context in
            guard let action = context.action(for: tab) else { return nil }
            return ActionItem(context: context, icon: action.icon(for: NSSize(width: 16, height: 16)), label: action.label,
                              badge: action.badgeText, attention: attention[context.uniqueIdentifier])
        }
    }

    /// Extension items for a page's right-click menu.
    func menuItems(for tab: Tab) -> [NSMenuItem] {
        contexts.flatMap { $0.menuItems(for: tab) }
    }

    private weak var actionAnchor: NSView?
    private static var toldAboutVerification = false
    private var popupShownAt: Date?
    static let log = Logger(subsystem: "wang.zigao.zigzag", category: "extensions")
    weak var lastAction: WKWebExtension.Action?

    func performAction(_ item: ActionItem, tab: Tab?, anchor: NSView) {
        var anchor = anchor
        // From the site panel: the panel steps aside and the popup opens from the address bar, where it stays put.
        var inPanel: NSView? = anchor.superview
        while let view = inPanel, !(view is SitePanel) { inPanel = view.superview }
        if let panel = inPanel as? SitePanel, let controller = WindowManager.shared.controllers.first(where: { $0.window === anchor.window }) {
            panel.close()
            anchor = controller.sidebar.address
        }
        actionAnchor = anchor
        // Its own popup always opens; if it still needs a step only you can do (1Password trusting Zigzag), a
        // short note says so, with the way there.
        if let attention = item.attention, let controller = WindowManager.shared.controllers.first(where: { $0.window === anchor.window }) {
            let open: (title: String, run: () -> Void)? = attention.appBundleID.map { id in
                (attention.buttonTitle, {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                })
            }
            Toast.show("\(attention.title): in its settings, choose Browser, then Add Browser.", symbol: "exclamationmark.circle",
                       action: open, duration: 6, in: controller)
        }
        // "When you click it": clicking gives it this site from now on.
        if ExtensionStore.siteAccess(item.id) == .click, let site = ContentBlocker.site(of: tab?.url),
           !ExtensionStore.accessSites(item.id).contains(site) {
            ExtensionStore.setSiteAccess(item.id, .click, sites: ExtensionStore.accessSites(item.id) + [site])
            tab?.reload()
        }
        // A click always does something: if the extension shows no popup and opens no page, its own options
        // (or, for 1Password, its setup) page opens instead.
        popupShownAt = nil
        let tabsBefore = WindowManager.shared.controllers.map(\.tabManager.allTabs.count).reduce(0, +)
        let context = item.context
        ExtensionLog.write("click \(context.webExtension.displayName ?? "?") popup=\(context.action(for: tab)?.presentsPopup ?? false)")
        context.performAction(for: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.popupShownAt == nil else { return }
            let tabsNow = WindowManager.shared.controllers.map(\.tabManager.allTabs.count).reduce(0, +)
            guard tabsNow == tabsBefore else { return }
            let fallback = context.uniqueIdentifier == ExtensionStore.onePasswordID || context.webExtension.displayName == "1Password"
                ? URL(string: "\(context.baseURL.absoluteString)app/app.html#/page/welcome")
                : context.optionsPageURL
            ExtensionLog.write("click did nothing; opening \(fallback?.absoluteString ?? "nothing")")
            guard let fallback, let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            controller.tabManager.newTab(url: fallback)
        }
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
    /// What a message is, never what it says: its field names, and the values of fields that name its kind.
    /// Used to follow 1Password's handshake without writing anything private down.
    static func shape(_ message: Any, depth: Int = 0) -> String {
        guard let dict = message as? [String: Any] else { return message is [Any] ? "[…]" : "·" }
        let kinds: Set<String> = ["type", "name", "command", "kind", "action", "status", "error"]
        let parts = dict.keys.sorted().map { key -> String in
            let value = dict[key]!
            if kinds.contains(key), let text = value as? String, text.count <= 60,
               text.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) { return "\(key)=\(text)" }
            if depth < 2, value is [String: Any] { return "\(key){\(shape(value, depth: depth + 1))}" }
            return key
        }
        return parts.joined(separator: " ")
    }

    fileprivate func nativeHostSent(_ message: Any, for id: String) {
        guard id == ExtensionStore.onePasswordID else { return }
        ExtensionLog.write("1Password extension sent \(Self.shape(message))")
    }

    fileprivate func nativeHostReplied(_ message: Any, for id: String) {
        guard id == ExtensionStore.onePasswordID else { return }
        let dict = message as? [String: Any]
        let inner = (dict?["content"] as? [String: Any])?["content"] as? [String: Any]
        guard let type = inner?["type"] as? String else {
            ExtensionLog.write("1Password app sent \(Self.shape(message))")
            return
        }
        ExtensionLog.write("1Password app replied: \(type)")
        // Turned away: say so where you're looking, once a session, instead of leaving 1Password's spinner going.
        if type == "BrowserVerificationFailed", !Self.toldAboutVerification,
           let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first {
            Self.toldAboutVerification = true
            Toast.show("1Password doesn’t trust Zigzag yet. In 1Password, open Settings › Browser, click Add Browser, and choose Zigzag in Applications.",
                       symbol: "exclamationmark.circle", action: ("Open 1Password", {
                           if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                               NSWorkspace.shared.openApplication(at: app, configuration: .init())
                           }
                       }), duration: 15, in: controller)
        }
        setAttention(type == "BrowserVerificationFailed" ? Attention(
            title: "Connect 1Password to Zigzag",
            message: "1. In 1Password, open Settings › Browser.\n2. Click Add Browser and choose Zigzag.\n3. Come back and click 1Password again.\n\n1Password only works with browsers it trusts, so this is a one-time step.",
            buttonTitle: "Open 1Password", appBundleID: "com.1password.1password") : nil, for: id)
    }

    /// An extension asked for its companion app, and that app isn't on this Mac.
    fileprivate func companionAppMissing(for context: WKWebExtensionContext) {
        let name = context.webExtension.displayName ?? "This extension"
        setAttention(Attention(
            title: "\(name) needs its app",
            message: "\(name) works together with an app on your Mac, and Zigzag couldn’t find it. Install the app, then reopen Zigzag.",
            buttonTitle: "OK", appBundleID: nil), for: context.uniqueIdentifier)
    }

    // MARK: Event fan-out from our model

    func tabOpened(_ tab: Tab) { controller.didOpenTab(tab) }
    func tabClosed(_ tab: Tab, windowClosing: Bool = false) { controller.didCloseTab(tab, windowIsClosing: windowClosing) }
    func tabActivated(_ tab: Tab, previous: Tab?) { controller.didActivateTab(tab, previousActiveTab: previous) }
    func tabChanged(_ tab: Tab, _ change: Tab.Change) {
        switch change {
        case .url: controller.didChangeTabProperties([.URL], for: tab)
        case .title: controller.didChangeTabProperties([.title], for: tab)
        case .loading: controller.didChangeTabProperties([.loading], for: tab)
        case .audio: controller.didChangeTabProperties([.playingAudio, .muted], for: tab)
        default: break
        }
    }
    func windowOpened(_ window: BrowserWindowController) { controller.didOpenWindow(window) }
    func windowClosed(_ window: BrowserWindowController) { controller.didCloseWindow(window) }
    func windowFocused(_ window: BrowserWindowController?) { controller.didFocusWindow(window) }

    /// Keyboard shortcuts declared by extensions (1Password's fill shortcut).
    func performCommand(for event: NSEvent) -> Bool {
        for context in contexts where context.performCommand(for: event) { return true }
        return false
    }
}

// MARK: - Controller delegate

@available(macOS 15.4, *)
extension ExtensionHost: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        WindowManager.shared.controllers
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        WindowManager.shared.keyController
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindowController) ?? WindowManager.shared.keyController ?? WindowManager.shared.newWindow(showCommandBar: false)
        let tab = window.tabManager.newTab(url: configuration.url, select: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = WindowManager.shared.newWindow(url: configuration.tabURLs.first, showCommandBar: false)
        for url in configuration.tabURLs.dropFirst() { window.tabManager.newTab(url: url, select: false) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL, let window = WindowManager.shared.keyController {
            window.tabManager.newTab(url: url, title: extensionContext.webExtension.displayName)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
        DispatchQueue.main.async { self.saveGrants(of: extensionContext) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler(urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
        DispatchQueue.main.async { self.saveGrants(of: extensionContext) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        changed.send()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        lastAction = action
        popupShownAt = Date()
        ExtensionLog.write("popup \(context.webExtension.displayName ?? "?") has=\(action.popupPopover != nil)")
        guard let popover = action.popupPopover else { completionHandler(nil); return }
        // Asked by the page (1Password's "Unlock" button) rather than a click: the button pressed last may be
        // gone with its panel, so the popup comes from the address bar instead of not at all.
        let pressed = actionAnchor.flatMap { $0.window != nil ? $0 : nil }
        let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first
        guard let anchor = pressed ?? controller?.sidebar.address, anchor.window != nil else {
            completionHandler(NSError(domain: "Zigzag", code: 2, userInfo: [NSLocalizedDescriptionKey: "No window to show the popup in"]))
            return
        }
        if pressed == nil { controller?.closeFloatingPanels() }
        popover.behavior = .semitransient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    // MARK: Native messaging (the extension talking to the 1Password app)

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let host = NativeMessagingHost(name: applicationIdentifier, context: extensionContext) else {
            companionAppMissing(for: extensionContext)
            replyHandler(nil, NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native host"]))
            return
        }
        host.sendOnce(message, reply: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let host = NativeMessagingHost(name: port.applicationIdentifier, context: extensionContext) else {
            companionAppMissing(for: extensionContext)
            completionHandler(NSError(domain: "Zigzag", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native host"]))
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
    private var windowController: BrowserWindowController? {
        WindowManager.shared.controllers.first { $0.tabManager.allTabs.contains { $0 === self } }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowController }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        windowController?.tabManager.navigableTabs.firstIndex { $0 === self } ?? 0
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { windowController?.tabManager.selectedTab === self }
    func isPinned(for context: WKWebExtensionContext) -> Bool { bookmarkID != nil }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        windowController?.tabManager.select(self)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        windowController?.tabManager.close(self)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        fromOrigin ? reloadFromOrigin() : reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack(); completionHandler(nil)
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
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabManager.navigableTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabManager.selectedTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
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
@available(macOS 15.4, *)
final class NativeMessagingHost {
    private let executable: URL
    private let origin: String
    private static var pointedAtApp = false
    private let extensionID: String
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    init?(name: String?, context: WKWebExtensionContext) {
        guard let name, let manifest = Self.manifest(named: name),
              let path = manifest["path"] as? String else { return nil }
        executable = URL(fileURLWithPath: path)
        // Hosts only talk to the extension IDs they list; we present the extension's Chrome ID.
        let allowed = (manifest["allowed_origins"] as? [String]) ?? []
        let id = context.uniqueIdentifier
        extensionID = id
        origin = allowed.first { $0.contains(id) } ?? "chrome-extension://\(id)/"
    }

    static func manifest(named name: String) -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts")]
        for dir in dirs {
            let file = dir.appendingPathComponent("\(name).json")
            if let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    private func start(onMessage: @escaping @MainActor (Any) -> Void, onExit: @escaping @MainActor () -> Void) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = [origin]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                guard let self else { return }
                if data.isEmpty { return }
                self.buffer.append(data)
                for message in self.drainMessages() { onMessage(message) }
                }
            }
        }
        process.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } } }
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        return true
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

    func sendOnce(_ message: Any, reply: @escaping (Any?, (any Error)?) -> Void) {
        let id = extensionID
        ExtensionLog.write("native message for \(id)")
        var replied = false
        let started = start(onMessage: { [weak self] response in
            guard !replied else { return }
            replied = true
            ExtensionHost.shared.nativeHostReplied(response, for: id)
            reply(response, nil)
            self?.process?.terminate()
        }, onExit: {
            if !replied { replied = true; reply(nil, nil) }
        })
        if started { write(message) } else { reply(nil, NSError(domain: "Zigzag", code: 2)) }
    }

    func connect(_ port: WKWebExtension.MessagePort, onClose: @escaping () -> Void) {
        let id = extensionID
        var received = 0
        var sent = 0
        let started = start(onMessage: { message in
            received += 1
            ExtensionHost.shared.nativeHostReplied(message, for: id)
            port.sendMessage(message, completionHandler: nil)
        }, onExit: {
            ExtensionLog.write("native host for \(id) exited after \(sent) sent, \(received) received")
            port.disconnect()
            onClose()
        })
        ExtensionLog.write("native host for \(id) started=\(started)")
        // No answer yet usually means the app is waiting on you in its own window (unlock, or allow Zigzag the
        // first time). Keep the connection open, never cut it, and point at that window once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, received == 0, self.process?.isRunning == true else { return }
            ExtensionLog.write("native host for \(id) waiting on the app after \(sent) sent")
            guard id == ExtensionStore.onePasswordID, !Self.pointedAtApp,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            Self.pointedAtApp = true
            Toast.show("1Password is waiting for you in its app. Unlock it, or allow Zigzag if it asks.",
                       symbol: "lock.open", action: ("Open 1Password", {
                           if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                               NSWorkspace.shared.openApplication(at: app, configuration: .init())
                           }
                       }), duration: 10, in: controller)
        }
        guard started else { port.disconnect(); onClose(); return }
        port.messageHandler = { [weak self] message, _ in
            sent += 1
            ExtensionHost.shared.nativeHostSent(message, for: id)
            self?.write(message)
        }
        port.disconnectHandler = { [weak self] _ in
            self?.process?.terminate()
            onClose()
        }
    }
}

/// A few lines about extensions, in every build, for finding out why one isn't working: what was clicked, whether
/// a popup opened, how many messages a companion app sent. Never what any message said.
enum ExtensionLog {
    nonisolated static func write(_ line: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Library/Logs/Zigzag Dev" : "Library/Logs/Zigzag", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("extensions.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// Debug builds write a plain log next to the app's data; release builds stay silent.
func debugLog(_ message: String) {
    #if DEBUG
    let line = "\(Date()) \(message)\n"
    let url = Paths.support.appendingPathComponent("debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}

/// Explains the one step only the person can do, like telling 1Password to trust Zigzag. Opened from the site
/// panel it takes that panel's place, so there's still one panel on screen.
@available(macOS 15.4, *)
enum AttentionHint {
    private static weak var current: FloatingPanelView?

    static func show(_ attention: ExtensionHost.Attention, icon: NSImage? = nil, below anchor: NSView, in controller: BrowserWindowController) {
        current?.dismiss()
        let overlay = controller.root.overlay
        // The panel the anchor sits in, if any: the hint replaces what it shows.
        var host: NSView? = anchor.superview
        while let view = host, !(view is FloatingPanelView) { host = view.superview }
        let panel = (host as? FloatingPanelView) ?? FloatingPanelView()
        let reusing = host != nil
        panel.removeContent()

        let width: CGFloat = reusing ? panel.frame.width : 300
        let pad = Tokens.Space.x5
        let inner = width - pad * 2
        var y = pad

        if let icon {
            let image = NSImageView(image: icon)
            image.frame = NSRect(x: pad, y: y, width: 32, height: 32)
            panel.addSubview(image)
            y = image.frame.maxY + Tokens.Space.x3
        }
        let title = NSTextField(wrappingLabelWithString: "")
        title.attributedStringValue = Brand.display(attention.title, size: 17, color: Tokens.Color.textPrimary, wraps: true)
        title.isSelectable = false
        let titleHeight = ceil(title.sizeThatFits(NSSize(width: inner, height: 200)).height)
        title.frame = NSRect(x: pad, y: y, width: inner, height: titleHeight)
        panel.addSubview(title)
        y = title.frame.maxY + Tokens.Space.x4

        // "1. Do this" lines become numbered steps; anything else is a note under them.
        let lines = attention.message.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var note: [String] = []
        var number = 0
        for line in lines {
            guard let dot = line.firstIndex(of: "."), Int(line[..<dot]) != nil else { note.append(line); continue }
            number += 1
            let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            let badge = ColorView(color: Tokens.Color.accent.withAlphaComponent(0.16))
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 10
            let digit = Label("\(number)", font: Tokens.Font.small(.semibold), color: Tokens.Color.accent)
            digit.alignment = .center
            badge.addSubview(digit)
            let body = NSTextField(wrappingLabelWithString: text)
            body.font = Tokens.Font.body()
            body.textColor = Tokens.Color.textPrimary
            body.isSelectable = false
            let textX = pad + 20 + Tokens.Space.x3
            let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width - textX - pad, height: 200)).height)
            badge.frame = NSRect(x: pad, y: y, width: 20, height: 20)
            digit.frame = NSRect(x: 0, y: (20 - digit.lineHeight) / 2, width: 20, height: digit.lineHeight)
            body.frame = NSRect(x: textX, y: y + 1, width: width - textX - pad, height: bodyHeight)
            panel.addSubview(badge)
            panel.addSubview(body)
            y = max(badge.frame.maxY, body.frame.maxY) + Tokens.Space.x3
        }
        if !note.isEmpty {
            let body = NSTextField(wrappingLabelWithString: note.joined(separator: " "))
            body.font = Tokens.Font.small()
            body.textColor = Tokens.Color.textSecondary
            body.isSelectable = false
            let h = ceil(body.sizeThatFits(NSSize(width: inner, height: 200)).height)
            body.frame = NSRect(x: pad, y: y + Tokens.Space.x1, width: inner, height: h)
            panel.addSubview(body)
            y = body.frame.maxY + Tokens.Space.x5
        }

        let open = PrimaryButton(title: attention.buttonTitle)
        open.frame = NSRect(x: pad, y: y, width: inner, height: Tokens.Space.x8)
        panel.addSubview(open)
        y = open.frame.maxY + pad
        open.onClick = { _ in
            if let bundleID = attention.appBundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            if reusing, let site = panel as? SitePanel { site.close() } else { panel.dismiss() }
        }

        if reusing {
            Tokens.Motion.withoutAnimation { panel.frame.size.height = y }
            // A quick fade between what the panel showed and the hint.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            panel.layer?.add(fade, forKey: "content")
            return
        }
        let anchorFrame = anchor.convert(anchor.bounds, to: overlay)
        panel.frame = NSRect(x: max(Tokens.Metric.cardInset, anchorFrame.maxX - width), y: anchorFrame.maxY + Tokens.Space.x2, width: width, height: y)
        overlay.addSubview(panel)
        panel.present(arrival: .fade)
        current = panel
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { if let m = monitor { NSEvent.removeMonitor(m) }; return event }
            let inside = panel.bounds.contains(panel.convert(event.locationInWindow, from: nil))
            if event.type == .keyDown && event.keyCode == 53 || event.type == .leftMouseDown && !inside {
                panel.dismiss()
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
            return event
        }
    }
}
