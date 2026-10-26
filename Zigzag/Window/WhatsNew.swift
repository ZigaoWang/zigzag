import AppKit

/// After an update: a quiet note that Zigzag updated, and this version's notes on a sheet. The notes are
/// Resources/WhatsNew.md, the same file the update window and the GitHub release show.
enum WhatsNew {
    struct Section {
        let title: String
        var items: [String]
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static var sections: [Section] {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// "## New" starts a section; "- " lines are its items.
    static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                sections.append(Section(title: String(line.dropFirst(3)), items: []))
            } else if line.hasPrefix("- "), !sections.isEmpty {
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

    static let allNotes = URL(string: "https://github.com/ZigaoWang/zigzag/releases")!
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
    private let width: CGFloat = 440
    private let pad = Tokens.Space.x6

    private init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        [icon, titleLabel, versionLabel, done, all].forEach { panel.addSubview($0) }
        for section in WhatsNew.sections {
            let heading = Label(section.title, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
            headings.append(heading)
            panel.addSubview(heading)
            for item in section.items {
                let dot = ColorView(color: Tokens.Color.accent)
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 2.5
                let text = NSTextField(wrappingLabelWithString: item)
                text.font = Tokens.Font.body()
                text.textColor = Tokens.Color.textSecondary
                text.isSelectable = false
                points.append((dot, text))
                panel.addSubview(dot)
                panel.addSubview(text)
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
        let height = layoutPanel(measureOnly: true)
        panel.frame = NSRect(x: round((bounds.width - width) / 2), y: round(max(Tokens.Space.x6, (bounds.height - height) / 2.4)),
                             width: width, height: min(height, bounds.height - Tokens.Space.x12))
    }

    @discardableResult
    private func layoutPanel(measureOnly: Bool = false) -> CGFloat {
        let inner = width - pad * 2
        let iconSize: CGFloat = 52
        var y = pad
        if !measureOnly {
            icon.frame = NSRect(x: pad, y: y, width: iconSize, height: iconSize)
            let textX = pad + iconSize + Tokens.Space.x3
            let block = titleLabel.lineHeight + Tokens.Space.x1 + versionLabel.lineHeight
            titleLabel.frame = NSRect(x: textX, y: y + (iconSize - block) / 2, width: inner - iconSize - Tokens.Space.x3, height: titleLabel.lineHeight)
            versionLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + Tokens.Space.x1, width: titleLabel.frame.width, height: versionLabel.lineHeight)
        }
        y += iconSize + Tokens.Space.x5
        var headingIndex = 0
        var startsSection = true
        for (dot, text) in points {
            if startsSection, headingIndex < headings.count {
                let heading = headings[headingIndex]
                if !measureOnly { heading.frame = NSRect(x: pad, y: y, width: inner, height: heading.lineHeight) }
                y += heading.lineHeight + Tokens.Space.x2
                headingIndex += 1
                startsSection = false
            }
            if text.stringValue.isEmpty {
                // The end of a section.
                y += Tokens.Space.x3
                startsSection = true
                continue
            }
            let textX = pad + Tokens.Space.x4
            let h = ceil(text.sizeThatFits(NSSize(width: inner - Tokens.Space.x4, height: 400)).height)
            if !measureOnly {
                text.frame = NSRect(x: textX, y: y, width: inner - Tokens.Space.x4, height: h)
                let lineMid = y + (text.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16) / 2
                dot.frame = NSRect(x: pad + Tokens.Space.x1, y: lineMid - 2.5, width: 5, height: 5)
            }
            y += h + Tokens.Space.x2
        }
        y += Tokens.Space.x2
        if !measureOnly {
            let dw = max(done.fittingWidth, 88)
            done.frame = NSRect(x: width - pad - dw, y: y, width: dw, height: Tokens.Space.x8)
            let aw = all.fittingWidth
            all.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: aw, height: Tokens.Space.x8)
        }
        return y + Tokens.Space.x8 + pad
    }
}
