import AppKit
import WebKit

/// Zigzag Mini: one page in a small, quiet window of its own, with no sidebar, for a link from another app or a
/// quick look-up. It wears its space as a browser window does (the same color, the same page card in a thin frame of
/// it), with a slim strip on top: the space, the page's site, Copy Link and Open in. Its page is a real tab, so
/// history, blocking, autofill and extensions work as they do anywhere; Open in moves that same live page into a
/// browser window, in the space chosen on the strip. It's never saved: quitting lets it go, as Arc did.
final class MiniWindowController: NSWindowController, NSWindowDelegate {
    /// Open ones, oldest first, for placing the next one and for extensions.
    private(set) static var all: [MiniWindowController] = []
    /// The one you're in, if any.
    static var key: MiniWindowController? { all.first { $0.window?.isKeyWindow == true } }

    /// What the feature is called wherever Zigzag names it.
    static var name: String { String(localized: "Zigzag Mini", comment: "The name of Zigzag's small window for one page, without the sidebar (Arc called it Little Arc). Kept in Latin letters, like the app's name.") }

    let tab: Tab
    private let root = MiniRootView()
    private var strip: MiniStripView { root.strip }
    /// Where floating things go over the page: the link under the pointer, a site's question, a toast.
    var overlay: PassthroughView { root.overlay }
    private lazy var linkStatus = LinkStatusController(overlay: overlay)
    /// ⌘L: the browser window's own command bar, over the page's site.
    private lazy var commandBar = CommandBarController(host: self)
    private var tokens: [SignalToken] = []
    /// The page went into a browser window: closing this one must leave it alone.
    private var movedOut = false
    /// Sent once the page has left (into a browser window, or closed with the window), so questions over it go too.
    private let pageGone = Signal<Void>()
    private var isClosing = false
    /// Fading away before it closes or moves into Zigzag: nothing more to do in it.
    private var isLeaving = false

    /// Settings › Zigzag Mini: links from other apps open here instead of in a tab. Off unless you turn it on.
    static var opensExternalLinks: Bool {
        get { UserDefaults.standard.bool(forKey: "OpensExternalLinksInMini") }
        set { UserDefaults.standard.set(newValue, forKey: "OpensExternalLinksInMini") }
    }

    /// Whether a page another app hands over goes to Zigzag Mini: only web links, only with the setting on, and
    /// never before onboarding is done, whose first window is where you start.
    nonisolated static func takes(_ url: URL, settingOn: Bool, needsOnboarding: Bool) -> Bool {
        settingOn && !needsOnboarding && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Opens one on `url`. `origin`: where on screen it grows from (the quick open bar it came out of); without
    /// one it takes the middle of the screen, a step down from any already there.
    @discardableResult
    static func open(url: URL, isSearch: Bool = false, from origin: NSRect? = nil, overFullScreen: Bool? = nil, fromAnotherApp: Bool = false) -> MiniWindowController {
        let controller = MiniWindowController(url: url, origin: origin, overFullScreen: overFullScreen ?? (NSApp.keyWindow?.styleMask.contains(.fullScreen) == true))
        controller.tab.isSearchTab = isSearch
        all.append(controller)
        Diagnostics.note("Zigzag Mini opened", site: url.host())
        controller.appear(from: origin)
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniOpened(controller) }
        if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        if fromAnotherApp {
            // From a link in another app, as Little Arc: only this window comes forward, the browser windows stay
            // where they were, and closing it goes back to the app the link came from.
            controller.returnTo = AppSwitching.lastOtherApp
            if !NSApp.isActive { NSRunningApplication.current.activate(options: []) }
            MiniLinkWake.linkOpenedInMini()
        }
        return controller
    }

    /// The app a link came from, to go back to when this closes, if you're still only here.
    private var returnTo: NSRunningApplication?

