import AppKit

/// About Zigzag: the brand at rest. The wordmark on the lit surface in the icon's own navy (About is the brand's
/// home, so it doesn't take a space's color), the version, a way to check for updates, and the credits.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static var shared: AboutWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 360, height: 432)
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
    private let beta = BetaTag()
    private let credits = NSTextField(wrappingLabelWithString: "Ad blocking uses EasyList and EasyPrivacy by the EasyList authors (CC BY-SA 3.0).")
    /// Where to go next: the site, what changed, the source and its license.
    private let links: [TextButton] = [
        ("Website", "https://zigzagbrowser.com"),
        ("What’s New", ""),
        ("GitHub", "https://github.com/ZigaoWang/zigzag"),
        ("License", "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE"),
    ].map { title, address in
        let button = TextButton(title: title, font: Tokens.Font.small(.medium))
        button.textColor = Brand.Theme.brand.accent
        button.onClick = { _ in
            if address.isEmpty {
                if let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first {
                    controller.window?.makeKeyAndOrderFront(nil)
                    WhatsNew.show(in: controller)
                }
            } else if let url = URL(string: address) {
                NSWorkspace.shared.open(url)
            }
        }
        return button
    }
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
        version.setAccessibilityLabel(version.stringValue + ", beta")
        maker.textColor = Tokens.Color.textTertiary
        maker.onClick = { _ in if let url = URL(string: "https://zigao.wang") { NSWorkspace.shared.open(url) } }
        // Click the wordmark and it writes itself again.
        wordmark.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rewrite)))
        copyright.stringValue = info?["NSHumanReadableCopyright"] as? String ?? ""
        copyright.alignment = .center
        credits.font = Tokens.Font.small()
        credits.textColor = Tokens.Color.textTertiary
        credits.alignment = .center
        credits.isSelectable = false
        updates.showsFillAtRest = true
        updates.onClick = { _ in Updater.shared.checkForUpdates() }
        [surface, wordmark, version, beta, maker, updates, credits, copyright].forEach { addSubview($0) }
        links.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        // The wordmark writes itself in, the way it does on the welcome screen. It's the one thing that moves:
        // the details under it are simply there.
        wordmark.drawIn(delay: 0.15, total: 1.2)
    }

    @objc private func rewrite() { wordmark.drawIn(total: 1.2) }

    override func layout() {
        super.layout()
        let surfaceHeight: CGFloat = 180
        surface.frame = NSRect(x: 0, y: 0, width: bounds.width, height: surfaceHeight)
        let markHeight: CGFloat = 44
        let markWidth = markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: round((bounds.width - markWidth) / 2), y: round((surfaceHeight - markHeight) / 2) + 6, width: markWidth, height: markHeight)
        let pad = Tokens.Space.x8
        var y = surfaceHeight + Tokens.Space.x6
        // The version and its Beta tag, centered together.
        let vw = version.textWidth
        let row = vw + Tokens.Space.x1 + beta.fittingWidth
        let vx = round((bounds.width - row) / 2)
        version.frame = NSRect(x: vx, y: y, width: vw, height: version.lineHeight)
        beta.frame = NSRect(x: version.frame.maxX + Tokens.Space.x1, y: round(version.frame.midY - BetaTag.height / 2), width: beta.fittingWidth, height: BetaTag.height)
        y = version.frame.maxY + Tokens.Space.x1
        let mw = maker.fittingWidth
        maker.frame = NSRect(x: round((bounds.width - mw) / 2), y: y, width: mw, height: Tokens.Space.x6)
        y = maker.frame.maxY + Tokens.Space.x5
        let w = updates.fittingWidth + Tokens.Space.x2
        updates.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Space.x8)
        y = updates.frame.maxY + Tokens.Space.x6
        // The links in one row, evenly apart.
        let widths = links.map(\.fittingWidth)
        let gap = Tokens.Space.x3
        var lx = round((bounds.width - widths.reduce(0, +) - gap * CGFloat(links.count - 1)) / 2)
        for (button, w) in zip(links, widths) {
            button.frame = NSRect(x: lx, y: y, width: w, height: Tokens.Space.x7Height)
            lx += w + gap
        }
        // Credits sit at the foot of the window, the copyright (when there is one) last.
        let inner = bounds.width - pad * 2
        var bottom = bounds.height - Tokens.Space.x5
        if !copyright.stringValue.isEmpty {
            copyright.frame = NSRect(x: pad, y: bottom - copyright.lineHeight, width: inner, height: copyright.lineHeight)
            bottom = copyright.frame.minY - Tokens.Space.x1
        }
        let creditsHeight = ceil(credits.sizeThatFits(NSSize(width: inner, height: 200)).height)
        credits.frame = NSRect(x: pad, y: bottom - creditsHeight, width: inner, height: creditsHeight)
    }
}

/// "Beta", quietly: a small capsule on the field fill, beside the version.
private final class BetaTag: ColorView {
    static let height: CGFloat = 16
    private let label = Label("Beta", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)

    init() {
        super.init(color: Tokens.Color.fieldFill)
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { label.inkWidth + Tokens.Space.x2 * 2 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: Tokens.Space.x2 - Label.inset, y: round((bounds.height - label.lineHeight) / 2), width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }
}
