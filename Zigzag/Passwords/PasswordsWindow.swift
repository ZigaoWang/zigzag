import AppKit

/// Every saved password in one place, laid out as Zigzag's pages are (`Tokens.Page`), a sibling of Settings and
/// History: the wordmark and "Passwords" over a column of kinds (All, Weak, Reused, Never Saved) at the left; the
/// chosen kind's name, the search and Import and Export across the top; the sites under it; the chosen login's
/// details at the right. Locked until Touch ID (or the Mac's password); locks again when the Mac sleeps. Passwords
/// stay dots until revealed, and copies clear themselves from the clipboard.
final class PasswordsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: PasswordsWindowController?

    /// Opens the window, searching for `query` when given (a site whose sign-in had no saved password).
    static func show(searching query: String? = nil) {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            if let query { (shared.window?.contentView as? PasswordsView)?.search(for: query) }
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = String(localized: "Passwords", comment: "Title of the Passwords window.")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 480)
        window.backgroundColor = Tokens.Color.surface
        // Passwords on screen stay out of screenshots and screen sharing (a debug copy on its own test vault aside,
        // so its layout can be checked).
        window.sharingType = PasswordStore.isTestVault ? .readOnly : .none
        let view = PasswordsView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = PasswordsWindowController(window: window)
        window.delegate = controller
        window.setFrameAutosaveName("Passwords")
        if !window.setFrameUsingName("Passwords") { window.center() }
        shared = controller
        controller.showWindow(nil)
        if let query { view.search(for: query) }
        view.unlock()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing doesn't lock: reopening soon after shouldn't ask again. Sleep, screen lock or time does.
        Self.shared = nil
    }
}

private enum Category: CaseIterable {
    case all, weak, reused, never

    var title: String {
        switch self {
        case .all: String(localized: "All Passwords", comment: "A kind of password in the Passwords window's column, and the list's title: every saved password.")
        case .weak: String(localized: "Weak", comment: "A kind of password in the Passwords window's column: easy to guess.")
        case .reused: String(localized: "Reused", comment: "A kind of password in the Passwords window's column: used on more than one site.")
        case .never: String(localized: "Never Saved", comment: "A kind of entry in the Passwords window's column: sites where the person chose never to save a password.")
        }
    }

    var symbol: String {
        switch self {
        case .all: "key"
        case .weak: "exclamationmark.triangle"
        case .reused: "arrow.triangle.2.circlepath"
        case .never: "nosign"
        }
    }
}

/// A kind of password in the column, with how many there are.
private final class CategoryItem: ListItem {
    let category: Category

    init(_ category: Category) {
        self.category = category
        super.init(title: category.title, symbol: category.symbol)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class PasswordsView: NSView {
    private let column = FlippedView()
    private let columnTitle = PageTitleView(String(localized: "Passwords", comment: "Title over the column of kinds in the Passwords window."))
    private let columnEdge = ColorView(color: Tokens.Color.separator)
    private var items: [CategoryItem] = []
    private let header = PageHeader()
    private let paneTitle = PageTitleView(String(localized: "All Passwords", comment: "A kind of password in the Passwords window's column, and the list's title: every saved password."))
    private let search = FilledField.search(String(localized: "Search sites and usernames", comment: "Placeholder of the search field in the Passwords window."))
    private let importButton = PillButton(title: String(localized: "Import…", comment: "Button in the Passwords window that imports passwords."), symbol: "square.and.arrow.down", style: .plain)
    private let exportButton = PillButton(title: String(localized: "Export", comment: "Button in the Passwords window that exports passwords to a file."), symbol: "square.and.arrow.up", style: .plain)
    private let listScroll = NSScrollView()
    private let list = FlippedView()
    private let listEdge = ColorView(color: Tokens.Color.separator)
    private let detail = DetailView()
    private let empty = PageEmptyView()
    private let locked = PageEmptyView()

    private var credentials: [Credential] = []
    private var neverSites: [Origin] = []
    private var weak: Set<UUID> = []
    private var reused: Set<UUID> = []
    private var category = Category.all
    private var selection: UUID?
    private var selectedNever: Origin?
    private var rows: [SiteRow] = []
    private var changeObserver: Any?
    private var sleepObservers: [Any] = []
    private var isLocked = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        items = Category.allCases.map { category in
            let item = CategoryItem(category)
            item.onClick = { [weak self] _ in self?.choose(category) }
            return item
        }
        ([columnTitle] + items as [NSView]).forEach { column.addSubview($0) }
        [column, columnEdge, header, listScroll, listEdge, detail, empty, locked].forEach { addSubview($0) }
        header.leading = paneTitle
        header.trailing = [search, importButton, exportButton]
        importButton.toolTip = String(localized: "Import passwords from another browser or a file", comment: "Tooltip of the Import button in the Passwords window.")
        exportButton.toolTip = String(localized: "Export passwords to a file", comment: "Tooltip of the Export button in the Passwords window.")
        importButton.onClick = { _ in ImportWindowController.show() }
        exportButton.onClick = { [weak self] _ in self?.export() }
        search.field.delegate = self
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.automaticallyAdjustsContentInsets = false
        listScroll.documentView = list
        listScroll.useSlimScroller()
        listScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: listScroll.contentView)
        let unlockButton = PillButton(title: String(localized: "Unlock", comment: "Button in the locked Passwords window: unlocks with Touch ID or the Mac's password."), symbol: "lock.open", style: .prominent)
        unlockButton.onClick = { [weak self] _ in self?.unlock() }
        locked.action = unlockButton
        importPasswords.onClick = { _ in ImportWindowController.show() }
        tryAgain.onClick = { [weak self] _ in
            guard let self else { return }
            self.isLoadingVault = true
            self.updateEmpty()
            self.reload()
        }
        empty.action = importPasswords
        detail.onDeleted = { [weak self] in self?.reload() }
        detail.onAllowSaving = { [weak self] origin in
            Task { @MainActor in
                await PasswordStore.shared.setNeverSave(false, on: origin)
                self?.selectedNever = nil
                self?.reload()
            }
        }
        changeObserver = NotificationCenter.default.addObserver(forName: PasswordStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if PasswordAuthentication.isUnlocked { self?.reload() } }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        // Still unlocked from a moment ago: straight to the passwords, no locked screen in between.
        setLocked(!PasswordAuthentication.isUnlocked)
        refreshCounts()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cgColor(Tokens.Color.surface)
        // The column of kinds in its window's theme, the same one its wordmark takes: a light tint of the space when
        // it's shown in a browser window, the plain form gray in a window of its own.
        column.wantsLayer = true
        column.layer?.backgroundColor = cgColor(Brand.Theme.for(self).wash)
    }
    private lazy var themeToken: SignalToken = Brand.themeChanged.observe { [weak self] in self?.needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = themeToken
        needsDisplay = true
    }

