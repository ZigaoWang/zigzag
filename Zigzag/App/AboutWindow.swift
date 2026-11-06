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

/// The icon, the wordmark and the version with its build; the release notes and the acknowledgements as buttons, and
/// the website; then the legal lines: the copyright, Zigzag's license and its marks.
private final class AboutView: NSView {
    static let height = Tokens.Welcome.aboutSize.height
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let wordmark = WordmarkView()
    private let version = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let notes = PillButton(title: "Release Notes")
    private let thanks = PillButton(title: "Acknowledgements")
    private let website = NSTextField(labelWithAttributedString: AboutView.link("zigzagbrowser.com", "https://zigzagbrowser.com"))
    private let legal = NSTextField(labelWithAttributedString: AboutView.legalText())

    override init(frame: NSRect) {
        super.init(frame: frame)
        let info = Bundle.main.infoDictionary
        // As a Mac app's About says it: the version, with the build in brackets for anyone reporting a problem.
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String
        version.stringValue = "Version \(short)" + (build.map { " (\($0))" } ?? "")
        version.alignment = .center
        version.isSelectable = true
        notes.onClick = { _ in NSWorkspace.shared.open(WhatsNew.allNotes) }
        thanks.onClick = { _ in AcknowledgementsWindowController.show() }
        // Selectable, so the links can be clicked.
        for field in [website, legal] {
            field.isSelectable = true
            field.allowsEditingTextAttributes = true
            field.maximumNumberOfLines = 0
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, wordmark, version, notes, thanks, website, legal].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let iconSide = Tokens.Welcome.aboutIcon
        icon.frame = NSRect(x: round((width - iconSide) / 2), y: Tokens.Space.x10, width: iconSide, height: iconSide)
        let markHeight = Tokens.Welcome.smallWordmarkHeight
        let markWidth = ceil(markHeight * WordmarkView.aspect)
        wordmark.frame = NSRect(x: round((width - markWidth) / 2), y: icon.frame.maxY + Tokens.Space.x4, width: markWidth, height: markHeight)
        version.frame = NSRect(x: 0, y: wordmark.frame.maxY + Tokens.Space.x2, width: width, height: version.lineHeight)
        // The two buttons side by side, each as wide as its words, centered together.
        let h = Tokens.Page.controlHeight
        let total = notes.fittingWidth + Tokens.Space.x2 + thanks.fittingWidth
        notes.frame = NSRect(x: round((width - total) / 2), y: version.frame.maxY + Tokens.Space.x5, width: notes.fittingWidth, height: h)
        thanks.frame = NSRect(x: notes.frame.maxX + Tokens.Space.x2, y: notes.frame.minY, width: thanks.fittingWidth, height: h)
        let siteHeight = ceil(website.sizeThatFits(NSSize(width: width, height: 100)).height)
        website.frame = NSRect(x: 0, y: notes.frame.maxY + Tokens.Space.x3, width: width, height: siteHeight)
        let inner = width - Tokens.Space.x4 * 2
        let legalHeight = ceil(legal.sizeThatFits(NSSize(width: inner, height: 200)).height)
        legal.frame = NSRect(x: Tokens.Space.x4, y: bounds.height - Tokens.Space.x6 - legalHeight, width: inner, height: legalHeight)
    }

    private static var centered: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 2
        return style
    }

    private static func link(_ title: String, _ url: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Tokens.Font.small(), .link: URL(string: url) as Any, .paragraphStyle: centered])
    }

    /// "© 2026 Zigao Wang", that Zigzag is under the Apache License (a link to the acknowledgements, which hold it in
    /// full), and that the name and logo are marks, which the license doesn't cover.
    private static func legalText() -> NSAttributedString {
        let quiet: [NSAttributedString.Key: Any] = [.font: Tokens.Font.small(), .foregroundColor: Tokens.Color.textTertiary,
                                                    .paragraphStyle: centered]
        let year = Calendar.current.component(.year, from: Date())
        let text = NSMutableAttributedString(string: "© \(year) Zigao Wang\nLicensed under the ", attributes: quiet)
        var license = quiet
        license[.link] = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")
        text.append(NSAttributedString(string: "Apache License 2.0", attributes: license))
        text.append(NSAttributedString(string: "\nZigzag is a trademark of Zigao Wang", attributes: quiet))
        return text
    }
}
