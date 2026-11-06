import AppKit

/// About Zigzag: a small window as every Mac app has it (icon, name, version and copyright), with the drawn wordmark
/// for the name, as Settings has it, the release notes and the acknowledgements a click away, and the legal lines at
/// the foot. Check for Updates sits right under About in the Zigzag menu.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AboutWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = AboutView(frame: NSRect(x: 0, y: 0, width: Tokens.Welcome.aboutSize.width, height: AboutView.height))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "About Zigzag"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.backgroundColor = Tokens.Color.formBackground
        window.contentView = view
        window.center()
        let controller = AboutWindowController(window: window)
        window.delegate = controller
        shared = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

/// The icon, the wordmark and the version with its build, then the places to go as one grouped list (release notes,
/// acknowledgements, the website, the source and who made it), and the copyright and license in a line at the foot.
private final class AboutView: NSView {
    static let height = Tokens.Welcome.aboutSize.height
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let wordmark = WordmarkView()
    private let version = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    /// Each a name, where it goes in quiet text, and an arrow that says whether it opens here or on the web.
    private let rows: [AboutRow] = [
        AboutRow("Release Notes", open: WhatsNew.allNotes),
        AboutRow("Acknowledgments", run: { AcknowledgementsWindowController.show() }),
        AboutRow("Website", detail: "zigzagbrowser.com", open: URL(string: "https://zigzagbrowser.com")!),
        AboutRow("Source Code", detail: "GitHub", open: URL(string: "https://github.com/ZigaoWang/zigzag")!),
        AboutRow("Developer", detail: "zigao.wang", open: URL(string: "https://www.zigao.wang")!),
    ]
    /// Hairlines between the rows, inset from the card's edges as a grouped list has them.
    private let lines: [ColorView] = (0..<4).map { _ in ColorView(color: Tokens.Color.separator) }
    /// The rows on one soft card, as a group of settings sits, so they read as one list.
    private let card = ColorView(color: Tokens.Color.surfaceGroup)
    /// The copyright, and the license as a link to its text.
    private let legal = NSTextField(labelWithAttributedString: AboutView.legalText())

    override init(frame: NSRect) {
        super.init(frame: frame)
        let info = Bundle.main.infoDictionary
        // As a Mac app's About says it: the version, with the build in brackets for anyone reporting a problem.
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String
        version.stringValue = "Version \(short)" + (build.map { " (\($0))" } ?? "")
        version.alignment = .center
        // Selectable, so its link can be clicked.
        legal.isSelectable = true
        legal.allowsEditingTextAttributes = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.group
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = Tokens.Metric.hairline
        ([icon, wordmark, version, legal, card] + lines + rows).forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// "© 2026 Zigao Wang. Apache License 2.0.", the license a link to Zigzag's own copy of it.
    private static func legalText() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let quiet: [NSAttributedString.Key: Any] = [.font: Tokens.Font.small(), .foregroundColor: Tokens.Color.textTertiary, .paragraphStyle: center]
        let text = NSMutableAttributedString(string: "© \(Calendar.current.component(.year, from: Date())) Zigao Wang. ", attributes: quiet)
        var link = quiet
        link[.link] = URL(string: "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE")
        text.append(NSAttributedString(string: "Apache License 2.0", attributes: link))
        text.append(NSAttributedString(string: ".", attributes: quiet))
        return text
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let iconSide = Tokens.Welcome.aboutIcon
        icon.frame = NSRect(x: round((width - iconSide) / 2), y: Tokens.Space.x10, width: iconSide, height: iconSide)
        let markHeight = Tokens.Welcome.smallWordmarkHeight
        let markWidth = ceil(markHeight * WordmarkView.aspect)
        wordmark.frame = NSRect(x: round((width - markWidth) / 2), y: icon.frame.maxY + Tokens.Space.x4, width: markWidth, height: markHeight)
        version.frame = NSRect(x: 0, y: wordmark.frame.maxY + Tokens.Space.x2, width: width, height: version.lineHeight)
        // The list, inset as a panel's rows are, a hairline between each two, the lines lined up with the text.
        let pad = Tokens.Space.x5, inset = Tokens.Space.x1, rowHeight = Tokens.Metric.rowHeight + Tokens.Space.x1
        let top = version.frame.maxY + Tokens.Space.x6
        card.frame = NSRect(x: pad, y: top, width: width - pad * 2, height: CGFloat(rows.count) * rowHeight + inset * 2)
        card.layer?.borderColor = cgColor(Tokens.Color.surfaceGroupEdge)
        var y = top + inset
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: pad + inset, y: y, width: width - (pad + inset) * 2, height: rowHeight)
            y += rowHeight
            if i < lines.count {
                let lineX = row.frame.minX + CardRow.inset
                lines[i].frame = NSRect(x: lineX, y: y - Tokens.Metric.hairline / 2, width: row.frame.maxX - CardRow.inset - lineX,
                                        height: Tokens.Metric.hairline)
            }
        }
        let legalHeight = ceil(legal.sizeThatFits(NSSize(width: width, height: 100)).height)
        legal.frame = NSRect(x: 0, y: bounds.height - Tokens.Space.x5 - legalHeight, width: width, height: legalHeight)
    }
}

/// A row of About's list: its name, where it goes in quiet text, and at the end an arrow: up and out for a page on
/// the web, a chevron for a window of Zigzag's own.
private final class AboutRow: CardRow {
    private let arrow = NSImageView()

    init(_ title: String, detail: String = "", open url: URL? = nil, run: (() -> Void)? = nil) {
        super.init(title: title, detail: detail, font: Tokens.Font.body())
        arrow.image = Tokens.Symbol.image(url == nil ? "chevron.right" : "arrow.up.right", size: Tokens.TypeSize.small)
        arrow.imageScaling = .scaleNone
        arrow.contentTintColor = Tokens.Color.textTertiary
        addSubview(arrow)
        onClick = { _ in
            if let url { NSWorkspace.shared.open(url) }
            run?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        arrow.frame = NSRect(x: bounds.width - Self.inset - side, y: (bounds.height - side) / 2, width: side, height: side)
        // The detail moves in from the end to sit before the arrow.
        detail.frame.origin.x -= side + Tokens.Space.x2
    }
}
