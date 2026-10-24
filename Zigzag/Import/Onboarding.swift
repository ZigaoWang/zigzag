import AppKit

/// First launch: a hello, then a few short steps on the brand's blue. Each has a title and one line, the thing to
/// do in the middle, and the same bottom row: Back, Skip, Next.
final class OnboardingView: NSView {
    var onFinish: (() -> Void)?

    enum Step: Int, CaseIterable { case hello, bring, sites, extensions, ads, color, ready }
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
        show(Self.resumeOnBring ? .bring : .hello, animated: false)
        Self.resumeOnBring = false
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(_ next: Step, animated: Bool) {
        let forward = next.rawValue >= step.rawValue
        step = next
        let view: NSView
        if next == .hello {
            let hello = HelloPage()
            hello.onStart = { [weak self] in self?.show(.bring, animated: true) }
            view = hello
        } else {
            let content: StepContent
            let title: String, body: String
            switch next {
            case .bring:
                content = BringPicker()
                title = "Bring your stuff over"
                body = "Pick the browsers to bring from. They stay exactly as they are."
            case .sites:
                content = SitesPicker()
                title = "Your everyday sites"
                body = "Pick the ones you open every day. They sit at the top of your sidebar."
            case .extensions:
                content = ExtensionsPicker()
                title = "Your extensions"
                body = "Chrome extensions work in Zigzag. Pick the ones you use."
            case .ads:
                content = AdsPicker()
                title = "Block ads?"
                body = "Zigzag can stop ads and trackers on every site. You can change this per site later."
            case .color:
                content = ColorPicker()
                (content as? ColorPicker)?.onColor = { [weak self] in self?.applySpaceColor() }
                title = "Make it yours"
                body = "Pick a color for your first space, and how it looks."
            default:
                content = ReadyPicker()
                title = "You’re ready"
                body = "One last thing: open links from other apps in Zigzag."
            }
            let stepPage = StepPage(title: title, body: body, content: content, showsBack: true,
                                    showsSkip: next != .ready)
            stepPage.onBack = { [weak self] in
                guard let self, let back = Step(rawValue: next.rawValue - 1) else { return }
                self.show(back, animated: true)
            }
            stepPage.onNext = { [weak self] in
                guard let self else { return }
                if let after = Step(rawValue: next.rawValue + 1) { self.show(after, animated: true) } else { self.onFinish?() }
            }
            view = stepPage
        }
        let old = page
        page = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        guard animated, let old else { old?.removeFromSuperview(); return }
        window?.makeFirstResponder(nil)
        slide(from: old, to: view, forward: forward)
    }

    /// Moving on: the screen you're leaving drifts a little aside as it fades, the next arrives from the other
    /// side. One smooth ease-out, short, no bounce.
    private func slide(from old: NSView, to new: NSView, forward: Bool) {
        [old, new].forEach { $0.wantsLayer = true }
        guard let oldLayer = old.layer, let newLayer = new.layer else { old.removeFromSuperview(); return }
        let distance: CGFloat = forward ? 36 : -36
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

    override func layout() {
        super.layout()
        surface.frame = bounds
        page?.frame = bounds
    }
}

// MARK: - The step layout

/// What a step's right side is: the thing to do, and what its main button says.
class StepContent: NSView {
    var onChange: (() -> Void)?
    var primaryTitle: String { "Next" }
    var primaryEnabled: Bool { true }
    var isBusy: Bool { false }
    /// The main button: do what the step needs, then call `done` to move on (now, or once it's finished).
    func commit(_ done: @escaping () -> Void) { done() }
    override var isFlipped: Bool { true }
}

/// One step on the blue: title and line at the top, the step in the middle, and Back, Skip and Next at the bottom.
private final class StepPage: NSView {
    var onBack: (() -> Void)?
    var onNext: (() -> Void)?
    private let title: NSTextField
    private let body: NSTextField
    private let back = Onboard.quiet("Back")
    private let next = Onboard.primary("Next")
    private let skip = Onboard.quiet("Skip")
    private let content: StepContent