    private init(url: URL, origin: NSRect?, overFullScreen: Bool) {
        let spaceID = MiniQuickOpen.space.id
        tab = Tab(url: url, spaceID: spaceID)
        // Zigzag's own PDF viewer and Back to the page that opened it belong to a browser window's tabs; here the page
        // is shown as in peek, and becomes a full tab once it moves.
        tab.isPeek = true
        let screen = origin.flatMap { o in NSScreen.screens.first { $0.frame.intersects(o) } } ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let size = Tokens.Metric.miniWindowSize
        let frame = origin.map { Self.frame(size: size, under: $0, in: area) }
            ?? Self.frame(size: size, in: area, taken: Self.all.compactMap { $0.window?.frame })

        let window = BrowserWindow(contentRect: frame)
        window.minSize = Tokens.Metric.miniWindowMinSize
        window.collectionBehavior.remove(.fullScreenPrimary)
        // Opened over a full-screen window, it stays there in the same Space instead of opening off in another one.
        if overFullScreen { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.eventInterceptor = { [weak self] event in self?.noteEscape(event) ?? false }
        window.setAccessibilityTitle(Self.name)

        strip.openButton.onClick = { [weak self] _ in self?.openInZigzag() }
        strip.title.onClick = { [weak self] _ in self?.openLocation(nil) }
        strip.copyButton.onClick = { [weak self] _ in self?.copyPageURL(nil) }
        strip.spaceChip.onClick = { [weak self] _ in self?.showSpaceMenu() }
        root.card.showLoading(of: tab)

        tab.host = self
        tokens.append(tab.changed.observe { [weak self] change in self?.tabChanged(change) })
        // The space's color or name changed, or the space went: the window follows, as a browser window does.
        tokens.append(Library.shared.changed.observe { [weak self] in
            self?.paint(animated: true)
            self?.refreshStrip()
        })
        // A shortcut changed in Settings: the button says the new one.
        tokens.append(Shortcuts.changed.observe { [weak self] in self?.refreshStrip() })
        paint(animated: false)
        showPage()
        refreshStrip()
        window.trafficLightOrigin = NSPoint(x: Tokens.Sidebar.lightsX, y: round((Tokens.Metric.miniStripHeight - window.trafficLightHeight) / 2))
        strip.trafficLightsWidth = window.trafficLightsWidth
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where a new one goes: its size, cut to fit, centered on the screen's usable area. One already at that spot
    /// moves it a step down and right, and so on, the way a Mac cascades windows; past the screen's edge it goes back
    /// to the middle.
    static func frame(size: NSSize, in area: NSRect, taken: [NSRect]) -> NSRect {
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let center = NSRect(x: round(area.midX - size.width / 2), y: round(area.midY - size.height / 2), width: size.width, height: size.height)
        let step = Tokens.Space.x6
        var frame = center
        func isTaken(_ frame: NSRect) -> Bool {
            taken.contains { abs($0.minX - frame.minX) < 2 && abs($0.maxY - frame.maxY) < 2 }
        }
        while isTaken(frame) {
            frame = frame.offsetBy(dx: step, dy: -step)
            guard area.contains(frame) else { return center }
        }
        return frame
    }

    /// Where one opened from the quick open bar goes: centered under the bar, its top where the bar's was, inside the
    /// screen's usable area.
    static func frame(size: NSSize, under bar: NSRect, in area: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let x = min(max(area.minX, round(bar.midX - size.width / 2)), area.maxX - size.width)
        let y = min(max(area.minY, bar.maxY - size.height), area.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The space it wears and Open in moves its page to: the one you were in as it opened, or the one chosen on the
    /// strip; the first one if that space has gone.
    var space: SpaceInfo { Library.shared.space(tab.spaceID) ?? Library.shared.spaces[0] }

    private func paint(animated: Bool) {
        root.paint(space, isPrivate: false, animated: animated)
        strip.refreshColors()
    }

    /// The spaces, from the strip's space: the one chosen is where Open in takes the page, and the window wears it.
    private func showSpaceMenu() {
        guard !isLeaving else { return }
        let current = space.id
        let entries: [MenuPanel.Entry] = Library.shared.spaces.map { other in
            let symbol = other.icon.flatMap { IconChoice.isSymbol($0) ? $0 : nil }
            let image = symbol == nil ? MiniSpaceChip.picture(of: other, size: DropdownButton.iconSide) : nil
            return .item(.init(title: other.name, image: image, symbol: symbol, isChecked: other.id == current) { [weak self] in
                self?.choose(space: other.id)
            })
        }
        strip.spaceChip.isSelected = true
        MenuPanel.show(entries, from: strip.spaceChip) { [weak self] in self?.strip.spaceChip.isSelected = false }
    }

    private func choose(space id: UUID) {
        guard id != tab.spaceID, Library.shared.space(id) != nil else { return }
        tab.spaceID = id
        paint(animated: true)
        refreshStrip()
    }

    // MARK: Coming and going

    /// Fades in at the window server while its content grows the last few percent toward you, out of the bar it came
    /// from or its own top middle. With Reduce Motion it only fades.
    private func appear(from origin: NSRect?) {
        guard let window else { return }
        window.alphaValue = 0
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.menuIn * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 1
        }
        guard !Tokens.Motion.reduceMotion, let layer = root.layer else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuFrom, of: layer, around: CGPoint(x: 0.5, y: 0), flipped: false))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.menuIn * Tokens.Motion.debugSlowdown
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "appear")
    }

