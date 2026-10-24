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
        let visible = isSelected || isHovered || isLifted ? 1 : freshness
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
        field.frame = title.frame.insetBy(dx: 0, dy: -2)
        field.delegate = self
        field.onCancel = { [weak self] in self?.endRename(commit: false) }
        title.isHidden = true
        addSubview(field)
        renameField = field
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        title.isHidden = false
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
        clicksOnMouseDown = true
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
        [partnerIcon, partnerTitle, divider].forEach { $0.isHidden = partner == nil }
        refreshPartner()
    }

    private func refreshPartner() {
        partnerTitle.stringValue = partner?.displayTitle ?? ""
        partnerIcon.image = partner?.favicon
        partnerIcon.isLoading = (partner?.isLoading ?? false) && !(partner?.isSuspended ?? true)
        refreshTitleColor()
        needsLayout = true
    }

    /// Which half of a split row a point (in this view) falls in.
    func half(at point: NSPoint) -> Int {
        partner != nil && point.x > bounds.midX ? 1 : 0
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
        setAccessibilityLabel(title.stringValue)
        refreshTitleColor()
        refreshAccessories()
    }

    var bookmarkIcon: NSImage?

    private func refreshTitleColor() {
        title.textColor = isUnloaded && !isSelected ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
        let split = partner != nil
        title.font = Tokens.Font.body(isSelected && (!split || focusedHalf == 0) ? .medium : .regular)
        partnerTitle.textColor = Tokens.Color.textPrimary
        partnerTitle.font = Tokens.Font.body(isSelected && focusedHalf == 1 ? .medium : .regular)
        dropHalf.color = Tokens.Color.accent.withAlphaComponent(0.14)
        dropHalf.layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.7))
    }

    private func refreshAccessories() {
        let showClose = (isHovered || isSelected) && !isLifted && (!isBookmark || !isUnloaded)
        closeButton.isHidden = !showClose
        closeButton.toolTip = isAway ? "Back to Pinned Page" : isBookmark ? "Unload Page" : "Close Tab"
        audioButton.isHidden = !showsAudio
        needsLayout = true
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
        let size = closeButton.frame.size
        let y = (bounds.height - size.height) / 2
        var x = bounds.width - Tokens.Space.x1 - size.width
        closeButton.frame.origin = NSPoint(x: x, y: y)
        if !closeButton.isHidden { x -= size.width + Tokens.Space.x1 }
        audioButton.frame.origin = NSPoint(x: x, y: y)
        layoutDropHalf()

        // A split shows both pages in one row: left half, a hairline, right half.
        guard partner != nil else { return }
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
        setAccessibilityLabel(label.stringValue + (isCollapsed ? ", bookmarks hidden" : ""))
    }
}

/// Thin line between bookmarks and tabs.
final class SeparatorRowView: NSView {
    private let line = ColorView(color: Tokens.Color.separator)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: Tokens.Space.x2, y: floor(bounds.height / 2), width: bounds.width - Tokens.Space.x4, height: Tokens.Metric.hairline)
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
