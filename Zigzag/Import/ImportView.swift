import AppKit
import UniformTypeIdentifiers

/// "Bring your stuff from another browser." Shown in the empty page on first launch, and in its own window
/// from Settings and the command bar. Pick browsers, pick what to bring, import; then a plain summary, and a
/// one-click fix for anything that couldn't come over.
final class ImportView: NSView {
    var onClose: (() -> Void)?

    private enum Stage { case choose, importing, done }
    private var stage = Stage.choose

    private let title = Label("Bring your stuff from another browser", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let subtitle = NSTextField(wrappingLabelWithString: "Passwords, bookmarks and history come over in one go. Your other browser stays exactly as it is.")
    private var sources: [ImportCoordinator.Source] = []
    private var rows: [SourceRow] = []
    private let choiceLabel = Label("Bring", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private var choiceButtons: [(ImportCoordinator.Choice, NSButton)] = []
    private let chooseFile = TextButton(title: "Choose a File…", font: Tokens.Font.body(.medium))
    private let primary = PrimaryButton(title: "Import")
    private let secondary = TextButton(title: "Not Now", font: Tokens.Font.body(.medium))
    private let emptyNote = NSTextField(wrappingLabelWithString: "No other browsers with data were found on this Mac. You can still bring passwords from a CSV export.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        subtitle.font = Tokens.Font.body()
        subtitle.textColor = Tokens.Color.textSecondary
        subtitle.isSelectable = false
        emptyNote.font = Tokens.Font.body()
        emptyNote.textColor = Tokens.Color.textSecondary
        emptyNote.isSelectable = false
        [title, subtitle, choiceLabel, chooseFile, primary, secondary].forEach { addSubview($0) }
        for (choice, name) in [(ImportCoordinator.Choice.passwords, "Passwords"), (.bookmarks, "Bookmarks"), (.history, "History"), (.tabs, "Spaces & pinned tabs")] {
            let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(choicesChanged))
            box.state = .on
            box.font = Tokens.Font.body()
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
        choiceButtons.reduce(into: []) { result, pair in if pair.1.state == .on, !pair.1.isHidden { result.insert(pair.0) } }
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
        title.stringValue = "Bringing your stuff over…"
        subtitle.stringValue = "macOS may ask to let Zigzag open a browser's saved passwords. Choose Allow."
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
        row.state = .done(summary)
        row.onFix = { [weak self, weak row] fix, password in
            guard let self, let row else { return }
            self.fix(fix, for: row, data: data, primaryPassword: password)
        }
        needsLayout = true
    }

    private func finish() {
        stage = .done
        title.stringValue = "You're all set"
        subtitle.stringValue = "Your passwords are in the Keychain and sync with iCloud Keychain. Open them anytime from Settings › Passwords."
        primary.title = "Done"
        primary.isEnabled = true
        needsLayout = true
    }

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
            row.onFinishedFile = { [weak self] in self?.offerToTrash(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// An export holds passwords in plain text; leaving it in Downloads is the risk.
    private func offerToTrash(_ file: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(file.lastPathComponent) to the Trash?"
        alert.informativeText = "The export holds your passwords unprotected. Now that they're in Zigzag, it's safer not to keep it."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.recycle([file]) }
        }
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
        let choicesHeight: CGFloat = showsChoices ? Tokens.Space.x4 + Tokens.Space.x2 + Tokens.Space.x6 : 0
        let emptyHeight: CGFloat = sources.isEmpty && stage == .choose ? ceil(emptyNote.sizeThatFits(NSSize(width: width, height: 200)).height) + Tokens.Space.x4 : 0
        let total = title.lineHeight + Tokens.Space.x2 + subtitleHeight + Tokens.Space.x6 + rowsHeight + emptyHeight
            + (showsChoices ? Tokens.Space.x6 + choicesHeight : 0) + Tokens.Space.x8 + Tokens.Space.x8
        y = max(Tokens.Space.x8, round((bounds.height - total) / 2))
        title.alignment = .left
        place(title, height: title.lineHeight, gap: Tokens.Space.x2)
        place(subtitle, height: subtitleHeight, gap: Tokens.Space.x6)
        if emptyHeight > 0 { place(emptyNote, height: emptyHeight - Tokens.Space.x4, gap: Tokens.Space.x4) }
        for row in visibleRows { place(row, height: row.preferredHeight, gap: Tokens.Space.x2) }
        if showsChoices {
            y += Tokens.Space.x4
            choiceLabel.isHidden = false
            place(choiceLabel, height: choiceLabel.lineHeight, gap: Tokens.Space.x2)
            var cx = x
            for (_, box) in choiceButtons where !box.isHidden {
                let w = ceil(box.fittingSize.width)
                box.frame = NSRect(x: cx, y: y, width: w, height: Tokens.Space.x6)
                cx += w + Tokens.Space.x4
            }
            y += Tokens.Space.x6
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
    var onFinishedFile: (() -> Void)?

    var isChosen = false { didSet { stateDidChange(animated: true); refresh() } }
    var state = State.idle { didSet { refresh() } }

    private let icon = NSImageView()
    private let name: Label
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let spinner = NSProgressIndicator()
    private var fixViews: [NSView] = []
    private var passwordField: NSSecureTextField?
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
        spinner.style = .spinning
        spinner.controlSize = .small
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
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        check.isHidden = true
        switch state {
        case .idle:
            detail.stringValue = preview
            check.isHidden = !isChosen
            check.image = Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.large)
            check.contentTintColor = Tokens.Color.accent
        case .waiting:
            detail.stringValue = "Waiting…"
        case .working:
            detail.stringValue = "Bringing it over…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .done(let summary):
            detail.stringValue = ([summary.sentence] + summary.problems.map(\.message)).joined(separator: "\n")
            check.isHidden = false
            let clean = summary.problems.isEmpty
            check.image = Tokens.Symbol.image(clean ? "checkmark.circle.fill" : "exclamationmark.circle.fill", size: Tokens.TypeSize.large)
            check.contentTintColor = clean ? .systemGreen : .systemOrange
            for problem in summary.problems { addFix(problem.fix) }
            if case .file = source.kind, summary.passwords + summary.updatedPasswords > 0 { onFinishedFile?() }
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
            let field = NSSecureTextField()
            field.placeholderString = "Primary password"
            field.controlSize = .regular
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
            let w: CGFloat = view is NSSecureTextField ? 180 : ((view as? TextButton)?.fittingWidth ?? 80)
            view.frame = NSRect(x: fx, y: fy, width: w, height: Tokens.Space.x8)
            fx += w + Tokens.Space.x2
        }
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isChosen ? Tokens.Color.fieldFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated)
        layer?.borderWidth = isChosen ? 1 : 0
        layer?.borderColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.5))
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
        let view = ImportView(frame: window.contentLayoutRect)
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
        let height = view.subviews.map(\.frame.maxY).max().map { $0 + Tokens.Space.x8 } ?? 560
        window.setContentSize(NSSize(width: 560, height: min(height - (view.subviews.map(\.frame.minY).min() ?? 0) + Tokens.Space.x10, 760)))
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}
