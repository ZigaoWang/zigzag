import AppKit

/// A page thumbnail with its site and title underneath, used by the switcher and desk view.
final class TabThumbnailView: InteractiveView {
    let imageClip = NSView()
    /// The page, filling its card and cropped from the bottom, never letterboxed. A split shows both pages, side
    /// by side, as it does on screen.
    private let halves = [CALayer(), CALayer()]
    private let images = [CALayer(), CALayer()]
    private let divider = CALayer()
    private let placeholder = FaviconView()
    let icon = FaviconView()
    let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    /// With a split: the other page's icon and title, under its half.
    private let icon2 = FaviconView()
    private let title2 = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let ring = CALayer()
    var showsTitle = true { didSet { needsLayout = true } }
    /// Desk view marks selection with an accent ring; the switcher uses a quiet highlight.
    var showsRing = false
    var showsHover = true
    /// Desk view: an × on the card while the pointer is over it.
    var onClose: (() -> Void)? { didSet { closeButton.isHidden = true } }
    private let closeButton = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Close Tab")
    /// A page with no picture yet, or only a blank one (asleep, or caught before it drew): its site instead.
    private let siteName = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    static let titleHeight = Tokens.Space.x8
    private(set) weak var tab: Tab?
    /// The page beside it in split view, if any.
    private(set) weak var partner: Tab?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.panel
        layer?.cornerCurve = .continuous
        imageClip.wantsLayer = true
        imageClip.layer?.cornerRadius = Tokens.Radius.thumbnail
        imageClip.layer?.cornerCurve = .continuous
        imageClip.layer?.masksToBounds = true
        imageClip.layer?.borderWidth = Tokens.Metric.hairline
        for (half, image) in zip(halves, images) {
            half.masksToBounds = true
            half.addSublayer(image)
            imageClip.layer?.addSublayer(half)
        }
        imageClip.layer?.addSublayer(divider)
        imageClip.addSubview(placeholder)
        ring.borderWidth = 2.5
        ring.cornerRadius = Tokens.Radius.thumbnail + 3
        ring.cornerCurve = .continuous
        ring.isHidden = true
        ring.zPosition = 10
        siteName.alignment = .center
        siteName.lineBreakMode = .byTruncatingMiddle
        imageClip.addSubview(siteName)
        closeButton.showsFillAtRest = true
        closeButton.isHidden = true
        closeButton.onClick = { [weak self] _ in self?.onClose?() }
        [imageClip, icon, title, icon2, title2, closeButton].forEach { addSubview($0) }
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tab: Tab, partner: Tab? = nil) {
        self.tab = tab
        self.partner = partner
        placeholder.image = tab.favicon
        siteName.stringValue = tab.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        icon.image = tab.favicon
        title.stringValue = tab.displayTitle
        icon2.image = partner?.favicon
        title2.stringValue = partner?.displayTitle ?? ""
        setAccessibilityLabel(partner.map { "\(tab.displayTitle) and \($0.displayTitle)" } ?? tab.displayTitle)
        refreshImage()
        needsLayout = true
    }

    func refreshImage() {
        guard let tab else { return }
        Tokens.Motion.withoutAnimation {
            images[0].contents = Self.isBlank(tab.snapshot) ? nil : tab.snapshot
            images[1].contents = partner?.snapshot
        }
        let showsPage = !Self.isBlank(tab.snapshot) || partner != nil
        placeholder.isHidden = showsPage
        siteName.isHidden = showsPage
        needsLayout = true
    }

    private static var blankness: [ObjectIdentifier: Bool] = [:]

    /// No picture, or one that's all one color: a page that hadn't drawn yet. Checked once per picture, on a
    /// thumbnail a few pixels across.
    static func isBlank(_ image: NSImage?) -> Bool {
        guard let image else { return true }
        let key = ObjectIdentifier(image)
        if let known = blankness[key] { return known }
        let side = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var low = [CGFloat](repeating: 1, count: 3), high = [CGFloat](repeating: 0, count: 3)
        for x in 0..<side { for y in 0..<side {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            for (i, v) in [c.redComponent, c.greenComponent, c.blueComponent].enumerated() { low[i] = min(low[i], v); high[i] = max(high[i], v) }
        } }
        let blank = zip(low, high).allSatisfy { $1 - $0 < 0.03 }
        if blankness.count > 500 { blankness.removeAll() }
        blankness[key] = blank
        return blank
    }

    /// Which page a click landed on: with a split, the half under the pointer.
    func tab(at event: NSEvent) -> Tab? {
        guard let partner else { return tab }
        return imageClip.convert(event.locationInWindow, from: nil).x > imageClip.bounds.midX ? partner : tab
    }

    /// Fills `rect` with the snapshot, scaled to cover it and pinned to its top, as a page is read.
    private func fill(_ index: Int, snapshot: NSImage?, in rect: CGRect) {
        halves[index].frame = rect
        guard let size = snapshot?.size, size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        // The clip isn't flipped: its top is the highest y.
        images[index].frame = CGRect(x: (rect.width - w) / 2, y: rect.height - h, width: w, height: h)
    }

    /// Space around the image so the selection highlight can surround it, like Command+Tab.
    var inset: CGFloat = Tokens.Space.x2 { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        let titleArea = showsTitle ? Self.titleHeight : 0
        imageClip.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - titleArea - inset * (showsTitle ? 1 : 2))
        Tokens.Motion.withoutAnimation {
            let b = imageClip.bounds
            if partner != nil {
                let half = floor((b.width - 1) / 2)
                fill(0, snapshot: tab?.snapshot, in: CGRect(x: 0, y: 0, width: half, height: b.height))
                fill(1, snapshot: partner?.snapshot, in: CGRect(x: half + 1, y: 0, width: b.width - half - 1, height: b.height))
                divider.frame = CGRect(x: half, y: 0, width: 1, height: b.height)
            } else {
                fill(0, snapshot: tab?.snapshot, in: b)
            }
            halves[1].isHidden = partner == nil
            divider.isHidden = partner == nil
        }
        let p = Tokens.Space.x8
        // The clip isn't flipped: the icon sits a little above the middle, its site under it.
        let nameHeight = siteName.lineHeight
        let block = p + Tokens.Space.x2 + nameHeight
        let bottom = (imageClip.bounds.height - block) / 2
        placeholder.frame = NSRect(x: (imageClip.bounds.width - p) / 2, y: bottom + nameHeight + Tokens.Space.x2, width: p, height: p)
        siteName.frame = NSRect(x: Tokens.Space.x2, y: bottom, width: imageClip.bounds.width - Tokens.Space.x4, height: nameHeight)
        let cs = Tokens.Space.x6
        closeButton.frame = NSRect(x: imageClip.frame.maxX - cs - Tokens.Space.x1, y: imageClip.frame.minY + Tokens.Space.x1, width: cs, height: cs)
        icon.isHidden = !showsTitle
        title.isHidden = !showsTitle
        icon2.isHidden = !showsTitle || partner == nil
        title2.isHidden = !showsTitle || partner == nil
        // One title under the card, or with a split, each page's under its own half.
        if partner != nil {
            let half = imageClip.frame.width / 2
            place(icon, title, in: NSRect(x: imageClip.frame.minX, y: imageClip.frame.maxY, width: half, height: titleArea))
            place(icon2, title2, in: NSRect(x: imageClip.frame.minX + half, y: imageClip.frame.maxY, width: half, height: titleArea))
        } else {
            place(icon, title, in: NSRect(x: inset, y: imageClip.frame.maxY, width: bounds.width - inset * 2, height: titleArea))
        }
        Tokens.Motion.withoutAnimation {
            ring.frame = imageClip.frame.insetBy(dx: -4, dy: -4)
        }
        refreshColors()
    }

    /// An icon and title, centered together in `area`.
    private func place(_ icon: FaviconView, _ title: Label, in area: NSRect) {
        let iconSize = Tokens.Metric.favicon
        let textWidth = max(0, min(title.textWidth, area.width - iconSize - Tokens.Space.x2 - Tokens.Space.x2))
        let total = iconSize + Tokens.Space.x2 + textWidth
        let x = area.minX + max(Tokens.Space.x1, (area.width - total) / 2)
        icon.frame = NSRect(x: x, y: area.minY + (area.height - iconSize) / 2, width: iconSize, height: iconSize)
        let h = title.lineHeight
        title.frame = NSRect(x: icon.frame.maxX + Tokens.Space.x2, y: area.minY + (area.height - h) / 2, width: textWidth, height: h)
    }

    override func stateDidChange(animated: Bool) {
        closeButton.isHidden = onClose == nil || !isHovered
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            imageClip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
            imageClip.layer?.borderColor = cgColor(Tokens.Color.cardEdge)
            divider.backgroundColor = cgColor(Tokens.Color.cardEdge)
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
            // Control was let go somewhere we didn't see (another app): the switch is over, and the key is yours.
            if isActive, !event.modifierFlags.contains(.control) { cancel(); return false }
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

    /// The window lost focus mid-switch (⌘Tab away): put it away, staying on the current tab.
    func windowResignedKey() { if isActive { cancel() } }

    private func finish() {
        isActive = false
        showWork?.cancel()
        if shown { panel.dismiss() }
        shown = false
    }
}
