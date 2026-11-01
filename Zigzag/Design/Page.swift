import AppKit

// Zigzag's page design, shared by its built-in pages (History in HTML, Settings in AppKit) and meant for its other
// surfaces too: one plain surface, the small wordmark and a semibold title at the top left, the search field and
// actions at the top right, quiet rows under it. The values live in `Tokens.Page` and `Tokens.Color`; the HTML pages
// get them from `PageStyle`, generated at serve time, so the two can't drift.

// MARK: - Native

/// The top left of a page: the drawn wordmark in the space's accent, a hairline, and the page's title.
final class PageTitleView: NSView {
    private let wordmark = WordmarkView()
    private let divider = ColorView(color: Tokens.Color.separator)
    private let label = Label("", font: Tokens.Font.pageTitle(), color: Tokens.Color.textPrimary)
    private var themeToken: SignalToken?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }

    /// Off when the wordmark is shown elsewhere on the page, or there's no room for it.
    var showsWordmark = true { didSet { wordmark.isHidden = !showsWordmark; divider.isHidden = !showsWordmark; needsLayout = true } }

    init(_ title: String) {
        super.init(frame: .zero)
        [wordmark, divider, label].forEach { addSubview($0) }
        self.title = title
        setAccessibilityElement(false)
        label.setAccessibilityRole(.staticText)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refreshTheme() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static var wordmarkWidth: CGFloat { ceil(Tokens.Page.wordmarkHeight * WordmarkView.aspect) }

    /// The width it needs.
    var fittingWidth: CGFloat {
        (showsWordmark ? Self.wordmarkWidth + Tokens.Space.x3 * 2 + Tokens.Metric.hairline : 0) + label.textWidth
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTheme()
    }

    private func refreshTheme() { wordmark.color = Brand.Theme.for(self).accent }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        // Too narrow for the wordmark and some of the title: the title alone, rather than the two overlapping.
        let roomy = bounds.width >= Self.wordmarkWidth + Tokens.Space.x6 + min(label.textWidth, Tokens.Space.x16)
        wordmark.isHidden = !showsWordmark || !roomy
        divider.isHidden = wordmark.isHidden
        if !wordmark.isHidden {
            let h = Tokens.Page.wordmarkHeight
            wordmark.frame = NSRect(x: 0, y: round((bounds.height - h) / 2), width: Self.wordmarkWidth, height: h)
            x = wordmark.frame.maxX + Tokens.Space.x3
            let lineHeight: CGFloat = Tokens.Space.x5
            divider.frame = NSRect(x: x, y: round((bounds.height - lineHeight) / 2), width: Tokens.Metric.hairline, height: lineHeight)
            x = divider.frame.maxX + Tokens.Space.x3
        }
        label.frame = NSRect(x: x - Label.inset, y: round((bounds.height - label.lineHeight) / 2),
                             width: max(0, bounds.width - x + Label.inset), height: label.lineHeight)
    }
}

/// A page's header bar: something at the left (the title), controls at the right (search, buttons), on the page's
/// surface, with a hairline under it once the page scrolls under it.
final class PageHeader: NSView {
    var leading: NSView? {
        didSet { oldValue?.removeFromSuperview(); leading.map { addSubview($0) }; needsLayout = true }
    }
    /// Right to left in reading order: the last one sits at the right edge.
    var trailing: [NSView] = [] {
        didSet {
            oldValue.forEach { if !trailing.contains($0) { $0.removeFromSuperview() } }
            trailing.forEach { if $0.superview !== self { addSubview($0) } }
            // A page's search is the outlined pill, like the buttons beside it.
            trailing.compactMap { $0 as? FilledField }.forEach { $0.isOutlined = true; $0.isPill = true }
            needsLayout = true
        }
    }
    /// Where the content starts and ends across the bar, so the header lines up with what's under it.
    var contentFrame: (minX: CGFloat, maxX: CGFloat) = (0, 0) { didSet { needsLayout = true } }
    /// The hairline under the bar, shown while something has scrolled under it.
    var showsEdge = false { didSet { edge.isHidden = !showsEdge } }
    private let edge = ColorView(color: Tokens.Color.separator)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.isHidden = true
        addSubview(edge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = cgColor(Tokens.Color.surface) }

