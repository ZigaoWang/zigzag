import AppKit

/// One result row: icon, title, quiet detail, and an action hint when selected.
final class CommandRowView: InteractiveView {
    private let icon = FaviconView()
    private let symbolView = NSImageView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let action = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let returnKey = NSImageView()
    /// On a tab that's already open: the other choice, a fresh copy in a new tab with ⌥↩.
    private let altAction = Label("New Tab", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    private let altKey = Label("⌥↩", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    private var offersNewTab = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        symbolView.imageScaling = .scaleNone
        symbolView.contentTintColor = Tokens.Color.icon
        returnKey.image = Tokens.Symbol.image("return", size: Tokens.TypeSize.small)
        returnKey.contentTintColor = Tokens.Color.textTertiary
        returnKey.imageScaling = .scaleNone
        [icon, symbolView, title, detail, action, returnKey, altAction, altKey].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ result: CommandResult) {
        title.stringValue = result.title
        detail.stringValue = result.detail
        action.stringValue = result.actionLabel
        if case .switchTo = result.kind { offersNewTab = true } else { offersNewTab = false }
        if let image = result.icon {
            icon.image = image
            icon.isHidden = false
            symbolView.isHidden = true
        } else {
            icon.isHidden = true
            symbolView.isHidden = false
            symbolView.image = Tokens.Symbol.image(result.symbol ?? "globe")
        }
        setAccessibilityRole(result.isActionable ? .button : .staticText)
        setAccessibilityLabel(result.detail.isEmpty ? result.title : "\(result.title), \(result.detail)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let iconSize = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        symbolView.frame = icon.frame
        let showAction = isSelected
        action.isHidden = !showAction
        returnKey.isHidden = !showAction
        var right = bounds.width - pad
        if showAction {
            returnKey.frame = NSRect(x: right - Tokens.Space.x3, y: 0, width: Tokens.Space.x3, height: bounds.height)
            let w = action.textWidth
            let h = ceil(action.intrinsicContentSize.height)
            action.frame = NSRect(x: returnKey.frame.minX - Tokens.Space.x1 - w, y: (bounds.height - h) / 2, width: w, height: h)
            right = action.frame.minX - Tokens.Space.x3
        }
        altAction.isHidden = !(showAction && offersNewTab)
        altKey.isHidden = altAction.isHidden
        if !altAction.isHidden {
            let kw = altKey.textWidth, aw = altAction.textWidth
            let h = ceil(altAction.intrinsicContentSize.height)
            altKey.frame = NSRect(x: right - kw, y: (bounds.height - h) / 2, width: kw, height: h)
            altAction.frame = NSRect(x: altKey.frame.minX - Tokens.Space.x1 - aw, y: (bounds.height - h) / 2, width: aw, height: h)
            right = altAction.frame.minX - Tokens.Space.x4
        }
        let x = icon.frame.maxX + Tokens.Space.x3
        let h = ceil(title.intrinsicContentSize.height)
        let y = (bounds.height - h) / 2
        let available = right - x
        let titleWidth = min(title.textWidth, detail.stringValue.isEmpty ? available : available * 0.62)
        title.frame = NSRect(x: x, y: y, width: max(0, titleWidth), height: h)
        let detailX = title.frame.maxX + Tokens.Space.x2
        detail.frame = NSRect(x: detailX, y: y, width: max(0, right - detailX), height: h)
    }

    override func stateDidChange(animated: Bool) {
        // The chosen row in the space's accent, like the rest of the window.
        let accent = Brand.Theme.for(self).accent
        let fill: NSColor? = isPressed ? accent.withAlphaComponent(0.24) : isSelected ? accent.withAlphaComponent(0.16) : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        needsLayout = true
    }
}

/// The floating command bar: one field for addresses, searches, tabs, bookmarks and history.
final class CommandBarController: NSObject, NSTextFieldDelegate {
    enum Mode { case newTab, editCurrent, history }

    private weak var controller: BrowserWindowController?
    /// Catches clicks outside the bar; it doesn't dim the page.
    private let scrim = ScrimView(dims: false)
    private let panel = FloatingPanelView()
    /// The bar itself, for pointing at it (the Getting started guide).
    var panelView: NSView { panel }
    private let field = PlainTextField(font: Tokens.Font.large(), placeholder: "Search or enter address")
    private let fieldIcon = NSImageView()
    private let divider = ColorView(color: Tokens.Color.separator)
    private var rows: [CommandRowView] = []
    private var results: [CommandResult] = []
    private var selectedIndex = 0
    private(set) var mode: Mode = .newTab
    private var suggestions: [String] = []
    private let fetcher = SuggestionFetcher()
    /// Text the user actually typed; the field may also hold an inline completion after it.
    private var typed = ""
    private var completionURL: URL?
    private var suppressCompletion = false
    private(set) var isVisible = false
    private var mouseAtOpen = NSPoint.zero
    /// Searching one site: its chip sits in front of the field, and Return searches there.
    private var scope: SiteSearch?
    private var shrinkWork: DispatchWorkItem?
    /// What you'd typed before Tab took you into a site, so Esc can give it back.
    private var typedBeforeScope = ""
    private let chip = ColorView(color: .clear)
    private let chipLabel = Label("", font: Tokens.Font.body(.semibold), color: .white)
    /// "Search YouTube  Tab", at the right of the field, when what you've typed names a site.
    private let hint = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let hintKey = KeyHint("Tab")
    private var hinted: SiteSearch?
    /// For the guide: searching inside a site, or about to be (its name typed, Tab not yet pressed).
    var isSearchingSite: Bool { scope != nil }
    var isOfferingSiteSearch: Bool { hinted != nil }

    init(window: BrowserWindowController) {
        controller = window
        super.init()
        field.delegate = self
        field.textInset = 2
        field.centersText = true
        fieldIcon.image = Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.large)
        fieldIcon.contentTintColor = Tokens.Color.textTertiary
        fieldIcon.imageScaling = .scaleNone
        panel.addSubview(fieldIcon)
        panel.addSubview(field)
        panel.addSubview(divider)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        chip.layer?.cornerCurve = .continuous
        chip.addSubview(chipLabel)
        chip.isHidden = true
        hint.alignment = .right
        hint.isHidden = true
        hintKey.isHidden = true
        [chip, hint, hintKey].forEach { panel.addSubview($0) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        scrim.onClick = { [weak self] in self?.dismiss() }
    }

    // MARK: Showing

    /// The bar takes on the space it opens in: its surface carries the space's color, and the search icon,
    /// cursor and chosen row use its accent.
    private func applySpaceTheme() {
        guard let controller else { return }
        let space = controller.tabManager.currentSpace
        let accent = Brand.Theme.of(controller.tabManager.isPrivate ? nil : space).accent
        panel.surfaceTint = controller.tabManager.isPrivate ? SpaceColor.graphite.background : space.background
        fieldIcon.contentTintColor = accent
        divider.color = accent.withAlphaComponent(0.18)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = accent
            editor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.25)]
        }
        rows.forEach { $0.stateDidChange(animated: false) }
        refreshAnchorLook()
    }

    /// Editing the address with nothing to suggest is the address bar itself: its corners, no shadow, and a soft
    /// accent outline to say it's being edited. With suggestions it lifts into a proper panel.
    private func refreshAnchorLook() {
        guard let controller else { return }
        let inPlace = isAnchored && results.isEmpty
        let accent = Brand.Theme.of(controller.tabManager.isPrivate ? nil : controller.tabManager.currentSpace).accent
        panel.isElevated = !inPlace
        panel.edgeColor = inPlace ? accent.withAlphaComponent(0.5) : nil
        panel.radius = inPlace ? controller.sidebar.address.layer?.cornerRadius ?? Tokens.Radius.panel : Tokens.Radius.panel
    }

    func show(mode: Mode) {
        guard let controller else { return }
        // A fresh bar, or a different one (⌘L over ⌘T): no leftover site scope, and no hint from the last thing typed.
        if !isVisible || mode != self.mode {
            typed = ""
            field.stringValue = ""
            setScope(nil)
        }
        self.mode = mode
        mouseAtOpen = NSEvent.mouseLocation
        let card = controller.root.cardFrame
        let opening = !isVisible
        if !isVisible {
            // One floating thing at a time.
            SitePanel.closeCurrent()
            DownloadsPanel.closeCurrent()
            SpaceEditorPanel.current?.close()
            controller.previews.hide()
            controller.linkStatus.show(nil, in: controller.root.cardFrame)
            isVisible = true
            scrim.frame = isAnchored ? controller.root.bounds : card
            controller.root.overlay.addSubview(scrim)
            controller.root.overlay.addSubview(panel)
            scrim.show()
        }
        applySpaceTheme()
        let font = isAnchored ? Tokens.Font.body() : Tokens.Font.large()
        field.font = font
        field.placeholderAttributedString = NSAttributedString(string: mode == .history ? "Search history" : "Search or enter address",
                                                               attributes: [.font: font, .foregroundColor: Tokens.Color.textTertiary])
        if mode == .editCurrent, let url = controller.tabManager.selectedTab?.url {
            field.stringValue = url.absoluteString
        } else {
            field.stringValue = ""
        }
        typed = field.stringValue
        completionURL = nil
        suggestions = []
        refreshResults(animated: false)
        panel.frame = panelFrame()
        // Attached to the address, it's simply there; over the page it arrives with the usual drop.
        // Arrives once; asked again while open (⌘T twice), it simply stays.
        // ⌘T is the thing you do most: the bar is simply there, no animation to wait through.
        if opening { panel.present(arrival: .instant) }
        controller.window?.makeFirstResponder(field)
        applySpaceTheme()
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss(restoringFocus: Bool = true) {
        guard isVisible, let controller else { return }
        isVisible = false
        fetcher.cancel()
        scrim.hide()
        panel.dismiss(instantly: isAnchored)
        if restoringFocus, let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }

    func reposition() {
        guard isVisible, let controller else { return }
        scrim.frame = isAnchored ? controller.root.bounds : controller.root.cardFrame
        // The window got shorter than the list: drop the rows that no longer fit.
        if results.count > rowsThatFit { refreshResults(animated: false) }
        panel.frame = panelFrame()
    }

    // MARK: Layout

    private var listHeight: CGFloat {
        guard !results.isEmpty else { return 0 }
        return CGFloat(results.count) * Tokens.Metric.commandBarRowHeight + Tokens.Space.x2 * 2
    }

    /// Editing the address you're on opens right where it is: over the address field in the sidebar, reaching
    /// into the page, like a dropdown. New tabs and history keep the bar centered over the page.
    private var isAnchored: Bool {
        guard let controller else { return false }
        return mode == .editCurrent && controller.root.sidebarVisible && !controller.root.isSidebarFloatingVisible
    }

    private func panelFrame() -> NSRect {
        guard let controller else { return .zero }
        if isAnchored {
            let address = controller.sidebar.address.convert(controller.sidebar.address.bounds, to: controller.root.overlay)
            // Nothing to suggest yet (the address as it is): it is the address bar, exactly. It reaches into the
            // page only once there are suggestions to show, growing from that same top-left corner.
            let wide = min(max(Tokens.Metric.commandBarWidth * 0.85, address.width), controller.root.bounds.width - address.minX - Tokens.Space.x4)
            if results.isEmpty { return address }
            return NSRect(x: address.minX, y: address.minY, width: wide, height: fieldHeight + listHeight)
        }
        let card = controller.root.cardFrame
        // Room to breathe on both sides of the page, however narrow the window.
        let margin = Tokens.Space.x8
        let width = min(Tokens.Metric.commandBarWidth, card.width - margin * 2)
        let height = Tokens.Metric.commandBarFieldHeight + listHeight
        let top = panelTop(in: card)
        // Centered on the whole window, not just the page beside the sidebar, but never tight against either edge.
        let x = min(max(card.minX + margin, floor(controller.root.bounds.midX - width / 2)), card.maxX - width - margin)
        return NSRect(x: x, y: top, width: width, height: height)
    }

    private func panelTop(in card: NSRect) -> CGFloat { card.minY + max(Tokens.Space.x12, floor(card.height * 0.18)) }

    /// How many rows fit under the field before the bar would run off the bottom of the window.
    private var rowsThatFit: Int {
        guard let controller else { return Tokens.Metric.commandBarMaxRows }
        let top: CGFloat, bottom: CGFloat
        if isAnchored {
            top = controller.sidebar.address.convert(controller.sidebar.address.bounds, to: controller.root.overlay).minY
            bottom = controller.root.bounds.maxY
        } else {
            let card = controller.root.cardFrame
            top = panelTop(in: card)
            bottom = card.maxY
        }
        let room = bottom - Tokens.Space.x4 - top - fieldHeight - Tokens.Space.x2 * 2
        return max(1, min(Tokens.Metric.commandBarMaxRows, Int(room / Tokens.Metric.commandBarRowHeight)))
    }

    /// Anchored to the address it's a little smaller, close to the address bar's own size.
    /// Anchored, the field is the address bar itself, being edited: its height, its text, its place.
    private var fieldHeight: CGFloat { isAnchored ? Tokens.Metric.addressHeight : Tokens.Metric.commandBarFieldHeight }

    private func layoutPanel() {
        let b = panel.bounds
        let fieldHeight = self.fieldHeight
        let iconSize = Tokens.Space.x6
        fieldIcon.frame = NSRect(x: Tokens.Space.x4, y: (fieldHeight - iconSize) / 2, width: iconSize, height: iconSize)
        // Anchored there's no icon: the text starts exactly where the address's own text was.
        fieldIcon.isHidden = isAnchored
        let textHeight = ceil(field.intrinsicContentSize.height)
        var fieldX = isAnchored ? Tokens.Space.x3 - 2 : fieldIcon.frame.maxX + Tokens.Space.x2
        if scope != nil {
            let cw = chipLabel.textWidth + Tokens.Space.x5
            let ch: CGFloat = 26
            chip.frame = NSRect(x: fieldX, y: (fieldHeight - ch) / 2, width: cw, height: ch)
            chipLabel.frame = NSRect(x: 0, y: (ch - chipLabel.lineHeight) / 2, width: cw, height: chipLabel.lineHeight)
            chipLabel.alignment = .center
            fieldX = chip.frame.maxX + Tokens.Space.x2
        }
        var fieldRight = b.width - (isAnchored ? Tokens.Space.x3 : Tokens.Space.x4)
        if !hint.isHidden {
            let kw = hintKey.width
            hintKey.frame = NSRect(x: fieldRight - kw, y: (fieldHeight - KeyHint.height) / 2, width: kw, height: KeyHint.height)
            let hw = hint.textWidth + 4
            hint.frame = NSRect(x: hintKey.frame.minX - Tokens.Space.x2 - hw, y: (fieldHeight - hint.lineHeight) / 2, width: hw, height: hint.lineHeight)
            fieldRight = hint.frame.minX - Tokens.Space.x3
        }
        // A little taller and wider than the text, which the field keeps inside, so selections draw whole.
        let inset = field.textInset, boxHeight = textHeight + inset * 4
        field.frame = NSRect(x: fieldX - inset, y: (fieldHeight - boxHeight) / 2, width: max(40, fieldRight - fieldX) + inset * 2, height: boxHeight)
        divider.frame = NSRect(x: 0, y: fieldHeight - Tokens.Metric.hairline, width: b.width, height: Tokens.Metric.hairline)
        divider.isHidden = results.isEmpty
        var y = fieldHeight + Tokens.Space.x2
        for row in rows {
            row.frame = NSRect(x: Tokens.Space.x2, y: y, width: b.width - Tokens.Space.x4, height: Tokens.Metric.commandBarRowHeight)
            y += Tokens.Metric.commandBarRowHeight
        }
    }

    // MARK: Results

    private func refreshResults(animated: Bool) {
        guard let controller else { return }
        let editing = mode == .editCurrent && typed == controller.tabManager.selectedTab?.url?.absoluteString
        results = CommandRanker.results(for: editing ? "" : typed, manager: controller.tabManager, suggestions: suggestions,
                                        editingCurrent: mode == .editCurrent, historyOnly: mode == .history)
        if editing { results = [] }
        if let scope {
            // Searching one site: the query there first, then suggestions, all searching that site.
            let q = typed.trimmingCharacters(in: .whitespaces)
            let queries = (q.isEmpty ? [] : [q]) + suggestions.filter { $0.lowercased() != q.lowercased() }.prefix(5)
            results = queries.compactMap { query in
                scope.url(for: query).map { CommandResult(kind: .searchOn($0), title: query, detail: "Search \(scope.name)",
                                                         icon: FaviconStore.shared.cachedIcon(for: scope.home), symbol: "magnifyingglass") }
            }
            // Nothing typed yet: the site itself and where you've been on it, so the bar doesn't empty out at Tab.
            if q.isEmpty {
                let domain = (scope.home.host() ?? "").split(separator: ".").suffix(2).joined(separator: ".")
                var seen = Set([TabManager.normalize(scope.home)])
                results = [CommandResult(kind: .open(scope.home), title: scope.name, detail: CommandRanker.displayURL(scope.home),
                                         icon: FaviconStore.shared.cachedIcon(for: scope.home), symbol: "globe")]
                for entry in HistoryStore.shared.search(domain, limit: 12) where results.count < 6 {
                    let key = TabManager.normalize(entry.url)
                    guard entry.url.host()?.hasSuffix(domain) == true, entry.url.path.count > 1, !SearchFolding.isSearchResultsPage(entry.url),
                          seen.insert(key).inserted else { continue }
                    results.append(CommandResult(kind: .history(entry.url), title: entry.title.isEmpty ? CommandRanker.displayURL(entry.url) : entry.title,
                                                 detail: CommandRanker.displayURL(entry.url), icon: FaviconStore.shared.cachedIcon(for: entry.url)))
                }
            }
        }
        // An inline completion becomes the first result.
        if let completionURL, !typed.isEmpty {
            var top = CommandResult(kind: .open(completionURL), title: CommandRanker.displayURL(completionURL), detail: "",
                                    icon: FaviconStore.shared.cachedIcon(for: completionURL), symbol: "globe")
            // Already open? Then the top hit is switching to it, not a second copy.
            if let existing = controller.tabManager.existingTab(for: completionURL) {
                top = CommandResult(kind: .switchTo(existing.id), title: existing.displayTitle,
                                    detail: CommandRanker.displayURL(completionURL), icon: existing.favicon)
            }
            results.removeAll { $0.kind == .open(completionURL) || $0.kind == top.kind || ($0.title == top.title) }
            results.insert(top, at: 0)
        }
        // A short window shows fewer rows rather than letting the list run off its bottom edge.
        results = Array(results.prefix(rowsThatFit))
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
        for (row, result) in zip(rows, results) { row.configure(result) }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        if !results.isEmpty { selectedIndex = 0 }
        updateSelection()
        refreshAnchorLook()
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
    private func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        select((selectedIndex + delta + results.count) % results.count)
    }

    private func updateSelection() {
        // A note is never highlighted: there's nothing for Return to do on it.
        for (i, row) in rows.enumerated() { row.isSelected = i == selectedIndex && results[i].isActionable }
    }

    // MARK: Searching one site

    private func refreshHint() {
        hinted = scope == nil && mode != .history ? SiteSearch.match(typed) : nil
        hint.stringValue = hinted.map { "Search \($0.name)" } ?? ""
        hint.isHidden = hinted == nil
        hintKey.isHidden = hinted == nil
        panel.needsLayout = true
    }

    #if DEBUG
    func debugTab() { if scope == nil, let site = hinted { setScope(site) } }
    #endif

    private func setScope(_ site: SiteSearch?) {
        let entering = site != nil && scope == nil, leaving = site == nil && scope != nil
        let before = field.frame
        scope = site
        if leaving { fadeOutChip() } else { chip.isHidden = site == nil }
        chip.color = site?.color ?? .clear
        // Ink that reads on the site's own colour: dark on light brands (IMDb, Amazon), white on the rest; a light
        // edge so near-black brands (X, MDN) still show on a dark panel.
        if let fill = site?.color.usingColorSpace(.sRGB) {
            let luminance = 0.2126 * fill.redComponent + 0.7152 * fill.greenComponent + 0.0722 * fill.blueComponent
            chipLabel.textColor = luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
            chip.layer?.borderWidth = luminance < 0.15 ? 1 : 0
            chip.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        }
        chipLabel.stringValue = site?.name ?? ""
        completionURL = nil
        if site != nil {
            if entering { typedBeforeScope = typed }
            field.stringValue = ""
            typed = ""
            suggestions = []
        } else if leaving {
            // Back to exactly what you'd typed, cursor at its end: Tab by mistake costs nothing.
            field.stringValue = typedBeforeScope
            typed = typedBeforeScope
            suppressCompletion = true
            (field.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: (typedBeforeScope as NSString).length, length: 0)
        }
        let font = field.font ?? Tokens.Font.large()
        field.placeholderAttributedString = NSAttributedString(string: site.map { "Search \($0.name)" } ?? (mode == .history ? "Search history" : "Search or enter address"),
                                                               attributes: [.font: font, .foregroundColor: Tokens.Color.textTertiary])
        if let site { FaviconStore.shared.prefetch(for: site.home) }
        refreshHint()
        refreshResults(animated: true)
        if entering || leaving { animateScope(entering: entering, fieldFrom: before) }
    }

    /// Tab into a site: its chip pops in where your words were, and the field slides over to make room. Leaving
    /// slides it back. Nothing jumps.
    private func animateScope(entering: Bool, fieldFrom before: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        panel.layoutSubtreeIfNeeded()
        let after = field.frame
        if before != after, before != .zero {
            field.frame = before
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                field.animator().frame = after
            }
        }
        // The words you typed fade as the field empties, rather than vanishing.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        field.layer?.add(fade, forKey: "scope")
        guard entering, let layer = chip.layer else { return }
        // Grows from the chip's own middle: layers scale from their corner, so shift by half the shrink.
        let size = chip.bounds.size, k: CGFloat = 0.92
        let small = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                        CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0))
        let pop = CABasicAnimation(keyPath: "transform")
        pop.fromValue = NSValue(caTransform3D: small)
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = 0.2
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = 0.16
        layer.add(pop, forKey: "pop")
        layer.add(show, forKey: "show")
    }

    private func fadeOutChip() {
        guard let layer = chip.layer, !chip.isHidden else { chip.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.scope == nil else { return }
            self.chip.isHidden = true
            layer.opacity = 1
            self.panel.needsLayout = true
        }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = 0.14
        layer.add(out, forKey: "hide")
        layer.opacity = 0
        CATransaction.commit()
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field.currentEditor() else { return }
        let text = field.stringValue
        typed = text
        completionURL = nil
        // Inline completion: only when typing forward at the end, never after deleting. Looked up once per keystroke.
        if scope == nil, !suppressCompletion, let controller, mode != .history,
           let (completion, url) = CommandRanker.inlineCompletion(for: text, manager: controller.tabManager) {
            if editor.selectedRange.location == (text as NSString).length,
               completion.lowercased().hasPrefix(text.lowercased()), completion.count > text.count {
                let suffix = String(completion.dropFirst(text.count))
                field.stringValue = text + suffix
                editor.selectedRange = NSRange(location: (text as NSString).length, length: (suffix as NSString).length)
                completionURL = url
            } else if completion.lowercased() == text.lowercased() {
                completionURL = url
            }
        }
        suppressCompletion = false
        refreshHint()
        refreshResults(animated: true)
        // Searching history stays on this Mac: nothing you type there goes to the search engine.
        guard mode != .history else { fetcher.cancel(); return }
        fetcher.fetch(text) { [weak self] list in
            guard let self, self.isVisible, self.typed == text else { return }
            self.suggestions = list
            let selected = self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex] : nil
            self.refreshResults(animated: true)
            if let selected, let index = self.results.firstIndex(of: selected) { self.select(index) }
        }
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
        case #selector(NSResponder.cancelOperation(_:)) where scope != nil:
            setScope(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completionURL != nil, field.stringValue != typed {
                field.stringValue = typed
                completionURL = nil
                refreshResults(animated: true)
            } else {
                dismiss()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab on a site's name searches that site; otherwise it accepts the inline completion.
            if scope == nil, let site = hinted {
                setScope(site)
            } else if completionURL != nil {
                textView.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                typed = field.stringValue
            } else {
                step(1)
            }
            return true
        // Shift-Tab steps back up the list; focus stays in the field while the bar is open.
        case #selector(NSResponder.insertBacktab(_:)):
            step(-1)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where scope != nil && field.stringValue.isEmpty:
            setScope(nil)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Deleting removes the completion first, without re-completing.
            if textView.selectedRange.length > 0, completionURL != nil {
                suppressCompletion = true
            }
            suppressCompletion = true
            return false
        default:
            return false
        }
    }

    private func commit(modifiers: NSEvent.ModifierFlags) {
        if results.indices.contains(selectedIndex) {
            guard results[selectedIndex].isActionable else { return }
            activate(results[selectedIndex], modifiers: modifiers)
        } else if let url = CommandRanker.url(from: field.stringValue) {
            activate(CommandResult(kind: .open(url), title: "", detail: ""), modifiers: modifiers)
        } else if mode == .editCurrent, field.stringValue == controller?.tabManager.selectedTab?.url?.absoluteString {
            controller?.tabManager.selectedTab?.reload()
            dismiss()
        }
    }

    private func activate(_ result: CommandResult, modifiers: NSEvent.ModifierFlags) {
        guard let controller, result.isActionable else { return }
        let manager = controller.tabManager
        let inBackground = modifiers.contains(.command)
        // ⌥↩: always a new tab, even for a page that's open already (a second copy of it).
        let forceNew = modifiers.contains(.option)
        let inCurrent = mode == .editCurrent && manager.selectedTab != nil
        dismiss(restoringFocus: false)
        func open(_ url: URL, search: Bool = false) {
            if !inCurrent { Tutorial.complete("newTab") }
            if inCurrent {
                manager.selectedTab?.load(url)
                manager.selectedTab?.isSearchTab = search
            } else if !search, !inBackground, !forceNew, let existing = manager.existingTab(for: url) {
                manager.select(existing)
            } else {
                let tab = manager.newTab(url: url, select: !inBackground)
                tab.isSearchTab = search
            }
        }
        switch result.kind {
        case .open(let url), .history(let url):
            // Back from the archive: it's a tab again, so it leaves the archive.
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
        case .note:
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
        case "passwords": PasswordsWindowController.show()
        case "clear-cache":
            Task { @MainActor in
                await WebsiteData.clear(.cache)
                Toast.show("Cache cleared. Pages load fresh.", symbol: "arrow.clockwise", duration: 2, in: controller)
            }
        case "clear-cookies": controller.confirmClearCookies()
        case "feedback": Feedback.show(in: controller)
        case "history": HistoryPage.open(in: controller)
        default: break
        }
    }
}

#if DEBUG
extension CommandBarController {
    func debugEnter() { commit(modifiers: []) }

    func debugType(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
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

    func show() {
        alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.animator().alphaValue = 1 }
    }

    func hide() {
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: {
            if self.alphaValue == 0 { self.removeFromSuperview() }
        })
    }
}
