import AppKit
import WebKit

/// An extension's side panel (`chrome.sidePanel`), docked on the window's right beside the page, as in Chrome.
/// One per window; it stays while you move between tabs, and its header says whose it is, with a way to close it.
final class ExtensionSidePanelView: NSView {
    static let width: CGFloat = 380
    private let header = NSView()
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.body(.semibold))
    private let close = IconButton(symbol: "xmark", size: .compact, toolTip: String(localized: "Close Side Panel", comment: "Tooltip of the close button on an extension's side panel."))
    private let separator = CALayer()
    private(set) var webView: WKWebView?
    /// The extension the panel belongs to.
    private(set) var extensionID: String?
    /// The tab (the extension's id for it) the panel was opened for, with options for that tab; nil for every tab.
    private(set) var tabID: Int?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        header.addSubview(icon)
        header.addSubview(title)
        header.addSubview(close)
        header.wantsLayer = true
        header.layer?.addSublayer(separator)
        addSubview(header)
        close.onClick = { [weak self] _ in self?.onClose?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Shows an extension's page in the panel, replacing whatever was there.
    func show(_ webView: WKWebView, extensionID: String, name: String, image: NSImage?, tabID: Int? = nil) {
        self.webView?.removeFromSuperview()
        self.webView = webView
        self.extensionID = extensionID
        self.tabID = tabID
        title.stringValue = name
        icon.image = image ?? Tokens.Symbol.image("puzzlepiece.extension", size: 14)
        setAccessibilityLabel(String(localized: "\(name) side panel", comment: "What VoiceOver calls an extension's side panel. The placeholder is the extension's name."))
        addSubview(webView, positioned: .below, relativeTo: header)
        needsLayout = true
    }

    /// The corner radius, with the right corners squared where the window rounds them itself.
    func setShape(radius: CGFloat, squareRight: (top: Bool, bottom: Bool)) {
        Tokens.Motion.withoutAnimation {
            layer?.cornerRadius = radius
            // In this flipped view, "min Y" is the top.
            var corners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            if !squareRight.top { corners.insert(.layerMaxXMinYCorner) }
            if !squareRight.bottom { corners.insert(.layerMaxXMaxYCorner) }
            layer?.maskedCorners = corners
            layer?.borderWidth = radius == 0 ? 0 : 1
        }
    }

    func clear() {
        webView?.removeFromSuperview()
        webView = nil
        extensionID = nil
        tabID = nil
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 40, pad = Tokens.Space.x3
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        icon.frame = NSRect(x: pad, y: (height - 16) / 2, width: 16, height: 16)
        let closeSide = IconButton.Size.compact.side
        close.frame = NSRect(x: bounds.width - pad - closeSide + 4, y: (height - closeSide) / 2, width: closeSide, height: closeSide)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: icon.frame.maxX + Tokens.Space.x2, y: (height - titleHeight) / 2, width: close.frame.minX - icon.frame.maxX - Tokens.Space.x3, height: titleHeight)
        Tokens.Motion.withoutAnimation { separator.frame = NSRect(x: 0, y: height - 1, width: bounds.width, height: 1) }
        webView?.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
        layer?.borderColor = cgColor(Tokens.Color.panelEdge)
        separator.backgroundColor = cgColor(Tokens.Color.separator)
    }
}