    override func layout() {
        super.layout()
        let h = Tokens.Page.controlHeight, y = Tokens.Page.headerTop
        var right = contentFrame.maxX
        // The title keeps the room it needs; a search field gives way first, down to a usable width.
        let titleNeeds = (leading as? PageTitleView)?.fittingWidth ?? 0
        let others = trailing.filter { !$0.isHidden && !($0 is FilledField) }.map { Self.width(of: $0) + Tokens.Space.x2 }.reduce(0, +)
        for view in trailing.reversed() where !view.isHidden {
            var wanted = Self.width(of: view)
            if view is FilledField {
                let spare = contentFrame.maxX - contentFrame.minX - others - titleNeeds - Tokens.Space.x2
                wanted = max(min(wanted, spare), Self.minimumSearchWidth)
            }
            let width = min(wanted, max(0, right - contentFrame.minX))
            view.frame = NSRect(x: right - width, y: y, width: width, height: h)
            right = view.frame.minX - Tokens.Space.x2
        }
        leading?.frame = NSRect(x: contentFrame.minX, y: y, width: max(0, right - Tokens.Space.x2 - contentFrame.minX), height: h)
        edge.frame = NSRect(x: 0, y: bounds.height - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
    }

    private static let minimumSearchWidth: CGFloat = 160

    private static func width(of view: NSView) -> CGFloat {
        if view is FilledField { return Tokens.Page.searchWidth }
        if let button = view as? TextButton { return ceil(button.fittingWidth) }
        if let pill = view as? PillButton { return pill.fittingWidth }
        let size = view.fittingSize
        return size.width > 0 ? size.width : view.intrinsicContentSize.width
    }
}

extension Label {
    /// A group's heading on a page ("Tabs", "Browsing data"): quiet gray, a size up from a panel's section label,
    /// over the group with room above it in place of a line.
    static func groupHeading(_ text: String) -> Label {
        let label = Label(text, font: Tokens.Font.pageLabel(), color: Tokens.Color.textTertiary)
        label.setAccessibilityRole(.staticText)
        return label
    }
}

/// A row in a list of places (Settings' sections): a symbol and a name, a soft fill of the accent when chosen, the
/// hover fill under the pointer. With little room it's just the symbol.
class ListItem: InteractiveView {
    private let icon = NSImageView()
    private let label: Label
    /// Quiet text at the trailing end: how many are in it.
    private let count = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    let title: String
    var detail: String {
        get { count.stringValue }
        set { count.stringValue = newValue; count.isHidden = newValue.isEmpty || isCompact; needsLayout = true }
    }
    /// Off where the list draws one selection that glides between its places (`SelectionGlide`): the chosen item
    /// then shows only its accent symbol.
    var drawsSelection = true { didSet { stateDidChange(animated: false) } }
    var isCompact = false {
        didSet {
            label.isHidden = isCompact
            count.isHidden = isCompact || count.stringValue.isEmpty
            toolTip = isCompact ? title : nil
            needsLayout = true
        }
    }

