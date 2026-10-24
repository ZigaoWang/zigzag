import AppKit

/// First launch, as its own moment: a clean window, the brand on the left (the wordmark writes itself in, once,
/// and each step's title), bringing your stuff over on the right. The browser appears when you're done or skip.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static var shared: WelcomeWindowController?
    private var onFinish: (() -> Void)?

    static func show(onFinish: @escaping () -> Void) {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 860, height: 580)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Welcome to Zigzag"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Tokens.Color.formBackground
        let view = WelcomeView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = WelcomeWindowController(window: window)
        controller.onFinish = onFinish
        view.onDone = { [weak controller] in controller?.finish() }
        window.delegate = controller
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ImportOfferDismissed")
        Self.shared = nil
        let done = onFinish
        onFinish = nil
        done?()
    }
}

private final class WelcomeView: NSView {
    var onDone: (() -> Void)?
    private let panel = BrandSurface()
    private let wordmark = WordmarkView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var steps: [Label] = []
    private var dots: [CALayer] = []
    private let importView = ImportView(presentation: .welcome)
    private let intro = WelcomeIntroView()
    /// The first step says hello before asking for anything; Get Started moves on to bringing your stuff over.
    private var showingIntro = true
    private var drewIn = false

    private let panelWidth: CGFloat = 330

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        heading.isSelectable = false
        heading.maximumNumberOfLines = 2
        panel.cornerRadius = 0
        panel.layer?.borderWidth = 0
        panel.showsWatermark = false
        body.font = .systemFont(ofSize: 14)
        body.isSelectable = false
        body.maximumNumberOfLines = 0
        [panel, wordmark, heading, body].forEach { addSubview($0) }
        for name in ["Welcome", "Bring your stuff", "Start browsing"] {
            let label = Label(name, font: Tokens.Font.small(.medium), color: Brand.ribbon)
            addSubview(label)
            steps.append(label)
            let dot = CALayer()
            dot.cornerRadius = 3
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        addSubview(importView)
        addSubview(intro)
        importView.isHidden = true
        intro.onStart = { [weak self] in self?.startImport() }
        importView.onClose = { [weak self] in self?.onDone?() }
        importView.onStageChange = { [weak self] stage in self?.show(stage, animated: true) }
        show(.choose, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func startImport() {
        showingIntro = false
        intro.isHidden = true
        importView.isHidden = false
        show(.choose, animated: true)
        Brand.enter([importView], delay: 0.05)
        window?.makeFirstResponder(nil)
    }
    override var isFlipped: Bool { true }

    private var theme: Brand.Theme { panel.theme }

    private func show(_ stage: ImportView.Stage, animated: Bool) {
        let copy: (String, String, Int)
        switch stage {
        case .choose where showingIntro:
            copy = ("Welcome to Zigzag", "A calm browser for the Mac.", 0)
        case .choose:
            copy = ("Bring your stuff", "Passwords, bookmarks and Arc spaces come over in a minute. Your other browser stays exactly as it is.", 1)
        case .importing:
            copy = ("Bringing it over", "This takes a moment. If macOS asks to let Zigzag open a browser’s saved passwords, choose Allow.", 1)
        case .done:
            let came = importView.summaries.contains { $0.passwords + $0.updatedPasswords + $0.bookmarks + $0.spaces + $0.history > 0 }
            let stuck = importView.summaries.contains { !$0.problems.isEmpty }
            copy = came
                ? ("You’re all set", "Your spaces and pinned tabs are in the sidebar, and your passwords are in Zigzag’s Passwords window.", 2)
                : stuck
                ? ("Almost there", "Something kept your things from coming over. Fix it here, or start browsing and bring them over later from Settings.", 2)
                : ("You’re all set", "Bring more over anytime from Settings › General.", 2)
        }
        heading.attributedStringValue = Brand.display(copy.0, size: 30, color: theme.tint, wraps: true)
        body.stringValue = copy.1
        body.textColor = theme.tint.withAlphaComponent(0.74)
        wordmark.color = theme.tint
        Tokens.Motion.withoutAnimation {
            for (i, (label, dot)) in zip(steps, dots).enumerated() {
                let current = i == copy.2, past = i < copy.2
                label.textColor = theme.tint.withAlphaComponent(current ? 1 : past ? 0.62 : 0.4)
                dot.backgroundColor = (current ? theme.accent : theme.tint.withAlphaComponent(past ? 0.62 : 0.3)).cgColor
            }
        }
        needsLayout = true
        if animated {
            layoutSubtreeIfNeeded()
            Brand.enter([heading, body])
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !drewIn else { return }
        drewIn = true
        show(.choose, animated: false)
        layoutSubtreeIfNeeded()
        // The one time the wordmark writes itself in, letter by letter; then the rest arrives.
        if !Brand.hasDrawnIn {
            wordmark.drawIn(delay: 0.3)
            Brand.enter([heading, body] + steps, delay: 1.2)
            Brand.enter([intro], delay: 1.3)
            Brand.hasDrawnIn = true
        } else {
            Brand.enter([wordmark, heading, body] + steps, delay: 0.05)
            Brand.enter([intro], delay: 0.1)
        }
    }

    override func layout() {
        super.layout()
        panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: bounds.height)
        let pad = Tokens.Space.x10
        let textWidth = panelWidth - pad * 2
        let markHeight: CGFloat = 26
        wordmark.frame = NSRect(x: pad, y: 76, width: markHeight * WordmarkView.aspect, height: markHeight)
        let headingHeight = ceil(heading.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        heading.frame = NSRect(x: pad - 1, y: wordmark.frame.maxY + Tokens.Space.x12, width: textWidth, height: headingHeight)
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
        body.frame = NSRect(x: pad, y: heading.frame.maxY + Tokens.Space.x3, width: textWidth, height: bodyHeight)
        var y = bounds.height - pad - CGFloat(steps.count) * 24 + 6
        Tokens.Motion.withoutAnimation {
            for (label, dot) in zip(steps, dots) {
                dot.frame = CGRect(x: pad, y: y + (label.lineHeight - 6) / 2, width: 6, height: 6)
                label.frame = NSRect(x: pad + 16, y: y, width: textWidth - 16, height: label.lineHeight)
                y += 24
            }
        }
        importView.frame = NSRect(x: panelWidth, y: 0, width: bounds.width - panelWidth, height: bounds.height)
        intro.frame = importView.frame
    }
}

/// The first thing you see: three things Zigzag does, in plain words, and one button to begin.
private final class WelcomeIntroView: NSView {
    var onStart: (() -> Void)?
    private let title = NSTextField(wrappingLabelWithString: "")
    private var rows: [(ColorView, NSImageView, Label, NSTextField)] = []
    private let start = PrimaryButton(title: "Get Started")
    private let note = Label("Takes about a minute.", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)

    private static let points: [(String, String, String)] = [
        ("square.stack", "A space for each part of your life", "Work, school and the rest stay apart, each with its own pinned tabs and color."),
        ("key.fill", "Passwords, built in", "Saved in your Mac’s Keychain, filled in for you, and synced with iCloud Keychain."),
        ("hand.raised.fill", "Quiet by default", "Ads and trackers are blocked. No account, and nothing about you is sent to us."),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.isSelectable = false
        title.attributedStringValue = Brand.display("A browser that stays out of your way", size: 24, color: Tokens.Color.textPrimary, wraps: true)
        addSubview(title)
        let accent = Brand.Theme.brand.accent
        for (symbol, heading, detail) in Self.points {
            let tile = ColorView(color: accent.withAlphaComponent(0.12))
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 10
            tile.layer?.cornerCurve = .continuous
            let icon = NSImageView(image: Tokens.Symbol.image(symbol, size: 17) ?? NSImage())
            icon.contentTintColor = accent
            tile.addSubview(icon)
            let label = Label(heading, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
            let body = NSTextField(wrappingLabelWithString: detail)
            body.font = Tokens.Font.body()
            body.textColor = Tokens.Color.textSecondary
            body.isSelectable = false
            [tile, label, body].forEach { addSubview($0) }
            rows.append((tile, icon, label, body))
        }
        start.onClick = { [weak self] _ in self?.onStart?() }
        [start, note].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x12
        let width = bounds.width - pad * 2
        let titleHeight = ceil(title.sizeThatFits(NSSize(width: width, height: 200)).height)
        title.frame = NSRect(x: pad, y: 96, width: width, height: titleHeight)
        var y = title.frame.maxY + Tokens.Space.x10
        let tileSize: CGFloat = 40
        for (tile, icon, label, body) in rows {
            tile.frame = NSRect(x: pad, y: y, width: tileSize, height: tileSize)
            icon.frame = tile.bounds.insetBy(dx: 10, dy: 10)
            let x = tile.frame.maxX + Tokens.Space.x4
            label.frame = NSRect(x: x, y: y, width: bounds.width - x - pad, height: label.lineHeight)
            let h = ceil(body.sizeThatFits(NSSize(width: bounds.width - x - pad, height: 200)).height)
            body.frame = NSRect(x: x, y: label.frame.maxY + 2, width: bounds.width - x - pad, height: h)
            y = max(tile.frame.maxY, body.frame.maxY) + Tokens.Space.x6
        }
        let h = Tokens.Space.x8 + Tokens.Space.x1
        let w = max(start.fittingWidth, 132)
        start.frame = NSRect(x: bounds.width - pad - w, y: bounds.height - Tokens.Space.x12 - h, width: w, height: h)
        note.frame = NSRect(x: pad, y: start.frame.midY - note.lineHeight / 2, width: start.frame.minX - pad - Tokens.Space.x4, height: note.lineHeight)
    }
}
