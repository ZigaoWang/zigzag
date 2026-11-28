import AppKit

/// One result row: an icon, the title, quiet detail after it, and on the chosen row what Return does, with its key.
/// The chosen row is a soft wash of the space's accent, so you always see where Return goes.
final class CommandRowView: InteractiveView {
    private let icon = FaviconView()
    private let symbolView = NSImageView()
    private let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    /// The sidebar's row size, for suggestions under the sidebar's address.
    var isCompact = false {
        didSet {
            guard oldValue != isCompact else { return }
            title.font = isCompact ? Tokens.Font.sidebarRow() : Tokens.Font.row()
            detail.font = isCompact ? Tokens.Font.small() : Tokens.Font.body()
            styleTitle(ink: title.textColor ?? Tokens.Color.textPrimary)
            needsLayout = true
        }
    }
    private let action = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let returnKey = KeyCap(symbol: "return")
    private var titleRuns: [OmniboxText.Run] = []

    private var themeToken: SignalToken?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Its colors are the space's: worked out again once it's in a window, and when the space's look changes.
        themeToken = Brand.themeChanged.observe { [weak self] in self?.stateDidChange(animated: false) }
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        symbolView.imageScaling = .scaleNone
        symbolView.contentTintColor = Tokens.Color.icon
        [icon, symbolView, title, detail, action, returnKey].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ result: CommandResult) {
        titleRuns = result.titleRuns
        title.stringValue = result.title
        styleTitle(ink: title.textColor ?? Tokens.Color.textPrimary)
        detail.stringValue = result.detail
        action.stringValue = result.actionLabel
        if let image = result.icon {
            icon.image = image
            icon.isHidden = false
            symbolView.isHidden = true
        } else {
            icon.isHidden = true
            symbolView.isHidden = false
            symbolView.image = Tokens.Symbol.image(result.symbol ?? "globe", size: Tokens.Symbol.row)
        }
        setAccessibilityRole(result.isActionable ? .button : .staticText)
        setAccessibilityLabel(result.detail.isEmpty ? result.title
                              : String(localized: "\(result.title), \(result.detail)", comment: "VoiceOver name of a command bar result: its title, then what's under it."))
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    /// Where a row's title starts, from the row's edge: the field's text lines up with it.
    static let titleX = CardRow.inset * 2 + Tokens.Metric.favicon

    override func layout() {
        super.layout()
        let inset = CardRow.inset
        let side = Tokens.Metric.favicon
        icon.frame = NSRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        symbolView.frame = icon.frame
        let hasAction = !action.stringValue.isEmpty
        action.isHidden = !(isSelected && hasAction)
        returnKey.isHidden = action.isHidden
        var right = bounds.width - inset
        // Every row with an action reserves its width, so titles don't shrink as the selection moves.
        if hasAction {
            let kw = returnKey.width, kh = Tokens.Metric.keyCapHeight
            returnKey.frame = NSRect(x: right - kw, y: round((bounds.height - kh) / 2), width: kw, height: kh)
            let w = action.textWidth
            action.frame = NSRect(x: returnKey.frame.minX - Tokens.Space.x2 - w, y: action.centeredY(in: bounds.height), width: w, height: action.lineHeight)
            right = action.frame.minX - Tokens.Space.x4
        }
        let x = Self.titleX - Label.inset
        let available = right - x
        let titleWidth = min(title.textWidth, detail.stringValue.isEmpty ? available : available * 0.62)
        title.frame = NSRect(x: x, y: title.centeredY(in: bounds.height), width: max(0, titleWidth), height: title.lineHeight)
        // On the title's baseline, though a size smaller.
        let lift = (title.font?.ascender ?? 0) - (detail.font?.ascender ?? 0)
        let detailX = title.frame.maxX + Tokens.Space.x2
        detail.frame = NSRect(x: detailX, y: title.frame.minY + round(lift), width: max(0, right - detailX), height: detail.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        // The chosen row takes the shared selection wash, as Settings' sections do.
        let theme = Brand.Theme.for(self)
        let alpha = isPressed ? Tokens.Color.selectionPressedAlpha : Tokens.Color.selectionAlpha
        let fill: NSColor? = isSelected ? theme.accent.withAlphaComponent(alpha) : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        styleTitle(ink: isSelected ? theme.rowInk : Tokens.Color.textPrimary)
        needsLayout = true
    }

    /// An extension's marks on its suggestion's text: a match a weight heavier, an address and dim text quieter.
    private func styleTitle(ink: NSColor) {
        title.textColor = ink
        guard !titleRuns.isEmpty, let font = title.font else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        // Kerned, so the label measures it as drawn, heavier stretches included.
        let styled = NSMutableAttributedString(string: title.stringValue, attributes: [.font: font, .foregroundColor: ink, .kern: 0, .paragraphStyle: paragraph])
        for run in titleRuns {
            let range = NSIntersectionRange(run.range, NSRange(location: 0, length: styled.length))
            guard range.length > 0 else { continue }
            if run.styles.contains(.match) { styled.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: range) }
            if run.styles.contains(.url) { styled.addAttribute(.foregroundColor, value: Tokens.Color.textSecondary, range: range) }
            if run.styles.contains(.dim) { styled.addAttribute(.foregroundColor, value: Tokens.Color.textTertiary, range: range) }
        }
        title.attributedStringValue = styled
    }
}

/// Where the command bar opens: a browser window, Zigzag Mini, or Zigzag Mini's quick open. The bar looks and types
/// the same in each; the host says where it sits, what it ranks and what Return opens.
protocol CommandBarHost: AnyObject {
    var window: NSWindow? { get }
    /// Holds the bar and the layer that catches clicks around it, over the whole host.
    var commandBarOverlay: NSView { get }
    /// The page the bar centers over, in the overlay's coordinates.
    var commandBarPageFrame: NSRect { get }
    /// The address the bar opens over while editing it, or nil to center it over the page. `asked` is the one the
    /// caller named (a split pane's).
    func commandBarAnchor(asked: NSView?) -> NSView?
    /// Over an anchor in the middle of the window (Zigzag Mini's title), the bar widens evenly both ways.
    var commandBarCentersOnAnchor: Bool { get }
    /// Over a small field in a slim strip (Zigzag Mini's), the bar opens at that field's own size, inside the strip,
    /// rather than at the sidebar address's height, which would hang below the strip and cover what sits beside it.
    var commandBarFitsAnchor: Bool { get }
    /// The light or dark of what the fitted field sits in (the strip), when it isn't the window's.
    var commandBarAppearance: NSAppearance? { get }
    /// The browser window's tabs, for open tabs among the results and for completing what you type; nil if there's none.
    var commandBarTabs: TabManager? { get }
    /// The browser window whose tabs, spaces and pages the bar opens in, when the host isn't one itself (the edge
    /// panel's bar, #560): a chosen page goes into that window's tabs, in the space the panel shows.
    var commandBarBrowser: BrowserWindowController? { get }
    /// Browser windows: the bar can be dragged and keeps its place.
    var commandBarIsMovable: Bool { get }
    /// The profile whose history, favorites and open pages the bar suggests: the one of the space it's used in.
    var commandBarProfile: Profile { get }
    /// The page ⌘L edits.
    var commandBarTab: Tab? { get }
    /// The space whose accent the bar takes; nil in a private window.
    var commandBarSpace: SpaceInfo? { get }
    var commandBarIsPrivate: Bool { get }
    /// Puts away whatever else floats here before the bar opens.
    func commandBarWillShow()
    /// Typing goes back to the page.
    func commandBarRestoreFocus()
    /// Opens a chosen result itself; false leaves it to the bar, which opens it in the browser window's tabs.
    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool
    /// The bar is gone from the screen, its exit finished.
    func commandBarDidHide()
}

extension CommandBarHost {
    var commandBarCentersOnAnchor: Bool { false }
    var commandBarFitsAnchor: Bool { false }
    var commandBarAppearance: NSAppearance? { nil }
    var commandBarIsMovable: Bool { false }
    var commandBarBrowser: BrowserWindowController? { self as? BrowserWindowController }
    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool { false }
    func commandBarDidHide() {}
}

/// The floating command bar: one field for addresses, searches, tabs, bookmarks and history.
final class CommandBarController: NSObject, NSTextFieldDelegate {
    enum Mode { case newTab, editCurrent, history }

