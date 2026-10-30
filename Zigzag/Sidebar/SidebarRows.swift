import AppKit

/// A row in the sidebar list. Tabs, bookmarks and "New Tab" all share one look.
class SidebarRowView: InteractiveView {
    let icon = FaviconView()
    let title = Label()
    /// Soft color from the site's own theme.
    var siteTint: NSColor? { didSet { stateDidChange(animated: false) } }
    /// 1 = just looked at, down to the faded floor for tabs left alone a long time.
    var freshness: CGFloat = 1 { didSet { if oldValue != freshness { applyFreshness() } } }
    /// While lifted for dragging, the row draws as selected-ish with a shadow.
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    /// Picked with ⌘ or ⇧ along with others, to drag or act on together.
    var isMarked = false { didSet { if oldValue != isMarked { stateDidChange(animated: true) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        addSubview(icon)
        addSubview(title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Space reserved at the trailing edge for accessory buttons.
    var trailingAccessoryWidth: CGFloat { 0 }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x2
        let iconSize = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let titleX = icon.frame.maxX + Tokens.Space.x2
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let trailing = trailingAccessoryWidth > 0 ? trailingAccessoryWidth + Tokens.Space.x1 : pad
        title.frame = NSRect(x: titleX, y: (bounds.height - titleHeight) / 2, width: max(0, bounds.width - titleX - trailing), height: titleHeight)
    }

    override func stateDidChange(animated: Bool) {
        let base: NSColor?
        if isSelected || isLifted {
            base = isHovered ? Tokens.Color.selectedHoverFill : Tokens.Color.selectedFill
        } else if isMarked {
            base = Brand.Theme.for(self).accent.withAlphaComponent(isHovered ? 0.26 : 0.2)
        } else if isPressed {
            base = Tokens.Color.pressedFill
        } else if isHovered {
            base = Tokens.Color.hoverFill
        } else {
            base = nil
        }
        var fill = base.map { cgColor($0) }
        // The site's color shows only on the tab you're on.
        if let siteTint, isSelected || isLifted {
            fill = cgColor(SidebarRowView.tinted(selectedFill: base ?? Tokens.Color.selectedFill, with: siteTint, appearance: effectiveAppearance))
        }
        layer?.set(backgroundColor: fill, animated: animated && !isHovered)
        let shadowed = isSelected || isLifted
        layer?.shadowOpacity = shadowed ? 1 : 0
        layer?.shadowColor = cgColor(isLifted ? Tokens.Color.panelShadow : Tokens.Color.selectedEdge)
        layer?.shadowRadius = isLifted ? Tokens.Space.x2 : 0.5
        layer?.shadowOffset = CGSize(width: 0, height: isLifted ? -Tokens.Space.x1 : -0.5)
        applyFreshness()
    }

    /// Selected rows take on a whisper of the site's color, the way the page itself would look.
    static func tinted(selectedFill: NSColor, with tint: NSColor, appearance: NSAppearance) -> NSColor {
        var result = selectedFill
        appearance.performAsCurrentDrawingAppearance {
            let fill = selectedFill.usingColorSpace(.sRGB) ?? selectedFill
            let site = tint.usingColorSpace(.sRGB) ?? tint
            let amount: CGFloat = appearance.isDark ? 0.16 : 0.12
            let blended = (fill.withAlphaComponent(1).blended(withFraction: amount, of: site) ?? fill)
            result = blended.withAlphaComponent(appearance.isDark ? max(fill.alphaComponent, 0.16) : fill.alphaComponent)
        }
        return result
    }

    private func applyFreshness() {
        let visible = isSelected || isHovered || isLifted || isMarked ? 1 : freshness
        icon.alphaValue = visible
        title.alphaValue = visible
    }
}

/// A tab (or a bookmark's live page).
final class TabRowView: SidebarRowView, NSTextFieldDelegate {
    private(set) var tab: Tab?
    private var token: SignalToken?
    let closeButton = IconButton(symbol: "xmark", size: Tokens.Space.x5, symbolSize: Tokens.TypeSize.small, toolTip: "Close Tab")
    let audioButton = IconButton(symbol: "speaker.wave.2.fill", size: Tokens.Space.x5, symbolSize: Tokens.TypeSize.small, toolTip: "Mute Tab")
    var onClose: (() -> Void)?
    /// Bookmarks keep their own title; only the icon and state follow the page.
    var fixedTitle: String? { didSet { refresh() } }
    var isBookmark = false
    /// Called with the new name when a rename is committed (empty: go back to the page's own title).
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    /// Double-click: the title becomes a field, the whole name selected. Return keeps it, Escape doesn't.
    func beginRename() {
        guard renameField == nil, let window else { return }
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: "Name")
        field.stringValue = title.stringValue
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        title.isHidden = true
        addSubview(field)
        renameField = field
        // The whole row is the name while you edit it: no close or audio button in the way.
        refreshAccessories()
        layoutRenameField()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        title.isHidden = false
        refreshAccessories()
        if commit { onRename?(name) }
        window?.makeFirstResponder(window?.contentView)
    }

    /// A pinned tab showing a different page from its pinned one: the close button takes it back instead.
    var isAway = false {
        didSet {
            guard oldValue != isAway else { return }
            closeButton.symbol = isAway ? "arrow.uturn.backward" : "xmark"
            awayMark.isHidden = !isAway
            refreshAccessories()
            needsLayout = true
        }
    }

    /// Always there while a pinned tab is away from its page: a short slanted stroke, the ribbon's own slant,
    /// between the icon and the title, so you can tell at a glance it isn't on its pinned page.
    private lazy var awayMark: CAShapeLayer = {
        let mark = CAShapeLayer()
        mark.lineWidth = 1.6
        mark.lineCap = .round
        mark.fillColor = nil
        mark.isHidden = true
        layer?.addSublayer(mark)
        return mark
    }()
    var isUnloaded = false { didSet { refreshTitleColor() } }
    /// The other half of a split: shown in the same row, to the right.
    private(set) var partner: Tab?
    /// A pinned split's other page, by its pinned name and icon: there whether or not its page is open.
    private var pinnedPartner: (title: String, icon: NSImage?, unloaded: Bool)?
    /// Two pages in one row: a split of tabs, or a pinned split.
    var isSplit: Bool { partner != nil || pinnedPartner != nil }
    /// Which half you're working in, when split (0 = left, 1 = right).
    var focusedHalf = 0 { didSet { refreshTitleColor() } }
    private var partnerToken: SignalToken?
    private let partnerIcon = FaviconView()
    private let partnerTitle = Label()
    private let divider = ColorView(color: Tokens.Color.separator)
    /// While another tab is dragged over this row's right half: where it would open.
    private let dropHalf = ColorView()
    /// 0 = would open on the left, 1 = on the right, nil = not a drop target.
    var splitDropSide: Int? {
        didSet {
            guard oldValue != splitDropSide else { return }
            layoutDropHalf()
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.dropHalf.animator().alphaValue = self.splitDropSide == nil ? 0 : 1 }
        }
    }

    private func layoutDropHalf() {
        let inset: CGFloat = 3
        let width = bounds.width / 2 - inset
        let x = splitDropSide == 0 ? inset : bounds.midX
        Tokens.Motion.withoutAnimation { dropHalf.frame = NSRect(x: x, y: inset, width: width, height: bounds.height - inset * 2) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Chosen on release, so pressing a row to drag it never switches the page first.
        clicksOnMouseDown = false
        closeButton.onClick = { [weak self] _ in self?.onClose?() }
        closeButton.isHidden = true
        audioButton.onClick = { [weak self] _ in
            guard let tab = self?.tab else { return }
            tab.setMuted(!tab.isMuted)
        }
        audioButton.isHidden = true
        dropHalf.wantsLayer = true
        dropHalf.layer?.cornerRadius = Tokens.Radius.row - 2
        dropHalf.layer?.cornerCurve = .continuous
        dropHalf.layer?.borderWidth = 1.5
        dropHalf.alphaValue = 0
        addSubview(dropHalf, positioned: .below, relativeTo: icon)
        partnerIcon.isHidden = true
        partnerTitle.isHidden = true
        divider.isHidden = true
        [partnerIcon, partnerTitle, divider].forEach { addSubview($0) }
        addSubview(audioButton)
        addSubview(closeButton)
    }

    func configure(partner: Tab?) {
        guard partner !== self.partner else { return }
        self.partner = partner
        partnerToken = partner?.changed.observe { [weak self] change in
            if change == .title || change == .favicon || change == .loading || change == .url { self?.refreshPartner() }
        }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    func configure(pinnedPartner title: String?, icon: NSImage?, unloaded: Bool) {
        pinnedPartner = title.map { ($0, icon, unloaded) }
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = !isSplit }
        refreshPartner()
    }

    private func refreshPartner() {
        partnerTitle.stringValue = pinnedPartner?.title ?? partner?.displayTitle ?? ""
        partnerIcon.image = partner?.favicon ?? pinnedPartner?.icon
        partnerIcon.isLoading = (partner?.isLoading ?? false) && !(partner?.isSuspended ?? true)
        refreshAccessibilityLabel()
        refreshTitleColor()
        needsLayout = true
    }

    /// A split row reads out both of its pages.
    private func refreshAccessibilityLabel() {
        setAccessibilityLabel(!isSplit ? title.stringValue : "\(title.stringValue), split with \(partnerTitle.stringValue)")
        // What VoiceOver says after the name: the tab you're on, and whether it's playing or muted.
        let state = [isSelected ? "current tab" : nil, tab?.isMuted == true ? "muted" : tab?.isPlayingAudio == true ? "playing audio" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        setAccessibilityValue(state.isEmpty ? nil : state)
        setAccessibilitySelected(isSelected)
    }

    /// Which half of a split row a point (in this view) falls in.
    func half(at point: NSPoint) -> Int {
        isSplit && point.x > bounds.midX ? 1 : 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab?) {
        guard tab !== self.tab || token == nil else { refresh(); return }
        self.tab = tab
        token = tab?.changed.observe { [weak self] change in self?.tabChanged(change) }
        refresh()
    }

    private func tabChanged(_ change: Tab.Change) {
        switch change {
        case .title, .url, .favicon, .loading, .audio, .themeColor, .webView, .activity: refresh()
        default: break
        }
    }

    var showsAudio: Bool { tab?.isPlayingAudio == true || tab?.isMuted == true }

    override var trailingAccessoryWidth: CGFloat {
        let close = (isHovered || isSelected) && !isLifted ? closeButton.frame.width : 0
        let audio = showsAudio ? audioButton.frame.width + (close > 0 ? Tokens.Space.x1 : 0) : 0
        return close + audio
    }

    func refresh() {
        title.stringValue = fixedTitle ?? tab?.displayTitle ?? ""
        icon.image = tab?.favicon ?? (fixedTitle != nil ? bookmarkIcon : nil)
        icon.isLoading = (tab?.isLoading ?? false) && !(tab?.isSuspended ?? true)
        audioButton.symbol = tab?.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        audioButton.toolTip = tab?.isMuted == true ? "Unmute Tab" : "Mute Tab"
        siteTint = tab.flatMap { SiteTint.color(for: $0) }
        refreshAccessibilityLabel()
        refreshTitleColor()
        refreshAccessories()
    }

    var bookmarkIcon: NSImage?

    private func refreshTitleColor() {
        title.textColor = isUnloaded && !isSelected ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
        let split = isSplit
        title.font = Tokens.Font.body(isSelected && (!split || focusedHalf == 0) ? .medium : .regular)
        partnerTitle.textColor = pinnedPartner?.unloaded == true && !isSelected ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
        partnerTitle.font = Tokens.Font.body(isSelected && focusedHalf == 1 ? .medium : .regular)
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(0.14)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.7))
    }

    private func refreshAccessories() {
        let showClose = (isHovered || isSelected) && !isLifted && (!isBookmark || !isUnloaded) && renameField == nil
        closeButton.isHidden = !showClose
        closeButton.toolTip = isAway ? "Back to Pinned Page" : isBookmark ? "Unload Page" : "Close Tab"
        audioButton.isHidden = !showsAudio || renameField != nil
        needsLayout = true
    }

    private func layoutRenameField() {
        guard let field = renameField else { return }
        let x = title.frame.minX
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - Tokens.Space.x2), height: height)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        refreshTitleColor()
        refreshAccessories()
        refreshAccessibilityLabel()
    }


    override func layout() {
        super.layout()
        if isAway {
            // Make room for the mark: the title moves over by its width.
            let x = icon.frame.maxX + Tokens.Space.x2
            let h: CGFloat = 12
            Tokens.Motion.withoutAnimation {
                awayMark.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: 6, height: h)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 5, y: isFlipped ? 1 : h - 1))
                path.addLine(to: CGPoint(x: 1, y: isFlipped ? h - 1 : 1))
                awayMark.path = path
                awayMark.strokeColor = cgColor(Tokens.Color.textTertiary)
            }
            title.frame.origin.x += 6 + Tokens.Space.x1
            title.frame.size.width = max(0, title.frame.width - 6 - Tokens.Space.x1)
        }
        layoutRenameField()
        let size = closeButton.frame.size
        let y = (bounds.height - size.height) / 2
        var x = bounds.width - Tokens.Space.x1 - size.width
        closeButton.frame.origin = NSPoint(x: x, y: y)
        if !closeButton.isHidden { x -= size.width + Tokens.Space.x1 }
        audioButton.frame.origin = NSPoint(x: x, y: y)
        layoutDropHalf()

        // A split shows both pages in one row: left half, a hairline, right half.
        guard isSplit else { return }
        let mid = bounds.midX
        title.frame.size.width = max(0, mid - Tokens.Space.x1 - title.frame.minX)
        divider.frame = NSRect(x: mid, y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
        partnerIcon.frame = icon.frame.offsetBy(dx: mid, dy: 0)
        let titleX = partnerIcon.frame.maxX + Tokens.Space.x2
        let trailing = trailingAccessoryWidth > 0 ? trailingAccessoryWidth + Tokens.Space.x1 : Tokens.Space.x2
        partnerTitle.frame = NSRect(x: titleX, y: title.frame.minY, width: max(0, bounds.width - titleX - trailing), height: title.frame.height)
    }
}

