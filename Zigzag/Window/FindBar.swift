import AppKit
import WebKit

/// A floating text field we draw ourselves: no bezel, our font, our colors.
final class PlainTextField: NSTextField {
    var onCancel: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?
    /// Room at the sides for a selection and the first letter to draw whole (the address). Zero for fields lined up
    /// with a label they replace, like renaming.
    var textInset: CGFloat = 0
    /// Text centered top to bottom in a field taller than its line (the address). Off, the text sits where AppKit
    /// puts it, as every other field always has.
    var centersText = false
    /// Items to offer right after Paste in the field's right-click menu (the address's Paste and Go).
    var pasteMenuItems: (() -> [NSMenuItem])?

    /// The field editor asks its delegate, this field, for the menu it shows on a right-click.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let items = pasteMenuItems?(), !items.isEmpty else { return menu }
        let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
        var index = paste.map { $0 + 1 } ?? 0
        for item in items { menu.insertItem(item, at: index); index += 1 }
        return menu
    }

    init(font: NSFont, placeholder: String) {
        super.init(frame: .zero)
        // A new cell starts out read-only; a text field you type in needs it editable again.
        cell = PaddedTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        self.font = font
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = Tokens.Color.textPrimary
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: Tokens.Color.textTertiary,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Draws and edits the text a little in from the sides, and centered in its height if the field asks, so a selection
/// that runs to the edge, or the first letter of a long address, isn't cut off.
private final class PaddedTextFieldCell: NSTextFieldCell {
    private func textRect(in rect: NSRect) -> NSRect {
        let field = controlView as? PlainTextField
        var r = rect.insetBy(dx: field?.textInset ?? 0, dy: 0)
        guard field?.centersText == true else { return r }
        let height = ceil(cellSize(forBounds: r).height)
        if height < r.height { r.origin.y += floor((r.height - height) / 2); r.size.height = height }
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { super.drawingRect(forBounds: textRect(in: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(in: rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: textRect(in: rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }

}

/// Find in page: a floating capsule at the top right of the page card holding a magnifying glass, the field, the count,
/// and round buttons whose circles run with the capsule's end.
final class FindBarController: NSObject, NSTextFieldDelegate {
    private weak var window: BrowserWindowController?
    private let panel = FloatingPanelView()
    private let glass = NSImageView(image: Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.body))
    private let field = PlainTextField(font: Tokens.Font.body(), placeholder: String(localized: "Find on page", comment: "Placeholder of the find bar's field."))
    private let countLabel = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let previousButton = IconButton(symbol: "chevron.up", toolTip: String(localized: "Previous", comment: "Tooltip of the find bar's button that goes to the previous match."))
    private let nextButton = IconButton(symbol: "chevron.down", toolTip: String(localized: "Next", comment: "Tooltip of the find bar's button that goes to the next match."))
    private let doneButton = IconButton(symbol: "xmark", toolTip: String(localized: "Done", comment: "Tooltip of the find bar's close button."))
    private(set) var isVisible = false
    private var query = ""
    var hasQuery: Bool { !query.isEmpty }

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        field.delegate = self
        panel.radius = Tokens.Metric.findBarHeight / 2
        glass.contentTintColor = Tokens.Color.textTertiary
        glass.imageScaling = .scaleNone
        panel.addSubview(glass)
        panel.addSubview(field)
        panel.addSubview(countLabel)
        panel.addSubview(previousButton)
        panel.addSubview(nextButton)
        panel.addSubview(doneButton)
        previousButton.onClick = { [weak self] _ in self?.next(backwards: true) }
        nextButton.onClick = { [weak self] _ in self?.next(backwards: false) }
        doneButton.onClick = { [weak self] _ in self?.hide() }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
    }

    /// The page the last search ran in, so its highlight goes when you move to the other pane.
    private weak var searched: WKWebView?
    /// The PDF the last search ran in, for the same reason.
    private weak var searchedPDF: PDFViewerView?
    /// A PDF is searched a moment after you stop typing: a long one takes a while, and each letter shouldn't wait.
    private var pdfSearch: DispatchWorkItem?

    /// Over the page it searches: in split view, the pane you're working in.
    private var frame: NSRect {
        guard let window else { return .zero }
        let card = window.focusedPaneFrame
        let height = Tokens.Metric.findBarHeight
        let width = Tokens.Metric.findBarWidth
        // Below a split pane's header, as far into the page as without one, clear of the header's buttons.
        let header = window.root.card.showsHeader ? PaneHeaderView.height : 0
        return NSRect(x: card.maxX - width - Tokens.Space.x3, y: card.minY + header + Tokens.Space.x3, width: width, height: height)
    }

    private func layoutPanel() {
        let b = panel.bounds
        let button = Tokens.Metric.iconButton
        // As far in from the end as from the top and bottom, so Done's circle runs with the capsule's.
        let inset = (b.height - button) / 2
        doneButton.frame = NSRect(x: b.width - inset - button, y: inset, width: button, height: button)
        nextButton.frame = NSRect(x: doneButton.frame.minX - button, y: inset, width: button, height: button)
        previousButton.frame = NSRect(x: nextButton.frame.minX - button, y: inset, width: button, height: button)
        [previousButton, nextButton, doneButton].forEach { $0.radius = button / 2 }
        let countWidth = countLabel.textWidth
        let countHeight = countLabel.lineHeight
        countLabel.frame = NSRect(x: previousButton.frame.minX - Tokens.Space.x1 - countWidth, y: (b.height - countHeight) / 2, width: countWidth, height: countHeight)
        let side = Tokens.Metric.favicon
        glass.frame = NSRect(x: Tokens.Space.x3 + 2, y: (b.height - side) / 2, width: side, height: side)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let x = glass.frame.maxX + Tokens.Space.x1 + 2
        field.frame = NSRect(x: x, y: (b.height - fieldHeight) / 2, width: max(0, countLabel.frame.minX - x - Tokens.Space.x2), height: fieldHeight)
    }

    /// ⌘F: opens the bar, or puts you back in it; pressed again while you're typing in it, closes it.
    func toggle() {
        if isVisible, field.currentEditor() != nil { hide() } else { show() }
    }

    func show(query newQuery: String? = nil, focus: Bool = true) {
        guard let window else { return }
        if let newQuery { query = newQuery; field.stringValue = newQuery }
        if !isVisible {
            isVisible = true
            panel.frame = frame
            window.root.overlay.addSubview(panel)
            panel.present()
            watchEscape()
        } else {
            panel.frame = frame
        }
        if focus {
            window.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        if !query.isEmpty { search(backwards: false, fromStart: !focus) }
    }

    /// Esc closes the bar from the page too, not only from its field, so you never need the mouse for it.
    private var escapeMonitor: Any?
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.isVisible, event.window === self.window?.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  // Something else in front (the address bar, peek) takes its own Esc first.
                  self.window?.commandBar.isVisible != true, self.window?.peek.isVisible != true else { return event }
            self.hide()
            return nil
        }
    }

    /// What you were finding in each tab: switching away puts the bar away, and coming back brings it back.
    private let remembered = NSMapTable<WKWebView, NSString>.weakToStrongObjects()

    func reposition() {
        guard isVisible else { return }
        panel.frame = frame
    }

    /// Another page came to the front. The other pane of a split: the bar moves over it and searches there. Another
    /// tab: the bar goes with the tab it was opened in, and comes back when you return to a tab you were finding in.
    func pageChanged() {
        let current = window?.selectedWebView
        guard isVisible else {
            if let current, let saved = remembered.object(forKey: current) as String? { show(query: saved, focus: false) }
            return
        }
        guard current !== searched else { return }
        // Still on screen (the other half of a split): follow over to the pane you're in. Otherwise it was another tab.
        let stillShown = searched.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false
        if !stillShown {
            if let searched, !query.isEmpty { remembered.setObject(query as NSString, forKey: searched) }
            hide(keepingMemory: true, focusPage: false)
            if let current, let saved = remembered.object(forKey: current) as String? { show(query: saved, focus: false) }
            return
        }
        clearHighlights()
        let target = frame
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) { [panel] in panel.animator().frame = target }
        if query.isEmpty { countLabel.stringValue = ""; layoutPanel() } else { search(backwards: false, fromStart: true) }
    }

    func hide() { hide(keepingMemory: false, focusPage: true) }

    private func hide(keepingMemory: Bool, focusPage: Bool) {
        guard isVisible else { return }
        isVisible = false
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        // Closed on purpose: that tab's search is done.
        if !keepingMemory, let webView = searched ?? window?.selectedWebView { remembered.removeObject(forKey: webView) }
        panel.dismiss()
        clearHighlights()
        if focusPage, let webView = window?.selectedWebView { window?.window?.makeFirstResponder(webView) }
    }

    func next(backwards: Bool) {
        if !isVisible { show() }
        search(backwards: backwards)
    }

    func controlTextDidChange(_ obj: Notification) {
        query = field.stringValue
        if query.isEmpty { countLabel.stringValue = ""; clearHighlights(); layoutPanel(); return }
        search(backwards: false, fromStart: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            search(backwards: shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func search(backwards: Bool, fromStart: Bool = false) {
        // A PDF is searched in its own viewer, which knows its pages and counts the matches itself.
        if let pdf = window?.selectedTab?.pdfViewer {
            searched = window?.selectedWebView
            searchedPDF = pdf
            pdfSearch?.cancel()
            let query = query
            let work = DispatchWorkItem { [weak self, weak pdf] in
                guard let self, let pdf else { return }
                let found = pdf.find(query, backwards: backwards, fromStart: fromStart)
                self.showCount(query.isEmpty ? "" : found.count == 0 ? Self.noMatches
                    : found.count == 1 ? Self.matches(found.count) : Self.place(found.place, of: found.count))
                self.countLabel.textColor = found.count > 0 ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
                self.layoutPanel()
            }
            pdfSearch = work
            // Typing waits; Return and the arrows move at once.
            if fromStart { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) } else { work.perform() }
            return
        }
        guard let webView = window?.selectedWebView, !query.isEmpty else { return }
        searched = webView
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        if fromStart { webView.evaluateJavaScript("window.getSelection().removeAllRanges()") }
        webView.find(query, configuration: config) { [weak self] result in
            self?.updateCount(found: result.matchFound)
        }
    }

    private static var noMatches: String { String(localized: "No matches", comment: "Find bar count when the page has nothing that matches.") }

    /// "12 matches", or "1 match".
    private static func matches(_ count: Int) -> String { String(localized: "\(count) matches", comment: "Find bar count: how many matches the page has.") }

    /// "3 of 12": the match you're on, and how many there are.
    private static func place(_ place: Int, of count: Int) -> String {
        String(localized: "\(place) of \(count)", comment: "Find bar count: the match you're on, and how many there are, like 3 of 12.")
    }

    private func updateCount(found: Bool) {
        guard let webView = window?.selectedWebView else { return }
        // WebKit's public find API doesn't count; a quick text scan does. It runs in Zigzag's own script world with
        // the query passed in, so the page can't see what you search for or change how it's counted.
        // Counted over the same text twice, the whole page and the part before the match WebKit just selected, so
        // "3 of 12" is where you are in the page.
        let script = """
        const q = String(query).toLowerCase(); if (!q || !document.body) return [0, 0];
        const count = (t) => { t = t.toLowerCase(); let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; };
        const all = document.createRange(); all.selectNodeContents(document.body);
        const total = count(all.toString());
        const sel = window.getSelection(); if (!sel.rangeCount) return [0, total];
        const before = document.createRange(); before.setStart(document.body, 0);
        const r = sel.getRangeAt(0); before.setEnd(r.startContainer, r.startOffset);
        return [count(before.toString()) + 1, total];
        """
        webView.callAsyncJavaScript(script, arguments: ["query": query], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pair = ((try? result.get()) as? [Int]) ?? [0, 0]
                let count = max(pair.count > 1 ? pair[1] : 0, 1), place = pair.first ?? 0
                self.showCount(!found ? Self.noMatches : count == 1 ? Self.matches(count)
                    : (1...count).contains(place) ? Self.place(place, of: count) : Self.matches(count))
                self.countLabel.textColor = found ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
                self.layoutPanel()
            }
        }
    }

    /// Shows the match count, and has VoiceOver say it when it changes.
    private func showCount(_ text: String) {
        if text != countLabel.stringValue { Announcement.post(text) }
        countLabel.stringValue = text
    }

    private func clearHighlights() {
        pdfSearch?.cancel()
        (searchedPDF ?? window?.selectedTab?.pdfViewer)?.clearFind()
        searchedPDF = nil
        if let webView = searched ?? window?.selectedWebView {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            // WebKit draws its own highlight over the match, apart from the selection; it stays until told to go.
            if webView.responds(to: Self.hideFindUI) { webView.perform(Self.hideFindUI) }
        }
        searched = nil
    }

    private static let hideFindUI = NSSelectorFromString("_hideFindUI")
}

/// A floating surface (the design's top layer, see Design/DESIGN.md): an opaque surface leaning toward the window's
/// space (`Brand.Theme.panel`), a crisp hairline edge, one soft small shadow, `Tokens.Radius.panel` corners, and an
/// eased arrival out of what opened it. Panels that belong to the sidebar (`liftedFrom`) or are tinted (`surfaceTint`)
/// take that color instead.
class FloatingPanelView: NSView {
    private let surface = ColorView(color: Tokens.Color.panelBackground)
    /// The Mac's own popover material under the surface: a panel reads as part of macOS, softly showing what's
    /// behind it, with the space's color washed thinly over it.
    private let material: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.zPosition = -1
        return view
    }()
    var onLayout: (() -> Void)?
    var radius: CGFloat = Tokens.Radius.panel { didSet { needsLayout = true } }
    /// In a window of its own with nothing else in it (Zigzag Mini's quick open), the material shows the desktop
    /// behind, as it shows the page behind in a browser window.
    var showsDesktop = false { didSet { material.blendingMode = showsDesktop ? .behindWindow : .withinWindow } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = Tokens.Metric.hairline
        surface.layer?.zPosition = 1
        super.addSubview(material)
        addSubview(surface)
        refreshColors()
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refreshColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var themeToken: SignalToken?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }

    override var isFlipped: Bool { true }

    /// Empties the panel so it can show something else in the same place.
    func removeContent() { surface.subviews.forEach { $0.removeFromSuperview() } }

    /// Content goes in the surface so it is clipped to the rounded shape.
    override func addSubview(_ view: NSView) {
        if view === surface { super.addSubview(view) } else { surface.addSubview(view) }
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.layer?.cornerRadius = radius
        material.frame = bounds
        material.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        onLayout?()
        matchCorners()
    }

    /// A button tucked into one of the panel's rounded corners follows that corner: its own radius is the panel's
    /// less the gap between them, so the two curves run side by side instead of a square-ish fill in a round shape.
    private func matchCorners() {
        for view in surface.subviews {
            guard view is IconButton || view is TextButton, !view.isHidden, let layer = view.layer else { continue }
            let f = view.frame
            let dx = min(f.minX, bounds.width - f.maxX), dy = min(f.minY, bounds.height - f.maxY)
            guard dx >= 0, dy >= 0, dx < radius, dy < radius else { continue }
            let fitted = min(max(radius - max(dx, dy), Tokens.Radius.control), min(f.width, f.height) / 2)
            if let button = view as? IconButton { button.radius = fitted } else { layer.cornerRadius = fitted }
            layer.cornerCurve = .continuous
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// A color mixed into the panel's surface, like the space's own, so the panel belongs to it. Nil is plain.
    var surfaceTint: NSColor? { didSet { refreshColors() } }
    /// How much of the tint goes in: more makes the panel read as part of what it's tinted from.
    var tintStrength: CGFloat? { didSet { refreshColors() } }
    /// Off for a panel that stands in for something in place (the address being edited): no shadow, no lift.
    var isElevated = true { didSet { refreshColors() } }
    /// The edge, if not the usual hairline (an edited field's soft accent outline).
    var edgeColor: NSColor? { didSet { refreshColors() } }
    /// Set for a panel that's part of the sidebar: the sidebar's color, which the panel takes lifted the way a
    /// selected tab is, so it reads as the sidebar's own and stands out clearly from it.
    var liftedFrom: NSColor? { didSet { refreshColors() } }
    /// What the panel sits over (the sidebar's tabs): faded back while it's open, so nothing peeks around it.
    var recedes: [NSView] = []

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            material.isHidden = liftedFrom != nil || surfaceTint != nil
            if let base = liftedFrom {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    let under = base.usingColorSpace(.sRGB) ?? base
                    let lift = Tokens.Color.selectedFill.usingColorSpace(.sRGB) ?? Tokens.Color.selectedFill
                    surface.color = under.blended(withFraction: lift.alphaComponent, of: lift.withAlphaComponent(1)) ?? under
                }
            } else if let tint = surfaceTint {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    let base = Tokens.Color.panelBackground.usingColorSpace(.sRGB) ?? Tokens.Color.panelBackground
                    let mixed = base.blended(withFraction: tintStrength ?? (effectiveAppearance.isDark ? 0.55 : 0.6), of: tint.usingColorSpace(.sRGB) ?? tint) ?? base
                    surface.color = mixed
                }
            } else {
                // The Mac's popover material with the space's panel color thinly over it: native, calm, and opaque
                // enough that text never fights the page behind.
                surface.color = Brand.Theme.for(self).panel.withAlphaComponent(0.88)
            }
            surface.layer?.borderColor = cgColor(edgeColor ?? Tokens.Color.panelEdge)
            surface.layer?.borderWidth = edgeColor == nil ? Tokens.Metric.hairline : 1.5
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            layer?.shadowOpacity = isElevated ? 1 : 0
            layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
        }
    }

    /// How a panel arrives. Where it lives decides how it moves:
    /// - opened by a key, or used constantly: it's simply there (`.instant`, and any arrival during a key press);
    /// - opened from a button: it grows out of that button (`growsFrom`), from 97%, eased out in 180ms (`.pop`, `.fade`);
    ///   `.burst` starts from 94%, for a panel something just landed in (a download hitting its button);
    /// - living at the page's top edge (`slidesFromTop`): it slides down from above the window and leaves back up.
    enum Arrival { case drop, fade, instant, zoom, pop, burst }

    /// Where a panel grows from, in its own bounds from the top-left: (0, 0) its top-left corner, (0.5, 0) its top
    /// middle. Set it to the side nearest what opened it.
    var growsFrom = CGPoint(x: 0.5, y: 0)

    /// Scaled by `k` around `growsFrom`, in layer coordinates (a view layer scales from its own corner).
    private func scaled(_ k: CGFloat) -> CATransform3D {
        let w = bounds.width, h = bounds.height
        let px = growsFrom.x * w
        let py = (layer?.isGeometryFlipped == true || isFlipped) ? growsFrom.y * h : (1 - growsFrom.y) * h
        return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(px * (1 - k), py * (1 - k), 0))
    }

    private func recede(_ on: Bool) {
        for view in recedes {
            // Another panel still open over the same tabs keeps them back.
            let held = superview?.subviews.contains { other in
                guard let other = other as? FloatingPanelView, other !== self, !other.dismissing else { return false }
                return other.recedes.contains { $0 === view }
            } ?? false
            if !on && held { continue }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = on ? Tokens.Motion.menuIn : Tokens.Motion.highlightGlide
                context.timingFunction = Tokens.Motion.easeOut
                view.animator().alphaValue = on ? Tokens.Opacity.receded : 1
            }
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { recede(false) }
        super.viewWillMove(toSuperview: newSuperview)
    }

    /// For things that live at the top edge of the page (toasts, offers, prompts): they slide down from above the
    /// window's edge into place and leave back up the same way, instead of growing out of nothing. Where a thing
    /// lives decides how it moves: from its edge, or out of the button that opened it (`growsFrom`).
    var slidesFromTop = false
    /// Above the window's top edge: where a top-edge panel comes from and goes back to.
    private var offstage: CGFloat { frame.maxY + 12 }

    /// A panel you open in Zigzag (site controls, a menu, Downloads) takes the place of an extension's popup, which
    /// would otherwise stay open beside it. Notes and toasts leave it be.
    var replacesExtensionPopup: Bool { false }

    func present(always: Bool = false, arrival: Arrival = .pop) {
        if replacesExtensionPopup, #available(macOS 15.4, *) { ExtensionHost.shared.closeActionPopup() }
        layoutSubtreeIfNeeded()
        recede(true)
        // Shown again while it was leaving: everything the exit left behind goes, so it never stays shrunk or
        // off-screen. The shrink fills forwards, so it has to be taken off by hand.
        layer?.removeAnimation(forKey: "dismiss")
        layer?.removeAnimation(forKey: "dismiss.shrink")
        Tokens.Motion.withoutAnimation { layer?.opacity = 1; layer?.transform = CATransform3DIdentity }
        alphaValue = 1
        // A dismiss a moment ago left the layer at 0 (alphaValue alone doesn't reset it when it's already 1), and its
        // completion would then take the panel away: shown again, it's fully back.
        layer?.opacity = 1
        dismissing = false
        // Opened from the keyboard it's simply there: something you summon with a key, often many times a day, should
        // never make you wait for it (https://emilkowal.ski/ui/you-dont-need-animations). Opened with the mouse, or by
        // something happening (`always`: a download landing, a prompt), it arrives with a short movement.
        let instant = arrival == .instant || (Tokens.Motion.isFromKey && !always)
        guard let layer, !instant else { return }
        if slidesFromTop, !Tokens.Motion.reduceMotion {
            let drop = CABasicAnimation(keyPath: "transform")
            drop.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -offstage, 0))
            drop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            drop.duration = Tokens.Motion.zoom
            drop.timingFunction = Tokens.Motion.easeOut
            drop.fillMode = .backwards
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Tokens.Motion.menuOut
            layer.add(drop, forKey: "present.grow")
            layer.add(fade, forKey: "present")
            return
        }
        if (arrival == .fade || arrival == .pop || arrival == .burst), !Tokens.Motion.reduceMotion {
            // Grows out of what opened it, from a little smaller (never from nothing), eased out in under 200ms. A
            // panel a download just landed in starts a touch smaller, so you see it come from the button.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Tokens.Motion.highlightGlide
            fade.timingFunction = Tokens.Motion.easeOut
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: scaled(arrival == .burst ? 0.94 : 0.97))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.duration = Tokens.Motion.menuIn
            grow.timingFunction = Tokens.Motion.easeOut
            layer.add(fade, forKey: "present")
            layer.add(grow, forKey: "present.grow")
            return
        }
        // With Reduce Motion on, panels only fade in; nothing moves.
        if arrival == .fade || arrival == .pop || arrival == .burst || Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Tokens.Motion.quick
            fade.timingFunction = Tokens.Motion.easeOut
            layer.add(fade, forKey: "present")
            return
        }
        let curve = Tokens.Motion.easeOut
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Tokens.Motion.highlightGlide
        if arrival == .zoom {
            // Grows a touch from its own middle, as Spotlight does: layers scale from their corner, so it's
            // shifted by half the shrink to stay centered.
            let k: CGFloat = 0.96, size = bounds.size
            let small = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                            CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0))
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: small)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let group = CAAnimationGroup()
            group.animations = [fade, grow]
            group.duration = Tokens.Motion.standard
            group.timingFunction = curve
            layer.add(group, forKey: "present")
            return
        }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = isFlippedInSuperview ? -4 : 4
        drop.toValue = 0
        drop.duration = Tokens.Motion.standard
        let group = CAAnimationGroup()
        group.animations = [fade, drop]
        group.duration = Tokens.Motion.standard
        group.timingFunction = curve
        layer.add(group, forKey: "present")
    }

    private var isFlippedInSuperview: Bool { superview?.isFlipped ?? true }

    private(set) var dismissing = false

    /// The one way a panel leaves: a quick fade as it eases a touch smaller, back toward where it came from.
    func dismiss(always: Bool = false, instantly: Bool = false, completion: (() -> Void)? = nil) {
        // Esc or a shortcut: gone at once, for the same reason it arrives at once.
        let instantly = instantly || (Tokens.Motion.isFromKey && !always)
        guard let layer, !instantly else { recede(false); removeFromSuperview(); completion?(); return }
        layer.removeAnimation(forKey: "present")
        layer.removeAnimation(forKey: "present.grow")
        dismissing = true
        recede(false)
        if !Tokens.Motion.reduceMotion {
            // Back the way it came: up past the top edge for a top-edge panel, a touch smaller toward its origin else.
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: slidesFromTop ? CATransform3DMakeTranslation(0, -offstage, 0) : scaled(0.98))
            shrink.duration = slidesFromTop ? 0.2 : 0.14
            shrink.timingFunction = Tokens.Motion.easeOut
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "dismiss.shrink")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Shown again while fading (a repeat toast): it stays.
            guard let self, self.layer?.opacity == 0 else { completion?(); return }
            self.removeFromSuperview()
            self.layer?.removeAnimation(forKey: "dismiss.shrink")
            self.layer?.opacity = 1
            completion?()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = slidesFromTop ? 0.2 : 0.12
        fade.timingFunction = Tokens.Motion.easeOut
        layer.add(fade, forKey: "dismiss")
        layer.opacity = 0
        CATransaction.commit()
    }
}

