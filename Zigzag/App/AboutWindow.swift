import AppKit

/// About Zigzag, the way Mac apps do it: the icon, the name, the version, one button, and the small print.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static var shared: AboutWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 300, height: 400)
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
    private let icon = NSImageView()
    private let wordmark = WordmarkView()
    private let version = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let beta = BetaTag()
    private let updates = TextButton(title: "Check for Updates", font: Tokens.Font.body(.medium))
    private let rule = ColorView(color: Tokens.Color.separator)
    private let links: [TextButton] = [
        ("Website", "https://zigzagbrowser.com"),
        ("Source", "https://github.com/ZigaoWang/zigzag"),
        ("License", "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE"),
    ].map { title, address in
        let button = TextButton(title: title, font: Tokens.Font.small())
        button.textColor = Tokens.Color.textSecondary
        button.onClick = { _ in if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
        return button
    }
    private let fine = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        wordmark.color = Tokens.Color.textPrimary
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        version.stringValue = build.isEmpty || build == short ? "Version \(short)" : "Version \(short) (\(build))"
        version.setAccessibilityLabel(version.stringValue + ", beta")
        updates.showsFillAtRest = true
        updates.onClick = { _ in Updater.shared.checkForUpdates() }
        let year = Calendar.current.component(.year, from: Date())
        fine.stringValue = "© \(year) Zigao Wang\nAd blocking lists by EasyList, CC BY-SA 3.0"
        fine.font = .systemFont(ofSize: 10.5)
        fine.textColor = Tokens.Color.textTertiary
        fine.alignment = .center
        fine.isSelectable = false
        // Click the name and it writes itself again.
        wordmark.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rewrite)))
        [icon, wordmark, version, beta, updates, rule, fine].forEach { addSubview($0) }
        links.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func rewrite() { wordmark.drawIn(total: 1.0) }

    override func layout() {
        super.layout()
        let w = bounds.width
        func center(_ width: CGFloat) -> CGFloat { round((w - width) / 2) }
        var y: CGFloat = 44
        let side: CGFloat = 96
        icon.frame = NSRect(x: center(side), y: y, width: side, height: side)
        y = icon.frame.maxY + 14
        let markHeight: CGFloat = 20
        let markWidth = markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: center(markWidth), y: y, width: markWidth, height: markHeight)
        y = wordmark.frame.maxY + 10
        let vw = version.textWidth, row = vw + Tokens.Space.x1 + beta.fittingWidth
        version.frame = NSRect(x: center(row), y: y, width: vw, height: version.lineHeight)
        beta.frame = NSRect(x: version.frame.maxX + Tokens.Space.x1, y: round(version.frame.midY - BetaTag.height / 2), width: beta.fittingWidth, height: BetaTag.height)
        y = version.frame.maxY + 18
        let uw = updates.fittingWidth + Tokens.Space.x2
        updates.frame = NSRect(x: center(uw), y: y, width: uw, height: Tokens.Space.x8)
        // The small print at the foot: links, then copyright and credits.
        let pad = Tokens.Space.x6
        let fh = ceil(fine.sizeThatFits(NSSize(width: w - pad * 2, height: 100)).height)
        fine.frame = NSRect(x: pad, y: bounds.height - 18 - fh, width: w - pad * 2, height: fh)
        let lh = Tokens.Space.x6
        let ly = fine.frame.minY - 8 - lh
        let widths = links.map(\.fittingWidth), gap: CGFloat = 4
        var lx = center(widths.reduce(0, +) + gap * CGFloat(links.count - 1))
        for (button, bw) in zip(links, widths) {
            button.frame = NSRect(x: lx, y: ly, width: bw, height: lh)
            lx += bw + gap
        }
        rule.frame = NSRect(x: pad, y: ly - 12, width: w - pad * 2, height: Tokens.Metric.hairline)
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
