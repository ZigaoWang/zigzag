import AppKit

/// Every saved password in one place: a sidebar of views (All, Weak, Reused, Never Saved), a searchable list, and
/// the chosen login's details. Locked until Touch ID (or the Mac's password); locks again when closed or when the
/// Mac sleeps. Passwords stay dots until revealed, and copies clear themselves from the clipboard.
final class PasswordsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: PasswordsWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Passwords"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 440)
        window.backgroundColor = Tokens.Color.formBackground
        // Passwords on screen stay out of screenshots and screen sharing.
        window.sharingType = .none
        let view = PasswordsView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = PasswordsWindowController(window: window)
        window.delegate = controller
        window.setFrameAutosaveName("Passwords")
        if !window.setFrameUsingName("Passwords") { window.center() }
        shared = controller
        controller.showWindow(nil)
        view.unlock()
    }

    func windowWillClose(_ notification: Notification) {
        PasswordAuthentication.lock()
        Self.shared = nil
    }
}

private enum Category: CaseIterable {
    case all, weak, reused, never

    var title: String {
        switch self {
        case .all: "All Passwords"
        case .weak: "Weak"
        case .reused: "Reused"
        case .never: "Never Saved"
        }
    }

    var symbol: String {
        switch self {
        case .all: "key.fill"
        case .weak: "exclamationmark.triangle.fill"
        case .reused: "arrow.triangle.2.circlepath"
        case .never: "nosign"
        }
    }
}

final class PasswordsView: NSView {
    private let locked = LockedView()
    private let sidebar = FlippedView()
    private let search = FilledField(placeholder: "Search")
    private var categoryRows: [CategoryRow] = []
    private let importButton = TextButton(title: "Import…", font: Tokens.Font.body(.medium))
    private let exportButton = TextButton(title: "Export…", font: Tokens.Font.body(.medium))
    private let listScroll = NSScrollView()
    private let list = FlippedView()
    private let listEdge = ColorView(color: Tokens.Color.separator)
    private let sidebarEdge = ColorView(color: Tokens.Color.separator)
    private let detail = DetailView()
    private let empty = EmptyStateView()

    private var credentials: [Credential] = []
    private var neverSites: [Origin] = []
    private var weak: Set<UUID> = []
    private var reused: Set<UUID> = []
    private var category = Category.all
    private var selection: UUID?
    private var selectedNever: Origin?
    private var rows: [ListRow] = []
    private var changeObserver: Any?
    private var sleepObservers: [Any] = []

    private let sidebarWidth: CGFloat = 200
    private let listWidth: CGFloat = 268

