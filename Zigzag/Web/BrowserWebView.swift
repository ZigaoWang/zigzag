import AppKit
import WebKit

/// Our WKWebView. Only adds what the browser frame needs: context menu tweaks and Peek.
final class BrowserWebView: WKWebView {
    weak var owner: Tab?
    private lazy var swipe = SwipeNavigator(webView: self)

    /// A swipe over something covering the page (the PDF viewer) goes back or forward like one over the page,
    /// unless it can still scroll that way (`room`).
    func handleSwipe(_ event: NSEvent, room: (left: Bool, right: Bool)) -> Bool { swipe.handle(event, room: room) }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Its tab went to the back mid-swipe: the swipe can't finish here any more.
        if window == nil { swipe.leftWindow() }
    }

    /// Edit › Select All (⌘A) on the History page selects every row, as in Safari, rather than the page's text. The
    /// menu takes ⌘A before the page sees it, so it's handed on here; with something typed in the page's search
    /// field, that text is what's selected, as usual.
    override func selectAll(_ sender: Any?) {
        guard HistoryPage.isHistory(url) else { super.selectAll(sender); return }
        evaluateJavaScript("window.zigzagSelectAll && window.zigzagSelectAll()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if result as? Bool != true { self?.superSelectAll(sender) }
            }
        }
    }

    private func superSelectAll(_ sender: Any?) { super.selectAll(sender) }

    override func scrollWheel(with event: NSEvent) {
        // A sideways swipe to go back or forward is taken here; everything else scrolls the page.
        if swipe.handle(event) { return }
        super.scrollWheel(with: event)
    }

    /// Three-finger swipes, for Macs set to swipe between pages that way: these come as swipe events, not scrolls.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, let owner, owner.canGoBackOrReturn { owner.goBack(); return }
        if event.deltaX < 0, canGoForward { goForward(); return }
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
        if #available(macOS 15.4, *), let owner {
            let extensionItems = ExtensionHost.shared.menuItems(for: owner)
            if !extensionItems.isEmpty {
                menu.addItem(.separator())
                extensionItems.forEach { menu.addItem($0) }
            }
        }
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                item.title = String(localized: "Open Link in New Tab", comment: "Item in a page's right-click menu.")
                let peek = NSMenuItem(title: String(localized: "Open Link in Peek", comment: "Item in a page's right-click menu. Peek is Zigzag's preview of a link over the page."), action: #selector(openInPeek(_:)), keyEquivalent: "")
                peek.target = self
                peek.representedObject = item
                if let index = menu.items.firstIndex(of: item) { menu.insertItem(peek, at: index + 1) }
                let original = item
                let tabItem = NSMenuItem(title: original.title, action: #selector(openInNewTab(_:)), keyEquivalent: "")
                tabItem.target = self
                tabItem.representedObject = original
                if let index = menu.items.firstIndex(of: original) {
                    menu.removeItem(at: index)
                    menu.insertItem(tabItem, at: index)
                    // Below Peek: a new window, and a private one.
                    for (offset, (title, selector)) in [(String(localized: "Open Link in New Window", comment: "Item in a page's right-click menu."), #selector(openInNewWindow(_:))),
                                                        (String(localized: "Open Link in Private Window", comment: "Item in a page's right-click menu."), #selector(openInPrivateWindow(_:)))].enumerated() {
                        let windowItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                        windowItem.target = self
                        windowItem.representedObject = original
                        menu.insertItem(windowItem, at: min(index + 2 + offset, menu.items.count))
                    }
                }
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
        Self.placeInspectElementLast(in: menu)
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

    @objc private func openInPeek(_ sender: NSMenuItem) {
        trigger(sender.representedObject as? NSMenuItem, disposition: .peek)
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
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      let controller = WindowManager.shared.controllers.first(where: { $0.window === self.window }) else { return }
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
/// Every use checks it's there first, so if it goes away the page's own button (PageScripts) still works.
extension WKWebView {
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
    }
}

enum PictureInPicture {
    private static let key = "PictureInPictureFollowsTabs"
    /// Float a playing video when you switch to another tab. On unless turned off in Settings.
    static var followsTabs: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
