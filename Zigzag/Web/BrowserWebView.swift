import AppKit
import WebKit

/// Our WKWebView. Only adds what the browser frame needs: context menu tweaks and swipes.
final class BrowserWebView: WKWebView {
    weak var owner: Tab?
    private lazy var swipe = SwipeNavigator(webView: self)

    /// A swipe over something covering the page (the PDF viewer) goes back or forward like one over the page,
    /// unless it can still scroll that way (`room`).
    func handleSwipe(_ event: NSEvent, room: (left: Bool, right: Bool)) -> Bool { swipe.handle(event, room: room) }

    /// Back and forward by a finger in from the page's edge (`PageHolder`).
    var swipeNavigator: SwipeNavigator { swipe }

    /// The page, in some frame, kept a sideways scroll from `at` (wall-clock ms) for itself, or left it (SwipeAnswers).
    func pageAnsweredSwipe(kept: Bool, at: Double) { swipe.pageAnswered(kept: kept, at: at) }

    /// Covered by the PDF viewer or Settings: typing (arrows, space, ⌘F's text) goes to that instead.
    override func becomeFirstResponder() -> Bool {
        let cover: NSView? = owner?.pdfViewer.flatMap { $0.superview != nil ? $0.pdfView : nil }
            ?? owner?.settingsView.flatMap { $0.superview != nil ? $0 : nil }
        if let cover {
            // Only if the page still has the keyboard by then: a click elsewhere in between keeps it there.
            DispatchQueue.main.async { [weak self, weak cover] in
                guard let self, let cover, cover.window != nil, let window = self.window, window.firstResponder === self else { return }
                window.makeFirstResponder(cover)
            }
        }
        return super.becomeFirstResponder()
    }

