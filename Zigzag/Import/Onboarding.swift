import AppKit

/// First launch: a hello, then a few short steps on the brand's blue. Each has a title and one line, the thing to
/// do in the middle, and the same bottom row: Back, Skip, Next.
final class OnboardingView: NSView {
    var onFinish: (() -> Void)?

    /// The space's color comes later, in the browser itself, where you can see it on the real thing.
    enum Step: Int, CaseIterable { case hello, bring, sites, ads, ready }
    private(set) var step = Step.hello

    private let surface = BrandSurface()
    private var page: NSView?

    /// Set if Zigzag has to reopen to pick up a permission: onboarding then picks up on the import step.
    static var resumeOnBring: Bool {
        get { UserDefaults.standard.bool(forKey: "OnboardingResumeOnBring") }
        set { UserDefaults.standard.set(newValue, forKey: "OnboardingResumeOnBring") }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.cornerRadius = 0
        surface.layer?.borderWidth = 0
        surface.showsWatermark = false
        addSubview(surface)
        SitesPicker.preload()
        PageShots.shared.start()
        show(Self.resumeOnBring ? .bring : .hello, animated: false)
        Self.resumeOnBring = false
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var shell: StepPage?

    func show(_ next: Step, animated: Bool) {
        let forward = next.rawValue >= step.rawValue
        step = next
        window?.makeFirstResponder(nil)
        if next == .hello {
            let hello = HelloPage()
            hello.onStart = { [weak self] in self?.show(.bring, animated: true) }
            let old = page
            page = hello
            shell = nil
            hello.frame = bounds
            hello.autoresizingMask = [.width, .height]
            addSubview(hello)
            if animated, let old { slide(from: old, to: hello, forward: false) } else { old?.removeFromSuperview() }
            return
        }
        let content: StepContent
        let title: String, body: String
        switch next {
        case .bring:
            content = BringPicker()
            title = "Bring your stuff over"
            body = "Passwords, bookmarks and history. Your old browser stays as it is."
        case .sites:
            content = SitesPicker()
            title = "Pin the sites you use"
            body = "Each one stays at the top of your sidebar."
        case .ads:
            content = AdsPicker()
            title = "Ad blocking is built in"
            body = "Pages load faster, with fewer trackers."
        default:
            content = ReadyPicker()
            title = "You’re all set"
            body = "One more thing, if you’d like."
        }
        // The steps share one frame: moving between them changes only what's on it.
        let isNew = shell == nil
        let stepPage = shell ?? StepPage(count: Step.allCases.count - 1)
        shell = stepPage
        stepPage.onBack = { [weak self] in
            guard let self, let back = Step(rawValue: next.rawValue - 1) else { return }
            self.show(back, animated: true)
        }
        stepPage.onNext = { [weak self] in
            guard let self else { return }
            if let after = Step(rawValue: next.rawValue + 1) { self.show(after, animated: true) } else { self.onFinish?() }
        }
        if isNew {
            let old = page
            page = stepPage
            stepPage.frame = bounds
            stepPage.autoresizingMask = [.width, .height]
            addSubview(stepPage)
            stepPage.present(title: title, body: body, content: content, index: next.rawValue - 1, showsSkip: next != .ready,
                             forward: forward, animated: false)
            if animated, let old { arrive(from: old, to: stepPage) } else { old?.removeFromSuperview() }
        } else {
            stepPage.present(title: title, body: body, content: content, index: next.rawValue - 1, showsSkip: next != .ready,
                             forward: forward, animated: animated)
        }
    }

    /// From the welcome into the steps: one crossfade.
    private func arrive(from hello: NSView, to steps: StepPage) {
        addSubview(hello, positioned: .above, relativeTo: steps)
        steps.rise()
        Motion.fade(hello, from: 1, to: 0, duration: 0.25, remove: true)
    }

    /// Moving on: the screen you're leaving drifts a little aside as it fades, the next arrives from the other
    /// side. One smooth ease-out, short, no bounce.
    private func slide(from old: NSView, to new: NSView, forward: Bool) {
        [old, new].forEach { $0.wantsLayer = true }
        guard let oldLayer = old.layer, let newLayer = new.layer else { old.removeFromSuperview(); return }
        // With Reduce Motion, a cross-fade in place.
        let distance: CGFloat = 0
        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
        func animation(_ key: String, _ from: Any, _ to: Any, _ duration: CFTimeInterval) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = curve
            return a
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperview() }
        oldLayer.opacity = 0
        oldLayer.add(animation("opacity", 1, 0, 0.22), forKey: "leave.fade")
        oldLayer.add(animation("transform.translation.x", 0, -distance, 0.38), forKey: "leave.move")
        newLayer.add(animation("opacity", 0, 1, 0.34), forKey: "arrive.fade")
        newLayer.add(animation("transform.translation.x", distance, 0, 0.42), forKey: "arrive.move")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        page?.frame = bounds
    }
}

// MARK: - The step layout

/// One step's choice (left), and the picture of what it does (right).
class StepContent: NSView {
    var onChange: (() -> Void)?
    var primaryTitle: String { "Continue" }
    var primaryEnabled: Bool { true }
    var isBusy: Bool { false }
    /// What the step shows on the right: a Zigzag window that changes as you choose.
    let preview = LiveBrowser()
    /// A picture of its own instead of the window, when the window wouldn't explain this step.
    var picture: NSView? { nil }
    /// The main button: do what the step needs, then call `done` to move on (now, or once it's finished).
    func commit(_ done: @escaping () -> Void) { done() }
    /// How tall the step's choice wants to be on the card at this width; the card shrinks or scrolls past that.
    func preferredHeight(for width: CGFloat) -> CGFloat { 300 }
    override var isFlipped: Bool { true }
}

/// Every step the same way: on the left, progress, a title and one line, the choice, and Back · Skip · Continue;
/// on the right, on the brand's blue, a Zigzag window showing what your choice does, so it explains itself.
private final class StepPage: NSView {
    var onBack: (() -> Void)?
    var onNext: (() -> Void)?
    /// The white card the choice sits on, floating on the blue. It stays from step to step and reshapes to fit.
    private let card = ColorView(color: Onboard.paper)
    private var dots: [ColorView] = []
    private var title = Onboard.title("")
    private var body = Onboard.subtitle("")
    private let back = Onboard.quietLight("Back")
    private let next = Onboard.light("Continue")
    private let skip = Onboard.quietLight("Skip")
    private var content = StepContent()
    private var index = 0

    static let cardWidth: CGFloat = 560
    static let cardPad: CGFloat = 20

    init(count: Int) {
        super.init(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 34
            shadow.shadowOffset = NSSize(width: 0, height: -14)
            return shadow
        }()
        for _ in 0..<count {
            let dot = ColorView(color: Brand.ribbon)
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dots.append(dot)
        }
        (dots + [card, back, skip, next] as [NSView]).forEach { addSubview($0) }
        back.onClick = { [weak self] _ in self?.onBack?() }
        skip.onClick = { [weak self] _ in self?.onNext?() }
        next.onClick = { [weak self] _ in
            guard let self else { return }
            self.content.commit { [weak self] in self?.onNext?() }
            self.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Changing step

    func present(title text: String, body bodyText: String, content newContent: StepContent, index newIndex: Int,
                 showsSkip: Bool, forward: Bool, animated: Bool) {
        let old = (title: title, body: body, content: content)
        let first = old.content.superview == nil
        let oldCard = card.frame
        title = Onboard.title(text)
        body = Onboard.subtitle(bodyText)
        content = newContent
        index = newIndex
        [title, body].forEach { addSubview($0) }
        card.addSubview(newContent)
        newContent.onChange = { [weak self] in self?.refresh() }
        skip.isHidden = !showsSkip
        refresh()
        let oldDots = dots.map(\.frame)
        needsLayout = true
        layoutSubtreeIfNeeded()
        let moving = animated && !first && !Tokens.Motion.reduceMotion
        guard moving else {
            [old.title, old.body, old.content].forEach { if $0 !== newContent && $0 !== title && $0 !== body { $0.removeFromSuperview() } }
            return
        }
        // Quiet: the card eases to its new size while the old step fades out and the new one fades in.
        Motion.easeFrame(card, from: oldCard, to: card.frame)
        for (i, view) in dots.enumerated() { Motion.easeFrame(view, from: oldDots[i], to: view.frame) }
        for view in [old.title, old.body, old.content] { Motion.fade(view, from: 1, to: 0, duration: 0.15, remove: true) }
        for view in [title, body, newContent] as [NSView] { Motion.fade(view, from: 0, to: 1, duration: 0.25, delay: 0.1) }
    }

    /// Arriving from the welcome: everything fades in together.
    func rise() {
        guard !Tokens.Motion.reduceMotion else { return }
        Motion.fade(self, from: 0, to: 1, duration: 0.3, delay: 0.1)
    }

    /// The right side follows your space's color as soon as you pick one.
    func retint() {}

    private func refresh() {
        next.title = content.primaryTitle
        next.isEnabled = content.primaryEnabled && !content.isBusy
        skip.isEnabled = !content.isBusy
        back.isEnabled = !content.isBusy
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = Self.cardWidth
        let x = round((bounds.width - width) / 2)
        // Progress at the top: dots, the step you're on drawn long, like the space dots in the sidebar.
        let dotY: CGFloat = 22
        let total = CGFloat(dots.count - 1) * 12 + 22
        var dx = round((bounds.width - total) / 2)
        for (i, dot) in dots.enumerated() {
            let w: CGFloat = i == index ? 22 : 6
            dot.frame = NSRect(x: dx, y: dotY, width: w, height: 6)
            dot.alphaValue = i == index ? 0.95 : i < index ? 0.55 : 0.28
            dx += w + 6
        }
        skip.frame = NSRect(x: bounds.width - 28 - skip.fittingWidth, y: 12, width: skip.fittingWidth, height: Tokens.Space.x8)
        let th = ceil(title.sizeThatFits(NSSize(width: width, height: 200)).height)
        let bh0 = ceil(body.sizeThatFits(NSSize(width: width - 80, height: 200)).height)
        let footY = bounds.height - 40 - Tokens.Space.x10
        let head = th + 10 + bh0 + 28
        let want = head + content.preferredHeight(for: width - Self.cardPad * 2) + Self.cardPad * 2
        // Title and card together, in the middle of the room above the buttons (never under the progress).
        var y = max(76, round((footY - 28 - want) / 2 + 20))
        title.frame = NSRect(x: x, y: y, width: width, height: th)
        y = title.frame.maxY + 10
        let bh = ceil(body.sizeThatFits(NSSize(width: width - 80, height: 200)).height)
        body.frame = NSRect(x: x + 40, y: y, width: width - 80, height: bh)
        y = body.frame.maxY + 28
        let h = Tokens.Space.x10
        let fy = bounds.height - 40 - h
        let inner = width - Self.cardPad * 2
        let room = fy - 28 - y
        let ch = min(room, content.preferredHeight(for: inner) + Self.cardPad * 2)
        card.frame = NSRect(x: x, y: y, width: width, height: ch)
        content.frame = NSRect(x: Self.cardPad, y: Self.cardPad, width: inner, height: ch - Self.cardPad * 2)
        let nw = max(next.fittingWidth + 24, 150)
        next.frame = NSRect(x: x + width - nw, y: fy, width: nw, height: h)
        back.frame = NSRect(x: x - Tokens.Space.x2, y: fy + (h - Tokens.Space.x8) / 2, width: back.fittingWidth, height: Tokens.Space.x8)
    }
}

/// The few fades and resizes onboarding uses, on layers so nothing waits on layout.
private enum Motion {
    static let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)

    static func fade(_ view: NSView, from: Float, to: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0, remove: Bool = false) {
        view.wantsLayer = true
        guard let layer = view.layer else { if remove { view.removeFromSuperview() }; return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.timingFunction = curve
        CATransaction.begin()
        if remove {
            layer.opacity = to
            CATransaction.setCompletionBlock { view.removeFromSuperview() }
        }
        layer.add(a, forKey: "m.fade")
        CATransaction.commit()
    }

    /// From one frame to another, for something that stays and changes shape.
    static func easeFrame(_ view: NSView, from old: NSRect, to new: NSRect) {
        guard old != new, old != .zero, let layer = view.layer else { return }
        for (key, from, to) in [("bounds.size", NSValue(size: old.size), NSValue(size: new.size)),
                                ("position", NSValue(point: layer.position(for: old, in: view)), NSValue(point: layer.position))] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.3
            a.timingFunction = curve
            layer.add(a, forKey: "m.\(key)")
        }
    }
}

private extension CALayer {
    /// Where this layer's position would be with its view at `frame` (the view's parent is flipped, as all of these are).
    func position(for frame: NSRect, in view: NSView) -> CGPoint {
        let current = view.frame
        return CGPoint(x: position.x + (frame.minX - current.minX) + (frame.width - current.width) * anchorPoint.x,
                       y: position.y + (frame.minY - current.minY) + (frame.height - current.height) * anchorPoint.y)
    }
}

/// Colors and controls for the steps (dark on the light left side) and the welcome (light on blue).
private enum Onboard {
    static let paper = Tokens.Color.dynamic(light: .white, dark: Tokens.Color.hex(0x1C1F25))
    static let ink = Tokens.Color.textPrimary
    static let accent = Brand.Theme.brand.accent
    /// Fills and outlines on the light side, used with alpha.
    static let tint = Tokens.Color.dynamic(light: Tokens.Color.hex(0x1E3A5F), dark: Tokens.Color.hex(0xDAE5F2))
    static func dim(_ alpha: CGFloat = 0.72) -> NSColor { Tokens.Color.textPrimary.withAlphaComponent(alpha * 0.85) }

