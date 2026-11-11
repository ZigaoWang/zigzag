import AppKit
import WebKit

/// A page's own parent, holding the web view and nothing else. WebKit docks the Web Inspector beside the page, in
/// the page's parent and as large as it. A tab keeps its own (`Tab.pageHolder`) and whatever shows the tab borrows
/// it, so the inspector goes where its page goes.
final class PageHolder: NSView {
    /// A holder the size of the page, with the page in it.
    convenience init(holding webView: WKWebView) {
        self.init(frame: webView.frame)
        hold(webView)
    }

    /// Takes the page in, filling the holder.
    func hold(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}
