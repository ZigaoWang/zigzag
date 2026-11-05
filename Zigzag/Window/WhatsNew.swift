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
        return parse(text, version: notesVersion)
    }

    /// A beta (0.5.0-beta.2) shows the notes of the version it leads up to.
    static var notesVersion: String { version.components(separatedBy: "-").first ?? version }

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
                sections[sections.count - 1].items.append(plain(String(line.dropFirst(2))))
            }
        }
        return sections.filter { !$0.items.isEmpty }
    }

    /// A note as it reads in the app: issue references ("([#3](…))") are for GitHub and the website, so they go,
    /// and any other link keeps only its words.
    static func plain(_ item: String) -> String {
        var text = item.replacingOccurrences(of: #"\s*\((\[#\d+\]\([^)]*\)(,\s*)?)+\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return text
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
        // No notes for this version in the app (a build between releases): every release's notes, on the site.
        guard !sections.isEmpty else { controller.open(allNotes, disposition: .foregroundTab); return }
        guard let host = controller.window?.contentView else { return }
        WhatsNewSheet.present(in: host)
    }

    static let allNotes = URL(string: "https://zigzagbrowser.com/release-notes")!
}

/// The notes for this version: the app icon and version on top, each section's points below, and a way to every
/// release before it.
final class WhatsNewSheet: NSView {
    private let panel = FloatingPanelView()
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    /// In the app's voice, as a page names itself.
    private let titleLabel: Label = {
        let label = Label("", font: Tokens.Font.voice(), color: Tokens.Color.textPrimary)
        label.attributedStringValue = Tokens.Font.voiceText("What’s New")
        return label
    }()
    private let versionLabel = Label("Version \(WhatsNew.version)", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var headings: [Label] = []
    private var points: [(dot: ColorView, text: NSTextField)] = []
    private let buttons = DialogButtons()
    private let done = PillButton(title: "Done", style: .prominent)
    private let all = PillButton(title: "All Release Notes", style: .quiet)
    private var monitor: Any?
    private var width: CGFloat { min(Tokens.Welcome.cardWidth, bounds.width - Tokens.Space.x6 * 2) }
    private let pad = Tokens.Space.x6
    /// The notes scroll between the header and the buttons, so a long list never pushes Done out of reach.
    private let scroll = NSScrollView()
    private let notes = FlippedView()

    private init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        [icon, titleLabel, versionLabel, buttons, scroll].forEach { panel.addSubview($0) }
        buttons.leading = [all]
        buttons.trailing = [done]
        scroll.documentView = notes
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for section in WhatsNew.sections {
            let heading = Label(section.title, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
            headings.append(heading)
            notes.addSubview(heading)
            for item in section.items {
                let dot = ColorView(color: Tokens.Color.accent)
                dot.wantsLayer = true
                dot.layer?.cornerRadius = Tokens.Metric.bullet / 2
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
        setAccessibilityLabel("What’s New in Zigzag")
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
        // It eases in and out even from a key, as a confirmation does (`ConfirmSheet`).
        Tokens.Motion.animate(Tokens.Motion.feedback, evenFromKeyboard: true, { sheet.animator().alphaValue = 1 })
        sheet.layoutSubtreeIfNeeded()
        sheet.panel.growsFrom = CGPoint(x: 0.5, y: 0.5)
        sheet.panel.present(always: true, arrival: .pop)
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === host.window else { return event }
            return sheet.handle(event)
        }
    }

    /// As a confirmation does (`ConfirmSheet`), no key gets past it to the window behind: Return, Esc and ⌘W close it,
    /// the arrows, Space and the page keys scroll the notes, and ⌘Q still quits.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command, key == "q" { return event }
        if mods.isEmpty && [36, 76, 53].contains(event.keyCode) || mods == .command && key == "w" { close(); return nil }
        guard mods.isEmpty || mods == .command else { return nil }
        let clip = scroll.contentView
        let line = Tokens.Space.x8, page = max(line, clip.bounds.height - line)
        var y = clip.bounds.minY
        switch event.keyCode {
        case 125: y += mods.isEmpty ? line : .greatestFiniteMagnitude
        case 126: y -= mods.isEmpty ? line : .greatestFiniteMagnitude
        case 49: y += event.modifierFlags.contains(.shift) ? -page : page
        case 121: y += page
        case 116: y -= page
        case 119: y = .greatestFiniteMagnitude
        case 115: y = 0
        default: return nil
        }
        y = min(max(0, y), max(0, notes.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        return nil
    }

    /// True while the notes cover `window`: anything else there waits, and leaves the keys to them.
    static func isShowing(in window: NSWindow?) -> Bool {
        window?.contentView?.subviews.contains(where: { $0 is WhatsNewSheet }) ?? false
    }

    /// Runs `body` once the notes are gone from `window`: at once if they aren't up.
    static func afterClosing(in window: NSWindow?, _ body: @escaping () -> Void) {
        guard let sheet = window?.contentView?.subviews.lazy.compactMap({ $0 as? WhatsNewSheet }).first else { body(); return }
        sheet.waiting.append(body)
    }

    private var waiting: [() -> Void] = []

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.dismiss(always: true)
        Tokens.Motion.animate(Tokens.Motion.feedback, evenFromKeyboard: true, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
    }

    /// Gone, closed or with its window: what was waiting goes ahead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let waiting = self.waiting
        self.waiting = []
        waiting.forEach { $0() }
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
    private var footerHeight: CGFloat { Tokens.Dialog.gap + DialogButtons.height + pad }

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
                let b = Tokens.Metric.bullet
                dot.frame = NSRect(x: pad + Tokens.Space.x1, y: lineMid - b / 2, width: b, height: b)
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
        buttons.frame = NSRect(x: pad, y: panel.bounds.height - pad - DialogButtons.height, width: inner, height: DialogButtons.height)
    }
}
