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
    /// The page's full screen, watched so the page is settled back in here once WebKit is done with it.
    private var fullScreenWatch: NSKeyValueObservation?
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
        // WebKit takes the page to a window of its own for an element's full screen, and puts it back here after.
        fullScreenWatch = webView.observe(\.fullscreenState) { [weak self] page, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, page === self.page, page.fullscreenState == .notInFullscreen else { return }
                    self.settlePage(relayout: true)
                }
            }
        }
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
        // Only WebKit puts the page back in here (`hold` adds it before it's the page): its full screen is ending.
        if subview === page { settlePage(relayout: false); return }
        noteDockedRoom()
    }

    /// The page back from its full screen (#204). WebKit puts it back at the frame it kept for it, which is only
    /// right if nothing moved meanwhile, and lays the page out for it only as it finishes: a page that went full
    /// screen by itself could be left laid out for the screen, with a band along its top and running past the card's
    /// edge, until the window was resized. So the page is kept within its holder (filling it unless the Web Inspector
    /// is docked beside it), the card lays out again, and once WebKit is done (`relayout`) the page is given its size
    /// afresh, as resizing the window would.
    func settlePage(relayout: Bool) {
        guard let page, page.superview === self else { return }
        if !bounds.contains(page.frame) || page.frame.isEmpty { page.frame = bounds }
        page.autoresizingMask = [.width, .height]
        superview?.needsLayout = true
        guard relayout else { return }
        let size = page.frame.size
        guard size.width > 1, size.height > 1 else { return }
        page.setFrameSize(NSSize(width: size.width, height: size.height - 1))
        page.setFrameSize(size)
    }
}