/// "New Tab" at the top of the tab list.
final class NewTabRowView: SidebarRowView {
    private let plus = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.stringValue = "New Tab"
        title.textColor = Tokens.Color.textSecondary
        icon.isHidden = true
        plus.image = Tokens.Symbol.image("plus")
        plus.contentTintColor = Tokens.Color.textSecondary
        plus.imageScaling = .scaleNone
        addSubview(plus)
        setAccessibilityLabel("New Tab")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        plus.frame = icon.frame
    }
}

/// A folder of pinned pages: a chevron that turns as it opens, a folder, and its name. Click to open or close it;
/// double-click to rename it. Pinned pages dropped on it go in.
final class FolderRowView: SidebarRowView, NSTextFieldDelegate {
    private let chevron = NSImageView()
    private let folderIcon = NSImageView()
    var isOpen = true { didSet { if oldValue != isOpen { turnChevron(animated: true) } } }
    /// While a pinned page or tab is dragged over it: it lights up to say it will take it.
    var isDropTarget = false { didSet { stateDidChange(animated: true) } }
    var onRename: ((String) -> Void)?
    private var renameField: PlainTextField?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.TypeSize.small - 1)
        chevron.contentTintColor = Tokens.Color.textTertiary
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        addSubview(chevron)
        icon.isHidden = true
        folderIcon.imageScaling = .scaleNone
        folderIcon.contentTintColor = Tokens.Color.textSecondary
        addSubview(folderIcon)
        title.font = Tokens.Font.body(.medium)
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, open: Bool, count: Int) {
        title.stringValue = name
        folderIcon.image = Tokens.Symbol.image(open ? "folder" : "folder.fill", size: Tokens.TypeSize.body)
        isOpen = open
        setAccessibilityLabel("\(name), folder, \(count) pinned")
        setAccessibilityValue(open ? 1 : 0)
        needsLayout = true
    }

    private func turnChevron(animated: Bool) {
        guard let layer = chevron.layer else { return }
        let size = chevron.bounds.size
        let angle: CGFloat = isOpen ? .pi / 2 : 0
        let turn = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                           CATransform3DMakeRotation(angle, 0, 0, 1)),
                                       CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        if animated && !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
            layer.transform = turn
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation { layer.transform = turn }
        }
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x3
        chevron.frame = NSRect(x: bounds.width - Tokens.Space.x2 - side, y: (bounds.height - side) / 2, width: side, height: side)
        folderIcon.frame = icon.frame
        turnChevron(animated: false)
        title.frame.size.width = max(0, chevron.frame.minX - Tokens.Space.x1 - title.frame.minX)
        if let field = renameField {
            let height = ceil(field.intrinsicContentSize.height)
            field.frame = NSRect(x: title.frame.minX, y: (bounds.height - height) / 2, width: max(0, bounds.width - title.frame.minX - Tokens.Space.x2), height: height)
        }
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        if isDropTarget { layer?.set(backgroundColor: cgColor(Tokens.Color.selectedFill), animated: animated) }
        chevron.alphaValue = isHovered || !isOpen || isDropTarget ? 1 : 0.6
    }

    func beginRename() {
        guard renameField == nil, let window else { return }
        let field = PlainTextField(font: title.font ?? Tokens.Font.body(), placeholder: "Folder name")
        field.stringValue = title.stringValue
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        title.isHidden = true
        addSubview(field)
        renameField = field
        needsLayout = true
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        title.isHidden = false
        if commit, !name.isEmpty { onRename?(name) }
        window?.makeFirstResponder(window?.contentView)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }
}

