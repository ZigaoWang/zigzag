import AppKit
import WebKit

/// The web page as a card: rounded, lifted by a hairline and a whisper of shadow, inset from the window or, borderless,
/// meeting its edges.
final class PageCardView: NSView {
    private let clip = NSView()
    private let edge = CALayer()
    private(set) weak var webView: WKWebView?
    /// In split view, the pane you're working in: its toolbar is at full strength, the other's dims. An outline
    /// would run along the window's own edges where a pane meets them.
    var isFocusedPane = false { didSet { refreshColors() } }
    /// In split view, a pane you're not working in.
    var isUnfocusedPane = false { didSet { refreshColors() } }
    /// In split view each pane gets its own small toolbar.
    let header = PaneHeaderView()
    var showsHeader = false { didSet { header.isHidden = !showsHeader; needsLayout = true } }
    /// Reader, over the page, which stays loaded underneath.
    private(set) var overlay: NSView?
    /// What covers the shown tab's page: its PDF viewer, over WebKit's own, or Settings.
    private weak var document: NSView?
    private var documentToken: SignalToken?

    /// No corners, edge or shadow: the page fills the window.
    var isEdgeToEdge: Bool {
        get { edgeToEdge }
        set { setEdgeToEdge(newValue, duration: 0) }
    }
    private var edgeToEdge = false

    /// The right corners that are the window's own corners, which the window rounds itself: square here.
    var squaresRightCorners = (top: false, bottom: false) { didSet { if squaresRightCorners != oldValue { needsLayout = true } } }
    /// Meeting the window's edges beside the sidebar: its corners curve like the window's, so a split's two panes
    /// match across the gap and the corner by the sidebar matches the window's.
    var isAttached = false { didSet { if isAttached != oldValue { needsLayout = true } } }

    /// Squares the corners off (or rounds them back) over `duration`, in step with the sidebar sliding away or back.
    func setEdgeToEdge(_ on: Bool, duration: TimeInterval) {
        guard on != edgeToEdge else { return }
        edgeToEdge = on
        let radius = on ? 0 : isAttached ? Tokens.Radius.window : Tokens.Radius.card
        CATransaction.begin()
        CATransaction.setDisableActions(duration == 0)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        clip.layer?.cornerRadius = radius
        edge.cornerRadius = radius
        edge.opacity = on ? 0 : 1
        layer?.shadowOpacity = on ? 0 : 1
        CATransaction.commit()
        needsLayout = true
    }

    /// Page loading, in the space's accent: a thin line along the card's top edge that grows with the load and fades when done.
    private let progressLine = CALayer()
    private var progress: CGFloat = 0
    private var isShowingProgress = false

    func setLoading(_ loading: Bool, progress value: Double) {
        if progressLine.superlayer == nil {
            progressLine.opacity = 0
            progressLine.anchorPoint = CGPoint(x: 0, y: 1)
            // Above the page's own layer.
            progressLine.zPosition = 100
            clip.layer?.addSublayer(progressLine)
        }
        Tokens.Motion.withoutAnimation { progressLine.backgroundColor = cgColor(Brand.Theme.current.accent) }
        let target = loading ? max(0.08, CGFloat(value)) : 1
        guard loading || isShowingProgress else { return }
        if loading && !isShowingProgress {
            // A fresh load starts from the left edge.
            isShowingProgress = true
            progress = 0
            Tokens.Motion.withoutAnimation { progressLine.opacity = 1; layoutProgress() }
        }
        guard target >= progress || !loading else { return }
        progress = target
        CATransaction.begin()
        CATransaction.setAnimationDuration(loading ? 0.3 : 0.18)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        layoutProgress()
        CATransaction.commit()
        guard !loading else { return }
        isShowingProgress = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        progressLine.opacity = 0
        CATransaction.commit()
    }

    private func layoutProgress() {
        let top = showsHeader ? PaneHeaderView.height : 0
        progressLine.bounds = CGRect(x: 0, y: 0, width: clip.bounds.width * progress, height: 2)
        progressLine.position = CGPoint(x: 0, y: clip.bounds.height - top)
    }

