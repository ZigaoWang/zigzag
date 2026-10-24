import AppKit

/// Getting started, in the window itself: one step at a time, the place to act lit up, and a small pill beside
/// it with the keys and three words. It follows along as you do the step (the address bar, a peek), then shows
/// you what changed for a moment before moving on, so nothing happens unnoticed.
final class GuidedTour: NSView {
    private static weak var current: GuidedTour?
    private weak var controller: BrowserWindowController?
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let card = FloatingPanelView()
    private let step = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textTertiary)
    private let check = NSImageView()
    private let title = Label("", font: .systemFont(ofSize: 15, weight: .semibold), color: Tokens.Color.textPrimary)
    private let note = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var caps: [(ColorView, Label)] = []
    private let skip = TextButton(title: "Skip", font: Tokens.Font.small(.medium))
    private let finish = PrimaryButton(title: "Start Browsing")
    // The last card: a note from the person who made Zigzag.
    private let wordmark = WordmarkView()
    private let letter = NSTextField(wrappingLabelWithString: "")
    private let signature = Label("Zigao, who makes Zigzag", font: .systemFont(ofSize: 13, weight: .medium), color: Tokens.Color.textSecondary)
    private var tokens: [SignalToken] = []
    private var watch: Timer?
    private var ending = false

    /// Showing what a step just did, before the next one.
    private var confirming: Tutorial.Task?
    private var sawPeek = false
    /// What the pill shows now, so it only redraws when that changes.
    private var shown = ""
    /// The step the pill was last showing, so its note follows it.
    private var lastStepID: String?

    /// Starts, or picks up at the step you're on. Nothing happens once every step is done or it was ended.
    static func start(in controller: BrowserWindowController) {
        guard Tutorial.current != nil, !Tutorial.isHidden else { return }
        current?.removeFromSuperview()
        let tour = GuidedTour(controller: controller)
        current = tour
        tour.frame = controller.root.overlay.bounds
        tour.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(tour, positioned: .below, relativeTo: nil)
        tour.refresh(animated: false)
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
        dim.fillColor = NSColor.black.withAlphaComponent(0.2).cgColor
        layer?.addSublayer(dim)
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.strokeColor = Brand.Theme.brand.accent.cgColor
        layer?.addSublayer(ring)
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 20)
        check.contentTintColor = Brand.Theme.brand.accent
        skip.textColor = Tokens.Color.textTertiary
        card.radius = Tokens.Radius.panel + 2
        [step, check, title, note, skip, finish, wordmark, letter, signature].forEach { card.addSubview($0) }
        wordmark.color = Brand.Theme.brand.accent
        letter.isSelectable = false
        letter.font = .systemFont(ofSize: 14)
        letter.textColor = Tokens.Color.textPrimary
        letter.stringValue = "Thanks for giving Zigzag a try. I made it to be a calm place for everything you do on the web, and I hope it feels that way.\n\nIf anything feels off, I’d love to hear it. Help › Getting Started walks you through this again anytime."
        
        addSubview(card)
        skip.onClick = { _ in Tutorial.skip() }
        finish.onClick = { [weak self] _ in self?.end() }
        tokens.append(Tutorial.changed.observe { [weak self] in self?.stepDone() })
        tokens.append(controller.tabManager.changed.observe { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(animated: true) }
        })
        // Follows what you're doing: the address bar opening, a peek opening and closing.
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Everything outside the pill goes straight to the browser, so you can do the step while the guide is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        card.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    private func end() {
        ending = true
        watch?.invalidate()
        watch = nil
        tokens = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    // MARK: Following along

    private func tick() {
        guard let controller, !ending else { return }
        // Peek counts once you've closed it again: that's the whole move.
        if confirming == nil, Tutorial.current?.id == "peek" {
            if controller.peek.isVisible { sawPeek = true } else if sawPeek { sawPeek = false; Tutorial.complete("peek") }
        }
        // Other panels (site controls, downloads) come first: the guide steps aside.
        let bar = controller.commandBar.isVisible, peek = controller.peek.isVisible
        let editing = SpaceEditorPanel.current != nil
        let spaceStep = Tutorial.current?.id == "space" || confirming?.id == "space" || Tutorial.current == nil
        let relevant = (bar && Tutorial.current?.id == "newTab") || (peek && Tutorial.current?.id == "peek") || (editing && spaceStep)
        let aside = !relevant && (controller.hasFloatingPanel || peek)
        let alpha: CGFloat = aside ? 0 : 1
        if alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.animator().alphaValue = alpha
            }
        }
        refresh(animated: true)
    }

    /// You did it: the pill turns into a short note on what changed, pointing at it, then the next step.
    private func stepDone() {
        guard confirming == nil else { return }
        confirming = Tutorial.tasks.first { $0.id == lastStepID && Tutorial.done.contains($0.id) }
        refresh(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            self.confirming = nil
            self.refresh(animated: true)
        }
    }

    // MARK: What to show

    private struct Display: Equatable {
        var keys: [String]
        var title: String
        var note: String
        var count: String
        var isDone: Bool
        var isFinal: Bool
        var target: String
    }

    private var display: Display {
        guard let controller else { return Display(keys: [], title: "", note: "", count: "", isDone: false, isFinal: true, target: "") }
        // The + opened the new space's editor: say what it's for, and finish once it's closed.
        if SpaceEditorPanel.current != nil, Tutorial.current == nil || Tutorial.current?.id == "space" {
            return Display(keys: [], title: "Name it and pick a color", note: "", count: "", isDone: false, isFinal: false, target: "editor")
        }
        if let done = confirming {
            return Display(keys: [], title: done.done, note: "", count: "", isDone: true, isFinal: false, target: "done." + done.id)
        }
        guard let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) else {
            return Display(keys: [], title: "You’re all set", note: "", count: "", isDone: false, isFinal: true, target: "")
        }
        let count = "\(index + 1)/\(Tutorial.tasks.count)"
        // Mid-step hints, where you are, for the moment you'd otherwise stall.
        if task.id == "newTab", controller.commandBar.isVisible {
            return Display(keys: ["↩"], title: "Type wikipedia.org, then Return", note: "", count: count, isDone: false, isFinal: false, target: "bar")
        }
        if task.id == "peek", controller.peek.isVisible {
            return Display(keys: ["esc"], title: "Close it", note: "", count: count, isDone: false, isFinal: false, target: "peek")
        }
        return Display(keys: task.keys, title: task.title, note: "", count: count, isDone: false, isFinal: false, target: task.id)
    }

    /// Where to point.
    private func view(for target: String) -> NSView? {
        guard let controller else { return nil }
        let row = controller.tabManager.selectedTab.flatMap { controller.sidebar.list.rowView(for: $0) }
        switch target {
        case "newTab": return controller.sidebar.address
        case "bar": return controller.commandBar.panelView
        case "pin", "done.newTab", "done.pin": return row ?? controller.sidebar.list
        case "peek": return controller.peek.panelView
        case "done.peek": return controller.root.card
        case "space": return controller.sidebar.newSpaceAnchor
        case "editor": return SpaceEditorPanel.current
        case "done.space": return controller.sidebar.dotsAnchor
        default: return nil
        }
    }

    private func refresh(animated: Bool) {
        let now = display
        let key = "\(now)"
        if key != shown {
            shown = key
            if !now.isDone, !now.isFinal { lastStepID = Tutorial.current?.id }
            apply(now, animated: animated)
        }
        layoutTour(now, animated: animated)
    }

    private func apply(_ d: Display, animated: Bool) {
        caps.forEach { $0.0.removeFromSuperview() }
        caps = []
        for key in d.keys {
            let cap = ColorView(color: Tokens.Color.fieldFill)
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 6
            cap.layer?.cornerCurve = .continuous
            let label = Label(key, font: .systemFont(ofSize: 15, weight: .semibold), color: Tokens.Color.textPrimary)
            label.alignment = .center
            cap.addSubview(label)
            card.addSubview(cap)
            caps.append((cap, label))
        }
        title.stringValue = d.title
        note.stringValue = d.note
        step.stringValue = d.count
        check.isHidden = !d.isDone
        skip.isHidden = d.isDone || d.isFinal
        step.isHidden = d.isDone || d.isFinal
        finish.isHidden = !d.isFinal
        note.isHidden = true
        [wordmark, letter, signature].forEach { $0.isHidden = !d.isFinal }
        title.font = d.isFinal ? Brand.displayFont(24) : .systemFont(ofSize: 15, weight: .semibold)
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            card.layer?.add(fade, forKey: "step")
        }
    }

    override func layout() {
        super.layout()
        layoutTour(display, animated: false)
    }

    private func pillSize(_ d: Display) -> NSSize {
        if d.isFinal {
            let inner: CGFloat = 400 - 64
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            return NSSize(width: 400, height: 32 + 26 + 22 + 34 + 12 + lh + 14 + signature.lineHeight + 26 + Tokens.Space.x10 + 32)
        }
        let keys = caps.map { max(34, $0.1.inkWidth + Tokens.Space.x4) }.reduce(0, +) + CGFloat(max(caps.count - 1, 0)) * 4
        var width = Tokens.Space.x4 + (d.isDone ? 20 : keys) + Tokens.Space.x3 + title.textWidth + Tokens.Space.x5
        if !d.isDone { width += step.textWidth + Tokens.Space.x3 + skip.fittingWidth - Tokens.Space.x2 }
        return NSSize(width: ceil(width), height: 56)
    }

    private func layoutTour(_ d: Display, animated: Bool) {
        let target = view(for: d.target)
        let hole: NSRect = target.flatMap { $0.window != nil ? $0.convert($0.bounds, to: self).insetBy(dx: -5, dy: -5) : nil } ?? .zero
        let cut = CGMutablePath()
        cut.addRect(bounds)
        if hole != .zero { cut.addRoundedRect(in: hole, cornerWidth: 12, cornerHeight: 12) }
        let ringPath: CGPath = hole == .zero ? CGMutablePath() : CGPath(roundedRect: hole, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
        if animated, ring.path != ringPath {
            for (layer, path) in [(dim, cut as CGPath), (ring, ringPath)] {
                let move = CABasicAnimation(keyPath: "path")
                move.fromValue = layer.presentation()?.path ?? layer.path
                move.toValue = path
                move.duration = 0.35
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

        let size = pillSize(d)
        let page = controller?.root.cardFrame ?? bounds
        var frame: NSRect
        if hole == .zero {
            frame = NSRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
        } else if d.target == "bar" || d.target == "editor" {
            // Right under the bar or the editor: next to what you're looking at.
            frame = NSRect(x: d.target == "bar" ? hole.midX - size.width / 2 : hole.minX, y: hole.maxY + Tokens.Space.x3, width: size.width, height: size.height)
        } else if d.target == "peek", let sidebar = controller?.root.sidebarContainer.frame, sidebar.width > size.width * 0.8 {
            // The peek fills the page, so the pill waits in the sidebar, clear of it.
            frame = NSRect(x: sidebar.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        } else if hole.width > page.width * 0.6 {
            // The page itself: the pill sits inside it, bottom right, clear of links.
            frame = NSRect(x: page.maxX - size.width - Tokens.Space.x6, y: page.maxY - size.height - Tokens.Space.x6, width: size.width, height: size.height)
        } else {
            // Beside the lit place, to its right, level with it.
            frame = NSRect(x: hole.maxX + Tokens.Space.x4, y: hole.midY - size.height / 2, width: size.width, height: size.height)
        }
        frame.origin.x = min(max(Tokens.Space.x4, frame.origin.x), bounds.width - size.width - Tokens.Space.x4)
        frame.origin.y = min(max(Tokens.Space.x2, frame.origin.y), bounds.height - size.height - Tokens.Space.x4)
        if animated, card.frame != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = ease
                card.animator().frame = frame
            }
        } else {
            card.frame = frame
        }
        layoutPill(d, in: frame.size)
    }

    private func layoutPill(_ d: Display, in size: NSSize) {
        let width = size.width, height = size.height
        if d.isFinal {
            let pad: CGFloat = 32, inner = width - pad * 2
            wordmark.frame = NSRect(x: pad, y: pad, width: 26 * WordmarkView.aspect, height: 26)
            title.frame = NSRect(x: pad, y: wordmark.frame.maxY + 22, width: inner, height: 34)
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            letter.frame = NSRect(x: pad, y: title.frame.maxY + 12, width: inner, height: lh)
            signature.frame = NSRect(x: pad, y: letter.frame.maxY + 14, width: inner, height: signature.lineHeight)
            finish.frame = NSRect(x: pad, y: signature.frame.maxY + 26, width: inner, height: Tokens.Space.x10)
            return
        }
        var x = Tokens.Space.x4
        if d.isDone {
            check.frame = NSRect(x: x, y: (height - 20) / 2, width: 20, height: 20)
            x = check.frame.maxX + Tokens.Space.x3
        }
        for (cap, label) in caps {
            let w = max(34, label.inkWidth + Tokens.Space.x4)
            cap.frame = NSRect(x: x, y: (height - 34) / 2, width: w, height: 34)
            label.frame = NSRect(x: 0, y: (34 - label.lineHeight) / 2, width: w, height: label.lineHeight)
            x += w + 4
        }
        if !caps.isEmpty { x += Tokens.Space.x3 - 4 }
        title.frame = NSRect(x: x, y: (height - title.lineHeight) / 2, width: title.textWidth + 4, height: title.lineHeight)
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: width - Tokens.Space.x2 - sw, y: (height - Tokens.Space.x8) / 2, width: sw, height: Tokens.Space.x8)
        let cw = step.textWidth + 2
        step.frame = NSRect(x: skip.frame.minX - Tokens.Space.x1 - cw, y: (height - step.lineHeight) / 2, width: cw, height: step.lineHeight)
    }
}
