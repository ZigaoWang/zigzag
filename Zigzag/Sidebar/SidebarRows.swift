import AppKit

/// A row in the sidebar list. Tabs, bookmarks and "New Tab" all share one look.
class SidebarRowView: InteractiveView {
    let icon = FaviconView()
    let title = Label()
    /// Soft color from the site's own theme.
    var siteTint: NSColor? { didSet { stateDidChange(animated: false) } }
    /// 1 = just looked at, down to the faded floor for tabs left alone a long time.
    var freshness: CGFloat = 1 { didSet { if oldValue != freshness { stateDidChange(animated: false) } } }
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
        if let siteTint {
            if isSelected || isLifted {
                fill = cgColor(SidebarRowView.tinted(selectedFill: base ?? Tokens.Color.selectedFill, with: siteTint, appearance: effectiveAppearance))
            } else {
                // A whisper of the site's color, so tabs are recognizable before they're read.
                let dark = effectiveAppearance.isDark
                let wash = siteTint.withAlphaComponent((dark ? 0.10 : 0.08) * freshness + (isHovered ? 0.04 : 0) + (isPressed ? 0.04 : 0))
                fill = cgColor(wash)
            }
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
final class TabRowView: SidebarRowView {
    private(set) var tab: Tab?
    private var token: SignalToken?
    let closeButton = IconButton(symbol: "xmark", size: Tokens.Space.x5, symbolSize: Tokens.TypeSize.small, toolTip: "Close Tab")
    let audioButton = IconButton(symbol: "speaker.wave.2.fill", size: Tokens.Space.x5, symbolSize: Tokens.TypeSize.small, toolTip: "Mute Tab")
    var onClose: (() -> Void)?
    /// Bookmarks keep their own title; only the icon and state follow the page.
    var fixedTitle: String? { didSet { refresh() } }
    var isBookmark = false
    var isUnloaded = false { didSet { refreshTitleColor() } }

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
        addSubview(audioButton)
        addSubview(closeButton)
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
        title.font = Tokens.Font.body(isSelected ? .medium : .regular)
    }

    private func refreshAccessories() {
        let showClose = (isHovered || isSelected) && !isLifted && (!isBookmark || !isUnloaded)
        closeButton.isHidden = !showClose
        closeButton.toolTip = isBookmark ? "Unload Page" : "Close Tab"
        audioButton.isHidden = !showsAudio
        needsLayout = true
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        refreshTitleColor()
        refreshAccessories()
    }

    override func layout() {
        super.layout()
        let size = closeButton.frame.size
        let y = (bounds.height - size.height) / 2
        var x = bounds.width - Tokens.Space.x1 - size.width
        closeButton.frame.origin = NSPoint(x: x, y: y)
        if !closeButton.isHidden { x -= size.width + Tokens.Space.x1 }
        audioButton.frame.origin = NSPoint(x: x, y: y)
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

/// The space name above its bookmarks and tabs.
final class SpaceHeaderView: InteractiveView {
    let label = Label("", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - h) / 2, width: bounds.width - Tokens.Space.x4, height: h)
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
    static func color(for tab: Tab) -> NSColor? {
        if let theme = tab.themeColor, let usable = usable(theme) { return usable }
        if let icon = tab.favicon { return FaviconStore.shared.dominantColor(of: icon) }
        return nil
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
