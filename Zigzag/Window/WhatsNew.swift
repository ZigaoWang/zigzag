import AppKit
import WebKit

/// After an update: a note that Zigzag updated, and this version's notes on a sheet. The notes are this version's
/// section of CHANGELOG.md, the same section the update window, the GitHub release and the website show.
enum WhatsNew {
    /// A GitHub issue or pull request a note is about: "#32" at its end, linked.
    struct Issue: Equatable {
        let number: Int
        let url: URL
    }

    /// One point: its words as inline Markdown (bold, code, links, credits), and the issues it closes.
    struct Item: Equatable {
        var text: String
        var issues: [Issue] = []
        /// Under the point before it, in a nested list.
        var nested = false
    }

    struct Section: Equatable {
        let title: String
        var items: [Item]
    }

    struct Release: Equatable {
        var date: Date?
        var sections: [Section] = []
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// This version's notes, read once from the copy of CHANGELOG.md in the app.
    static let release: Release = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Release() }
        return parse(text, version: notesVersion)
    }()

    static var sections: [Section] { release.sections }

    /// A beta (0.5.0-beta.2) shows the notes of the version it leads up to.
    static var notesVersion: String { version.components(separatedBy: "-").first ?? version }

    /// One version's notes from a Keep a Changelog file: under "## [1.2.3] - 2026-11-10", each "### New" starts a
    /// section and its "- " points are the items, up to the next version. A point can run on over more lines, and
    /// one indented under another is nested in it.
    static func parse(_ text: String, version: String) -> Release {
        var release = Release()
        var inVersion = false
        // The point the next line can run on from: none after a blank line or a heading.
        var open = false
        // The last point is still being read; once it's whole, its issues are taken off its end.
        var unfinished = false
        func finishItem() {
            guard unfinished, let s = release.sections.indices.last, let i = release.sections[s].items.indices.last else { return }
            unfinished = false
            release.sections[s].items[i] = item(release.sections[s].items[i].text, nested: release.sections[s].items[i].nested)
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inVersion { break }
                let heading = line.dropFirst(3)
                inVersion = heading.hasPrefix("[\(version)]") || heading.hasPrefix("\(version) ") || heading == version
                if inVersion { release.date = date(in: String(heading)) }
                continue
            }
            guard inVersion else { continue }
            if line.hasPrefix("### ") {
                finishItem()
                release.sections.append(Section(title: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces), items: []))
                open = false
            } else if line.isEmpty || line.hasPrefix("#") {
                open = false
            } else if line.hasPrefix("- ") || line.hasPrefix("* "), !release.sections.isEmpty {
                finishItem()
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
                release.sections[release.sections.count - 1].items.append(Item(text: String(line.dropFirst(2)), nested: indent >= 2))
                open = true
                unfinished = true
            } else if open, var last = release.sections.last?.items.last {
                // The same point, on the next line.
                last.text += " " + line
                release.sections[release.sections.count - 1].items[release.sections[release.sections.count - 1].items.count - 1] = last
            }
        }
        finishItem()
        release.sections.removeAll { $0.items.isEmpty }
        return release
    }

    /// "[0.7.7] - 2026-11-10" → that day.
    private static func date(in heading: String) -> Date? {
        guard let match = heading.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(heading[match]))
    }

    /// A point's words and the issues at its end: "Fixed. ([#1](…), [#2](…))" is "Fixed." with #1 and #2.
    static func item(_ text: String, nested: Bool = false) -> Item {
        let text = text.trimmingCharacters(in: .whitespaces)
        let trailing = #"\s*\(\s*\[#\d+\]\([^\s()]+\)(\s*,\s*\[#\d+\]\([^\s()]+\))*\s*\)\s*$"#
        guard let range = text.range(of: trailing, options: .regularExpression) else { return Item(text: text, nested: nested) }
        let refs = String(text[range])
        var issues: [Issue] = []
        let link = try? NSRegularExpression(pattern: #"\[#(\d+)\]\(([^\s()]+)\)"#)
        for match in link?.matches(in: refs, range: NSRange(refs.startIndex..., in: refs)) ?? [] {
            guard let number = Range(match.range(at: 1), in: refs).flatMap({ Int(refs[$0]) }),
                  let url = Range(match.range(at: 2), in: refs).flatMap({ URL(string: String(refs[$0])) }) else { continue }
            issues.append(Issue(number: number, url: url))
        }
        return Item(text: String(text[..<range.lowerBound]), issues: issues, nested: nested)
    }

    /// Where a link in the notes may go: the web, nothing else.
    static func isWebLink(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// A point as it reads on the sheet: its Markdown drawn (bold, italics, code, links in the accent), then its
    /// issues as small quiet links. Text that isn't valid Markdown reads as it's written.
    static func attributed(_ item: Item, accent: NSColor) -> NSAttributedString {
        let body = Tokens.Font.body()
        let out = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: item.text, options: options) {
            for run in parsed.runs {
                let words = String(parsed[run.range].characters)
                var font = body
                var color = Tokens.Color.textSecondary
                var attributes: [NSAttributedString.Key: Any] = [:]
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) {
                        font = .monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular)
                        color = Tokens.Color.textPrimary
                    }
                    if intent.contains(.stronglyEmphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                        color = Tokens.Color.textPrimary
                    }
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                if let url = run.link, isWebLink(url) {
                    color = accent
                    attributes[.link] = url
                    attributes[.toolTip] = url.absoluteString
                }
                attributes[.font] = font
                attributes[.foregroundColor] = color
                out.append(NSAttributedString(string: words, attributes: attributes))
            }
        } else {
            out.append(NSAttributedString(string: item.text, attributes: [.font: body, .foregroundColor: Tokens.Color.textSecondary]))
        }
        // The issues, after the words: small and quiet.
        let quiet: [NSAttributedString.Key: Any] = [.font: Tokens.Font.small(), .foregroundColor: Tokens.Color.textTertiary]
        for (index, issue) in item.issues.enumerated() where isWebLink(issue.url) {
            out.append(NSAttributedString(string: index == 0 ? " " : ", ", attributes: quiet))
            var link = quiet
            link[.link] = issue.url
            link[.toolTip] = String(localized: "#\(issue.number) on GitHub", comment: "Tooltip of an issue number at the end of a point in What’s New, like “#32 on GitHub”.")
            out.append(NSAttributedString(string: "#\(issue.number)", attributes: link))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The version whose notes are still owed: set at launch the first time a new version runs, cleared only once
    /// the offer has been on screen. A launch with no browser window to show it in keeps it for the next one.
    static let pendingKey = "WhatsNewPending"

    /// At launch, before anything records this version as run (`ProfileBackup` does, as it backs up): a new version
    /// owes its notes. A fresh install has nothing to compare against and stays quiet.
    static func noteLaunch(defaults: UserDefaults = .standard, version: String = version) {
        let last = defaults.string(forKey: "LastRunVersion")
        // Before this was remembered, a Mac that had launched Zigzag before was updating from an older version.
        let updated = last.map { $0 != version } ?? (defaults.integer(forKey: "LaunchCount") > 0)
        if updated { defaults.set(version, forKey: pendingKey) }
    }

    /// This version's notes haven't been offered yet.
    static func isPending(defaults: UserDefaults = .standard, version: String = version) -> Bool {
        defaults.string(forKey: pendingKey) == version
    }

    static func markOffered(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: pendingKey) }

    private static var keyObserver: Any?
    private static var settling: DispatchWorkItem?

    /// After launch: when this version's notes are owed, they're offered once a browser window is in front, so the
    /// offer is never lost to a window that isn't up yet. True while it's owed, so the default browser offer waits.
    @discardableResult
    static func offerIfUpdated() -> Bool {
        guard isPending() else { return false }
        // No notes for this version (a build between releases): nothing to offer.
        guard !sections.isEmpty else { markOffered(); return false }
        guard keyObserver == nil else { return true }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { settle() }
        }
        settle()
        return true
    }

    /// A moment after a window comes in front, once the restored tabs have settled, it looks again.
    private static func settle(after delay: TimeInterval = 1.2) {
        settling?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { offerNow() } }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func offerNow() {
        guard isPending() else { stopWaiting(); return }
        guard let controller = offerWindow() else {
            // A browser window in front with something over it (a confirmation): it looks again once that's gone.
            // Anything else waits for a browser window to come in front.
            if let front = NSApp.keyWindow?.windowController as? BrowserWindowController, !front.tabManager.isPrivate,
               !WindowManager.needsOnboarding { settle(after: 2) }
            return
        }
        // A site's question or Save password? at the top of the page goes first; the offer comes once it's answered.
        if PermissionPrompt.isShowing(in: controller) || SavePasswordPrompt.isShowing(in: controller.window) {
            settle(after: 2)
            return
        }
        WhatsNewOffer.show(in: controller)
        markOffered()
        stopWaiting()
    }

    /// The browser window in front, when it's one to offer the notes in: visible, not private, with nothing over it.
    /// Zigzag Mini, onboarding and the other windows wait for a browser window.
    static func offerWindow() -> BrowserWindowController? {
        guard !WindowManager.needsOnboarding, WelcomeWindowController.shared?.window?.isVisible != true,
              let window = NSApp.keyWindow, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              let controller = window.windowController as? BrowserWindowController, !controller.tabManager.isPrivate,
              !WhatsNewSheet.isShowing(in: window),
              !controller.root.overlay.subviews.contains(where: { $0 is ConfirmSheet }) else { return nil }
        return controller
    }

    private static func stopWaiting() {
        settling?.cancel()
        settling = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    static func show(in controller: BrowserWindowController) {
        // No notes for this version in the app (a build between releases): every release's notes, on the site.
        guard !sections.isEmpty else { controller.open(allNotes, disposition: .foregroundTab); return }
        // Asked for before the note came up, or with it up: it has nothing more to offer.
        markOffered()
        WhatsNewOffer.close(in: controller)
        WhatsNewSheet.present(in: controller)
    }

    static let allNotes = URL(string: "https://zigzagbrowser.com/release-notes")!
}

