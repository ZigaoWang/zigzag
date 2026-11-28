import AppKit
import WebKit

/// The browser's empty space, shown as the page Zigzag serves (`zigzag://blank`) rather than drawn natively.
///
/// It sits in the page card where a page sits, so it shares the card's shape and moves with it. It never takes a click
/// or the keyboard: nothing on a blank page is pressable, and the window's keys stay where they were. The native mark
/// (`EmptySpaceMark`) and ground (`EmptyPageBackdrop`) underneath stay as they are until the page has drawn over them,
/// which is also what a swipe shows while it paints two spaces' looks partway between.
final class BlankPageView: NSView {
    private(set) var page: WKWebView?
    /// Called when the served page covers the card, or stops covering it: the native mark is hidden while it does, so
    /// the two wordmarks are never drawn over each other.
    var onCover: ((Bool) -> Void)?
    /// False while the card is empty: a window with a page never makes a web view for its blank one.
    private var isActive = false
    private var hasDrawn = false
    /// Whether the card was last told the page is covering it, so a repeat doesn't and a real change always does.
    private var toldCovering = false
    /// What the card asks the page to show, and what the page was last served with (`page` nil until first shown).
    private var asked: Look?
    private var served: Look?

    private struct Look: Equatable {
        var space: UUID
        var isPrivate: Bool
        /// The picture's file, so a space whose picture changed is served again; nil is a space with none.
        var picture: String?
    }

    override var isFlipped: Bool { true }

    /// Nothing on the page is for clicking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `space`'s blank page: served the first time the card is empty, and served again when the space, its
    /// privacy or its picture changes, since the page is written with all three.
    func request(space: SpaceInfo, isPrivate: Bool) {
        asked = Look(space: space.id, isPrivate: isPrivate, picture: EmptyPage.picture(for: space, isPrivate: isPrivate))
        sync()
    }

    /// The empty card showed, or a page opened over it.
    func setActive(_ active: Bool) {
        isActive = active
        isHidden = !active
        // Whatever the card was last told, it is told again about this showing: a card that had a page on it was never
        // told the blank page covers anything.
        toldCovering = false
        sync()
    }

    /// A swipe is painting the empty card partway between two spaces' looks, which one served ground can't: the native
    /// backdrop shows that, and the page comes back when the swipe lands (`request`).
    func showWash() {
        setCovered(false)
    }

    // MARK: The page

    private func sync() {
        guard isActive, let asked else { return }
        guard let page else {
            load(asked)
            return
        }
        guard asked != served else {
            // Already this look: a swipe that hid the page brings it back as the swipe lands (`showWash`), since the
            // page's own ground can't be painted partway between two spaces' looks.
            setCovered(true)
            return
        }
        served = asked
        // Hidden as the new page loads: the old page still shows the space that was left, and the native backdrop under
        // it has already been drawn for the space arrived at.
        setCovered(false)
        page.load(URLRequest(url: ViewportPage.blankURL(for: asked.space, isPrivate: asked.isPrivate,
                                                        picture: asked.picture)))
    }

    private func load(_ look: Look) {
        served = look
        let configuration = WKWebViewConfiguration()
        // The handler that serves every other zigzag:// page serves this one too. None of a tab's own work: no site
        // scripts, no content blockers, no history, because nothing here is a website.
        HistoryPage.attach(to: configuration)
        let page = WKWebView(frame: bounds, configuration: configuration)
        page.autoresizingMask = [.width, .height]
        // The card's ground is the page's own, so WebKit's white is never seen between the two.
        page.setValue(false, forKey: "drawsBackground")
        page.setAccessibilityLabel(String(localized: "New tab", comment: "What the blank page is called to VoiceOver: the page a space shows with no tab open."))
        page.navigationDelegate = self
        page.alphaValue = 0
        addSubview(page)
        self.page = page
        page.load(URLRequest(url: ViewportPage.blankURL(for: look.space, isPrivate: look.isPrivate,
                                                        picture: look.picture)))
    }

    /// Drawn or not, and not while a swipe paints the wash. The swap is instant, not faded: the page draws the same mark
    /// on the same ground the native backdrop does, so fading between the two would only ghost one over the other. A web
    /// view's first frame is white, which is why the page stays hidden until it has drawn at all.
    private func setCovered(_ on: Bool) {
        guard let page else { return }
        let target: CGFloat = on && hasDrawn ? 1 : 0
        let covering = target > 0
        if page.alphaValue != target { page.alphaValue = target }
        guard toldCovering != covering else { return }
        toldCovering = covering
        onCover?(covering)
    }
}

extension BlankPageView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === page else { return }
        // Drawn even if the card is showing a page now: the next empty card gets this drawing at once rather than
        // waiting for another load.
        hasDrawn = true
        setCovered(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === page else { return }
        // The native mark and ground stay: they are what an empty card shows when its page can't be served.
        setCovered(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === page else { return }
        // A page that never commits fails here rather than in `didFail`: same answer, the native drawing stays.
        setCovered(false)
    }
}