    #if DEBUG
    /// Debug commands that click into a page from a test copy in the background, where the first click would
    /// otherwise only bring the window forward.
    nonisolated(unsafe) static var takesFirstMouse = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { Self.takesFirstMouse || super.acceptsFirstMouse(for: event) }
    /// Holds a swipe partway (`SwipeNavigator.debugHold`).
    func debugHoldSwipe(direction: Int, progress: CGFloat?) { swipe.debugHold(direction: direction, progress: progress) }
    #endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Its tab went to the back mid-swipe: the swipe can't finish here any more.
        if window == nil { swipe.leftWindow() }
    }

    /// Edit › Select All (⌘A) on the History page selects every row, as in Safari, rather than the page's text. The
    /// menu takes ⌘A before the page sees it, so it's handed on here; with something typed in the page's search
    /// field, that text is what's selected, as usual.
    override func selectAll(_ sender: Any?) {
        // After a click in the sidebar, ⌘A picks its tabs (#302).
        if (window as? BrowserWindow)?.selectAllInSidebar() == true { return }
        // A PDF from the web is in WebKit's own viewer, which takes Select All only once its plugin has the page's
        // focus, as a click in it gives: a PDF just opened has none, and ⌘A selected nothing (#219).
        if isPDF, owner?.pdfViewer == nil {
            Self.focusPDF(in: self) { [weak self] in self?.superSelectAll(sender) }
            return
        }
        guard HistoryPage.isHistory(url) else { super.selectAll(sender); return }
        evaluateJavaScript("window.zigzagSelectAll && window.zigzagSelectAll()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if result as? Bool != true { self?.superSelectAll(sender) }
            }
        }
    }

    private func superSelectAll(_ sender: Any?) { super.selectAll(sender) }

    /// The page is a PDF (`Tab.checkForPDF`), in WebKit's viewer unless Zigzag's covers it.
    var isPDF = false

    /// Gives WebKit's PDF viewer the page's focus, as a click in it would, then `then`. In Zigzag's own world, so
    /// the page's scripts can't stand in its way.
    static func focusPDF(in webView: WKWebView, then: @escaping @MainActor () -> Void) {
        let script = """
            (() => {
              const plugin = document.contentType === 'application/pdf' && document.querySelector('embed');
              if (plugin && document.activeElement !== plugin) plugin.focus();
              return !!plugin;
            })()
            """
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in
            MainActor.assumeIsolated { then() }
        }
    }

    // WKWebView's text input methods aren't public, so these take their selectors; WebKit's hasMarkedText reads false.
    private var markedLetters: String?
    private var composingSource: IMECommit.Source?
    private var urlObservation: NSKeyValueObservation?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        _ = Self.interposed
        super.init(frame: frame, configuration: configuration)
        // A composition doesn't outlive its page.
        urlObservation = observe(\.url) { webView, _ in MainActor.assumeIsolated { webView.forgetComposition() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The page took the composition away (a click, a new page): what was marked is no longer coming.
    private func forgetComposition() {
        markedLetters = nil
        composingSource = nil
    }

    #if DEBUG
    var debugMarkedLetters: String? { markedLetters }
    #endif

    /// WebKit's text input selectors and the ones here that stand in for them.
    static let imeSelectors: [(webKit: Selector, ours: Selector)] = [
        (NSSelectorFromString("setMarkedText:selectedRange:replacementRange:"), #selector(imeSetMarkedText(_:selectedRange:replacementRange:))),
        (NSSelectorFromString("insertText:replacementRange:"), #selector(imeInsertText(_:replacementRange:))),
        (NSSelectorFromString("unmarkText"), #selector(imeUnmarkText)),
    ]

    static let interposed: [Selector] = interpose(into: BrowserWebView.self, over: WKWebView.self)

    /// Adds the stand-ins to `cls` for each selector `base` implements; the others are left to `base`. Returns the
    /// selectors it took.
    static func interpose(into cls: AnyClass, over base: AnyClass) -> [Selector] {
        imeSelectors.compactMap { webKit, ours in
            guard class_getInstanceMethod(base, webKit) != nil, let method = class_getInstanceMethod(BrowserWebView.self, ours) else { return nil }
            return class_addMethod(cls, webKit, method_getImplementation(method), method_getTypeEncoding(method)) ? webKit : nil
        }
    }

    @objc(zigzagSetMarkedText:selectedRange:replacementRange:)
    func imeSetMarkedText(_ string: AnyObject, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if text.isEmpty { forgetComposition() } else {
            composingSource = markedLetters == nil ? IMECommit.currentSource() : composingSource
            markedLetters = text
        }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject, NSRange, NSRange) -> Void
        let selector = Self.imeSelectors[0].webKit
        Self.webKit(selector, as: Call.self)(self, selector, string, selectedRange, replacementRange)
    }

    @objc(zigzagInsertText:replacementRange:)
    func imeInsertText(_ string: AnyObject, replacementRange: NSRange) {
        let plain = (string as? String) ?? (string as? NSAttributedString)?.string
        // Only the marked letters themselves, committed: never dictation or a text replacement.
        let composing = markedLetters != nil && plain == markedLetters
        let source = composing ? composingSource ?? IMECommit.currentSource() : nil
        forgetComposition()
        superInsertText(IMECommit.cleaned(string as Any, composing: composing, source: source) as AnyObject, replacementRange)
    }

    /// Switching to English mid-word commits the marked text this way.
    @objc(zigzagUnmarkText)
    func imeUnmarkText() {
        let marked = markedLetters
        let source = composingSource ?? IMECommit.currentSource()
        forgetComposition()
        if let marked {
            let text = IMECommit.cleaned(marked, composing: true, source: source)
            if text != marked { superInsertText(text as NSString, NSRange(location: NSNotFound, length: 0)); return }
        }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        let selector = Self.imeSelectors[2].webKit
        Self.webKit(selector, as: Call.self)(self, selector)
    }

    private func superInsertText(_ string: AnyObject, _ replacementRange: NSRange) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
        let selector = Self.imeSelectors[1].webKit
        Self.webKit(selector, as: Call.self)(self, selector, string, replacementRange)
    }

    override func resignFirstResponder() -> Bool {
        forgetComposition()
        return super.resignFirstResponder()
    }

    /// WebKit's own implementation; only called for selectors `interpose` found it has.
    private static func webKit<Call>(_ selector: Selector, as: Call.Type) -> Call {
        unsafeBitCast(class_getMethodImplementation(WKWebView.self, selector), to: Call.self)
    }

    override func scrollWheel(with event: NSEvent) {
        // A sideways swipe to go back or forward is taken here; everything else scrolls the page.
        if TouchSwipeRecognizer.claims(event) || swipe.handle(event) { return }
        owner?.scrolledSinceSave = true
        super.scrollWheel(with: swipe.forPage(event))
    }

    // Keys (space, arrows, Page Down) and clicks (the scroll bar, a link to a heading) move the page too: the next
    // session save encodes where it is now (WindowManager).
    override func keyDown(with event: NSEvent) {
        owner?.scrolledSinceSave = true
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.scrolledSinceSave = true
        forgetComposition()
        if event.modifierFlags.contains(.control) { readSelectionForMenu() }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        readSelectionForMenu()
        super.rightMouseDown(with: event)
    }

    /// Selected text at right-click, for the menu (#234). Read before the page gets the click, so it arrives before
    /// the menu the page sends after handling it.
    private var menuSelection: String?

    private func readSelectionForMenu() {
        menuSelection = nil
        runOwnScript(Self.selectionScript) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let text) = result { self?.menuSelection = text as? String }
            }
        }
    }

    /// Read in Zigzag's world so the page can't fake it; falls back to the focused frame's selection when that frame
    /// is same-site.
    static let selectionScript = """
    (() => {
      let text = getSelection().toString();
      if (!text) {
        try {
          const frame = document.activeElement;
          if (frame && frame.contentWindow) text = frame.contentWindow.getSelection().toString();
        } catch (e) {}
      }
      return text;
    })()
    """

    /// When the last click in the page ended (system uptime). WebKit reports a click on the key icon in a sign-in
    /// field a moment after; a page can't make one of these.
    private(set) var lastClickUp: TimeInterval = -.infinity

    override func mouseUp(with event: NSEvent) {
        lastClickUp = ProcessInfo.processInfo.systemUptime
        super.mouseUp(with: event)
    }

    /// Three-finger swipes, for Macs set to swipe between pages that way: these come as swipe events, not scrolls.
    override func swipe(with event: NSEvent) {
        // In a split, the page swiped is the one that goes, and the one you're in from now on (#170).
        if event.deltaX > 0, let owner, owner.canGoBackOrReturn { owner.host?.tabWantsFocus(owner); owner.goBack(); return }
        if event.deltaX < 0, canGoForward {
            if let owner { owner.host?.tabWantsFocus(owner); owner.goForward() } else { goForward() }
            return
        }
        super.swipe(with: event)
    }
    /// Set by a context menu item right before WebKit asks this page for a new web view. WebKit asks the page first,
    /// so on a busy page (a forum's long topic list) the request can come well after the item was chosen: the choice
    /// waits for it, a few seconds at most, rather than going and leaving the request to look like a pop-up nobody
    /// clicked for. It belongs to the page it was chosen on: another tab's pop-up in that time is still a pop-up.
    private static var pending: (disposition: OpenDisposition, source: Source, until: Date)?
    private struct Source { weak var value: WKWebView? }

    /// The disposition chosen in this page's menu, while its request is still to come.
    static func pendingDisposition(for webView: WKWebView?) -> OpenDisposition? {
        guard let pending, let webView, pending.source.value === webView, Date() < pending.until else { return nil }
        return pending.disposition
    }

    /// The same, used up: the new web view it was for is being made.
    static func takePendingDisposition(for webView: WKWebView?) -> OpenDisposition? {
        guard let disposition = pendingDisposition(for: webView) else { return nil }
        pending = nil
        return disposition
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Extensions' own items ("Translate this page", "Save to Notion") go at the end.
        if #available(macOS 15.4, *), let owner { owner.extensionHost?.addMenuItems(for: owner, to: menu) }
        Self.arrangeLinkItems(in: menu, target: self)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = String(localized: "Open Image in New Tab", comment: "Item in a page's right-click menu.")
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = String(localized: "Open Video in New Tab", comment: "Item in a page's right-click menu.")
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.isHidden = true
            case "WKMenuItemIdentifierSearchWeb":
                // Searches with the engine you chose in Settings, in a new tab, not always Google in Safari.
                item.title = String(localized: "Search with \(Library.shared.searchEngine.name)", comment: "Item in a page's right-click menu. The placeholder is the search engine's name, like “Google”.")
                item.action = #selector(searchSelection(_:))
                item.target = self
            default:
                break
            }
        }
        addOpenSelection(to: menu)
        addSaveToPins(to: menu)
        // In a browser window's page or Zigzag Mini's, which a browser window translates; not a web app's.
        if let owner, WindowManager.shared.controller(for: window) != nil || MiniWindowController.showing(window) != nil { Self.addTranslate(to: menu, for: owner, target: self, action: #selector(translatePage(_:))) }
        Self.addAutoFill(to: menu)
        if HistoryPage.isHistory(url) { HistoryPage.addMenuItems(to: menu, in: self) }
        Self.placeInspectElementLast(in: menu)
        #if DEBUG
        // What the page's menu holds, with submenus and actions (AutoFill › Passwords… in a field), for scripts.
        debugLog("webmenu " + Self.debugDescribe(menu))
        #endif
    }

    /// A link's menu starts as Chrome's does (#419): Open Link in New Tab, in New Window, in Private Window, then
    /// Zigzag Mini. WebKit's Open Link (in this tab, even for a target=_blank link) goes below them.
    static func arrangeLinkItems(in menu: NSMenu, target: AnyObject?) {
        guard let original = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) else { return }
        let openLink = menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }
        let index = [original, openLink].compactMap { $0.map { menu.index(of: $0) } }.min() ?? 0
        menu.removeItem(original)
        if let openLink { menu.removeItem(openLink) }
        let choices = [(String(localized: "Open Link in New Tab", comment: "Item in a page's right-click menu."), #selector(openInNewTab(_:))),
                       (String(localized: "Open Link in New Window", comment: "Item in a page's right-click menu."), #selector(openInNewWindow(_:))),
                       (String(localized: "Open Link in Private Window", comment: "Item in a page's right-click menu."), #selector(openInPrivateWindow(_:))),
                       (String(localized: "Open Link in Zigzag Mini", comment: "Item in a page's right-click menu: opens the link in Zigzag Mini, the small window for one page, over this one (Arc called it Little Arc)."), #selector(openInMini(_:)))]
        let items = choices.map { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = original
            return item
        } + [openLink].compactMap { $0 }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: min(index + offset, menu.items.count)) }
    }

    static let openSelectionIdentifier = "ZigzagOpenSelection"
    static let saveToPinsIdentifier = "ZigzagSaveToPins"

    /// A link's right-click menu gets Pin Link (#326), under Open Link's items: the link pinned without opening it.
    /// Only over a link, and only in a browser window that isn't private, which is where pins live.
    private func addSaveToPins(to menu: NSMenu) {
        // Our own Open Link items (#419) replaced WebKit's, so they're found by action.
        let openActions: Set<Selector> = [#selector(openInNewTab(_:)), #selector(openInNewWindow(_:)), #selector(openInPrivateWindow(_:)), #selector(openInMini(_:))]
        guard let owner, !owner.isPrivate, WindowManager.shared.controller(for: window) != nil,
              let last = menu.items.lastIndex(where: { $0.action.map(openActions.contains) == true || $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else { return }
        let item = NSMenuItem(title: String(localized: "Pin Link", comment: "Item in a page's right-click menu over a link: pins the link, without opening it."),
                              action: #selector(saveMenuLinkToPins(_:)), keyEquivalent: "")
        item.target = self
        // WebKit's own Open Link in New Window, which knows the link the menu is for.
        item.representedObject = menu.items.first { $0.action == #selector(openInNewTab(_:)) }?.representedObject
        item.identifier = NSUserInterfaceItemIdentifier(Self.saveToPinsIdentifier)
        item.image = Tokens.Symbol.image("star")
        // After the link's own items: Open Link in New Tab, Zigzag Mini, a New Window, a Private one, and a download.
        var at = last
        let linkItems = ["WKMenuItemIdentifierOpenLinkInNewTab", "WKMenuItemIdentifierOpenLinkInNewWindow",
                         "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierDownloadLinkedFileAs"]
        while at + 1 < menu.items.count, linkItems.contains(menu.items[at + 1].identifier?.rawValue ?? "") { at += 1 }
        menu.insertItem(item, at: at + 1)
    }

    /// Pin Link chosen in the page's menu: the link the menu was opened on, pinned without opening it, named after its
    /// text. WebKit names the link through its own Open Link in New Window, as the Open Link items do; it never
    /// opens. ⇧ held, it asks which folder (#326).
    @objc private func saveMenuLinkToPins(_ sender: NSMenuItem) {
        guard let owner, !owner.isPrivate, WindowManager.shared.controller(for: window) != nil,
              let original = sender.representedObject as? NSMenuItem, let action = original.action else { return }
        BrowserWebView.pendingPin = (Source(value: self), BrowserWindowController.shiftHeld, Date().addingTimeInterval(3))
        NSApp.sendAction(action, to: original.target, from: original)
    }

    /// Pin Link's link, on its way from WebKit as a request for a new web view: `shiftHeld` asks where.
    private static var pendingPin: (source: Source, shiftHeld: Bool, until: Date)?

    /// Whether this page's request for a new web view is Pin Link's, used up: ⇧ held or not, or nil if it isn't.
    static func takePendingPin(for webView: WKWebView?) -> Bool? {
        guard let pin = pendingPin, let webView, pin.source.value === webView, Date() < pin.until else { return nil }
        pendingPin = nil
        return pin.shiftHeld
    }

    /// Selected text that's a web address but not a link ("example.com" in a post) gets Open and Open in New Tab at
    /// the top of its menu, as Chrome's Go to does (#234). Only in a browser window's page.
    private func addOpenSelection(to menu: NSMenu) {
        guard menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
              !menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }),
              WindowManager.shared.controller(for: window) != nil,
              let text = selectedText(in: menu), let destination = CommandRanker.destination(fromSelection: text) else { return }
        let items = [Self.openSelectionItem(String(localized: "Open", comment: "Item in a page's right-click menu over selected text that's a web address, not a link: opens it in this tab."), destination: destination, target: self, action: #selector(openSelection(_:))),
                     Self.openSelectionItem(String(localized: "Open in New Tab", comment: "Item in a page's right-click menu over selected text that's a web address, not a link: opens it in a new tab."), destination: destination, target: self, action: #selector(openSelectionInNewTab(_:)))]
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        if menu.items.count > items.count, !menu.items[items.count].isSeparatorItem { menu.insertItem(.separator(), at: items.count) }
    }

    private static func openSelectionItem(_ title: String, destination: CommandRanker.Destination, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = destination
        item.identifier = NSUserInterfaceItemIdentifier(openSelectionIdentifier)
        item.toolTip = destination.url.absoluteString
        return item
    }

    /// The selection read at click start, if it still matches WebKit's Look Up item (which truncates with …). A click
    /// that selected a word instead gets no Open.
    private func selectedText(in menu: NSMenu) -> String? {
        defer { menuSelection = nil }
        guard let text = menuSelection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let lookUp = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierLookUp" }) else { return text }
        return Self.lookUpTitle(lookUp.title, names: text) ? text : nil
    }

    /// Matches Look Up “example.com” or a truncated “A long sel…”.
    nonisolated static func lookUpTitle(_ title: String, names text: String) -> Bool {
        guard let open = title.firstIndex(of: "“"), let close = title.lastIndex(of: "”"), open < close else { return false }
        let named = String(title[title.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        let squeezed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if named == squeezed || named == text { return true }
        guard named.hasSuffix("…") else { return false }
        let start = named.dropLast().trimmingCharacters(in: .whitespaces)
        return !start.isEmpty && (squeezed.hasPrefix(start) || text.hasPrefix(start))
    }

    @objc private func openSelection(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? CommandRanker.Destination, let owner else { return }
        owner.load(destination.url, by: .page, httpFallback: destination.httpFallback)
    }

    @objc private func openSelectionInNewTab(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? CommandRanker.Destination, let controller = WindowManager.shared.controller(for: window) else { return }
        controller.open(destination.url, disposition: .backgroundTab, opener: owner, allowSwitch: false, by: .page, httpFallback: destination.httpFallback)
    }

    #if DEBUG
    static func debugDescribe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "-" }
            let action = item.action.map { NSStringFromSelector($0) } ?? ""
            let sub = item.submenu.map { " [" + debugDescribe($0) + "]" } ?? ""
            return "\(item.title){\(action)}\(item.isHidden ? "(hidden)" : "")\(sub)"
        }.joined(separator: " | ")
    }
    #endif

    /// A field's menu (one with Paste) gets the Mac's AutoFill submenu, Contact…, Passwords… and Credit Card…, as in
    /// Safari: the same items as Edit › AutoFill. Chosen with the cursor in the page's field, macOS opens its AutoFill
    /// panel there, knowing the page's site, and fills what you pick into it. WebKit's own menu doesn't have it.
    static func addAutoFill(to menu: NSMenu, from mainMenu: NSMenu? = NSApp.mainMenu) {
        guard let paste = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierPaste" }),
              !hasItem(SystemAutoFillPanel.command, in: menu),
              let source = mainMenu.flatMap({ autoFillItem(in: $0) }), let items = source.submenu?.items else { return }
        // Copies: an item belongs to one menu only.
        let autoFill = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
        autoFill.submenu = NSMenu(title: source.title)
        items.compactMap { $0.copy() as? NSMenuItem }.forEach { autoFill.submenu?.addItem($0) }
        menu.insertItem(.separator(), at: paste + 1)
        menu.insertItem(autoFill, at: paste + 2)
        if paste + 3 < menu.items.count, !menu.items[paste + 3].isSeparatorItem { menu.insertItem(.separator(), at: paste + 3) }
    }

    /// The menu bar's AutoFill submenu (AppKit puts it in the Edit menu, in the Mac's language).
    private static func autoFillItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            if submenu.items.contains(where: { $0.action == SystemAutoFillPanel.command }) { return item }
            if let found = autoFillItem(in: submenu) { return found }
        }
        return nil
    }

    private static func hasItem(_ action: Selector, in menu: NSMenu) -> Bool {
        menu.items.contains { $0.action == action || $0.submenu.map { hasItem(action, in: $0) } == true }
    }

    /// The page's own menu (Back, Forward, Reload) has Translate to English under Reload, as in Chrome, or Show
    /// Original once it's translated (#218). It's there whatever language the page seemed to be in.
    static func addTranslate(to menu: NSMenu, for tab: Tab, target: AnyObject?, action: Selector) {
        guard PageTranslator.offersTranslation(tab),
              let reload = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }) else { return }
        let item = NSMenuItem(title: PageTranslator.menuTitle(translated: tab.isTranslated), action: action, keyEquivalent: "")
        item.target = target
        item.identifier = NSUserInterfaceItemIdentifier(translateItemIdentifier)
        menu.insertItem(item, at: reload + 1)
    }

    static let translateItemIdentifier = "ZigzagTranslatePage"

    @objc private func translatePage(_ sender: NSMenuItem) {
        if let mini = MiniWindowController.showing(window) { mini.translatePage(sender); return }
        guard let owner, let controller = WindowManager.shared.controller(for: window) else { return }
        controller.translatePage(tab: owner)
    }

    /// WebKit's Inspect Element stays the menu's last item, below extensions' own, where Chrome keeps it.
    static func placeInspectElementLast(in menu: NSMenu) {
        guard let inspect = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }),
              inspect !== menu.items.last else { return }
        menu.removeItem(inspect)
        // The separator it had above it went with nothing; one goes above it at the end instead.
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var index = 1
        while index < menu.items.count {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) } else { index += 1 }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(inspect)
    }

    @objc private func openInMini(_ sender: NSMenuItem) {
        trigger(sender.representedObject as? NSMenuItem, disposition: .mini)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        trigger(sender.representedObject as? NSMenuItem, disposition: .backgroundTab)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        trigger(sender.representedObject as? NSMenuItem, disposition: .newWindow)
    }

    @objc private func openInPrivateWindow(_ sender: NSMenuItem) {
        trigger(sender.representedObject as? NSMenuItem, disposition: .privateWindow)
    }

    @objc private func searchSelection(_ sender: NSMenuItem) {
        runOwnScript("window.getSelection().toString()") { [weak self] answer in
            let result = try? answer.get()
            MainActor.assumeIsolated {
                guard let self, let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      let controller = WindowManager.shared.controller(for: self.window) else { return }
                controller.open(Library.shared.searchEngine.searchURL(text), disposition: .foregroundTab, opener: self.owner, allowSwitch: false)
            }
        }
    }

    private func trigger(_ original: NSMenuItem?, disposition: OpenDisposition) {
        guard let original, let action = original.action else { return }
        BrowserWebView.pending = (disposition, Source(value: self), Date().addingTimeInterval(3))
        NSApp.sendAction(action, to: original.target, from: original)
    }
}