    /// The one way it leaves, closing or moving into Zigzag: a quick fade as it eases a touch smaller, quieter than
    /// it came.
    private func fadeAway(then done: @escaping () -> Void) {
        guard let window else { done(); return }
        isLeaving = true
        if !Tokens.Motion.reduceMotion, let layer = root.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: Tokens.Motion.scale(Tokens.Motion.menuOutScale, of: layer, flipped: false))
            shrink.duration = Tokens.Motion.menuOut * Tokens.Motion.debugSlowdown
            shrink.timingFunction = Tokens.Motion.easeOut
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "leave")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.menuOut * Tokens.Motion.debugSlowdown
            context.timingFunction = Tokens.Motion.easeOut
            window.animator().alphaValue = 0
        }, completionHandler: done)
    }

    // MARK: The page

    private func showPage() {
        root.card.show(tab.ensureWebView())
        root.card.hidePlaceholder()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .loading, .title, .favicon, .webView:
            refreshStrip()
            window?.title = tab.displayTitle
            // A new web view (the page crashed and came back, or crossed into an extension's page) takes the old one's place.
            if change == .webView, tab.webView != nil, !movedOut { showPage() }
        default: break
        }
    }

    /// "Open in Work": what the button and ⌘O's menu item say, with the space the page goes to.
    private var openTitle: String {
        String(localized: "Open in \(space.name)", comment: "The button in Zigzag Mini's top strip, and the File menu item in place of Open File… while it's in front: moves its page into a browser window as a tab, in this space. The placeholder is the space's name.")
    }

    private func refreshStrip() {
        strip.title.show(tab)
        strip.spaceChip.show(space)
        strip.openButton.show(openTitle, keys: Shortcuts.keys(for: #selector(openDocument(_:))))
        strip.openButton.isEnabled = tab.url != nil
        strip.copyButton.isEnabled = tab.url != nil
        strip.needsLayout = true
    }

    // MARK: Typing an address

    /// ⌘L: the command bar over the page's site, the address in it to change; again, it goes.
    @objc func openLocation(_ sender: Any?) {
        guard !isLeaving else { return }
        if commandBar.isVisible { commandBar.dismiss(); return }
        commandBar.show(mode: .editCurrent)
    }

    /// Esc puts Zigzag Mini away, as it does Spotlight or Quick Look: it's there for a quick look. Only an Esc the page
    /// left alone gets here, and the command bar and Zigzag's questions over the page take their own. It stays when the
    /// page has a dialog of its own open (many close on Esc without telling WebKit they took it), and in a field you're
    /// typing in, also inside a frame or a web component, the first Esc only leaves the field, so a half-written reply
    /// never goes on a stray key.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        escape()
    }

    override func cancelOperation(_ sender: Any?) { escape() }

    private func escape() {
        guard !isLeaving, !commandBar.isVisible, !overlay.subviews.contains(where: { $0 is PermissionPrompt || $0 is SavePasswordPrompt }) else { return }
        guard let webView = tab.webView, let focused = window?.firstResponder as? NSView, focused.isDescendant(of: webView) else {
            window?.performClose(nil)
            return
        }
        // What the page was doing as Esc arrived (noted before the page saw it, in `noteEscape`), since by now its
        // handler may have closed its dialog. Typing: the field lets go of the focus, and the window stays.
        let decide = """
            (() => {
              const was = window.__zigzagEsc ?? (\(Self.escapeState));
              delete window.__zigzagEsc;
              if (was === 'typing') {
                let e = document.activeElement;
                while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
                e?.blur();
              }
              return was;
            })()
            """
        webView.evaluateJavaScript(decide) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard (result as? String) == "" else { return }
                self?.window?.performClose(nil)
            }
        }
    }

    /// Whether the page is in the middle of something Esc shouldn't end: "typing" in a field (inside a frame or a web
    /// component too), "dialog" with one of its own dialogs open, or "" when it's just a page.
    private static let escapeState = """
        (() => {
          let e = document.activeElement;
          while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
          if (e && (e.isContentEditable || /^(input|textarea|select|iframe)$/i.test(e.tagName))) return 'typing';
          return document.querySelector('dialog[open], [aria-modal="true"]') ? 'dialog' : '';
        })()
        """

    /// Called as Esc comes in, before the page gets it: WebKit runs this script ahead of the key, so the note says
    /// what the page looked like before its own Esc handler ran.
    private func noteEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, !commandBar.isVisible, let webView = tab.webView,
              let focused = window?.firstResponder as? NSView, focused.isDescendant(of: webView) else { return false }
        webView.evaluateJavaScript("window.__zigzagEsc = \(Self.escapeState)", completionHandler: nil)
        return false
    }

    #if DEBUG
    func debugEnter(_ text: String) {
        if !commandBar.isVisible { commandBar.show(mode: .editCurrent) }
        commandBar.debugType(text)
        commandBar.debugEnter()
    }

    /// minibar [text]: the command bar over the page, with this typed in it.
    func debugBar(_ text: String) {
        if !commandBar.isVisible { commandBar.show(mode: .editCurrent) }
        if !text.isEmpty { commandBar.debugType(text) }
    }

    /// minispace [name]: the strip's space menu, or that space chosen from it.
    func debugSpace(_ name: String) {
        if let id = Library.shared.spaces.first(where: { $0.name == name })?.id { choose(space: id) } else { showSpaceMenu() }
    }

    func debugEscape() {
        if commandBar.isVisible { commandBar.debugEscape() } else { cancelOperation(nil) }
    }

    var debugState: [String: Any] {
        ["editing": commandBar.isVisible, "titleShown": !strip.title.isHidden, "title": strip.title.text,
         "space": space.name, "open": strip.openButton.title, "openEnabled": strip.openButton.isEnabled, "webViewHere": tab.webView?.window === window, "movedOut": movedOut,
         "loading": tab.isLoading, "alpha": window?.alphaValue ?? 0,
         "fullScreenAuxiliary": window?.collectionBehavior.contains(.fullScreenAuxiliary) == true, "glass": root.debugGlass]
    }
    #endif

    // MARK: Moving into Zigzag

    /// The browser window this one's pages go to: the front everyday window, else the session brought back, else a
    /// new one. Never a private window: Zigzag Mini isn't private.
    static func browserWindow() -> BrowserWindowController {
        let manager = WindowManager.shared
        let key = manager.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        return key ?? manager.controllers.last { !$0.tabManager.isPrivate } ?? manager.restoreIfNoWindows()
            ?? manager.newWindow(showCommandBar: false)
    }

    /// Moves the page, live, into a browser window as its selected tab, in the space chosen on the strip: this window
    /// fades away first, then the page is there.
    @objc func openInZigzag(_ sender: Any? = nil) {
        guard tab.url != nil, !movedOut, !isLeaving else { return }
        commandBar.dismiss(restoringFocus: false)
        linkStatus.hide()
        fadeAway { [weak self] in self?.moveIntoZigzag() }
    }

    private func moveIntoZigzag() {
        let target = Self.browserWindow()
        let spaceID = space.id
        movedOut = true
        pageGone.send()
        tokens.removeAll()
        Autofill.shared.forget(windowOf: window)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        tab.webView?.removeFromSuperview()
        tab.isPeek = false
        target.tabManager.switchToSpace(spaceID)
        target.tabManager.insertAsNewTab(tab)
        window?.close()
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘O, as in Arc: Open File… becomes Open in (the space) while this window is in front.
    @objc func openDocument(_ sender: Any?) { openInZigzag(sender) }

    /// The strip's Copy Link, and ⇧⌘C: the page's address, with the toast a browser window shows.
    @objc func copyPageURL(_ sender: Any?) {
        guard let url = tab.url, !isLeaving else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
    }

    // MARK: Menu commands while it's in front

    /// ⌘W closes the page, and with it the window: it holds nothing else.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
    @objc func goBack(_ sender: Any?) { tab.goBack() }
    @objc func goForward(_ sender: Any?) { tab.goForward() }
    @objc func reloadPage(_ sender: Any?) { tab.reload() }
    @objc func reloadPageFromOrigin(_ sender: Any?) { tab.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { tab.stopLoading() }

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.first { $0 > webView.pageZoom + 0.001 } ?? Self.zoomSteps.last!)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tab.webView else { return }
        setZoom(Self.zoomSteps.last { $0 < webView.pageZoom - 0.001 } ?? Self.zoomSteps.first!)
    }

    @objc func actualSize(_ sender: Any?) {
        setZoom(1)
        tab.webView?.magnification = 1
    }

    /// The same zoom a tab keeps for the site, so the page looks the same once it moves into Zigzag.
    private func setZoom(_ zoom: CGFloat) {
        guard let webView = tab.webView, let url = tab.url else { return }
        webView.pageZoom = zoom
        ZoomLevels.set(zoom, for: url)
    }

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = tab.webView, webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return }
        inspector.perform(NSSelectorFromString("show"))
    }

    // MARK: Closing

    /// Closing fades it away first, however it's closed (⌘W, the red light, an extension); the page goes with it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isLeaving else { return false }
        // Opened from another app and closed straight from here: back to that app, before this one fades, so no
        // browser window comes forward in its place.
        if let app = returnTo, !app.isTerminated, NSApp.keyWindow === window, Self.all.count == 1 {
            app.activate()
        }
        commandBar.dismiss(restoringFocus: false)
        fadeAway { [weak self] in self?.window?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        pageGone.send()
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        if !movedOut {
            tokens.removeAll()
            if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab, windowClosing: true) }
            tab.close()
        }
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniClosed(self) }
        Self.all.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniFocused(self) }
    }
}

