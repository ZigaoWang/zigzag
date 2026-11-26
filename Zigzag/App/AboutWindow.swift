import AppKit
import UniformTypeIdentifiers

/// About Zigzag: Your Zigzag Card as the hero, its finishes and Save as Image… and Share… under it, the version with
/// its build, the release notes and the acknowledgements a click away, and the legal lines at the foot. Check for
/// Updates sits right under About in the Zigzag menu.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var shared: AboutWindowController?
    private let content: AboutView
    private var themeToken: SignalToken?
    private let sharing = SharingWatch()

    private static var frontSpace: SpaceInfo? {
        (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first)?.tabManager.currentSpace
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let shared {
            shared.refresh()
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AboutWindowController()
        shared = controller
        controller.showWindow(nil)
    }

    private init() {
        content = AboutView(face: .current(), palette: .of(Self.frontSpace), finish: CardFinish.chosen)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.frame.size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = String(localized: "About Zigzag", comment: "Title of the About window.")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.backgroundColor = Tokens.Color.formBackground
        window.contentView = content
        window.center()
        super.init(window: window)
        window.delegate = self
        content.save.onClick = { [weak self] _ in self?.saveImage() }
        content.share.onClick = { [weak self] _ in self?.shareImage() }
        content.finishes.onPick = { [weak self] finish in
            CardFinish.chosen = finish
            self?.content.stage.finish = finish
        }
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// The space in front and today, again.
    private func refresh() {
        // While this window is key, the space in front is the last browser window's.
        let palette = CardPalette.of(Self.frontSpace)
        content.stage.palette = palette
        content.finishes.palette = palette
        content.stage.face = .current()
    }

    private var png: Data? {
        let stage = content.stage
        return CardArt.png(stage.face, finish: stage.finish, palette: stage.palette, dark: content.effectiveAppearance.isDark)
    }

    private static var fileName: String { String(localized: "Zigzag Card", comment: "File name of Your Zigzag Card saved as a picture.") + ".png" }

    private func saveImage() {
        guard let window, let data = png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName
        panel.directoryURL = DownloadManager.folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func shareImage() {
        guard let data = png else { return }
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = Self.fileName
        let picker = NSSharingServicePicker(items: [provider])
        picker.delegate = sharing
        picker.show(relativeTo: content.share.bounds, of: content.share, preferredEdge: .minY)
    }

    #if DEBUG
    /// `card tilt <x> <y>|off`, `card finish <name>`, `card flip`, `card hover <n>|off`, `card save <path>`,
    /// `card shot <path>`, `card close`.
    func debugCard(_ f: [String]) {
        switch f.first ?? "" {
        case "tilt":
            let n = f.dropFirst().compactMap { Double($0) }
            content.stage.lean(toward: n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil)
        case "finish":
            guard f.count == 2, let finish = CardFinish(rawValue: f[1]) else { break }
            content.finishes.selected = finish
            content.finishes.onPick?(finish)
        case "flip": content.stage.turnOver()
        case "hover": content.finishes.debugHover(f.count == 2 ? Int(f[1]) : nil)
        case "save": if f.count == 2 { try? png?.write(to: URL(fileURLWithPath: f[1])) }
        case "shot":
            guard f.count == 2, let number = window?.windowNumber else { break }
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(number)", f[1]]
            try? shot.run()
        case "close": window?.close()
        default: break
        }
    }
    #endif
}

/// The card, its finishes at its left under it and Save as Image… and Share… at its right, the version, then the
/// places to go as one grouped list (release notes, acknowledgements, the website, the source and who made it), and
/// the copyright and license in a line at the foot.
private final class AboutView: NSView {
    let stage: CardStage
    let finishes: CardFinishSwatches
    /// Quiet symbols beside the finishes, named for VoiceOver and under the pointer, so the card stays the thing to look at.
    let save = AboutView.action("square.and.arrow.down",
                                String(localized: "Save as Image…", comment: "Button in About Zigzag, under Your Zigzag Card: saves it as a PNG picture, asking where."))
    let share = AboutView.action("square.and.arrow.up",
                                 String(localized: "Share…", comment: "Button in About Zigzag, under Your Zigzag Card: opens the Mac's share menu with its picture."))

    private static func action(_ symbol: String, _ name: String) -> PillButton {
        let button = PillButton(symbol: symbol, style: .quiet)
        button.toolTip = name
        button.setAccessibilityLabel(name)
        return button
    }
    private let version = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    /// Each a name, where it goes in quiet text, and an arrow that says whether it opens here or on the web.
    private let rows: [AboutRow] = [
        AboutRow(String(localized: "Release Notes", comment: "Row in the About window."), open: WhatsNew.allNotes),
        AboutRow(String(localized: "Acknowledgments", comment: "Row in the About window: the licenses of the works Zigzag uses."),
                 run: { AcknowledgementsWindowController.show() }),
        AboutRow(String(localized: "Website", comment: "Row in the About window."), detail: "zigzagbrowser.com", open: URL(string: "https://zigzagbrowser.com")!),
        AboutRow(String(localized: "Source Code", comment: "Row in the About window; GitHub is beside it."), detail: "GitHub",
                 open: URL(string: "https://github.com/ZigaoWang/zigzag")!),
        AboutRow(String(localized: "Developer", comment: "Row in the About window: the developer's website."), detail: "zigao.wang",
                 open: URL(string: "https://www.zigao.wang")!),
    ]
    /// Hairlines between the rows, inset from the card's edges as a grouped list has them.
    private let lines: [ColorView] = (0..<4).map { _ in ColorView(color: Tokens.Color.separator) }
    /// The rows on one soft card, as a group of settings sits, so they read as one list.
    private let card = ColorView(color: Tokens.Color.surfaceGroup)
    /// The copyright, and the license as a link to its text.
    private let legal = NSTextField(labelWithAttributedString: AboutView.legalText())
    private var tracking: NSTrackingArea?

    init(face: CardFace, palette: CardPalette, finish: CardFinish) {
        stage = CardStage(face: face, palette: palette, finish: finish)
        finishes = CardFinishSwatches(selected: finish, palette: palette)
        super.init(frame: .zero)
        let info = Bundle.main.infoDictionary
        // As a Mac app's About says it: the version, with the build in brackets for anyone reporting a problem.
        let short = VersionName.display(info?["CFBundleShortVersionString"] as? String ?? "")
        let build = info?["CFBundleVersion"] as? String
        version.stringValue = build.map { String(localized: "Version \(short) (\($0))", comment: "In the About window: the version, then the build number in brackets.") }
            ?? String(localized: "Version \(short)", comment: "In the About window: the version.")
        version.alignment = .center
        // Selectable, so its link can be clicked.
        legal.isSelectable = true
        legal.allowsEditingTextAttributes = true
        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.group
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = Tokens.Metric.hairline
        ([stage, finishes, save, share, version, legal, card] + lines + rows).forEach { addSubview($0) }
        let width = Tokens.Keepsake.size.width + Tokens.Keepsake.margin * 2
        setFrameSize(NSSize(width: width, height: place(width: width, apply: false)))
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
        // The license's name is the link, wherever the sentence puts it.
        let license = "Apache License 2.0"
        let year = String(Calendar.current.component(.year, from: Date()))
        let line = String(localized: "© \(year) Zigao Wang. \(license).",
                          comment: "Small print in the About window: the year, the developer's name, then the license's name, which is a link.")
        let text = NSMutableAttributedString(string: line, attributes: quiet)
        if let range = line.range(of: license, options: .backwards) {
            text.addAttribute(.link, value: URL(string: "https://github.com/ZigaoWang/zigzag/blob/main/LICENSE")!, range: NSRange(range, in: line))
        }
        return text
    }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    /// Lays everything out top down for `width`, and returns the height it takes.
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        let k = Tokens.Keepsake.self
        let left = k.margin, right = width - k.margin
        var y = k.top + k.size.height + k.gap
        let height = Tokens.Page.controlHeight
        let versionHeight = version.lineHeight
        let pad = Tokens.Space.x1, rowHeight = Tokens.Metric.rowHeight + Tokens.Space.x1
        let legalHeight = ceil(legal.sizeThatFits(NSSize(width: width, height: 100)).height)
        if apply {
            // The stage runs to the window's sides with the card in its middle, so the shadow and the turn have room.
            stage.frame = NSRect(x: 0, y: 0, width: width, height: (k.top + k.size.height / 2) * 2)
            let swatches = finishes.fittingSize
            finishes.frame = NSRect(x: left, y: y + (height - swatches.height) / 2, width: swatches.width, height: swatches.height)
            // The last symbol's ink on the card's right edge, its hover fill past it.
            var x = right + (height - Tokens.Space.x4) / 2
            for button in [share, save] {
                let w = button.fittingWidth
                x -= w
                button.frame = NSRect(x: x, y: y, width: w, height: height)
                x -= Tokens.Space.x1
            }
        }
        y += height + k.gap
        if apply { version.frame = NSRect(x: 0, y: y, width: width, height: versionHeight) }
        y += versionHeight + Tokens.Space.x4
        // The list, as wide as the card, a hairline between each two, the lines lined up with the text.
        let listHeight = CGFloat(rows.count) * rowHeight + pad * 2
        if apply {
            card.frame = NSRect(x: left, y: y, width: right - left, height: listHeight)
            card.layer?.borderColor = cgColor(Tokens.Color.surfaceGroupEdge)
            var rowY = y + pad
            for (i, row) in rows.enumerated() {
                row.frame = NSRect(x: left + pad, y: rowY, width: right - left - pad * 2, height: rowHeight)
                rowY += rowHeight
                if i < lines.count {
                    let lineX = row.frame.minX + CardRow.inset
                    lines[i].frame = NSRect(x: lineX, y: rowY - Tokens.Metric.hairline / 2, width: row.frame.maxX - CardRow.inset - lineX,
                                            height: Tokens.Metric.hairline)
                }
            }
        }
        y += listHeight + Tokens.Space.x5
        if apply { legal.frame = NSRect(x: 0, y: y, width: width, height: legalHeight) }
        return y + legalHeight + Tokens.Space.x5
    }

    // The card turns toward the pointer only while it's over the card or just beside it.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { stage.lean(toward: nil) }

    private func follow(_ event: NSEvent) {
        let location = stage.convert(event.locationInWindow, from: nil)
        let near = stage.cardFrame.insetBy(dx: -Tokens.Space.x3, dy: -Tokens.Space.x3).contains(location)
        stage.lean(toward: near ? stage.leanPoint(for: location) : nil)
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
            if let url { WindowManager.shared.openFromZigzag(url) }
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
