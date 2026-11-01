import AppKit

// The design language's shared parts. Values come from `Tokens`; these put them together the one way everything
// in Zigzag draws them:
// - a row: the hover fill under the pointer, a step darker pressed, and the soft card when it's the chosen one;
// - a section label: small, gray, never bold, with room above it instead of a line;
// - a glass tile: a see-through fill with a faint light edge, the card when chosen;
// - a pill button and a pill field;
// - a floating panel (`FloatingPanelView`): Liquid Glass on macOS 26, frosted before it.

// MARK: - Rows

extension InteractiveView {
    /// The one look for a row in a list: nothing at rest, the hover fill under the pointer, the pressed fill while
    /// held, and the soft card (`Tokens.Color.selectedFill`, a hairline edge, a faint shadow) when chosen.
    /// Hover is instant; a change of selection eases out in `Tokens.Motion.selection`.
    func applyRowStyle(animated: Bool) {
        let fill: NSColor? = isSelected ? (isHovered ? Tokens.Color.selectedHoverFill : Tokens.Color.selectedFill)
            : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered, duration: Tokens.Motion.selection)
        setLifted(isSelected)
    }
}

/// A row: a symbol or an image, a title, and optional quiet text at the trailing end. The chosen one is the soft
/// card. `Tokens.Metric.rowHeight` tall in the sidebar's scale; any height works.
class CardRow: InteractiveView {
    let iconView = NSImageView()
    let title: Label
    /// Quiet text at the trailing end: a count, a shortcut, a domain.
    let detail = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)

    /// A symbol, tinted like the rest of the app's icons.
    var symbol: String? {
        didSet { iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.TypeSize.row) }; needsLayout = true }
    }
    /// A picture (a favicon) in place of a symbol.
    var image: NSImage? {
        didSet { iconView.image = image; needsLayout = true }
    }

    init(title: String, symbol: String? = nil, detail: String = "", font: NSFont = Tokens.Font.row()) {
        self.title = Label(title, font: font, color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Tokens.Color.icon
        self.detail.stringValue = detail
        self.detail.alignment = .right
        [iconView, self.title, self.detail].forEach { addSubview($0) }
        defer { self.symbol = symbol }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// From the row's edge to its icon, and from the icon to the title: the sidebar's rows use the same.
    static let inset: CGFloat = Tokens.Space.x2 + 2

    override func layout() {
        super.layout()
        let side = Tokens.Metric.favicon
        var x = Self.inset - Label.inset
        if iconView.image != nil {
            iconView.frame = NSRect(x: Self.inset, y: (bounds.height - side) / 2, width: side, height: side)
            x = iconView.frame.maxX + Self.inset - Label.inset
        }
        let detailWidth = detail.stringValue.isEmpty ? 0 : detail.inkWidth + Label.inset * 2
        detail.frame = NSRect(x: bounds.width - Self.inset + Label.inset - detailWidth, y: (bounds.height - detail.lineHeight) / 2,
                              width: detailWidth, height: detail.lineHeight)
        let end = detailWidth > 0 ? detail.frame.minX - Tokens.Space.x2 : bounds.width - Self.inset
        title.frame = NSRect(x: x, y: (bounds.height - title.lineHeight) / 2, width: max(0, end - x), height: title.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        applyRowStyle(animated: animated)
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

// MARK: - Section labels

extension Label {
    /// A section's label ("Pinned", "Tabs", a group in a panel): small, gray, never bold. Give it generous room
    /// above, `Tokens.Metric.sectionLabelHeight` with the label low in it, in place of a divider.
    static func section(_ text: String) -> Label {
        let label = Label(text, font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
        label.setAccessibilityRole(.staticText)
        return label
    }
}

// MARK: - Glass tiles

/// A tile of soft glass: a see-through fill with a faint light edge and round corners (the favorites). Under the
/// pointer the glass brightens; the chosen one is the soft card. Put content in it as subviews.
class GlassTile: InteractiveView {
    /// A fine darker edge in place of the light one: the favorite's page is open in the background.
    var showsOpenEdge = false { didSet { if oldValue != showsOpenEdge { stateDidChange(animated: false) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(animated: Bool) {
        let fill = isSelected ? (isHovered ? Tokens.Color.selectedHoverFill : Tokens.Color.selectedFill)
            : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.glassHover : Tokens.Color.glassFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered, duration: Tokens.Motion.selection)
        setLifted(isSelected)
        guard !isSelected else { return }
        layer?.borderWidth = Tokens.Metric.hairline
        layer?.borderColor = cgColor(showsOpenEdge ? Tokens.Color.openEdge : Tokens.Color.glassEdge)
    }
}

// MARK: - Pill buttons

/// A capsule button: a symbol, a title, or both. `.plain` sits on a soft fill, `.quiet` shows a fill only under the
/// pointer, `.prominent` is the accent (one per surface, for the thing to do).
final class PillButton: InteractiveView {
    enum Style { case plain, quiet, prominent }
    let style: Style
    private let label: Label
    private let iconView = NSImageView()
    /// What it says, which can change (a toast's action, "Try Again"): the row around it lays out again.
    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            setAccessibilityLabel(newValue.isEmpty ? accessibilityLabel() : newValue)
            invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true
        }
    }
    /// The accent for `.prominent`; nil takes its window's.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }

    init(title: String = "", symbol: String? = nil, style: Style = .plain) {
        self.style = style
        label = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Tokens.Page.controlHeight))
        layer?.cornerCurve = .continuous
        iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.TypeSize.body) }
        iconView.imageScaling = .scaleNone
        iconView.isHidden = symbol == nil
        label.isHidden = title.isEmpty
        [iconView, label].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? symbol : title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var hasIcon: Bool { !iconView.isHidden }
    private var hasTitle: Bool { !label.isHidden }

    /// Says what just happened in place of the title for a moment ("Cleared"), then goes back.
    func flash(_ text: String, for seconds: TimeInterval = 1.6) {
        let original = title
        title = text
        isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.title = original
            self?.isEnabled = true
        }
    }

    var fittingWidth: CGFloat {
        guard hasTitle else { return Tokens.Page.controlHeight }
        return ceil(Tokens.Space.x3 * 2 + label.inkWidth + (hasIcon ? Tokens.Space.x4 + Tokens.Space.x1 + 2 : 0))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: Tokens.Page.controlHeight) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let side = Tokens.Space.x4
        guard hasTitle else {
            iconView.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            return
        }
        let total = label.inkWidth + (hasIcon ? side + Tokens.Space.x1 + 2 : 0)
        var x = round((bounds.width - total) / 2)
        if hasIcon {
            iconView.frame = NSRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
            x = iconView.frame.maxX + Tokens.Space.x1 + 2
        }
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor?
        let ink: NSColor
        switch style {
        case .prominent:
            let theme = Brand.Theme.for(self)
            let base = tint ?? theme.accent
            fill = isPressed ? (base.shadow(withLevel: 0.15) ?? base) : isHovered ? (base.highlight(withLevel: 0.08) ?? base) : base
            ink = theme.onAccent
        case .plain:
            fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
            ink = Tokens.Color.textPrimary
        case .quiet:
            fill = isPressed ? Tokens.Color.pressedFill : isHovered || isSelected ? Tokens.Color.hoverFill : nil
            ink = isHovered || isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        }
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        label.textColor = ink
        iconView.contentTintColor = style == .prominent ? ink : isHovered || isSelected ? Tokens.Color.textPrimary : Tokens.Color.icon
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }
}

