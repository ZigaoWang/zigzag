import AppKit

/// Every page you've visited, newest first, grouped by day: search it, open a page, or forget one, a stretch of time
/// or everything. Window › History, or ⇧⌘Y.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    static var shared: HistoryWindowController?

    static func show() {
        if let shared { shared.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "History"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 400)
        window.backgroundColor = Tokens.Color.formBackground
        let view = HistoryView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = HistoryWindowController(window: window)
        window.delegate = controller
        window.setFrameAutosaveName("History")
        if !window.setFrameUsingName("History") { window.center() }
        shared = controller
        controller.showWindow(nil)
        view.focusSearch()
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private final class HistoryView: NSView, NSTextFieldDelegate {
    private let titleLabel = Label("History", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let searchBackground = ColorView(color: Tokens.Color.fieldFill)
    private let searchIcon = NSImageView(image: Tokens.Symbol.image("magnifyingglass"))
    private let search = PlainTextField(font: Tokens.Font.body(), placeholder: "Search history")
    private let clearButton = TextButton.form("Clear History…")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let empty = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var entries: [HistoryEntry] = []
    private var views: [NSView] = []
    private var exhausted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchBackground.wantsLayer = true
        searchBackground.layer?.cornerRadius = Tokens.Radius.control + 2
        searchBackground.layer?.cornerCurve = .continuous
        searchIcon.contentTintColor = Tokens.Color.textTertiary
        search.delegate = self
        clearButton.onClick = { [weak self] _ in self?.showClearMenu() }
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        empty.alignment = .center
        [titleLabel, searchBackground, searchIcon, search, clearButton, scroll, empty].forEach { addSubview($0) }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func focusSearch() { window?.makeFirstResponder(search) }

    // MARK: Loading

    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        exhausted = !query.isEmpty
        entries = query.isEmpty ? HistoryStore.shared.page() : HistoryStore.shared.search(query, limit: 200)
        rebuild()
    }

    /// Near the bottom: the next stretch of older pages.
    @objc private func scrolled() {
        guard !exhausted, let last = entries.last else { return }
        let visible = scroll.contentView.bounds
        guard visible.maxY > list.bounds.height - 600 else { return }
        let more = HistoryStore.shared.page(before: last.lastVisit)
        if more.isEmpty { exhausted = true; return }
        entries += more
        rebuild()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Rows

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()

    private static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormat.string(from: date)
    }

    private func rebuild() {
        views.forEach { $0.removeFromSuperview() }
        views = []
        let searching = !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        var lastDay: String?
        for entry in entries {
            let day = Self.dayTitle(entry.lastVisit)
            if !searching, day != lastDay {
                let header = Label(day, font: Tokens.Font.body(.semibold), color: Tokens.Color.textSecondary)
                views.append(header)
                lastDay = day
            }
            let row = HistoryRow(entry: entry)
            row.onOpen = { [weak self] background in self?.open(entry.url, background: background) }
            row.onDelete = { [weak self, weak row] in
                HistoryStore.shared.delete(entry.url)
                self?.entries.removeAll { $0.url == entry.url }
                guard let row else { return }
                Tokens.Motion.animate(Tokens.Motion.feedback, { row.animator().alphaValue = 0 }, completion: { self?.rebuild() })
            }
            views.append(row)
        }
        views.forEach { list.addSubview($0) }
        empty.stringValue = searching ? "Nothing in your history matches that." : "Pages you visit show up here."
        empty.isHidden = !entries.isEmpty
        needsLayout = true
    }

    private func open(_ url: URL, background: Bool) {
        let controller = WindowManager.shared.controllers.first { !$0.tabManager.isPrivate } ?? WindowManager.shared.newWindow(showCommandBar: false)
        controller.open(url, disposition: background ? .backgroundTab : .foregroundTab)
        if !background { controller.window?.makeKeyAndOrderFront(nil) }
    }

    // MARK: Clearing

    private func showClearMenu() {
        let menu = NSMenu()
        let calendar = Calendar.current
        let now = Date()
        let choices: [(String, Date?)] = [
            ("The Last Hour", now.addingTimeInterval(-3600)),
            ("Today", calendar.startOfDay(for: now)),
            ("Today and Yesterday", calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))),
            ("All History", nil),
        ]
        for (title, since) in choices {
            menu.addItem(SidebarMenus.Item(title) { [weak self] in self?.clear(since: since, title: title) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: clearButton.bounds.maxY + 4), in: clearButton)
    }

    private func clear(since: Date?, title: String) {
        guard let host = window?.contentView else { return }
        let what = since == nil ? "all of your history" : "your history from \(title.lowercased())"
        ConfirmSheet.show(in: host, title: "Clear \(title.lowercased())?",
                          message: "This removes \(what) from Zigzag. Pinned tabs and open tabs stay.",
                          confirmTitle: "Clear", destructive: true) { [weak self] confirmed in
            guard confirmed else { return }
            if let since { HistoryStore.shared.clear(since: since) } else { HistoryStore.shared.clearAll() }
            self?.reload()
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x6
        let top: CGFloat = 40
        titleLabel.frame = NSRect(x: pad, y: top, width: 200, height: titleLabel.lineHeight)
        let cw = clearButton.fittingWidth
        clearButton.frame = NSRect(x: bounds.width - pad - cw, y: top - 4, width: cw, height: Tokens.Space.x8)
        let sy = titleLabel.frame.maxY + Tokens.Space.x4
        searchBackground.frame = NSRect(x: pad, y: sy, width: bounds.width - pad * 2, height: 34)
        searchIcon.frame = NSRect(x: pad + 10, y: sy + 9, width: 16, height: 16)
        let fh = ceil(search.intrinsicContentSize.height)
        search.frame = NSRect(x: pad + 34, y: sy + (34 - fh) / 2, width: bounds.width - pad * 2 - 44, height: fh)
        let listTop = searchBackground.frame.maxY + Tokens.Space.x4
        scroll.frame = NSRect(x: 0, y: listTop, width: bounds.width, height: bounds.height - listTop)
        var y: CGFloat = 0
        let width = scroll.contentSize.width
        for view in views {
            if view is HistoryRow {
                view.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: width - (pad - Tokens.Space.x2) * 2, height: 40)
                y += 40
            } else {
                y += y == 0 ? 0 : Tokens.Space.x4
                view.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 24)
                y += 28
            }
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + Tokens.Space.x6, scroll.contentSize.height))
        empty.frame = NSRect(x: pad, y: listTop + 60, width: bounds.width - pad * 2, height: empty.lineHeight)
    }
}

