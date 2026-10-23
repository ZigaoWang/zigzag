import AppKit

/// A page thumbnail with its site and title underneath, used by the switcher and desk view.
final class TabThumbnailView: InteractiveView {
    let imageClip = NSView()
    private let imageView = NSImageView()
    private let placeholder = FaviconView()
    let icon = FaviconView()
    let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let ring = CALayer()
    var showsTitle = true { didSet { needsLayout = true } }
    /// Desk view marks selection with an accent ring; the switcher uses a quiet highlight.
    var showsRing = false
    var showsHover = true
    static let titleHeight = Tokens.Space.x8
    private(set) weak var tab: Tab?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.panel
        layer?.cornerCurve = .continuous
        imageClip.wantsLayer = true
        imageClip.layer?.cornerRadius = Tokens.Radius.thumbnail
        imageClip.layer?.cornerCurve = .continuous
        imageClip.layer?.masksToBounds = true
        imageClip.layer?.borderWidth = Tokens.Metric.hairline
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageClip.addSubview(imageView)
        imageClip.addSubview(placeholder)
        ring.borderWidth = 2.5
        ring.cornerRadius = Tokens.Radius.thumbnail + 3
        ring.cornerCurve = .continuous
        ring.isHidden = true
        ring.zPosition = 10
        [imageClip, icon, title].forEach { addSubview($0) }
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tab: Tab) {
        self.tab = tab
        imageView.image = tab.snapshot
        imageView.isHidden = tab.snapshot == nil
        placeholder.isHidden = tab.snapshot != nil
        placeholder.image = tab.favicon
        icon.image = tab.favicon
        title.stringValue = tab.displayTitle
        setAccessibilityLabel(tab.displayTitle)
        needsLayout = true
    }

    func refreshImage() {
        guard let tab else { return }
        imageView.image = tab.snapshot
        imageView.isHidden = tab.snapshot == nil
        placeholder.isHidden = tab.snapshot != nil
    }

    /// Space around the image so the selection highlight can surround it, like Command+Tab.
    var inset: CGFloat = Tokens.Space.x2 { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        let titleArea = showsTitle ? Self.titleHeight : 0
        imageClip.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - titleArea - inset * (showsTitle ? 1 : 2))
        imageView.frame = imageClip.bounds
        let p = Tokens.Space.x8
        placeholder.frame = NSRect(x: (imageClip.bounds.width - p) / 2, y: (imageClip.bounds.height - p) / 2, width: p, height: p)
        let iconSize = Tokens.Metric.favicon
        icon.isHidden = !showsTitle
        title.isHidden = !showsTitle
        let textWidth = min(title.textWidth, bounds.width - iconSize - Tokens.Space.x2 - inset * 2)
        let total = iconSize + Tokens.Space.x2 + textWidth
        let x = max(inset, (bounds.width - total) / 2)
        let y = imageClip.frame.maxY + (titleArea - iconSize) / 2
        icon.frame = NSRect(x: x, y: y, width: iconSize, height: iconSize)
        let h = title.lineHeight
        title.frame = NSRect(x: icon.frame.maxX + Tokens.Space.x2, y: imageClip.frame.maxY + (titleArea - h) / 2, width: textWidth, height: h)
        Tokens.Motion.withoutAnimation {
            ring.frame = imageClip.frame.insetBy(dx: -4, dy: -4)
        }
        refreshColors()
    }

    override func stateDidChange(animated: Bool) {
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            imageClip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
            imageClip.layer?.borderColor = cgColor(Tokens.Color.cardEdge)
            ring.borderColor = cgColor(Tokens.Color.accent)
            ring.isHidden = !(isSelected && showsRing)
        }
        let fill: NSColor? = isSelected && !showsRing ? Tokens.Color.pressedFill : (isHovered && showsHover) ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }
}

/// Control+Tab: big thumbnails of recent tabs, like Command+Tab for apps.
/// Hold Control, press Tab to step through, let go to switch.
final class TabSwitcher {
    private weak var controller: BrowserWindowController?
    private let panel = FloatingPanelView()
    private var thumbs: [TabThumbnailView] = []
    private var tabs: [Tab] = []
    private var index = 0
    private(set) var isActive = false
    private var shown = false
    private var showWork: DispatchWorkItem?

    init(controller: BrowserWindowController) {
        self.controller = controller
        panel.radius = Tokens.Radius.panel + Tokens.Space.x1
    }

    /// Returns true if the event was handled.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard event.keyCode == 48 /* tab */, event.modifierFlags.contains(.control) else {
                if isActive, event.keyCode == 53 /* esc */ { cancel(); return true }
                return isActive
            }
            let backwards = event.modifierFlags.contains(.shift)
            if !isActive { begin(backwards: backwards) } else { step(backwards ? -1 : 1) }
            return true
        case .flagsChanged:
            if isActive, !event.modifierFlags.contains(.control) { commit(); return true }
            return false
        default:
            return false
        }
    }

    private func begin(backwards: Bool) {
        guard let controller else { return }
        tabs = Array(controller.tabManager.recentTabs.prefix(9))
        guard tabs.count > 1 else { return }
        controller.tabManager.selectedTab?.captureSnapshot()
        isActive = true
        index = backwards ? tabs.count - 1 : 1
        // A quick Control+Tab switches without flashing any UI, like Command+Tab.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.show() } }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func show() {
        guard isActive, let controller else { return }
        shown = true
        thumbs.forEach { $0.removeFromSuperview() }
        let card = controller.root.cardFrame
        let aspect = min(max(card.height / max(card.width, 1), 0.5), 0.8)
        let gap = 0 as CGFloat
        let pad = Tokens.Space.x2
        let bounds = controller.root.bounds
        let maxWidth = bounds.width - Tokens.Space.x16
        var thumbWidth = Tokens.Metric.switcherThumbWidth
        let count = CGFloat(tabs.count)
        if count * thumbWidth + (count - 1) * gap + pad * 2 > maxWidth {
            thumbWidth = floor((maxWidth - pad * 2 - (count - 1) * gap) / count)
        }
        let thumbHeight = round((thumbWidth - Tokens.Space.x4) * aspect) + TabThumbnailView.titleHeight + Tokens.Space.x2
        thumbs = tabs.enumerated().map { i, tab in
            let thumb = TabThumbnailView()
            thumb.configure(tab)
            thumb.showsHover = false
            thumb.frame = NSRect(x: pad + CGFloat(i) * (thumbWidth + gap), y: pad, width: thumbWidth, height: thumbHeight)
            thumb.onClick = { [weak self] _ in self?.index = i; self?.commit() }
            panel.addSubview(thumb)
            return thumb
        }
        let width = pad * 2 + count * thumbWidth + (count - 1) * gap
        let height = pad * 2 + thumbHeight
        panel.frame = NSRect(x: round(bounds.midX - width / 2), y: round(bounds.midY - height / 2), width: width, height: height)
        controller.root.overlay.addSubview(panel)
        panel.present()
        updateSelection()
    }

    private func step(_ delta: Int) {
        guard isActive else { return }
        index = (index + delta + tabs.count) % tabs.count
        updateSelection()
    }

    private func updateSelection() {
        for (i, thumb) in thumbs.enumerated() { thumb.isSelected = i == index }
    }

    private func commit() {
        guard isActive else { return }
        let target = tabs.indices.contains(index) ? tabs[index] : nil
        finish()
        if let target { controller?.tabManager.select(target) }
    }

    private func cancel() { finish() }

    private func finish() {
        isActive = false
        showWork?.cancel()
        if shown { panel.dismiss() }
        shown = false
    }
}