    isolated deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func listScrolled() { header.showsEdge = listScroll.contentView.bounds.minY > 0 }

    // MARK: Locking

    func unlock() {
        Task { @MainActor in
            locked.action?.isEnabled = false
            locked.text = Self.lockedPrompt
            let ok = await PasswordAuthentication.authenticate(String(localized: "see your saved passwords", comment: "Why Touch ID is asked for, finishing the sentence macOS starts with “Zigzag is trying to”."), keepUnlockedFor: PasswordAuthentication.unlockDuration)
            locked.action?.isEnabled = true
            guard ok else { locked.text = String(localized: "Not unlocked. Try again when you’re ready.", comment: "Shown in the locked Passwords window after Touch ID was cancelled or failed."); return }
            setLocked(false)
            reload()
        }
    }

    private static let lockedPrompt = String(localized: "Your passwords are locked. Unlock with Touch ID or your Mac’s password.", comment: "Shown in the locked Passwords window.")

    private func lock() {
        PasswordAuthentication.lock()
        detail.show(nil)
        setLocked(true)
    }

    /// True from unlocking until the vault is read, so an empty state never flashes before the list arrives.
    private var isLoadingVault = false
    /// The keychain wouldn't give up the list: say so, rather than look like there are no passwords at all.
    private var readFailed = false
    private let importPasswords = PillButton(title: String(localized: "Import Passwords…", comment: "Button in the empty Passwords window."), style: .prominent)
    private let tryAgain = PillButton(title: String(localized: "Try Again", comment: "Button in the Passwords window after the passwords couldn't be read."), style: .prominent)

    private func setLocked(_ isLocked: Bool) {
        self.isLocked = isLocked
        locked.text = Self.lockedPrompt
        locked.isHidden = !isLocked
        // Locked, the page is just its title and the way in: no kinds, no counts, no search.
        ([columnEdge, header, listScroll, listEdge, detail, empty] + items as [NSView]).forEach { $0.isHidden = isLocked }
        if isLocked {
            locked.appear()
        } else {
            isLoadingVault = true
            updateEmpty()
        }
        needsLayout = true
    }

    // MARK: Data

