import AppKit
import UniformTypeIdentifiers

/// "Bring your stuff from another browser." Shown in the empty page on first launch, and in its own window
/// from Settings and the command bar. Pick browsers, pick what to bring, import; then a plain summary, and a
/// one-click fix for anything that couldn't come over.
final class ImportView: NSView {
    var onClose: (() -> Void)?

    /// First launch shows it in the empty page, under the wordmark; elsewhere it's its own window, under a banner.
    enum Presentation { case welcome, window }
    let presentation: Presentation

    private enum Stage { case choose, importing, done }
    private var stage = Stage.choose

    private let hero = ImportHero()
    private let banner = BrandBanner()
    private var summaries: [ImportCoordinator.Summary] = []

    private let title = Label("", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private var sources: [ImportCoordinator.Source] = []
    private var rows: [SourceRow] = []
    private let choiceLabel = Label("Bring", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private var choiceButtons: [(ImportCoordinator.Choice, ChoicePill)] = []
    private let chooseFile = TextButton(title: "Choose a File…", font: Tokens.Font.body(.medium))
    private let primary = PrimaryButton(title: "Import")
    private let secondary = TextButton(title: "Not Now", font: Tokens.Font.body(.medium))
    private let emptyNote = NSTextField(wrappingLabelWithString: "No other browsers with data were found on this Mac. You can still bring passwords from a CSV export.")

    init(presentation: Presentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        switch presentation {
        case .welcome:
            // It sits in the page; whatever page is there stays out of sight behind it.
            layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
            title.stringValue = "Welcome to Zigzag"
            subtitle.stringValue = "Bring your passwords, bookmarks and Arc spaces over in one go. Your other browser stays exactly as it is."
            addSubview(hero)
        case .window:
            title.stringValue = ""
            subtitle.stringValue = ""
            banner.title = "Bring your stuff over"
            banner.subtitle = "Passwords, bookmarks and history, from any browser on this Mac."
            addSubview(banner)
        }
        subtitle.font = Tokens.Font.body()
        subtitle.textColor = Tokens.Color.textSecondary
        subtitle.isSelectable = false
        emptyNote.font = Tokens.Font.body()
        emptyNote.textColor = Tokens.Color.textSecondary
        emptyNote.isSelectable = false
        [title, subtitle, choiceLabel, chooseFile, primary, secondary].forEach { addSubview($0) }
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & tabs")] {
            let box = ChoicePill(title: name)
            box.tint = Brand.Theme.current.accent
            box.onChange = { [weak self] _ in self?.choicesChanged() }
            addSubview(box)
            choiceButtons.append((choice, box))
        }
        chooseFile.onClick = { [weak self] _ in self?.pickFile() }
        primary.onClick = { [weak self] _ in self?.primaryAction() }
        secondary.onClick = { [weak self] _ in self?.onClose?() }
        reloadSources()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if presentation == .welcome { layer?.backgroundColor = cgColor(Tokens.Color.cardBackground) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, presentation == .welcome else { return }
        hero.showWordmark(drawIn: !Brand.hasDrawnIn)
        Brand.hasDrawnIn = true
    }

    private func reloadSources() {
        rows.forEach { $0.removeFromSuperview() }
        sources = ImportCoordinator.detectedSources()
        rows = sources.enumerated().map { index, source in
            let row = SourceRow(source: source)
            // Arc first and on; the rest start off so nothing comes over by surprise.
            row.isChosen = index == 0
            row.onToggle = { [weak self] in self?.choicesChanged() }
            addSubview(row)
            return row
        }
        if sources.isEmpty { addSubview(emptyNote) } else { emptyNote.removeFromSuperview() }
        choicesChanged()
    }

    @objc private func choicesChanged() {
        let anyArc = rows.contains { $0.isChosen && $0.source.offers.contains(.tabs) }
        choiceButtons.first { $0.0 == .tabs }?.1.isHidden = !anyArc
        primary.isEnabled = stage != .choose || (rows.contains(where: \.isChosen) && !chosenData.isEmpty)
        needsLayout = true
    }

    private var chosenData: ImportCoordinator.Choice {
        choiceButtons.reduce(into: []) { result, pair in if pair.1.isOn, !pair.1.isHidden { result.insert(pair.0) } }
    }

    private func primaryAction() {
        switch stage {
        case .choose: startImport(rows.filter(\.isChosen))
        case .importing: break
        case .done: onClose?()
        }
    }

    // MARK: Importing

    private func startImport(_ chosen: [SourceRow]) {
        guard !chosen.isEmpty else { return }
        stage = .importing
        title.stringValue = "Bringing it over…"
        subtitle.stringValue = "macOS may ask to let Zigzag open a browser’s saved passwords. Choose Allow, and it carries on."
        primary.title = "Importing…"
        primary.isEnabled = false
        secondary.isHidden = true
        chooseFile.isHidden = true
        choiceLabel.isHidden = true
        choiceButtons.forEach { $0.1.isHidden = true }
        rows.filter { !$0.isChosen }.forEach { $0.isHidden = true }
        chosen.forEach { $0.state = .waiting }
        needsLayout = true
        let data = chosenData
        Task { @MainActor in
            for row in chosen { await run(row, data) }
            finish()
        }
    }

    private func run(_ row: SourceRow, _ data: ImportCoordinator.Choice, primaryPassword: String = "") async {
        row.state = .working
        let choice = data.intersection(row.source.offers)
        let summary = await ImportCoordinator.run(row.source, choice, primaryPassword: primaryPassword)
        summaries.removeAll { $0.source == summary.source }
        summaries.append(summary)
        row.state = .done(summary)
        row.onFix = { [weak self, weak row] fix, password in
            guard let self, let row else { return }
            self.fix(fix, for: row, data: data, primaryPassword: password)
        }
        needsLayout = true
    }

    private func finish() {
        stage = .done
        title.stringValue = "You’re all set"
        subtitle.stringValue = "Passwords are in your Keychain and sync with iCloud Keychain. They’re in Passwords whenever you need them."
        // The finished moment: the lit surface, the count, and the ribbon writing itself across it.
        if hero.superview == nil { addSubview(hero) }
        banner.isHidden = true
        hero.showSuccess(summaries)
        primary.title = "Done"
        fitWindow()
        primary.isEnabled = true
        needsLayout = true
    }

    /// In its own window, the window follows the content: shorter once only the summary is left.
    func fitWindow() {
        guard presentation == .window, let window else { return }
        layoutSubtreeIfNeeded()
        let bottom = subviews.filter { !$0.isHidden && $0.superview === self }.map(\.frame.maxY).max() ?? bounds.height
        let height = min(bottom + Tokens.Space.x6, 780)
        var frame = window.frame
        let delta = height - window.contentLayoutRect.height
        guard abs(delta) > 1 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
    }

    #if DEBUG
    /// For the debug bridge: the finished screen with sample numbers, without importing anything.
    func debugShowSuccess() {
        var arc = ImportCoordinator.Summary(source: "Arc")
        arc.passwords = 214
        arc.bookmarks = 86
        arc.spaces = 3
        summaries = [arc]
        rows.filter { !$0.isChosen }.forEach { $0.isHidden = true }
        [secondary, chooseFile, choiceLabel].forEach { $0.isHidden = true }
        choiceButtons.forEach { $0.1.isHidden = true }
        finish()
    }
    #endif

    private func fix(_ fix: ImportProblem.Fix, for row: SourceRow, data: ImportCoordinator.Choice, primaryPassword: String) {
        switch fix {
        case .retry, .primaryPassword:
            stage = .importing
            primary.isEnabled = false
            Task { @MainActor in
                await run(row, data, primaryPassword: primaryPassword)
                finish()
            }
        case .fullDiskAccess:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        case .exportFromApplePasswords:
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            pickFile()
        case .none:
            break
        }
    }

    /// A password CSV, or Safari's browsing data zip.
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .zip]
        panel.message = "Choose a password export (a .csv file) or Safari's browsing data export (a .zip file)."
        panel.prompt = "Import"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let row = SourceRow(source: ImportCoordinator.fileSource(url))
            row.isChosen = true
            self.addSubview(row)
            self.rows.append(row)
            self.startImport([row])
            row.exportFile = url
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width: CGFloat = 440
        let x = round((bounds.width - width) / 2)
        var y: CGFloat = 0
        func place(_ view: NSView, height: CGFloat, gap: CGFloat = 0) {
            view.frame = NSRect(x: x, y: y, width: width, height: height)
            y += height + gap
        }
        let subtitleHeight = ceil(subtitle.sizeThatFits(NSSize(width: width, height: 200)).height)
        let visibleRows = rows.filter { !$0.isHidden }
        let rowsHeight = visibleRows.map(\.preferredHeight).reduce(0, +) + CGFloat(max(0, visibleRows.count - 1)) * Tokens.Space.x2
        let showsChoices = stage == .choose && !sources.isEmpty
        let choicesHeight: CGFloat = showsChoices ? Tokens.Space.x4 + Tokens.Space.x2 + Tokens.Space.x8 : 0
        let emptyHeight: CGFloat = sources.isEmpty && stage == .choose ? ceil(emptyNote.sizeThatFits(NSSize(width: width, height: 200)).height) + Tokens.Space.x4 : 0
        let showsHero = hero.superview != nil
        let heroHeight: CGFloat = showsHero ? ImportHero.height + Tokens.Space.x8 : 0
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let total = heroHeight + titleHeight + Tokens.Space.x2 + subtitleHeight + Tokens.Space.x6 + rowsHeight + emptyHeight
            + (showsChoices ? Tokens.Space.x6 + choicesHeight : 0) + Tokens.Space.x8 + Tokens.Space.x8
        if presentation == .window {
            banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 128)
            banner.contentInset = x
            y = (banner.isHidden ? Tokens.Space.x12 : banner.frame.maxY + Tokens.Space.x6)
        } else {
            y = max(Tokens.Space.x8, round((bounds.height - total) / 2))
        }
        if showsHero {
            hero.frame = NSRect(x: x, y: y, width: width, height: ImportHero.height)
            y = hero.frame.maxY + Tokens.Space.x6
        }
        title.alignment = .left
        title.attributedStringValue = Brand.display(title.stringValue, size: 22, color: Tokens.Color.textPrimary)
        if !title.stringValue.isEmpty {
            place(title, height: titleHeight, gap: Tokens.Space.x2)
            place(subtitle, height: subtitleHeight, gap: Tokens.Space.x6)
        }
        if emptyHeight > 0 { place(emptyNote, height: emptyHeight - Tokens.Space.x4, gap: Tokens.Space.x4) }
        for row in visibleRows { place(row, height: row.preferredHeight, gap: Tokens.Space.x2) }
        if showsChoices {
            y += Tokens.Space.x4
            choiceLabel.isHidden = false
            place(choiceLabel, height: choiceLabel.lineHeight, gap: Tokens.Space.x2)
            var cx = x
            for (_, box) in choiceButtons where !box.isHidden {
                let w = box.fittingWidth
                if cx + w > x + width { cx = x; y += Tokens.Space.x8 + Tokens.Space.x2 }
                box.frame = NSRect(x: cx, y: y, width: w, height: Tokens.Space.x8)
                cx += w + Tokens.Space.x2
            }
            y += Tokens.Space.x8
        }
        y += Tokens.Space.x8
        let buttonHeight = Tokens.Space.x8
        let pw = max(primary.fittingWidth, 96)
        primary.frame = NSRect(x: x + width - pw, y: y, width: pw, height: buttonHeight)
        if !secondary.isHidden {
            let sw = secondary.fittingWidth
            secondary.frame = NSRect(x: primary.frame.minX - Tokens.Space.x2 - sw, y: y, width: sw, height: buttonHeight)
        }
        if !chooseFile.isHidden {
            chooseFile.frame = NSRect(x: x - Tokens.Space.x2, y: y, width: chooseFile.fittingWidth, height: buttonHeight)
        }
    }
}