    override init(frame: NSRect) {
        super.init(frame: frame)
        [sidebar, listScroll, detail, empty, sidebarEdge, listEdge].forEach { addSubview($0) }
        addSubview(locked)
        sidebar.addSubview(search)
        for category in Category.allCases {
            let row = CategoryRow(category: category)
            row.onClick = { [weak self] _ in self?.choose(category) }
            sidebar.addSubview(row)
            categoryRows.append(row)
        }
        [importButton, exportButton].forEach { sidebar.addSubview($0) }
        importButton.onClick = { _ in ImportWindowController.show() }
        exportButton.onClick = { [weak self] _ in self?.export() }
        search.field.delegate = self
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.automaticallyAdjustsContentInsets = false
        listScroll.documentView = list
        listScroll.useSlimScroller()
        locked.onUnlock = { [weak self] in self?.unlock() }
        detail.onDeleted = { [weak self] in self?.reload() }
        detail.onAllowSaving = { [weak self] origin in
            Task { @MainActor in
                await PasswordStore.shared.setNeverSave(false, on: origin)
                self?.selectedNever = nil
                self?.reload()
            }
        }
        empty.onImport = { ImportWindowController.show() }
        changeObserver = NotificationCenter.default.addObserver(forName: PasswordStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if PasswordAuthentication.isUnlocked { self?.reload() } }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        setLocked(true)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: Locking

    func unlock() {
        Task { @MainActor in
            locked.isBusy = true
            let ok = await PasswordAuthentication.authenticate("see your saved passwords", keepUnlockedFor: 300)
            locked.isBusy = false
            guard ok else { locked.showFailure(); return }
            setLocked(false)
            reload()
            window?.makeFirstResponder(search.field)
        }
    }

    private func lock() {
        PasswordAuthentication.lock()
        detail.show(nil)
        setLocked(true)
    }

    private func setLocked(_ isLocked: Bool) {
        locked.isHidden = !isLocked
        [sidebar, listScroll, detail, empty, sidebarEdge, listEdge].forEach { $0.isHidden = isLocked }
        if !isLocked { updateEmpty() }
    }

    // MARK: Data

    private func reload() {
        Task { @MainActor in
            let store = PasswordStore.shared
            credentials = ((try? await store.all()) ?? []).sorted {
                ($0.origin.displayName, $0.username.lowercased()) < ($1.origin.displayName, $1.username.lowercased())
            }
            neverSites = await store.neverSaveSites().sorted { $0.displayName < $1.displayName }
            // Health is worked out from the passwords themselves, read once, then let go.
            var entries: [(id: UUID, origin: Origin, password: SecretString)] = []
            for credential in credentials {
                if let password = try? await store.password(for: credential.id) { entries.append((credential.id, credential.origin, password)) }
            }
            let snapshot = entries
            let checked = await Task.detached(priority: .userInitiated) {
                (Set(snapshot.filter { PasswordHealth.isWeak($0.password) }.map(\.id)), Set(PasswordHealth.reused(snapshot).flatMap { $0 }))
            }.value
            entries.removeAll()
            weak = checked.0
            reused = checked.1
            refreshCounts()
            rebuildList()
        }
    }

    private func refreshCounts() {
        for row in categoryRows {
            switch row.category {
            case .all: row.count = credentials.count
            case .weak: row.count = weak.count
            case .reused: row.count = reused.count
            case .never: row.count = neverSites.count
            }
            row.isSelected = row.category == category
        }
        exportButton.isEnabled = !credentials.isEmpty
    }

    private func choose(_ category: Category) {
        self.category = category
        selection = nil
        selectedNever = nil
        refreshCounts()
        rebuildList()
    }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    private var visibleCredentials: [Credential] {
        let base: [Credential]
        switch category {
        case .all, .never: base = credentials
        case .weak: base = credentials.filter { weak.contains($0.id) }
        case .reused: base = credentials.filter { reused.contains($0.id) }
        }
        guard !query.isEmpty else { return base }
        return base.filter { $0.origin.host.contains(query) || $0.username.lowercased().contains(query) || $0.title.lowercased().contains(query) }
    }

    private var visibleNever: [Origin] {
        query.isEmpty ? neverSites : neverSites.filter { $0.host.contains(query) }
    }

    private func rebuildList() {
        rows.forEach { $0.removeFromSuperview() }
        if category == .never {
            rows = visibleNever.map { origin in
                let row = ListRow(title: origin.displayName, subtitle: origin.scheme == "https" ? "Never offer to save" : origin.description, origin: origin)
                row.onClick = { [weak self] _ in self?.selectNever(origin) }
                return row
            }
            if selectedNever == nil || !visibleNever.contains(selectedNever!) { selectedNever = visibleNever.first }
        } else {
            let shown = visibleCredentials
            rows = shown.map { credential in
                let row = ListRow(title: credential.title.isEmpty ? credential.origin.displayName : credential.title,
                                  subtitle: credential.username.isEmpty ? "No username" : credential.username, origin: credential.origin)
                row.credentialID = credential.id
                row.onClick = { [weak self] _ in self?.select(credential.id) }
                return row
            }
            if selection == nil || !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
        }
        rows.forEach { list.addSubview($0) }
        needsLayout = true
        updateSelection()
        updateEmpty()
    }

    private func select(_ id: UUID) {
        selection = id
        updateSelection()
    }

    private func selectNever(_ origin: Origin) {
        selectedNever = origin
        updateSelection()
    }

    private func updateSelection() {
        if category == .never {
            rows.forEach { $0.isSelected = $0.origin == selectedNever }
            detail.showNever(selectedNever)
        } else {
            rows.forEach { $0.isSelected = $0.credentialID == selection }
            let credential = credentials.first { $0.id == selection }
            detail.show(credential, isWeak: credential.map { weak.contains($0.id) } ?? false, isReused: credential.map { reused.contains($0.id) } ?? false)
        }
    }

    private func updateEmpty() {
        let nothing = rows.isEmpty
        empty.isHidden = !nothing || !locked.isHidden
        detail.isHidden = nothing || !locked.isHidden
        listEdge.isHidden = nothing || !locked.isHidden
        guard nothing else { return }
        if !query.isEmpty {
            empty.set(symbol: "magnifyingglass", title: "No results for “\(search.stringValue)”", body: "Try a site or a username.", showsImport: false)
            return
        }
        switch category {
        case .all: empty.set(symbol: "key.fill", title: "No passwords yet", body: "Passwords you save while signing in, or bring over from another browser, appear here.", showsImport: true)
        case .weak: empty.set(symbol: "checkmark.shield.fill", title: "No weak passwords", body: "Every saved password is long and varied enough to stand up to guessing.", showsImport: false)
        case .reused: empty.set(symbol: "checkmark.shield.fill", title: "No reused passwords", body: "Each site has a password of its own.", showsImport: false)
        case .never: empty.set(symbol: "nosign", title: "No sites here", body: "Sites where you choose Never for This Site appear here, so you can change your mind.", showsImport: false)
        }
    }

    // MARK: Export

    private func export() {
        guard !credentials.isEmpty else { return }
        let count = credentials.count
        ConfirmSheet.show(in: self, title: "Export \(count) \(count == 1 ? "password" : "passwords")?",
                          message: "The file isn’t protected: anyone who opens it can read every password. Keep it somewhere safe and delete it when you’re done.",
                          confirmTitle: "Export…") { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task { @MainActor in
                // Always asked fresh, even while unlocked.
                guard await PasswordAuthentication.authenticate("export your passwords") else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Zigzag Passwords.csv"
                panel.allowedContentTypes = [.commaSeparatedText]
                guard let window = self.window, await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                do {
                    try await PasswordExport.write(self.credentials, to: url)
                    Toast.show("Exported \(count) \(count == 1 ? "password" : "passwords")", symbol: "square.and.arrow.up", duration: 2, over: self, area: self.detail.frame)
                } catch {
                    Toast.show("Couldn’t write the file. Choose another folder and try again.", symbol: "exclamationmark.triangle", duration: 3, over: self, area: self.detail.frame)
                }
            }
        }
    }

    #if DEBUG
    /// For the debug bridge: show a category, or the locked screen, without clicking.
    func debugShow(_ name: String) {
        switch name {
        case "lock": lock()
        case "reveal", "delete", "edit": detail.debugAction(name)
        default: if let category = Category.allCases.first(where: { "\($0)" == name }) { choose(category) }
        }
    }
    #endif

    // MARK: Layout

    override func layout() {
        super.layout()
        locked.frame = bounds
        let top: CGFloat = 52
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        sidebarEdge.frame = NSRect(x: sidebarWidth, y: 0, width: Tokens.Metric.hairline, height: bounds.height)
        let pad = Tokens.Space.x3
        search.frame = NSRect(x: pad, y: top, width: sidebarWidth - pad * 2, height: Tokens.Space.x8)
        var y = search.frame.maxY + Tokens.Space.x3
        for row in categoryRows {
            row.frame = NSRect(x: pad - Tokens.Space.x1, y: y, width: sidebarWidth - pad * 2 + Tokens.Space.x2, height: Tokens.Space.x8)
            y += Tokens.Space.x8 + 2
        }
        let buttonY = bounds.height - pad - Tokens.Space.x8
        importButton.frame = NSRect(x: pad - Tokens.Space.x2, y: buttonY, width: importButton.fittingWidth, height: Tokens.Space.x8)
        exportButton.frame = NSRect(x: importButton.frame.maxX + Tokens.Space.x1, y: buttonY, width: exportButton.fittingWidth, height: Tokens.Space.x8)

        let listX = sidebarWidth + Tokens.Metric.hairline
        listScroll.frame = NSRect(x: listX, y: top - Tokens.Space.x2, width: listWidth, height: bounds.height - top + Tokens.Space.x2)
        listEdge.frame = NSRect(x: listX + listWidth, y: 0, width: Tokens.Metric.hairline, height: bounds.height)
        let rowHeight = Tokens.Space.x12 + 2
        let rowWidth = listWidth - Tokens.Space.x4
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Tokens.Space.x2, y: Tokens.Space.x2 + CGFloat(index) * (rowHeight + 2), width: rowWidth, height: rowHeight)
        }
        list.frame = NSRect(x: 0, y: 0, width: listWidth, height: max(listScroll.contentSize.height, Tokens.Space.x4 + CGFloat(rows.count) * (rowHeight + 2)))
        let detailX = listX + listWidth + Tokens.Metric.hairline
        detail.frame = NSRect(x: detailX, y: 0, width: bounds.width - detailX, height: bounds.height)
        empty.frame = NSRect(x: listX, y: 0, width: bounds.width - listX, height: bounds.height)
    }
}