// MARK: - Keycaps

/// A key, drawn small: Return on a chosen result, Tab beside "Search YouTube", a shortcut in a hint. A word or a
/// symbol on a faint fill with a hairline edge, `Tokens.Metric.keyCapHeight` tall. Never takes clicks.
final class KeyCap: NSView {
    private let label = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let iconView = NSImageView()

    /// `key` is a word ("Tab", "esc"); `symbol` an SF Symbol ("return", "command") in its place.
    init(_ key: String = "", symbol: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.small
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Tokens.Metric.hairline
        label.stringValue = key
        label.alignment = .center
        iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.TypeSize.small - 1) }
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = Tokens.Color.textSecondary
        label.isHidden = symbol != nil
        iconView.isHidden = symbol == nil
        [label, iconView].forEach { addSubview($0) }
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var width: CGFloat { iconView.isHidden ? max(Tokens.Metric.keyCapHeight + 4, label.inkWidth + Tokens.Space.x2 + 2) : Tokens.Metric.keyCapHeight + 4 }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Tokens.Metric.keyCapHeight) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - label.lineHeight) / 2, width: bounds.width, height: label.lineHeight)
        iconView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        Tokens.Motion.withoutAnimation {
            layer?.backgroundColor = cgColor(Tokens.Color.keyCapFill)
            layer?.borderColor = cgColor(Tokens.Color.keyCapEdge)
        }
    }
}

// MARK: - Panel material

/// What a floating panel is made of: Liquid Glass (regular) on macOS 26, a frosted popover material before it.
/// `FloatingPanelView.isGlass` puts one behind a panel's content; this makes one for a surface of your own.
enum PanelMaterial {
    static func make(radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            return glass
        }
        let frost = NSVisualEffectView()
        frost.material = .popover
        frost.blendingMode = .withinWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = radius
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        return frost
    }

    static func setRadius(_ radius: CGFloat, of view: NSView) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView { glass.cornerRadius = radius; return }
        view.layer?.cornerRadius = radius
    }
}