// MARK: - Its menu items

extension MiniWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openDocument(_:)):
            item.title = openTitle
            return tab.url != nil && !isLeaving
        case #selector(copyPageURL(_:)): return tab.url != nil && !isLeaving
        case #selector(goBack(_:)): return tab.canGoBack
        case #selector(goForward(_:)): return tab.canGoForward
        case #selector(stopLoading(_:)): return tab.isLoading
        default: return !isLeaving
        }
    }
}

// MARK: - Its space

extension MiniWindowController: SpaceTinted {
    var tintSpace: SpaceInfo? { space }
}

// MARK: - The command bar over it

extension MiniWindowController: CommandBarHost {
    var commandBarOverlay: NSView { root.barLayer }
    var commandBarPageFrame: NSRect { root.card.frame }
    /// Always over the page's site, in the middle of the strip, whatever opened it.
    func commandBarAnchor(asked: NSView?) -> NSView? { strip.anchor }
    var commandBarCentersOnAnchor: Bool { true }
    var commandBarTabs: TabManager? { MiniQuickOpen.tabs }
    var commandBarTab: Tab? { tab }
    var commandBarSpace: SpaceInfo? { space }
    var commandBarIsPrivate: Bool { false }

    func commandBarWillShow() {
        linkStatus.hide()
        strip.title.isHidden = true
    }