/// One browser (or a chosen file): its real icon, its name, and as the import runs, what came over.
private final class SourceRow: InteractiveView {
    enum State { case idle, waiting, working, done(ImportCoordinator.Summary) }

    let source: ImportCoordinator.Source
    var onToggle: (() -> Void)?
    var onFix: ((ImportProblem.Fix, String) -> Void)?
    /// A chosen export: once its passwords are in, offer to move it to the Trash, since it holds them unprotected.
    var exportFile: URL?

    var isChosen = false { didSet { stateDidChange(animated: true); refresh() } }
    var state = State.idle { didSet { refresh() } }

    private let icon = NSImageView()
    private let name: Label
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let spinner = RibbonView()
    private var fixViews: [NSView] = []
    private var passwordField: FilledField?
    /// What the browser holds, filled in once counted.
    private var preview = "Looking…" { didSet { refresh() } }

    init(source: ImportCoordinator.Source) {
        self.source = source
        name = Label(source.name, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.panel - 2
        layer?.cornerCurve = .continuous
        icon.image = source.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        detail.font = Tokens.Font.small()
        detail.textColor = Tokens.Color.textSecondary
        detail.isSelectable = false
        spinner.color = Brand.Theme.current.accent
        spinner.isHidden = true
        check.isHidden = true
        [icon, name, detail, check, spinner].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, case .idle = self.state else { return }
            self.isChosen.toggle()
            self.onToggle?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(source.name)
        refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.preview = await ImportCoordinator.preview(source)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        let base = Tokens.Space.x12 + Tokens.Space.x2
        let detailHeight = detail.stringValue.isEmpty ? 0 : ceil(detail.sizeThatFits(NSSize(width: 440 - 96, height: 400)).height)
        let fixes = fixViews.isEmpty ? 0 : Tokens.Space.x8 + Tokens.Space.x2
        return max(base, Tokens.Space.x3 + name.lineHeight + 2 + detailHeight + Tokens.Space.x3 + fixes)
    }

    private func refresh() {
        fixViews.forEach { $0.removeFromSuperview() }
        fixViews = []
        passwordField = nil
        spinner.stopLooping()
        spinner.isHidden = true
        check.isHidden = true
        switch state {
        case .idle:
            detail.stringValue = preview
            check.isHidden = !isChosen
            check.image = Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.large)
            check.contentTintColor = Brand.Theme.current.accent
        case .waiting:
            detail.stringValue = "Waiting…"
        case .working:
            detail.stringValue = "Bringing it over…"
            spinner.isHidden = false
            spinner.startLooping()
        case .done(let summary):
            detail.stringValue = ([summary.sentence] + summary.problems.map(\.message)).joined(separator: "\n")
            check.isHidden = false
            let clean = summary.problems.isEmpty
            check.image = Tokens.Symbol.image(clean ? "checkmark.circle.fill" : "exclamationmark.circle.fill", size: Tokens.TypeSize.large)
            check.contentTintColor = clean ? .systemGreen : .systemOrange
            for problem in summary.problems { addFix(problem.fix) }
            if let exportFile, summary.passwords + summary.updatedPasswords > 0, FileManager.default.fileExists(atPath: exportFile.path) {
                detail.stringValue += "\nThe file still holds your passwords unprotected. It's safer to move it to the Trash."
                let button = TextButton(title: "Move to Trash", font: Tokens.Font.body(.medium))
                button.showsFillAtRest = true
                button.onClick = { [weak self, weak button] _ in
                    NSWorkspace.shared.recycle([exportFile]) { _, error in
                        DispatchQueue.main.async {
                            button?.title = error == nil ? "Moved to Trash" : "Couldn't Move It"
                            button?.isEnabled = false
                            self?.needsLayout = true
                        }
                    }
                }
                addSubview(button)
                fixViews.append(button)
            }
        }
        superview?.needsLayout = true
        needsLayout = true
    }