    private func reload() {
        Task { @MainActor in
            let store = PasswordStore.shared
            let all: [Credential]
            do { all = try await store.all(); readFailed = false } catch { all = []; readFailed = true }
            credentials = all.sorted {
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
            isLoadingVault = false
            refreshCounts()
            rebuildList()
        }
    }

    private func refreshCounts() {
        for item in items {
            let n: Int
            switch item.category {
            case .all: n = credentials.count
            case .weak: n = weak.count
            case .reused: n = reused.count
            case .never: n = neverSites.count
            }
            item.detail = n == 0 ? "" : n.formatted()
            item.isSelected = item.category == category
        }
        paneTitle.title = category.title
        exportButton.isEnabled = !credentials.isEmpty
        header.needsLayout = true
    }

    private func choose(_ category: Category) {
        guard category != self.category else { return }
        self.category = category
        selection = nil
        selectedNever = nil
        refreshCounts()
        rebuildList()
        listScroll.contentView.scroll(to: .zero)
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
                let row = SiteRow(title: origin.displayName, subtitle: origin.scheme == "https" ? String(localized: "Never offer to save", comment: "Under a site in the Passwords window's Never Saved list.") : origin.description, origin: origin)
                row.onClick = { [weak self] _ in self?.selectNever(origin) }
                return row
            }
            if selectedNever == nil || !visibleNever.contains(selectedNever!) { selectedNever = visibleNever.first }
        } else {
            let shown = visibleCredentials
            rows = shown.map { credential in
                let row = SiteRow(title: credential.title.isEmpty ? credential.origin.displayName : credential.title,
                                  subtitle: credential.username.isEmpty ? String(localized: "No username", comment: "Shown in place of a login's username when it has none.") : credential.username, origin: credential.origin)
                row.credentialID = credential.id
                row.onClick = { [weak self] _ in self?.select(credential.id) }
                return row
            }
            if selection == nil || !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
        }
        rows.forEach { list.addSubview($0) }
        needsLayout = true
        updateSelection(animated: false)
        updateEmpty()
    }

    private func select(_ id: UUID) {
        guard id != selection else { return }
        selection = id
        updateSelection(animated: true)
    }

    private func selectNever(_ origin: Origin) {
        guard origin != selectedNever else { return }
        selectedNever = origin
        updateSelection(animated: true)
    }

    private func updateSelection(animated: Bool) {
        if category == .never {
            rows.forEach { $0.setSelected($0.origin == selectedNever, animated: animated) }
            detail.showNever(selectedNever)
        } else {
            rows.forEach { $0.setSelected($0.credentialID == selection, animated: animated) }
            let credential = credentials.first { $0.id == selection }
            detail.show(credential, isWeak: credential.map { weak.contains($0.id) } ?? false, isReused: credential.map { reused.contains($0.id) } ?? false)
        }
        if animated { detail.settle() }
    }

    private func updateEmpty() {
        guard !isLocked else { return }
        let nothing = rows.isEmpty
        empty.isHidden = !nothing
        listScroll.isHidden = nothing
        listEdge.isHidden = nothing
        detail.isHidden = nothing
        guard nothing else { return }
        empty.showsAction = false
        empty.action = readFailed ? tryAgain : importPasswords
        if isLoadingVault {
            empty.text = String(localized: "Opening your passwords…", comment: "Shown in the Passwords window while the saved passwords are read.")
        } else if readFailed {
            empty.text = String(localized: "Couldn’t read your passwords. Nothing was deleted.", comment: "Shown in the Passwords window when the Keychain wouldn't give up the passwords.")
            empty.showsAction = true
        } else if !query.isEmpty {
            empty.text = String(localized: "No sites or usernames match “\(search.stringValue)”.", comment: "Shown in the Passwords window when a search finds nothing. The placeholder is what was typed.")
        } else {
            switch category {
            case .all:
                empty.text = String(localized: "Passwords you save while signing in, or bring over from another browser, show up here.", comment: "Shown in the Passwords window with no passwords saved yet.")
                empty.showsAction = true
            case .weak: empty.text = String(localized: "No weak passwords. Every one is long and varied enough to stand up to guessing.", comment: "Shown in the Passwords window's Weak list when it's empty.")
            case .reused: empty.text = String(localized: "No reused passwords. Each site has a password of its own.", comment: "Shown in the Passwords window's Reused list when it's empty.")
            case .never: empty.text = String(localized: "Sites where you choose Never when Zigzag offers to save show up here, so you can change your mind.", comment: "Shown in the Passwords window's Never Saved list when it's empty. Never is the button in the save-password prompt.")
            }
        }
        empty.appear()
    }

    // MARK: Export

    private func export() {
        guard !credentials.isEmpty else { return }
        let count = credentials.count
        ConfirmSheet.show(in: self, title: String(localized: "Export \(count) passwords?", comment: "Title of the sheet that confirms exporting passwords."),
                          message: String(localized: "The file isn’t protected: anyone who opens it can read every password. Keep it somewhere safe and delete it when you’re done.", comment: "Message of the sheet that confirms exporting passwords."),
                          confirmTitle: String(localized: "Export", comment: "Button in the sheet that confirms exporting passwords.")) { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task { @MainActor in
                // Always asked fresh, even while unlocked.
                guard await PasswordAuthentication.authenticate(String(localized: "export your passwords", comment: "Why Touch ID is asked for, finishing the sentence macOS starts with “Zigzag is trying to”.")) else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = String(localized: "Zigzag Passwords.csv", comment: "The file name suggested when exporting passwords. Keep .csv.")
                panel.allowedContentTypes = [.commaSeparatedText]
                guard let window = self.window, await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                do {
                    let written = try await PasswordExport.write(self.credentials, to: url)
                    Toast.show(String(localized: "Exported \(written) passwords", comment: "Toast after passwords were exported to a file."), symbol: "square.and.arrow.up", duration: 2, over: self, area: self.detail.frame)
                } catch {
                    Toast.show(String(localized: "Couldn’t write the file. Choose another folder and try again.", comment: "Toast in the Passwords window when the export file couldn't be written."), symbol: "exclamationmark.triangle", duration: 3, over: self, area: self.detail.frame)
                }
            }
        }
    }

    #if DEBUG
    /// For the debug bridge: show a category, or the locked screen, without clicking.
    func debugShow(_ name: String) {
        switch name {
        case "lock": lock()
        case "open": setLocked(false); reload()
        case "reveal", "delete", "edit": detail.debugAction(name)
        default:
            if name.hasPrefix("row ") , let n = Int(name.dropFirst(4)), rows.indices.contains(n) {
                if let id = rows[n].credentialID { select(id) } else { selectNever(rows[n].origin) }
            } else if name.hasPrefix("size ") {
                let n = name.split(separator: " ").dropFirst().compactMap { Double($0) }
                if n.count == 2 { window?.setContentSize(NSSize(width: n[0], height: n[1])) }
            } else if name.hasPrefix("find ") {
                search(for: String(name.dropFirst(5)))
            } else if let category = Category.allCases.first(where: { "\($0)" == name }) {
                choose(category)
            }
        }
    }
    #endif

    // MARK: Layout

    /// Wide enough, the kinds have their names; narrower, just their symbols.
    private var isCompact: Bool { bounds.width < 900 }

    override func layout() {
        super.layout()
        let top = Tokens.Page.windowTop
        let line = Tokens.Metric.hairline
        let gutter = Tokens.Page.gutter, inset = Tokens.Page.rowInset
        let compact = isCompact
        let columnWidth = compact ? Tokens.Space.x16 : Tokens.Page.columnWidth
        column.frame = NSRect(x: 0, y: 0, width: columnWidth, height: bounds.height)
        columnEdge.frame = NSRect(x: columnWidth, y: 0, width: line, height: bounds.height)
        // The title where Settings has its own, under the traffic lights. Locked, it's all the page shows, with room.
        columnTitle.frame = NSRect(x: gutter, y: top + Tokens.Page.headerTop, width: max(columnWidth - gutter * 2, columnTitle.fittingWidth + Tokens.Space.x2),
                                   height: Tokens.Page.controlHeight)
        columnTitle.isHidden = compact && !isLocked
        var y = top + Tokens.Page.headerHeight + Tokens.Space.x1
        for item in items {
            item.isCompact = compact
            if compact {
                let side = Tokens.Space.x10
                item.frame = NSRect(x: (columnWidth - side) / 2, y: y, width: side, height: side)
                y += side + 2
            } else {
                item.frame = NSRect(x: gutter - inset, y: y, width: columnWidth - (gutter - inset) * 2, height: Tokens.Page.rowHeight)
                y += Tokens.Page.rowHeight + 2
            }
        }

        let area = NSRect(x: columnWidth + line, y: 0, width: max(0, bounds.width - columnWidth - line), height: bounds.height)
        header.frame = NSRect(x: area.minX, y: top, width: area.width, height: Tokens.Page.headerHeight)
        // The pane's title lines up with the sites' names under it.
        let rowX = Tokens.Space.x3
        header.contentFrame = (rowX + CardRow.inset, area.width - gutter)
        // Under the header: the sites, a hairline, and the chosen one.
        let bodyY = header.frame.maxY
        let bodyHeight = max(0, bounds.height - bodyY)
        let listWidth = Tokens.Page.listWidth
        listScroll.frame = NSRect(x: area.minX, y: bodyY, width: listWidth, height: bodyHeight)
        listEdge.frame = NSRect(x: listScroll.frame.maxX, y: bodyY, width: line, height: bodyHeight)
        detail.frame = NSRect(x: listEdge.frame.maxX, y: bodyY, width: max(0, area.maxX - listEdge.frame.maxX), height: bodyHeight)
        let rowHeight = Tokens.Page.tallRowHeight
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: rowX, y: Tokens.Space.x2 + CGFloat(index) * (rowHeight + Tokens.Metric.rowGap), width: listWidth - rowX * 2, height: rowHeight)
        }
        let listHeight = Tokens.Space.x4 + CGFloat(rows.count) * (rowHeight + Tokens.Metric.rowGap)
        list.frame = NSRect(x: 0, y: 0, width: listWidth, height: max(listScroll.contentSize.height, listHeight))
        empty.frame = NSRect(x: area.minX, y: bodyY, width: area.width, height: bodyHeight)
        locked.frame = bounds
    }
}