    func commandBarRestoreFocus() {
        if let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    func commandBarDidHide() { strip.title.isHidden = false }

    /// What you choose opens here, in place of this page; an open tab is gone to in its browser window.
    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool {
        if MiniQuickOpen.switchToTab(kind) { return true }
        guard let (url, search) = MiniQuickOpen.page(for: kind) else { return true }
        tab.isSearchTab = search
        tab.load(url)
        strip.title.isHidden = false
        commandBarRestoreFocus()
        return true
    }
}

// MARK: - Its page's requests

extension MiniWindowController: TabHost {
    var hostWindow: NSWindow? { window }

    /// One page lives here: a link that asks for a tab of its own goes to a browser window, as a sign-in popup's does.
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        switch disposition {
        case .currentTab, .peek:
            tab.load(url)
        case .newWindow, .privateWindow:
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: disposition == .privateWindow)
        case .foregroundTab, .backgroundTab:
            let target = Self.browserWindow()
            target.open(url, disposition: disposition, allowSwitch: false)
            if disposition == .foregroundTab { target.window?.makeKeyAndOrderFront(nil) }
        }
    }

    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        let pending = BrowserWebView.takePendingDisposition(for: tab.webView)
        if pending == .newWindow || pending == .privateWindow, let url = action.request.url {
            WindowManager.shared.newWindow(url: url, showCommandBar: false, isPrivate: pending == .privateWindow)
            return nil
        }
        // Sized window.open() calls are sign-in and payment popups: their own small window, over this one.
        if pending == nil, features.width != nil || features.height != nil || features.toolbarsVisibility?.boolValue == false {
            return PopupWindowController.open(configuration: configuration, features: features, parent: window)
        }
        // A link for a new tab (target=_blank, ⌘-click, Open Link in New Tab) opens in the browser window; ⌘-click
        // and the menu's own items leave you here, a plain click takes you there.
        let background = pending != nil || (action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
        let target = Self.browserWindow()
        let newTab = target.tabManager.newTab(url: action.request.url, select: !background, configuration: configuration)
        if !background { target.window?.makeKeyAndOrderFront(nil) }
        return newTab.ensureWebView()
    }

    func tabDidRequestClose(_ tab: Tab) { window?.performClose(nil) }
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tabDidChangeFullscreen(_ tab: Tab, isFullscreen: Bool) {}

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        linkStatus.show(url, in: overlay.bounds)
    }
}

// MARK: - The window's content

/// Zigzag Mini's content: the space's frame, the slim strip on top of it, and the page as a card in a thin, even
/// frame of the space's color, so it reads as a small Zigzag window.
final class MiniRootView: SpaceFrameView {
    let strip = MiniStripView()
    let card = PageCardView()
    /// Over the page: the link under the pointer, a site's question, a toast.
    let overlay = PassthroughView()
    /// Over the whole window: the command bar.
    let barLayer = PassthroughView()

    init() {
        super.init(color: SpaceColor.sky.background)
        [strip, card, overlay, barLayer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = Tokens.Metric.miniStripHeight
        let inset = Tokens.Metric.miniFrame
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        card.frame = NSRect(x: inset, y: top, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - top - inset))
        overlay.frame = card.frame
        barLayer.frame = bounds
    }
}

// MARK: - The top strip