    private weak var host: CommandBarHost?
    /// The browser window it's in, for what only a browser window does (its commands, its other panels).
    private var controller: BrowserWindowController? { host?.commandBarBrowser }
    /// Catches clicks outside the bar; it doesn't dim the page.
    private let scrim = ScrimView(dims: false)
    private let panel = FloatingPanelView()
    /// The bar itself, for pointing at it (the Getting started guide).
    var panelView: NSView { panel }
    /// On a window of its own over the desktop (Zigzag Mini's quick open).
    var showsDesktop: Bool {
        get { panel.showsDesktop }
        set { panel.showsDesktop = newValue }
    }
    private let field = PlainTextField(font: Tokens.Font.title(.regular), placeholder: String(localized: "Search or enter address", comment: "Placeholder of the command bar's field."))
    /// A press on it drags the bar.
    private let fieldIcon = PassiveImageView()
    private let divider = ColorView(color: Tokens.Color.separator)
    private var rows: [CommandRowView] = []
    private var results: [CommandResult] = []
    private var selectedIndex = 0
    private(set) var mode: Mode = .newTab
    private var suggestions: [String] = []
    private let fetcher = SuggestionFetcher()
    /// History's pages and sites for what's typed, read off the main thread; they join the list as they arrive.
    private let history = HistoryLookup(store: Profiles.shared.default.history)
    /// What was typed when the inline completion was last asked of History, while the answer is still coming.
    private var completionAsked: String?
    /// Text the user actually typed; the field may also hold an inline completion after it.
    private var typed = ""
    /// The site what you typed completes to. The rest of its address sits selected after what you typed, unless
    /// you've typed it all; either way it's the first row and where Return goes.
    private var completion: InlineCompletion.Match?
    private var completionURL: URL? { completion?.url }
    /// Takes the completion back before a letter replaces it, so the completion never enters Undo.
    private var typingMonitor: Any?
    /// The key event of the last delete command, so the change it makes is known to take away, not type.
    private weak var deleteEvent: NSEvent?
    private(set) var isVisible = false
    /// Opened for an empty window's first page.
    private(set) var isForEmptyWindow = false
    private var mouseAtOpen = NSPoint.zero
    /// Searching one site: its chip sits in front of the field, and Return searches there.
    private var scope: SiteSearch?
    private var shrinkWork: DispatchWorkItem?
    /// What you'd typed before Tab took you into a site, so Esc can give it back.
    private var typedBeforeScope = ""
    /// The site's own color, a capsule in front of the field.
    private let chip = ColorView(color: .clear)
    /// The hairline between the site's name and what you type.
    private let chipRule = ColorView(color: Tokens.Color.separator)
    private let chipLabel = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    /// "Search YouTube  Tab", at the right of the field, when what you've typed names a site.
    private let hint = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let hintKey = KeyCap("Tab")
    private var hinted: SiteSearch?
    /// For the guide: searching inside a site, or about to be (its name typed, Tab not yet pressed).
    var isSearchingSite: Bool { scope != nil }
    var isOfferingSiteSearch: Bool { hinted != nil }
    /// An extension's keyword mode: its name sits in front of the field, and what you type goes to the extension.
    private var keyword: OmniboxKeyword?
    private var omniboxInput: OmniboxInput?
    private var omniboxWork: DispatchWorkItem?
    /// The keyword what's typed is, so Tab enters it.
    private var hintedKeyword: OmniboxKeyword?
    /// A site's or an extension's name in front of the field.
    private var isScoped: Bool { scope != nil || keyword != nil }