extension PasswordsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { rebuildList() }

    func search(for text: String) {
        search.stringValue = text
        rebuildList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard rows.count > 0 else { return false }
        let ids = rows.compactMap(\.credentialID)
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard category != .never, !ids.isEmpty else { return false }
            let index = ids.firstIndex { $0 == selection } ?? -1
            let next = selector == #selector(NSResponder.moveDown(_:)) ? min(index + 1, ids.count - 1) : max(index - 1, 0)
            select(ids[next])
            if let row = rows.first(where: { $0.credentialID == ids[next] }) { list.scrollToVisible(row.frame.insetBy(dx: 0, dy: -Tokens.Space.x2)) }
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

// MARK: - Empty and locked

/// Nothing to show, the way History says it: the wordmark, faint and large, a quiet sentence under it, and at most
/// one thing to do.
private final class PageEmptyView: NSView {
    private let mark = WordmarkView()
    private let label = NSTextField(wrappingLabelWithString: "")
    var action: PillButton? {
        didSet { oldValue?.removeFromSuperview(); action.map { addSubview($0) }; needsLayout = true }
    }
    var showsAction = true { didSet { action?.isHidden = !showsAction; needsLayout = true } }
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Tokens.Font.body()
        label.textColor = Tokens.Color.textSecondary
        label.alignment = .center
        label.isSelectable = false
        // Faded as one piece, as History's is, so its strokes don't darken where they cross.
        markHolder.wantsLayer = true
        markHolder.alphaValue = Tokens.EmptyState.markOpacity
        markHolder.addSubview(mark)
        [markHolder, label].forEach { addSubview($0) }
        refreshColors()
    }

    private let markHolder = NSView()

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { mark.color = Tokens.Color.textPrimary }
    }

    /// Eases in, rather than snapping, when it takes the page's place.
    func appear() {
        guard window != nil, !isHidden else { return }
        layoutSubtreeIfNeeded()
        Brand.enter([mark, label, action].compactMap { $0 }.filter { !$0.isHidden })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appear()
    }

    static let markWidth = Tokens.EmptyState.markWidth

    override func layout() {
        super.layout()
        let width = min(bounds.width - Tokens.Space.x8 * 2, Tokens.EmptyState.textWidth)
        // No watermark: the sentence and the one thing to do, as every other empty list says it.
        markHolder.isHidden = true
        let markHeight: CGFloat = -Tokens.EmptyState.markGap
        let textHeight = ceil(label.sizeThatFits(NSSize(width: width, height: 400)).height)
        let showsButton = action != nil && showsAction
        let total = markHeight + Tokens.EmptyState.markGap + textHeight + (showsButton ? Tokens.EmptyState.actionGap + Tokens.Page.controlHeight : 0)
        // A little above the middle, where the eye rests.
        var y = round((bounds.height - total) / 2.3)
        markHolder.frame = NSRect(x: round((bounds.width - Self.markWidth) / 2), y: y, width: Self.markWidth, height: markHeight)
        mark.frame = markHolder.bounds
        y = markHolder.frame.maxY + Tokens.EmptyState.markGap
        label.frame = NSRect(x: round((bounds.width - width) / 2), y: y, width: width, height: textHeight)
        y = label.frame.maxY + Tokens.EmptyState.actionGap
        if let action {
            let w = max(action.fittingWidth, Tokens.Dialog.minButtonWidth)
            action.frame = NSRect(x: round((bounds.width - w) / 2), y: y, width: w, height: Tokens.Page.controlHeight)
        }
    }
}

