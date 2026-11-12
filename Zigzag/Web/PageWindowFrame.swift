import AppKit
import WebKit

/// The window a page is told it's in: `window.outerWidth`, `outerHeight`, `screenX` and `screenY`.
///
/// WebKit asks the browser for these (WKUIDelegatePrivate's `_webView:getWindowFrameWithCompletionHandler:`, as
/// Safari answers it); with no answer a page sees a window 0 wide and 0 high. Sites read the window against the page
/// to guess the browser's zoom: Google Sheets, on a Safari older than 26.4, scales its grid by `outerWidth /
/// innerWidth`, so a 0 there drew it at a quarter of its resolution, blurred over the sharp first view (#161).
///
/// The answer is the page's own place on screen rather than Zigzag's whole window: a page beside the sidebar isn't
/// zoomed, and a window wider than the page by the sidebar's width also reads as an open Web Inspector to sites
/// that look for one that way.
enum PageWindowFrame {
    /// The page's frame in screen coordinates (Cocoa's, from the bottom left, which WebKit turns over itself).
    /// `pageOnScreen` is the page's rect on screen while it's in a window; out of one (a tab loading in the
    /// background) it's the page's size, at the window it'll show in when there is one.
    nonisolated static func frame(pageOnScreen: NSRect?, pageSize: NSSize, hostWindowFrame: NSRect?) -> NSRect {
        if let pageOnScreen, pageOnScreen.width > 0, pageOnScreen.height > 0 { return pageOnScreen.integral }
        let origin = hostWindowFrame?.origin ?? .zero
        return NSRect(origin: origin, size: NSSize(width: max(0, pageSize.width), height: max(0, pageSize.height))).integral
    }

    /// The frame for a web view, wherever it is now.
    @MainActor static func frame(of webView: WKWebView, hostWindow: NSWindow?) -> NSRect {
        let onScreen = webView.window.map { $0.convertToScreen(webView.convert(webView.bounds, to: nil)) }
        return frame(pageOnScreen: onScreen, pageSize: webView.bounds.size, hostWindowFrame: hostWindow?.frame)
    }
}