    /// A step's title, on the blue.
    static func title(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = false
        field.font = .systemFont(ofSize: 30, weight: .bold)
        field.textColor = Brand.ribbon
        field.alignment = .center
        return field
    }

    /// The line under a step's title, on the blue.
    static func subtitle(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = false
        field.font = .systemFont(ofSize: 15)
        field.textColor = Brand.ribbon.withAlphaComponent(0.72)
        field.alignment = .center
        return field
    }

    /// Plain text on the white card.
    static func line(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = false
        field.font = .systemFont(ofSize: 14)
        field.textColor = Tokens.Color.textSecondary
        return field
    }

    /// Back and Skip, quiet on the blue.
    static func quietLight(_ title: String) -> TextButton {
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.textColor = Brand.ribbon.withAlphaComponent(0.75)
        return button
    }

    /// The main action on a step: the brand's blue.
    static func primary(_ title: String) -> PrimaryButton {
        let button = PrimaryButton(title: title)
        button.fixedTheme = Brand.Theme.brand
        return button
    }

    /// The welcome's one button: light on the blue.
    static func light(_ title: String) -> PrimaryButton {
        let button = PrimaryButton(title: title)
        button.customFill = Brand.ribbon
        button.customInk = Brand.navy
        return button
    }

    static func quiet(_ title: String) -> TextButton {
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.textColor = Tokens.Color.textSecondary
        return button
    }
}

// MARK: - 1. Hello

/// "Welcome to", then the wordmark writing itself in, then one button. Nothing else on the screen moves.
private final class HelloPage: NSView {
    var onStart: (() -> Void)?
    private let welcome = Label("Welcome to", font: .systemFont(ofSize: 18, weight: .medium), color: Brand.ribbon.withAlphaComponent(0.78))
    private let wordmark = WordmarkView()
    private let start = Onboard.light("Get Started")
    private var drewIn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        welcome.alignment = .center
        wordmark.color = Brand.ribbon
        start.onClick = { [weak self] _ in self?.onStart?() }
        [welcome, wordmark, start].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !drewIn else { return }
        drewIn = true
        layoutSubtreeIfNeeded()
        welcome.alphaValue = 0
        start.alphaValue = 0
        let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
        func fadeIn(_ view: NSView, after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    ctx.timingFunction = ease
                    view.animator().alphaValue = 1
                }
            }
        }
        fadeIn(welcome, after: 0.15)
        wordmark.drawIn(delay: 0.4, total: 1.1)
        fadeIn(start, after: 1.6)
    }

    override func layout() {
        super.layout()
        let markHeight: CGFloat = 72
        let markWidth = markHeight * WordmarkView.aspect
        let h = Tokens.Space.x10
        let total = welcome.lineHeight + Tokens.Space.x5 + markHeight + Tokens.Space.x16 + h
        var y = round((bounds.height - total) / 2) - Tokens.Space.x4
        welcome.frame = NSRect(x: 0, y: y, width: bounds.width, height: welcome.lineHeight)
        y = welcome.frame.maxY + Tokens.Space.x5
        wordmark.frame = NSRect(x: round((bounds.width - markWidth) / 2), y: y, width: markWidth, height: markHeight)
        y = wordmark.frame.maxY + Tokens.Space.x16
        let w: CGFloat = 176
        start.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: h)
    }
}

/// One kind of data to bring (passwords, bookmarks…): a check and a word, light on the blue.
private final class DataToggle: InteractiveView {
    var isOn = true { didSet { refresh() } }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    var isLocked = false { didSet { refresh() } }
    var onChange: (() -> Void)?
    private let check = NSImageView()
    private let label: Label

    init(_ title: String) {
        label = Label(title, font: Tokens.Font.small(.medium), color: Onboard.ink)
        super.init(frame: .zero)
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        check.image = Tokens.Symbol.image("checkmark", size: 9)
        [check, label].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked else { return }
            self.isOn.toggle()
            self.onChange?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat { ceil(Tokens.Space.x3 + 10 + Tokens.Space.x1 + label.inkWidth + Tokens.Space.x3) }

    private func refresh() {
        layer?.backgroundColor = Onboard.tint.withAlphaComponent(isOn ? 0.16 : 0).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Onboard.tint.withAlphaComponent(isOn ? 0 : 0.25).cgColor
        label.textColor = isOn ? Onboard.ink : Onboard.dim(0.55)
        check.contentTintColor = Onboard.ink
        check.isHidden = !isOn
        alphaValue = isLocked ? 0.5 : 1
        needsLayout = true
    }

    override func stateDidChange(animated: Bool) {
        guard !isLocked else { return }
        if isHovered && !isOn { layer?.backgroundColor = Onboard.tint.withAlphaComponent(0.07).cgColor } else { refresh() }
    }

    override func layout() {
        super.layout()
        let x = Tokens.Space.x3
        check.frame = NSRect(x: x, y: (bounds.height - 10) / 2, width: 10, height: 10)
        let lx = isOn ? check.frame.maxX + Tokens.Space.x1 : x + 7
        label.frame = NSRect(x: lx - Label.inset, y: (bounds.height - label.lineHeight) / 2, width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }
}

/// One browser: checkbox, icon, name and what it holds; then progress, what came over, or the problem in full.
private final class BrowserRow: InteractiveView {
    enum State { case idle, waiting, working, done(ImportCoordinator.Summary) }
    private(set) var source: ImportCoordinator.Source
    var isChosen = false { didSet { refresh() } }
    override func accessibilityValue() -> Any? { isChosen ? 1 : 0 }
    var isLocked = false { didSet { refresh() } }
    var onChange: (() -> Void)?
    var onFix: ((ImportProblem.Fix) -> Void)?
    var state = State.idle { didSet { refresh() } }
    /// macOS keeps this browser's files private until you allow Zigzag (macOS 27 does this for Chrome and others).
    private(set) var needsAccess = false

    var isFinished: Bool { if case .done(let s) = state { s.problems.isEmpty } else { false } }
    var hasProblem: Bool { if case .done(let s) = state { !s.problems.isEmpty } else { needsAccess } }

    private let box = ColorView(color: .clear)
    private let tick = NSImageView()
    private let icon = NSImageView()
    private let name: Label
    private let detail = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.62))
    private let status = Label("", font: Tokens.Font.small(.medium), color: Onboard.ink)
    private let doneMark = NSImageView(image: Tokens.Symbol.image("checkmark.circle.fill", size: 18))
    private let spinner = RibbonView()
    private let fixButton = Onboard.primary("")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private var fixKind = ImportProblem.Fix.none