/// The space name above its bookmarks. Click it to fold the bookmarks away; a chevron says so.
final class SpaceHeaderView: InteractiveView {
    let label = Label("", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    private let chevron = NSImageView()
    var isCollapsed = false { didSet { stateDidChange(animated: false) } }
    /// Only spaces with bookmarks can fold.
    var canCollapse = false { didSet { stateDidChange(animated: false) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.imageScaling = .scaleNone
        chevron.contentTintColor = Tokens.Color.textTertiary
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        let x = Tokens.Space.x2
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: min(label.textWidth, bounds.width - x - Tokens.Space.x6), height: h)
        chevron.frame = NSRect(x: label.frame.maxX + Tokens.Space.x1, y: 0, width: Tokens.Space.x3, height: bounds.height)
    }

    override func stateDidChange(animated: Bool) {
        label.textColor = isHovered && canCollapse ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        chevron.image = Tokens.Symbol.image(isCollapsed ? "chevron.right" : "chevron.down", size: Tokens.TypeSize.small - 2)
        // The chevron shows on hover, and stays while folded so you know something is tucked away.
        chevron.isHidden = !canCollapse || !(isHovered || isCollapsed)
        setAccessibilityLabel(label.stringValue + (isCollapsed ? ", pinned tabs hidden" : ""))
    }
}

/// Thin line between bookmarks and tabs.
/// The line above today's tabs. Clear sits at its end, as in Arc: on a line of its own, apart from New Tab and the
/// pinned tabs it leaves alone, and only while the pointer is over the list and there are tabs to clear.
final class SeparatorRowView: NSView {
    private let line = ColorView(color: Tokens.Color.separator)
    let clearButton = ClearTabsButton()
    var showsClear = false { didSet { if showsClear != oldValue { refreshClear() } } }
    var hasTabs = false { didSet { if hasTabs != oldValue { refreshClear() } } }
    private var clearShown: Bool { showsClear && hasTabs }
    /// When Clear last came into view. A click right as it appears was meant for whatever was under the pointer
    /// a moment before (New Tab, just below), so it counts only once Clear has been there a beat.
    private var clearShownAt = Date.distantPast
    var clearIsArmed: Bool { clearShown && Date().timeIntervalSince(clearShownAt) > 0.35 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
        clearButton.alphaValue = 0
        clearButton.isHidden = true
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refreshClear() {
        let show = clearShown
        if show { clearButton.isHidden = false; clearShownAt = Date() }
        needsLayout = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            clearButton.animator().alphaValue = show ? 1 : 0
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, !self.clearShown else { return }
            self.clearButton.isHidden = true
        })
    }

