import AppKit
import WebKit

/// A mini window: one page in a small, quiet window of its own, with no sidebar, for a link from another app or a
/// quick look-up. Its page is a real tab, so history, blocking, autofill and extensions work as they do anywhere;
/// Open in Zigzag moves that same live page into a browser window. It's never saved: quitting lets it go, as Arc did.
final class MiniWindowController: NSWindowController, NSWindowDelegate {
    /// Open ones, oldest first, for placing the next one and for extensions.
    private(set) static var all: [MiniWindowController] = []
    /// The mini window you're in, if any.
    static var key: MiniWindowController? { all.first { $0.window?.isKeyWindow == true } }

    let tab: Tab
    private let strip = MiniStripView()
    /// Where floating things go over the page: the link under the pointer, the sign-in menu.
    let overlay = PassthroughView()
    private let page = NSView()
    private lazy var linkStatus = LinkStatusController(overlay: overlay)
    private var token: SignalToken?
    /// The page went into a browser window: closing this one must leave it alone.
    private var movedOut = false

    /// Settings › General: links from other apps open in a mini window instead of a tab. Off unless you turn it on.
    static var opensExternalLinks: Bool {
        get { UserDefaults.standard.bool(forKey: "OpensExternalLinksInMini") }
        set { UserDefaults.standard.set(newValue, forKey: "OpensExternalLinksInMini") }
    }

    /// Whether a page another app hands over goes to a mini window: only web links, only with the setting on, and
    /// never before onboarding is done, whose first window is where you start.
    nonisolated static func takes(_ url: URL, settingOn: Bool, needsOnboarding: Bool) -> Bool {
        settingOn && !needsOnboarding && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Opens one, on `url`, or blank with the address field ready to type in.
    @discardableResult
    static func open(url: URL?) -> MiniWindowController {
        let controller = MiniWindowController(url: url)
        all.append(controller)
        Diagnostics.note("Mini window opened", site: url?.host())
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if #available(macOS 15.4, *) { ExtensionHost.shared.miniOpened(controller) }
        if url == nil { controller.editAddress() } else if let webView = controller.tab.webView { controller.window?.makeFirstResponder(webView) }
        return controller
    }

    private init(url: URL?) {
        let spaceID = WindowManager.shared.keyController?.tabManager.currentSpaceID ?? Library.shared.spaces[0].id
        tab = Tab(url: url, spaceID: spaceID)
        // Zigzag's own PDF viewer and Back to the page that opened it belong to a browser window's tabs; here the page
        // is shown as in peek, and becomes a full tab once it moves.
        tab.isPeek = true
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let taken = Self.all.compactMap { $0.window?.frame }
        let frame = Self.frame(size: Tokens.Metric.miniWindowSize, in: screen, taken: taken)

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 260)
        // Opened over a full-screen window, it stays there in the same Space instead of opening off in another one.
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.setFrame(frame, display: false)
        super.init(window: window)
        window.delegate = self

        let content = ColorView(color: SpaceColor.graphite.background)
        window.contentView = content
        let width = content.bounds.width, height = content.bounds.height
        let header = PopupWindowController.headerHeight
        strip.frame = NSRect(x: 0, y: 0, width: width, height: header)
        strip.autoresizingMask = [.width]
        page.frame = NSRect(x: 0, y: header, width: width, height: height - header)
        page.autoresizingMask = [.width, .height]
        overlay.frame = page.frame
        overlay.autoresizingMask = [.width, .height]
        [strip, page, overlay].forEach(content.addSubview)
        strip.openButton.onClick = { [weak self] _ in self?.openInZigzag() }
        strip.field.field.delegate = self
        strip.field.field.target = self
        strip.field.field.action = #selector(addressEntered)

        tab.host = self
        token = tab.changed.observe { [weak self] change in self?.tabChanged(change) }
        if url != nil { showPage() }
        refreshStrip()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where a new mini window goes: its size, cut to fit, centered on the screen's usable area. One already at that
    /// spot moves it a step down and right, and so on, the way a Mac cascades windows; past the screen's edge it goes
    /// back to the middle.
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

    // MARK: The page

    private func showPage() {
        let webView = tab.ensureWebView()
        guard webView.superview !== page else { return }
        webView.frame = page.bounds
        webView.autoresizingMask = [.width, .height]
        page.addSubview(webView)
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .url, .loading, .title, .webView:
            refreshStrip()
            window?.title = tab.displayTitle
            // A new web view (the page crashed and came back, or crossed into an extension's page) takes the old one's place.
            if change == .webView, tab.webView != nil, !movedOut { showPage() }
        default: break
        }
    }

    private func refreshStrip() {
        strip.header.show(url: tab.url, secure: tab.webView?.hasOnlySecureContent ?? false)
        strip.header.isHidden = tab.url == nil || strip.isEditing
        strip.openButton.isEnabled = tab.url != nil
    }

    // MARK: Typing an address

    /// The address field in the strip, in place of the site's name: blank for a new mini window, the page's address
    /// for ⌘L.
    func editAddress() {
        strip.field.stringValue = tab.url.map { $0.absoluteString } ?? ""
        strip.isEditing = true
        refreshStrip()
        window?.makeFirstResponder(strip.field.field)
        strip.field.field.currentEditor()?.selectAll(nil)
    }

