import AppKit
import WebKit

/// Our WKWebView. Only adds what the browser frame needs: context menu tweaks and Peek.
final class BrowserWebView: WKWebView {
    weak var owner: Tab?
    private lazy var swipe = SwipeNavigator(webView: self)

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
    /// Set by a context menu item right before WebKit asks for a new web view.
    static var pendingDisposition: OpenDisposition?

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
                item.title = "Open Link in New Tab"
                let peek = NSMenuItem(title: "Open Link in Peek", action: #selector(openInPeek(_:)), keyEquivalent: "")
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
                    for (offset, (title, selector)) in [("Open Link in New Window", #selector(openInNewWindow(_:))),
                                                        ("Open Link in Private Window", #selector(openInPrivateWindow(_:)))].enumerated() {
                        let windowItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                        windowItem.target = self
                        windowItem.representedObject = original
                        menu.insertItem(windowItem, at: min(index + 2 + offset, menu.items.count))
                    }
                }
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.isHidden = true
            case "WKMenuItemIdentifierSearchWeb":
                // Searches with the engine you chose in Settings, in a new tab, not always Google in Safari.
                item.title = "Search with \(Library.shared.searchEngine.name)"
                item.action = #selector(searchSelection(_:))
                item.target = self
            default:
                break
            }
        }
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
        BrowserWebView.pendingDisposition = disposition
        NSApp.sendAction(action, to: original.target, from: original)
        DispatchQueue.main.async { BrowserWebView.pendingDisposition = nil }
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