    init(title text: String, body bodyText: String, content: StepContent, showsBack: Bool, showsSkip: Bool) {
        self.content = content
        title = Onboard.title(text)
        body = Onboard.line(bodyText)
        super.init(frame: .zero)
        back.isHidden = !showsBack
        skip.isHidden = !showsSkip
        [title, body, content, back, skip, next].forEach { addSubview($0) }
        back.onClick = { [weak self] _ in self?.onBack?() }
        skip.onClick = { [weak self] _ in self?.onNext?() }
        next.onClick = { [weak self] _ in
            guard let self else { return }
            self.content.commit { [weak self] in self?.onNext?() }
            self.refresh()
        }
        content.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func refresh() {
        next.title = content.primaryTitle
        next.isEnabled = content.primaryEnabled && !content.isBusy
        skip.isEnabled = !content.isBusy
        back.isEnabled = !content.isBusy
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 520
        let x = (bounds.width - width) / 2
        let top = Onboard.header(title, body, in: bounds, top: 56, width: 560) + Tokens.Space.x6
        // Bottom row: Back on the left; Skip beside Next on the right.
        let h = Tokens.Space.x10
        let y = bounds.height - 48 - h
        let nw = max(next.fittingWidth, 140)
        next.frame = NSRect(x: x + width - nw, y: y, width: nw, height: h)
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: next.frame.minX - Tokens.Space.x3 - sw, y: y + (h - Tokens.Space.x8) / 2, width: sw, height: Tokens.Space.x8)
        back.frame = NSRect(x: x - Tokens.Space.x2, y: y + (h - Tokens.Space.x8) / 2, width: back.fittingWidth, height: Tokens.Space.x8)
        content.frame = NSRect(x: x - 20, y: top, width: width + 40, height: max(0, y - Tokens.Space.x6 - top))
    }
}

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

