import AppKit
import WebKit

/// The web page as a card: rounded, inset from the window, lifted by a hairline and a whisper of shadow.
final class PageCardView: NSView {
    private let clip = NSView()
    private let edge = CALayer()
    private(set) weak var webView: WKWebView?
    /// In split view, the pane you're working in gets a quiet accent edge.
    var isFocusedPane = false { didSet { refreshColors() } }
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
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            clip.frame = bounds
            webView?.frame = clip.bounds
            placeholder.frame = clip.bounds
            edge.frame = clip.bounds
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.Radius.card, cornerHeight: Tokens.Radius.card, transform: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            clip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
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
            newWebView.frame = clip.bounds
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