    private func addFix(_ fix: ImportProblem.Fix) {
        let title: String
        switch fix {
        case .retry: title = "Try Again"
        case .fullDiskAccess: title = "Open Full Disk Access"
        case .exportFromApplePasswords: title = "Show Me How"
        case .primaryPassword: title = "Unlock"
        case .none: return
        }
        guard !fixViews.contains(where: { ($0 as? TextButton)?.title == title }) else { return }
        if fix == .primaryPassword {
            let field = FilledField(placeholder: "Primary password", secure: true)
            addSubview(field)
            fixViews.append(field)
            passwordField = field
        }
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.showsFillAtRest = true
        button.onClick = { [weak self] _ in
            guard let self else { return }
            self.onFix?(fix, self.passwordField?.stringValue ?? "")
            self.passwordField?.stringValue = ""
        }
        addSubview(button)
        fixViews.append(button)
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let side = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: pad, width: side, height: side)
        let textX = icon.frame.maxX + Tokens.Space.x3
        let textWidth = bounds.width - textX - pad - Tokens.Space.x8
        name.frame = NSRect(x: textX, y: pad, width: textWidth, height: name.lineHeight)
        let detailHeight = ceil(detail.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
        detail.preferredMaxLayoutWidth = textWidth
        detail.frame = NSRect(x: textX, y: name.frame.maxY + 2, width: textWidth, height: detailHeight)
        let indicator = NSRect(x: bounds.width - pad - Tokens.Space.x5, y: pad + (side - Tokens.Space.x5) / 2, width: Tokens.Space.x5, height: Tokens.Space.x5)
        check.frame = indicator
        spinner.frame = indicator.insetBy(dx: 2, dy: 2)
        var fx = textX
        let fy = detail.frame.maxY + Tokens.Space.x2
        for view in fixViews {
            let w: CGFloat = view is FilledField ? 180 : ((view as? TextButton)?.fittingWidth ?? 80)
            view.frame = NSRect(x: fx, y: fy, width: w, height: Tokens.Space.x8)
            fx += w + Tokens.Space.x2
        }
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isChosen ? Tokens.Color.fieldFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated)
        layer?.borderWidth = isChosen ? 1 : 0
        layer?.borderColor = cgColor(Brand.Theme.current.accent.withAlphaComponent(0.55))
    }
}