    /// A screen with one action: the button centered above the step dots.
    static func centeredFooter(_ primary: PrimaryButton, in bounds: NSRect) {
        let h = Tokens.Space.x10
        let w = max(primary.fittingWidth, 176)
        primary.frame = NSRect(x: round((bounds.width - w) / 2), y: bounds.height - 76 - h, width: w, height: h)
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

/// "Welcome to", then the wordmark writing itself in, then one button. Nothing else on the screen moves.
private final class HelloPage: NSView {
    var onStart: (() -> Void)?
    private let welcome = Label("Welcome to", font: .systemFont(ofSize: 18, weight: .medium), color: Onboard.dim(0.78))
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
        layer?.backgroundColor = Brand.ribbon.withAlphaComponent(isOn ? 0.16 : 0).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Brand.ribbon.withAlphaComponent(isOn ? 0 : 0.25).cgColor
        label.textColor = isOn ? Onboard.ink : Onboard.dim(0.55)
        check.contentTintColor = Onboard.ink
        check.isHidden = !isOn
        alphaValue = isLocked ? 0.5 : 1
        needsLayout = true
    }

    override func stateDidChange(animated: Bool) {
        guard !isLocked else { return }
        if isHovered && !isOn { layer?.backgroundColor = Brand.ribbon.withAlphaComponent(0.07).cgColor } else { refresh() }
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
    var isLocked = false { didSet { refresh() } }
    var onChange: (() -> Void)?
    var onFix: ((ImportProblem.Fix) -> Void)?
    var state = State.idle { didSet { refresh() } }
    /// macOS keeps this browser's files private until you allow Zigzag (macOS 27 does this for Chrome and others).
    private var needsAccess = false

    var isFinished: Bool { if case .done(let s) = state { s.problems.isEmpty } else { false } }
    var hasProblem: Bool { if case .done(let s) = state { !s.problems.isEmpty } else { needsAccess } }

    private let box = ColorView(color: .clear)
    private let tick = NSImageView()
    private let icon = NSImageView()
    private let name: Label
    private let detail = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.62))
    private let status = Label("", font: Tokens.Font.small(.medium), color: Onboard.ink)
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
        tick.contentTintColor = Brand.navy
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
        problem.textColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.55, alpha: 1)
        problem.isSelectable = false
        [box, icon, name, detail, status, spinner, fixButton, problem].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, !self.isLocked, !self.needsAccess, !self.isFinished else { return }
            self.isChosen.toggle()
            self.onChange?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(source.name)
        Task { @MainActor [weak self] in
            let text = await ImportCoordinator.preview(source)
            guard let self, case .idle = self.state else { return }
            if text.contains("permission") {
                // Found before starting, so it's fixed first instead of failing midway.
                self.needsAccess = true
                self.isChosen = false
                self.detail.stringValue = "macOS asks you to allow this once"
                self.fixKind = .fullDiskAccess
                self.onChange?()
            } else {
                self.detail.stringValue = text.replacingOccurrences(of: " · passwords from the Passwords app", with: "")
                    .replacingOccurrences(of: "spaces and pinned tabs", with: "spaces and pinned tabs")
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

    private static let rowHeight: CGFloat = 60

    func height(for width: CGFloat) -> CGFloat {
        guard !problem.stringValue.isEmpty else { return Self.rowHeight }
        let h = ceil(problem.sizeThatFits(NSSize(width: width - 62 - Tokens.Space.x4, height: 200)).height)
        return Self.rowHeight + h + Tokens.Space.x2
    }

    private func refresh() {
        spinner.stopLooping()
        spinner.isHidden = true
        status.isHidden = true
        fixButton.isHidden = true
        switch state {
        case .idle:
            if needsAccess {
                fixButton.title = waitingForSettings ? "Check Again" : triedPicker && !isSafari ? "Open Settings" : "Allow Access"
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
                problem.textColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.55, alpha: 1)
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
                status.stringValue = "Imported"
                status.textColor = Onboard.ink
                status.isHidden = false
                detail.stringValue = Self.sentence(summary)
            }
        }
        let on = isChosen || isFinished
        box.layer?.backgroundColor = on ? Brand.ribbon.cgColor : nil
        box.layer?.borderColor = Brand.ribbon.withAlphaComponent(on ? 1 : 0.45).cgColor
        tick.isHidden = !on
        box.alphaValue = needsAccess || (isLocked && !isChosen) ? 0.35 : 1
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
        let interactive = !isLocked && !needsAccess && !isFinished
        layer?.backgroundColor = interactive && isHovered ? Brand.ribbon.withAlphaComponent(isPressed ? 0.1 : 0.05).cgColor : nil
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
        if !fixButton.isHidden {
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
    }
}

// MARK: - Bring your stuff

/// The browsers on this Mac, each with a checkbox, what it holds, and how its import went. Anything macOS keeps
/// private says so before you start, with the fix beside it.
private final class BringPicker: StepContent {
    private let list = ColorView(color: Brand.ribbon.withAlphaComponent(0.07))
    private var rows: [BrowserRow] = []
    private var separators: [ColorView] = []
    private let empty = Onboard.line("No other browsers with something to bring were found on this Mac.")
    private let hint = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.7))
    private let bringLabel = Label("Bring", font: Tokens.Font.small(.medium), color: Onboard.dim(0.6))
    private var pills: [(ImportCoordinator.Choice, DataToggle)] = []
    private let fileLink = Onboard.quiet("Import a password file")
    private var isImporting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.wantsLayer = true
        list.layer?.cornerRadius = 12
        list.layer?.cornerCurve = .continuous
        list.layer?.borderWidth = 1
        list.layer?.borderColor = Brand.ribbon.withAlphaComponent(0.1).cgColor
        hint.alignment = .center
        [list, bringLabel, fileLink, hint].forEach { addSubview($0) }
        for (i, source) in ImportCoordinator.detectedSources().enumerated() { add(source, chosen: i == 0) }
        if rows.isEmpty { addSubview(empty) }
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & tabs")] {
            let pill = DataToggle(name)
            pill.onChange = { [weak self] in self?.refresh() }
            addSubview(pill)
            pills.append((choice, pill))
        }
        fileLink.onClick = { [weak self] _ in self?.pickFile() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTitle: String { isImporting ? "Importing…" : waiting.isEmpty ? "Next" : "Import" }
    override var primaryEnabled: Bool { waiting.isEmpty || !choice.isEmpty }
    override var isBusy: Bool { isImporting }

    override func commit(_ done: @escaping () -> Void) {
        let toDo = waiting
        if toDo.isEmpty { done(); return }
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
        list.addSubview(row)
        rows.append(row)
        if rows.count > 1 {
            let line = ColorView(color: Brand.ribbon.withAlphaComponent(0.09))
            list.addSubview(line)
            separators.append(line)
        }
        return row
    }

    private var waiting: [BrowserRow] { rows.filter { $0.isChosen && !$0.isFinished } }
    private var choice: ImportCoordinator.Choice { pills.reduce(into: []) { r, p in if p.1.isOn { r.insert(p.0) } } }

    private func refresh() {
        let arc = rows.contains { $0.isChosen && $0.source.offers.contains(.tabs) }
        pills.first { $0.0 == .tabs }?.1.isHidden = !arc
        pills.forEach { $0.1.isLocked = isImporting }
        rows.forEach { $0.isLocked = isImporting }
        let problems = rows.contains { if case .done(let s) = $0.state { !s.problems.isEmpty } else { false } }
        hint.stringValue = isImporting ? "If macOS asks to let Zigzag open a browser’s passwords, choose Allow."
            : problems ? "Some of it didn’t come over yet. The fix is next to it." : ""
        needsLayout = true
        onChange?()
    }

    private func run(_ rows: [BrowserRow]) {
        isImporting = true
        rows.forEach { $0.state = .waiting }
        refresh()
        let choice = self.choice
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
            self.isImporting = false
            self.refresh()
        }
    }

    private func fix(_ fix: ImportProblem.Fix, _ row: BrowserRow) {
        switch fix {
        case .retry:
            row.isChosen = true
            run([row])
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

    override func layout() {
        super.layout()
        let pad: CGFloat = 24
        let width = bounds.width - pad * 2
        var ry: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let h = row.height(for: width)
            row.frame = NSRect(x: 0, y: ry, width: width, height: h)
            ry += h
            if i < separators.count { separators[i].frame = NSRect(x: 62, y: ry, width: width - 62, height: Tokens.Metric.hairline) }
        }
        // The list, the choice of what to bring, and the file link, as one block in the middle.
        let block = ry + Tokens.Space.x5 + Tokens.Space.x8 + Tokens.Space.x3 + Tokens.Space.x8
        var y = max(pad, (bounds.height - block) / 2)
        list.isHidden = rows.isEmpty
        list.frame = NSRect(x: pad, y: y, width: width, height: ry)
        if rows.isEmpty {
            empty.frame = NSRect(x: pad, y: y, width: width, height: 40)
            ry = 40
        }
        y += ry + Tokens.Space.x5
        bringLabel.frame = NSRect(x: pad + 2, y: y + (Tokens.Space.x8 - bringLabel.lineHeight) / 2, width: 40, height: bringLabel.lineHeight)
        var px = bringLabel.frame.maxX + Tokens.Space.x1
        for (_, pill) in pills where !pill.isHidden {
            let w = pill.fittingWidth
            pill.frame = NSRect(x: px, y: y + 2, width: w, height: 28)
            px += w + Tokens.Space.x1
        }
        y += Tokens.Space.x8 + Tokens.Space.x3
        let fw = fileLink.fittingWidth
        fileLink.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: fw, height: Tokens.Space.x8)
        hint.frame = NSRect(x: pad, y: bounds.height - pad - hint.lineHeight, width: width, height: hint.lineHeight)
    }
}

