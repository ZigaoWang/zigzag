import AppKit

/// About Zigzag, the way polished Mac apps lay it out: the icon on the left; beside it the name, the version, who
/// made it, where to read more, and one button.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static var shared: AboutWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 470, height: 270)
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
    private let maker = LinkText("Made by Zigao Wang", url: "https://zigao.wang", color: Tokens.Color.textSecondary)
    private let links: [LinkText] = [
        LinkText("Website", url: "https://zigzagbrowser.com"),
        LinkText("Release Notes", url: "https://zigzagbrowser.com/release-notes"),
        LinkText("License", url: "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE"),
    ]
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
        fine.alignment = .left

        fine.isSelectable = false
        // Click the name and it writes itself again.
        wordmark.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rewrite)))
        [icon, wordmark, version, beta, maker, updates, fine].forEach { addSubview($0) }
        links.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func rewrite() { wordmark.drawIn(total: 1.0) }

    override func layout() {
        super.layout()
        let side: CGFloat = 112, pad: CGFloat = 32
        icon.frame = NSRect(x: pad - 6, y: 44, width: side, height: side)
        // Everything else in one column beside the icon, on one left edge.
        let x = icon.frame.maxX + 22, width = bounds.width - x - pad
        var y: CGFloat = 48
        let markHeight: CGFloat = 22
        wordmark.frame = NSRect(x: x, y: y, width: markHeight * WordmarkView.aspect, height: markHeight)
        y = wordmark.frame.maxY + 12
        version.frame = NSRect(x: x, y: y, width: version.textWidth, height: version.lineHeight)
        beta.frame = NSRect(x: version.frame.maxX + Tokens.Space.x2, y: round(version.frame.midY - BetaTag.height / 2), width: beta.fittingWidth, height: BetaTag.height)
        y = version.frame.maxY + 3
        maker.frame = NSRect(x: x, y: y, width: maker.width, height: maker.lineHeight)
        y = maker.frame.maxY + 14
        var lx = x
        for link in links {
            link.frame = NSRect(x: lx, y: y, width: link.width, height: link.lineHeight)
            lx += link.width + 18
        }
        y += links[0].lineHeight + 16
        updates.frame = NSRect(x: x - 1, y: y, width: updates.fittingWidth + Tokens.Space.x2, height: Tokens.Space.x8)
        let fh = ceil(fine.sizeThatFits(NSSize(width: width, height: 60)).height)
        fine.frame = NSRect(x: x, y: updates.frame.maxY + 18, width: width, height: fh)
    }
}

/// Words that open a page when clicked, with the pointing hand: no button around them, nothing that lights up.
private final class LinkText: NSView {
    private let url: URL?
    private let label: Label

    init(_ text: String, url: String, color: NSColor = Brand.Theme.brand.accent) {
        self.url = URL(string: url)
        label = Label(text, font: Tokens.Font.small(), color: color)
        super.init(frame: .zero)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    var width: CGFloat { ceil(label.textWidth) + 2 }
    var lineHeight: CGFloat { label.lineHeight }
    override func layout() {
        super.layout()
        label.frame = bounds
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { if let url { NSWorkspace.shared.open(url) } }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
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