    init(source: ImportCoordinator.Source) {
        self.source = source
        name = Label(source.name, font: Tokens.Font.body(.semibold), color: Onboard.ink)
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1.5
        tick.image = Tokens.Symbol.image("checkmark", size: 10)
        tick.contentTintColor = NSColor.white
        box.addSubview(tick)
        icon.image = source.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        detail.lineBreakMode = .byTruncatingTail
        status.alignment = .right
        spinner.color = Onboard.ink
        fixButton.onClick = { [weak self] _ in
            guard let self else { return }
            if self.waitingForSettings { self.recheckAccess(); return }
            self.onFix?(self.fixKind)
        }
        problem.font = Tokens.Font.small()
        problem.textColor = Tokens.Color.caution
        problem.isSelectable = false
        doneMark.contentTintColor = Tokens.Color.success
        doneMark.isHidden = true
        [box, icon, name, detail, status, spinner, fixButton, problem, doneMark].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked, !self.isFinished else { return }
            self.isChosen.toggle()
            self.onChange?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(source.name)
        Task { @MainActor [weak self] in
            let text = await ImportCoordinator.preview(source)
            guard let self, case .idle = self.state else { return }
            if text.contains("permission") {
                // Found before starting, so it's fixed first instead of failing midway. A browser you use stays
                // checked: Import asks for the OK, then carries on, rather than quietly leaving it behind.
                self.needsAccess = true
                self.detail.stringValue = "Needs your OK once"
                self.fixKind = .fullDiskAccess
                self.onChange?()
            } else {
                self.detail.stringValue = text.replacingOccurrences(of: " Passwords come from the Passwords app.", with: "")
            }
            self.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static func isSafari(_ source: ImportCoordinator.Source) -> Bool { if case .safari = source.kind { true } else { false } }

    private var isSafari: Bool { if case .safari = source.kind { true } else { false } }
    /// Allowing through the folder panel comes first; if macOS still says no, the switch in System Settings.
    var triedPicker = false
    /// Access was just allowed: the list may now split this browser into its profiles.
    var onGranted: (() -> Void)?
    private var waitingForSettings = false

    func awaitSettings() {
        waitingForSettings = true
        refresh()
    }

    /// Opens one of the browser's files for real, so macOS records the attempt (and lists the browser under
    /// Zigzag in Files & Folders) instead of only being asked whether it would be allowed.
    private func touchFiles() async {
        guard case .chromium(let browser) = source.kind else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(browser.root)")
        await Task.detached {
            for name in ["Local State", "Default/Bookmarks"] {
                if let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(name)) { try? handle.close() }
            }
        }.value
    }

    /// After you've allowed it: read what it holds again, and pick it if it can come over now.
    func recheckAccess() {
        Task { @MainActor in
            await touchFiles()
            let text = await ImportCoordinator.preview(source)
            if text.contains("permission") {
                note(waitingForSettings ? "Not yet. In Files & Folders, under Zigzag, turn on \(source.name), then click Check Again."
                                        : "macOS still keeps it private. One switch in System Settings fixes it.")
            } else {
                needsAccess = false
                waitingForSettings = false
                onGranted?()
                problem.stringValue = ""
                detail.stringValue = text
                isChosen = true
                onChange?()
            }
            refresh()
            superview?.superview?.needsLayout = true
        }
    }

    /// Safari's export stands in for Safari itself: it holds passwords, bookmarks and history.
    func useFile(_ url: URL) {
        source = ImportCoordinator.fileSource(url)
        needsAccess = false
        isChosen = true
        detail.stringValue = url.lastPathComponent
    }

    /// A line under the row, for a step to take.
    func note(_ text: String) {
        problem.stringValue = text
        problem.textColor = Onboard.dim(0.8)
        needsLayout = true
        superview?.superview?.needsLayout = true
    }

    private static let rowHeight: CGFloat = 50

    func height(for width: CGFloat) -> CGFloat {
        guard !problem.stringValue.isEmpty else { return Self.rowHeight }
        let h = ceil(problem.sizeThatFits(NSSize(width: width - 62 - Tokens.Space.x4, height: 200)).height)
        return Self.rowHeight + h + Tokens.Space.x3
    }

    private func refresh() {
        spinner.stopLooping()
        spinner.isHidden = true
        status.isHidden = true
        fixButton.isHidden = true
        switch state {
        case .idle:
            if needsAccess {
                fixButton.title = waitingForSettings ? "Check Again" : triedPicker && !isSafari ? "Settings" : "Allow"
                fixButton.isHidden = false
            }
        case .waiting:
            status.stringValue = "Waiting"
            status.textColor = Onboard.dim(0.6)
            status.isHidden = !isChosen
        case .working:
            spinner.isHidden = false
            spinner.startLooping()
        case .done(let summary):
            if let first = summary.problems.first {
                problem.stringValue = summary.problems.map(\.message).joined(separator: " ")
                problem.textColor = Tokens.Color.caution
                fixKind = first.fix
                switch first.fix {
                case .retry: fixButton.title = "Try Again"
                case .fullDiskAccess: fixButton.title = "Allow Access"
                case .primaryPassword: fixButton.title = "Unlock"
                case .exportFromApplePasswords: fixButton.title = "Show Me How"
                case .none: break
                }
                fixButton.isHidden = first.fix == .none
            } else {
                problem.stringValue = ""
                status.stringValue = ""
                status.isHidden = true
                doneMark.isHidden = false
                detail.stringValue = Self.sentence(summary)
            }
        }
        let on = isChosen || isFinished
        box.layer?.backgroundColor = on ? Onboard.accent.cgColor : nil
        box.layer?.borderColor = Onboard.tint.withAlphaComponent(on ? 1 : 0.45).cgColor
        tick.isHidden = !on
        box.alphaValue = (needsAccess || isLocked) && !isChosen ? 0.35 : 1
        stateDidChange(animated: false)
        needsLayout = true
    }

    /// "6 passwords, 3 spaces and 58 bookmarks".
    private static func sentence(_ s: ImportCoordinator.Summary) -> String {
        func n(_ v: Int, _ one: String, _ many: String) -> String? { v > 0 ? "\(v.formatted()) \(v == 1 ? one : many)" : nil }
        let parts = [n(s.passwords + s.updatedPasswords, "password", "passwords"), n(s.spaces, "space", "spaces"),
                     n(s.bookmarks, "bookmark", "bookmarks"), n(s.history, "page of history", "pages of history")].compactMap { $0 }
        return parts.isEmpty ? "Nothing new: it was already here" : ListFormatter.localizedString(byJoining: parts)
    }

    override func stateDidChange(animated: Bool) {
        let interactive = !isLocked && !isFinished
        layer?.backgroundColor = interactive && isHovered ? Onboard.tint.withAlphaComponent(isPressed ? 0.1 : 0.05).cgColor : nil
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x4
        let top = Self.rowHeight
        box.frame = NSRect(x: pad, y: (top - 18) / 2, width: 18, height: 18)
        tick.frame = box.bounds.insetBy(dx: 3, dy: 3)
        icon.frame = NSRect(x: box.frame.maxX + Tokens.Space.x3, y: (top - 30) / 2, width: 30, height: 30)
        let x = icon.frame.maxX + Tokens.Space.x3
        var right = bounds.width - pad
        // The fix sits on the browser's line, at the right; what went wrong reads underneath.
        let buttonBelow = false
        if !fixButton.isHidden, !buttonBelow {
            let w = fixButton.fittingWidth
            right -= w
            fixButton.frame = NSRect(x: right, y: (top - Tokens.Space.x7Height) / 2, width: w, height: Tokens.Space.x7Height)
            right -= Tokens.Space.x3
        }
        if !spinner.isHidden {
            right -= 18
            spinner.frame = NSRect(x: right, y: (top - 18) / 2, width: 18, height: 18)
            right -= Tokens.Space.x3
        }
        if !doneMark.isHidden {
            right -= 18
            doneMark.frame = NSRect(x: right, y: (top - 18) / 2, width: 18, height: 18)
            right -= Tokens.Space.x3
        }
        if !status.isHidden {
            let w = status.textWidth + 2
            right -= w
            status.frame = NSRect(x: right, y: (top - status.lineHeight) / 2, width: w, height: status.lineHeight)
            right -= Tokens.Space.x3
        }
        let block = name.lineHeight + 1 + detail.lineHeight
        name.frame = NSRect(x: x, y: (top - block) / 2, width: right - x, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: name.frame.maxY + 1, width: right - x, height: detail.lineHeight)
        problem.isHidden = problem.stringValue.isEmpty
        let ph = ceil(problem.sizeThatFits(NSSize(width: bounds.width - x - pad, height: 200)).height)
        problem.frame = NSRect(x: x, y: top - Tokens.Space.x2, width: bounds.width - x - pad, height: ph)
        if buttonBelow {
            let w = fixButton.fittingWidth
            fixButton.frame = NSRect(x: x, y: problem.frame.maxY + Tokens.Space.x2, width: w, height: Tokens.Space.x7Height)
        }
    }
}

// MARK: - Bring your stuff

/// The browsers on this Mac, each with a checkbox, what it holds, and how its import went. Anything macOS keeps
/// private says so before you start, with the fix beside it.
private final class BringPicker: StepContent {
    private let arrow = IntoZigzag()
    override var picture: NSView? { arrow }
    private let list = ColorView(color: .clear)
    private var rows: [BrowserRow] = []
    private var separators: [ColorView] = []
    private let empty = Onboard.line("No other browsers with something to bring were found on this Mac.")
    private let hint = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.7))
    private let bringLabel = Label("Bring", font: Tokens.Font.small(.medium), color: Onboard.dim(0.6))
    private var pills: [(ImportCoordinator.Choice, DataToggle)] = []
    private let fileLink = Onboard.quiet("Import a password file")
    private var isImporting = false
    /// Many browsers or profiles: the list scrolls inside its box instead of running into the buttons.
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.borderWidth = 0
        scroll.layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.useSlimScroller()
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.contentView = FlippedClipView()
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        hint.alignment = .center
        [scroll, bringLabel, fileLink, hint].forEach { addSubview($0) }
        let sources = ImportCoordinator.detectedSources()
        let suggested = ImportCoordinator.suggested(sources)
        // The browser you use comes first, already checked.
        for source in sources.filter({ suggested.contains($0.id) }) + sources.filter({ !suggested.contains($0.id) }) {
            add(source, chosen: suggested.contains(source.id))
        }
        if rows.isEmpty { addSubview(empty) }
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & tabs")] {
            let pill = DataToggle(name)
            pill.onChange = { [weak self] in self?.refresh() }
            addSubview(pill)
            pills.append((choice, pill))
        }
        fileLink.onClick = { [weak self] _ in self?.pickFile() }
        // Everything comes over; choosing what (and password files) lives in the Import window in Settings.
        pills.forEach { $0.1.isHidden = true }
        fileLink.isHidden = true
        bringLabel.isHidden = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTitle: String { isImporting ? "Importing…" : waiting.isEmpty ? "Next" : "Import" }
    override var primaryEnabled: Bool { waiting.isEmpty || !choice.isEmpty }
    override var isBusy: Bool { isImporting }

    override func commit(_ done: @escaping () -> Void) {
        let toDo = waiting
        if toDo.isEmpty { done(); return }
        // A checked browser macOS still keeps private: ask for the OK first, and import once it's given.
        if let locked = toDo.first(where: \.needsAccess) {
            importAfterAccess = true
            allow(locked)
            return
        }
        // Importing stays on this step, so you see what came over; Next then moves on.
        run(toDo)
    }

    @discardableResult
    private func add(_ source: ImportCoordinator.Source, chosen: Bool) -> BrowserRow {
        let row = BrowserRow(source: source)
        row.isChosen = chosen
        row.onChange = { [weak self] in self?.refresh() }
        row.onFix = { [weak self, weak row] fix in
            guard let self, let row else { return }
            self.fix(fix, row)
        }
        row.onGranted = { [weak self, weak row] in
            guard let self, let row else { return }
            self.splitIntoProfiles(row)
            if self.importAfterAccess, !self.waiting.contains(where: \.needsAccess) {
                self.importAfterAccess = false
                if !self.waiting.isEmpty { self.run(self.waiting) }
            }
        }
        list.addSubview(row)
        rows.append(row)
        if rows.count > 1 {
            let line = ColorView(color: Onboard.tint.withAlphaComponent(0.09))
            list.addSubview(line)
            separators.append(line)
        }
        return row
    }

    /// Once a browser can be read, several profiles become several rows ("Chrome (Work)"), each its own choice.
    private func splitIntoProfiles(_ row: BrowserRow) {
        guard case .chromium(let browser) = row.source.kind, browser.profile == nil, browser.name != "Arc",
              let index = rows.firstIndex(where: { $0 === row }) else { return }
        let profiles = ChromiumImporter.profileNames(of: browser)
        guard profiles.count > 1 else { return }
        let split = profiles.map { folder, name in
            ImportCoordinator.Source(kind: .chromium(browser.only(folder, named: name)), name: "\(browser.name) (\(name))", bundleID: browser.bundleID)
        }
        // The profiles in use stay checked; an old, empty one doesn't come along.
        let wanted = row.isChosen ? ImportCoordinator.suggested(split) : []
        row.removeFromSuperview()
        rows.remove(at: index)
        separators.forEach { $0.removeFromSuperview() }
        separators = []
        let all = rows
        rows = []
        for (k, old) in all.enumerated() {
            if k == index { for source in split { add(source, chosen: wanted.contains(source.id)) } }
            old.removeFromSuperview()
            rows.append(old)
            list.addSubview(old)
            if rows.count > 1 { let line = ColorView(color: Onboard.tint.withAlphaComponent(0.09)); list.addSubview(line); separators.append(line) }
        }
        if index >= all.count { for source in split { add(source, chosen: wanted.contains(source.id)) } }
        refresh()
    }

    /// Import was pressed while a checked browser still needed macOS's OK: it goes ahead once that's given.
    private var importAfterAccess = false

    /// Chosen and not yet imported. A row that came over with a problem is retried from its own fix, never by
    /// importing everything from it again.
    private var waiting: [BrowserRow] { rows.filter { row in if case .done = row.state { false } else { row.isChosen } } }
    private var choice: ImportCoordinator.Choice { pills.reduce(into: []) { r, p in if p.1.isOn { r.insert(p.0) } } }

    private func refresh() {
        pills.forEach { $0.1.isHidden = true }
        arrow.show(rows.filter(\.isChosen).map(\.source.icon))
        rows.forEach { $0.isLocked = isImporting }
        let problems = rows.contains { if case .done(let s) = $0.state { !s.problems.isEmpty } else { false } }
        hint.stringValue = isImporting ? "macOS will ask for your Mac’s password to open your passwords. Type it, then click Always Allow."
            : problems ? "Not everything came over yet." : ""
        needsLayout = true
        onChange?()
    }

    private func run(_ rows: [BrowserRow], only: ImportCoordinator.Choice? = nil) {
        isImporting = true
        arrow.set(.importing)
        rows.forEach { $0.state = .waiting }
        refresh()
        let choice = only ?? self.choice
        let started = Date()
        Task { @MainActor in
            for row in rows {
                row.state = .working
                var wanted = choice.intersection(row.source.offers)
                let isSafari: Bool = { if case .safari = row.source.kind { true } else { false } }()
                // Safari's passwords live in the Passwords app, which only it can read; the row says how to bring them.
                if isSafari { wanted.remove(.passwords) }
                let summary = await ImportCoordinator.run(row.source, wanted)
                row.state = .done(summary)
                if isSafari, choice.contains(.passwords), summary.problems.isEmpty {
                    row.note("Safari’s passwords are in the Passwords app. Export them there, then use Import a password file.")
                }
                self.needsLayout = true
            }
            // A quick import still shows the wave for two full rounds, so it reads as work done, not a flicker.
            let shortest = IntoZigzag.wave * 2
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < shortest { try? await Task.sleep(for: .seconds(shortest - elapsed)) }
            self.isImporting = false
            let failed = rows.contains { if case .done(let s) = $0.state { !s.problems.isEmpty } else { false } }
            self.arrow.set(failed ? .idle : .done)
            self.refresh()
        }
    }

    private func fix(_ fix: ImportProblem.Fix, _ row: BrowserRow) {
        switch fix {
        case .retry:
            row.isChosen = true
            var only: ImportCoordinator.Choice?
            if case .done(let summary) = row.state { only = ImportCoordinator.Choice.retrying(summary.problems, else: choice) }
            run([row], only: only)
        case .fullDiskAccess:
            allow(row)
        case .primaryPassword, .exportFromApplePasswords:
            // These need a password or an export file; the Import window walks through both.
            ImportWindowController.show()
        case .none:
            break
        }
        needsLayout = true
    }

    /// macOS opens a browser's private folder to an app once you pick that folder yourself. The panel opens on
    /// it already, so it's one click on Allow.
    private func allow(_ row: BrowserRow) {
        guard let window else { return }
        switch row.source.kind {
        case .chromium(let browser) where row.triedPicker:
            // macOS 27 keeps some browsers' folders private unless you switch them on, under Zigzag, in
            // Privacy & Security › Files & Folders.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
            row.note("In Files & Folders, find Zigzag and turn on \(browser.name). Then come back and click Check Again.")
            row.awaitSettings()
        case .chromium(let browser):
            row.triedPicker = true
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(browser.root)")
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = folder.deletingLastPathComponent()
            panel.prompt = "Allow"
            panel.message = "Click Allow to let Zigzag read \(browser.name)’s bookmarks and passwords. Nothing in \(browser.name) changes."
            panel.beginSheetModal(for: window) { [weak self, weak row] _ in
                guard let self, let row else { return }
                row.recheckAccess()
                self.refresh()
            }
            DispatchQueue.main.async { panel.directoryURL = folder }
        case .safari:
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = folder
            panel.prompt = "Allow"
            panel.message = "Click Allow to let Zigzag read Safari’s bookmarks and history. Nothing in Safari changes."
            panel.beginSheetModal(for: window) { [weak self, weak row] _ in
                guard let self, let row else { return }
                row.recheckAccess()
                self.refresh()
            }
        default:
            break
        }
    }

    /// A CSV from a password manager (1Password, Bitwarden…) or Safari's export.
    private func pickFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .zip]
        panel.message = "Choose a password export (a .csv file) or Safari’s exported browsing data (a .zip file)."
        panel.prompt = "Import"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let row = self.add(ImportCoordinator.fileSource(url), chosen: true)
            self.run([row])
        }
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let list = rows.isEmpty ? 40 : rows.map { $0.height(for: width) }.reduce(0, +)
        return list + (hint.stringValue.isEmpty ? 0 : hint.lineHeight + Tokens.Space.x3)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 0
        let width = bounds.width
        var ry: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let h = row.height(for: width)
            row.frame = NSRect(x: 0, y: ry, width: width, height: h)
            ry += h
            if i < separators.count { separators[i].frame = NSRect(x: 62, y: ry, width: width - 62, height: Tokens.Metric.hairline) }
        }
        // The list, the choice of what to bring, and the file link, as one block in the middle.
        let block = ry + Tokens.Space.x5 + Tokens.Space.x8 + Tokens.Space.x3 + Tokens.Space.x8
        var y: CGFloat = 0
        _ = block
        scroll.isHidden = rows.isEmpty
        let room = bounds.height - (hint.stringValue.isEmpty ? 0 : hint.lineHeight + Tokens.Space.x3)
        scroll.frame = NSRect(x: pad, y: y, width: width, height: min(ry, max(room, 0)))
        list.frame = NSRect(x: 0, y: 0, width: width, height: ry)
        if rows.isEmpty {
            empty.frame = NSRect(x: pad, y: y, width: width, height: 40)
            ry = 40
        }
        y += ry + Tokens.Space.x5
        _ = y
        let fw = fileLink.fittingWidth
        fileLink.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: fw, height: Tokens.Space.x8)
        hint.alignment = .left
        hint.frame = NSRect(x: 0, y: bounds.height - hint.lineHeight, width: width, height: hint.lineHeight)
    }
}