// MARK: - Tiles

/// A square you tap to pick: an icon over a name, and a check when it's picked. Light on the blue.
private final class PickTile: InteractiveView {
    var isPicked = false { didSet { refresh() } }
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
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 16)
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
        let fill = Brand.ribbon.withAlphaComponent(isPicked ? 0.2 : (isHovered && !isLocked ? 0.1 : 0.06))
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = isPicked ? 1.5 : 0
        layer?.borderColor = Brand.ribbon.withAlphaComponent(0.7).cgColor
        check.isHidden = !isPicked || !spinner.isHidden
    }

    override func stateDidChange(animated: Bool) { refresh() }

    override func layout() {
        super.layout()
        check.frame = NSRect(x: bounds.width - 16 - 8, y: 8, width: 16, height: 16)
        spinner.frame = check.frame
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

private func loadIcon(_ tile: PickTile, site: URL, app: URL? = nil, explicit: URL? = nil) {
    if let app {
        tile.icon.image = NSWorkspace.shared.icon(forFile: app.path)
        tile.icon.contentTintColor = nil
        return
    }
    tile.icon.image = Tokens.Symbol.image("globe", size: 22)
    tile.icon.contentTintColor = Onboard.dim(0.7)
    guard let source = iconSource(site: site, explicit: explicit) else { return }
    fetchIcon(source) { [weak tile] image in
        tile?.icon.image = image
        tile?.icon.contentTintColor = nil
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
        Suggestion(name: "Spotify", url: URL(string: "https://open.spotify.com")!, app: "com.spotify.client"),
        Suggestion(name: "Slack", url: URL(string: "https://app.slack.com")!, app: "com.tinyspeck.slackmacgap"),
        Suggestion(name: "Figma", url: URL(string: "https://www.figma.com")!, app: "com.figma.Desktop"),
        Suggestion(name: "GitHub", url: URL(string: "https://github.com")!, app: "com.github.GitHubClient"),
        Suggestion(name: "WhatsApp", url: URL(string: "https://web.whatsapp.com")!, app: "net.whatsapp.WhatsApp"),
        Suggestion(name: "Discord", url: URL(string: "https://discord.com/app")!, app: "com.hnc.Discord"),
    ]
    /// Starts the icons while you're still on the first screens.
    static func preload() {
        for site in sites where site.appURL == nil { if let source = iconSource(site: site.url, explicit: site.icon) { fetchIcon(source) } }
    }

    /// Nine: the ones whose apps are on this Mac first, since those are the ones you use.
    private static var sites: [Suggestion] {
        let (have, rest) = (all.filter { $0.appURL != nil }, all.filter { $0.appURL == nil })
        return Array((have + rest).prefix(9))
    }
    private var tiles: [(PickTile, URL, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let have = Set(Library.shared.favorites.map { TabManager.normalize($0.url) })
        for site in Self.sites {
            let tile = PickTile(name: site.name)
            tile.isPicked = have.contains(TabManager.normalize(site.url))
            tile.onToggle = { [weak self] in self?.onChange?() }
            addSubview(tile)
            tiles.append((tile, site.url, site.name))
            loadIcon(tile, site: site.url, app: site.appURL, explicit: site.icon)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var picked: [(URL, String)] { tiles.filter { $0.0.isPicked }.map { ($0.1, $0.2) } }
    override var primaryTitle: String { picked.isEmpty ? "Next" : "Add \(picked.count)" }

    override func commit(_ done: @escaping () -> Void) {
        let have = Set(Library.shared.favorites.map { TabManager.normalize($0.url) })
        for (url, name) in picked where !have.contains(TabManager.normalize(url)) { _ = Library.shared.addFavorite(url: url, title: name) }
        done()
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 104, gap: CGFloat = 12
        let total = size * 3 + gap * 2
        let x0 = (bounds.width - total) / 2, y0 = max(0, (bounds.height - total) / 2)
        for (i, (tile, _, _)) in tiles.enumerated() {
            tile.frame = NSRect(x: x0 + CGFloat(i % 3) * (size + gap), y: y0 + CGFloat(i / 3) * (size + gap), width: size, height: size)
        }
    }
}

// MARK: - Extensions

/// Popular extensions as tiles; the ones you pick are added from the Chrome Web Store when you press Next, each
/// showing how it went.
private final class ExtensionsPicker: StepContent {
    private static let suggestions: [(id: String, name: String, kind: String, site: String)] = [
        (ExtensionStore.onePasswordID, "1Password", "Passwords", "https://1password.com"),
        ("nngceckbapebfimnlniiiahkandclblb", "Bitwarden", "Passwords", "https://bitwarden.com"),
        ("kbfnbcaeplbcioakkpcpgfkobkghlhen", "Grammarly", "Writing", "https://www.grammarly.com"),
        ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "Dark Reader", "Dark mode for sites", "https://darkreader.org"),
        ("knheggckgoiihginacbkhaalnibhilkk", "Notion Web Clipper", "Save pages", "https://www.notion.so"),
        ("aapbdbdomjkkjkaonfhkkikfgjllcleb", "Google Translate", "Translation", "https://translate.google.com"),
    ]
    private var tiles: [(PickTile, String)] = []
    private var installing = false
    private var finished = false
    private let note = Label("", font: Tokens.Font.small(), color: Onboard.dim(0.7))

    override init(frame: NSRect) {
        super.init(frame: frame)
        var installed: Set<String> = []
        if #available(macOS 15.4, *) { installed = Set(ExtensionHost.shared.installed.keys) }
        for s in Self.suggestions {
            let tile = PickTile(name: s.name, horizontal: true)
            tile.detail.stringValue = installed.contains(s.id) ? "Already added" : s.kind
            tile.isPicked = installed.contains(s.id)
            tile.isLocked = installed.contains(s.id)
            tile.onToggle = { [weak self] in self?.onChange?() }
            addSubview(tile)
            tiles.append((tile, s.id))
        }
        let apps: [String: String] = [ExtensionStore.onePasswordID: "com.1password.1password", "nngceckbapebfimnlniiiahkandclblb": "com.bitwarden.desktop"]
        for ((tile, id), s) in zip(tiles, Self.suggestions) {
            guard let site = URL(string: s.site) else { continue }
            loadIcon(tile, site: site, app: apps[id].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
        }
        note.alignment = .center
        note.stringValue = "More anytime from the Chrome Web Store: choose Add to Zigzag."
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var toAdd: [(PickTile, String)] { tiles.filter { $0.0.isPicked && !$0.0.isLocked } }
    override var primaryTitle: String { installing ? "Adding…" : (toAdd.isEmpty || finished) ? "Next" : "Add \(toAdd.count)" }
    override var isBusy: Bool { installing }

    override func commit(_ done: @escaping () -> Void) {
        let work = toAdd
        guard !work.isEmpty, !finished else { done(); return }
        installing = true
        onChange?()
        Task { @MainActor in
            var failed = false
            for (tile, id) in work {
                tile.isLocked = true
                tile.setWorking(true)
                tile.detail.stringValue = "Adding…"
                let result = await ExtensionStore.install(id)
                tile.setWorking(false)
                switch result {
                case .success: tile.detail.stringValue = "Added"
                case .failure(let error):
                    failed = true
                    tile.isPicked = false
                    tile.isLocked = false
                    tile.detail.stringValue = "Couldn’t add it"
                    tile.toolTip = error.message
                }
            }
            self.installing = false
            self.finished = true
            if failed {
                // Say so, and wait: Next then moves on.
                self.note.stringValue = "Some couldn’t be added. Check your connection, or add them later from the Chrome Web Store."
                self.onChange?()
            } else {
                done()
            }
        }
    }

    override func layout() {
        super.layout()
        let w: CGFloat = 228, h: CGFloat = 64, gap: CGFloat = 12
        let total = w * 2 + gap
        let rows = CGFloat((tiles.count + 1) / 2)
        let blockH = rows * h + (rows - 1) * gap
        let x0 = (bounds.width - total) / 2, y0 = max(0, (bounds.height - blockH - 40) / 2)
        for (i, (tile, _)) in tiles.enumerated() {
            tile.frame = NSRect(x: x0 + CGFloat(i % 2) * (w + gap), y: y0 + CGFloat(i / 2) * (h + gap), width: w, height: h)
        }
        note.frame = NSRect(x: 0, y: y0 + blockH + 20, width: bounds.width, height: note.lineHeight)
    }
}

// MARK: - Ads

/// Two clear answers, one picked: block ads and trackers, or leave sites as they are.
private final class AdsPicker: StepContent {
    private let block = ChoiceCard(title: "Block ads and trackers", detail: "Pages load faster, and fewer sites follow you around.", recommended: true)
    private let allow = ChoiceCard(title: "Leave them on", detail: "Sites show everything, ads included.", recommended: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        [block, allow].forEach { addSubview($0) }
        pick(ContentBlocker.isEnabled)
        block.onClick = { [weak self] _ in self?.pick(true) }
        allow.onClick = { [weak self] _ in self?.pick(false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pick(_ on: Bool) {
        block.isChosen = on
        allow.isChosen = !on
    }

    override func commit(_ done: @escaping () -> Void) {
        ContentBlocker.isEnabled = block.isChosen
        done()
    }

    override func layout() {
        super.layout()
        let w: CGFloat = 420, h: CGFloat = 76, gap: CGFloat = 14
        let y0 = max(0, (bounds.height - h * 2 - gap) / 2)
        block.frame = NSRect(x: (bounds.width - w) / 2, y: y0, width: w, height: h)
        allow.frame = NSRect(x: (bounds.width - w) / 2, y: y0 + h + gap, width: w, height: h)
    }
}

/// A choice you can only pick one of: a ring, a title and a line.
private final class ChoiceCard: InteractiveView {
    var isChosen = false { didSet { refresh() } }
    private let ring = ColorView(color: .clear)
    private let dot = ColorView(color: Onboard.ink)
    private let title: Label
    private let detail: Label
    private let badge = Label("Recommended", font: .systemFont(ofSize: 11, weight: .semibold), color: Brand.navy)
    private let badgeFill = ColorView(color: Brand.ribbon)

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
        layer?.backgroundColor = Brand.ribbon.withAlphaComponent(isChosen ? 0.16 : (isHovered ? 0.09 : 0.05)).cgColor
        layer?.borderWidth = isChosen ? 1.5 : 0
        layer?.borderColor = Brand.ribbon.withAlphaComponent(0.7).cgColor
        ring.layer?.borderColor = Brand.ribbon.withAlphaComponent(isChosen ? 1 : 0.45).cgColor
        dot.isHidden = !isChosen
    }

    override func layout() {
        super.layout()
        ring.frame = NSRect(x: 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        dot.frame = NSRect(x: 5, y: 5, width: 10, height: 10)
        let x = ring.frame.maxX + 16
        let block = title.lineHeight + 2 + detail.lineHeight
        title.frame = NSRect(x: x, y: (bounds.height - block) / 2, width: title.textWidth + 4, height: title.lineHeight)
        detail.frame = NSRect(x: x, y: title.frame.maxY + 2, width: bounds.width - x - 16, height: detail.lineHeight)
        let bw = badge.textWidth + 14
        badgeFill.frame = NSRect(x: title.frame.maxX + 8, y: title.frame.midY - 10, width: bw, height: 20)
        badge.frame = NSRect(x: 0, y: (20 - badge.lineHeight) / 2, width: bw, height: badge.lineHeight)
    }
}

// MARK: - Color

/// A small Zigzag window that takes on your space's color as you pick it, with the colors and Light, Dark or
/// Automatic underneath.
private final class ColorPicker: StepContent {
    var onColor: (() -> Void)?
    private let preview = MiniBrowser()
    private var swatches: [(SpaceColor, ColorView)] = []
    private var looks: [(String?, DataToggle)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(preview)
        for color in SpaceColor.allCases {
            let dot = ColorView(color: color.swatch)
            dot.wantsLayer = true
            dot.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(picked(_:))))
            addSubview(dot)
            swatches.append((color, dot))
        }
        for (value, name) in [(nil, "Automatic"), ("light", "Light"), ("dark", "Dark")] as [(String?, String)] {
            let toggle = DataToggle(name)
            toggle.onChange = { [weak self] in self?.look(value) }
            addSubview(toggle)
            looks.append((value, toggle))
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var space: SpaceInfo? { Library.shared.spaces.first }

    @objc private func picked(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let color = swatches.first(where: { $0.1 === view })?.0, let id = space?.id else { return }
        Library.shared.setColor(color, for: id)
        refresh()
        onColor?()
    }

    private func look(_ value: String?) {
        guard let id = space?.id else { return }
        Library.shared.setAppearance(value, for: id)
        refresh()
    }

    private func refresh() {
        let current = space
        for (color, dot) in swatches {
            let on = current?.hue == nil && current?.color == color
            dot.layer?.borderWidth = on ? 3 : 0
            dot.layer?.borderColor = Brand.ribbon.cgColor
        }
        for (value, toggle) in looks { toggle.isOn = current?.appearance == value }
        preview.show(background: current?.background ?? SpaceColor.sky.background, appearance: current?.appearance)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let ww: CGFloat = 400, wh: CGFloat = 230
        let size: CGFloat = 30, gap: CGFloat = 12
        let swW = CGFloat(swatches.count) * size + CGFloat(swatches.count - 1) * gap
        let lookW = looks.map { $0.1.fittingWidth }.reduce(0, +) + CGFloat(looks.count - 1) * 8
        let block = wh + 24 + size + 18 + 28
        var y = max(0, (bounds.height - block) / 2)
        preview.frame = NSRect(x: (bounds.width - ww) / 2, y: y, width: ww, height: wh)
        y = preview.frame.maxY + 24
        var x = (bounds.width - swW) / 2
        for (_, dot) in swatches {
            dot.frame = NSRect(x: x, y: y, width: size, height: size)
            dot.layer?.cornerRadius = size / 2
            x += size + gap
        }
        y += size + 18
        x = (bounds.width - lookW) / 2
        for (_, toggle) in looks {
            let w = toggle.fittingWidth
            toggle.frame = NSRect(x: x, y: y, width: w, height: 28)
            x += w + 8
        }
    }
}

/// A drawing of a Zigzag window in your space's color: traffic lights, the address field, three favorites, a
/// few tabs with one selected, the space dots, and a page. Drawn rather than captured, so it changes as you pick.
private final class MiniBrowser: NSView {
    private var background: NSColor = SpaceColor.sky.background
    private var accent: NSColor = Brand.Theme.brand.accent
    private var isDark = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(background: NSColor, appearance: String?) {
        self.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.isDark = self.effectiveAppearance.isDark
            self.background = background.usingColorSpace(.sRGB) ?? background
            self.accent = Brand.Theme.of(Library.shared.spaces.first).accent.usingColorSpace(.sRGB) ?? Brand.Theme.brand.accent
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = isDark ? NSColor.white : NSColor.black
        background.setFill()
        bounds.fill()
        func box(_ r: NSRect, _ color: NSColor, _ radius: CGFloat) {
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        let side: CGFloat = 112, pad: CGFloat = 10
        // Traffic lights.
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: pad + CGFloat(i) * 11, y: 10, width: 7, height: 7)).fill()
        }
        // Address field.
        box(NSRect(x: pad, y: 26, width: side - pad * 2, height: 14), ink.withAlphaComponent(0.07), 5)
        // Favorites.
        let favW = (side - pad * 2 - 8) / 3
        let favColors: [NSColor] = [.systemRed, .systemRed.blended(withFraction: 0.3, of: .systemOrange) ?? .systemRed, .systemBlue]
        for i in 0..<3 {
            let r = NSRect(x: pad + CGFloat(i) * (favW + 4), y: 46, width: favW, height: 20)
            box(r, ink.withAlphaComponent(0.06), 5)
            box(NSRect(x: r.midX - 4, y: r.midY - 4, width: 8, height: 8), favColors[i].withAlphaComponent(0.85), 2)
        }
        // Tabs: one selected, lit like the real thing.
        for i in 0..<4 {
            let r = NSRect(x: pad - 2, y: 76 + CGFloat(i) * 18, width: side - pad * 2 + 4, height: 15)
            if i == 1 { box(r, isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.8), 5) }
            box(NSRect(x: r.minX + 5, y: r.midY - 3, width: 6, height: 6), (i == 1 ? accent : ink.withAlphaComponent(0.25)), 2)
            box(NSRect(x: r.minX + 15, y: r.midY - 2, width: [52, 62, 44, 56][i], height: 4), ink.withAlphaComponent(i == 1 ? 0.45 : 0.18), 2)
        }
        // Space dots, the current one in the accent.
        for i in 0..<3 {
            (i == 0 ? accent : ink.withAlphaComponent(0.2)).setFill()
            NSBezierPath(ovalIn: NSRect(x: side / 2 - 16 + CGFloat(i) * 13, y: bounds.height - 16, width: 6, height: 6)).fill()
        }
        // The page.
        let page = NSRect(x: side, y: 8, width: bounds.width - side - 8, height: bounds.height - 16)
        box(page, isDark ? NSColor(white: 0.12, alpha: 1) : .white, 8)
        let text = (isDark ? NSColor.white : NSColor.black)
        box(NSRect(x: page.minX + 14, y: page.minY + 16, width: page.width * 0.5, height: 8), text.withAlphaComponent(0.7), 3)
        for (k, w) in [0.86, 0.78, 0.82, 0.6].enumerated() {
            box(NSRect(x: page.minX + 14, y: page.minY + 34 + CGFloat(k) * 11, width: (page.width - 28) * w, height: 5), text.withAlphaComponent(0.14), 2)
        }
        box(NSRect(x: page.minX + 14, y: page.minY + 86, width: page.width - 28, height: page.height - 100), accent.withAlphaComponent(0.18), 6)
        box(NSRect(x: page.minX + 14, y: page.minY + 86, width: 54, height: 16), accent, 5)
    }
}

// MARK: - Ready

/// The last step: make Zigzag the browser links open in, then start.
private final class ReadyPicker: StepContent {
    private let card = ColorView(color: Brand.ribbon.withAlphaComponent(0.08))
    private let title = Label("Make Zigzag your default browser", font: Tokens.Font.body(.semibold), color: Onboard.ink)
    private let line = Label("Links from other apps open here.", font: Tokens.Font.small(), color: Onboard.dim(0.65))
    private let button = Onboard.primary("Make Default")
    private let done = Label("✓  Zigzag is your default browser", font: Tokens.Font.body(.medium), color: Onboard.ink)

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        [card, title, line, button, done].forEach { addSubview($0) }
        button.onClick = { [weak self] _ in
            DefaultBrowser.make()
            // macOS asks to confirm; the card catches up once it has.
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
        title.isHidden = isDefault
        line.isHidden = isDefault
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w: CGFloat = 460, h: CGFloat = 80
        let r = NSRect(x: (bounds.width - w) / 2, y: max(0, (bounds.height - h) / 2), width: w, height: h)
        card.frame = r
        let block = title.lineHeight + 2 + line.lineHeight
        let bw = max(button.fittingWidth, 124)
        let tw = w - 40 - bw - 16
        title.frame = NSRect(x: r.minX + 20, y: r.minY + (h - block) / 2, width: tw, height: title.lineHeight)
        line.frame = NSRect(x: r.minX + 20, y: title.frame.maxY + 2, width: tw, height: line.lineHeight)
        button.frame = NSRect(x: r.maxX - 20 - bw, y: r.minY + (h - Tokens.Space.x8) / 2, width: bw, height: Tokens.Space.x8)
        done.frame = NSRect(x: r.minX, y: r.minY + (h - done.lineHeight) / 2, width: w, height: done.lineHeight)
        done.alignment = .center
    }
}