/// The strip on top, as slim as a split view pane's: the traffic lights, the space the page goes to, the page's site
/// in the middle, and Copy Link and Open in at the right end, lined up with the page's edge. Dragging it moves the
/// window.
final class MiniStripView: NSView {
    let spaceChip = MiniSpaceChip()
    let title = MiniTitleView()
    let copyButton: IconButton = {
        let button = IconButton(symbol: "link", size: Tokens.Pane.button, symbolSize: Tokens.Pane.glyph,
                                toolTip: Shortcuts.tooltip(String(localized: "Copy Link", comment: "Edit menu item."),
                                                           for: #selector(MiniWindowController.copyPageURL(_:))))
        button.isChrome = true
        return button
    }()
    let openButton = MiniOpenButton()
    /// Where ⌘L's command bar opens: the address field's size, in the middle of the strip.
    let anchor = NSView()
    /// The traffic lights' width, kept clear on the left.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        anchor.isHidden = true
        [anchor, spaceChip, title, copyButton, openButton].forEach(addSubview)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func refreshColors() { [spaceChip, title, openButton].forEach { $0.stateDidChange(animated: false) } }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        let h = Tokens.Pane.addressHeight, b = Tokens.Pane.button
        let y = round(mid - h / 2)
        let left = Tokens.Sidebar.lightsX + trafficLightsWidth + Tokens.Space.x2
        // The button's end lines up with the page's right edge, the frame's width in.
        let right = bounds.width - Tokens.Metric.miniFrame
        // Narrow, the shortcut goes first, then the space's name shortens.
        openButton.showsKeys = true
        if right - left < spaceChip.fittingWidth + b + openButton.fittingWidth + Tokens.Space.x3 { openButton.showsKeys = false }
        let openWidth = min(openButton.fittingWidth, max(0, right - left - b))
        openButton.frame = NSRect(x: right - openWidth, y: y, width: openWidth, height: h)
        copyButton.frame = NSRect(x: openButton.frame.minX - Tokens.Space.x1 - b, y: round(mid - b / 2), width: b, height: b)
        let chipWidth = max(0, min(spaceChip.fittingWidth, copyButton.frame.minX - Tokens.Space.x2 - left))
        spaceChip.frame = NSRect(x: left, y: y, width: chipWidth, height: h)
        // The site stays in the middle of the window, as wide on both sides as the room beside it allows; with too
        // little room it steps aside.
        let half = max(0, min(bounds.midX - spaceChip.frame.maxX, copyButton.frame.minX - bounds.midX) - Tokens.Space.x2)
        var width = min(title.fittingWidth, half * 2)
        if width < Tokens.Space.x10 { width = 0 }
        title.frame = NSRect(x: round(bounds.midX - width / 2), y: y, width: width, height: h)
        let field = min(Tokens.Metric.miniAddressWidth, max(bounds.width - left * 2, Tokens.Metric.miniAddressWidth / 2))
        anchor.frame = NSRect(x: round(bounds.midX - field / 2), y: y, width: field, height: h)
    }
}

/// The space Open in moves the page to, after the traffic lights: its icon, when it has one, and name, quiet, in
/// the sidebar's small type. A click opens the spaces to choose another; the window takes its color.
final class MiniSpaceChip: InteractiveView {
    private let picture = NSImageView()
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText, weight: .medium), color: Tokens.Color.textSecondary)
    private static let pad = Tokens.Space.x2 - 2
    private static let side = Tokens.Sidebar.rowGlyph + 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A menu opens as the button goes down, as a pop-up button's does.
        clicksOnMouseDown = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        picture.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingTail
        [picture, label].forEach(addSubview)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(String(localized: "Space", comment: "VoiceOver name of the space in Zigzag Mini's top strip, the one Open in moves the page to. Its value is the space's name."))
        setAccessibilityHelp(String(localized: "Chooses the space the page opens in", comment: "VoiceOver hint of the space in Zigzag Mini's top strip."))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A space's own picture where a symbol can't stand for it, its emoji; none when it has no icon, as in the sidebar.
    static func picture(of space: SpaceInfo, size: CGFloat) -> NSImage? {
        space.icon.map { IconChoice.image($0, size: size) }
    }

    func show(_ space: SpaceInfo) {
        picture.image = Self.picture(of: space, size: Self.side)
        picture.isHidden = picture.image == nil
        label.stringValue = space.name
        setAccessibilityValue(space.name)
        needsLayout = true
    }

    /// The picture's room, when the space has one.
    private var pictureRoom: CGFloat { picture.isHidden ? 0 : Self.side + Tokens.Space.x1 + 2 }

    var fittingWidth: CGFloat { Self.pad * 2 + pictureRoom + label.inkWidth + 2 }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: Self.pad, y: round((bounds.height - Self.side) / 2), width: Self.side, height: Self.side)
        let x = Self.pad + pictureRoom
        let h = label.lineHeight
        label.frame = NSRect(x: x - Label.inset, y: round((bounds.height - h) / 2), width: max(0, bounds.width - Self.pad - x + Label.inset * 2), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // Plain on the frame at rest; under the pointer and while its menu is open, the toolbar buttons' wash.
        let fill: NSColor? = isPressed ? Tokens.Chrome.pressed : isHovered || isSelected ? Tokens.Chrome.hover : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        let theme = Brand.Theme.for(self)
        let ink = isHovered || isSelected ? theme.rowInk : theme.quietInk
        label.textColor = ink
        picture.contentTintColor = ink
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }
}