// MARK: - Site rows

/// A site in the list: its icon, its name over the username, the soft card when chosen.
private final class SiteRow: InteractiveView {
    let origin: Origin
    var credentialID: UUID?
    private let icon = FaviconView()
    private let title: Label
    private let subtitle: Label
    private var animatesNext = false

    init(title: String, subtitle: String, origin: Origin) {
        self.origin = origin
        // A list of places on a page: the row's title over its explanation, as Settings and History set them.
        self.title = Label(title, font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        self.subtitle = Label(subtitle, font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        icon.image = SiteIcon.image(for: origin)
        self.title.lineBreakMode = .byTruncatingTail
        self.subtitle.lineBreakMode = .byTruncatingMiddle
        [icon, self.title, self.subtitle].forEach { addSubview($0) }
        if let url = origin.url, FaviconStore.shared.cachedIcon(for: url) == nil { FaviconStore.shared.prefetch(for: url) }
        setAccessibilityRole(.row)
        setAccessibilityLabel(String(localized: "\(title), \(subtitle)", comment: "What VoiceOver says for a row in the Passwords window: the site, then the username."))
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Chosen by a click, the card moves to it; on a rebuilt list it's simply there.
    func setSelected(_ selected: Bool, animated: Bool) {
        animatesNext = animated
        isSelected = selected
        animatesNext = false
    }

    override func layout() {
        super.layout()
        let side = Tokens.Metric.favicon
        icon.frame = NSRect(x: CardRow.inset, y: round((bounds.height - side) / 2), width: side, height: side)
        let x = icon.frame.maxX + CardRow.inset - Label.inset
        let top = round((bounds.height - title.lineHeight - subtitle.lineHeight) / 2)
        title.frame = NSRect(x: x, y: top, width: bounds.width - x - CardRow.inset, height: title.lineHeight)
        subtitle.frame = NSRect(x: x, y: title.frame.maxY, width: bounds.width - x - CardRow.inset, height: subtitle.lineHeight)
    }

    override func stateDidChange(animated: Bool) { applyRowStyle(animated: animated || animatesNext) }
}

/// A site's favicon, or its first letter on a soft tile when there's none yet.
private enum SiteIcon {
    static func image(for origin: Origin) -> NSImage {
        if let url = origin.url, let icon = FaviconStore.shared.cachedIcon(for: url) { return icon }
        let letter = String(origin.displayName.first.map { String($0).uppercased() } ?? "?")
        let side = Tokens.Metric.favicon
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            Tokens.Color.fieldFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.control, yRadius: Tokens.Radius.control).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: Tokens.Font.small(.medium), .foregroundColor: Tokens.Color.textSecondary]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
    }
}

// MARK: - Detail

private final class DetailView: NSView, NSTextFieldDelegate {
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.title(.semibold), color: Tokens.Color.textPrimary)
    private let subtitle = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let warning = WarningBanner()
    /// The login's details as quiet grouped rows, as Settings groups its own.
    private let card = FormGroup()
    private let usernameRow = FieldRow(name: String(localized: "Username", comment: "Name of a field of a saved login in the Passwords window."))
    private let passwordRow = FieldRow(name: String(localized: "Password", comment: "Name of a field of a saved login in the Passwords window."))
    private let websiteRow = FieldRow(name: String(localized: "Website", comment: "Name of a field of a saved login in the Passwords window."))
    private let notesRow = FieldRow(name: String(localized: "Notes", comment: "Name of a field of a saved login in the Passwords window."))
    private let editButton = PillButton(title: String(localized: "Edit", comment: "Button on a saved login in the Passwords window."), style: .plain)
    private let deleteButton = PillButton(title: String(localized: "Delete", comment: "Button on a saved login in the Passwords window."), style: .plain)
    private let saveButton = PillButton(title: String(localized: "Save", comment: "Button that saves the changes to a login in the Passwords window."), style: .prominent)
    private let cancelButton = PillButton(title: String(localized: "Cancel", comment: "Button that stops editing a login in the Passwords window."), style: .plain)
    private let usernameField = FilledField(placeholder: String(localized: "Username", comment: "Name of a field of a saved login in the Passwords window."))
    private let passwordField = FilledField(placeholder: String(localized: "Password", comment: "Name of a field of a saved login in the Passwords window."))
    private let notesField = FilledField(placeholder: String(localized: "Notes", comment: "Name of a field of a saved login in the Passwords window."))
    private let neverBody = NSTextField(wrappingLabelWithString: "")
    private let allowButton = PillButton(title: String(localized: "Allow Saving", comment: "Button for a Never Saved site in the Passwords window: offer to save its passwords again."), style: .prominent)