    init(title: String, symbol: String) {
        self.title = title
        label = Label(title, font: Tokens.Font.pageRow(.regular), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        // Monochrome outline symbols, the size of the text beside them.
        icon.image = Tokens.Symbol.image(symbol, size: Tokens.TypeSize.pageRow)
        icon.imageScaling = .scaleNone
        count.alignment = .right
        count.isHidden = true
        [icon, label, count].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let side: CGFloat = 20
        if isCompact {
            icon.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        } else {
            // The symbol's ink, not its box, starts at the row's inset, so it lines up with text above and below.
            icon.frame = NSRect(x: Tokens.Page.rowInset - 2, y: (bounds.height - side) / 2, width: side, height: side)
            let x = icon.frame.maxX + Tokens.Space.x2 + 2 - Label.inset
            let countWidth = count.isHidden ? 0 : count.inkWidth + Label.inset * 2
            count.frame = NSRect(x: bounds.width - Tokens.Page.rowInset + Label.inset - countWidth, y: (bounds.height - count.lineHeight) / 2,
                                 width: countWidth, height: count.lineHeight)
            let end = count.isHidden ? bounds.width - Tokens.Space.x2 : count.frame.minX - Tokens.Space.x2
            label.frame = NSRect(x: x, y: (bounds.height - label.lineHeight) / 2, width: max(0, end - x), height: label.lineHeight)
        }
    }

    override func stateDidChange(animated: Bool) {
        let accent = Brand.Theme.for(self).accent
        let fill: NSColor? = isSelected ? (drawsSelection ? accent.withAlphaComponent(isPressed ? Tokens.Color.selectionPressedAlpha : Tokens.Color.selectionAlpha) : nil)
            : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        icon.contentTintColor = isSelected ? accent : Tokens.Color.icon
    }
}

/// One selection that glides between a list's places or a filter's segments, instead of each lighting on its own:
/// a soft fill of the accent, `Radius.row`, moved with `Motion.glide` in `Motion.highlightGlide`. Put it behind the
/// items; a change from the keyboard, or with Reduce Motion, lands at once.
final class SelectionGlide: ColorView {
    var tint: NSColor? { didSet { color = tint?.withAlphaComponent(Tokens.Color.selectionAlpha) } }

    init(radius: CGFloat = Tokens.Radius.row) {
        super.init(color: nil)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Moves to `frame`; `animated` when the choice was made with the pointer.
    func move(to frame: NSRect, animated: Bool) {
        isHidden = frame.isEmpty
        if animated && !Tokens.Motion.isFromKey && frame.width > 0 && self.frame.width > 0 {
            Tokens.Motion.glide(self, to: frame, duration: Tokens.Motion.highlightGlide, timing: Tokens.Motion.easeOut)
        } else {
            layer?.removeAnimation(forKey: "glide")
            Tokens.Motion.withoutAnimation { self.frame = frame }
        }
    }
}

// MARK: - HTML

/// The same design for Zigzag's HTML pages: the tokens as CSS custom properties for light and dark, in the space's
/// accent, and the shared parts (the title with its wordmark, the search field, buttons, a menu).
@MainActor
enum PageStyle {
    /// A `<style>` body: the variables, then the shared parts. Put a page's own rules after it.
    static func css(theme: Brand.Theme) -> String {
        variables(theme: theme) + components
    }

    /// The wordmark and title, for the page's header.
    static func title(_ text: String) -> String {
        #"<div class="page-title">"# + WordmarkView.svg(class: "wordmark") + #"<span class="divider"></span><h1>"# + text + "</h1></div>"
    }

    /// The search field: a magnifying glass, then the input.
    static func search(id: String, placeholder: String) -> String {
        #"<label class="search"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg>"#
            + #"<input id="\#(id)" type="search" placeholder="\#(placeholder)" aria-label="\#(placeholder)" autocomplete="off" autofocus></label>"#
    }

    private static func color(_ color: NSColor, _ appearance: NSAppearance.Name) -> String {
        var out = "transparent"
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            let (r, g, b) = (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            out = c.alphaComponent >= 1 ? String(format: "#%02x%02x%02x", r, g, b) : "rgba(\(r),\(g),\(b),\(String(format: "%.3g", c.alphaComponent)))"
        }
        return out
    }

    private static func px(_ value: CGFloat) -> String { "\(Int(value))px" }