/// The import screen in its own window, from Settings and the command bar.
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ImportWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.title = "Import"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = Tokens.Color.formBackground
        let view = ImportView(presentation: .window)
        view.frame = window.contentLayoutRect
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = ImportWindowController(window: window)
        view.onClose = { [weak window] in window?.close() }
        window.delegate = controller
        view.frame.size.width = 560
        view.needsLayout = true
        // Laid out once tall, so the content's real height can be measured, then fitted.
        view.frame.size.height = 2000
        view.layoutSubtreeIfNeeded()
        let height = view.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max().map { $0 + Tokens.Space.x6 } ?? 560
        window.setContentSize(NSSize(width: 560, height: min(height, 780)))
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

/// The brand moment above the import: the wordmark on the lit surface on first launch, and the count of what
/// came over when it's done.
private final class ImportHero: NSView {
    static let height: CGFloat = 168
    private let surface = BrandSurface()
    private let wordmark = WordmarkView()
    private let count = Label("", font: .systemFont(ofSize: 60, weight: .heavy), color: Brand.ribbon)
    private let caption = Label("", font: .systemFont(ofSize: 17, weight: .semibold), color: Brand.ribbon)
    private let detail = Label("", font: Tokens.Font.body(), color: Brand.ribbon.withAlphaComponent(0.7))