// MARK: - Picture in picture

/// WebKit floats a page's main playing video through a method it doesn't publish; Safari's own button uses it.
/// Every use checks it's there first, so if it goes away the page's own button still works (WebKitSetup turns the
/// page-facing Picture in Picture on).
extension WKWebView {
    /// Bounces sideways only when the page scrolls sideways, as on an iPad and in Chrome; WebKit bounces every page.
    func bouncesSidewaysOnlyWhenWide() {
        let setter = NSSelectorFromString("_setAlwaysBounceHorizontal:")
        guard responds(to: setter), let method = class_getInstanceMethod(type(of: self), setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Set.self)(self, setter, false)
    }

    private static let canToggle = NSSelectorFromString("_canTogglePictureInPicture")
    private static let isActive = NSSelectorFromString("_isPictureInPictureActive")
    private static let toggle = NSSelectorFromString("_togglePictureInPicture")

    private func flag(_ selector: Selector) -> Bool {
        guard responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
    }

    /// True when the page has a playing video that can float.
    var canTogglePictureInPicture: Bool { responds(to: Self.toggle) && flag(Self.canToggle) }
    var isPictureInPictureActive: Bool { flag(Self.isActive) }

    func togglePictureInPicture() {
        guard canTogglePictureInPicture || isPictureInPictureActive else { return }
        perform(Self.toggle)
        PictureInPicture.floatSoon()
    }
}

