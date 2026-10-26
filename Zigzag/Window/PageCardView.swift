import AppKit
import WebKit

/// The web page as a card: rounded, inset from the window, lifted by a hairline and a whisper of shadow.
final class PageCardView: NSView {
    private let clip = NSView()
    private let edge = CALayer()
    private(set) weak var webView: WKWebView?
    /// In split view, the pane you're working in gets a quiet accent edge.
    var isFocusedPane = false { didSet { refreshColors() } }
    /// In split view each pane gets its own small toolbar.
    let header = PaneHeaderView()
    var showsHeader = false { didSet { header.isHidden = !showsHeader; needsLayout = true } }
    /// Reader, over the page, which stays loaded underneath.
    private(set) var overlay: NSView?

    /// No corners, edge or shadow: the page fills the window.
    var isEdgeToEdge: Bool {
        get { edgeToEdge }
        set { setEdgeToEdge(newValue, duration: 0) }
    }
    private var edgeToEdge = false

    /// Squares the corners off (or rounds them back) over `duration`, in step with the sidebar sliding away or back.
    func setEdgeToEdge(_ on: Bool, duration: TimeInterval) {
        guard on != edgeToEdge else { return }
        edgeToEdge = on
        let radius = on ? 0 : Tokens.Radius.card
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
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
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
            placeholder.frame = content
            overlay?.frame = content
            edge.frame = clip.bounds
            if progressLine.superlayer != nil { layoutProgress() }
            let radius = isEdgeToEdge ? 0 : Tokens.Radius.card
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
            edge.borderColor = cgColor(isFocusedPane ? Tokens.Color.accent.withAlphaComponent(0.55) : Tokens.Color.cardEdge)
            edge.borderWidth = isFocusedPane ? 2 : Tokens.Metric.hairline
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
        placeholder.image = placeholderImage
        placeholder.isHidden = placeholderImage == nil
        edge.removeFromSuperlayer()
        clip.layer?.addSublayer(edge)
    }

    func hidePlaceholder() {
        guard !placeholder.isHidden else { return }
        placeholder.isHidden = true
        placeholder.image = nil
    }
}
