import AppKit

/// The page's whole address at the start of the developer tools' bar (#141), as Arc's Developer Mode has it: with
/// the address kept in the sidebar, the bar above a page in Developer Mode says exactly where it is, scheme, port,
/// path and query, in monospaced figures, with the lock before it. A click edits it, as the address does; Copy
/// Link beside it and its own menu copy it.
final class DeveloperAddressView: InteractiveView {
    private let lock = NSImageView()
    private let text = Label("", font: Tokens.Font.code(Tokens.TypeSize.label), color: Tokens.Color.textPrimary)
    /// The bar is the top of the page's card, in the page's color: the neutral fills, as its buttons take.
    var isOnPage = false { didSet { if isOnPage != oldValue { stateDidChange(animated: false) } } }
    private(set) var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.small + 1
        layer?.cornerCurve = .continuous
        lock.imageScaling = .scaleNone
        lock.setAccessibilityElement(false)
        text.lineBreakMode = .byTruncatingTail
        text.setAccessibilityElement(false)
        addSubview(lock)
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The address as it's said: whole, its escapes read as the letters they are, without the slash a site's own
    /// page ends in ("https://example.com", "http://localhost:3000/admin?tab=2").
    nonisolated static func shown(_ url: URL?) -> String {
        guard let url else { return "" }
        var text = url.absoluteString
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path == "/", parts.query == nil, parts.fragment == nil, text.hasSuffix("/") {
            text.removeLast()
        }
        return text.removingPercentEncoding ?? text
    }

    func show(_ url: URL?) {
        self.url = url
        let secure = url?.scheme == "https"
        text.stringValue = Self.shown(url)
        lock.image = Tokens.Symbol.image(secure ? "lock" : "lock.open", size: Tokens.Symbol.inline)
        lock.contentTintColor = Tokens.Color.textSecondary
        lock.isHidden = url == nil
        toolTip = secure ? nil : SitePanel.notSecure
        setAccessibilityLabel(secure ? text.stringValue : String(localized: "\(text.stringValue), \(SitePanel.notSecure)", comment: "VoiceOver name of the page's whole address in the developer tools' bar on a plain http page: the address, then that it's not secure."))
        setAccessibilityHelp(String(localized: "Edits the address", comment: "VoiceOver hint of the page's whole address in the developer tools' bar: pressing it opens the address for editing."))
        needsLayout = true
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? (isOnPage ? Tokens.Color.pressedFill : Tokens.Chrome.pressed)
            : isHovered || isSelected ? (isOnPage ? Tokens.Color.hoverFill : Tokens.Chrome.hover) : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }

    /// From its leading edge to the lock's ink: the bar's buttons' own inset, so the lock lines up under them.
    static let pad = Tokens.Space.x2

    override func layout() {
        super.layout()
        let side = Tokens.Symbol.inline + 2
        lock.frame = NSRect(x: Self.pad, y: floor((bounds.height - side) / 2), width: side, height: side)
        let x = lock.isHidden ? Self.pad : lock.frame.maxX + Tokens.Space.x1 + 2
        let height = text.lineHeight
        text.frame = NSRect(x: x - Label.inset, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - x - Self.pad + Label.inset * 2), height: height)
    }
}