enum PictureInPicture {
    private static let key = "PictureInPictureFollowsTabs"
    /// A playing video follows you in the window's mini player when you switch to another tab (`MiniPlayer`). On
    /// unless turned off in Settings. The key is from when it floated in Picture in Picture, kept so the choice stays.
    static var followsTabs: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// WebKit's Picture in Picture window (`PIPPanel`), in any app but Safari, comes up as an ordinary window: at the
    /// normal level, on the one desktop it opened on, so it went behind the next app you switched to and stayed
    /// behind when you changed desktops (#210). Each one is lifted to float as Safari's does, over every app, on
    /// every desktop and beside full screen windows, until it's closed.
    static func floatPanels() {
        for window in NSApp.windows where isPanel(window) { float(window) }
    }

    /// `floatPanels` now and again in a moment: WebKit makes the window a little after the video asks for it.
    static func floatSoon() {
        floatPanels()
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { floatPanels() } }
        }
    }

    nonisolated static func isPanel(_ window: NSWindow) -> Bool { isPanel(className: NSStringFromClass(type(of: window))) }
    nonisolated static func isPanel(className: String) -> Bool { className.hasSuffix("PIPPanel") }

    /// What the window may do as it floats: join every desktop and sit beside full screen windows; never move to
    /// one desktop alone, nor stay on one.
    nonisolated static func floatingBehavior(from current: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var behavior = current
        behavior.subtract([.moveToActiveSpace, .stationary, .managed])
        behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        return behavior
    }

    static func float(_ window: NSWindow) {
        let behavior = floatingBehavior(from: window.collectionBehavior)
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        if window.level < .floating { window.level = .floating }
        if window.hidesOnDeactivate { window.hidesOnDeactivate = false }
    }
}

