import AppKit

/// After an update: a quiet note that Zigzag updated, and this version's notes on a sheet. The notes are this
/// version's section of CHANGELOG.md, the same section the update window, the GitHub release and the website show.
enum WhatsNew {
    struct Section {
        let title: String
        var items: [String]
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static var sections: [Section] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text, version: version)
    }

    /// One version's notes from a Keep a Changelog file: under "## [1.2.3] - date", each "### New" starts a section
    /// and its "- " lines are the items, up to the next version.
    static func parse(_ text: String, version: String) -> [Section] {
        var sections: [Section] = []
        var inVersion = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inVersion { break }
                let heading = line.dropFirst(3)
                inVersion = heading.hasPrefix("[\(version)]") || heading.hasPrefix("\(version) ") || heading == version
            } else if inVersion, line.hasPrefix("### ") {
                sections.append(Section(title: String(line.dropFirst(4)), items: []))
            } else if inVersion, line.hasPrefix("- "), !sections.isEmpty {
                sections[sections.count - 1].items.append(String(line.dropFirst(2)))
            }
        }
        return sections.filter { !$0.items.isEmpty }
    }

    private static let lastVersionKey = "LastRunVersion"

    /// On launch: the first time a new version runs, say so once, with the notes a click away. A fresh install
    /// has nothing to compare against and stays quiet.
    @discardableResult
    static func offerIfUpdated() -> Bool {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: lastVersionKey)
        // Before this was remembered, a Mac that had launched Zigzag before was updating from an older version.
        let updated = last.map { $0 != version } ?? (defaults.integer(forKey: "LaunchCount") > 0)
        defaults.set(version, forKey: lastVersionKey)
        guard updated, !sections.isEmpty, !WindowManager.needsOnboarding else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let controller = WindowManager.shared.keyController else { return }
            Toast.show("Zigzag updated to \(version)", symbol: "sparkles", action: ("What’s New", { show(in: controller) }),
                       duration: 10, in: controller)
        }
        return true
    }

    static func show(in controller: BrowserWindowController) {
        guard let host = controller.window?.contentView else { return }
        WhatsNewSheet.present(in: host)
    }

    static let allNotes = URL(string: "https://zigzagbrowser.com/changelog")!
}

/// The notes for this version: the app icon and version on top, each section's points below, and a way to every
/// release before it.
final class WhatsNewSheet: NSView {
    private let panel = FloatingPanelView()
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let titleLabel = Label("What’s new in Zigzag", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let versionLabel = Label("Version \(WhatsNew.version)", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var headings: [Label] = []
    private var points: [(dot: ColorView, text: NSTextField)] = []
    private let done = PrimaryButton(title: "Done")
    private let all = TextButton(title: "All Release Notes", font: Tokens.Font.body(.medium))
    private var monitor: Any?
    private var width: CGFloat { min(560, bounds.width - Tokens.Space.x6 * 2) }
    private let pad = Tokens.Space.x6
    /// The notes scroll between the header and the buttons, so a long list never pushes Done out of reach.
    private let scroll = NSScrollView()
    private let notes = FlippedView()

    private init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        [icon, titleLabel, versionLabel, done, all, scroll].forEach { panel.addSubview($0) }
        scroll.documentView = notes
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for section in WhatsNew.sections {
            let heading = Label(section.title, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
            headings.append(heading)
            notes.addSubview(heading)
            for item in section.items {
                let dot = ColorView(color: Tokens.Color.accent)
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 2.5
                let text = NSTextField(wrappingLabelWithString: item)
                text.font = Tokens.Font.body()
                text.textColor = Tokens.Color.textSecondary
                text.isSelectable = false
                points.append((dot, text))
                notes.addSubview(dot)
                notes.addSubview(text)
            }
            // Marks where the next section starts.
            points.append((ColorView(color: .clear), NSTextField(labelWithString: "")))
        }
        done.onClick = { [weak self] _ in self?.close() }
        all.onClick = { [weak self] _ in
            NSWorkspace.shared.open(WhatsNew.allNotes)
            self?.close()
        }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("What’s new in Zigzag")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func present(in host: NSView) {
        guard !host.subviews.contains(where: { $0 is WhatsNewSheet }) else { return }
        let sheet = WhatsNewSheet()
        sheet.frame = host.bounds
        sheet.autoresizingMask = [.width, .height]
        host.addSubview(sheet)
        sheet.layer?.backgroundColor = sheet.cgColor(Tokens.Color.scrim)
        sheet.alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.feedback, { sheet.animator().alphaValue = 1 })
        sheet.layoutSubtreeIfNeeded()
        sheet.panel.growsFrom = CGPoint(x: 0.5, y: 0.5)
        sheet.panel.present(arrival: .pop)
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === host.window else { return event }
            if [36, 76, 53].contains(event.keyCode) { sheet.close(); return nil }
            return event
        }
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
    }

    // A click outside the panel closes it; nothing reaches the window underneath.
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = cgColor(Tokens.Color.scrim)
    }