/// The import step's picture: the browsers you've picked, the way across, and Zigzag. While importing, dots
/// run along the way across; when it's done, Zigzag gets a check.
final class IntoZigzag: NSView {
    enum State { case idle, importing, done }
    /// One round of the importing wave, in seconds.
    static let wave: Double = 1.6
    #if DEBUG
    static weak var shown: IntoZigzag?
    #endif
    private var sources: [NSImageView] = []
    private let zigzag = NSImageView()
    private var dots: [CALayer] = []
    private let badge = NSImageView()
    private let caption = Label("", font: .systemFont(ofSize: 15, weight: .semibold), color: Brand.ribbon)
    private var state = State.idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        zigzag.image = NSApp.applicationIconImage
        zigzag.wantsLayer = true
        #if DEBUG
        Self.shown = self
        #endif
        badge.image = Tokens.Symbol.image("checkmark.circle.fill", size: 38)
        badge.contentTintColor = Tokens.Color.success
        badge.wantsLayer = true
        badge.isHidden = true
        caption.alignment = .center
        [zigzag, badge, caption].forEach { addSubview($0) }
        for _ in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = Brand.ribbon.withAlphaComponent(0.6).cgColor
            dot.cornerRadius = 4
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(_ icons: [NSImage]) {
        sources.forEach { $0.removeFromSuperview() }
        sources = icons.map { image in
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            addSubview(view)
            return view
        }
        needsLayout = true
    }