    override func layout() {
        super.layout()
        let cw = clearButton.fittingWidth, ch: CGFloat = 18
        clearButton.frame = NSRect(x: bounds.width - cw, y: floor((bounds.height - ch) / 2), width: cw, height: ch)
        clearButton.layoutSubtreeIfNeeded()
        // The line runs up to Clear while it shows, so the two read as one.
        let end = clearShown ? clearButton.frame.minX - Tokens.Space.x1 : bounds.width - Tokens.Space.x2
        line.frame = NSRect(x: Tokens.Space.x2, y: floor(bounds.height / 2), width: max(0, end - Tokens.Space.x2), height: Tokens.Metric.hairline)
    }
}

enum SiteTint {
    private static var iconColors: [ObjectIdentifier: NSColor?] = [:]

    static func color(for tab: Tab) -> NSColor? {
        if let theme = tab.themeColor, let usable = usable(theme) { return usable }
        guard let icon = tab.favicon else { return nil }
        let key = ObjectIdentifier(icon)
        if let cached = iconColors[key] { return cached }
        let color = FaviconStore.shared.dominantColor(of: icon)
        iconColors[key] = color
        return color
    }

    /// Ignores pale, gray and near-black theme colors: they say nothing about the site,
    /// and a gray wash would read as a hover state.
    private static func usable(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        if rgb.saturationComponent < 0.35 { return nil }
        if rgb.brightnessComponent < 0.3 { return nil }
        return rgb
    }

