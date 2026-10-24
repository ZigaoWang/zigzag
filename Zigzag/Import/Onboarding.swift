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

    /// Set if Zigzag has to reopen to pick up a permission: onboarding then picks up on the import screen.
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
        for _ in Step.allCases {
            let dot = CALayer()
            dot.cornerRadius = 3
            dot.zPosition = 10
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        show(Self.resumeOnBring ? .bring : .hello, animated: false)
        Self.resumeOnBring = false
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

// MARK: - 2. Bring your stuff

/// The browsers on this Mac in one list, each with a checkbox, what it holds, and how its import went. Anything
/// macOS keeps private says so before you start, with the fix beside it; problems are written out in full.
private final class BringPage: NSView {
    var onContinue: (() -> Void)?
    private let title = Onboard.title("Bring your stuff over")
    private let line = Onboard.line("")
    private let list = ColorView(color: Brand.ribbon.withAlphaComponent(0.07))
    private var rows: [BrowserRow] = []
    private var separators: [ColorView] = []
    private let empty = Onboard.line("No other browsers with something to bring were found on this Mac.")
    private let bringLabel = Label("Bring", font: Tokens.Font.small(.medium), color: Onboard.dim(0.6))
    private var pills: [(ImportCoordinator.Choice, DataToggle)] = []
    private let fileLink = Onboard.quiet("Import a password file")
    private let primary = Onboard.primary("Import")
    private let skip = Onboard.quiet("Not Now")
    private var isImporting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.wantsLayer = true
        list.layer?.cornerRadius = 14
        list.layer?.cornerCurve = .continuous
        list.layer?.borderWidth = 1
        list.layer?.borderColor = Brand.ribbon.withAlphaComponent(0.1).cgColor
        [title, line, list, bringLabel, fileLink, primary, skip].forEach { addSubview($0) }
        for (i, source) in ImportCoordinator.detectedSources().enumerated() { add(source, chosen: i == 0) }
        if rows.isEmpty { addSubview(empty) }
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & tabs")] {
            let pill = DataToggle(name)
            pill.onChange = { [weak self] in self?.refresh() }
            addSubview(pill)
            pills.append((choice, pill))
        }
        fileLink.onClick = { [weak self] _ in self?.pickFile() }
        primary.onClick = { [weak self] _ in self?.primaryAction() }
        skip.onClick = { [weak self] _ in self?.onContinue?() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

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
    private var anyImported: Bool { rows.contains(where: \.isFinished) }

    private func refresh() {
        let arc = rows.contains { $0.isChosen && $0.source.offers.contains(.tabs) }
        pills.first { $0.0 == .tabs }?.1.isHidden = !arc
        pills.forEach { $0.1.isLocked = isImporting }
        rows.forEach { $0.isLocked = isImporting }
        let toDo = waiting.count
        if isImporting {
            primary.title = "Importing…"
            primary.isEnabled = false
        } else if toDo > 0 {
            primary.title = "Import"
            primary.isEnabled = !choice.isEmpty
        } else {
            primary.title = "Continue"
            primary.isEnabled = true
        }
        skip.isHidden = anyImported || isImporting || rows.isEmpty
        let problems = rows.contains { if case .done(let s) = $0.state { !s.problems.isEmpty } else { false } }
        line.stringValue = isImporting ? "If macOS asks to let Zigzag open a browser’s passwords, choose Allow."
            : problems ? "Some of it didn’t come over yet. The fix is next to it."
            : anyImported ? "Done. Pick another browser to bring more, or continue."
            : "Pick the browsers to bring from. They stay exactly as they are."
        needsLayout = true
    }

    private func primaryAction() {
        let toDo = waiting
        if toDo.isEmpty { onContinue?(); return }
        run(toDo)
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
                    row.note("Safari’s passwords are in the Passwords app. Export them there (File › Export All Passwords), then use Import a password file.")
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
    /// it already, so it's one click on Allow; Safari instead hands over its own export file.
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
            panel.beginSheetModal(for: window) { [weak self, weak row] response in
                guard let self, let row else { return }
                row.recheckAccess()
                self.refresh()
            }
            // Pre-select the browser's own folder, so Allow is the only thing to do.
            DispatchQueue.main.async { panel.directoryURL = folder }
        case .safari:
            // The same one click as Chrome: macOS opens Safari's folder to Zigzag once you allow it here.
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
        let width: CGFloat = 520
        let x = (bounds.width - width) / 2
        var y = Onboard.header(title, line, in: bounds, top: 64, width: 560) + Tokens.Space.x6
        // The list grows with its rows, and scrolls nothing: past six browsers the rows get shorter.
        var ry: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let h = row.height(for: width)
            row.frame = NSRect(x: 0, y: ry, width: width, height: h)
            ry += h
            if i < separators.count { separators[i].frame = NSRect(x: 62, y: ry, width: width - 62, height: Tokens.Metric.hairline) }
        }
        list.isHidden = rows.isEmpty
        list.frame = NSRect(x: x, y: y, width: width, height: ry)
        y = rows.isEmpty ? y : list.frame.maxY + Tokens.Space.x5
        if rows.isEmpty {
            empty.frame = NSRect(x: x, y: y, width: width, height: 40)
            y = empty.frame.maxY + Tokens.Space.x4
        }
        // What to bring, always in view, in one row.
        bringLabel.frame = NSRect(x: x + 2, y: y + (Tokens.Space.x8 - bringLabel.lineHeight) / 2, width: 44, height: bringLabel.lineHeight)
        var px = bringLabel.frame.maxX + Tokens.Space.x2
        for (_, pill) in pills where !pill.isHidden {
            let w = pill.fittingWidth
            pill.frame = NSRect(x: px, y: y + 2, width: w, height: 28)
            px += w + Tokens.Space.x2
        }
        // Bottom row: a password manager's export on the left; Not Now beside Import on the right.
        Onboard.footer(primary: primary, quiet: nil, in: bounds, width: width)
        let fw = fileLink.fittingWidth
        fileLink.frame = NSRect(x: x - Tokens.Space.x2, y: primary.frame.midY - Tokens.Space.x4, width: fw, height: Tokens.Space.x8)
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: primary.frame.minX - Tokens.Space.x3 - sw, y: primary.frame.midY - Tokens.Space.x4, width: sw, height: Tokens.Space.x8)
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
        Onboard.centeredFooter(next, in: bounds)
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
        let capSize: CGFloat = 30, capGap: CGFloat = 5
        func capWidth(_ cap: ColorView) -> CGFloat { max(capSize, ((cap.subviews.first as? Label)?.inkWidth ?? 0) + Tokens.Space.x4) }
        // Keys right-aligned in one column, what they do left-aligned in the next, the pair centered as a block.
        let keysWidth = rows.map { $0.caps.map(capWidth).reduce(0, +) + CGFloat(max($0.caps.count - 1, 0)) * capGap }.max() ?? 0
        let textWidth = rows.map { $0.label.textWidth }.max() ?? 0
        let gap = Tokens.Space.x5
        let x = round((bounds.width - (keysWidth + gap + textWidth)) / 2)
        for (caps, label) in rows {
            let rowKeys = caps.map(capWidth).reduce(0, +) + CGFloat(max(caps.count - 1, 0)) * capGap
            var cx = x + keysWidth - rowKeys
            for cap in caps {
                let text = cap.subviews.first as? Label
                let w = capWidth(cap)
                cap.frame = NSRect(x: cx, y: y, width: w, height: capSize)
                text?.frame = NSRect(x: 0, y: (capSize - (text?.lineHeight ?? 0)) / 2, width: w, height: text?.lineHeight ?? 0)
                cx += w + capGap
            }
            let lx = x + keysWidth + gap
            label.frame = NSRect(x: lx, y: y + (capSize - label.lineHeight) / 2, width: textWidth + 4, height: label.lineHeight)
            y += capSize + Tokens.Space.x4
        }
        Onboard.centeredFooter(start, in: bounds)
    }
}