    override init(frame: NSRect) {
        super.init(frame: frame)
        [surface, wordmark, count, caption, detail].forEach { addSubview($0) }
        [count, caption, detail].forEach { $0.isHidden = true }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var theme: Brand.Theme { Brand.Theme.current }

    private func applyTheme() {
        wordmark.color = theme.tint
        caption.textColor = theme.tint
        detail.textColor = theme.tint.withAlphaComponent(0.7)
    }

    func showWordmark(drawIn: Bool) {
        applyTheme()
        layoutSubtreeIfNeeded()
        // The one time the wordmark writes itself in: the very first time Zigzag opens.
        Brand.enter([surface])
        if drawIn {
            wordmark.drawIn(delay: 0.25)
            surface.watermark.drawIn(delay: 1.25)
        } else {
            Brand.enter([wordmark], delay: 0.04)
            surface.watermark.drawIn(delay: 0.2)
        }
    }

    func showSuccess(_ summaries: [ImportCoordinator.Summary]) {
        applyTheme()
        let passwords = summaries.map { $0.passwords + $0.updatedPasswords }.reduce(0, +)
        let bookmarks = summaries.map(\.bookmarks).reduce(0, +)
        let spaces = summaries.map(\.spaces).reduce(0, +)
        let history = summaries.map(\.history).reduce(0, +)
        let from = summaries.count == 1 ? " from \(summaries[0].source)" : ""
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        // The biggest thing that came over leads; the rest follow in a line.
        var lead: (Int, String)?
        var rest: [String] = []
        for (n, one, many) in [(passwords, "password", "passwords"), (bookmarks, "bookmark", "bookmarks"), (spaces, "space", "spaces"), (history, "page of history", "pages of history")] where n > 0 {
            if lead == nil { lead = (n, (n == 1 ? one : many) + from) } else { rest.append(plural(n, one, many)) }
        }
        wordmark.isHidden = true
        [count, caption, detail].forEach { $0.isHidden = false }
        if let lead {
            caption.stringValue = lead.1
            detail.stringValue = rest.isEmpty ? "All in. Nothing left behind." : "Plus " + ListFormatter.localizedString(byJoining: rest) + "."
            count.attributedStringValue = Brand.display(lead.0.formatted(), size: 60, color: theme.tint)
        } else {
            count.attributedStringValue = Brand.display("All set", size: 44, color: theme.tint)
            caption.stringValue = "Nothing new to bring over"
            detail.stringValue = "Everything was already here."
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The panel arrives, its lines a beat apart, then the ribbon writes itself across it.
        Brand.enter([surface, count, caption, detail])
        surface.watermark.drawIn(delay: 0.2)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let pad = Tokens.Space.x8
        let wordmarkHeight: CGFloat = 44
        wordmark.frame = NSRect(x: pad, y: (bounds.height - wordmarkHeight) / 2, width: wordmarkHeight * WordmarkView.aspect, height: wordmarkHeight)
        let countHeight = ceil(count.intrinsicContentSize.height)
        let textWidth = bounds.width * 0.62
        let total = countHeight + caption.lineHeight + 4 + detail.lineHeight
        var y = (bounds.height - total) / 2
        count.frame = NSRect(x: pad - 3, y: y, width: textWidth, height: countHeight)
        y = count.frame.maxY
        caption.frame = NSRect(x: pad, y: y, width: textWidth, height: caption.lineHeight)
        y = caption.frame.maxY + 4
        detail.frame = NSRect(x: pad, y: y, width: textWidth, height: detail.lineHeight)
    }
}