/// A brief confirmation pill at the top of the page ("Link Copied", "90%"). Shown at once, gone in a moment;
/// pressing the same shortcut again updates it in place instead of stacking another.
final class ToastView: FloatingPanelView {
    let icon = NSImageView()
    let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    let actionButton = PillButton(style: .plain)
    /// Puts an offer away before it goes on its own ("This page is in French"), as the other offers at the top of
    /// the page are put away.
    let closeButton = IconButton(symbol: "xmark", size: .compact, toolTip: String(localized: "Not Now", comment: "Tooltip of the close button on a toast that offers something, like translating the page."))
    /// Something under way ("Writing report…"): the ribbon turns where the icon goes.
    let spinner = Spinner()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = Tokens.Color.icon
        addSubview(icon)
        addSubview(spinner)
        addSubview(label)
        addSubview(actionButton)
        addSubview(closeButton)
        actionButton.isHidden = true
        closeButton.isHidden = true
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height = Tokens.Metric.toastHeight

    var fittingWidth: CGFloat {
        (icon.image == nil ? Tokens.Space.x4 : Tokens.Space.x3 + Tokens.Metric.favicon + Tokens.Space.x2) + label.inkWidth + trailingWidth
    }

    /// The right end: padding, or the action and the close button, the last one inset as evenly as it sits.
    private var trailingWidth: CGFloat {
        guard !actionButton.isHidden || !closeButton.isHidden else { return Tokens.Space.x4 }
        var width = actionButton.isHidden ? 0 : Tokens.Space.x3 + actionButton.fittingWidth
        if !closeButton.isHidden { width += (actionButton.isHidden ? Tokens.Space.x3 : Tokens.Space.x1) + closeButton.frame.width }
        return width + (Self.height - (closeButton.isHidden ? Tokens.Metric.toastButtonHeight : closeButton.frame.height)) / 2
    }