/// The page's site in the middle of the strip, small and quiet, with the not-secure mark on a plain http page. Under
/// the pointer it shows the address field's soft fill, and a click opens the command bar over it, as the sidebar's
/// address does.
final class MiniTitleView: InteractiveView {
    private let mark = NSImageView()
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    private var themeToken: SignalToken?
    private static let pad = Tokens.Space.x2 + 2
    var text: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        mark.imageScaling = .scaleNone
        mark.image = Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline)
        mark.toolTip = SitePanel.notSecure
        mark.isHidden = true
        label.lineBreakMode = .byTruncatingMiddle
        [mark, label].forEach(addSubview)
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "Opens the command bar", comment: "Accessibility help of the address in the sidebar."))
        themeToken = Brand.themeChanged.observe { [weak self] in self?.stateDidChange(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab) {
        let name = AddressView.name(of: tab.url)
        label.stringValue = name.isEmpty ? tab.displayTitle : name
        mark.isHidden = tab.url?.scheme != "http"
        setAccessibilityLabel(mark.isHidden ? label.stringValue
                              : String(localized: "\(label.stringValue), \(SitePanel.notSecure)", comment: "Accessibility label of the address in the sidebar on a plain http page: the site, then that it's not secure."))
        needsLayout = true
    }

    /// As wide as the mark and the whole site want, with the field's padding either side.
    var fittingWidth: CGFloat {
        var width = Self.pad * 2 + label.inkWidth + 2
        if !mark.isHidden { width += Tokens.Space.x3 + Tokens.Space.x1 }
        return width
    }

    override func layout() {
        super.layout()
        var x = Self.pad
        if !mark.isHidden {
            mark.frame = NSRect(x: x, y: 0, width: Tokens.Space.x3, height: bounds.height)
            x = mark.frame.maxX + Tokens.Space.x1
        }
        let h = label.lineHeight
        label.frame = NSRect(x: x - Label.inset, y: round((bounds.height - h) / 2), width: max(0, bounds.width - Self.pad - x + Label.inset * 2), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // Plain on the frame at rest; under the pointer, the sidebar address's soft field, a step back when pressed.
        let fill: NSColor? = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.field : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        let theme = Brand.Theme.for(self)
        label.textColor = isHovered ? theme.rowInk : theme.quietInk
        mark.contentTintColor = theme.quietInk
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }
}

/// Open in at the strip's right end: what it does in words, "Open in Work", and its shortcut after it in quieter
/// type, on the sidebar address's soft field with a hairline edge.
final class MiniOpenButton: InteractiveView {
    private let label = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText, weight: .medium), color: Tokens.Color.textPrimary)
    private let keys = Label("", font: .systemFont(ofSize: Tokens.Pane.addressText), color: Tokens.Color.textSecondary)
    private static let pad = Tokens.Space.x2 + 2
    var title: String { label.stringValue }
    /// Whether the shortcut shows after the words; a narrow window leaves it to the tooltip.
    var showsKeys = true { didSet { keys.isHidden = !showsKeys || keys.stringValue.isEmpty; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressSinks = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        [label, keys].forEach(addSubview)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, keys shortcut: String) {
        label.stringValue = title
        keys.stringValue = shortcut
        keys.isHidden = !showsKeys || shortcut.isEmpty
        setAccessibilityLabel(title)
        toolTip = shortcut.isEmpty ? title : String(localized: "\(title) (\(shortcut))", comment: "A button's tooltip: its name, then its keyboard shortcut in parentheses, like “Reload (⌘R)”.")
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        var width = Self.pad * 2 + label.inkWidth + 2
        if !keys.isHidden { width += Tokens.Space.x1 + 2 + keys.inkWidth + 2 }
        return width
    }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        let keysInk = keys.isHidden ? 0 : keys.inkWidth + 2
        let keysRoom = keys.isHidden ? 0 : keysInk + Tokens.Space.x1 + 2
        label.frame = NSRect(x: Self.pad - Label.inset, y: round((bounds.height - h) / 2),
                             width: max(0, bounds.width - Self.pad * 2 - keysRoom + Label.inset * 2), height: h)
        keys.frame = NSRect(x: bounds.width - Self.pad - keysInk - Label.inset, y: label.frame.minY, width: keysInk + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        // The sidebar address's soft field, a step brighter under the pointer, a step back when pressed; the space
        // key's hairline around it, so it still reads as a button on a white or pale space.
        let fill = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: false)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = Tokens.Metric.hairline
            layer?.borderColor = cgColor(Tokens.Chrome.keyEdge)
        }
        let theme = Brand.Theme.for(self)
        label.textColor = theme.rowInk
        keys.textColor = theme.quietInk
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}

