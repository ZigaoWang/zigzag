import AppKit
import WebKit

/// A page's own parent, holding the web view and nothing else. WebKit docks the Web Inspector beside the page, in
/// the page's parent and as large as it. A tab keeps its own (`Tab.pageHolder`) and whatever shows the tab borrows
/// it, so the inspector goes where its page goes.
final class PageHolder: NSView {
    /// The page it holds.
    private(set) weak var page: WKWebView?
    private var pageObserver: NSObjectProtocol?
    private var lastDocked = NSSize.zero
    /// The room what's docked beside the page takes changed: whoever sizes the holder for the page's sake hears.
    var onDockedRoomChange: (() -> Void)?

    /// The room what's docked beside the page (the Web Inspector) takes of the holder: its width at a side, its
    /// height at the bottom. WebKit lays the two out in the holder and keeps the inspector's own size whatever the
    /// holder's is, so a holder made a page's size plus this leaves the page exactly that size. None with nothing
    /// docked.
    var dockedRoom: NSSize {
        guard let page, subviews.contains(where: { $0 !== page && !$0.isHidden }) else { return .zero }
        return NSSize(width: max(0, bounds.width - page.frame.width), height: max(0, bounds.height - page.frame.height))
    }

    isolated deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

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
        page = webView
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        // WebKit moves the page as the inspector docks, leaves or is dragged wider: said once the room really changed.
        webView.postsFrameChangedNotifications = true
        pageObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: webView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteDockedRoom() }
        }
    }

    /// Says the docked room changed, if it did.
    private func noteDockedRoom() {
        guard dockedRoom != lastDocked else { return }
        lastDocked = dockedRoom
        onDockedRoomChange?()
    }

    /// The inspector comes into the holder after WebKit has made room for it, with no move of the page to say so:
    /// looked at again as it comes in. (Its leaving moves the page, which says it.)
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== page else { return }
        noteDockedRoom()
    }
}