/// The notes for this version: the app icon, the version and its day on top, each section's points below with their
/// links and credits, and a way to every release before it.
final class WhatsNewSheet: NSView, NSTextViewDelegate {
    private let panel = FloatingPanelView()
    private let icon = NSImageView(image: NSApp.applicationIconImage)
    /// In the app's voice, as a page names itself.
    private let titleLabel: Label = {
        let label = Label("", font: Tokens.Font.voice(), color: Tokens.Color.textPrimary)
        label.attributedStringValue = Tokens.Font.voiceText(String(localized: "What’s New", comment: "Title of the sheet with this version's release notes."))
        return label
    }()
    private let versionLabel = Label(WhatsNewSheet.versionLine, font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var headings: [Label] = []
    /// Each section's points in order, a nil between sections.
    private var points: [(dot: ColorView, text: NSTextView, nested: Bool)?] = []
    private let buttons = DialogButtons()
    private let done = PillButton(title: String(localized: "Done", comment: "Button that closes the What’s New sheet."), style: .prominent)
    private let all = PillButton(title: String(localized: "All Release Notes", comment: "Button in the What’s New sheet: opens every version's notes on the website."), style: .quiet)
    private var monitor: Any?
    private weak var controller: BrowserWindowController?
    private var width: CGFloat { min(Tokens.Welcome.cardWidth, bounds.width - Tokens.Space.x6 * 2) }
    private let pad = Tokens.Space.x6
    /// The notes scroll between the header and the buttons, so a long list never pushes Done out of reach.
    private let scroll = NSScrollView()
    private let notes = FlippedView()

    /// "Version 0.7.7, November 10, 2026": the day in the app's own language.
    private static var versionLine: String {
        guard let date = WhatsNew.release.date else {
            return String(localized: "Version \(WhatsNew.version)", comment: "Under the title of the What’s New sheet: the version number, like 0.5.2.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return String(localized: "Version \(WhatsNew.version), \(formatter.string(from: date))",
                      comment: "Under the title of the What’s New sheet: the version number, then the day it was released, like “Version 0.7.7, November 10, 2026”.")
    }

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        [icon, titleLabel, versionLabel, buttons, scroll].forEach { panel.addSubview($0) }
        buttons.leading = [all]
        buttons.trailing = [done]
        done.tint = controller.promptAccent
        scroll.documentView = notes
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let accent = controller.promptAccent
        for section in WhatsNew.sections {
            let heading = Label(section.title, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
            heading.setAccessibilityRole(.staticText)
            headings.append(heading)
            notes.addSubview(heading)
            for item in section.items {
                let dot = ColorView(color: item.nested ? Tokens.Color.textTertiary : accent)
                dot.wantsLayer = true
                dot.layer?.cornerRadius = Tokens.Metric.bullet / 2
                let text = Self.textView(WhatsNew.attributed(item, accent: accent))
                text.delegate = self
                points.append((dot, text, item.nested))
                notes.addSubview(dot)
                notes.addSubview(text)
            }
            points.append(nil)
        }
        done.onClick = { [weak self] _ in self?.close() }
        all.onClick = { [weak self] _ in self?.openLink(WhatsNew.allNotes) }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(String(localized: "What’s New in Zigzag", comment: "VoiceOver name of the What’s New sheet."))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// A point's words, wrapping, with links you can click: read-only, drawn on the panel.
    private static func textView(_ text: NSAttributedString) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // Each link keeps its own ink (the accent, or quiet for an issue number), with the pointing hand over it.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: Tokens.Color.accent.withAlphaComponent(Tokens.Color.textSelectionAlpha)]
        view.textStorage?.setAttributedString(text)
        return view
    }

    /// The height `text` takes at `width`.
    private static func height(of text: NSTextView, width: CGFloat) -> CGFloat {
        guard let container = text.textContainer, let layout = text.layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    /// A link in the notes, or All Release Notes: in a new tab in front, once the notes are closed.
    private func openLink(_ url: URL) {
        guard WhatsNew.isWebLink(url) else { return }
        let controller = self.controller
        close()
        controller?.open(url, disposition: .foregroundTab)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        openLink(url)
        return true
    }

    static func present(in controller: BrowserWindowController) {
        guard let host = controller.window?.contentView, !host.subviews.contains(where: { $0 is WhatsNewSheet }) else { return }
        let sheet = WhatsNewSheet(controller: controller)
        sheet.frame = host.bounds
        sheet.autoresizingMask = [.width, .height]
        host.addSubview(sheet)
        sheet.layer?.backgroundColor = sheet.cgColor(Tokens.Color.scrim)
        sheet.alphaValue = 0
        // It eases in and out even from a key, as a confirmation does (`ConfirmSheet`).
        Tokens.Motion.animate(Tokens.Motion.entering, evenFromKeyboard: true, { sheet.animator().alphaValue = 1 })
        sheet.layoutSubtreeIfNeeded()
        sheet.panel.growsFrom = Tokens.Motion.sheetOrigin
        sheet.panel.present(arrival: .pop)
        sheet.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak sheet] event in
            guard let sheet, event.window === host.window else { return event }
            return sheet.handle(event)
        }
    }

    /// As a confirmation does (`ConfirmSheet`), no key gets past it to the window behind: Return, Esc and ⌘W close it,
    /// the arrows and the page keys scroll the notes, Space scrolls them and closes them at their end, ⌘C copies
    /// what's selected in them, and ⌘Q still quits.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command, key == "q" { return event }
        if mods == .command, key == "c", window?.firstResponder is NSTextView { return event }
        if mods.isEmpty && [36, 76, 53].contains(event.keyCode) || mods == .command && key == "w" { close(); return nil }
        guard mods.isEmpty || mods == .command else { return nil }
        let clip = scroll.contentView
        let line = Tokens.Space.x8, page = max(line, clip.bounds.height - line)
        let end = max(0, notes.frame.height - clip.bounds.height)
        var y = clip.bounds.minY
        switch event.keyCode {
        case 125: y += mods.isEmpty ? line : .greatestFiniteMagnitude
        case 126: y -= mods.isEmpty ? line : .greatestFiniteMagnitude
        case 49:
            let back = event.modifierFlags.contains(.shift)
            // Read to the end: Space is Done's, as on a page with nothing more to show.
            if !back, y >= end - 0.5 { close(); return nil }
            y += back ? -page : page
        case 121: y += page
        case 116: y -= page
        case 119: y = .greatestFiniteMagnitude
        case 115: y = 0
        default: return nil
        }
        y = min(max(0, y), end)
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
        panel.dismiss()
        Tokens.Motion.animate(Tokens.Motion.leaving, evenFromKeyboard: true, { self.animator().alphaValue = 0 }, completion: { self.removeFromSuperview() })
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
        let lineHeight = ceil(Tokens.Font.body().ascender - Tokens.Font.body().descender + Tokens.Font.body().leading)
        for point in points {
            if startsSection, headingIndex < headings.count {
                let heading = headings[headingIndex]
                // Its first letter where the bullets start: the label draws its text Label.inset in.
                if layingOut { heading.frame = NSRect(x: pad - Label.inset, y: y, width: inner + Label.inset * 2, height: heading.lineHeight) }
                y += heading.lineHeight + Tokens.Space.x2
                headingIndex += 1
                startsSection = false
            }
            guard let (dot, text, nested) = point else {
                y += Tokens.Space.x3
                startsSection = true
                continue
            }
            let x = pad + Tokens.Space.x4 * (nested ? 2 : 1)
            let h = Self.height(of: text, width: inner - (x - pad))
            if layingOut {
                text.frame = NSRect(x: x, y: y, width: inner - (x - pad), height: h)
                let b = Tokens.Metric.bullet
                // The bullet's left edge on the heading's first letter (a nested one's on its point's words).
                dot.frame = NSRect(x: x - Tokens.Space.x4, y: y + lineHeight / 2 - b / 2, width: b, height: b)
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
        // All Release Notes is words without a fill until the pointer is on it: the row reaches out by its padding, so
        // those words start where the headings and bullets do.
        let reach = Tokens.Space.x3
        buttons.frame = NSRect(x: pad - reach, y: panel.bounds.height - pad - DialogButtons.height, width: inner + reach, height: DialogButtons.height)
    }
}

/// "Zigzag updated to 0.7.7", at the top of the page the first time a new version runs, with its notes a click away.
/// The same panel a page's questions come in (`SavePasswordPrompt`): it slides down from the page's top edge and
/// stays, without stopping anything, until you answer it: Not Now puts it away (Esc too), What’s New is the
/// default (Return). The notes are in Help › What’s New in Zigzag after that.
final class WhatsNewOffer: FloatingPanelView {
    private let header = DialogHeader(title: String(localized: "Zigzag updated to \(WhatsNew.version)", comment: "Title of the note shown after an update, with the new version number, like 0.5.2."),
                                      subtitle: String(localized: "See what’s new and what’s fixed in this version.", comment: "Under “Zigzag updated to 0.7.7” in the note shown after an update."))
    private let buttons = DialogButtons()
    private let notNow = PillButton(title: String(localized: "Not Now", comment: "Button in the note shown after an update: puts it away."), style: .plain)
    private let open = PillButton(title: String(localized: "What’s New", comment: "Default button in the note shown after an update: shows the release notes."), style: .prominent)
    private weak var controller: BrowserWindowController?
    private var frameObservers: [Any] = []
    private var keyMonitor: Any?
    /// No click for its first half second, as on a site's question: a click meant for the page never lands on it.
    private var shownAt = Date.distantFuture
    private let pad = Tokens.Dialog.padding

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Tokens.Dialog.width, height: 0))
        radius = Tokens.Radius.panel
        header.setImage(NSApp.applicationIconImage)
        header.subtitle.lineBreakMode = .byTruncatingTail
        open.tint = controller.promptAccent
        [header, buttons].forEach { addSubview($0) }
        buttons.trailing = [notNow, open]
        notNow.onClick = { [weak self] _ in self?.close() }
        open.onClick = { [weak self] _ in self?.openNotes() }
        onLayout = { [weak self] in self?.layoutContent() }
        setAccessibilityRole(.group)
        setAccessibilityLabel(header.title.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func offer(in controller: BrowserWindowController) -> WhatsNewOffer? {
        controller.root.overlay.subviews.lazy.compactMap { $0 as? WhatsNewOffer }.first
    }

    static func show(in controller: BrowserWindowController) {
        guard offer(in: controller) == nil else { return }
        // Clear of a toast that might be up, as a page's questions come in.
        Toast.hide(in: controller)
        let offer = WhatsNewOffer(controller: controller)
        offer.slidesFromTop = true
        controller.root.overlay.addSubview(offer)
        offer.place()
        offer.present()
        offer.shownAt = Date()
        // The window resizing, the sidebar coming or going, or a split: it stays at the top of the page.
        for card in controller.promptPageViews {
            offer.frameObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: .main) { [weak offer] _ in
                MainActor.assumeIsolated { offer?.place() }
            })
        }
        // Return and Esc answer it while the keyboard isn't anywhere else: never a Return meant for a page, a field
        // or the command bar.
        offer.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak offer] event in
            guard let offer, let window = offer.window, event.window === window, offer.takesKeys,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 36, 76: offer.openNotes(); return nil
            case 53: offer.close(); return nil
            default: return event
            }
        }
        Announcement.post(offer.header.title.stringValue + ". " + offer.header.subtitle.stringValue, priority: .high)
    }

    /// Nothing else has the keyboard: no page, field or text, and nothing floating over the window.
    private var takesKeys: Bool {
        guard let controller, let window, !controller.promptIsCovered, !WhatsNewSheet.isShowing(in: window) else { return false }
        guard let responder = window.firstResponder as? NSView else { return true }
        if responder is NSText || responder is NSTextField { return false }
        var view: NSView? = responder
        while let v = view {
            if v is WKWebView { return false }
            view = v.superview
        }
        return true
    }

    /// Gone with its window: it stops listening.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Put away, for a site's question to come up where it was.
    static func close(in controller: BrowserWindowController) { offer(in: controller)?.close() }

    private func openNotes() {
        guard Toast.acceptsAction(shownAt: shownAt), let controller else { return }
        close()
        WhatsNew.show(in: controller)
    }

    #if DEBUG
    /// For the debug bridge: What’s New or Not Now, as its buttons would.
    static func debugAnswer(open: Bool, in controller: BrowserWindowController) {
        guard let offer = offer(in: controller) else { debugLog("whatsnewoffer: none showing"); return }
        offer.shownAt = .distantPast
        if open { offer.openNotes() } else { offer.close() }
    }

    static func debugShowing(in controller: BrowserWindowController) -> Bool { offer(in: controller) != nil }
    #endif

    private var measuredHeight: CGFloat {
        let inner = frame.width - pad * 2
        return pad + header.height(for: inner) + Tokens.Dialog.gap + DialogButtons.height + pad
    }

    /// At the top of the page, in the middle.
    private func place() {
        guard let controller, superview != nil else { return }
        let area = controller.root.cardFrame
        let width = min(Tokens.Dialog.width, area.width - Tokens.Space.x6)
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3, width: width, height: frame.height)
        frame.size.height = measuredHeight
    }

    private func close() {
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameObservers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        dismiss()
    }

    private func layoutContent() {
        let inner = bounds.width - pad * 2
        header.frame = NSRect(x: pad, y: pad, width: inner, height: header.height(for: inner))
        buttons.frame = NSRect(x: pad, y: header.frame.maxY + Tokens.Dialog.gap, width: inner, height: DialogButtons.height)
    }
}