extension PasswordsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { rebuildList() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard rows.count > 0 else { return false }
        let ids = rows.compactMap(\.credentialID)
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard category != .never, !ids.isEmpty else { return false }
            let index = ids.firstIndex { $0 == selection } ?? -1
            let next = selector == #selector(NSResponder.moveDown(_:)) ? min(index + 1, ids.count - 1) : max(index - 1, 0)
            select(ids[next])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !search.stringValue.isEmpty else { return false }
            search.stringValue = ""
            rebuildList()
            return true
        default:
            return false
        }
    }
}

// MARK: - Locked

private final class LockedView: NSView {
    private let badge = NSImageView()
    private let title = Label("Your passwords are locked", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let body = Label("Unlock with Touch ID or your Mac’s password.", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private let button = PrimaryButton(title: "Unlock")
    var onUnlock: (() -> Void)?
    var isBusy = false { didSet { button.isEnabled = !isBusy } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.image = Tokens.Symbol.image("lock.fill", size: 28)
        badge.contentTintColor = Tokens.Color.accent
        title.alignment = .center
        body.alignment = .center
        [badge, title, body, button].forEach { addSubview($0) }
        button.onClick = { [weak self] _ in self?.onUnlock?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func showFailure() {
        body.stringValue = "Not unlocked. Try again when you’re ready."
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 40
        let total = side + Tokens.Space.x4 + title.lineHeight + Tokens.Space.x2 + body.lineHeight + Tokens.Space.x6 + Tokens.Space.x8
        var y = round((bounds.height - total) / 2)
        badge.frame = NSRect(x: round((bounds.width - side) / 2), y: y, width: side, height: side)
        y = badge.frame.maxY + Tokens.Space.x4
        title.frame = NSRect(x: 0, y: y, width: bounds.width, height: title.lineHeight)
        y = title.frame.maxY + Tokens.Space.x2
        body.frame = NSRect(x: 0, y: y, width: bounds.width, height: body.lineHeight)
        y = body.frame.maxY + Tokens.Space.x6
        let w = max(button.fittingWidth, 120)
        button.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Space.x8)
    }
}

// MARK: - Sidebar and list rows

private final class CategoryRow: InteractiveView {
    let category: Category
    private let icon = NSImageView()
    private let name: Label
    private let countLabel = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    var count = 0 { didSet { countLabel.stringValue = count > 0 ? "\(count)" : "" ; needsLayout = true } }

    init(category: Category) {
        self.category = category
        name = Label(category.title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        icon.image = Tokens.Symbol.image(category.symbol, size: Tokens.TypeSize.body)
        switch category {
        case .all: icon.contentTintColor = Tokens.Color.accent
        case .weak: icon.contentTintColor = .systemOrange
        case .reused: icon.contentTintColor = .systemYellow
        case .never: icon.contentTintColor = Tokens.Color.textSecondary
        }
        countLabel.alignment = .right
        [icon, name, countLabel].forEach { addSubview($0) }
        setAccessibilityRole(.button)
        setAccessibilityLabel(category.title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        icon.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - side) / 2, width: side, height: side)
        let cw = countLabel.textWidth
        countLabel.frame = NSRect(x: bounds.width - Tokens.Space.x2 - cw, y: (bounds.height - countLabel.lineHeight) / 2, width: cw, height: countLabel.lineHeight)
        let x = icon.frame.maxX + Tokens.Space.x2
        name.frame = NSRect(x: x, y: (bounds.height - name.lineHeight) / 2, width: countLabel.frame.minX - x, height: name.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isSelected ? Tokens.Color.selectedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

private final class ListRow: InteractiveView {
    let origin: Origin
    var credentialID: UUID?
    private let icon = NSImageView()
    private let title: Label
    private let subtitle: Label

    init(title: String, subtitle: String, origin: Origin) {
        self.origin = origin
        self.title = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        self.subtitle = Label(subtitle, font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control + 2
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = SiteIcon.image(for: origin)
        [icon, self.title, self.subtitle].forEach { addSubview($0) }
        if let url = origin.url, FaviconStore.shared.cachedIcon(for: url) == nil { FaviconStore.shared.prefetch(for: url) }
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(title), \(subtitle)")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x6
        icon.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - side) / 2, width: side, height: side)
        let x = icon.frame.maxX + Tokens.Space.x3
        let top = (bounds.height - title.lineHeight - subtitle.lineHeight) / 2
        title.frame = NSRect(x: x, y: top, width: bounds.width - x - Tokens.Space.x2, height: title.lineHeight)
        subtitle.frame = NSRect(x: x, y: title.frame.maxY, width: bounds.width - x - Tokens.Space.x2, height: subtitle.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isSelected ? Tokens.Color.selectedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// A site's favicon, or its first letter on a soft tile when there's none yet.
private enum SiteIcon {
    static func image(for origin: Origin) -> NSImage {
        if let url = origin.url, let icon = FaviconStore.shared.cachedIcon(for: url) { return icon }
        let letter = String(origin.displayName.first.map { String($0).uppercased() } ?? "?")
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            Tokens.Color.fieldFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: Tokens.Font.body(.semibold), .foregroundColor: Tokens.Color.textSecondary]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
    }
}

// MARK: - Empty

private final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let body = NSTextField(wrappingLabelWithString: "")
    private let importButton = PrimaryButton(title: "Import Passwords…")
    var onImport: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = Tokens.Color.textTertiary
        title.alignment = .center
        body.font = Tokens.Font.body()
        body.textColor = Tokens.Color.textSecondary
        body.alignment = .center
        body.isSelectable = false
        [icon, title, body, importButton].forEach { addSubview($0) }
        importButton.onClick = { [weak self] _ in self?.onImport?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func set(symbol: String, title: String, body: String, showsImport: Bool) {
        icon.image = Tokens.Symbol.image(symbol, size: 28)
        self.title.stringValue = title
        self.body.stringValue = body
        importButton.isHidden = !showsImport
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - Tokens.Space.x8 * 2, 340)
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width, height: 200)).height)
        let side: CGFloat = 36
        let total = side + Tokens.Space.x4 + title.lineHeight + Tokens.Space.x2 + bodyHeight + (importButton.isHidden ? 0 : Tokens.Space.x6 + Tokens.Space.x8)
        var y = round((bounds.height - total) / 2)
        let x = round((bounds.width - width) / 2)
        icon.frame = NSRect(x: round((bounds.width - side) / 2), y: y, width: side, height: side)
        y = icon.frame.maxY + Tokens.Space.x4
        title.frame = NSRect(x: x, y: y, width: width, height: title.lineHeight)
        y = title.frame.maxY + Tokens.Space.x2
        body.frame = NSRect(x: x, y: y, width: width, height: bodyHeight)
        y = body.frame.maxY + Tokens.Space.x6
        let w = importButton.fittingWidth
        importButton.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Space.x8)
    }
}

// MARK: - Detail

private final class DetailView: NSView {
    private let icon = NSImageView()
    private let title = Label("", font: .systemFont(ofSize: 22, weight: .semibold), color: Tokens.Color.textPrimary)
    private let subtitle = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let warning = WarningBanner()
    private let card = ColorView(color: Tokens.Color.formGroup)
    private let usernameRow = FieldRow(name: "Username")
    private let passwordRow = FieldRow(name: "Password")
    private let websiteRow = FieldRow(name: "Website")
    private let notesRow = FieldRow(name: "Notes")
    private let editButton = TextButton(title: "Edit", font: Tokens.Font.body(.medium))
    private let deleteButton = TextButton(title: "Delete", font: Tokens.Font.body(.medium))
    private let saveButton = PrimaryButton(title: "Save")
    private let cancelButton = TextButton(title: "Cancel", font: Tokens.Font.body(.medium))
    private let usernameField = FilledField(placeholder: "Username")
    private let passwordField = FilledField(placeholder: "Password")
    private let notesField = FilledField(placeholder: "Notes")
    private let neverBody = NSTextField(wrappingLabelWithString: "")
    private let allowButton = PrimaryButton(title: "Allow Saving")

    private var credential: Credential?
    private var neverOrigin: Origin?
    private var revealed: SecretString?
    private var isEditing = false
    var onDeleted: (() -> Void)?
    var onAllowSaving: ((Origin) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = Tokens.Radius.panel - 2
        card.layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        neverBody.font = Tokens.Font.body()
        neverBody.textColor = Tokens.Color.textSecondary
        neverBody.isSelectable = false
        [icon, title, subtitle, warning, card, editButton, deleteButton, saveButton, cancelButton, neverBody, allowButton].forEach { addSubview($0) }
        [usernameRow, passwordRow, websiteRow, notesRow].forEach { card.addSubview($0) }
        editButton.showsFillAtRest = true
        deleteButton.showsFillAtRest = true
        deleteButton.textColor = .systemRed
        passwordField.field.font = .monospacedSystemFont(ofSize: Tokens.TypeSize.body, weight: .regular)

        usernameRow.actions = [("doc.on.doc", "Copy Username", { [weak self] in self?.copyUsername() })]
        passwordRow.actions = [("eye", "Show Password", { [weak self] in self?.toggleReveal() }),
                               ("doc.on.doc", "Copy Password", { [weak self] in self?.copyPassword() })]
        websiteRow.actions = [("arrow.up.forward.app", "Open Website", { [weak self] in self?.openWebsite() })]
        editButton.onClick = { [weak self] _ in self?.beginEditing() }
        cancelButton.onClick = { [weak self] _ in self?.endEditing() }
        saveButton.onClick = { [weak self] _ in self?.saveEdits() }
        deleteButton.onClick = { [weak self] _ in self?.delete() }
        allowButton.onClick = { [weak self] _ in if let origin = self?.neverOrigin { self?.onAllowSaving?(origin) } }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(_ credential: Credential?, isWeak: Bool = false, isReused: Bool = false) {
        if credential?.id != self.credential?.id { revealed = nil; if isEditing { endEditing() } }
        self.credential = credential
        neverOrigin = nil
        guard let credential else { subviews.forEach { $0.isHidden = true }; return }
        subviews.forEach { $0.isHidden = false }
        [neverBody, allowButton].forEach { $0.isHidden = true }
        icon.image = SiteIcon.image(for: credential.origin)
        title.stringValue = credential.title.isEmpty ? credential.origin.displayName : credential.title
        subtitle.stringValue = "Last changed " + credential.modified.formatted(date: .abbreviated, time: .omitted)
        usernameRow.value = credential.username.isEmpty ? "No username" : credential.username
        usernameRow.isPlaceholder = credential.username.isEmpty
        usernameRow.showsActions = !credential.username.isEmpty
        updatePasswordRow()
        websiteRow.value = credential.origin.description
        notesRow.value = credential.notes
        notesRow.isHidden = credential.notes.isEmpty
        if isReused {
            warning.set("This password is used on other sites. If one of them leaks, this account is at risk too. Change it on the site, then update it here.", color: .systemYellow)
        } else if isWeak {
            warning.set("This password is easy to guess. Change it on the site, and use a strong password Zigzag makes for you.", color: .systemOrange)
        }
        warning.isHidden = !(isWeak || isReused)
        applyEditing()
        needsLayout = true
    }

    func showNever(_ origin: Origin?) {
        credential = nil
        revealed = nil
        neverOrigin = origin
        subviews.forEach { $0.isHidden = true }
        guard let origin else { return }
        [icon, title, subtitle, neverBody, allowButton].forEach { $0.isHidden = false }
        icon.image = SiteIcon.image(for: origin)
        title.stringValue = origin.displayName
        subtitle.stringValue = origin.description
        neverBody.stringValue = "Zigzag won’t offer to save passwords on this site. Allow it, and the next time you sign in there you’ll be asked again."
        needsLayout = true
    }

    private func updatePasswordRow() {
        if let revealed {
            passwordRow.value = revealed.withUnsafeString { $0 }
            passwordRow.isMonospaced = true
            passwordRow.actions[0].symbol = "eye.slash"
        } else {
            passwordRow.value = String(repeating: "•", count: 12)
            passwordRow.isMonospaced = false
            passwordRow.actions[0].symbol = "eye"
        }
    }

    #if DEBUG
    func debugAction(_ name: String) {
        switch name {
        case "reveal": toggleReveal()
        case "delete": delete()
        case "edit": beginEditing()
        default: break
        }
    }
    #endif

    // MARK: Actions

    private func password() async -> SecretString? {
        guard let credential, await PasswordAuthentication.authenticate("show your password for \(credential.origin.displayName)", keepUnlockedFor: 300) else { return nil }
        return try? await PasswordStore.shared.password(for: credential.id)
    }

    private func toggleReveal() {
        if revealed != nil { revealed = nil; updatePasswordRow(); return }
        Task { @MainActor in
            revealed = await password()
            updatePasswordRow()
        }
    }

    private func copyUsername() {
        guard let credential else { return }
        Clipboard.copy(credential.username, concealed: false)
        toast("Username copied")
    }

    private func copyPassword() {
        Task { @MainActor in
            guard let secret = await password() else { return }
            secret.withUnsafeString { Clipboard.copy($0, concealed: true) }
            toast("Password copied. It leaves the clipboard in 90 seconds.")
        }
    }

    private func openWebsite() {
        guard let url = credential?.origin.url else { return }
        WindowManager.shared.openExternal(url)
    }

    private func delete() {
        guard let credential else { return }
        Task { @MainActor in
            let store = PasswordStore.shared
            // Kept in memory only, so Undo can put it back.
            let kept = try? await store.password(for: credential.id)
            do { try await store.delete(credential.id) } catch {
                toast("Couldn’t delete it. Try again.")
                return
            }
            onDeleted?()
            guard let host = superview else { return }
            Toast.show("Deleted \(credential.origin.displayName)", symbol: "trash", action: ("Undo", {
                guard let kept else { return }
                Task {
                    _ = try? await store.save(origin: credential.origin, username: credential.username, password: kept, title: credential.title.isEmpty ? nil : credential.title,
                                              notes: credential.notes, otpAuth: credential.otpAuth, created: credential.created)
                }
            }), duration: 6, over: host, area: frame)
        }
    }

    private func beginEditing() {
        guard let credential else { return }
        Task { @MainActor in
            guard let secret = await password() else { return }
            usernameField.stringValue = credential.username
            passwordField.stringValue = secret.withUnsafeString { $0 }
            notesField.stringValue = credential.notes
            isEditing = true
            applyEditing()
            window?.makeFirstResponder(usernameField.field)
        }
    }

    private func endEditing() {
        isEditing = false
        passwordField.stringValue = ""
        applyEditing()
    }

    private func saveEdits() {
        guard var edited = credential else { return }
        let newPassword = SecretString(passwordField.stringValue)
        guard !newPassword.isEmpty else { toast("A password can’t be empty."); return }
        edited.username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.notes = notesField.stringValue
        Task { @MainActor in
            do {
                try await PasswordStore.shared.update(edited, password: newPassword)
                revealed = nil
                endEditing()
                toast("Saved")
            } catch {
                toast("Couldn’t save the changes. Try again.")
            }
        }
    }

    private func applyEditing() {
        let editing = isEditing && credential != nil
        usernameRow.editor = editing ? usernameField : nil
        passwordRow.editor = editing ? passwordField : nil
        notesRow.editor = editing ? notesField : nil
        websiteRow.isHidden = false
        notesRow.isHidden = !editing && (credential?.notes.isEmpty ?? true)
        editButton.isHidden = editing || credential == nil
        deleteButton.isHidden = editing || credential == nil
        saveButton.isHidden = !editing
        cancelButton.isHidden = !editing
        needsLayout = true
    }

    private func toast(_ text: String) {
        guard let host = superview else { return }
        Toast.show(text, duration: 2, over: host, area: frame)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x6
        let width = min(bounds.width - pad * 2, 520)
        let x = pad
        var y: CGFloat = 52 + Tokens.Space.x2
        let side: CGFloat = 44
        icon.frame = NSRect(x: x, y: y, width: side, height: side)
        let textX = icon.frame.maxX + Tokens.Space.x4
        title.frame = NSRect(x: textX, y: y + (side - title.lineHeight - subtitle.lineHeight) / 2, width: width - (textX - x), height: title.lineHeight)
        subtitle.frame = NSRect(x: textX, y: title.frame.maxY, width: width - (textX - x), height: subtitle.lineHeight)
        y = icon.frame.maxY + Tokens.Space.x6

        if neverOrigin != nil {
            let h = ceil(neverBody.sizeThatFits(NSSize(width: width, height: 200)).height)
            neverBody.frame = NSRect(x: x, y: y, width: width, height: h)
            y = neverBody.frame.maxY + Tokens.Space.x5
            allowButton.frame = NSRect(x: x, y: y, width: allowButton.fittingWidth, height: Tokens.Space.x8)
            return
        }
        if !warning.isHidden {
            let h = warning.height(for: width)
            warning.frame = NSRect(x: x, y: y, width: width, height: h)
            y = warning.frame.maxY + Tokens.Space.x4
        }
        let rowHeight = Tokens.Space.x12
        var cy: CGFloat = 0
        for view in [usernameRow, passwordRow, websiteRow, notesRow] where !view.isHidden {
            view.frame = NSRect(x: 0, y: cy, width: width, height: rowHeight)
            cy += rowHeight
        }
        card.frame = NSRect(x: x, y: y, width: width, height: cy)
        card.layer?.borderWidth = Tokens.Metric.hairline
        card.layer?.borderColor = card.cgColor(Tokens.Color.formGroupEdge)
        y = card.frame.maxY + Tokens.Space.x5
        let h = Tokens.Space.x8
        if isEditing {
            let sw = max(saveButton.fittingWidth, 80)
            saveButton.frame = NSRect(x: x + width - sw, y: y, width: sw, height: h)
            cancelButton.frame = NSRect(x: saveButton.frame.minX - Tokens.Space.x2 - cancelButton.fittingWidth, y: y, width: cancelButton.fittingWidth, height: h)
        } else {
            editButton.frame = NSRect(x: x, y: y, width: max(editButton.fittingWidth, 64), height: h)
            deleteButton.frame = NSRect(x: editButton.frame.maxX + Tokens.Space.x2, y: y, width: max(deleteButton.fittingWidth, 64), height: h)
        }
    }
}

/// One line of the detail card: a name on the left, the value, and small icon buttons on the right.
private final class FieldRow: NSView {
    private let nameLabel: Label
    private let valueLabel = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private var buttons: [IconButton] = []
    private let line = ColorView(color: Tokens.Color.separator)

    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }
    var isPlaceholder = false { didSet { valueLabel.textColor = isPlaceholder ? Tokens.Color.textTertiary : Tokens.Color.textPrimary } }
    var isMonospaced = false {
        didSet { valueLabel.font = isMonospaced ? .monospacedSystemFont(ofSize: Tokens.TypeSize.body - 1, weight: .regular) : Tokens.Font.body() }
    }
    var showsActions = true { didSet { buttons.forEach { $0.isHidden = !showsActions || editor != nil } } }
    /// While editing, a field takes the value's place; the name stays.
    var editor: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let editor { addSubview(editor) }
            valueLabel.isHidden = editor != nil
            buttons.forEach { $0.isHidden = !showsActions || editor != nil }
            needsLayout = true
        }
    }
    var actions: [(symbol: String, tip: String, run: () -> Void)] = [] {
        didSet {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.map { action in
                let button = IconButton(symbol: action.symbol, size: (Tokens.Space.x6 + Tokens.Space.x1), toolTip: action.tip)
                button.onClick = { _ in action.run() }
                addSubview(button)
                return button
            }
            needsLayout = true
        }
    }