    /// The space around the text: the icon on the left, the action (or padding) on the right.
    private var chromeWidth: CGFloat { fittingWidth - label.inkWidth }

    /// Fits `maxWidth`: one line when it can, two wrapped lines when it can't, never past the page.
    func size(maxWidth: CGFloat) -> NSSize {
        let width = min(ceil(fittingWidth), maxWidth)
        let textWidth = width - chromeWidth
        let wraps = label.inkWidth > textWidth + 0.5
        label.usesSingleLineMode = !wraps
        label.maximumNumberOfLines = wraps ? 2 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.cell?.wraps = wraps
        label.cell?.truncatesLastVisibleLine = true
        let textHeight = wraps ? ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth + Label.inset * 2, height: 200)).height ?? label.lineHeight * 2) : label.lineHeight
        radius = wraps ? Tokens.Radius.panel : Self.height / 2
        return NSSize(width: width, height: max(Self.height, textHeight + Tokens.Space.x4))
    }

    private func layoutContent() {
        var x = icon.image == nil ? Tokens.Space.x4 : Tokens.Space.x3
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: (bounds.height - Tokens.Metric.favicon) / 2, width: Tokens.Metric.favicon, height: Tokens.Metric.favicon)
            spinner.frame = icon.frame
            x = icon.frame.maxX + Tokens.Space.x2
        }
        let actionWidth = actionButton.isHidden ? 0 : actionButton.fittingWidth
        var right = bounds.width
        if !closeButton.isHidden {
            let side = closeButton.frame.width
            closeButton.frame.origin = NSPoint(x: bounds.width - (Self.height - side) / 2 - side, y: (bounds.height - side) / 2)
            right = closeButton.frame.minX - Tokens.Space.x1
        }
        if !actionButton.isHidden {
            // Inset evenly from the toast's edge, top, bottom and right alike, so the pill runs with the capsule. The
            // right inset is a one-line toast's, the room `fittingWidth` keeps, so wrapped text never runs under it.
            let h = Tokens.Metric.toastButtonHeight
            let end = closeButton.isHidden ? bounds.width - (Self.height - h) / 2 : right
            actionButton.frame = NSRect(x: end - actionWidth, y: (bounds.height - h) / 2, width: actionWidth, height: h)
        }
        let textWidth = bounds.width - chromeWidth
        let h = label.usesSingleLineMode ? label.lineHeight : bounds.height - Tokens.Space.x4
        // The text field draws its text Label.inset in from its edges: set it that much wider, so the ink sits
        // exactly where the padding ends, the same both ends.
        label.frame = NSRect(x: x - Label.inset, y: (bounds.height - h) / 2, width: textWidth + Label.inset * 2, height: h)
    }
}

