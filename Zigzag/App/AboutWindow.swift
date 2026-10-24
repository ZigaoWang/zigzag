import AppKit

/// About Zigzag: the brand at rest. The wordmark on the lit surface in the icon's own navy (About is the brand's
/// home, so it doesn't take a space's color), the version, and a way to check for updates.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static var shared: AboutWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 360, height: 400)
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
    private let line = NSTextField(wrappingLabelWithString: "A calm browser for the Mac. Your spaces, passwords and pages, kept on this Mac and in your iCloud, nowhere else.")
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
        line.font = Tokens.Font.body()
        line.textColor = Tokens.Color.textPrimary
        line.alignment = .center
        line.isSelectable = false
        copyright.stringValue = info?["NSHumanReadableCopyright"] as? String ?? ""
        copyright.alignment = .center
        updates.showsFillAtRest = true
        updates.onClick = { _ in Updater.shared.checkForUpdates() }
        [surface, wordmark, version, line, updates, copyright].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        Brand.enter([wordmark], delay: 0.05)
        Brand.enter([version, line, updates, copyright], delay: 0.12)
    }

    override func layout() {
        super.layout()
        let surfaceHeight: CGFloat = 196
        surface.frame = NSRect(x: 0, y: 0, width: bounds.width, height: surfaceHeight)
        let markHeight: CGFloat = 40
        let markWidth = markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: round((bounds.width - markWidth) / 2), y: round((surfaceHeight - markHeight) / 2) + 6, width: markWidth, height: markHeight)
        let pad = Tokens.Space.x8
        var y = surfaceHeight + Tokens.Space.x6
        version.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: version.lineHeight)
        y = version.frame.maxY + Tokens.Space.x3
        let lineHeight = ceil(line.sizeThatFits(NSSize(width: bounds.width - pad * 2, height: 200)).height)
        line.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: lineHeight)
        y = line.frame.maxY + Tokens.Space.x5
        let w = updates.fittingWidth + Tokens.Space.x2
        updates.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Space.x8)
        copyright.frame = NSRect(x: pad, y: bounds.height - Tokens.Space.x5 - copyright.lineHeight, width: bounds.width - pad * 2, height: copyright.lineHeight)
    }
}