    func setOverlay(_ view: NSView?) {
        overlay?.removeFromSuperview()
        overlay = view
        if let view {
            // Placed at once and kept in step with the card, so nothing of the page shows around it.
            let top = showsHeader ? PaneHeaderView.height : 0
            view.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height - top)
            view.autoresizingMask = [.width, .height]
            clip.addSubview(view, positioned: .below, relativeTo: header)
        }
    }

    /// Shown while a suspended tab wakes up so the card never flashes blank.
    private let placeholder = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Tokens.Shadow.cardRadius
        layer?.shadowOffset = Tokens.Shadow.cardOffset

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Tokens.Radius.card
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        addSubview(clip)

        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.imageAlignment = .alignTop
        placeholder.isHidden = true
        clip.addSubview(placeholder)

        edge.cornerRadius = Tokens.Radius.card
        edge.cornerCurve = .continuous
        edge.borderWidth = Tokens.Metric.hairline
        edge.zPosition = 10
        clip.layer?.addSublayer(edge)
        header.isHidden = true
        clip.addSubview(header)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            clip.frame = bounds
            let top = showsHeader ? PaneHeaderView.height : 0
            // The clip isn't flipped: the header sits at its top edge, the page fills the rest below.
            header.frame = NSRect(x: 0, y: clip.bounds.height - PaneHeaderView.height, width: clip.bounds.width, height: PaneHeaderView.height)
            let content = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height - top)
            webView?.frame = content
            document?.frame = content
            placeholder.frame = content
            overlay?.frame = content
            edge.frame = clip.bounds
            if progressLine.superlayer != nil { layoutProgress() }
            let radius = isEdgeToEdge ? 0 : isAttached ? Tokens.Radius.window : Tokens.Radius.card
            clip.layer?.cornerRadius = radius
            edge.cornerRadius = radius
            // The clip isn't flipped: its top corners are at max Y.
            var corners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            if squaresRightCorners.top { corners.remove(.layerMaxXMaxYCorner) }
            if squaresRightCorners.bottom { corners.remove(.layerMaxXMinYCorner) }
            clip.layer?.maskedCorners = corners
            edge.maskedCorners = corners
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            clip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
            progressLine.backgroundColor = cgColor(Brand.Theme.current.accent)
            edge.borderColor = cgColor(Tokens.Color.cardEdge)
            edge.borderWidth = Tokens.Metric.hairline
            header.alphaValue = isUnfocusedPane ? 0.45 : 1
            layer?.shadowColor = cgColor(Tokens.Color.cardShadow)
        }
    }

    /// Puts a web view in the card. The new view goes in before the old one leaves, so nothing flickers.
    func show(_ newWebView: WKWebView?, placeholderImage: NSImage? = nil) {
        guard newWebView !== webView else { return }
        let old = webView
        if let newWebView {
            let top = showsHeader ? PaneHeaderView.height : 0
            newWebView.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height - top)
            newWebView.autoresizingMask = [.width, .height]
            clip.addSubview(newWebView, positioned: .below, relativeTo: placeholder)
        }
        webView = newWebView
        if let old, old.superview === clip { old.removeFromSuperview() }
        let owner = (newWebView as? BrowserWebView)?.owner
        documentToken = owner?.changed.observe { [weak self] change in if change == .pdf || change == .settings { self?.refreshDocument() } }
        refreshDocument()
        placeholder.image = placeholderImage
        placeholder.isHidden = placeholderImage == nil
        edge.removeFromSuperlayer()
        clip.layer?.addSublayer(edge)
    }

    /// Puts the shown tab's PDF viewer (or Settings) over its page, or takes it away. Typing goes to it, as it did to
    /// the page.
    private func refreshDocument() {
        let owner = (webView as? BrowserWebView)?.owner
        let viewer: NSView? = owner?.pdfViewer ?? owner?.settingsView
        guard viewer !== document else { return }
        if let document, document.superview === clip {
            // Typing was in the viewer going away: it goes back to the page rather than nowhere.
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: document) {
                window.makeFirstResponder(webView)
            }
            document.removeFromSuperview()
        }
        document = viewer
        guard let viewer, let webView else { return }
        viewer.frame = webView.frame
        viewer.autoresizingMask = [.width, .height]
        clip.addSubview(viewer, positioned: .above, relativeTo: webView)
        if let window, window.firstResponder === webView { window.makeFirstResponder((viewer as? PDFViewerView)?.pdfView ?? viewer) }
    }

    func hidePlaceholder() {
        guard !placeholder.isHidden else { return }
        placeholder.isHidden = true
        placeholder.image = nil
    }
}
