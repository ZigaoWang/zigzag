import AppKit

// The design language's shared parts. Values come from `Tokens`; these put them together the one way everything
// in Zigzag draws them:
// - a row: the hover fill under the pointer, a step darker pressed, and the soft card when it's the chosen one;
// - a section label: small, gray, never bold, with room above it instead of a line;
// - a glass tile: a see-through fill with a faint light edge, the card when chosen;
// - a pill button and a pill field;
// - a floating panel (`FloatingPanelView`): opaque, leaning toward the space, one small shadow.

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
        didSet { iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.Symbol.row) }; needsLayout = true }
    }
    /// A picture (a favicon) in place of a symbol.
    var image: NSImage? {
        didSet { iconView.image = image; needsLayout = true }
    }

    init(title: String, symbol: String? = nil, detail: String = "", font: NSFont = Tokens.Font.row()) {
        self.title = Label(title, font: font, color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Tokens.Color.icon
        self.detail.stringValue = detail
        self.detail.alignment = .right
        [iconView, self.title, self.detail].forEach { addSubview($0) }
        // Set here directly: an observer doesn't run for a property set in its own class's init.
        self.symbol = symbol
        iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.Symbol.row) }
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

// MARK: - Press

extension NSView {
    /// The tactile press, shared by every button and row (`InteractiveView.pressScales`): down to
    /// `Motion.pressScale` around its middle as it's pressed, eased out at once, and eased back over `Motion.pressSettle`
    /// when let go, from wherever it is, so quick taps never queue or jump. Nothing waits on it. Not with Reduce Motion,
    /// and not for a press from the keyboard, where the darker fill says it.
    func showPress(_ pressed: Bool) {
        guard let layer else { return }
        let still = Tokens.Motion.reduceMotion || (pressed && Tokens.Motion.isFromKey)
        let target = pressed && !still ? Tokens.Motion.scale(Tokens.Motion.pressScale, of: layer) : CATransform3DIdentity
        let shown = layer.presentation()?.transform ?? layer.transform
        Tokens.Motion.withoutAnimation { layer.transform = target }
        guard !still, !CATransform3DEqualToTransform(shown, target) else { layer.removeAnimation(forKey: "press"); return }
        let animation: CABasicAnimation
        if pressed {
            animation = CABasicAnimation(keyPath: "transform")
            animation.duration = Tokens.Motion.pressIn
            animation.timingFunction = Tokens.Motion.easeOut
        } else {
            animation = Tokens.Motion.easeAnimation(keyPath: "transform", duration: Tokens.Motion.pressSettle)
        }
        animation.fromValue = NSValue(caTransform3D: shown)
        animation.toValue = NSValue(caTransform3D: target)
        layer.add(animation, forKey: "press")
    }
}

extension NSView {
    /// The sink, for things that read as objects (a space key, a pill button, a favorite): down `Motion.pressSink`
    /// as it's pressed, eased out at once, and back over `Motion.pressSettle` when let go, eased out, from wherever it
    /// is. The darker pressed fill goes with it. From the keyboard it doesn't move; with Reduce Motion, never.
    func showSink(_ pressed: Bool) {
        guard let layer else { return }
        let still = Tokens.Motion.reduceMotion || Tokens.Motion.isFromKey
        // The move is in the superview's layer, so "down" follows which way that one runs.
        let flipped = superview?.isFlipped ?? isFlipped
        let down = CATransform3DMakeTranslation(0, flipped ? Tokens.Motion.pressSink : -Tokens.Motion.pressSink, 0)
        let target = pressed && !still ? down : CATransform3DIdentity
        let shown = layer.presentation()?.transform ?? layer.transform
        Tokens.Motion.withoutAnimation { layer.transform = target }
        guard !still, !CATransform3DEqualToTransform(shown, target) else { layer.removeAnimation(forKey: "press"); return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: shown)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = pressed ? Tokens.Motion.pressIn : Tokens.Motion.pressSettle
        animation.timingFunction = Tokens.Motion.easeOut
        layer.add(animation, forKey: "press")
    }
}

// MARK: - Button looks

/// The looks a button takes, the same everywhere (`PillButton`, `PrimaryButton`, `TextButton.form`, `DropdownButton`):
/// - `.secondary`: white with a hairline edge and a faint shadow (a lighter step of the surface in dark mode);
/// - `.primary`: the one thing to do on a surface, a dark filled pill (light in dark mode), whatever the space;
/// - `.quiet`: no fill until the pointer is over it.
/// Hover is instant and a hair grayer; pressed is a step darker, at once, never a scale or a bounce.
enum ButtonLook { case secondary, primary, quiet }

