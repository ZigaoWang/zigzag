import AppKit

/// Getting started, in the window itself: one step at a time, the place to act lit up, and one card beside it
/// saying exactly what to do. You do the step in the real browser, and the guide moves on by itself.
final class GuidedTour: NSView {
    private static weak var current: GuidedTour?
    private weak var controller: BrowserWindowController?
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let card = FloatingPanelView()
    private let step = Label("", font: Tokens.Font.small(.semibold), color: Brand.Theme.brand.accent)
    private let close = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: 9, toolTip: "End Getting Started")
    private let check = NSImageView()
    private let title = Label("", font: .systemFont(ofSize: 16, weight: .semibold), color: Tokens.Color.textPrimary)
    private let how = NSTextField(wrappingLabelWithString: "")
    private var caps: [(ColorView, Label)] = []
    private let skip = TextButton(title: "Skip", font: Tokens.Font.small(.medium))
    private let finish = PrimaryButton(title: "Start Browsing")
    private var tokens: [SignalToken] = []
    private var celebrating = false

    /// Starts, or picks up at the step you're on. Nothing happens once every step is done or it was ended.
    static func start(in controller: BrowserWindowController) {
        guard Tutorial.current != nil, !Tutorial.isHidden else { return }
        current?.removeFromSuperview()
        let tour = GuidedTour(controller: controller)
        current = tour
        tour.frame = controller.root.overlay.bounds
        tour.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(tour, positioned: .below, relativeTo: nil)
        tour.showStep(animated: false)
        tour.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            tour.animator().alphaValue = 1
        }
    }

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.addSublayer(dim)
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.strokeColor = Brand.Theme.brand.accent.cgColor
        layer?.addSublayer(ring)
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 18)
        check.contentTintColor = Brand.Theme.brand.accent
        check.isHidden = true
        how.font = Tokens.Font.body()
        how.textColor = Tokens.Color.textSecondary
        how.isSelectable = false
        skip.textColor = Tokens.Color.textTertiary
        card.radius = Tokens.Radius.panel + 2
        [step, close, check, title, how, skip, finish].forEach { card.addSubview($0) }
        addSubview(card)
        close.onClick = { [weak self] _ in
            Tutorial.isHidden = true
            self?.end()
        }
        skip.onClick = { _ in Tutorial.skip() }
        finish.onClick = { [weak self] _ in self?.end() }
        tokens.append(Tutorial.changed.observe { [weak self] in self?.stepDone() })
        // The lit place follows the window: a new tab's row, a resize, the sidebar opening.
        tokens.append(controller.tabManager.changed.observe { [weak self] _ in
            DispatchQueue.main.async { self?.layoutTour(animated: true) }
        })
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Everything outside the card goes straight to the browser, so you can do the step while the guide is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inCard = card.frame.contains(convert(point, from: superview))
        return inCard ? super.hitTest(point) : nil
    }

    private func end() {
        tokens = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    /// A beat with a check on the step you just did, then the next.
    private func stepDone() {
        guard !celebrating else { return }
        celebrating = true
        check.isHidden = false
        title.textColor = Tokens.Color.textSecondary
        layoutCard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.celebrating = false
            self.check.isHidden = true
            self.title.textColor = Tokens.Color.textPrimary
            self.showStep(animated: true)
        }
    }

    /// Where each step happens.
    private func target(for id: String?) -> NSView? {
        guard let controller else { return nil }
        switch id {
        case "newTab": return controller.sidebar.address
        case "pin": return controller.tabManager.selectedTab.flatMap { controller.sidebar.list.rowView(for: $0) } ?? controller.sidebar.list
        case "peek": return controller.root.card
        case "space": return controller.sidebar.newSpaceAnchor
        default: return nil
        }
    }

    private func showStep(animated: Bool) {
        caps.forEach { $0.0.removeFromSuperview() }
        caps = []
        if let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) {
            step.stringValue = "Step \(index + 1) of \(Tutorial.tasks.count)"
            title.stringValue = task.title
            how.stringValue = task.how
            for key in task.keys {
                let cap = ColorView(color: Tokens.Color.fieldFill)
                cap.wantsLayer = true
                cap.layer?.cornerRadius = 6
                cap.layer?.cornerCurve = .continuous
                let label = Label(key, font: .systemFont(ofSize: 13, weight: .semibold), color: Tokens.Color.textPrimary)
                label.alignment = .center
                cap.addSubview(label)
                card.addSubview(cap)
                caps.append((cap, label))
            }
            skip.isHidden = false
            finish.isHidden = true
            close.isHidden = false
        } else {
            step.stringValue = "Getting started"
            title.stringValue = "You’re all set"
            how.stringValue = "That’s the basics. You can see this again anytime from Help › Getting Started."
            skip.isHidden = true
            finish.isHidden = false
            close.isHidden = true
        }
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            card.layer?.add(fade, forKey: "step")
        }
        layoutTour(animated: animated)
    }

    override func layout() {
        super.layout()
        layoutTour(animated: false)
    }

    private var cardSize: NSSize {
        let width: CGFloat = 320, pad = Tokens.Space.x5
        let howHeight = ceil(how.sizeThatFits(NSSize(width: width - pad * 2, height: 200)).height)
        return NSSize(width: width, height: pad + step.lineHeight + Tokens.Space.x2 + title.lineHeight + Tokens.Space.x1 + howHeight
                      + Tokens.Space.x4 + Tokens.Space.x8 + pad)
    }

    private func layoutTour(animated: Bool) {
        let target = self.target(for: Tutorial.current?.id)
        let hole: NSRect = target.flatMap { $0.window != nil ? $0.convert($0.bounds, to: self).insetBy(dx: -5, dy: -5) : nil } ?? .zero
        let cut = CGMutablePath()
        cut.addRect(bounds)
        if hole != .zero { cut.addRoundedRect(in: hole, cornerWidth: 12, cornerHeight: 12) }
        let ringPath: CGPath = hole == .zero ? CGMutablePath() : CGPath(roundedRect: hole, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
        if animated {
            for (layer, path) in [(dim, cut as CGPath), (ring, ringPath)] {
                let move = CABasicAnimation(keyPath: "path")
                move.fromValue = layer.presentation()?.path ?? layer.path
                move.toValue = path
                move.duration = 0.4
                move.timingFunction = ease
                layer.add(move, forKey: "move")
            }
        }
        Tokens.Motion.withoutAnimation {
            dim.frame = bounds
            ring.frame = bounds
            dim.path = cut
            ring.path = ringPath
        }

        let size = cardSize
        var frame: NSRect
        if hole == .zero {
            // The last card stands alone in the middle of the page.
            let page = controller?.root.cardFrame ?? bounds
            frame = NSRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
        } else if let page = controller?.root.cardFrame, hole.width > page.width * 0.6 {
            // A step on the page itself: the card sits inside it, bottom right, out of the way of links.
            frame = NSRect(x: page.maxX - size.width - Tokens.Space.x6, y: page.maxY - size.height - Tokens.Space.x6, width: size.width, height: size.height)
        } else {
            // Beside the lit place, to its right, level with it, kept inside the window.
            let x = min(hole.maxX + Tokens.Space.x4, bounds.width - size.width - Tokens.Space.x4)
            let y = max(Tokens.Space.x4, min(hole.midY - size.height / 2, bounds.height - size.height - Tokens.Space.x4))
            frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = ease
                card.animator().frame = frame
            }
        } else {
            card.frame = frame
        }
        layoutCard()
    }

    private func layoutCard() {
        let width = card.frame.width, pad = Tokens.Space.x5
        let inner = width - pad * 2
        var y = pad
        step.frame = NSRect(x: pad, y: y, width: inner - 30, height: step.lineHeight)
        close.frame.origin = NSPoint(x: width - pad - close.frame.width + Tokens.Space.x1, y: y - 5)
        y = step.frame.maxY + Tokens.Space.x2
        check.frame = NSRect(x: pad, y: y, width: 18, height: 18)
        let tx = check.isHidden ? pad : check.frame.maxX + Tokens.Space.x2
        title.frame = NSRect(x: tx, y: y, width: width - tx - pad, height: title.lineHeight)
        y = title.frame.maxY + Tokens.Space.x1
        let howHeight = ceil(how.sizeThatFits(NSSize(width: inner, height: 200)).height)
        how.frame = NSRect(x: pad, y: y, width: inner, height: howHeight)
        y = how.frame.maxY + Tokens.Space.x4
        var x = pad
        for (cap, label) in caps {
            let w = max(28, label.inkWidth + Tokens.Space.x4)
            cap.frame = NSRect(x: x, y: y + 2, width: w, height: 28)
            label.frame = NSRect(x: 0, y: (28 - label.lineHeight) / 2, width: w, height: label.lineHeight)
            x += w + 4
        }
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: width - pad - sw + Tokens.Space.x2, y: y, width: sw, height: Tokens.Space.x8)
        let fw = max(finish.fittingWidth, 140)
        finish.frame = NSRect(x: width - pad - fw, y: y, width: fw, height: Tokens.Space.x8)
    }
}