/// Retires a web view (tab closed, slept or rebuilt): closes it on the next main-loop turn, then releases it. Never
/// freed inside a WebKit callback: on macOS 26.5 WebKit may be swapping the page into a new process and crashes if
/// the view is gone (#305, https://bugs.webkit.org/show_bug.cgi?id=316686). Closing first stops the page even if
/// something else still holds the view.
@MainActor
enum PageRetirement {
    private static var retiring: [WKWebView] = []

    /// `endingPasskeys`: a waiting passkey request is ended before the page closes, in case closing leaves it with macOS (#348).
    static func retire(_ webView: WKWebView, endingPasskeys: Bool = Passkeys.available) {
        guard endingPasskeys else { queue(webView); return }
        Passkeys.endRequests(in: webView) { queue(webView) }
    }

    private static func queue(_ webView: WKWebView) {
        retiring.append(webView)
        guard retiring.count == 1 else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { closeRetired() } }
    }

    private static func closeRetired() {
        let going = retiring
        retiring = []
        going.forEach(close)
    }

    private static let closeSelector = NSSelectorFromString("_close")

    private static func close(_ webView: WKWebView) {
        guard webView.responds(to: closeSelector) else { return }
        typealias Close = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(webView.method(for: closeSelector), to: Close.self)(webView, closeSelector)
    }
}
