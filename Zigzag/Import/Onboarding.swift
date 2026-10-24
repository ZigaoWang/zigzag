import AppKit

/// First launch: four calm screens on the brand's blue, one idea each, centered, one main button.
/// Hello → bring your stuff over → make it yours → the few keys worth knowing.
final class OnboardingView: NSView {
    var onFinish: (() -> Void)?

    enum Step: Int, CaseIterable { case hello, bring, personalize, ready }
    private(set) var step = Step.hello

    private let surface = BrandSurface()
    private var page: NSView?
    private var dots: [CALayer] = []
    private var startedImport = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.cornerRadius = 0
        surface.layer?.borderWidth = 0
        surface.showsWatermark = false
        addSubview(surface)
        for _ in Step.allCases {
            let dot = CALayer()
            dot.cornerRadius = 3
            dot.zPosition = 10
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        show(.hello, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The space you're setting up: the first one, which a fresh install has.
    private var spaceID: UUID? { Library.shared.spaces.first?.id }

    func show(_ next: Step, animated: Bool) {
        step = next
        let view: NSView
        switch next {
        case .hello:
            let hello = HelloPage()
            hello.onStart = { [weak self] in self?.show(.bring, animated: true) }
            view = hello
        case .bring:
            let bring = BringPage()
            bring.onContinue = { [weak self] in self?.show(.personalize, animated: true) }
            view = bring
        case .personalize:
            let page = PersonalizePage(spaceID: spaceID)
            page.onColor = { [weak self] in self?.applySpaceColor() }
            page.onContinue = { [weak self] in self?.show(.ready, animated: true) }
            view = page
        case .ready:
            let ready = ReadyPage()
            ready.onStart = { [weak self] in self?.onFinish?() }
            view = ready
        }
        let old = page
        page = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        refreshDots()
        guard animated, let old else { old?.removeFromSuperview(); return }
        window?.makeFirstResponder(nil)
        slide(from: old, to: view)
    }

    /// Moving on: the screen you're leaving drifts a little left as it fades, the next arrives from the right.
    /// One smooth ease-out, short, no bounce, so it reads as going forward and nothing more.
    private func slide(from old: NSView, to new: NSView) {
        [old, new].forEach { $0.wantsLayer = true }
        guard let oldLayer = old.layer, let newLayer = new.layer else { old.removeFromSuperview(); return }
        let distance: CGFloat = 36
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

    /// Picking a color tints the whole window, so you see it before you start browsing.
    private func applySpaceColor() {
        surface.fixedTheme = Brand.Theme.of(Library.shared.spaces.first)
    }

    private func refreshDots() {
        Tokens.Motion.withoutAnimation {
            for (i, dot) in dots.enumerated() {
                dot.backgroundColor = Brand.ribbon.withAlphaComponent(i == step.rawValue ? 0.95 : 0.3).cgColor
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        page?.frame = bounds
        let size: CGFloat = 6, gap: CGFloat = 10
        let total = CGFloat(dots.count) * size + CGFloat(dots.count - 1) * gap
        Tokens.Motion.withoutAnimation {
            for (i, dot) in dots.enumerated() {
                dot.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(i) * (size + gap), y: bounds.height - Tokens.Space.x8 - size, width: size, height: size)
            }
        }
    }
}

// MARK: - Pieces

/// Text and buttons that read on the blue.
private enum Onboard {
    static let ink = Brand.ribbon
    static func dim(_ alpha: CGFloat = 0.72) -> NSColor { Brand.ribbon.withAlphaComponent(alpha) }

    static func title(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = false
        field.attributedStringValue = Brand.display(text, size: 28, color: ink, alignment: .center, wraps: true)
        return field
    }

    static func line(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = false
        field.font = .systemFont(ofSize: 14)
        field.textColor = dim()
        field.alignment = .center
        return field
    }

    /// The one main action on a screen: light on the blue.
    static func primary(_ title: String) -> PrimaryButton {
        let button = PrimaryButton(title: title)
        button.customFill = Brand.ribbon
        button.customInk = Brand.navy
        return button
    }

    static func quiet(_ title: String) -> TextButton {
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.textColor = dim(0.8)
        return button
    }

    /// Lays a title and line out centered from `y`, returning where the content below should start.
    static func header(_ title: NSTextField, _ line: NSTextField, in bounds: NSRect, top y: CGFloat, width: CGFloat = 540) -> CGFloat {
        let x = (bounds.width - width) / 2
        let th = ceil(title.sizeThatFits(NSSize(width: width, height: 200)).height)
        title.frame = NSRect(x: x, y: y, width: width, height: th)
        let lh = ceil(line.sizeThatFits(NSSize(width: width, height: 200)).height)
        line.frame = NSRect(x: x, y: title.frame.maxY + Tokens.Space.x2, width: width, height: lh)
        return line.frame.maxY
    }

    /// The bottom row: the main button on the right, a quiet choice on the left, above the step dots.
    static func footer(primary: NSView, quiet: NSView?, in bounds: NSRect, width: CGFloat = 460) {
        let h = Tokens.Space.x10
        let y = bounds.height - 76 - h
        let x = (bounds.width - width) / 2
        let w = max((primary as? PrimaryButton)?.fittingWidth ?? 120, 140)
        primary.frame = NSRect(x: x + width - w, y: y, width: w, height: h)
        if let quiet {
            let qw = (quiet as? TextButton)?.fittingWidth ?? 100
            quiet.frame = NSRect(x: x - Tokens.Space.x2, y: y + (h - Tokens.Space.x8) / 2, width: qw, height: Tokens.Space.x8)
        }
    }
}

// MARK: - 1. Hello

/// "Welcome to", then the wordmark writing itself in, then one button.
private final class HelloPage: NSView {
    var onStart: (() -> Void)?
    private let welcome = Label("Welcome to", font: .systemFont(ofSize: 17, weight: .medium), color: Onboard.dim(0.78))
    private let wordmark = WordmarkView()
    private let start = Onboard.primary("Get Started")
    private var drewIn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        welcome.alignment = .center
        wordmark.color = Onboard.ink
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
        wordmark.drawIn(delay: 0.35)
        Brand.enter([welcome], delay: 0.1)
        Brand.enter([start], delay: 1.3)
    }

    override func layout() {
        super.layout()
        let markHeight: CGFloat = 64
        let markWidth = markHeight * WordmarkView.aspect
        let h = Tokens.Space.x10
        let total = welcome.lineHeight + Tokens.Space.x4 + markHeight + Tokens.Space.x16 + h
        var y = round((bounds.height - total) / 2) - Tokens.Space.x4
        welcome.frame = NSRect(x: 0, y: y, width: bounds.width, height: welcome.lineHeight)
        y = welcome.frame.maxY + Tokens.Space.x4
        wordmark.frame = NSRect(x: round((bounds.width - markWidth) / 2), y: y, width: markWidth, height: markHeight)
        y = wordmark.frame.maxY + Tokens.Space.x16
        let w: CGFloat = 176
        start.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: h)
    }
}

// MARK: - 2. Bring your stuff

private final class BringPage: NSView {
    var onContinue: (() -> Void)?
    private let title = Onboard.title("Bring your stuff over")
    private let line = Onboard.line("Passwords, bookmarks and history. Your other browser stays as it is.")
    private var tiles: [BrowserTile] = []
    private let empty = Onboard.line("No other browsers with something to bring were found on this Mac.")
    private let primary = Onboard.primary("Import")
    private let skip = Onboard.quiet("Not Now")
    private let choose = Onboard.quiet("Choose what to bring")
    private var pills: [(ImportCoordinator.Choice, ChoicePill)] = []
    private var showsChoices = false
    private var isDone = false
    private var isImporting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        [title, line, primary, skip].forEach { addSubview($0) }
        let sources = Array(ImportCoordinator.detectedSources().prefix(6))
        tiles = sources.enumerated().map { i, source in
            let tile = BrowserTile(source: source)
            // The first (Arc, when it's here) starts chosen; the rest wait to be picked.
            tile.isChosen = i == 0
            tile.onToggle = { [weak self] in self?.refresh() }
            addSubview(tile)
            return tile
        }
        if sources.isEmpty {
            addSubview(empty)
            primary.title = "Continue"
            skip.isHidden = true
            choose.isHidden = true
        }
        // Everything comes over unless you say otherwise; the choice is one click away for those who want it.
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & tabs")] {
            let pill = ChoicePill(title: name)
            pill.tint = Brand.ribbon
            pill.isHidden = true
            pill.onChange = { [weak self] _ in self?.refresh() }
            addSubview(pill)
            pills.append((choice, pill))
        }
        addSubview(choose)
        choose.onClick = { [weak self] _ in
            guard let self else { return }
            self.showsChoices.toggle()
            self.choose.title = self.showsChoices ? "Bring everything" : "Choose what to bring"
            if !self.showsChoices { self.pills.forEach { $0.1.isOn = true } }
            self.refresh()
        }
        primary.onClick = { [weak self] _ in self?.primaryAction() }
        skip.onClick = { [weak self] _ in self?.onContinue?() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var chosen: [BrowserTile] { tiles.filter(\.isChosen) }

    private var choice: ImportCoordinator.Choice {
        pills.reduce(into: []) { result, pair in if pair.1.isOn { result.insert(pair.0) } }
    }

    private func refresh() {
        let arc = chosen.contains { $0.source.offers.contains(.tabs) }
        for (kind, pill) in pills { pill.isHidden = !showsChoices || isImporting || isDone || (kind == .tabs && !arc) }
        choose.isHidden = tiles.isEmpty || isImporting || isDone
        primary.isEnabled = isDone || tiles.isEmpty || (!isImporting && !chosen.isEmpty && !choice.isEmpty)
        needsLayout = true
    }

    private func primaryAction() {
        if isDone || tiles.isEmpty { onContinue?(); return }
        run(chosen)
    }

    private func run(_ tiles: [BrowserTile]) {
        isImporting = true
        primary.title = "Importing…"
        skip.isHidden = true
        line.stringValue = "If macOS asks to let Zigzag open a browser’s passwords, choose Allow."
        self.tiles.forEach { $0.isLocked = true }
        tiles.forEach { $0.state = .waiting }
        refresh()
        let choice = self.choice
        Task { @MainActor in
            for tile in tiles {
                tile.state = .working
                let summary = await ImportCoordinator.run(tile.source, choice.intersection(tile.source.offers))
                tile.state = .done(summary)
                tile.onFix = { [weak self, weak tile] fix in
                    guard let self, let tile else { return }
                    self.fix(fix, tile)
                }
            }
            self.finish()
        }
    }

    private func finish() {
        isImporting = false
        isDone = true
        primary.title = "Continue"
        let failed = tiles.contains { if case .done(let s) = $0.state { !s.problems.isEmpty } else { false } }
        line.stringValue = failed ? "Some of it didn’t come over. Fix it here, or bring it over later from Settings." : "It’s all in Zigzag now."
        refresh()
    }

    private func fix(_ fix: ImportProblem.Fix, _ tile: BrowserTile) {
        switch fix {
        case .retry:
            isDone = false
            run([tile])
        case .fullDiskAccess:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            tile.awaitsRetry = true
        case .primaryPassword, .exportFromApplePasswords:
            // These need a password or an export file; the Import window walks through both.
            ImportWindowController.show()
        case .none:
            break
        }
    }

    override func layout() {
        super.layout()
        var y = Onboard.header(title, line, in: bounds, top: 72) + Tokens.Space.x8
        let width: CGFloat = 460, gap = Tokens.Space.x3
        let x = (bounds.width - width) / 2
        let tileWidth = (width - gap) / 2, tileHeight: CGFloat = 68
        for (i, tile) in tiles.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            tile.frame = NSRect(x: x + col * (tileWidth + gap), y: y + row * (tileHeight + gap), width: tileWidth, height: tileHeight)
        }
        if !tiles.isEmpty { y = (tiles.last?.frame.maxY ?? y) + Tokens.Space.x5 }
        if tiles.isEmpty {
            empty.frame = NSRect(x: x, y: y, width: width, height: 40)
            y = empty.frame.maxY + Tokens.Space.x5
        }
        let cw = choose.fittingWidth
        choose.frame = NSRect(x: (bounds.width - cw) / 2, y: y, width: cw, height: Tokens.Space.x8)
        if showsChoices {
            let visible = pills.filter { !$0.1.isHidden }.map(\.1)
            let widths = visible.map { $0.intrinsicContentSize.width }
            let total = widths.reduce(0, +) + CGFloat(max(visible.count - 1, 0)) * Tokens.Space.x2
            var px = (bounds.width - total) / 2
            for (pill, w) in zip(visible, widths) {
                pill.frame = NSRect(x: px, y: choose.frame.maxY + Tokens.Space.x2, width: w, height: Tokens.Space.x8)
                px += w + Tokens.Space.x2
            }
        }
        Onboard.footer(primary: primary, quiet: skip.isHidden ? nil : skip, in: bounds)
    }
}

/// A browser you can bring over: its icon, its name, what it holds; then how the import went.
private final class BrowserTile: InteractiveView {
    enum State { case idle, waiting, working, done(ImportCoordinator.Summary) }
    let source: ImportCoordinator.Source
    var isChosen = false { didSet { stateDidChange(animated: true) } }
    var isLocked = false
    var awaitsRetry = false { didSet { if awaitsRetry { fixButton.title = "Try Again" ; fixKind = .retry; needsLayout = true } } }
    var onToggle: (() -> Void)?
    var onFix: ((ImportProblem.Fix) -> Void)?
    var state = State.idle { didSet { refreshState() } }