    init(name: String) {
        nameLabel = Label(name, font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        valueLabel.isSelectable = false
        [nameLabel, valueLabel, line].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x4
        let nameWidth: CGFloat = 80
        nameLabel.frame = NSRect(x: pad, y: (bounds.height - nameLabel.lineHeight) / 2, width: nameWidth, height: nameLabel.lineHeight)
        var right = bounds.width - Tokens.Space.x2
        for button in buttons.reversed() where !button.isHidden {
            let side = (Tokens.Space.x6 + Tokens.Space.x1)
            button.frame = NSRect(x: right - side, y: (bounds.height - side) / 2, width: side, height: side)
            right = button.frame.minX - 2
        }
        let x = nameLabel.frame.maxX + Tokens.Space.x2
        if let editor {
            editor.frame = NSRect(x: x - Tokens.Space.x2, y: (bounds.height - Tokens.Space.x8) / 2, width: bounds.width - x - Tokens.Space.x2, height: Tokens.Space.x8)
        }
        valueLabel.frame = NSRect(x: x, y: (bounds.height - valueLabel.lineHeight) / 2, width: right - x - Tokens.Space.x2, height: valueLabel.lineHeight)
        line.frame = NSRect(x: pad, y: bounds.height - Tokens.Metric.hairline, width: bounds.width - pad, height: Tokens.Metric.hairline)
        line.isHidden = superview?.subviews.last(where: { !$0.isHidden && $0.frame.maxY > frame.maxY }) == nil
    }
}

private final class WarningBanner: NSView {
    private let icon = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var color = NSColor.systemOrange

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.panel - 2
        layer?.cornerCurve = .continuous
        icon.image = Tokens.Symbol.image("exclamationmark.triangle.fill", size: Tokens.TypeSize.body)
        text.font = Tokens.Font.body()
        text.textColor = Tokens.Color.textPrimary
        text.isSelectable = false
        [icon, text].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func set(_ message: String, color: NSColor) {
        text.stringValue = message
        self.color = color
        icon.contentTintColor = color
        updateColors()
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil(text.sizeThatFits(NSSize(width: width - Tokens.Space.x12, height: 400)).height) + Tokens.Space.x3 * 2
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        let side = Tokens.Space.x4
        icon.frame = NSRect(x: Tokens.Space.x3, y: Tokens.Space.x3 + 1, width: side, height: side)
        let x = icon.frame.maxX + Tokens.Space.x3
        text.frame = NSRect(x: x, y: Tokens.Space.x3, width: bounds.width - x - Tokens.Space.x3, height: bounds.height - Tokens.Space.x3 * 2)
    }
}

// MARK: - Clipboard and export

enum Clipboard {
    private static var clearWork: DispatchWorkItem?

    /// Copies text. A concealed copy is marked so clipboard managers skip it, and is cleared after 90 seconds if
    /// it's still what's on the clipboard.
    static func copy(_ text: String, concealed: Bool) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        clearWork?.cancel()
        guard concealed else { return }
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = board.changeCount
        let work = DispatchWorkItem { if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() } }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }
}

enum PasswordExport {
    /// The CSV every browser and password manager imports: name, url, username, password, note.
    static func write(_ credentials: [Credential], to url: URL) async throws {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var data = Data("name,url,username,password,note\n".utf8)
        defer { data.resetBytes(in: 0..<data.count) }
        for credential in credentials {
            guard let password = try? await PasswordStore.shared.password(for: credential.id) else { continue }
            let line = password.withUnsafeString { secret in
                [credential.title.isEmpty ? credential.origin.displayName : credential.title, credential.origin.description, credential.username, secret, credential.notes]
                    .map(field).joined(separator: ",") + "\n"
            }
            data.append(Data(line.utf8))
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