enum Toast {
    /// Each window's toast and its timer, so a toast in one window never cancels another window's.
    private final class Showing {
        weak var toast: ToastView?
        var hideWork: DispatchWorkItem?
    }
    private static var showing: [ObjectIdentifier: Showing] = [:]

    private static func state(for host: NSView) -> Showing {
        showing = showing.filter { $0.value.toast?.superview != nil }
        if let state = showing[ObjectIdentifier(host)] { return state }
        let state = Showing()
        showing[ObjectIdentifier(host)] = state
        return state
    }

    /// Takes down the toast showing in this window, if any.
    static func hide(in controller: BrowserWindowController) {
        let state = state(for: controller.root.overlay)
        guard let toast = state.toast, toast.superview === controller.root.overlay else { return }
        state.hideWork?.cancel()
        toast.dismiss(always: true)
        state.toast = nil
    }

    /// `closes` adds a close button, for an offer you may want gone before it goes on its own.
    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, closes: Bool = false, in controller: BrowserWindowController) {
        show(text, symbol: symbol, action: action, duration: duration, closes: closes, over: controller.root.overlay, area: area(in: controller))
    }

    /// Over the page, or with the desk open, over the desk, clear of its search field.
    private static func area(in controller: BrowserWindowController) -> NSRect {
        controller.desk.toastArea ?? controller.root.cardFrame
    }

    /// Something that takes a moment: the spinner and what's happening, up until the next toast or `hide` replaces it.
    static func working(_ text: String, in controller: BrowserWindowController) {
        show(text, duration: .greatestFiniteMagnitude, over: controller.root.overlay, area: area(in: controller), busy: true)
    }

    /// Top center of the page: where your eyes already are, clear of the content you're reading.
    private static func place(_ toast: ToastView, in area: NSRect) {
        let size = toast.size(maxWidth: max(160, area.width - Tokens.Space.x12))
        toast.frame = NSRect(x: round(area.midX - size.width / 2), y: area.minY + Tokens.Space.x3, width: size.width, height: size.height)
        toast.needsLayout = true
    }

    /// Keeps the window's toast over the middle of the page when the page moves under it: the sidebar shown or
    /// hidden, full screen, a resize. Riding a sidebar slide (`slide` is its duration) it moves with the page, on the
    /// same curve.
    static func reposition(in controller: BrowserWindowController, slide: TimeInterval? = nil) {
        let host = controller.root.overlay
        guard let toast = showing[ObjectIdentifier(host)]?.toast, toast.superview === host, !toast.dismissing else { return }
        let old = toast.frame
        place(toast, in: area(in: controller))
        let dx = old.minX - toast.frame.minX, dy = old.minY - toast.frame.minY
        // Dragging the window's edge, it simply stays with the page; gliding there would trail behind.
        guard abs(dx) > 0.5 || abs(dy) > 0.5, !Tokens.Motion.reduceMotion, controller.window?.inLiveResize != true,
              let layer = toast.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.duration = slide ?? 0.24
        move.timingFunction = slide == nil ? Tokens.Motion.easeInOut : Tokens.Motion.slide.timing
        move.fillMode = .backwards
        layer.add(move, forKey: "follow")
    }

    /// Shows a toast at the top center of `area` in any flipped host view (the Passwords window uses it too).
    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, closes: Bool = false, over host: NSView, area: NSRect, busy: Bool = false) {
        let state = state(for: host)
        let toast: ToastView
        let isNew: Bool
        if let existing = state.toast, existing.superview === host {
            toast = existing
            isNew = false
            // Something opened over it since (the desk): it comes back on top.
            if host.subviews.last !== existing { host.addSubview(existing, positioned: .above, relativeTo: nil) }
        } else {
            toast = ToastView()
            isNew = true
        }
        toast.label.stringValue = text
        Announcement.post(text, priority: action == nil ? .medium : .high)
        // Busy: an empty picture keeps the icon's place for the spinner.
        toast.icon.image = busy ? NSImage(size: NSSize(width: Tokens.Metric.favicon, height: Tokens.Metric.favicon)) : symbol.map { Tokens.Symbol.image($0) }
        busy ? toast.spinner.startAnimation(nil) : toast.spinner.stopAnimation(nil)
        toast.actionButton.isHidden = action == nil
        if let action {
            toast.actionButton.title = action.title
            toast.actionButton.onClick = { [weak toast] _ in
                action.run()
                toast?.dismiss(always: true)
            }
        }
        toast.closeButton.isHidden = !closes
        toast.closeButton.onClick = { [weak toast] _ in
            state.hideWork?.cancel()
            toast?.dismiss(always: true)
            state.toast = nil
        }
        place(toast, in: area)
        if isNew {
            host.addSubview(toast)
            // Springs down out of the top of the page, as a notice does, and eases back up when it goes.
            toast.slidesFromTop = true
            toast.present(always: true, arrival: .pop)
        } else if toast.dismissing {
            // Caught on its way out: it comes back rather than finishing the exit and vanishing.
            toast.present(always: true, arrival: .instant)
        }
        // A repeat that's still up (zoom 90% → 80%) only changes the number: it comes from a key, so nothing moves.
        state.toast = toast
        state.hideWork?.cancel()
        // Toasts with an action wait for the pointer to leave before going, however long it stays, so Undo never
        // slips away from under it.
        @MainActor func hideWhenClear(_ toast: ToastView?) {
            // Shown again since (a repeat toast): that showing decides when it goes.
            guard let toast, toast.superview != nil, state.hideWork == nil else { return }
            if action != nil, toast.bounds.contains(toast.convert(toast.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak toast] in hideWhenClear(toast) }
                return
            }
            toast.dismiss(always: true)
        }
        // A busy toast stays until what replaces it.
        guard duration < .greatestFiniteMagnitude else { return }
        let work = DispatchWorkItem { [weak toast] in
            MainActor.assumeIsolated {
                state.hideWork = nil
                hideWhenClear(toast)
            }
        }
        state.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