    func set(_ new: State) {
        guard new != state else { return }
        state = new
        // One wave rolls toward Zigzag over and over while it works: every dot is already moving, each a step
        // behind the one before.
        let period = Self.wave
        let now = CACurrentMediaTime()
        // Where each dot is right now, so finishing fades from there instead of snapping.
        let showing = dots.map { $0.presentation()?.opacity ?? $0.opacity }
        for (i, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            guard new == .importing else { continue }
            // A ripple: each dot swells and fades in turn, overlapping the next, then all three rest a moment
            // before the next ripple, so it breathes instead of chasing its tail.
            let samples = 64
            let start = Double(i) * 0.17, width = 0.42
            let bump = (0...samples).map { k -> Double in
                let t = (Double(k) / Double(samples) - start) / width
                guard t > 0, t < 1 else { return 0 }
                return 0.5 - 0.5 * cos(2 * .pi * t)
            }
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = bump.map { 0.25 + 0.75 * $0 }
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = bump.map { 1 + 0.3 * $0 }
            let both = CAAnimationGroup()
            // With Reduce Motion, the dots only glow in turn; nothing swells.
            both.animations = Tokens.Motion.reduceMotion ? [glow] : [glow, grow]
            both.duration = period
            both.repeatCount = .infinity
            both.timingFunction = CAMediaTimingFunction(name: .linear)
            both.beginTime = now
            dot.add(both, forKey: "run")
        }
        caption.stringValue = new == .importing ? "Bringing it over…" : new == .done ? "All in Zigzag" : ""
        badge.isHidden = true
        if new == .done {
            // Each browser glides into Zigzag and fades, one after another; then Zigzag gets a little pop.
            let target = zigzag.frame
            for (k, view) in sources.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.07) {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.45
                        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.3, 1)
                        if !Tokens.Motion.reduceMotion { view.animator().frame = target.insetBy(dx: 26, dy: 26) }
                        view.animator().alphaValue = 0
                    }, completionHandler: { view.removeFromSuperview() })
                }
            }
            // The wave fades out where it is, rather than vanishing mid-step.
            for (dot, from) in zip(dots, showing) {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = from
                out.toValue = 0
                out.duration = 0.3
                out.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dot.add(out, forKey: "out")
                dot.opacity = 0
            }
            let delay = 0.45 + Double(max(sources.count - 1, 0)) * 0.07
            sources = []
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let layer = self.zigzag.layer else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.5
                    ctx.allowsImplicitAnimation = true
                    self.layoutSubtreeIfNeeded()
                }
                guard !Tokens.Motion.reduceMotion else { self.needsLayout = true; return }
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.9
                pop.toValue = 1
                pop.damping = 10
                pop.duration = pop.settlingDuration
                layer.add(pop, forKey: "pop")
                self.needsLayout = true
            }
            return
        }
        if new == .done, let layer = badge.layer {
            // The check lands with a little give, once.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.3
            pop.toValue = 1
            pop.damping = 11
            pop.initialVelocity = 6
            pop.duration = pop.settlingDuration
            layer.add(pop, forKey: "pop")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Every icon the same size: the browsers in a little fanned stack, then the way across, then Zigzag.
        let size: CGFloat = 104, way: CGFloat = 96
        // Every browser you picked, however many: the stack tightens to keep the row inside the panel.
        let room = bounds.width - 64 - way - size - size
        let step = sources.count > 1 ? min(30, max(10, room / CGFloat(sources.count - 1))) : 0
        let stack = sources.isEmpty ? 0 : size + CGFloat(sources.count - 1) * step
        let row = sources.isEmpty ? size : stack + way + size
        var x = round((bounds.width - row) / 2)
        let top = round(bounds.height / 2 - size / 2) - 16
        for (k, view) in sources.enumerated() {
            view.frame = NSRect(x: x + CGFloat(k) * step, y: top, width: size, height: size)
            view.wantsLayer = true
            // A slight fan: each one turned a touch, the newest flat on top.
            let turn = CGFloat(sources.count - 1 - k) * -0.06
            view.frameCenterRotation = turn * 180 / .pi
        }
        x += stack
        let mid = top + size / 2
        Tokens.Motion.withoutAnimation {
            for (i, dot) in dots.enumerated() {
                dot.isHidden = sources.isEmpty && state != .done
                dot.frame = CGRect(x: x + (way - 8 * 3 - 12 * 2) / 2 + CGFloat(i) * 20, y: mid - 4, width: 8, height: 8)
                dot.opacity = state == .importing ? 0.2 : state == .done ? 0 : 0.6
            }
        }
        if !sources.isEmpty { x += way }
        zigzag.frame = NSRect(x: x, y: top, width: size, height: size)
        // Done: the dots give way to one check, halfway across.
        badge.frame = NSRect(x: x - way / 2 - 20, y: mid - 20, width: 40, height: 40)
        caption.frame = NSRect(x: 0, y: top + size + 28, width: bounds.width, height: caption.lineHeight)
        if state == .done {
            let check = NSTextAttachment()
            let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white, Tokens.Color.success])))
            check.image = symbol
            let text = NSMutableAttributedString(attachment: check)
            text.append(NSAttributedString(string: "  All in Zigzag", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Brand.ribbon]))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            caption.attributedStringValue = text
        }
    }
}

// MARK: - Tiles

/// A square you tap to pick: an icon over a name, and a check when it's picked. Light on the blue.
private final class PickTile: InteractiveView {
    var isPicked = false { didSet { refresh() } }
    override func accessibilityValue() -> Any? { isPicked ? 1 : 0 }
    var isLocked = false { didSet { refresh() } }
    var onToggle: (() -> Void)?
    let icon = NSImageView()
    private let name: Label
    let detail = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.6))
    private let check = NSImageView()
    private let spinner = RibbonView()
    private let horizontal: Bool

    init(name text: String, horizontal: Bool = false) {
        name = Label(text, font: Tokens.Font.body(.medium), color: Onboard.ink)
        self.horizontal = horizontal
        super.init(frame: .zero)
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = horizontal ? .left : .center
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 18)
        check.wantsLayer = true
        check.layer?.backgroundColor = NSColor.white.cgColor
        check.layer?.cornerRadius = 9
        check.contentTintColor = Onboard.ink
        spinner.color = Onboard.ink
        spinner.isHidden = true
        [icon, name, detail, check, spinner].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked else { return }
            self.isPicked.toggle()
            self.onToggle?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(text)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func setWorking(_ working: Bool) {
        spinner.isHidden = !working
        working ? spinner.startLooping() : spinner.stopLooping()
        needsLayout = true
    }

    private func refresh() {
        // Quiet at rest, a soft accent wash and a check when picked: the icon does the talking.
        let fill = isPicked ? Onboard.accent.withAlphaComponent(0.12) : Onboard.tint.withAlphaComponent(isHovered && !isLocked ? 0.06 : 0)
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 0
        check.contentTintColor = Onboard.accent
        check.isHidden = !isPicked || !spinner.isHidden
    }

    override func stateDidChange(animated: Bool) { refresh() }

    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: bounds.width - 16 - 8, y: 8, width: 16, height: 16)
        if horizontal {
            let s: CGFloat = 30
            icon.frame = NSRect(x: 14, y: (bounds.height - s) / 2, width: s, height: s)
            let x = icon.frame.maxX + 12
            let block = name.lineHeight + 1 + detail.lineHeight
            name.frame = NSRect(x: x, y: (bounds.height - block) / 2, width: bounds.width - x - 28, height: name.lineHeight)
            detail.frame = NSRect(x: x, y: name.frame.maxY + 1, width: bounds.width - x - 12, height: detail.lineHeight)
        } else {
            let s: CGFloat = 40
            icon.frame = NSRect(x: (bounds.width - s) / 2, y: bounds.height / 2 - s + 4, width: s, height: s)
            // Picked: a small check on the icon's bottom-right corner, like a selected photo.
            check.frame = NSRect(x: icon.frame.maxX - 13, y: icon.frame.maxY - 13, width: 18, height: 18)
            name.frame = NSRect(x: 4, y: icon.frame.maxY + 8, width: bounds.width - 8, height: name.lineHeight)
        }
    }
}

/// A site you might use every day, with the Mac app that goes with it (for its icon) when there is one.
private struct Suggestion {
    let name: String
    let url: URL
    let app: String?
    var icon: URL?
    /// No sharp icon on the web: suggested only when its app is here, to borrow the app's icon.
    var onlyWithApp = false
    /// An icon shipped with Zigzag, by resource name.
    var bundled: String? = nil
    /// Always suggested, whatever's installed.
    var always = false
    var appURL: URL? { app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
}

/// Icons, sharp at tile size: the Mac app's own icon if it's installed, else the site's large icon, fetched by
/// domain from one icon service (nothing about you is sent). A globe shows until each arrives.
@MainActor private var iconCache: [URL: NSImage] = [:]
@MainActor private var iconWaiters: [URL: [(NSImage) -> Void]] = [:]

/// Fetches an icon once, sharing it with everyone who asked; started early so it's there when the step opens.
@MainActor private func fetchIcon(_ source: URL, then: ((NSImage) -> Void)? = nil) {
    if let image = iconCache[source] { then?(image); return }
    let first = iconWaiters[source] == nil
    iconWaiters[source, default: []].append(then ?? { _ in })
    guard first else { return }
    Task { @MainActor in
        guard let (data, _) = try? await URLSession.shared.data(from: source), let image = NSImage(data: data), image.isValid else {
            iconWaiters[source] = nil
            return
        }
        iconCache[source] = image
        iconWaiters.removeValue(forKey: source)?.forEach { $0(image) }
    }
}

private func iconSource(site: URL, explicit: URL?) -> URL? {
    explicit ?? site.host().flatMap { URL(string: "https://www.google.com/s2/favicons?domain=\($0)&sz=128") }
}

/// A web logo set in a white rounded tile the size of a Mac app icon's artwork, so logos and app icons read as
/// one set side by side.
private func appTile(_ logo: NSImage) -> NSImage {
    NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        let tile = rect.insetBy(dx: 12, dy: 12)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 24, yRadius: 24).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        logo.draw(in: tile.insetBy(dx: 20, dy: 20), from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
}

private func loadIcon(_ tile: PickTile, site: URL, app: URL? = nil, explicit: URL? = nil, bundled: String? = nil) {
    if let bundled, let url = Bundle.main.url(forResource: bundled, withExtension: "png"), let image = NSImage(contentsOf: url) {
        FaviconStore.shared.remember(image, for: site)
        tile.icon.image = image.size.width >= 128 && bundled == "avoidxray" ? appTileFull(image) : appTile(image)
        tile.icon.contentTintColor = nil
        return
    }
    if let app {
        tile.icon.image = NSWorkspace.shared.icon(forFile: app.path)
        tile.icon.contentTintColor = nil
        // The sidebar still wants the site's own icon, for the favorite.
        if let source = iconSource(site: site, explicit: explicit) { fetchIcon(source) { image in FaviconStore.shared.remember(image, for: site) } }
        return
    }
    tile.icon.image = Tokens.Symbol.image("globe", size: 22)
    tile.icon.contentTintColor = Onboard.dim(0.7)
    guard let source = iconSource(site: site, explicit: explicit) else { return }
    fetchIcon(source) { image in FaviconStore.shared.remember(image, for: site) }
    fetchIcon(source) { [weak tile] image in
        tile?.icon.image = appTile(image)
        tile?.icon.contentTintColor = nil
    }
}

/// An icon that's already a full square design, rounded and sized like an app icon.
private func appTileFull(_ art: NSImage) -> NSImage {
    NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        let tile = rect.insetBy(dx: 12, dy: 12)
        NSBezierPath(roundedRect: tile, xRadius: 24, yRadius: 24).addClip()
        art.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
}

private func loadIcons(_ pairs: [(PickTile, URL)]) { for (tile, url) in pairs { loadIcon(tile, site: url) } }

// MARK: - Everyday sites

/// The sites people open every day, as tiles: the ones you pick become favorites at the top of the sidebar.
final class SitesPicker: StepContent {
    private static let all: [Suggestion] = [
        Suggestion(name: "Gmail", url: URL(string: "https://mail.google.com")!, app: nil,
                   icon: URL(string: "https://www.gstatic.com/images/branding/product/2x/gmail_2020q4_48dp.png")),
        Suggestion(name: "Calendar", url: URL(string: "https://calendar.google.com")!, app: nil,
                   icon: URL(string: "https://ssl.gstatic.com/calendar/images/dynamiclogo_2020q4/calendar_31_2x.png")),
        Suggestion(name: "YouTube", url: URL(string: "https://www.youtube.com")!, app: nil),
        Suggestion(name: "Drive", url: URL(string: "https://drive.google.com")!, app: "com.google.drivefs",
                   icon: URL(string: "https://www.gstatic.com/images/branding/product/2x/drive_2020q4_48dp.png")),
        Suggestion(name: "Notion", url: URL(string: "https://www.notion.so")!, app: "notion.id"),
        Suggestion(name: "ChatGPT", url: URL(string: "https://chatgpt.com")!, app: "com.openai.chat"),
        Suggestion(name: "Claude", url: URL(string: "https://claude.ai")!, app: "com.anthropic.claudefordesktop"),
        Suggestion(name: "Spotify", url: URL(string: "https://open.spotify.com")!, app: "com.spotify.client"),
        Suggestion(name: "Slack", url: URL(string: "https://app.slack.com")!, app: "com.tinyspeck.slackmacgap"),
        Suggestion(name: "Figma", url: URL(string: "https://www.figma.com")!, app: "com.figma.Desktop"),
        Suggestion(name: "GitHub", url: URL(string: "https://github.com")!, app: nil),
        Suggestion(name: "AvoidXray", url: URL(string: "https://avoidxray.com")!, app: nil, bundled: "avoidxray", always: true),
        Suggestion(name: "WhatsApp", url: URL(string: "https://web.whatsapp.com")!, app: "net.whatsapp.WhatsApp", onlyWithApp: true),
        Suggestion(name: "Discord", url: URL(string: "https://discord.com/app")!, app: "com.hnc.Discord"),
        Suggestion(name: "X", url: URL(string: "https://x.com")!, app: nil),
        Suggestion(name: "Instagram", url: URL(string: "https://www.instagram.com")!, app: nil),
    ]
    /// Starts the icons while you're still on the first screens.
    static func preload() {
        for site in sites where site.appURL == nil { if let source = iconSource(site: site.url, explicit: site.icon) { fetchIcon(source) } }
    }