    private static func variables(theme: Brand.Theme) -> String {
        typealias C = Tokens.Color
        let colors: [(String, NSColor)] = [
            ("accent", theme.accent), ("on-accent", theme.onAccent), ("mark", theme.mark),
            ("bg", C.surface), ("text", C.textPrimary), ("muted", C.textSecondary), ("faint", C.textTertiary), ("icon", C.icon),
            ("hover", C.hoverFill), ("pressed", C.pressedFill), ("highlight", C.highlight), ("field", C.fieldFill), ("line", C.separator),
            ("group", C.surfaceGroup), ("group-edge", C.surfaceGroupEdge),
            ("panel", C.panelBackground), ("panel-wash", C.panelWash), ("panel-edge", C.panelEdge), ("panel-shadow", C.panelShadow), ("destructive", C.destructive),
            ("control", C.controlFill), ("control-hover", C.controlHover), ("control-pressed", C.controlPressed), ("control-edge", C.controlEdge),
            ("control-shadow", C.controlShadow), ("primary", C.primaryFill), ("primary-hover", C.primaryHover), ("primary-pressed", C.primaryPressed),
            ("on-primary", C.onPrimary),
        ]
        func block(_ name: NSAppearance.Name) -> String { colors.map { "--\($0.0): \(color($0.1, name));" }.joined(separator: " ") }
        let page = Tokens.Page.self, radius = Tokens.Radius.self, size = Tokens.TypeSize.self
        let metrics = [
            "--gutter: \(px(page.gutter))", "--header-top: \(px(page.headerTop))", "--header-bottom: \(px(page.headerBottom))",
            "--control: \(px(page.controlHeight))", "--max: \(px(page.maxWidth))", "--row: \(px(page.rowHeight))",
            "--row-inset: \(px(page.rowInset))", "--wordmark: \(px(page.wordmarkHeight))", "--search: \(px(page.searchWidth))",
            "--radius-small: \(px(radius.small))", "--radius-control: \(px(radius.control))", "--radius-field: \(px(radius.field))", "--radius-row: \(px(radius.row))",
            "--radius-panel: \(px(radius.group))", "--radius-float: \(px(radius.panel))", "--small: \(px(size.small))", "--label: \(px(size.label))", "--body: \(px(size.body))", "--heading: \(px(size.heading))",
            "--selection: \(Int(Tokens.Color.selectionAlpha * 100))%", "--group-gap: \(px(page.groupGap))",
            "--page-row: \(px(size.pageRow))", "--page-label: \(px(size.pageLabel))", "--page-title: \(px(size.pageTitle))",
            "--control-text: \(px(size.row))", "--focus: \(Int(Tokens.Color.focusAlpha * 100))%",
            "--disabled: \(Tokens.Opacity.disabled)", "--space-1: \(px(Tokens.Space.x1))", "--space-2: \(px(Tokens.Space.x2))", "--space-3: \(px(Tokens.Space.x3))", "--space-4: \(px(Tokens.Space.x4))", "--space-5: \(px(Tokens.Space.x5))",
            "--space-6: \(px(Tokens.Space.x6))", "--space-8: \(px(Tokens.Space.x8))",
            "--panel-blur: \(px(Tokens.Shadow.panelRadius))", "--panel-drop: \(px(Tokens.Shadow.panelDrop))",
        ].joined(separator: "; ")
        return """
        :root { color-scheme: light dark; \(metrics); \(block(.aqua)) }
        @media (prefers-color-scheme: dark) { :root { \(block(.darkAqua)) } }
        @media (max-width: \(px(page.narrowWidth))) { :root { --gutter: \(px(page.narrowGutter)); } }

        """
    }

