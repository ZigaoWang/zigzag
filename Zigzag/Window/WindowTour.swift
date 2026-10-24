import AppKit

/// The first browser window after onboarding: three short stops that light up the real parts of the window
/// (the sidebar, the space dots, the address) with a card beside each. Runs once; Skip ends it anytime.
final class WindowTour: NSView {
    private struct Stop {
        let title: String
        let body: String
        let target: (BrowserWindowController) -> NSView?
    }

    private static let stops: [Stop] = [
        Stop(title: "Your sidebar", body: "Pinned pages sit at the top and stay put. Tabs open below, and tidy themselves away when you’re done.",
             target: { $0.sidebar.list }),
        Stop(title: "Your spaces", body: "Each dot is a space with its own tabs and pins. Click one, or swipe with two fingers on the sidebar.",
             target: { $0.sidebar.dotsAnchor }),
        Stop(title: "Go anywhere", body: "Type an address or a search here. From anywhere in Zigzag, ⌘T does the same.",
             target: { $0.sidebar.address }),
    ]

    static var hasRun: Bool {
        get { UserDefaults.standard.bool(forKey: "WindowTourShown") }
        set { UserDefaults.standard.set(newValue, forKey: "WindowTourShown") }
    }

    private weak var controller: BrowserWindowController?
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let card = FloatingPanelView()
    private let step = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textTertiary)
    private let title = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let body = NSTextField(wrappingLabelWithString: "")
    private let next = PrimaryButton(title: "Next")
    private let skip = TextButton(title: "Skip", font: Tokens.Font.body(.medium))
    private var index = 0
    private var onDone: (() -> Void)?
    private var keyMonitor: Any?

    static func start(in controller: BrowserWindowController, onDone: @escaping () -> Void) {
        let tour = WindowTour(controller: controller)
        tour.onDone = onDone
        tour.frame = controller.root.overlay.bounds
        tour.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(tour)
        tour.show(0, animated: false)
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
        dim.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        layer?.addSublayer(dim)
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.addSublayer(ring)
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textSecondary
        body.isSelectable = false
        [step, title, body, next, skip].forEach { card.addSubview($0) }
        addSubview(card)
        next.onClick = { [weak self] _ in self?.advance() }
        skip.onClick = { [weak self] _ in self?.finish() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.keyCode {
            case 36, 76, 49: self.advance(); return nil
            case 53: self.finish(); return nil
            default: return event
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // Clicks outside the card don't fall through to the page while the tour is up.
    override func mouseDown(with event: NSEvent) {}

    func advance() {
        if index + 1 < Self.stops.count { show(index + 1, animated: true) } else { finish() }
    }

    private func finish() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Self.hasRun = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onDone?()
        })
    }

    private var holeRect: NSRect {
        guard let controller, let target = Self.stops[index].target(controller), target.window != nil else { return .zero }
        return target.convert(target.bounds, to: self).insetBy(dx: -6, dy: -6)
    }

    private func show(_ i: Int, animated: Bool) {
        index = i
        let stop = Self.stops[i]
        step.stringValue = "\(i + 1) of \(Self.stops.count)"
        title.stringValue = stop.title
        body.stringValue = stop.body
        next.title = i + 1 == Self.stops.count ? "Done" : "Next"
        skip.isHidden = i + 1 == Self.stops.count
        layoutTour(animated: animated)
    }

    override func layout() {
        super.layout()
        layoutTour(animated: false)
    }

    /// The light moves to the next part of the window in one smooth glide; the card follows it.
    private func layoutTour(animated: Bool) {
        let hole = holeRect
        let full = CGPath(rect: bounds, transform: nil)
        let cut = CGMutablePath()
        cut.addPath(full)
        cut.addRoundedRect(in: hole, cornerWidth: 12, cornerHeight: 12)
        let ringPath = CGPath(roundedRect: hole, cornerWidth: 12, cornerHeight: 12, transform: nil)
        if animated {
            for (layer, path) in [(dim, cut as CGPath), (ring, ringPath)] {
                let move = CABasicAnimation(keyPath: "path")
                move.fromValue = layer.presentation()?.path ?? layer.path
                move.toValue = path
                move.duration = 0.4
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
                layer.add(move, forKey: "move")
            }
        }
        Tokens.Motion.withoutAnimation {
            dim.frame = bounds
            ring.frame = bounds
            dim.path = cut
            ring.path = ringPath
        }

        // The card sits beside the lit area, inside the window, its top level with the light's.
        let width: CGFloat = 300, pad = Tokens.Space.x5
        let inner = width - pad * 2
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: inner, height: 200)).height)
        let height = pad + step.lineHeight + Tokens.Space.x1 + title.lineHeight + Tokens.Space.x2 + bodyHeight + Tokens.Space.x5 + Tokens.Space.x8 + pad
        var x = hole.maxX + Tokens.Space.x4
        if x + width > bounds.width - Tokens.Space.x4 { x = max(Tokens.Space.x4, hole.minX - Tokens.Space.x4 - width) }
        var y = hole.minY
        if hole.height < height { y = hole.midY - height / 2 }
        y = max(Tokens.Space.x4, min(y, bounds.height - height - Tokens.Space.x4))
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
                card.animator().frame = frame
            }
        } else {
            card.frame = frame
        }
        var cy = pad
        step.frame = NSRect(x: pad, y: cy, width: inner, height: step.lineHeight)
        cy = step.frame.maxY + Tokens.Space.x1
        title.frame = NSRect(x: pad, y: cy, width: inner, height: title.lineHeight)
        cy = title.frame.maxY + Tokens.Space.x2
        body.frame = NSRect(x: pad, y: cy, width: inner, height: bodyHeight)
        cy = body.frame.maxY + Tokens.Space.x5
        let nw = max(next.fittingWidth, 84)
        next.frame = NSRect(x: width - pad - nw, y: cy, width: nw, height: Tokens.Space.x8)
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: pad - Tokens.Space.x2, y: cy, width: sw, height: Tokens.Space.x8)
    }
}
