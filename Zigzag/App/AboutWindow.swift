import AppKit

/// About Zigzag: the brand at rest. The wordmark on the lit surface in the icon's own navy (About is the brand's
/// home, so it doesn't take a space's color), the version, and a way to check for updates.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static var shared: AboutWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 360, height: 372)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "About Zigzag"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Tokens.Color.formBackground
        window.contentView = AboutView(frame: NSRect(origin: .zero, size: size))
        let controller = AboutWindowController(window: window)
        window.delegate = controller
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private final class AboutView: NSView {
    private let surface = BrandSurface()
    private let wordmark = WordmarkView()
    private let version = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let maker = TextButton(title: "Made by Zigao Wang", font: Tokens.Font.small())
    private let updates = TextButton(title: "Check for Updates", font: Tokens.Font.body(.medium))
    private let copyright = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.fixedTheme = .navy
        surface.cornerRadius = 0
        surface.layer?.borderWidth = 0
        surface.showsWatermark = false
        wordmark.color = Brand.ribbon
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        version.stringValue = build.isEmpty || build == short ? "Version \(short)" : "Version \(short) (\(build))"
        version.alignment = .center
        maker.textColor = Tokens.Color.textTertiary
        maker.onClick = { _ in if let url = URL(string: "https://zigao.wang") { NSWorkspace.shared.open(url) } }
        // Click the wordmark and it writes itself again.
        wordmark.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rewrite)))
        copyright.stringValue = info?["NSHumanReadableCopyright"] as? String ?? ""
        copyright.alignment = .center
        updates.showsFillAtRest = true
        updates.onClick = { _ in Updater.shared.checkForUpdates() }
        [surface, wordmark, version, maker, updates, copyright].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        // The wordmark writes itself in, the way it does on the welcome screen; the rest settles in under it.
        wordmark.drawIn(delay: 0.15, total: 1.2)
        Brand.enter([version, maker, updates, copyright], delay: 0.9)
    }

    @objc private func rewrite() { wordmark.drawIn(total: 1.2) }

    override func layout() {
        super.layout()
        let surfaceHeight: CGFloat = 220
        surface.frame = NSRect(x: 0, y: 0, width: bounds.width, height: surfaceHeight)
        let markHeight: CGFloat = 44
        let markWidth = markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: round((bounds.width - markWidth) / 2), y: round((surfaceHeight - markHeight) / 2) + 6, width: markWidth, height: markHeight)
        let pad = Tokens.Space.x8
        var y = surfaceHeight + Tokens.Space.x6
        version.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: version.lineHeight)
        y = version.frame.maxY + Tokens.Space.x1
        let mw = maker.fittingWidth
        maker.frame = NSRect(x: round((bounds.width - mw) / 2), y: y, width: mw, height: Tokens.Space.x6)
        y = maker.frame.maxY + Tokens.Space.x5
        let w = updates.fittingWidth + Tokens.Space.x2
        updates.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Space.x8)
        copyright.frame = NSRect(x: pad, y: bounds.height - Tokens.Space.x5 - copyright.lineHeight, width: bounds.width - pad * 2, height: copyright.lineHeight)
    }
}