    private static let components = """
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--bg); color: var(--text); font: var(--body)/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
                 -webkit-font-smoothing: antialiased; -webkit-user-select: none; cursor: default; }
    ::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
    button { appearance: none; border: 0; background: none; color: inherit; font: inherit; padding: 0; cursor: default; }
    /* Keyboard focus: a ring in the accent just outside the control, never the system's blue. */
    :focus-visible { outline: 2px solid color-mix(in srgb, var(--accent) var(--focus), transparent); outline-offset: 2px; }

    /* The header: the title at the left, the search field and actions at the right, the page under it. */
    .page-header { position: sticky; top: 0; z-index: 4; background: var(--bg); box-shadow: 0 1px 0 transparent; transition: box-shadow .15s; }
    .page-header.scrolled { box-shadow: 0 1px 0 var(--line); }
    .page-header > .inner { max-width: calc(var(--max) + 2 * var(--gutter)); margin: 0 auto; display: flex; flex-wrap: wrap; align-items: center;
                            gap: 8px; padding: var(--header-top) var(--gutter) var(--header-bottom); }
    .page-title { display: flex; align-items: center; gap: 12px; min-height: var(--control); margin-right: auto; min-width: 0; }
    .page-title .wordmark { height: var(--wordmark); width: auto; flex: none; color: var(--accent); display: block; }
    .page-title .divider { width: 1px; height: 20px; background: var(--line); flex: none; }
    .page-title h1 { font-size: var(--page-title); font-weight: 600; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

    /* A page's search: the outlined pill, white with a hairline edge and a faint shadow, the accent's ring while typing. */
    .search { display: flex; align-items: center; gap: 4px; background: var(--control); border-radius: calc(var(--control) / 2); padding: 0 14px 0 10px;
              height: var(--control); width: var(--search); max-width: 100%; box-shadow: inset 0 0 0 1px var(--control-edge), 0 0.5px 1.5px var(--control-shadow); }
    .search:focus-within { box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--accent) var(--focus), transparent); }
    .search svg { flex: none; width: 16px; padding: 1px; color: var(--faint); }
    .search input { flex: 1; min-width: 0; border: 0; outline: 0; background: none; color: var(--text); font: inherit; caret-color: var(--accent);
                    -webkit-user-select: text; padding: 0 0 0 2px; }
    .search input::placeholder { color: var(--faint); }
    .search input::-webkit-search-cancel-button { display: none; }
    @media (max-width: 520px) { .search { order: 3; width: 100%; } }

    /* A pill button (PillButton): the secondary look, white with a hairline edge and a faint shadow. `.quiet` shows a
       fill only under the pointer; `.prominent` is the primary, a dark filled pill, one per page. Hover and press are
       instant; press darkens, never scales. */
    .button { height: var(--control); padding: 0 14px; border-radius: calc(var(--control) / 2); background: var(--control); color: var(--text);
              box-shadow: inset 0 0 0 1px var(--control-edge), 0 0.5px 1.5px var(--control-shadow); font-size: var(--control-text);
              font-weight: 500; white-space: nowrap; display: inline-flex; align-items: center; justify-content: center; text-decoration: none; }
    .button:hover, .button[aria-expanded="true"] { background: var(--control-hover); }
    .button:active { background: var(--control-pressed); }
    .button.quiet { background: none; box-shadow: none; padding: 0 var(--space-3); }
    .button.quiet:hover, .button.quiet[aria-expanded="true"] { background: var(--hover); }
    .button.quiet:active { background: var(--pressed); }
    .button.prominent { background: var(--primary); color: var(--on-primary); box-shadow: none; }
    .button.prominent:hover { background: var(--primary-hover); }
    .button.prominent:active { background: var(--primary-pressed); }
    .button:disabled { opacity: var(--disabled); }

    /* A menu, drawn as Zigzag's menus are (MenuPanel): a solid panel with a hairline edge and the one panel shadow,
       15px items, a soft gray row under the pointer. It arrives with a quick fade from a touch smaller. */
    .menu { position: absolute; right: 0; top: calc(100% + var(--space-1)); z-index: 5; min-width: 200px; padding: var(--space-1); border-radius: var(--radius-float);
            background: var(--panel); box-shadow: 0 0 0 1px var(--panel-edge), 0 var(--panel-drop) var(--panel-blur) var(--panel-shadow); display: none; }
    .menu.open { display: block; animation: menu-in .14s cubic-bezier(.23, 1, .32, 1); transform-origin: top right; }
    @keyframes menu-in { from { opacity: 0; transform: scale(.97); } }
    @media (prefers-reduced-motion: reduce) { .menu.open { animation-name: menu-fade; } }
    @keyframes menu-fade { from { opacity: 0; } }
    .menu [role="menuitem"] { display: block; width: 100%; text-align: left; height: var(--control); padding: 0 var(--space-3); border-radius: var(--radius-row);
                              font-size: var(--page-row); }
    .menu [role="menuitem"]:hover, .menu [role="menuitem"]:focus-visible { background: var(--highlight); outline: none; }
    .menu [role="menuitem"]:active { background: var(--pressed); }
    .menu [role="menuitem"].destructive { color: var(--destructive); }
    .menu hr { border: 0; height: 1px; background: var(--line); margin: var(--space-1) var(--space-3); }

    """
}