    private var credential: Credential?
    private var neverOrigin: Origin?
    private var revealed: SecretString?
    private var isEditing = false
    var onDeleted: (() -> Void)?
    var onAllowSaving: ((Origin) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        neverBody.font = Tokens.Font.body()
        neverBody.textColor = Tokens.Color.textSecondary
        neverBody.isSelectable = false
        [icon, title, subtitle, warning, card, editButton, deleteButton, saveButton, cancelButton, neverBody, allowButton].forEach { addSubview($0) }
        [websiteRow, usernameRow, passwordRow, notesRow].forEach { card.add($0) }
        deleteButton.isDestructive = true
        passwordField.field.font = .monospacedSystemFont(ofSize: Tokens.TypeSize.body, weight: .regular)

        usernameRow.actions = [("doc.on.doc", String(localized: "Copy Username", comment: "Tooltip of a button by a login's username in the Passwords window."), { [weak self] in self?.copyUsername() })]
        passwordRow.actions = [("eye", String(localized: "Show Password", comment: "Tooltip of a button by a login's password in the Passwords window."), { [weak self] in self?.toggleReveal() }),
                               ("doc.on.doc", String(localized: "Copy Password", comment: "Tooltip of a button by a login's password in the Passwords window."), { [weak self] in self?.copyPassword() })]
        websiteRow.actions = [("arrow.up.forward.app", String(localized: "Open Website", comment: "Tooltip of a button by a login's website in the Passwords window."), { [weak self] in self?.openWebsite() })]
        editButton.onClick = { [weak self] _ in self?.beginEditing() }
        cancelButton.onClick = { [weak self] _ in self?.endEditing() }
        saveButton.onClick = { [weak self] _ in self?.saveEdits() }
        deleteButton.onClick = { [weak self] _ in self?.delete() }
        [usernameField, passwordField, notesField].forEach { $0.field.delegate = self }
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
        let changed = credential.modified.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Words.locale))
        subtitle.stringValue = String(localized: "Last changed \(changed)", comment: "Under a saved login's name in the Passwords window. The placeholder is a date, like Nov 8, 2026.")
        usernameRow.value = credential.username.isEmpty ? String(localized: "No username", comment: "Shown in place of a login's username when it has none.") : credential.username
        usernameRow.isPlaceholder = credential.username.isEmpty
        usernameRow.showsActions = !credential.username.isEmpty
        updatePasswordRow()
        websiteRow.value = credential.origin.displayName + (credential.origin.port.map { ":\($0)" } ?? "")
        notesRow.value = credential.notes
        notesRow.isHidden = credential.notes.isEmpty
        if isReused {
            warning.set(String(localized: "This password is used on other sites. If one of them leaks, this account is at risk too. Change it on the site, then update it here.", comment: "Warning on a reused password in the Passwords window."), color: Tokens.Color.caution)
        } else if isWeak {
            warning.set(String(localized: "This password is easy to guess. Change it on the site, and use a strong password Zigzag makes for you.", comment: "Warning on a weak password in the Passwords window."), color: Tokens.Color.warning)
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
        neverBody.stringValue = String(localized: "Zigzag won’t offer to save passwords on this site. Allow it, and the next time you sign in there you’ll be asked again.", comment: "Shown for a Never Saved site in the Passwords window.")
        needsLayout = true
    }

    private func updatePasswordRow() {
        if let revealed {
            passwordRow.value = revealed.withUnsafeString { $0 }
            passwordRow.isMonospaced = true
            passwordRow.actions[0].symbol = "eye.slash"
            passwordRow.actions[0].tip = String(localized: "Hide Password", comment: "Tooltip of the button that hides a shown password in the Passwords window.")
        } else {
            passwordRow.value = String(repeating: "•", count: 12)
            passwordRow.isMonospaced = false
            passwordRow.actions[0].symbol = "eye"
            passwordRow.actions[0].tip = String(localized: "Show Password", comment: "Tooltip of a button by a login's password in the Passwords window.")
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
        guard let credential, await PasswordAuthentication.authenticate(String(localized: "show your password for \(credential.origin.displayName)", comment: "Why Touch ID is asked for, finishing the sentence macOS starts with “Zigzag is trying to”. The placeholder is a site, like github.com."), keepUnlockedFor: PasswordAuthentication.unlockDuration) else { return nil }
        return try? await PasswordStore.shared.password(for: credential.id)
    }

    private func toggleReveal() {
        if revealed != nil { revealed = nil; updatePasswordRow(); return }
        let id = credential?.id
        Task { @MainActor in
            let secret = await password()
            // Another login chosen while Touch ID was up: its password isn't the one asked for.
            guard credential?.id == id else { return }
            revealed = secret
            updatePasswordRow()
        }
    }

    private func copyUsername() {
        guard let credential else { return }
        Clipboard.copy(credential.username, concealed: false)
        toast(String(localized: "Username copied", comment: "Toast in the Passwords window."))
    }

    private func copyPassword() {
        Task { @MainActor in
            guard let secret = await password() else { return }
            secret.withUnsafeString { Clipboard.copy($0, concealed: true) }
            toast(String(localized: "Password copied. It leaves the clipboard in 90 seconds.", comment: "Toast in the Passwords window."))
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
            // Unreadable: deleting now would offer an Undo that can't bring it back.
            guard let kept = try? await store.password(for: credential.id) else {
                toast(String(localized: "Couldn’t delete it. Try again.", comment: "Toast in the Passwords window when a login couldn't be deleted."))
                return
            }
            do { try await store.delete(credential.id) } catch {
                toast(String(localized: "Couldn’t delete it. Try again.", comment: "Toast in the Passwords window when a login couldn't be deleted."))
                return
            }
            onDeleted?()
            guard let host = superview else { return }
            let area = frame
            Toast.show(String(localized: "Deleted \(credential.origin.displayName)", comment: "Toast after a login is deleted in the Passwords window. The placeholder is a site, like github.com."), symbol: "trash", action: (String(localized: "Undo", comment: "Button in the toast after a login is deleted."), { [weak host] in
                Task { @MainActor in
                    do {
                        _ = try await store.save(origin: credential.origin, username: credential.username, password: kept, title: credential.title.isEmpty ? nil : credential.title,
                                                 notes: credential.notes, otpAuth: credential.otpAuth, created: credential.created)
                    } catch {
                        if let host { Toast.show(String(localized: "Couldn’t put it back", comment: "Toast when undoing a deleted login failed."), symbol: "exclamationmark.triangle", duration: 4, over: host, area: area) }
                    }
                }
            }), duration: 6, over: host, area: frame)
        }
    }

    private func beginEditing() {
        guard let credential else { return }
        Task { @MainActor in
            // Another login chosen while Touch ID was up: this one isn't on screen to edit any more.
            guard let secret = await password(), self.credential?.id == credential.id else { return }
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
        guard !newPassword.isEmpty else { toast(String(localized: "A password can’t be empty.", comment: "Toast when saving a login with its password cleared.")); return }
        edited.username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.notes = notesField.stringValue
        edited.modified = Date()
        Task { @MainActor in
            do {
                try await PasswordStore.shared.update(edited, password: newPassword)
                // Still showing the login that was saved: its fields close. Another one chosen meanwhile is left as it is.
                if credential?.id == edited.id {
                    revealed = nil
                    endEditing()
                }
                toast(String(localized: "Saved", comment: "Toast after changes to a login are saved."))
            } catch {
                toast(String(localized: "Couldn’t save the changes. Try again.", comment: "Toast when changes to a login couldn't be saved."))
            }
        }
    }

    /// While editing, Return saves and Esc cancels, from any of the fields.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isEditing else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): saveEdits(); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(); return true
        default: return false
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

    /// A new login chosen: what's shown eases in, so the change reads as a change rather than a flicker.
    func settle() {
        guard window != nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = Tokens.Motion.standard
        fade.timingFunction = Tokens.Motion.easeOut
        wantsLayer = true
        layer?.add(fade, forKey: "settle")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // The page's gutter around a column no wider than reading wants.
        let pad = Tokens.Page.gutter
        let width = max(0, min(bounds.width - pad * 2, Tokens.Page.detailWidth))
        let x = pad
        var y: CGFloat = Tokens.Space.x5
        let side = Tokens.Space.x10
        icon.frame = NSRect(x: x, y: y, width: side, height: side)
        let textX = icon.frame.maxX + Tokens.Space.x3
        let textWidth = max(0, width - (textX - x))
        let block = title.lineHeight + 2 + subtitle.lineHeight
        title.frame = NSRect(x: textX - Label.inset, y: y + round((side - block) / 2), width: textWidth, height: title.lineHeight)
        subtitle.frame = NSRect(x: textX - Label.inset, y: title.frame.maxY + 2, width: textWidth, height: subtitle.lineHeight)
        y = icon.frame.maxY + Tokens.Space.x6

        if neverOrigin != nil {
            let h = ceil(neverBody.sizeThatFits(NSSize(width: width, height: 200)).height)
            neverBody.frame = NSRect(x: x, y: y, width: width, height: h)
            y = neverBody.frame.maxY + Tokens.Space.x5
            allowButton.frame = NSRect(x: x, y: y, width: allowButton.fittingWidth, height: Tokens.Page.controlHeight)
            return
        }
        if !warning.isHidden {
            let h = warning.height(for: width)
            warning.frame = NSRect(x: x, y: y, width: width, height: h)
            y = warning.frame.maxY + Tokens.Space.x4
        }
        for row in [websiteRow, usernameRow, passwordRow, notesRow] { row.frame.size = NSSize(width: width, height: FieldRow.height) }
        card.frame = NSRect(x: x, y: y, width: width, height: card.fittingHeight(for: width))
        y = card.frame.maxY + Tokens.Space.x4
        let h = Tokens.Page.controlHeight
        if isEditing {
            let sw = max(saveButton.fittingWidth, Tokens.Dialog.minButtonWidth)
            saveButton.frame = NSRect(x: x + width - sw, y: y, width: sw, height: h)
            let cw = max(cancelButton.fittingWidth, Tokens.Dialog.minButtonWidth)
            cancelButton.frame = NSRect(x: saveButton.frame.minX - Tokens.Dialog.buttonGap - cw, y: y, width: cw, height: h)
        } else {
            let ew = max(editButton.fittingWidth, Tokens.Dialog.minButtonWidth)
            editButton.frame = NSRect(x: x, y: y, width: ew, height: h)
            let dw = max(deleteButton.fittingWidth, Tokens.Dialog.minButtonWidth)
            deleteButton.frame = NSRect(x: editButton.frame.maxX + Tokens.Dialog.buttonGap, y: y, width: dw, height: h)
        }
    }
}

/// One line of the detail card: a name on the left, the value, and small icon buttons on the right.
private final class FieldRow: NSView {
    private let nameLabel: Label
    private let valueLabel = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private var buttons: [IconButton] = []
    /// As tall as a row in Settings' groups.
    static let height: CGFloat = 44

    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }
    var isPlaceholder = false { didSet { valueLabel.textColor = isPlaceholder ? Tokens.Color.textTertiary : Tokens.Color.textPrimary } }
    var isMonospaced = false {
        didSet { valueLabel.font = isMonospaced ? .monospacedSystemFont(ofSize: Tokens.TypeSize.body, weight: .regular) : Tokens.Font.body() }
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
                let button = IconButton(symbol: action.symbol, size: .compact, toolTip: action.tip)
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
        [nameLabel, valueLabel].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let nameWidth: CGFloat = 88
        nameLabel.frame = NSRect(x: pad, y: (bounds.height - nameLabel.lineHeight) / 2, width: nameWidth, height: nameLabel.lineHeight)
        var right = bounds.width - Tokens.Space.x2
        for button in buttons.reversed() where !button.isHidden {
            let side = Tokens.Metric.compactIconButton
            button.frame = NSRect(x: right - side, y: (bounds.height - side) / 2, width: side, height: side)
            right = button.frame.minX - 2
        }
        let x = nameLabel.frame.maxX + Tokens.Space.x2
        if let editor {
            let h = Tokens.Page.controlHeight
            editor.frame = NSRect(x: x - Tokens.Space.x2, y: (bounds.height - h) / 2, width: bounds.width - x - Tokens.Space.x1, height: h)
        }
        valueLabel.frame = NSRect(x: x, y: (bounds.height - valueLabel.lineHeight) / 2, width: right - x - Tokens.Space.x2, height: valueLabel.lineHeight)
    }
}