extension InteractiveView {
    /// Paints the look for the control's state and returns the color its text and symbol take. `tint` replaces the
    /// primary's dark fill (a light button on the brand's blue, a destructive red), with `ink` on it.
    @discardableResult
    func applyButtonLook(_ look: ButtonLook, tint: NSColor? = nil, ink: NSColor? = nil) -> NSColor {
        let fill: NSColor?
        var text = Tokens.Color.textPrimary
        switch look {
        case .secondary:
            fill = isPressed ? Tokens.Color.controlPressed : isHovered || isSelected ? Tokens.Color.controlHover : Tokens.Color.controlFill
        case .primary:
            if let tint {
                fill = isPressed ? (tint.shadow(withLevel: 0.15) ?? tint) : isHovered ? (tint.highlight(withLevel: 0.08) ?? tint) : tint
                text = ink ?? .white
            } else {
                fill = isPressed ? Tokens.Color.primaryPressed : isHovered ? Tokens.Color.primaryHover : Tokens.Color.primaryFill
                text = ink ?? Tokens.Color.onPrimary
            }
        case .quiet:
            fill = isPressed ? Tokens.Color.pressedFill : isHovered || isSelected ? Tokens.Color.hoverFill : nil
            text = isHovered || isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        }
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        let edged = look == .secondary
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = edged ? Tokens.Metric.hairline : 0
            layer?.borderColor = cgColor(Tokens.Color.controlEdge)
            layer?.shadowOpacity = edged && isEnabled ? 1 : 0
            layer?.shadowColor = cgColor(Tokens.Color.controlShadow)
            layer?.shadowRadius = Tokens.Shadow.controlRadius
            layer?.shadowOffset = CGSize(width: 0, height: isFlipped ? Tokens.Shadow.controlDrop : -Tokens.Shadow.controlDrop)
        }
        alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
        return text
    }

    /// The faint shadow's shape, set once the control has its size so it isn't worked out from its contents.
    func updateButtonShadowPath() {
        let radius = layer?.cornerRadius ?? 0
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

// MARK: - Pill buttons

/// A capsule button: a symbol, a title, or both. `.plain` is the secondary look (white, a hairline, a faint shadow),
/// `.quiet` shows a fill only under the pointer, `.prominent` is the primary, a dark filled pill (one per surface,
/// for the thing to do).
final class PillButton: InteractiveView {
    enum Style { case plain, quiet, prominent }
    let style: Style
    private let label: Label
    private let iconView = NSImageView()
    /// What it says, which can change (a toast's action, "Try Again"): the row around it lays out again.
    private var written = ""
    var title: String {
        get { written }
        set {
            written = newValue
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            setAccessibilityLabel(newValue.isEmpty ? accessibilityLabel() : newValue)
            invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true
        }
    }
    /// A fill for `.prominent` in place of the dark one (a red for what can't be undone); nil is the primary's.
    var tint: NSColor? { didSet { stateDidChange(animated: false) } }
    /// For an action that can't be undone (Delete): `.prominent` turns red, the others take red ink.
    var isDestructive = false { didSet { stateDidChange(animated: false) } }
    /// Set both to draw the button in other colors: a light pill on the brand's blue frame (the welcome).
    var customFill: NSColor? { didSet { stateDidChange(animated: false) } }
    var customInk: NSColor? { didSet { stateDidChange(animated: false) } }

    init(title: String = "", symbol: String? = nil, style: Style = .plain) {
        self.style = style
        written = title
        label = Label(title, font: Tokens.Font.control(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Tokens.Page.controlHeight))
        pressSinks = true
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

    /// Room on each side of the title: a touch more for the outlined and filled looks, which read as objects.
    private var sidePad: CGFloat { style == .quiet ? Tokens.Space.x3 : Tokens.Space.x4 - 2 }

    var fittingWidth: CGFloat {
        guard hasTitle else { return Tokens.Page.controlHeight }
        return ceil(sidePad * 2 + label.inkWidth + (hasIcon ? Tokens.Space.x4 + Tokens.Space.x1 + 2 : 0))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: Tokens.Page.controlHeight) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateButtonShadowPath()
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
        let ink: NSColor
        switch style {
        case _ where customFill != nil:
            ink = applyButtonLook(.primary, tint: customFill, ink: customInk ?? Tokens.Color.textPrimary)
        case .prominent:
            ink = isDestructive ? applyButtonLook(.primary, tint: Tokens.Color.destructive, ink: .white)
                // The space's own accent, as a switch that's on: one color for "this is the thing to do".
                : applyButtonLook(.primary, tint: tint ?? Brand.Theme.for(self).accent, ink: tint.map { _ in .white } ?? Brand.Theme.for(self).onAccent)
        case .plain: ink = applyButtonLook(.secondary)
        case .quiet: ink = applyButtonLook(.quiet)
        }
        let tinted = style == .prominent || customFill != nil
        label.textColor = isDestructive && !tinted ? Tokens.Color.destructive : ink
        iconView.contentTintColor = tinted ? ink : isHovered || isSelected || style == .plain ? Tokens.Color.textPrimary : Tokens.Color.icon
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
        iconView.image = symbol.map { Tokens.Symbol.image($0, size: Tokens.Symbol.inline) }
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

// MARK: - Line drawings

/// Zigzag's own glyphs where a stock symbol says too little: thin precise lines, one stroke (`stroke`), round caps and
/// joins, on a 16pt square with the same 1.5pt margin, so they sit together like one set of drawings. Templates, so
/// they take whatever ink they're given.
enum LineGlyph {
    static let stroke: CGFloat = 1.1
    static let side: CGFloat = 16

    private static func draw(_ body: @escaping (NSBezierPath) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            body(path)
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Something new: a plus, shorter and lighter than type's, its arms the same length.
    static let plus = draw { path in
        path.move(to: NSPoint(x: 8, y: 3.5)); path.line(to: NSPoint(x: 8, y: 12.5))
        path.move(to: NSPoint(x: 3.5, y: 8)); path.line(to: NSPoint(x: 12.5, y: 8))
    }
}

// MARK: - Panel material

/// A panel's blur: only something to see through, never something to click.
final class PanelFrost: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Frost for a brand moment's glass (`GlassSurface`): Liquid Glass on macOS 26, a frosted popover material before it.
/// `FloatingPanelView.isGlass` puts one behind a panel's content; this makes one for a surface of your own.
enum PanelMaterial {
    /// A real blur on every macOS, with the panel's wash drawn over it. Liquid Glass draws above its sibling views,
    /// so the wash never landed on it and a busy page read straight through text panels like the address bar.
    static func make(radius: CGFloat) -> NSView {
        let frost = PanelFrost()
        frost.material = .popover
        frost.blendingMode = .withinWindow
        frost.state = .followsWindowActiveState
        frost.wantsLayer = true
        frost.layer?.cornerRadius = radius
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        // The effect view can redo its own layer, so the layer's corners alone don't reliably hold its blur: the
        // mask is what it keeps to.
        frost.maskImage = mask(radius: radius)
        return frost
    }

    static func setRadius(_ radius: CGFloat, of view: NSView) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView { glass.cornerRadius = radius; return }
        guard view.layer?.cornerRadius != radius else { return }
        view.layer?.cornerRadius = radius
        (view as? NSVisualEffectView)?.maskImage = mask(radius: radius)
    }

    /// A rounded rectangle that stretches to any size, its corners kept at `radius`.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Dialogs

/// The top of every dialog (`Tokens.Dialog`): a picture (a site's or an app's icon, or a symbol on a soft circle of
/// the accent), the question in the heading's weight, and a quiet line under it (the site, the version).
final class DialogHeader: NSView {
    private let picture = NSImageView()
    private let circle = ColorView(color: .clear)
    let title: NSTextField
    let subtitle = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    /// Room kept at the trailing end for a close button in the panel's corner.
    var trailingRoom: CGFloat = 0 { didSet { needsLayout = true } }

    init(title text: String, subtitle detail: String = "") {
        title = NSTextField(wrappingLabelWithString: text)
        title.font = Tokens.Font.heading()
        title.textColor = Tokens.Color.textPrimary
        title.isSelectable = false
        title.maximumNumberOfLines = 3
        super.init(frame: .zero)
        subtitle.stringValue = detail
        subtitle.lineBreakMode = .byTruncatingMiddle
        circle.wantsLayer = true
        circle.layer?.cornerRadius = Tokens.Dialog.iconSide / 2
        circle.isHidden = true
        picture.isHidden = true
        [circle, picture, title, subtitle].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// A picture of its own: a favicon, an app's or an extension's icon.
    func setImage(_ image: NSImage?) {
        picture.image = image
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.contentTintColor = nil
        picture.isHidden = image == nil
        circle.isHidden = true
        needsLayout = true
    }

    /// A symbol in the accent on a soft circle of it.
    func setSymbol(_ name: String, tint: NSColor) {
        picture.image = Tokens.Symbol.image(name, size: Tokens.TypeSize.heading)
        picture.imageScaling = .scaleNone
        picture.contentTintColor = tint
        picture.isHidden = false
        circle.color = tint.withAlphaComponent(Tokens.Color.selectionAlpha)
        circle.isHidden = false
        needsLayout = true
    }

    private var hasPicture: Bool { !picture.isHidden }
    private var textX: CGFloat { hasPicture ? Tokens.Dialog.iconSide + Tokens.Space.x3 : 0 }

    private func titleHeight(_ width: CGFloat) -> CGFloat {
        ceil(title.sizeThatFits(NSSize(width: max(0, width - textX - trailingRoom) + Label.inset * 2, height: 400)).height)
    }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        titleHeight(width) + (subtitle.stringValue.isEmpty ? 0 : 2 + subtitle.lineHeight)
    }

    func height(for width: CGFloat) -> CGFloat { max(hasPicture ? Tokens.Dialog.iconSide : 0, textHeight(width)) }

    override func layout() {
        super.layout()
        let side = Tokens.Dialog.iconSide
        let text = textHeight(bounds.width)
        let total = height(for: bounds.width)
        circle.frame = NSRect(x: 0, y: round((total - side) / 2), width: side, height: side)
        picture.frame = circle.frame
        let width = max(0, bounds.width - textX - trailingRoom)
        // The title draws its text Label.inset in from its edges, as the subtitle does: both are set that much wider, so
        // their first letters line up where the text starts.
        title.frame = NSRect(x: textX - Label.inset, y: round((total - text) / 2), width: width + Label.inset * 2, height: titleHeight(bounds.width))
        subtitle.isHidden = subtitle.stringValue.isEmpty
        subtitle.frame = NSRect(x: textX - Label.inset, y: title.frame.maxY + 2, width: width + Label.inset * 2, height: subtitle.lineHeight)
    }
}

/// A dialog's answers: pill buttons at the trailing end, the main one last and filled; a quiet choice can sit
/// alone at the leading end. When they don't fit side by side, the trailing ones share the row evenly.
final class DialogButtons: NSView {
    var leading: [PillButton] = [] { didSet { replace(oldValue, with: leading) } }
    var trailing: [PillButton] = [] { didSet { replace(oldValue, with: trailing) } }

    private func replace(_ old: [PillButton], with new: [PillButton]) {
        old.forEach { if !new.contains($0) { $0.removeFromSuperview() } }
        new.forEach { if $0.superview !== self { addSubview($0) } }
        needsLayout = true
    }

    override var isFlipped: Bool { true }
    static var height: CGFloat { Tokens.Page.controlHeight }

    private static func width(_ button: PillButton) -> CGFloat { max(button.fittingWidth, Tokens.Dialog.minButtonWidth) }

    override func layout() {
        super.layout()
        let gap = Tokens.Dialog.buttonGap, h = Self.height
        let shown = trailing.filter { !$0.isHidden }
        let lead = leading.filter { !$0.isHidden }
        let leadWidth = lead.reduce(0) { $0 + $1.fittingWidth + gap }
        let wanted = shown.reduce(0) { $0 + Self.width($1) } + gap * CGFloat(max(0, shown.count - 1))
        let even = wanted > bounds.width - leadWidth
        let each = (bounds.width - gap * CGFloat(max(0, shown.count - 1))) / CGFloat(max(1, shown.count))
        var x = bounds.width
        for button in shown.reversed() {
            let w = even ? each : Self.width(button)
            x -= w
            button.frame = NSRect(x: x, y: 0, width: w, height: h)
            x -= gap
        }
        var lx: CGFloat = 0
        for button in lead {
            // No room beside the answers: the quiet choice steps aside rather than squeeze them.
            button.alphaValue = even ? 0 : 1
            button.frame = NSRect(x: lx, y: 0, width: button.fittingWidth, height: h)
            lx += button.fittingWidth + gap
        }
    }
}

extension NSTextField {
    /// A dialog's or a page's explaining sentence: body size, secondary, wrapping.
    static func dialogText(_ text: String, font: NSFont = Tokens.Font.body()) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = Tokens.Color.textSecondary
        field.isSelectable = false
        return field
    }

    /// Its height when wrapped to `width`.
    func wrappedHeight(_ width: CGFloat) -> CGFloat { ceil(sizeThatFits(NSSize(width: max(0, width), height: 2000)).height) }
}
