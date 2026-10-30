import AppKit

/// About Zigzag: a small window as every Mac app has it (icon, name, version and copyright), with the drawn wordmark
/// for the name, as Settings has it, and who made it and where to read more below. Check for Updates sits right
/// under About in the Zigzag menu.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AboutWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let view = AboutView(frame: NSRect(x: 0, y: 0, width: 300, height: AboutView.height))
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

/// The icon, the wordmark, the version (its build in the tooltip), then the credits and the copyright.
private final class AboutView: NSView {
    static let height: CGFloat = 340
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let wordmark = WordmarkView()
    private let version = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let credits = NSTextField(labelWithAttributedString: AboutView.creditsText())
    private let copyright = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let info = Bundle.main.infoDictionary
        // The same words Settings and What's New use; the build is there for anyone who asks.
        version.stringValue = "Version \(info?["CFBundleShortVersionString"] as? String ?? "")"
        if let build = info?["CFBundleVersion"] as? String { version.toolTip = "Build \(build)" }
        copyright.stringValue = "© \(Calendar.current.component(.year, from: Date())) Zigao Wang"
        [version, copyright].forEach { $0.alignment = .center }
        // Selectable, so its links can be clicked.
        credits.isSelectable = true
        credits.allowsEditingTextAttributes = true
        credits.maximumNumberOfLines = 0
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, wordmark, version, credits, copyright].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let iconSide: CGFloat = 96
        icon.frame = NSRect(x: round((width - iconSide) / 2), y: Tokens.Space.x10, width: iconSide, height: iconSide)
        let markHeight: CGFloat = 22
        let markWidth = ceil(markHeight * WordmarkView.aspect)
        wordmark.frame = NSRect(x: round((width - markWidth) / 2), y: icon.frame.maxY + Tokens.Space.x4, width: markWidth, height: markHeight)
        version.frame = NSRect(x: 0, y: wordmark.frame.maxY + Tokens.Space.x2, width: width, height: version.lineHeight)
        let inner = width - Tokens.Space.x6 * 2
        let creditsHeight = ceil(credits.sizeThatFits(NSSize(width: inner, height: 200)).height)
        credits.frame = NSRect(x: Tokens.Space.x6, y: version.frame.maxY + Tokens.Space.x5, width: inner, height: creditsHeight)
        copyright.frame = NSRect(x: 0, y: bounds.height - Tokens.Space.x6 - copyright.lineHeight, width: width, height: copyright.lineHeight)
    }

    /// Centered lines: the maker, the links, then the ad blocking lists' credit.
    private static func creditsText() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [.font: Tokens.Font.small(), .foregroundColor: Tokens.Color.textSecondary,
                                                   .paragraphStyle: center]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            var attributes = body
            attributes[.link] = URL(string: url)
            return NSAttributedString(string: title, attributes: attributes)
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Made by ", attributes: body))
        text.append(link("Zigao Wang", "https://zigao.wang"))
        text.append(NSAttributedString(string: "\n", attributes: body))
        text.append(link("Website", "https://zigzagbrowser.com"))
        text.append(NSAttributedString(string: "\u{2003}", attributes: body))
        text.append(link("Release Notes", "https://zigzagbrowser.com/release-notes"))
        text.append(NSAttributedString(string: "\u{2003}", attributes: body))
        text.append(link("License", "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE"))
        text.append(NSAttributedString(string: "\nAd blocking lists by EasyList, CC BY-SA 3.0", attributes: body))
        return text
    }
}