    /// 1 for recently used tabs, easing down to the floor for tabs left alone for days.
    static func freshness(lastActivated: Date, now: Date = Date()) -> CGFloat {
        let age = now.timeIntervalSince(lastActivated)
        guard age > Tokens.Fade.start else { return 1 }
        let t = min(1, (age - Tokens.Fade.start) / (Tokens.Fade.full - Tokens.Fade.start))
        let eased = 1 - pow(1 - t, 2)
        return 1 - CGFloat(eased) * (1 - Tokens.Opacity.fadedFloor)
    }
}

/// A dashed outline that invites a drop.
final class DropZoneView: NSView {
    private let label: Label
    private let border = CAShapeLayer()

    init(text: String) {
        label = Label(text, font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
        label.alignment = .center
        super.init(frame: .zero)
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = Tokens.Metric.hairline
        border.lineDashPattern = [3, 3]
        layer?.addSublayer(border)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            border.frame = bounds
            border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Tokens.Radius.row, cornerHeight: Tokens.Radius.row, transform: nil)
            border.strokeColor = cgColor(Tokens.Color.textTertiary)
        }
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }
}

/// Where a dragged tab will land: a short accent line with round ends.
final class InsertionLineView: NSView {
    private let line = ColorView(color: Tokens.Color.accent)

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        line.layer?.cornerRadius = 1
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: Tokens.Space.x2, y: floor((bounds.height - 2) / 2), width: bounds.width - Tokens.Space.x4, height: 2)
    }
}