    init(host: CommandBarHost) {
        self.host = host
        super.init()
        field.delegate = self
        field.textInset = 2
        field.centersText = true
        // Paste and Go: what's on the clipboard, opened or searched in one step, as in Safari and Chrome.
        field.pasteMenuItems = { [weak self] in
            guard let self, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.contains("\n") else { return [] }
            let destination = CommandRanker.destination(from: text)
            let title = destination != nil ? String(localized: "Paste and Go", comment: "Item in the command bar field's right-click menu: opens the copied address.")
                                : String(localized: "Paste and Search", comment: "Item in the command bar field's right-click menu: searches for the copied text.")
            return [SidebarMenus.Item(title) { [weak self] in
                // Straight to the page or the search, never a suggestion listed for what was typed before.
                self?.activate(CommandResult(kind: destination.map { .open($0.url, httpFallback: $0.httpFallback) } ?? .search(text),
                                             title: "", detail: ""), modifiers: [])
            }]
        }
        fieldIcon.image = Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.title)
        fieldIcon.contentTintColor = Tokens.Color.textTertiary
        fieldIcon.imageScaling = .scaleNone
        panel.addSubview(fieldIcon)
        panel.addSubview(field)
        panel.addSubview(divider)
        // ⌘Z undoes what you typed: the completion after it is never part of that, so it goes first.
        NotificationCenter.default.addObserver(self, selector: #selector(undoWillChange), name: .NSUndoManagerWillUndoChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoWillChange), name: .NSUndoManagerWillRedoChange, object: nil)
        chip.wantsLayer = true
        chip.layer?.cornerCurve = .continuous
        chip.addSubview(chipLabel)
        chip.isHidden = true
        hint.alignment = .right
        hint.isHidden = true
        hintKey.isHidden = true
        [chip, chipRule, hint, hintKey].forEach { panel.addSubview($0) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        panel.onBarePress = { [weak self] event in self?.barePress(event) }
        scrim.onClick = { [weak self] in self?.dismiss() }
        history.onPages = { [weak self] in self?.mergeArrived() }
        history.onSites = { [weak self] in self?.completionArrived() }
    }

    // MARK: Showing

    /// The bar is glass, whatever the space: what's under it shows through. It belongs to the space by its accent,
    /// in the cursor, the selected text and the chosen row.
    private func applySpaceTheme() {
        guard let host else { return }
        let accent = Brand.Theme.of(host.commandBarIsPrivate ? nil : host.commandBarSpace).accent
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = accent
            editor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(Tokens.Color.textSelectionAlpha)]
        }
        rows.forEach { $0.stateDidChange(animated: false) }
    }


    /// Where the bar opens while editing an address: the sidebar's address, or a split pane's (`show(anchor:)`).
    private weak var anchor: NSView?

    /// `anchor`: open over this address instead of the sidebar's (a split pane's), whether or not the sidebar shows.
    func show(mode: Mode, anchor: NSView? = nil) {
        guard let host else { return }
        // A different place to open from is a fresh bar: it moves there.
        if isVisible, anchor !== self.anchor { dismiss(restoringFocus: false) }
        self.anchor = mode == .editCurrent ? anchor : nil
        // A fresh bar, or a different one (⌘L over ⌘T): no leftover site scope, and no hint from the last thing typed.
        if !isVisible || mode != self.mode {
            typed = ""
            field.stringValue = ""
            setScope(nil)
        }
        if !isVisible || mode != self.mode { isForEmptyWindow = mode == .newTab && host.commandBarTab == nil }
        self.mode = mode
        fetcher.isPrivate = host.commandBarIsPrivate
        mouseAtOpen = NSEvent.mouseLocation
        let opening = !isVisible
        if !isVisible {
            host.commandBarWillShow()
            isVisible = true
            // The host may have made room for the bar: the edge panel widens beside its card (#560).
            let card = host.commandBarPageFrame
            // The history of the profile the bar is used in. It may have changed since the bar was last open: nothing
            // found then is reused.
            history.use(host.commandBarProfile.history)
            history.reset()
            completionAsked = nil
            // Another window may have moved it.
            position = CommandBarPlacement.load()
            scrim.frame = isAnchored ? host.commandBarOverlay.bounds : card
            host.commandBarOverlay.addSubview(scrim)
            host.commandBarOverlay.addSubview(panel)
            scrim.show()
            typingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.letterWillReplaceCompletion(event)
                return event
            }
        }
        applySpaceTheme()
        // From the address: the sidebar's own size, so the text doesn't change as you click in; the centered bar for
        // a new tab is large. Regular weight both ways: what you type reads as text, not a heading.
        // Light type, the space name's voice: the sidebar's size over the address, large and airy for a new tab.
        // In a slim strip's field, the strip's own address size, so it fits the field's height.
        let fits = fitsAnchor
        let font = Tokens.Font.voice(fits ? Tokens.Pane.addressText : isAnchored ? Tokens.Font.sidebarRow().pointSize : 22)
        field.font = font
        panel.appearance = fits ? host.commandBarAppearance ?? anchorView?.effectiveAppearance : nil
        let placeholder = mode == .history ? String(localized: "Search history", comment: "Placeholder of the command bar's field while it searches history.") : String(localized: "Search or enter address", comment: "Placeholder of the command bar's field.")
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
                                                               attributes: [.font: font, .kern: Tokens.Font.voiceKern(font.pointSize), .foregroundColor: Tokens.Color.textTertiary])
        if mode == .editCurrent, let url = host.commandBarTab?.shownURL {
            field.stringValue = url.absoluteString
        } else if mode == .newTab, let unsent, Date().timeIntervalSince(unsent.at) < Self.unsentMemory {
            // Closed by a stray click or Esc a moment ago: what you'd typed is still here, selected, so typing replaces it.
            field.stringValue = unsent.text
        } else {
            field.stringValue = ""
        }
        unsent = nil
        typed = field.stringValue
        // A site search hint from the last time the bar was open never carries over.
        refreshHint()
        completion = nil
        suggestions = []
        refreshResults(animated: false)
        panel.frame = panelFrame()
        // Arrives once; asked again while open (⌘T twice), it simply stays. From a key (⌘T, ⌘L, the thing you do
        // most) it's simply there; clicked open, it grows out of the page's top, or fades in place over the address
        // it stands in for.
        if opening { panel.present(arrival: Tokens.Motion.isFromKey ? .instant : isAnchored ? .fade : .pop) }
        host.window?.makeFirstResponder(field)
        applySpaceTheme()
        field.currentEditor()?.selectAll(nil)
    }

    /// What was typed into the new tab bar when it closed without opening anything, for a few seconds.
    private var unsent: (text: String, at: Date)?
    private static let unsentMemory: TimeInterval = 10

    func dismiss(restoringFocus: Bool = true) {
        guard isVisible, let host else { return }
        isVisible = false
        // Kept only for the new tab bar; opening something clears it (`activate`). In a keyword, with the keyword.
        unsent = mode == .newTab && !typed.isEmpty ? (keyword.map { "\($0.keyword) \(typed)" } ?? typed, Date()) : nil
        endKeyword()
        if let typingMonitor { NSEvent.removeMonitor(typingMonitor) }
        typingMonitor = nil
        fetcher.cancel()
        scrim.hide()
        dragStart = nil
        guides.show(x: nil, y: nil)
        // Esc or Return: gone at once, as it came.
        panel.dismiss(instantly: isAnchored || Tokens.Motion.isFromKey) { [weak self, weak host] in
            // Shown again while it was leaving: it's still here.
            guard self?.isVisible == false else { return }
            host?.commandBarDidHide()
        }
        if restoringFocus { host.commandBarRestoreFocus() }
    }

    /// A page arrived another way (from Zigzag Mini, dragged in): close the empty window's bar.
    func pageArrived() {
        if isVisible, isForEmptyWindow { dismiss(restoringFocus: false) }
    }

    func reposition() {
        guard isVisible, let host else { return }
        scrim.frame = isAnchored ? host.commandBarOverlay.bounds : host.commandBarPageFrame
        // The window got shorter than the list: drop the rows that no longer fit.
        if results.count > rowsThatFit { refreshResults(animated: false) }
        panel.frame = panelFrame()
    }

    // MARK: Layout

    private var listHeight: CGFloat {
        guard !results.isEmpty else { return 0 }
        return CGFloat(results.count) * rowHeight + Self.listInset * 2
    }

    /// Editing the address you're on opens right where it is: over the address field in the sidebar, reaching
    /// into the page, like a dropdown. New tabs and history keep the bar centered over the page.
    private var isAnchored: Bool {
        guard let host, mode == .editCurrent else { return false }
        return host.commandBarAnchor(asked: anchor.flatMap { $0.window != nil ? $0 : nil }) != nil
    }

    private var anchorView: NSView? { host?.commandBarAnchor(asked: anchor.flatMap { $0.window != nil ? $0 : nil }) }

    /// The split pane's strip whose address the bar opens over.
    private var paneStrip: PaneHeaderView? { anchorView?.superview as? PaneHeaderView }

    /// Opened over a slim strip's field (Zigzag Mini's, a split pane's): at that field's size, in the strip's light or dark.
    private var fitsAnchor: Bool {
        guard isAnchored, let host else { return false }
        return host.commandBarFitsAnchor || paneStrip != nil
    }

    /// The address the bar opens over, in the overlay's coordinates.
    private func anchorFrame(in host: CommandBarHost) -> NSRect {
        guard let view = host.commandBarAnchor(asked: anchor.flatMap { $0.window != nil ? $0 : nil }) else { return .zero }
        return view.convert(view.bounds, to: host.commandBarOverlay)
    }

    private func panelFrame() -> NSRect {
        guard let host else { return .zero }
        if isAnchored {
            let address = anchorFrame(in: host)
            // From the address's own corner, wide enough for the whole address at once, reaching over the page;
            // suggestions continue below in the same panel. Never past the window's right edge: a pane's address
            // on the right opens toward the left.
            // The address field itself, opened in place: its own height and corners, as wide as it is unless the
            // address needs more room (then only as wide as the address), suggestions below once you type.
            let bounds = host.commandBarOverlay.bounds
            let font = field.font ?? Tokens.Font.sidebarRow()
            let textWidth = ceil((field.stringValue as NSString).size(withAttributes: [.font: font]).width)
            // The same 12pt on both sides of the text as the resting field, and a hair for the caret.
            let needed = textWidth + Tokens.Space.x3 * 2 - 1
            let wanted = results.isEmpty ? needed : max(needed, Tokens.Metric.commandBarWidth * 0.7)
            // A field wider than the bar (the address above the page) opens at its own width, never narrower.
            // Fitted to a strip's field, it stays that field's width until suggestions need the room.
            // A split pane's field may grow into the room between its strip's buttons, never over them.
            let strip = paneStrip.map { $0.convert(NSRect(x: $0.addressRoom.lowerBound, y: 0, width: $0.addressRoom.upperBound - $0.addressRoom.lowerBound, height: $0.bounds.height), to: host.commandBarOverlay) }
            let widest = fitsAnchor && results.isEmpty ? max(address.width, strip?.width ?? 0) : max(Tokens.Metric.commandBarWidth, address.width)
            let wide = min(max(wanted, address.width), widest, bounds.width - Tokens.Space.x2 - Tokens.Space.x4)
            if let strip, results.isEmpty {
                let x = min(max(round(address.midX - wide / 2), strip.minX), strip.maxX - wide)
                return NSRect(x: x, y: address.minY, width: wide, height: fieldHeight)
            }
            let start = host.commandBarCentersOnAnchor ? round(address.midX - wide / 2) : address.minX
            // A field that itself reaches nearer the edge keeps its place.
            let margin = min(Tokens.Space.x4, max(0, bounds.maxX - address.maxX))
            let x = max(Tokens.Space.x2, min(start, bounds.maxX - margin - wide))
            return NSRect(x: x, y: address.minY, width: wide, height: fieldHeight + listHeight)
        }
        if host.commandBarIsMovable {
            let placement = self.placement(in: host)
            return NSRect(origin: placement.origin(for: position), size: NSSize(width: placement.width, height: Tokens.Metric.commandBarFieldHeight + listHeight))
        }
        let card = host.commandBarPageFrame
        // Room to breathe on both sides of the page, however narrow the window.
        let margin = Tokens.Space.x8
        let width = min(Tokens.Metric.commandBarWidth, card.width - margin * 2)
        let height = Tokens.Metric.commandBarFieldHeight + listHeight
        let top = panelTop(in: card)
        // Centered on the whole window, not just the page beside the sidebar, but never tight against either edge.
        let x = min(max(card.minX + margin, floor(host.commandBarOverlay.bounds.midX - width / 2)), card.maxX - width - margin)
        return NSRect(x: x, y: top, width: width, height: height)
    }

    private func panelTop(in card: NSRect) -> CGFloat { card.minY + max(Tokens.Space.x12, floor(card.height * 0.18)) }

    /// How many rows fit under the field before the bar would run off the bottom of the window.
    private var rowsThatFit: Int {
        guard let host else { return Tokens.Metric.commandBarMaxRows }
        let top: CGFloat, bottom: CGFloat
        if isAnchored {
            top = anchorFrame(in: host).minY
            bottom = host.commandBarOverlay.bounds.maxY
        } else if host.commandBarIsMovable {
            let placement = self.placement(in: host)
            top = placement.origin(for: position).y
            bottom = placement.bottom(for: position)
        } else {
            let card = host.commandBarPageFrame
            top = panelTop(in: card)
            bottom = card.maxY
        }
        let room = bottom - Tokens.Space.x4 - top - fieldHeight - Self.listInset * 2
        return max(1, min(Tokens.Metric.commandBarMaxRows, Int(room / rowHeight)))
    }

    // MARK: Moving it

    /// The default unless dragged.
    private var position = CommandBarPlacement.load()
    private lazy var guides = CommandBarGuides()
    /// Top-left at drag start, and the guides it's on.
    private var dragStart: NSPoint?
    private var snapped = (x: false, y: false)

    /// Room a dragged bar always keeps: the field and this many rows.
    private static let minimumRows = 4

    private func placement(in host: CommandBarHost) -> CommandBarPlacement {
        CommandBarPlacement(bounds: host.commandBarOverlay.bounds, page: host.commandBarPageFrame,
                            minimumHeight: Tokens.Metric.commandBarFieldHeight + Self.listInset * 2 + Tokens.Metric.commandBarRowHeight * CGFloat(Self.minimumRows))
    }

    private var isMovable: Bool { isVisible && !isAnchored && host?.commandBarIsMovable == true }

    /// A press on the bar's background drags it past a few points, as Raycast's does; a double-click resets it.
    private func barePress(_ event: NSEvent) {
        guard isMovable, let host, let window = host.window else { return }
        if event.clickCount == 2 { resetPosition(); return }
        let overlay = host.commandBarOverlay
        let start = overlay.convert(event.locationInWindow, from: nil)
        var moving = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = overlay.convert(next.locationInWindow, from: nil)
            let delta = NSPoint(x: now.x - start.x, y: now.y - start.y)
            if !moving {
                guard hypot(delta.x, delta.y) >= CommandBarPlacement.dragThreshold else { continue }
                moving = true
                beginDrag()
            }
            drag(by: delta)
        }
        if moving { endDrag() }
    }

    private func beginDrag() {
        guard let host else { return }
        dragStart = panel.frame.origin
        snapped = (false, false)
        let overlay = host.commandBarOverlay
        guides.frame = overlay.bounds
        guides.color = Brand.Theme.of(host.commandBarIsPrivate ? nil : host.commandBarSpace).accent
        if guides.superview !== overlay { overlay.addSubview(guides, positioned: .below, relativeTo: panel) }
    }

    /// `delta`: pointer movement since drag start, top-down.
    private func drag(by delta: NSPoint) {
        guard let host, let start = dragStart else { return }
        let placement = self.placement(in: host)
        let drag = placement.drag(to: NSPoint(x: start.x + delta.x, y: start.y + delta.y))
        // Haptic tap on snapping to a guide, like Keynote.
        if (drag.snappedX && !snapped.x) || (drag.snappedY && !snapped.y) { Haptics.snap() }
        snapped = (drag.snappedX, drag.snappedY)
        position = drag.position
        guides.show(x: drag.snappedX ? placement.guideX : nil, y: drag.snappedY ? placement.guideY : nil)
        refitRows()
        panel.frame = panelFrame()
    }

    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        guides.show(x: nil, y: nil)
        CommandBarPlacement.save(position)
    }

    /// Animates back to the default position unless Reduce Motion is on.
    private func resetPosition() {
        position = .standard
        CommandBarPlacement.save(position)
        let from = panel.frame
        refitRows()
        let to = panelFrame()
        guard from != to else { return }
        panel.frame = from
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) { self.panel.animator().frame = to }
    }

    /// Fit as many rows as the new height allows.
    private func refitRows() {
        guard let fresh = currentResults(), fresh.count != results.count else { return }
        display(fresh, animated: false)
    }

    /// Opened from the address it's the address field's own height, so clicking in changes nothing but the width.
    private var fieldHeight: CGFloat {
        guard isAnchored else { return Tokens.Metric.commandBarFieldHeight }
        if let host, fitsAnchor {
            let height = anchorFrame(in: host).height
            if height > 0 { return height }
        }
        return Tokens.Sidebar.addressHeight
    }

    /// Hanging from the sidebar's address, the suggestions are the sidebar's own rows in size; over the page, the
    /// larger rows of the new tab bar.
    private var rowHeight: CGFloat { isAnchored ? Tokens.Sidebar.rowHeight : Tokens.Metric.commandBarRowHeight }

    /// Rows sit this far in from the panel's edges, so their corners run with the panel's.
    private static let listInset = Tokens.Space.x1

    private func layoutPanel() {
        let b = panel.bounds
        // Over the address with nothing below it, it keeps the field's corners; with suggestions, the panel's.
        let fitted = fitsAnchor
        // In a slim strip, the strip's own corners, as its other fields and buttons have.
        panel.radius = isAnchored && results.isEmpty ? (fitted ? Tokens.Radius.control : Tokens.Sidebar.addressRadius) : Tokens.Radius.panel
        let fieldHeight = self.fieldHeight
        let inset = Self.listInset
        // The glass lines up with the rows under it: its middle over their icons, the text where their titles start.
        let iconSize = Tokens.Space.x6
        let iconMid = inset + CardRow.inset + Tokens.Metric.favicon / 2
        fieldIcon.frame = NSRect(x: iconMid - iconSize / 2, y: (fieldHeight - iconSize) / 2, width: iconSize, height: iconSize)
        // Anchored there's no icon: the text starts exactly where the address's own text was.
        fieldIcon.isHidden = isAnchored
        let textHeight = ceil(field.intrinsicContentSize.height)
        // Anchored, the text's first letter lands exactly where the resting address's does (12pt in), so nothing moves
        // as you click in; the field's own text inset and its editor's padding make up the rest.
        var fieldX = isAnchored ? Tokens.Space.x3 - 4 : inset + CommandRowView.titleX
        if isScoped {
            // The site's name in the field's own type, so it reads as the start of the line, then a hairline.
            let font = field.font ?? Tokens.Font.voice(22)
            chipLabel.font = font
            chipLabel.attributedStringValue = NSAttributedString(string: chipLabel.stringValue, attributes: [
                .font: font, .kern: Tokens.Font.voiceKern(font.pointSize), .foregroundColor: chipLabel.textColor ?? Tokens.Color.textPrimary,
            ])
            let ch = textHeight
            let cw = ceil(chipLabel.inkWidth) + Label.inset * 2
            chip.frame = NSRect(x: fieldX - Label.inset, y: round((fieldHeight - ch) / 2), width: cw, height: ch)
            chip.layer?.cornerRadius = 0
            chipLabel.frame = NSRect(x: 0, y: chipLabel.centeredY(in: ch), width: cw, height: chipLabel.lineHeight)
            chipLabel.alignment = .left
            let ruleHeight = round(font.pointSize * 0.9)
            chipRule.frame = NSRect(x: chip.frame.maxX + Tokens.Space.x2, y: round((fieldHeight - ruleHeight) / 2),
                                    width: Tokens.Metric.hairline, height: ruleHeight)
            fieldX = chipRule.frame.maxX + Tokens.Space.x2 + 2
        }
        chipRule.isHidden = !isScoped
        // Unanchored, the Tab key's cap ends where the rows' Return caps do.
        var fieldRight = b.width - (isAnchored ? Tokens.Space.x3 : inset + CardRow.inset)
        if !hint.isHidden {
            let kw = hintKey.width, kh = Tokens.Metric.keyCapHeight
            hintKey.frame = NSRect(x: fieldRight - kw, y: round((fieldHeight - kh) / 2), width: kw, height: kh)
            let hw = hint.textWidth + 4
            hint.frame = NSRect(x: hintKey.frame.minX - Tokens.Space.x2 - hw, y: hint.centeredY(in: fieldHeight), width: hw, height: hint.lineHeight)
            fieldRight = hint.frame.minX - Tokens.Space.x3
        }
        // A little taller and wider than the text, which the field keeps inside, so selections draw whole.
        let textInset = field.textInset, boxHeight = textHeight + textInset * 4
        // Caps centered, as every label's are.
        field.frame = NSRect(x: fieldX - textInset, y: field.centeredY(in: fieldHeight) - textInset * 2, width: max(40, fieldRight - fieldX) + textInset * 2, height: boxHeight)
        // A hairline between what you type and what it finds, held in from the edges like the rows.
        divider.frame = NSRect(x: Tokens.Space.x3, y: fieldHeight - Tokens.Metric.hairline, width: b.width - Tokens.Space.x3 * 2, height: Tokens.Metric.hairline)
        // No rule between what you type and what it finds: the space between them is enough.
        divider.isHidden = true
        var y = fieldHeight + inset
        for row in rows {
            row.frame = NSRect(x: inset, y: y, width: b.width - inset * 2, height: rowHeight)
            y += rowHeight
        }
    }

    // MARK: Results

    private func refreshResults(animated: Bool) {
        guard let fresh = currentResults() else { return }
        display(fresh, animated: animated)
    }

    /// Something read in the background arrived (History's pages, web suggestions) and joins the list. A row you've
    /// moved to stays the one picked; when it would go, the list waits for your next letter instead, so the selection
    /// never jumps under you and Return does what's showing.
    private func mergeArrived() {
        guard isVisible, let fresh = currentResults() else { return }
        guard selectedIndex != 0, results.indices.contains(selectedIndex) else { display(fresh, animated: true); return }
        guard let index = fresh.firstIndex(of: results[selectedIndex]) else { return }
        display(fresh, animated: true)
        select(index)
    }

    /// The rows for what's typed now, from what's at hand: History's part as far as it's been read.
    private func currentResults() -> [CommandResult]? {
        guard let host else { return nil }
        if let keyword { return Array(keywordResults(keyword).prefix(rowsThatFit)) }
        let editing = mode == .editCurrent && typed == host.commandBarTab?.shownURL?.absoluteString
        let query = editing || scope != nil ? "" : typed
        let pages = query.isEmpty ? [] : history.pages(for: query, limit: CommandRanker.historyLimit(historyOnly: mode == .history))
        var results = CommandRanker.results(for: query, manager: host.commandBarTabs, profile: host.commandBarProfile, suggestions: suggestions, history: pages,
                                            editingCurrent: mode == .editCurrent, historyOnly: mode == .history,
                                            leavingOutFailed: controller == nil)
        if editing { results = [] }
        // Zigzag's commands act on a browser window's tabs: outside one there's nothing for them to act on.
        if controller == nil { results.removeAll { if case .action = $0.kind { true } else { false } } }
        if let scope {
            // Searching one site: the query there first, then suggestions, all searching that site.
            let q = typed.trimmingCharacters(in: .whitespaces)
            let queries = (q.isEmpty ? [] : [q]) + suggestions.filter { $0.lowercased() != q.lowercased() }.prefix(5)
            results = queries.compactMap { query in
                scope.url(for: query).map { CommandResult(kind: .searchOn($0), title: query, detail: String(localized: "Search \(scope.name)", comment: "Under each result while the command bar searches one site. The name is the site's, like YouTube."),
                                                         icon: FaviconStore.shared.cachedIcon(for: scope.home), symbol: "magnifyingglass") }
            }
            // Nothing typed yet: the site itself and where you've been on it, so the bar doesn't empty out at Tab.
            if q.isEmpty {
                let domain = (scope.home.host() ?? "").split(separator: ".").suffix(2).joined(separator: ".")
                var seen = Set([TabManager.normalize(scope.home)])
                results = [CommandResult(kind: .open(scope.home), title: scope.name, detail: CommandRanker.displayURL(scope.home),
                                         icon: FaviconStore.shared.cachedIcon(for: scope.home), symbol: "globe")]
                for entry in history.pages(for: domain, limit: 12) ?? [] where results.count < 6 {
                    let key = TabManager.normalize(entry.url)
                    guard entry.url.host()?.hasSuffix(domain) == true, entry.url.path.count > 1, !SearchFolding.isSearchResultsPage(entry.url),
                          seen.insert(key).inserted else { continue }
                    results.append(CommandResult(kind: .history(entry.url), title: entry.title.isEmpty ? CommandRanker.displayURL(entry.url) : entry.title,
                                                 detail: CommandRanker.displayURL(entry.url), icon: SiteIcons.shownIcon(for: entry.url, privateStore: host.commandBarTabs?.privateStore)))
                }
            }
        }
        // An inline completion becomes the first result.
        if let completionURL, !typed.isEmpty {
            let top = CommandResult(kind: .open(completionURL), title: CommandRanker.displayURL(completionURL), detail: "",
                                    icon: SiteIcons.shownIcon(for: completionURL, privateStore: host.commandBarTabs?.privateStore), symbol: "globe")
            results.removeAll { $0.kind == .open(completionURL) || $0.title == top.title }
            results.insert(top, at: 0)
            // Already open in another tab? Enter still opens what you typed; switching to that tab is the row under it,
            // one ↓ away, so neither ever happens by surprise.
            if let manager = host.commandBarTabs, let existing = manager.existingTab(for: completionURL), existing !== manager.selectedTab {
                let other = CommandResult(kind: .switchTo(existing.id), title: existing.displayTitle,
                                          detail: CommandRanker.displayURL(completionURL), icon: existing.displayIcon)
                results.removeAll { $0.kind == other.kind }
                results.insert(other, at: 1)
            }
        }
        // A short window shows fewer rows rather than letting the list run off its bottom edge.
        return Array(results.prefix(rowsThatFit))
    }

    private func display(_ fresh: [CommandResult], animated: Bool) {
        results = fresh
        while rows.count < results.count {
            let row = CommandRowView()
            row.onClick = { [weak self, weak row] event in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.activate(self.results[index], modifiers: event.modifierFlags)
            }
            row.hoverChanged = { [weak self, weak row] hovering in
                // Only a mouse that actually moved picks a row; a resting cursor must not steal the selection.
                guard let self, let row, hovering, NSEvent.mouseLocation != self.mouseAtOpen,
                      let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.select(index)
            }
            rows.append(row)
            panel.addSubview(row)
        }
        while rows.count > results.count { rows.removeLast().removeFromSuperview() }
        for (row, result) in zip(rows, results) { row.isCompact = isAnchored; row.configure(result) }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        if !results.isEmpty { selectedIndex = 0 }
        updateSelection()
        let frame = panelFrame()
        // While you type, the list never bounces: it grows at once to fit more, and gives back room only once the
        // results have stayed fewer for a moment (web suggestions arrive a beat after what's local).
        shrinkWork?.cancel()
        if animated, isVisible, frame.height < panel.frame.height, frame.minY == panel.frame.minY, frame.width == panel.frame.width {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.panel.frame = self.panelFrame()
                    self.panel.needsLayout = true
                }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            // Meanwhile the rows that are gone just aren't drawn; the panel keeps its size.
            panel.needsLayout = true
            return
        }
        panel.frame = frame
        panel.needsLayout = true
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        updateSelection()
    }

    /// Moves the selection by one row, wrapping around at either end.
    func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        select((selectedIndex + delta + results.count) % results.count)
        // Focus stays in the field, so VoiceOver hears which row the arrows landed on.
        let result = results[selectedIndex]
        Announcement.post([result.title, result.detail, result.actionLabel].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func updateSelection() {
        // A note is never highlighted: there's nothing for Return to do on it.
        for (i, row) in rows.enumerated() { row.isSelected = i == selectedIndex && results[i].isActionable }
    }

    // MARK: Searching one site

    private func refreshHint() {
        hintedKeyword = !isScoped && mode != .history ? OmniboxKeyword.named(typed, among: keywords()) : nil
        hinted = !isScoped && hintedKeyword == nil && mode != .history ? SiteSearch.match(typed) : nil
        let name = hintedKeyword?.name ?? hinted?.name
        hint.stringValue = name.map { String(localized: "Search \($0)", comment: "In the command bar, when what's typed names a site: Tab searches it. The name is the site's, like YouTube.") } ?? ""
        hint.isHidden = name == nil
        hintKey.isHidden = name == nil
        panel.needsLayout = true
    }

    #if DEBUG
    func debugTab() {
        if !isScoped, let keyword = hintedKeyword { setKeyword(keyword, typedBefore: typed) } else if scope == nil, let site = hinted { setScope(site) }
    }
    #endif

    private func setScope(_ site: SiteSearch?) { applyScope(site: site, keyword: nil) }

    /// Into an extension's keyword. `text`: what followed the keyword and its space; `typedBefore`: what Esc gives back.
    private func setKeyword(_ keyword: OmniboxKeyword, text: String = "", typedBefore: String) {
        applyScope(site: nil, keyword: keyword, text: text, typedBefore: typedBefore)
    }

    private func applyScope(site: SiteSearch?, keyword next: OmniboxKeyword?, text: String = "", typedBefore: String? = nil) {
        let named = site?.name ?? next?.name
        let entering = named != nil && !isScoped, leaving = named == nil && isScoped
        let before = field.frame
        scope = site
        if next != keyword {
            endKeyword()
            keyword = next
        }
        if leaving { fadeOutChip() } else { chip.isHidden = named == nil }
        // The site's name in the space's accent, then a hairline, as a page heads itself ("zigzag | history"):
        // no capsule, no brand color.
        let theme = Brand.Theme.for(panel)
        chip.color = .clear
        chip.layer?.borderWidth = 0
        chipLabel.textColor = theme.accent
        chipLabel.stringValue = named ?? ""
        completion = nil
        if named != nil {
            if entering { typedBeforeScope = typedBefore ?? typed }
            field.stringValue = text
            typed = text
            suggestions = []
            (field.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        } else if leaving {
            // Back to exactly what you'd typed, cursor at its end: Tab by mistake costs nothing.
            field.stringValue = typedBeforeScope
            typed = typedBeforeScope
            (field.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: (typedBeforeScope as NSString).length, length: 0)
        }
        let font = field.font ?? Tokens.Font.title(.regular)
        let placeholder = named.map { String(localized: "Search \($0)", comment: "Placeholder of the command bar's field while it searches one site. The name is the site's, like YouTube.") }
            ?? (mode == .history ? String(localized: "Search history", comment: "Placeholder of the command bar's field while it searches history.") : String(localized: "Search or enter address", comment: "Placeholder of the command bar's field."))
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
                                                               attributes: [.font: font, .kern: Tokens.Font.voiceKern(font.pointSize), .foregroundColor: Tokens.Color.textTertiary])
        if let site { FaviconStore.shared.prefetch(for: site.home) }
        if let next, omniboxInput == nil { startKeyword(next, text: text) }
        // The extension's own icon where the glass was.
        let icon = next != nil ? omniboxInput?.icon : nil
        fieldIcon.image = icon ?? Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.title)
        refreshHint()
        refreshResults(animated: true)
        if entering || leaving { animateScope(entering: entering, fieldFrom: before) }
    }

    // MARK: Extension keywords

    /// The bar's extensions' omnibox, in a browser window; nil elsewhere and while searching history.
    private var omnibox: BridgeOmnibox? {
        guard controller != nil, mode != .history, let profile = host?.commandBarProfile else { return nil }
        return (profile.isDefault ? profile.extensions : profile.startedExtensions)?.bridge.omnibox
    }

    private func keywords() -> [OmniboxKeyword] { omnibox?.keywords(isPrivate: host?.commandBarIsPrivate ?? false) ?? [] }

    private func startKeyword(_ keyword: OmniboxKeyword, text: String) {
        guard let omnibox else { return }
        let input = omnibox.start(keyword, isPrivate: host?.commandBarIsPrivate ?? false)
        input.onChange = { [weak self, weak input] in
            guard let self, self.isVisible, let input, self.omniboxInput === input else { return }
            self.mergeArrived()
        }
        omniboxInput = input
        if !text.isEmpty { input.change(text) }
    }

    /// Leaving the keyword without Return: onInputCancelled.
    private func endKeyword() {
        omniboxWork?.cancel()
        omniboxInput?.cancel()
        omniboxInput = nil
    }

    /// What's typed goes to the extension once typing pauses for a moment.
    private func keywordTyped(_ text: String) {
        omniboxWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.typed == text else { return }
                self.omniboxInput?.change(text)
            }
        }
        omniboxWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// What's typed as the extension's default suggestion, then what it suggests; Return sends the chosen one.
    private func keywordResults(_ keyword: OmniboxKeyword) -> [CommandResult] {
        let icon = omniboxInput?.icon
        let symbol = "puzzlepiece.extension"
        var rows: [CommandResult] = []
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            let styled = omniboxInput?.defaultSuggestion.map { OmniboxText.defaultSuggestion($0, typed: typed) }
            let title = styled.flatMap { $0.text.isEmpty ? nil : $0 } ?? OmniboxText.Styled(text: typed, runs: [])
            rows.append(CommandResult(kind: .omnibox(extensionID: keyword.extensionID, content: typed, isDefault: true), title: title.text,
                                      detail: keyword.name, icon: icon, symbol: symbol, titleRuns: title.runs))
        }
        for suggestion in omniboxInput?.suggestions ?? [] {
            let text = suggestion.description.text
            let address = URL(string: suggestion.content).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
            let shown = address.map { CommandRanker.displayURL($0) } ?? suggestion.content
            // Under the text, unless the text already says it.
            let detail = text.isEmpty || text.contains(shown) ? "" : shown
            rows.append(CommandResult(kind: .omnibox(extensionID: keyword.extensionID, content: suggestion.content, isDefault: false),
                                      title: text.isEmpty ? suggestion.content : text, detail: detail, icon: icon, symbol: symbol,
                                      titleRuns: text.isEmpty ? [] : suggestion.description.runs))
        }
        return rows
    }

    /// Tab into a site: its chip pops in where your words were, and the field slides over to make room. Leaving
    /// slides it back. Nothing jumps.
    private func animateScope(entering: Bool, fieldFrom before: NSRect) {
        guard !Tokens.Motion.reduceMotion else { return }
        let curve = Tokens.Motion.snappy
        panel.layoutSubtreeIfNeeded()
        let after = field.frame
        if before != after, before != .zero {
            field.frame = before
            // Tab is how you get here, so it moves even from the keyboard.
            Tokens.Motion.animate(curve, evenFromKeyboard: true, moves: true) { self.field.animator().frame = after }
        }
        // The words you typed fade as the field empties, rather than vanishing.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Tokens.Motion.change.duration
        fade.timingFunction = Tokens.Motion.change.timing
        field.layer?.add(fade, forKey: "scope")
        guard entering, let layer = chip.layer else { return }
        // Grows from the chip's own middle: layers scale from their corner, so shift by half the shrink.
        let size = chip.bounds.size, k: CGFloat = 0.92
        let small = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                        CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0))
        let pop = CABasicAnimation(keyPath: "transform")
        pop.fromValue = NSValue(caTransform3D: small)
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = Tokens.Motion.change.duration
        pop.timingFunction = Tokens.Motion.change.timing
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = Tokens.Motion.snap.duration
        show.timingFunction = Tokens.Motion.snap.timing
        layer.add(pop, forKey: "pop")
        layer.add(show, forKey: "show")
    }

    private func fadeOutChip() {
        guard let layer = chip.layer, !chip.isHidden, !Tokens.Motion.reduceMotion else { chip.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isScoped else { return }
            self.chip.isHidden = true
            layer.opacity = 1
            self.panel.needsLayout = true
        }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = Tokens.Motion.snap.duration
        out.timingFunction = Tokens.Motion.snap.timing
        layer.add(out, forKey: "hide")
        layer.opacity = 0
        CATransaction.commit()
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let text = field.stringValue
        let length = (text as NSString).length
        // What the field held before this change: what you'd typed, and the completion after it.
        let shown = completion.map { typed + $0.text.dropFirst(typed.count) } ?? typed
        let caretAtEnd = editor.selectedRange == NSRange(location: length, length: 0)
        let previous = completion
        let deleting = (deleteEvent != nil && NSApp.currentEvent === deleteEvent)
            || editor.undoManager?.isUndoing == true || editor.undoManager?.isRedoing == true
        let allowed = InlineCompletion.allowed(text, shown: shown, typed: typed, deleting: deleting,
                                               caretAtEnd: caretAtEnd, hasMarkedText: editor.hasMarkedText())
        // An extension's keyword and a space: what follows goes to the extension. Never while deleting or composing.
        if !isScoped, !deleting, !editor.hasMarkedText(), let entered = OmniboxKeyword.entered(text, among: keywords()) {
            setKeyword(entered.keyword, text: entered.rest, typedBefore: String(text.prefix { $0 != " " }))
            return
        }
        typed = text
        completion = nil
        completionAsked = nil
        if keyword != nil {
            history.stopSites()
            fetcher.cancel()
            refreshResults(animated: true)
            keywordTyped(text)
            return
        }
        // Not in a site search or history, and never while an input method is still composing.
        if allowed, !isScoped, host != nil, mode != .history {
            // A letter that agrees with the completion keeps it, unless it finished a host you've been to. One lookup per
            // keystroke, off the main thread: until History answers, only the completion already showing can stay.
            completion = InlineCompletion.next(previous: previous, found: foundCompletion(for: text), typed: text)
            fillCompletion(editor)
        } else {
            history.stopSites()
        }
        refreshHint()
        refreshResults(animated: true)
        // Searching history stays on this Mac: nothing you type there goes to the search engine.
        guard mode != .history else { fetcher.cancel(); return }
        fetcher.fetch(text) { [weak self] list in
            guard let self, self.isVisible, self.typed == text else { return }
            self.suggestions = list
            self.mergeArrived()
        }
    }

    /// What History's sites complete the text to, once they're read; nil meanwhile (`completionArrived` follows up).
    private func foundCompletion(for text: String) -> InlineCompletion.Match? {
        guard let bare = CommandRanker.completionPrefix(for: text) else { return nil }
        guard let sites = history.completionSites(for: bare) else { completionAsked = text; return nil }
        guard let host else { return nil }
        return CommandRanker.inlineCompletion(for: text, manager: host.commandBarTabs, profile: host.commandBarProfile, history: sites)
    }

    /// What you typed stays as you typed it; the rest of the completion follows, selected, so the next letter replaces it.
    private func fillCompletion(_ editor: NSTextView) {
        guard let completion, completion.text.count > typed.count else { return }
        let length = (typed as NSString).length
        let rest = String(completion.text.dropFirst(typed.count))
        editor.replaceCharacters(in: NSRange(location: length, length: 0), with: rest)
        editor.selectedRange = NSRange(location: length, length: (rest as NSString).length)
    }

    /// History's sites arrived for what you typed: the completion they give fills in now, as if it had come at once,
    /// unless you've moved on since (the caret moved, a row picked with the arrows; another letter asks afresh).
    private func completionArrived() {
        guard isVisible, let asked = completionAsked, asked == typed, !isScoped, mode != .history, selectedIndex == 0,
              let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let atEnd = field.stringValue == typed && editor.selectedRange == NSRange(location: (typed as NSString).length, length: 0)
        guard atEnd || completionIsSelected(editor) else { return }
        completionAsked = nil
        let next = InlineCompletion.next(previous: completion, found: foundCompletion(for: typed), typed: typed)
        guard next != completion else { return }
        takeBackCompletion()
        completion = next
        fillCompletion(editor)
        refreshResults(animated: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            step(1); return true
        case #selector(NSResponder.moveUp(_:)):
            step(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(modifiers: NSApp.currentEvent?.modifierFlags ?? []); return true
        // ⌥↩ reaches a text field as this, not as a plain newline.
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commit(modifiers: (NSApp.currentEvent?.modifierFlags ?? []).union(.option)); return true
        case #selector(NSResponder.cancelOperation(_:)) where isScoped:
            setScope(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // The first Esc takes back the completion, leaving what you typed; the next closes the bar.
            if takeBackCompletion() {
                refreshResults(animated: true)
            } else {
                dismiss()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab on a keyword or a site's name goes into it; otherwise it accepts the inline completion.
            if !isScoped, let keyword = hintedKeyword {
                setKeyword(keyword, typedBefore: typed)
            } else if !isScoped, let site = hinted {
                setScope(site)
            } else if completion != nil {
                acceptCompletion(textView)
            } else {
                step(1)
            }
            return true
        // Shift-Tab steps back up the list; focus stays in the field while the bar is open.
        case #selector(NSResponder.insertBacktab(_:)):
            step(-1)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where isScoped && field.stringValue.isEmpty:
            setScope(nil)
            return true
        // → and End take the completion as typed, caret after it. (End scrolls a text view rather than moving the caret.)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            guard completion != nil, field.stringValue != typed else { return false }
            acceptCompletion(textView)
            return true
        default:
            guard NSStringFromSelector(selector).hasPrefix("delete") else { return false }
            // Deleting the selected completion takes it back, the way Esc does, so Undo never brings it back as text.
            if completionIsSelected(textView), takeBackCompletion() {
                refreshResults(animated: true)
                return true
            }
            deleteEvent = NSApp.currentEvent
            return false
        }
    }

    /// The completion is showing after what you typed, selected the way it was filled in.
    private func completionIsSelected(_ editor: NSTextView) -> Bool {
        guard completion != nil, field.stringValue != typed, !editor.hasMarkedText() else { return false }
        let end = (typed as NSString).length
        return editor.selectedRange == NSRange(location: end, length: (field.stringValue as NSString).length - end)
    }

    /// Removes the completion from the field, leaving what you typed with the caret after it. It went in without
    /// Undo and leaves the same way, so Undo only ever sees what you typed.
    @discardableResult
    private func takeBackCompletion() -> Bool {
        guard completion != nil, field.stringValue != typed, let editor = field.currentEditor() as? NSTextView else { return false }
        let end = (typed as NSString).length
        editor.replaceCharacters(in: NSRange(location: end, length: (field.stringValue as NSString).length - end), with: "")
        editor.selectedRange = NSRange(location: end, length: 0)
        completion = nil
        return true
    }

    /// A letter about to replace the selected completion: it's taken back first, so the letter goes after what you
    /// typed and Undo doesn't remember the completion as something you replaced.
    private func letterWillReplaceCompletion(_ event: NSEvent) {
        guard isVisible, event.window === host?.window, let editor = field.currentEditor() as? NSTextView,
              editor.window?.firstResponder === editor, completionIsSelected(editor),
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let scalar = event.characters?.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) else { return }
        takeBackCompletion()
    }

    @objc private func undoWillChange(_ note: Notification) {
        guard isVisible, let editor = field.currentEditor(), note.object as? UndoManager === editor.undoManager else { return }
        if takeBackCompletion() { refreshResults(animated: false) }
    }

    /// The completion becomes what you typed: the caret goes after it and it stays the first row.
    private func acceptCompletion(_ textView: NSTextView) {
        textView.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        typed = field.stringValue
    }

    private func commit(modifiers: NSEvent.ModifierFlags) {
        if results.indices.contains(selectedIndex) {
            guard results[selectedIndex].isActionable else { return }
            activate(results[selectedIndex], modifiers: modifiers)
        } else if let destination = CommandRanker.destination(from: field.stringValue) {
            activate(CommandResult(kind: .open(destination.url, httpFallback: destination.httpFallback), title: "", detail: ""), modifiers: modifiers)
        } else if mode == .editCurrent, let tab = host?.commandBarTab, field.stringValue == tab.shownURL?.absoluteString {
            tab.reload()
            dismiss()
        }
    }

    private func activate(_ result: CommandResult, modifiers: NSEvent.ModifierFlags) {
        guard let host, result.isActionable else { return }
        let editing = mode == .editCurrent && host.commandBarTab != nil
        // An extension's keyword: the extension decides what happens, told where to open it.
        if case .omnibox(_, let content, _) = result.kind {
            let input = omniboxInput
            omniboxInput = nil
            omniboxWork?.cancel()
            input?.enter(content, disposition: OmniboxKeyword.disposition(modifiers: modifiers, inNewTab: !editing))
            dismiss(restoringFocus: false)
            unsent = nil
            if let controller, let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
            return
        }
        dismiss(restoringFocus: false)
        unsent = nil
        if host.commandBarOpen(result.kind, modifiers: modifiers, editing: editing) { return }
        guard let controller else { return }
        let manager = controller.tabManager
        let inBackground = modifiers.contains(.command)
        // ⌥↩ on Switch to Tab: a second copy of that page in a new tab instead.
        let forceNew = modifiers.contains(.option)
        let inCurrent = editing
        func open(_ url: URL, search: Bool = false, httpFallback: Bool = false) {
            if !inCurrent { Tutorial.complete("newTab") }
            // Routed sites open in their space (#286), never over the current page. Searches stay here.
            if !search, controller.openRouted(url, arrival: .typed, inBackground: inBackground && !inCurrent, by: .you,
                                              httpFallback: httpFallback) { return }
            // Typed or chosen here: yours, so an app's link you typed opens without asking (the site's Block still holds).
            if inCurrent {
                manager.selectedTab?.load(url, by: .you, httpFallback: httpFallback)
                manager.selectedTab?.isSearchTab = search
            } else {
                let tab = manager.newTab(url: url, select: !inBackground, by: .you, httpFallback: httpFallback)
                tab.isSearchTab = search
            }
        }
        switch result.kind {
        case .open(let url, let httpFallback):
            // Back from the archive: it's a tab again, so it leaves the archive.
            TabArchive.shared.remove(url: url)
            open(url, httpFallback: httpFallback)
        case .history(let url):
            TabArchive.shared.remove(url: url)
            open(url)
        case .search(let query), .suggestion(let query):
            open(Library.shared.searchEngine.searchURL(query), search: true)
        case .searchOn(let url):
            open(url, search: true)
        case .switchTo(let id):
            if forceNew || inBackground, let url = manager.tab(with: id)?.url {
                manager.newTab(url: url, select: !inBackground)
            } else if let tab = manager.tab(with: id) {
                manager.select(tab)
            }
        case .bookmark(let id):
            if let bookmark = Library.shared.bookmark(id) {
                if Library.shared.spaceID(ofBookmark: id) != manager.currentSpaceID, let space = Library.shared.spaceID(ofBookmark: id) {
                    manager.switchToSpace(space)
                }
                manager.openBookmark(bookmark)
            }
        case .action(let id):
            runAction(id)
            return
        case .note, .omnibox:
            return
        }
        if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }
}

extension CommandBarController {
    func runAction(_ id: String) {
        guard let controller else { return }
        switch id {
        case "import": ImportWindowController.show()
        case "export": DataExport.show(in: controller)
        case "passwords": PasswordsWindowController.show()
        case "clear-cache": controller.confirmClearCache()
        case "clear-cookies": controller.confirmClearCookies()
        case "feedback": Feedback.show(in: controller)
        case "report": ProblemReport.show(in: controller)
        case "history": HistoryPage.open(in: controller)
        case "archive": ArchivePage.open(in: controller)
        case "settings": SettingsPage.open(in: controller)
        case "show-headless": Headless.showWindow()
        // The page and window commands do what the menu bar's items of the same name do.
        case "pin": if let tab = controller.tabManager.selectedTab { controller.save(tab, request: .quick) }
        case "pin-to-folder": if let tab = controller.tabManager.selectedTab { controller.save(tab, request: .picker) }
        case "unpin": if let tab = controller.tabManager.selectedTab { controller.toggleSavedState(of: tab) }
        case "favorite": controller.addToFavorites(nil)
        case "separate": controller.closeSplitView(nil)
        case "split":
            if let tab = controller.tabManager.selectedTab, let other = CommandRanker.splitPartner(for: tab, in: controller.tabManager) {
                controller.splitWithUndo(tab, with: other)
            }
        case "close-others": controller.closeOtherTabs(nil)
        case "capture": controller.capture.begin()
        case "close-below": controller.closeTabsBelow(nil)
        case "reopen": controller.reopenClosedTab(nil)
        case "new-space": controller.newSpace(nil)
        default:
            // A developer tool does what its menu item does.
            if let tool = DeveloperTool(commandID: id) { tool.run(in: controller); return }
            if let size = PageSizes.size(commandID: id) { controller.setPageSize(size.size); return }
            if id.hasPrefix("space:"), let space = UUID(uuidString: String(id.dropFirst(6))), Library.shared.space(space) != nil {
                controller.tabManager.switchToSpace(space)
            } else if id.hasPrefix("move:"), let space = UUID(uuidString: String(id.dropFirst(5))), Library.shared.space(space) != nil,
                      let tab = controller.tabManager.selectedTab, tab.bookmarkID == nil {
                controller.moveToSpaceWithToast(tab, spaceID: space)
            }
        }
    }
}

#if DEBUG
extension CommandBarController {
    func debugEnter(_ modifiers: NSEvent.ModifierFlags = []) { commit(modifiers: modifiers) }

    /// `barrows <path>`: the chip, what's typed, the hint and each row.
    var debugState: [String: Any] {
        ["chip": chip.isHidden ? "" : chipLabel.stringValue, "typed": typed, "field": field.stringValue, "keyword": keyword?.keyword ?? "",
         "hint": hint.isHidden ? "" : hint.stringValue, "selected": selectedIndex,
         "rows": results.map { result in
             ["title": result.title, "detail": result.detail, "action": result.actionLabel, "kind": String(describing: result.kind),
              "runs": result.titleRuns.map { "\($0.range.location)+\($0.range.length) \($0.styles.map(\.rawValue).sorted())" }] as [String: Any]
         }]
    }

    /// Backspace in the field, as the key would press it.
    func debugBackspace() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        if !control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))) { editor.deleteBackward(nil) }
    }

    func debugType(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// `bardrag`: drags the bar by its edge; `ending` releases.
    func debugDrag(_ dx: CGFloat, _ dy: CGFloat, ending: Bool) {
        guard isMovable else { return }
        if dragStart == nil { beginDrag() }
        drag(by: NSPoint(x: dx, y: dy))
        if ending { endDrag() }
    }

    /// `barreset`: as a double-click on the edge.
    func debugResetPosition() { if isMovable { resetPosition() } }

    var debugPanelFrame: NSRect { panel.frame }

    /// Esc in the field, as the key would press it.
    func debugEscape() {
        guard let editor = field.currentEditor() as? NSTextView else { dismiss(); return }
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }
}
#endif