/// One page: its icon, title and site, and when; click to open (⌘-click behind), × to forget it.
private final class HistoryRow: InteractiveView {
    var onOpen: ((Bool) -> Void)?
    var onDelete: (() -> Void)?
    private let entry: HistoryEntry
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let site = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let time = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    private let remove = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Remove from History")

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    init(entry: HistoryEntry) {
        self.entry = entry
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        icon.image = FaviconStore.shared.cachedIcon(for: entry.url)
        if icon.image == nil { FaviconStore.shared.prefetch(for: entry.url) }
        title.stringValue = entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title
        site.stringValue = HistoryStore.normalizedHost(entry.url)
        time.stringValue = Self.timeFormat.string(from: entry.lastVisit)
        time.alignment = .right
        remove.isHidden = true
        remove.onClick = { [weak self] _ in self?.onDelete?() }
        onClick = { [weak self] event in self?.onOpen?(event.modifierFlags.contains(.command)) }
        [icon, title, site, time, remove].forEach { addSubview($0) }
        toolTip = entry.url.absoluteString
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.stringValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, pad = Tokens.Space.x2
        icon.frame = NSRect(x: pad, y: (h - Tokens.Metric.favicon) / 2, width: Tokens.Metric.favicon, height: Tokens.Metric.favicon)
        let right = bounds.width - pad - 80
        time.frame = NSRect(x: right, y: (h - time.lineHeight) / 2, width: 80, height: time.lineHeight)
        remove.frame = NSRect(x: bounds.width - pad - Tokens.Space.x6, y: (h - Tokens.Space.x6) / 2, width: Tokens.Space.x6, height: Tokens.Space.x6)
        let x = icon.frame.maxX + Tokens.Space.x3
        let siteWidth = min(site.textWidth + 2, 200)
        let titleWidth = min(title.textWidth + 2, right - x - siteWidth - Tokens.Space.x3)
        title.frame = NSRect(x: x, y: (h - title.lineHeight) / 2, width: max(0, titleWidth), height: title.lineHeight)
        site.frame = NSRect(x: title.frame.maxX + Tokens.Space.x2, y: (h - site.lineHeight) / 2, width: max(0, min(siteWidth, right - title.frame.maxX - Tokens.Space.x3)), height: site.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        layer?.backgroundColor = isHovered ? cgColor(Tokens.Color.hoverFill) : nil
        // The time steps aside for the × while the pointer is on the row.
        remove.isHidden = !isHovered
        time.isHidden = isHovered
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(SidebarMenus.Item("Open") { [weak self] in self?.onOpen?(false) })
        menu.addItem(SidebarMenus.Item("Open in Background") { [weak self] in self?.onOpen?(true) })
        menu.addItem(SidebarMenus.Item("Copy Link") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.entry.url.absoluteString, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(SidebarMenus.Item("Remove from History") { [weak self] in self?.onDelete?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