/// Clear, on the line above the tabs: small, quiet text with a downward arrow (it clears what's below), the same
/// grey as the line until the pointer is on it.
final class ClearTabsButton: InteractiveView {
    /// The tabs below get swept away, the way Arc says it: an arrow pointing down at them.
    private let arrow = NSImageView()
    private let label = Label("Clear", font: Tokens.Font.small(.medium), color: Tokens.Color.textTertiary)
    private static let arrowSide: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerCurve = .continuous
        arrow.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Tokens.TypeSize.small - 2, weight: .semibold))
        arrow.imageScaling = .scaleNone
        [arrow, label].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        keepsCurrent = true
        stateDidChange(animated: false)
    }

    /// Clear closes the other tabs first, and the one you're on only once it's the last.
    var keepsCurrent = false {
        didSet {
            toolTip = keepsCurrent ? "Close All Tabs but This One" : "Close This Tab"
            setAccessibilityLabel(toolTip)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { ceil(6 + Self.arrowSide + 3 + label.inkWidth + Tokens.Space.x2) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A capsule, so its hover fill reads as one small button on the line.
        layer?.cornerRadius = bounds.height / 2
        arrow.frame = NSRect(x: 6, y: (bounds.height - Self.arrowSide) / 2, width: Self.arrowSide, height: Self.arrowSide)
        let h = label.lineHeight
        label.frame = NSRect(x: arrow.frame.maxX + 3 - Label.inset, y: (bounds.height - h) / 2, width: label.inkWidth + Label.inset * 2, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let active = isHovered || isPressed
        label.textColor = active ? Tokens.Color.textPrimary : Tokens.Color.textTertiary
        arrow.contentTintColor = label.textColor
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }
}