/// Dims the page under a floating panel; clicking it dismisses the panel.
final class ScrimView: ColorView {
    var onClick: (() -> Void)?

    init(dims: Bool = true) {
        super.init(color: dims ? Tokens.Color.scrim : nil)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Clicks pass through while it fades out.
    private var isLeaving = false
    override func hitTest(_ point: NSPoint) -> NSView? { isLeaving ? nil : super.hitTest(point) }

    /// Fades in from its current opacity, reversing a fade-out instead of flashing. `evenFromKeyboard`: fade even from
    /// a key (a sheet), unlike the command bar. `animated` false: shown at once.
    func show(evenFromKeyboard: Bool = false, animated: Bool = true) {
        isLeaving = false
        let shown = layer?.presentation()?.opacity
        Tokens.Motion.withoutAnimation { alphaValue = animated ? shown.map { CGFloat($0) } ?? 0 : 1 }
        guard animated else { layer?.removeAnimation(forKey: "opacity"); return }
        Tokens.Motion.fadeBackdrop(self, entering: true, evenFromKeyboard: evenFromKeyboard)
    }

    /// `evenFromKeyboard`: it fades with something that leaves even from a key (a sheet), rather than going at once
    /// with the command bar.
    func hide(evenFromKeyboard: Bool = false) {
        isLeaving = true
        Tokens.Motion.fadeBackdrop(self, entering: false, evenFromKeyboard: evenFromKeyboard) {
            if self.isLeaving { self.removeFromSuperview() }
        }
    }
}

/// An image view that passes presses through.
final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Snap guides for a dragged command bar: a vertical line at the default center and a horizontal one at its top, each
/// shown only while snapped.
final class CommandBarGuides: NSView {
    private let vertical = CALayer()
    private let horizontal = CALayer()
    var color: NSColor = Tokens.Color.textTertiary { didSet { refreshColor() } }
    private var x: CGFloat?
    private var y: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [vertical, horizontal] {
            line.opacity = 0
            line.cornerRadius = Tokens.Metric.hairline / 2
            layer?.addSublayer(line)
        }
        refreshColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let line = cgColor(color.withAlphaComponent(0.7))
            Tokens.Motion.withoutAnimation { [vertical, horizontal].forEach { $0.backgroundColor = line } }
        }
    }

    /// In overlay coordinates; nil fades that line out.
    func show(x: CGFloat?, y: CGFloat?) {
        if let x { self.x = x }
        if let y { self.y = y }
        place()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Tokens.Motion.snap.duration)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.snap.timing)
        vertical.opacity = x == nil ? 0 : 1
        horizontal.opacity = y == nil ? 0 : 1
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let inset = Tokens.Space.x2, line = Tokens.Metric.hairline
        Tokens.Motion.withoutAnimation {
            if let x { vertical.frame = NSRect(x: floor(x), y: inset, width: line, height: max(0, bounds.height - inset * 2)) }
            if let y { horizontal.frame = NSRect(x: inset, y: floor(y), width: max(0, bounds.width - inset * 2), height: line) }
        }
    }
}