    /// Twelve: the ones whose apps are on this Mac first, since those are the ones you use.
    private static var sites: [Suggestion] {
        let pinned = all.filter(\.always)
        let (have, rest) = (all.filter { $0.appURL != nil && !$0.always }, all.filter { $0.appURL == nil && !$0.onlyWithApp && !$0.always })
        return Array((have + pinned + rest).prefix(12))
    }
    private var tiles: [(PickTile, URL, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let have = Set(Library.shared.favorites.map { TabManager.normalize($0.url) })
        for site in Self.sites {
            let tile = PickTile(name: site.name)
            tile.isPicked = have.contains(TabManager.normalize(site.url))
            tile.onToggle = { [weak self] in self?.showPicked() }
            addSubview(tile)
            tiles.append((tile, site.url, site.name))
            loadIcon(tile, site: site.url, app: site.appURL, explicit: site.icon, bundled: site.bundled)
        }
        preview.page = .blank
        preview.tabs = ["New Tab"]
        preview.favoritesView.onReorder = { [weak self] bookmark, index in
            guard let self, let from = self.order.firstIndex(where: { $0.id == bookmark.id }) else { return }
            self.order.remove(at: from)
            self.order.insert(bookmark, at: min(index, self.order.count))
            self.preview.liveFavorites = self.order
        }
        // Icons can still be arriving; the window catches up.
        for delay in [0.4, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.showPicked() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var picked: [(URL, String)] { tiles.filter { $0.0.isPicked }.map { ($0.1, $0.2) } }

    /// Picked sites in the order you've arranged them (drag them in the window on the right).
    private var order: [Bookmark] = []
    private var ids: [URL: UUID] = [:]

    /// The window on the right gains each site you pick as a favorite, as you pick it.
    private func showPicked() {
        let picked = tiles.filter { $0.0.isPicked }
        let urls = Set(picked.map(\.1))
        order.removeAll { !urls.contains($0.url) }
        for (_, url, name) in picked where !order.contains(where: { $0.url == url }) {
            let id = ids[url] ?? UUID()
            ids[url] = id
            order.append(Bookmark(id: id, url: url, title: name))
        }
        preview.liveFavorites = order
        onChange?()
    }
    override var primaryTitle: String { "Continue" }

    override func commit(_ done: @escaping () -> Void) {
        let have = Set(Library.shared.favorites.map { TabManager.normalize($0.url) })
        for bookmark in order where !have.contains(TabManager.normalize(bookmark.url)) { _ = Library.shared.addFavorite(url: bookmark.url, title: bookmark.title) }
        done()
    }

    private static let columns = 6
    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let size = floor((width - CGFloat(Self.columns - 1) * 8) / CGFloat(Self.columns))
        let lines = CGFloat((tiles.count + Self.columns - 1) / Self.columns)
        return lines * size + (lines - 1) * 8
    }

    override func layout() {
        super.layout()
        let columns = Self.columns, gap: CGFloat = 8
        let size = floor((bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let x0: CGFloat = 0, y0: CGFloat = 0
        for (i, (tile, _, _)) in tiles.enumerated() {
            tile.frame = NSRect(x: x0 + CGFloat(i % columns) * (size + gap), y: y0 + CGFloat(i / columns) * (size + gap), width: size, height: size)
        }
    }
}

// MARK: - Extensions

/// Popular extensions in a list like the import step's: tick the ones you use, and each row shows its install
/// as it happens: a spinner, then Added, or what went wrong.
private final class ExtensionsPicker: StepContent {
    private static let suggestions: [(id: String, name: String, kind: String, site: String, app: String?)] = [
        // A password app on your Mac fills nothing in a browser by itself: its browser extension is what does.
        (ExtensionStore.onePasswordID, "1Password", "Needed to fill from the 1Password app", "https://1password.com", "com.1password.1password"),
        ("nngceckbapebfimnlniiiahkandclblb", "Bitwarden", "Needed to fill from Bitwarden", "https://bitwarden.com", "com.bitwarden.desktop"),
        ("kbfnbcaeplbcioakkpcpgfkobkghlhen", "Grammarly", "Checks your writing", "https://www.grammarly.com", nil),
        ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader", "Dark mode for every site", "https://darkreader.org", nil),
        ("knheggckgoiihginacbkhaalnibhilkk", "Notion Web Clipper", "Saves pages to Notion", "https://www.notion.so", nil),
        ("aapbdbdomjkkjkaonfhkkikfgjllcleb", "Google Translate", "Translates what you select", "https://translate.google.com", nil),
    ]
    private let list = ColorView(color: .clear)
    private var rows: [(ExtensionRow, String)] = []
    private var separators: [ColorView] = []
    private var installing = false
    private var finished = false
    private let note = Label("Sign in to each one after it’s added.", font: Tokens.Font.small(), color: Onboard.dim(0.65))

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.wantsLayer = true
        list.layer?.cornerRadius = 12
        list.layer?.cornerCurve = .continuous
        list.layer?.borderWidth = 0
        addSubview(list)
        var installed: Set<String> = []
        if #available(macOS 15.4, *) { installed = Set(ExtensionHost.shared.installed.keys) }
        for (i, s) in Self.suggestions.enumerated() {
            let row = ExtensionRow(name: s.name, kind: s.kind)
            if installed.contains(s.id) { row.state = .added }
            row.onChange = { [weak self] in self?.showChosen() }
            list.addSubview(row)
            rows.append((row, s.id))
            if i > 0 {
                let line = ColorView(color: Onboard.tint.withAlphaComponent(0.09))
                list.addSubview(line)
                separators.append(line)
            }
            let tile = row.iconTile
            if let site = URL(string: s.site) {
                loadIcon(tile, site: site, app: s.app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            }
        }
        note.alignment = .left
        addSubview(note)
        for delay in [0.4, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.showChosen() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var toAdd: [(ExtensionRow, String)] { rows.filter { $0.0.isChosen && $0.0.state == .idle } }

    /// The window on the right shows each extension you pick, as you pick it.
    private func showChosen() {
        preview.extensions = rows.filter { $0.0.isChosen || $0.0.state == .added }.compactMap { $0.0.iconTile.icon.image }
        onChange?()
    }
    override var primaryTitle: String { installing ? "Adding…" : toAdd.isEmpty ? "Continue" : "Add \(toAdd.count)" }
    override var isBusy: Bool { installing }

    override func commit(_ done: @escaping () -> Void) {
        let work = toAdd
        guard !work.isEmpty else { done(); return }
        installing = true
        rows.forEach { $0.0.isLocked = true }
        work.forEach { $0.0.state = .waiting }
        onChange?()
        Task { @MainActor in
            var failed = false
            for (row, id) in work {
                row.state = .working
                switch await ExtensionStore.install(id) {
                case .success: row.state = .added
                case .failure(let error):
                    failed = true
                    row.state = .failed(error.message)
                }
            }
            self.installing = false
            self.rows.forEach { $0.0.isLocked = false }
            if failed {
                // Say so and wait: Next then moves on.
                self.note.stringValue = "Some couldn’t be added. You can add them later from the Chrome Web Store."
                self.onChange?()
            } else {
                // A beat to see them all marked Added, then on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done() }
            }
        }
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat { CGFloat(rows.count) * 50 + 12 + note.lineHeight }

    override func layout() {
        super.layout()
        let width = bounds.width, rowH: CGFloat = 50
        list.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowH)
        for (i, (row, _)) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * rowH, width: width, height: rowH)
            if i > 0 { separators[i - 1].frame = NSRect(x: 62, y: CGFloat(i) * rowH, width: width - 62, height: Tokens.Metric.hairline) }
        }
        note.frame = NSRect(x: 2, y: list.frame.maxY + 12, width: width, height: note.lineHeight)
    }

}

/// One suggested extension: checkbox, icon, name and what it does; on the right, how adding it went.
private final class ExtensionRow: InteractiveView {
    enum State: Equatable { case idle, waiting, working, added, failed(String) }
    var state = State.idle { didSet { refresh() } }
    var isChosen = false { didSet { refresh() } }
    override func accessibilityValue() -> Any? { isChosen ? 1 : 0 }
    var isLocked = false
    var onChange: (() -> Void)?
    /// Holds the icon; borrowed for loading.
    let iconTile = PickTile(name: "")
    private let box = ColorView(color: .clear)
    private let tick = NSImageView()
    private let name: Label
    private let kind: Label
    private let status = Label("", font: Tokens.Font.small(.medium), color: Onboard.ink)
    private let statusIcon = NSImageView()
    private let spinner = Spinner()

    init(name text: String, kind detail: String) {
        name = Label(text, font: Tokens.Font.body(.semibold), color: Onboard.ink)
        kind = Label(detail, font: Tokens.Font.small(), color: Onboard.dim(0.62))
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1.5
        tick.image = Tokens.Symbol.image("checkmark", size: 10)
        tick.contentTintColor = NSColor.white
        box.addSubview(tick)
        status.alignment = .right
        [box, iconTile.icon, name, kind, status, statusIcon, spinner].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked, self.state == .idle || { if case .failed = self.state { true } else { false } }() else { return }
            if case .failed = self.state { self.state = .idle }
            self.isChosen.toggle()
            self.onChange?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(text)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func stateDidChange(animated: Bool) { refresh() }

    private func refresh() {
        let added = state == .added
        let on = isChosen || added
        box.layer?.backgroundColor = on ? Onboard.accent.cgColor : nil
        box.layer?.borderColor = Onboard.tint.withAlphaComponent(on ? 1 : 0.45).cgColor
        tick.isHidden = !on
        box.alphaValue = added ? 0.5 : 1
        layer?.backgroundColor = isHovered && state == .idle && !isLocked ? Onboard.tint.withAlphaComponent(0.05).cgColor : nil
        statusIcon.isHidden = true
        status.textColor = Onboard.ink
        switch state {
        case .idle: status.stringValue = ""
        case .waiting: status.stringValue = "Waiting"; status.textColor = Onboard.dim(0.55)
        case .working: status.stringValue = "Adding"
        case .added:
            status.stringValue = "Added"
            statusIcon.image = Tokens.Symbol.image("checkmark.circle.fill", size: 15)
            statusIcon.contentTintColor = Tokens.Color.success
            statusIcon.isHidden = false
        case .failed(let message):
            status.stringValue = "Couldn’t add"
            status.textColor = Tokens.Color.caution
            toolTip = message
        }
        state == .working ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, pad = Tokens.Space.x4
        box.frame = NSRect(x: pad, y: (h - 18) / 2, width: 18, height: 18)
        tick.frame = box.bounds.insetBy(dx: 3, dy: 3)
        iconTile.icon.frame = NSRect(x: box.frame.maxX + 10, y: (h - 38) / 2, width: 38, height: 38)
        let x = iconTile.icon.frame.maxX + 10
        var right = bounds.width - pad
        if !statusIcon.isHidden {
            statusIcon.frame = NSRect(x: right - 15, y: (h - 15) / 2, width: 15, height: 15)
            right = statusIcon.frame.minX - 6
        }
        if !spinner.isHidden || state == .working {
            spinner.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
            right = spinner.frame.minX - 6
        }
        let sw = status.textWidth + 2
        status.frame = NSRect(x: right - sw, y: (h - status.lineHeight) / 2, width: sw, height: status.lineHeight)
        let block = name.lineHeight + 1 + kind.lineHeight
        name.frame = NSRect(x: x, y: (h - block) / 2, width: status.frame.minX - x - 8, height: name.lineHeight)
        kind.frame = NSRect(x: x, y: name.frame.maxY + 1, width: status.frame.minX - x - 8, height: kind.lineHeight)
    }
}

// MARK: - Ads

/// Two clear answers, one picked, over a page that shows the difference: with ads, banners and a pop-up crowd
/// the article; blocked, it's just the article.
private final class AdsPicker: StepContent {
    private let badge = ColorView(color: Onboard.accent)
    private let shield = NSImageView()
    private let title = Label("Block ads and trackers", font: Tokens.Font.body(.semibold), color: Onboard.ink)
    private let line = Label("Built into Zigzag, no extension needed.", font: Tokens.Font.small(), color: Onboard.dim(0.65))
    private let toggle = Toggle(isOn: ContentBlocker.isEnabled)
    private let rule = ColorView(color: Onboard.tint.withAlphaComponent(0.1))
    private let note = Label("A site that breaks can be let through from its controls.", font: Tokens.Font.small(), color: Onboard.dim(0.6))

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        badge.layer?.cornerCurve = .continuous
        shield.image = Tokens.Symbol.image("shield.lefthalf.filled", size: 22)
        shield.contentTintColor = .white
        badge.addSubview(shield)
        [badge, title, line, toggle, rule, note].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func commit(_ done: @escaping () -> Void) {
        ContentBlocker.isEnabled = toggle.isOn
        done()
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat { 52 + 33 + note.lineHeight }

    override func layout() {
        super.layout()
        let w = bounds.width, h: CGFloat = 52
        badge.frame = NSRect(x: 0, y: 0, width: h, height: h)
        shield.frame = badge.bounds
        toggle.frame = NSRect(x: w - 34, y: (h - 20) / 2, width: 34, height: 20)
        let tx = badge.frame.maxX + 14, tw = toggle.frame.minX - 16 - tx
        let block = title.lineHeight + 2 + line.lineHeight
        title.frame = NSRect(x: tx, y: (h - block) / 2, width: tw, height: title.lineHeight)
        line.frame = NSRect(x: tx, y: title.frame.maxY + 2, width: tw, height: line.lineHeight)
        rule.frame = NSRect(x: 0, y: h + 16, width: w, height: Tokens.Metric.hairline)
        note.frame = NSRect(x: 0, y: rule.frame.maxY + 16, width: w, height: note.lineHeight)
    }
}

/// A choice you can only pick one of: a ring, a title and a line.
private final class ChoiceCard: InteractiveView {
    var isChosen = false { didSet { refresh() } }
    private let ring = ColorView(color: .clear)
    private let dot = ColorView(color: Onboard.accent)
    private let title: Label
    private let detail: Label
    private let badge = Label("Recommended", font: .systemFont(ofSize: 11, weight: .semibold), color: NSColor.white)
    private let badgeFill = ColorView(color: Onboard.accent)

    init(title text: String, detail line: String, recommended: Bool) {
        title = Label(text, font: Tokens.Font.body(.semibold), color: Onboard.ink)
        detail = Label(line, font: Tokens.Font.small(), color: Onboard.dim(0.65))
        super.init(frame: .zero)
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 10
        ring.layer?.borderWidth = 1.5
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        ring.addSubview(dot)
        badgeFill.wantsLayer = true
        badgeFill.layer?.cornerRadius = 6
        badge.alignment = .center
        badgeFill.addSubview(badge)
        badgeFill.isHidden = !recommended
        [ring, title, detail, badgeFill].forEach { addSubview($0) }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(text)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func stateDidChange(animated: Bool) { refresh() }

    private func refresh() {
        layer?.backgroundColor = Onboard.tint.withAlphaComponent(isChosen ? 0.16 : (isHovered ? 0.09 : 0.05)).cgColor
        layer?.borderWidth = isChosen ? 1.5 : 0
        layer?.borderColor = Onboard.tint.withAlphaComponent(0.7).cgColor
        ring.layer?.borderColor = Onboard.tint.withAlphaComponent(isChosen ? 1 : 0.45).cgColor
        dot.isHidden = !isChosen
    }

    override func layout() {
        super.layout()
        ring.frame = NSRect(x: 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        dot.frame = NSRect(x: 5, y: 5, width: 10, height: 10)
        let x = ring.frame.maxX + 16
        let block = title.lineHeight + 2 + detail.lineHeight
        title.frame = NSRect(x: x, y: (bounds.height - block) / 2, width: min(title.textWidth + 4, bounds.width - x - 12), height: title.lineHeight)
        detail.frame = NSRect(x: x, y: title.frame.maxY + 2, width: bounds.width - x - 16, height: detail.lineHeight)
        let bw = badge.textWidth + 14
        // Top right, clear of the title however narrow the card.
        badgeFill.frame = NSRect(x: bounds.width - bw - 10, y: 10, width: bw, height: 20)
        badge.frame = NSRect(x: 0, y: (20 - badge.lineHeight) / 2, width: bw, height: badge.lineHeight)
    }
}

/// The window on the right of every step: a drawing of Zigzag in your space's color that shows what each choice
/// does: the favorites you pick, the extensions you add, a page with or without ads.
final class LiveBrowser: NSView {
    enum Page: Equatable { case blank, wikipedia, news(ads: Bool) }
    var favorites: [NSImage]? { didSet { needsDisplay = true } }
    /// Favorites drawn with a ring: the ones you just picked.
    var highlightsFavorites = false { didSet { needsDisplay = true } }
    var extensions: [NSImage] = [] { didSet { needsDisplay = true } }
    /// Zigzag's own favorites grid, for the step where you pick them: it looks and drags exactly like the app's.
    let favoritesView = FavoritesView()
    var liveFavorites: [Bookmark]? {
        didSet {
            favoritesView.isHidden = liveFavorites == nil
            favoritesView.reload(favorites: liveFavorites ?? [], openIDs: [], selectedID: nil)
            needsLayout = true
            needsDisplay = true
        }
    }
    private let side: CGFloat = 170
    private var shotsToken: SignalToken?
    var page: Page = .wikipedia { didSet { needsDisplay = true } }
    var tabs = ["Wikipedia", "Recipes", "Trip ideas"] { didSet { needsDisplay = true } }
    private var background: NSColor = SpaceColor.sky.background
    /// Where a gradient ends, which way it runs, how grainy, and whether it's glass: the frame as the real one draws it.
    private var background2: NSColor?
    private var angle: Double = 90
    private var grain: Double = 0
    private var glass = false
    private var accent: NSColor = Brand.Theme.brand.accent
    private var isDark = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -16)
        favoritesView.isHidden = true
        addSubview(favoritesView)
        shotsToken = PageShots.shared.changed.observe { [weak self] in self?.needsDisplay = true }
        refreshColors()
    }

    override func layout() {
        super.layout()
        favoritesView.frame = NSRect(x: 12, y: 64, width: side - 24, height: max(favoritesView.preferredHeight, 1))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Takes on the first space's color and look.
    func refreshColors() {
        let space = Library.shared.spaces.first
        let look = space?.readableAppearance
        appearance = look == "dark" ? NSAppearance(named: .darkAqua) : look == "light" ? NSAppearance(named: .aqua) : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.isDark = self.effectiveAppearance.isDark
            self.glass = space?.glass == true
            let bg = self.glass ? space?.glassColor ?? .clear : space?.background ?? SpaceColor.sky.background
            self.background = bg.usingColorSpace(.sRGB) ?? bg
            self.background2 = self.glass ? nil : space?.background2.map { $0.usingColorSpace(.sRGB) ?? $0 }
            self.angle = space?.gradientAngle ?? 90
            self.grain = space?.grain ?? 0
            self.accent = Brand.Theme.of(space).accent.usingColorSpace(.sRGB) ?? Brand.Theme.brand.accent
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        shape.addClip()
        let ink = isDark ? NSColor.white : NSColor.black
        if let background2, let gradient = NSGradient(starting: background, ending: background2) {
            // Flipped, so 90° runs top to bottom, as in the window.
            gradient.draw(in: bounds, angle: CGFloat(angle))
        } else {
            // Glass lets the backdrop behind this little window through, washed white or smoked.
            background.setFill()
            bounds.fill(using: glass ? .sourceOver : .copy)
        }
        if grain > 0.01, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.overlay)
            context.setAlpha(CGFloat(grain) * 0.22)
            NSColor(patternImage: BrandSurface.noise).setFill()
            bounds.fill(using: .sourceOver)
            context.restoreGState()
        }
        func box(_ r: NSRect, _ color: NSColor, _ radius: CGFloat) {
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ string: String, _ point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, width: CGFloat = 200) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
                .draw(with: NSRect(x: point.x, y: point.y, width: width, height: size * 1.4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let pad: CGFloat = 12
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: pad + CGFloat(i) * 14, y: 13, width: 9, height: 9)).fill()
        }
        // Address field, with extension icons at its end once you've added some.
        let address = NSRect(x: pad, y: 32, width: side - pad * 2, height: 24)
        box(address, ink.withAlphaComponent(0.07), 7)
        let label: String = { switch page { case .news: "thedailyfield.com"; case .wikipedia: "wikipedia.org"; case .blank: "Search or enter address" } }()
        text(label, NSPoint(x: address.minX + 8, y: address.minY + 5), size: 10.5, color: ink.withAlphaComponent(0.5), width: address.width - 16)
        // Favorites: the sites you picked, with their own icons.
        let favs = liveFavorites != nil ? [] : favorites ?? Library.shared.favorites.prefix(8).compactMap { FaviconStore.shared.cachedIcon(for: $0.url) }
        let slots = liveFavorites != nil ? 0 : max(4, min(favs.count, 8))
        let cols = 4
        let favW = (side - pad * 2 - CGFloat(cols - 1) * 5) / CGFloat(cols)
        var y: CGFloat = 64
        if liveFavorites != nil { y += favoritesView.preferredHeight + 8 - 37 }
        for i in 0..<slots {
            let r = NSRect(x: pad + CGFloat(i % cols) * (favW + 5), y: y + CGFloat(i / cols) * 37, width: favW, height: 32)
            box(r, ink.withAlphaComponent(0.06), 8)
            if i < favs.count {
                if highlightsFavorites {
                    accent.setStroke()
                    let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
                favs[i].draw(in: NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16))
            }
        }
        y += CGFloat(max(1, (slots + cols - 1) / cols)) * 37 + 8
        text(Library.shared.spaces.first?.name ?? "Personal", NSPoint(x: pad + 2, y: y), size: 9.5, weight: .semibold, color: ink.withAlphaComponent(0.5))
        y += 18
        for (i, title) in tabs.enumerated() {
            let r = NSRect(x: pad - 3, y: y + CGFloat(i) * 26, width: side - pad * 2 + 6, height: 23)
            if i == 0 { box(r, isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.85), 7) }
            box(NSRect(x: r.minX + 7, y: r.midY - 4, width: 8, height: 8), i == 0 ? accent : ink.withAlphaComponent(0.25), 2)
            text(title, NSPoint(x: r.minX + 22, y: r.minY + 5), size: 11, weight: i == 0 ? .medium : .regular,
                 color: ink.withAlphaComponent(i == 0 ? 0.85 : 0.6), width: r.width - 28)
        }
        var extensionPanel: NSRect?
        if !extensions.isEmpty {
            // Where the app keeps them: site controls, from the button at the end of the address.
            let button = NSRect(x: address.maxX - 22, y: address.minY + 4, width: 16, height: 16)
            box(button, accent.withAlphaComponent(0.2), 4)
            extensionPanel = NSRect(x: address.minX, y: address.maxY + 8, width: 236, height: 150)
        }
        // The page.
        let pageRect = NSRect(x: side, y: 10, width: bounds.width - side - 10, height: bounds.height - 20)
        let pageInk = isDark ? NSColor.white : NSColor.black
        box(pageRect, isDark ? NSColor(white: 0.12, alpha: 1) : .white, 9)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: pageRect, xRadius: 9, yRadius: 9).addClip()
        let px = pageRect.minX + 22
        let shot: PageShots.Shot? = { switch page { case .wikipedia: .wikipedia; case .news(let ads): ads ? .adsShown : .adsBlocked; case .blank: nil } }()
        if let shot, let image = PageShots.shared.images[shot] {
            // The real page, scaled to the window's width, from the top.
            let scale = max(pageRect.width / image.size.width, pageRect.height / image.size.height)
            image.draw(in: NSRect(x: pageRect.minX, y: pageRect.minY, width: image.size.width * scale, height: image.size.height * scale),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if case .news(false) = page {
                let badge = NSRect(x: pageRect.minX + 16, y: pageRect.maxY - 42, width: 180, height: 26)
                box(badge, accent, 8)
                text("Ads and trackers blocked", NSPoint(x: badge.minX + 12, y: badge.minY + 6), size: 10.5, weight: .semibold, color: .white, width: 170)
            }
        } else {
        switch page {
        case .blank:
            break
        case .wikipedia:
            text("Wikipedia", NSPoint(x: px, y: pageRect.minY + 20), size: 18, weight: .semibold, color: pageInk.withAlphaComponent(0.85), width: pageRect.width - 44)
            text("The free encyclopedia", NSPoint(x: px, y: pageRect.minY + 46), size: 11, color: pageInk.withAlphaComponent(0.5), width: pageRect.width - 44)
            for (k, w) in [0.9, 0.82, 0.86, 0.64].enumerated() {
                box(NSRect(x: px, y: pageRect.minY + 76 + CGFloat(k) * 13, width: (pageRect.width - 44) * w, height: 6), pageInk.withAlphaComponent(0.12), 3)
            }
            let card = NSRect(x: px, y: pageRect.minY + 142, width: pageRect.width - 44, height: pageRect.height - 162)
            box(card, accent.withAlphaComponent(0.16), 9)
            box(NSRect(x: card.minX + 14, y: card.minY + 14, width: 78, height: 22), accent, 6)
            text("Read more", NSPoint(x: card.minX + 23, y: card.minY + 18), size: 10, weight: .semibold, color: .white, width: 70)
        case .news(let ads):
            text("Today’s news", NSPoint(x: px, y: pageRect.minY + 20), size: 18, weight: .semibold, color: pageInk.withAlphaComponent(0.85), width: pageRect.width - 44)
            for (k, w) in [0.92, 0.84, 0.88, 0.7, 0.9, 0.8, 0.86, 0.6, 0.88, 0.75].enumerated() {
                box(NSRect(x: px, y: pageRect.minY + 58 + CGFloat(k) * 15 + (k > 4 ? 12 : 0), width: (pageRect.width - 44) * w, height: 6), pageInk.withAlphaComponent(0.12), 3)
            }
            if ads {
                func ad(_ r: NSRect, _ c: NSColor) {
                    box(r, c, 6)
                    text("AD", NSPoint(x: r.minX + 8, y: r.minY + 6), size: 10, weight: .heavy, color: .white.withAlphaComponent(0.9))
                }
                ad(NSRect(x: px, y: pageRect.minY + 50, width: pageRect.width - 44, height: 40), NSColor.systemOrange)
                ad(NSRect(x: pageRect.maxX - 140, y: pageRect.minY + 110, width: 118, height: 110), NSColor.systemPink)
                ad(NSRect(x: pageRect.minX, y: pageRect.maxY - 34, width: pageRect.width, height: 34), NSColor.systemPurple)
                NSColor.black.withAlphaComponent(0.25).setFill()
                pageRect.fill()
                let popup = NSRect(x: pageRect.midX - 100, y: pageRect.midY - 50, width: 200, height: 96)
                box(popup, .white, 12)
                ad(NSRect(x: popup.minX + 14, y: popup.minY + 14, width: popup.width - 28, height: 40), NSColor.systemBlue)
                box(NSRect(x: popup.minX + 14, y: popup.minY + 66, width: 100, height: 8), NSColor(white: 0.85, alpha: 1), 3)
            } else {
                let badge = NSRect(x: pageRect.maxX - 196, y: pageRect.maxY - 40, width: 180, height: 26)
                box(badge, accent.withAlphaComponent(0.14), 8)
                text("Ads and trackers blocked", NSPoint(x: badge.minX + 12, y: badge.minY + 6), size: 10.5, weight: .semibold, color: accent, width: 170)
            }
        }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        if let panel = extensionPanel {
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            box(panel, isDark ? NSColor(white: 0.17, alpha: 1) : .white, 10)
            NSGraphicsContext.current?.restoreGraphicsState()
            // As the app's site controls draw it: the site, its extensions, then its switches.
            let inset = panel.minX + 14
            if let favicon = FaviconStore.shared.cachedIcon(for: URL(string: "https://www.wikipedia.org")!) {
                favicon.draw(in: NSRect(x: inset, y: panel.minY + 12, width: 16, height: 16))
            }
            text("wikipedia.org", NSPoint(x: inset + 24, y: panel.minY + 11), size: 11.5, weight: .semibold, color: pageInk.withAlphaComponent(0.85))
            text("Secure connection", NSPoint(x: inset + 24, y: panel.minY + 26), size: 9.5, color: pageInk.withAlphaComponent(0.45))
            box(NSRect(x: inset, y: panel.minY + 46, width: panel.width - 28, height: 1), pageInk.withAlphaComponent(0.08), 0)
            text("Extensions", NSPoint(x: inset, y: panel.minY + 54), size: 9.5, weight: .semibold, color: pageInk.withAlphaComponent(0.45))
            for (k, icon) in extensions.prefix(6).enumerated() {
                let r = NSRect(x: inset + CGFloat(k) * 32, y: panel.minY + 70, width: 28, height: 28)
                box(r, pageInk.withAlphaComponent(0.06), 8)
                icon.draw(in: r.insetBy(dx: 5, dy: 5))
            }
            text("Block ads and trackers", NSPoint(x: inset, y: panel.minY + 112), size: 10.5, color: pageInk.withAlphaComponent(0.75))
            let toggle = NSRect(x: panel.maxX - 14 - 26, y: panel.minY + 110, width: 26, height: 16)
            box(toggle, accent, 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: toggle.maxX - 14, y: toggle.minY + 2, width: 12, height: 12)).fill()
        }
    }
}

// MARK: - Ready

/// The last step: make Zigzag the browser links open in, then start.
private final class ReadyPicker: StepContent {
    private let icon = NSImageView()
    private let title = Label("Make Zigzag your default browser", font: Tokens.Font.body(.semibold), color: Onboard.ink)
    private let line = Label("Links from Mail, Messages and other apps open here.", font: Tokens.Font.small(), color: Onboard.dim(0.65))
    private let button = Onboard.primary("Make Default")
    private let done = Label("Default browser", font: Tokens.Font.small(.medium), color: Onboard.dim(0.65))
    private let check = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        line.lineBreakMode = .byTruncatingTail
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 15)
        check.contentTintColor = Onboard.accent
        [icon, title, line, button, done, check].forEach { addSubview($0) }
        button.onClick = { [weak self] _ in
            DefaultBrowser.make()
            // macOS asks to confirm; the row catches up once it has.
            for delay in [1.0, 3.0, 6.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refresh() } }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTitle: String { "Start Browsing" }

    private func refresh() {
        let isDefault = SettingsWindowController.isDefaultBrowser
        button.isHidden = isDefault
        done.isHidden = !isDefault
        check.isHidden = !isDefault
        needsLayout = true
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat { 56 }

    override func layout() {
        super.layout()
        let w = bounds.width, h: CGFloat = 56
        icon.frame = NSRect(x: 0, y: 0, width: h, height: h)
        let right: CGFloat
        if button.isHidden {
            let dw = ceil(done.intrinsicContentSize.width)
            done.frame = NSRect(x: w - dw, y: (h - done.lineHeight) / 2, width: dw, height: done.lineHeight)
            check.frame = NSRect(x: done.frame.minX - 20, y: (h - 16) / 2, width: 16, height: 16)
            right = check.frame.minX - 12
        } else {
            let bw = max(button.fittingWidth + 16, 128)
            button.frame = NSRect(x: w - bw, y: (h - Tokens.Space.x8) / 2, width: bw, height: Tokens.Space.x8)
            right = button.frame.minX - 16
        }
        let tx = icon.frame.maxX + 14
        let block = title.lineHeight + 2 + line.lineHeight
        title.frame = NSRect(x: tx, y: (h - block) / 2, width: right - tx, height: title.lineHeight)
        line.frame = NSRect(x: tx, y: title.frame.maxY + 2, width: right - tx, height: line.lineHeight)
    }
}


/// A clip view whose content starts at the top, so a scrolling list reads top-down.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