    override func layout() {
        super.layout()
        let maxHeight = bounds.height - Tokens.Space.x12
        let height = min(headerHeight + notesHeight() + footerHeight, maxHeight)
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: round(max(Tokens.Space.x6, (bounds.height - height) / 2.4)),
                             width: width, height: height)
    }

    private let iconSize: CGFloat = 52
    private var headerHeight: CGFloat { pad + iconSize + Tokens.Space.x5 }
    private var footerHeight: CGFloat { Tokens.Space.x4 + Tokens.Space.x8 + pad }

    /// Lays the notes out in their scrolling column; returns how tall they are.
    @discardableResult
    private func notesHeight(layingOut: Bool = false) -> CGFloat {
        let inner = width - pad * 2
        var y: CGFloat = 0
        var headingIndex = 0
        var startsSection = true
        for (dot, text) in points {
            if startsSection, headingIndex < headings.count {
                let heading = headings[headingIndex]
                if layingOut { heading.frame = NSRect(x: pad, y: y, width: inner, height: heading.lineHeight) }
                y += heading.lineHeight + Tokens.Space.x2
                headingIndex += 1
                startsSection = false
            }
            if text.stringValue.isEmpty {
                y += Tokens.Space.x3
                startsSection = true
                continue
            }
            let h = ceil(text.sizeThatFits(NSSize(width: inner - Tokens.Space.x4, height: 400)).height)
            if layingOut {
                text.frame = NSRect(x: pad + Tokens.Space.x4, y: y, width: inner - Tokens.Space.x4, height: h)
                let lineMid = y + (text.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16) / 2
                dot.frame = NSRect(x: pad + Tokens.Space.x1, y: lineMid - 2.5, width: 5, height: 5)
            }
            y += h + Tokens.Space.x2
        }
        return y
    }

    private func layoutPanel() {
        let inner = width - pad * 2
        icon.frame = NSRect(x: pad, y: pad, width: iconSize, height: iconSize)
        let textX = pad + iconSize + Tokens.Space.x3
        let block = titleLabel.lineHeight + Tokens.Space.x1 + versionLabel.lineHeight
        titleLabel.frame = NSRect(x: textX, y: pad + (iconSize - block) / 2, width: inner - iconSize - Tokens.Space.x3, height: titleLabel.lineHeight)
        versionLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + Tokens.Space.x1, width: titleLabel.frame.width, height: versionLabel.lineHeight)
        let contentHeight = notesHeight(layingOut: true)
        let scrollHeight = panel.bounds.height - headerHeight - footerHeight
        scroll.frame = NSRect(x: 0, y: headerHeight, width: width, height: max(0, scrollHeight))
        notes.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(contentHeight, scroll.contentSize.height))
        let y = panel.bounds.height - pad - Tokens.Space.x8
        let dw = max(done.fittingWidth, 88)
        done.frame = NSRect(x: width - pad - dw, y: y, width: dw, height: Tokens.Space.x8)
        all.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: all.fittingWidth, height: Tokens.Space.x8)
    }
}