    private let icon = NSImageView()
    private let name: Label
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let spinner = RibbonView()
    private let fixButton = TextButton(title: "", font: Tokens.Font.small(.semibold))
    private var fixKind: ImportProblem.Fix = .none

    init(source: ImportCoordinator.Source) {
        self.source = source
        name = Label(source.name, font: Tokens.Font.body(.semibold), color: Onboard.ink)
        super.init(frame: .zero)
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        icon.image = source.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 16)
        check.contentTintColor = Onboard.ink
        spinner.color = Onboard.ink
        spinner.isHidden = true
        fixButton.textColor = Onboard.ink
        fixButton.showsFillAtRest = true
        fixButton.isHidden = true
        fixButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.onFix?(self.fixKind)
        }
        detail.font = Tokens.Font.small()
        detail.textColor = Onboard.dim(0.66)
        detail.isSelectable = false
        detail.maximumNumberOfLines = 2
        [icon, name, detail, check, spinner, fixButton].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked else { return }
            self.isChosen.toggle()
            self.onToggle?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(source.name)
        Task { @MainActor [weak self] in
            let text = await ImportCoordinator.preview(source)
            guard let self, case .idle = self.state else { return }
            self.detail.stringValue = Self.short(text)
            self.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func refreshState() {
        spinner.stopLooping()
        spinner.isHidden = true
        fixButton.isHidden = true
        switch state {
        case .idle: break
        case .waiting:
            detail.stringValue = isChosen ? "Waiting…" : detail.stringValue
        case .working:
            detail.stringValue = "Bringing it over…"
            spinner.isHidden = false
            spinner.startLooping()
        case .done(let summary):
            if let problem = summary.problems.first {
                detail.stringValue = problem.message
                detail.textColor = Tokens.Color.caution.blended(withFraction: 0.35, of: .white) ?? Tokens.Color.caution
                toolTip = summary.problems.map(\.message).joined(separator: "\n")
                fixKind = problem.fix
                switch problem.fix {
                case .retry: fixButton.title = "Try Again"
                case .fullDiskAccess: fixButton.title = "Allow"
                case .primaryPassword: fixButton.title = "Unlock"
                case .exportFromApplePasswords: fixButton.title = "Show Me"
                case .none: break
                }
                fixButton.isHidden = problem.fix == .none
            } else {
                detail.textColor = Onboard.dim(0.66)
                detail.stringValue = Self.sentence(summary)
            }
        }
        stateDidChange(animated: true)
        needsLayout = true
    }

    /// The tile has room for a few words: the long previews say the same thing shorter here.
    private static func short(_ text: String) -> String {
        text.replacingOccurrences(of: "macOS will need your permission to read it", with: "Needs your permission")
            .replacingOccurrences(of: "Bookmarks and history need your permission", with: "Needs your permission")
            .replacingOccurrences(of: " · passwords from the Passwords app", with: "")
            .replacingOccurrences(of: "spaces and pinned tabs", with: "spaces")
    }

    /// "214 passwords · 3 spaces", or that nothing new was needed.
    private static func sentence(_ s: ImportCoordinator.Summary) -> String {
        func n(_ v: Int, _ one: String, _ many: String) -> String? { v > 0 ? "\(v.formatted()) \(v == 1 ? one : many)" : nil }
        let parts = [n(s.passwords + s.updatedPasswords, "password", "passwords"), n(s.spaces, "space", "spaces"),
                     n(s.bookmarks, "bookmark", "bookmarks"), n(s.history, "page of history", "pages of history")].compactMap { $0 }
        return parts.isEmpty ? "Nothing new to bring" : parts.joined(separator: " · ")
    }

    override func stateDidChange(animated: Bool) {
        let on = isChosen
        let fill = Brand.ribbon.withAlphaComponent(on ? (isPressed ? 0.22 : 0.16) : (isHovered && !isLocked ? 0.1 : 0.06))
        layer?.set(backgroundColor: fill.cgColor, animated: animated)
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = Brand.ribbon.withAlphaComponent(0.55).cgColor
        let showsCheck: Bool = { if case .done(let s) = state { return s.problems.isEmpty } else { return on && !isLocked } }()
        check.isHidden = !showsCheck
        alphaValue = isLocked && !on ? 0.45 : 1
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x4
        let s: CGFloat = 32
        icon.frame = NSRect(x: pad, y: (bounds.height - s) / 2, width: s, height: s)
        let x = icon.frame.maxX + Tokens.Space.x3
        var right = bounds.width - pad
        if !fixButton.isHidden {
            let w = fixButton.fittingWidth
            right -= w
            fixButton.frame = NSRect(x: right, y: (bounds.height - Tokens.Space.x7Height) / 2, width: w, height: Tokens.Space.x7Height)
            right -= Tokens.Space.x2
        }
        check.frame = NSRect(x: bounds.width - pad - 16, y: Tokens.Space.x3, width: 16, height: 16)
        spinner.frame = NSRect(x: bounds.width - pad - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let textRight = check.isHidden && spinner.isHidden ? right : min(right, check.frame.minX - Tokens.Space.x2)
        let dh = min(ceil(detail.sizeThatFits(NSSize(width: right - x, height: 100)).height), 32)
        let block = name.lineHeight + 2 + dh
        name.frame = NSRect(x: x, y: (bounds.height - block) / 2, width: textRight - x, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: name.frame.maxY + 2, width: right - x, height: dh)
    }
}

// MARK: - 3. Make it yours

private final class PersonalizePage: NSView {
    var onColor: (() -> Void)?
    var onContinue: (() -> Void)?
    private let spaceID: UUID?
    private let title = Onboard.title("Make it yours")
    private let line = Onboard.line("Pick a color for your first space. Each space can have its own, and you can change it anytime.")
    private var swatches: [(SpaceColor, ColorView)] = []
    private let card = ColorView(color: Brand.ribbon.withAlphaComponent(0.08))
    private let cardTitle = Label("Your default browser", font: Tokens.Font.body(.semibold), color: Onboard.ink)
    private let cardLine = Label("Links from other apps open in Zigzag.", font: Tokens.Font.small(), color: Onboard.dim(0.66))
    private let makeDefault = Onboard.primary("Make Default")
    private let isDefaultLabel = Label("", font: Tokens.Font.body(.medium), color: Onboard.ink)
    private let next = Onboard.primary("Continue")

    init(spaceID: UUID?) {
        self.spaceID = spaceID
        super.init(frame: .zero)
        [title, line, card, cardTitle, cardLine, makeDefault, isDefaultLabel, next].forEach { addSubview($0) }
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        for color in SpaceColor.allCases {
            let dot = ColorView(color: color.swatch)
            dot.wantsLayer = true
            let click = NSClickGestureRecognizer(target: self, action: #selector(picked(_:)))
            dot.addGestureRecognizer(click)
            dot.toolTip = "\(color)".capitalized
            addSubview(dot)
            swatches.append((color, dot))
        }
        makeDefault.onClick = { [weak self] _ in
            DefaultBrowser.make()
            // macOS asks to confirm; the card catches up once it has.
            for delay in [1.0, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refreshDefault() }
            }
        }
        next.onClick = { [weak self] _ in self?.onContinue?() }
        refreshDefault()
        refreshSwatches()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func picked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let color = swatches.first(where: { $0.1 === view })?.0, let spaceID else { return }
        Library.shared.setColor(color, for: spaceID)
        refreshSwatches()
        onColor?()
    }

    private func refreshSwatches() {
        let current = Library.shared.spaces.first { $0.id == spaceID }
        for (color, dot) in swatches {
            let on = current?.hue == nil && current?.color == color
            dot.layer?.borderWidth = on ? 3 : 0
            dot.layer?.borderColor = Brand.ribbon.cgColor
        }
    }

    private func refreshDefault() {
        let isDefault = SettingsWindowController.isDefaultBrowser
        makeDefault.isHidden = isDefault
        isDefaultLabel.isHidden = !isDefault
        isDefaultLabel.stringValue = "✓  It’s Zigzag"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y = Onboard.header(title, line, in: bounds, top: 96) + Tokens.Space.x8
        let size: CGFloat = 36, gap = Tokens.Space.x4
        let total = CGFloat(swatches.count) * size + CGFloat(swatches.count - 1) * gap
        var x = (bounds.width - total) / 2
        for (_, dot) in swatches {
            dot.frame = NSRect(x: x, y: y, width: size, height: size)
            dot.layer?.cornerRadius = size / 2
            x += size + gap
        }
        y += size + Tokens.Space.x12
        let width: CGFloat = 460
        let cx = (bounds.width - width) / 2
        card.frame = NSRect(x: cx, y: y, width: width, height: 72)
        let pad = Tokens.Space.x5
        let block = cardTitle.lineHeight + 2 + cardLine.lineHeight
        cardTitle.frame = NSRect(x: cx + pad, y: y + (72 - block) / 2, width: 260, height: cardTitle.lineHeight)
        cardLine.frame = NSRect(x: cx + pad, y: cardTitle.frame.maxY + 2, width: 260, height: cardLine.lineHeight)
        let bw = max(makeDefault.fittingWidth, 120)
        makeDefault.frame = NSRect(x: card.frame.maxX - pad - bw, y: y + (72 - Tokens.Space.x8) / 2, width: bw, height: Tokens.Space.x8)
        let lw = isDefaultLabel.textWidth + 4
        isDefaultLabel.frame = NSRect(x: card.frame.maxX - pad - lw, y: y + (72 - isDefaultLabel.lineHeight) / 2, width: lw, height: isDefaultLabel.lineHeight)
        Onboard.footer(primary: next, quiet: nil, in: bounds)
    }
}

// MARK: - 4. Ready

private final class ReadyPage: NSView {
    var onStart: (() -> Void)?
    private let title = Onboard.title("You’re ready")
    private let line = Onboard.line("Three keys worth knowing. Every other one is in Settings › Shortcuts.")
    private var rows: [(caps: [ColorView], label: Label)] = []
    private let start = Onboard.primary("Start Browsing")

    /// What each key does, read from the menus themselves, so a shortcut you've changed shows as you set it.
    private static let tips: [(Selector, String)] = [
        (#selector(BrowserWindowController.newTab(_:)), "Open a page or search, from anywhere"),
        (#selector(BrowserWindowController.toggleBookmark(_:)), "Pin the page you’re on to its space"),
        (#selector(BrowserWindowController.toggleBrowserSidebar(_:)), "Show or hide the sidebar"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        [title, line, start].forEach { addSubview($0) }
        for (action, text) in Self.tips {
            let keys = Shortcuts.allItems.first { $0.action == action }.map(Shortcuts.caps) ?? []
            let caps: [ColorView] = keys.map { key in
                let cap = ColorView(color: Brand.ribbon.withAlphaComponent(0.14))
                cap.wantsLayer = true
                cap.layer?.cornerRadius = 7
                cap.layer?.cornerCurve = .continuous
                let label = Label(key, font: .systemFont(ofSize: 14, weight: .semibold), color: Onboard.ink)
                label.alignment = .center
                cap.addSubview(label)
                addSubview(cap)
                return cap
            }
            let label = Label(text, font: Tokens.Font.body(), color: Onboard.ink)
            addSubview(label)
            rows.append((caps, label))
        }
        start.onClick = { [weak self] _ in self?.onStart?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var y = Onboard.header(title, line, in: bounds, top: 96) + Tokens.Space.x10
        let width: CGFloat = 400
        let x = (bounds.width - width) / 2
        let capSize: CGFloat = 30
        for (caps, label) in rows {
            var cx = x
            for cap in caps {
                let text = cap.subviews.first as? Label
                let w = max(capSize, (text?.inkWidth ?? 0) + Tokens.Space.x4)
                cap.frame = NSRect(x: cx, y: y, width: w, height: capSize)
                text?.frame = NSRect(x: 0, y: (capSize - (text?.lineHeight ?? 0)) / 2, width: w, height: text?.lineHeight ?? 0)
                cx += w + 5
            }
            let lx = x + 116
            label.frame = NSRect(x: lx, y: y + (capSize - label.lineHeight) / 2, width: x + width - lx, height: label.lineHeight)
            y += capSize + Tokens.Space.x4
        }
        Onboard.footer(primary: start, quiet: nil, in: bounds)
    }
}