    private func endEditing() {
        strip.isEditing = false
        refreshStrip()
        if let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    @objc private func addressEntered() {
        let text = strip.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url = CommandRanker.url(from: text) ?? Library.shared.searchEngine.searchURL(text)
        tab.isSearchTab = CommandRanker.url(from: text) == nil
        strip.isEditing = false
        tab.load(url)
        showPage()
        refreshStrip()
        if let webView = tab.webView { window?.makeFirstResponder(webView) }
    }

    @objc func openLocation(_ sender: Any?) { editAddress() }

    #if DEBUG
    func debugEnter(_ text: String) {
        if !strip.isEditing { editAddress() }
        strip.field.stringValue = text
        addressEntered()
    }

    func debugEscape() {
        guard let editor = strip.field.field.currentEditor() as? NSTextView else { return }
        _ = control(strip.field.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    var debugState: [String: Any] {
        ["editing": strip.isEditing, "fieldFocused": strip.field.field.currentEditor() != nil, "hostShown": !strip.header.isHidden,
         "openEnabled": strip.openButton.isEnabled, "webViewHere": tab.webView?.window === window, "movedOut": movedOut,
         "fullScreenAuxiliary": window?.collectionBehavior.contains(.fullScreenAuxiliary) == true]
    }
    #endif

    // MARK: Moving into Zigzag

    /// The browser window this one's pages go to: the front everyday window, else the session brought back, else a
    /// new one. Never a private window: a mini window isn't private.
    static func browserWindow() -> BrowserWindowController {
        let manager = WindowManager.shared
        let key = manager.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        return key ?? manager.controllers.last { !$0.tabManager.isPrivate } ?? manager.restoreIfNoWindows()
            ?? manager.newWindow(showCommandBar: false)
    }

    /// Moves the page, live, into a browser window as its selected tab, and closes this window.
    @objc func openInZigzag(_ sender: Any? = nil) {
        guard tab.url != nil, !movedOut else { return }
        let target = Self.browserWindow()
        movedOut = true
        token = nil
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        tab.webView?.removeFromSuperview()
        tab.isPeek = false
        target.tabManager.insertAsNewTab(tab)
        window?.close()
        target.window?.makeKeyAndOrderFront(nil)
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

    func windowWillClose(_ notification: Notification) {
        linkStatus.hide()
        Autofill.shared.forget(windowOf: window)
        if !movedOut {
            token = nil
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

// MARK: - The address field

extension MiniWindowController: NSTextFieldDelegate {
    /// Esc puts the address back as it was; on a mini window with no page yet, it closes the window, as nothing
    /// was asked for.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if tab.url == nil { window?.performClose(nil) } else { endEditing() }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicked away into the page: the site's name comes back.
        guard strip.isEditing, tab.url != nil else { return }
        strip.isEditing = false
        refreshStrip()
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
        let pending = BrowserWebView.pendingDisposition
        BrowserWebView.pendingDisposition = nil
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

    func tabDidRequestClose(_ tab: Tab) { window?.close() }
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tabDidChangeFullscreen(_ tab: Tab, isFullscreen: Bool) {}

    func tab(_ tab: Tab, hoveringLink url: URL?) {
        linkStatus.show(url, in: overlay.bounds)
    }
}

// MARK: - The top strip

/// The mini window's top strip: traffic lights, the site's host in the middle (as a sign-in popup shows it), the
/// address field in its place while you type one, and Open in Zigzag at the right end.
final class MiniStripView: NSView {
    let header = PopupHeaderView()
    let field = FilledField(placeholder: String(localized: "Search or enter address", comment: "Placeholder of the command bar's field."))
    let openButton = IconButton(symbol: "arrow.up.forward.app",
                                toolTip: String(localized: "Open in Zigzag", comment: "Tooltip of the button in a mini window's top strip that moves its page into a Zigzag window as a tab."))
    var isEditing = false { didSet { field.isHidden = !isEditing; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isPill = true
        field.isHidden = true
        field.field.setAccessibilityLabel(String(localized: "Address", comment: "VoiceOver label of the address field in a mini window's top strip."))
        [header, field, openButton].forEach(addSubview)
        header.trailingInset = Tokens.Metric.iconButton + Tokens.Space.x2
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        header.frame = bounds
        let b = Tokens.Metric.iconButton
        openButton.frame = NSRect(x: bounds.width - Tokens.Space.x2 - b, y: (bounds.height - b) / 2, width: b, height: b)
        // Clear of the traffic lights on the left and the button on the right, no wider than an address needs.
        let left = Tokens.Space.x16 + Tokens.Space.x4
        let width = max(0, min(Tokens.Metric.miniAddressWidth, openButton.frame.minX - Tokens.Space.x2 - left))
        let h = Tokens.Metric.controlHeight
        let x = max(left, round((bounds.width - width) / 2))
        field.frame = NSRect(x: min(x, openButton.frame.minX - Tokens.Space.x2 - width), y: round((bounds.height - h) / 2), width: width, height: h)
    }
}

// MARK: - As extensions see it

/// A mini window, for extensions: a popup-type window holding its one tab, as a sign-in popup is.
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
        window?.close()
        completionHandler(nil)
    }
}