// MARK: - As extensions see it

/// Zigzag Mini, for extensions: a popup-type window holding its one tab, as a sign-in popup is.
@available(macOS 15.4, *)
extension MiniWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { movedOut ? [] : [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { movedOut ? nil : tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { window?.isMiniaturized == true ? .minimized : .normal }
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

// MARK: - Its page's questions

/// A site's permission question and Save password? come up here over the one page, as they do in a browser window.
extension MiniWindowController: PromptHost {
    var promptOverlay: NSView { overlay }
    func pageFrame(showing tab: Tab) -> NSRect? { promptHolds(tab) ? overlay.bounds : nil }
    var focusedPaneFrame: NSRect { overlay.bounds }
    var promptFrontTab: Tab? { movedOut || isClosing ? nil : tab }
    func promptHolds(_ tab: Tab) -> Bool { tab === self.tab && !movedOut && !isClosing }
    func promptShows(_ tab: Tab) -> Bool { promptHolds(tab) }
    var promptIsPrivate: Bool { false }
    var promptAccent: NSColor { Brand.Theme.of(space).accent }
    /// Its one page never changes places; it only leaves, into Zigzag or with the window.
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? { pageGone.observe { _ in body() } }
    var promptPageViews: [NSView] { [root.card] }
    func clearForPrompt() {
        linkStatus.hide()
        commandBar.dismiss()
    }
    var promptIsCovered: Bool { commandBar.isVisible }
    var promptAnchor: NSView? { strip }
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) {
        Toast.show(text, symbol: symbol, duration: duration, over: overlay, area: overlay.bounds)
    }
}

/// A link for Zigzag Mini from another app wakes Zigzag, and macOS brings every Zigzag window forward with it, a moment
/// before Zigzag hears of the link. So when Zigzag is woken from the background (not by ⌘Tab or a click on one of its
/// windows), its browser windows wait unseen for that moment: a link for Zigzag Mini puts them back where they were,
/// behind the app you clicked in, before they show again; anything else shows them right where macOS put them.
enum MiniLinkWake {
    private static var waiting: [NSWindow] = []
    /// Each waiting window's place as Zigzag woke: the window just above it, of any app, top to bottom.
    private static var places: [(window: NSWindow, below: Int?)] = []
    private static var timeout: DispatchWorkItem?

    static func appWillActivate() {
        guard MiniWindowController.opensExternalLinks, waiting.isEmpty else { return }
        // ⌘Tab holds ⌘; a click on a Zigzag window is that window's.
        if NSEvent.modifierFlags.contains(.command) { return }
        let windows = WindowManager.shared.controllers.compactMap(\.window).filter { $0.isVisible && !$0.isMiniaturized }
        let pointer = NSEvent.mouseLocation
        guard !windows.isEmpty, !(NSEvent.pressedMouseButtons != 0 && windows.contains { $0.frame.contains(pointer) }) else { return }
        places = Self.places(of: windows)
        waiting = windows
        windows.forEach { $0.alphaValue = 0 }
        let work = DispatchWorkItem { release(restoring: false) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The link went to Zigzag Mini: the browser windows go back exactly where they were.
    static func linkOpenedInMini() {
        guard !waiting.isEmpty else { return }
        release(restoring: true)
    }

    private static func release(restoring: Bool) {
        timeout?.cancel()
        timeout = nil
        if restoring {
            // Top to bottom, so each window it goes under is already back in its place.
            for place in places { if let below = place.below { place.window.order(.below, relativeTo: below) } }
        }
        waiting.forEach { $0.alphaValue = 1 }
        waiting = []
        places = []
    }

    /// Where each window sits among every app's windows on screen, as the window right above it.
    private static func places(of windows: [NSWindow]) -> [(window: NSWindow, below: Int?)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let byNumber = Dictionary(windows.map { ($0.windowNumber, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(window: NSWindow, below: Int?)] = []
        var above: Int?
        for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            if let window = byNumber[number] { result.append((window, above)) }
            above = number
        }
        return result
    }
}

/// The app you were in before Zigzag: where a link for Zigzag Mini came from, to go back to when it closes.
enum AppSwitching {
    private(set) static var lastOtherApp: NSRunningApplication?
    private static var token: NSObjectProtocol?

    static func start() {
        guard token == nil else { return }
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            MainActor.assumeIsolated { lastOtherApp = app }
        }
    }
}