private final class WarningBanner: NSView {
    private let icon = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var color = Tokens.Color.warning

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.group
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
        // A soft wash of the warning's color: noticed, never loud.
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(Tokens.Color.statusFillAlpha).cgColor }
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
        // A concealed copy stays on this Mac: Universal Clipboard would hand it to your other devices, where the
        // 90-second clear never reaches.
        board.prepareForNewContents(with: concealed ? .currentHostOnly : [])
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
    /// Returns how many passwords went into the file: one that can't be read from the Keychain is left out.
    @discardableResult
    static func write(_ credentials: [Credential], to url: URL) async throws -> Int {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        // Chrome's columns, which every password manager reads, and the one-time-code secret as Apple's Passwords
        // writes it, so codes come along too.
        var data = Data("name,url,username,password,note,otpauth\n".utf8)
        var written = 0
        defer { data.resetBytes(in: 0..<data.count) }
        for credential in credentials {
            guard let password = try? await PasswordStore.shared.password(for: credential.id) else { continue }
            let line = password.withUnsafeString { secret in
                [credential.title.isEmpty ? credential.origin.displayName : credential.title, credential.origin.description, credential.username, secret,
                 credential.notes, credential.otpAuth]
                    .map(field).joined(separator: ",") + "\n"
            }
            data.append(Data(line.utf8))
            written += 1
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return written
    }
}
