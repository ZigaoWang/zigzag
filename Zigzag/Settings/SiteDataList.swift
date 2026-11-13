import AppKit

/// A group row that says how tall it is at a width, as a `FormRow` does.
protocol SettingsSizedRow: NSView { func height(for width: CGFloat) -> CGFloat }

/// A group row that "Find a setting" searches inside: it shows what in it matches, and says whether anything does.
protocol SettingsFilteredRow: NSView { func find(_ words: [String]) -> Bool }

/// Settings' list of what websites keep (#207): every site, as tall as all its rows, inside the page's own scroll,
/// with row views made only for the part in view and reused as it scrolls, so thousands of sites open at once and
/// scroll at the display's rate. Each row looks as a `FormRow` with a picture does: the site's icon, its name (what
/// a search matched marked), what it keeps, its size at the trailing end, and the trash on hover.
final class SiteDataList: NSView, SettingsSizedRow, SettingsFilteredRow, SettingsSearchable {
    /// Before Show All, the first sites by the order chosen.
    static let collapsedCount = 30

    var model: SiteDataModel? {
        didSet {
            oldValue?.changed = nil
            model?.changed = { [weak self] in self?.modelChanged() }
            visible.values.forEach(recycle)
            visible = [:]
            modelChanged()
        }
    }
    /// Show All: every site, not only the first.
    var showsAll = false { didSet { if showsAll != oldValue { modelChanged() } } }
    /// Its height changed: the page lays out again.
    /// What's shown changed; true when its height did too, so the page lays out again.
    var changed: ((_ heightChanged: Bool) -> Void)?
    /// The trash on a site's row.
    var onRemove: ((SiteDataEntry) -> Void)?

    var searchText: String {
        String(localized: "website data cookies cache storage sites remove", comment: "Words that find the list of what websites keep with Find a setting in Settings. Not shown.")
    }

    /// The row's height: a title and the line under it, as every row with a line under its name.
    static let rowHeight: CGFloat = {
        let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
        return max(Tokens.Page.groupRowHeight, Tokens.Page.groupRowPad * 2 + title.lineHeight + 2 + detail.lineHeight)
    }()
    /// Rows made past each edge of what's in view, so a quick scroll finds them there.
    private static let overscan: CGFloat = 240

    private var visible: [Int: SiteDataRow] = [:]
    private var pool: [SiteDataRow] = []
    /// Under the first sites: how many more there are, and Show All.
    private let footer: FormRow
    private let showAllButton = PillButton(title: String(localized: "Show All", comment: "Button under the first 30 sites in Settings › Privacy."))
    /// Loading, nothing kept, or nothing matching: one quiet row in the list's place.
    private let message: FormRow
    private var hoverArea: NSTrackingArea?
    private var hovered: Int? { didSet { if hovered != oldValue { [oldValue, hovered].compactMap { $0 }.forEach(refreshHover) } } }
    private var boundsToken: NSObjectProtocol?
    /// Icons read for this list, so scrolling back never reads them again: a site with none keeps NSNull.
    private var icons: [String: NSImage] = [:]
    private var iconsMissing: Set<String> = []
    private var iconsReading: Set<String> = []
    private var lastHeight: CGFloat = 0

    override init(frame: NSRect) {
        footer = FormRow(title: "", control: showAllButton)
        message = FormRow(title: "", control: NSView())
        super.init(frame: frame)
        showAllButton.onClick = { [weak self] _ in self?.showsAll = true }
        addSubview(footer)
        addSubview(message)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Websites", comment: "VoiceOver name of the list of sites in Settings › Privacy › Stored by Websites."))
        modelChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: What's shown

    private var entries: [SiteDataEntry] { model?.shown ?? [] }
    /// How many rows are listed: all matches while searching, else the first until Show All.
    private var count: Int {
        let all = entries.count
        guard let model, !model.isFiltering, !showsAll else { return all }
        return min(all, Self.collapsedCount)
    }
    private var hasFooter: Bool { count < entries.count }

    private enum Message { case none, loading, empty, noMatch(String) }
    private var messageShown: Message {
        guard let model else { return .loading }
        if model.state != .loaded { return .loading }
        if !entries.isEmpty { return .none }
        return model.isFiltering ? .noMatch(model.words.joined(separator: " ")) : .empty
    }

    func height(for width: CGFloat) -> CGFloat {
        if case .none = messageShown {
            return CGFloat(count) * Self.rowHeight + (hasFooter ? footer.height(for: width) : 0)
        }
        return message.height(for: width)
    }

    func find(_ words: [String]) -> Bool {
        model?.outsideWords = words
        return !words.isEmpty ? !(model?.shown.isEmpty ?? true) : true
    }

    private func modelChanged() {
        visible.values.forEach(recycle)
        visible = [:]
        switch messageShown {
        case .none: message.isHidden = true
        case .loading:
            message.isHidden = false
            message.update(title: String(localized: "Loading…", comment: "In Settings › Privacy › Stored by Websites while the list of sites is read."), detail: nil, quiet: true)
        case .empty:
            message.isHidden = false
            message.update(title: String(localized: "None yet", comment: "A setting in Settings › Privacy."),
                           detail: String(localized: "Sites you visit can keep cookies and files here, to keep you signed in and load faster.", comment: "Explanation under “None yet” in Settings › Privacy."),
                           quiet: false)
        case .noMatch(let words):
            message.isHidden = false
            message.update(title: String(localized: "No sites match “\(words)”.", comment: "In Settings › Privacy › Stored by Websites when its search finds nothing; what was typed."), detail: nil, quiet: true)
        }
        let rest = entries.count - count
        footer.isHidden = !hasFooter || !message.isHidden
        if hasFooter {
            footer.update(title: String(localized: "\(rest) more sites", comment: "Under the first 30 sites in Settings › Privacy, beside Show All."), detail: nil, quiet: false)
        }
        needsLayout = true
        let height = height(for: bounds.width > 0 ? bounds.width : 600)
        let grew = height != lastHeight
        lastHeight = height
        changed?(grew)
    }

    // MARK: Rows for what's in view

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let boundsToken { NotificationCenter.default.removeObserver(boundsToken) }
        boundsToken = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        boundsToken = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tile()
                self?.followPointer()
            }
        }
    }

    isolated deinit { boundsToken.map(NotificationCenter.default.removeObserver) }

    override func layout() {
        super.layout()
        lastHeight = bounds.height
        message.frame = NSRect(x: 0, y: 0, width: bounds.width, height: message.height(for: bounds.width))
        footer.frame = NSRect(x: 0, y: CGFloat(count) * Self.rowHeight, width: bounds.width, height: footer.height(for: bounds.width))
        for (index, row) in visible { place(row, at: index) }
        tile()
    }

    /// The rows in view (and a little past) made or reused; the rest put back for later.
    private func tile() {
        guard message.isHidden, count > 0 else {
            visible.values.forEach(recycle)
            visible = [:]
            return
        }
        let area = visibleRect.insetBy(dx: 0, dy: -Self.overscan)
        guard !area.isEmpty else { return }
        let first = max(0, Int(floor(area.minY / Self.rowHeight)))
        let last = min(count - 1, Int(ceil(area.maxY / Self.rowHeight)))
        guard first <= last else { visible.values.forEach(recycle); visible = [:]; return }
        let wanted = first...last
        for (index, row) in visible where !wanted.contains(index) {
            recycle(row)
            visible[index] = nil
        }
        for index in wanted where visible[index] == nil {
            let row = pool.popLast() ?? makeRow()
            row.isHidden = false
            visible[index] = row
            configure(row, at: index)
            place(row, at: index)
        }
    }

    private func makeRow() -> SiteDataRow {
        let row = SiteDataRow(frame: NSRect(x: 0, y: 0, width: bounds.width, height: Self.rowHeight))
        row.onRemove = { [weak self, weak row] in
            guard let self, let row, let site = row.site, let entry = self.entries.first(where: { $0.site == site }) else { return }
            self.onRemove?(entry)
        }
        addSubview(row)
        return row
    }

    private func recycle(_ row: SiteDataRow) {
        row.isHidden = true
        row.site = nil
        pool.append(row)
    }

    private func place(_ row: SiteDataRow, at index: Int) {
        let frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        if row.frame != frame { row.frame = frame }
        row.showsLine = index < count - 1 || hasFooter
    }

    private func configure(_ row: SiteDataRow, at index: Int) {
        let entry = entries[index]
        row.show(entry, words: model?.words ?? [], icon: icon(for: entry.site))
        row.isHovered = index == hovered
    }

    // MARK: Icons

    /// The site's icon from memory, or the globe while it's read from disk off the main thread.
    private func icon(for site: String) -> NSImage? {
        if let image = icons[site] { return image }
        guard !iconsMissing.contains(site), !iconsReading.contains(site), let url = URL(string: "https://\(site)") else { return nil }
        iconsReading.insert(site)
        Task { [weak self] in
            let image = await FaviconStore.shared.storedIcon(for: url)
            guard let self else { return }
            self.iconsReading.remove(site)
            if let image { self.icons[site] = image } else { self.iconsMissing.insert(site) }
            if let image, let row = self.visible.values.first(where: { $0.site == site }) { row.icon = image }
        }
        return nil
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    /// The page scrolled under a still pointer: the row under it now is the hovered one.
    private func followPointer() {
        guard let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) { hover(at: point) } else { hovered = nil }
    }

    private func hover(at point: NSPoint) {
        guard message.isHidden, point.y >= 0, bounds.contains(point) else { hovered = nil; return }
        let index = Int(point.y / Self.rowHeight)
        hovered = index < count ? index : nil
    }

    private func refreshHover(_ index: Int) { visible[index]?.isHovered = index == hovered }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visible.values.forEach { $0.needsLayout = true }
    }

    #if DEBUG
    /// How many row views exist, in view and kept for reuse.
    var debugRowViews: Int { visible.count + pool.count }
    var debugExpanded: Bool { showsAll }
    var debugListed: Int { count }
    #endif
}

/// One site's row in `SiteDataList`, reused for another site as the list scrolls.
final class SiteDataRow: NSView {
    var site: String?
    var onRemove: (() -> Void)?
    var icon: NSImage? {
        didSet {
            iconView.image = icon ?? SettingsIcon.symbol("globe")
            iconView.imageScaling = icon == nil ? .scaleNone : .scaleProportionallyUpOrDown
        }
    }
    var isHovered = false { didSet { if isHovered != oldValue { refreshDelete() } } }
    var showsLine = true { didSet { line.isHidden = !showsLine } }

    private let iconView = NSImageView()
    private let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let size = Label("", font: Tokens.Font.figures(Tokens.Font.detail().pointSize), color: Tokens.Color.textSecondary)
    private let remove = IconButton(symbol: "trash", size: .compact)
    private let line = ColorView(color: Tokens.Color.separator)

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.contentTintColor = Tokens.Color.icon
        size.alignment = .right
        remove.onClick = { [weak self] _ in self?.onRemove?() }
        remove.keyboardFocusChanged = { [weak self] _ in self?.refreshDelete() }
        [iconView, title, detail, size, remove, line].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        refreshDelete()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ entry: SiteDataEntry, words: [String], icon: NSImage?) {
        site = entry.site
        self.icon = icon
        let styled = NSMutableAttributedString(string: entry.site, attributes: [.font: Tokens.Font.row(), .foregroundColor: Tokens.Color.textPrimary])
        // What the search matched, a step bolder: the rest of the name stays as it is.
        for range in SiteDataListing.matchRanges(of: words, in: entry.site) { styled.addAttribute(.font, value: Tokens.Font.row(.semibold), range: range) }
        title.attributedStringValue = styled
        detail.stringValue = Self.describe(entry.kinds)
        size.stringValue = entry.size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? ""
        remove.toolTip = String(localized: "Remove Data for \(entry.site)…", comment: "Tooltip and VoiceOver name of the trash on a site's row in Settings › Privacy › Stored by Websites; the site, like apple.com.")
        setAccessibilityLabel([entry.site, detail.stringValue, size.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    private func refreshDelete() {
        RowDelete.apply(remove, shows: RowDelete.shows(hovered: isHovered, focused: remove.hasKeyboardFocus, voiceOver: RowDelete.voiceOver))
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Page.groupPad, side = Tokens.Metric.favicon
        iconView.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        let b = Tokens.Metric.compactIconButton
        remove.frame = NSRect(x: bounds.width - pad - b + Tokens.Space.x1, y: round((bounds.height - b) / 2), width: b, height: b)
        let sizeWidth: CGFloat = size.stringValue.isEmpty ? 0 : size.textWidth
        size.frame = NSRect(x: remove.frame.minX - Tokens.Space.x2 - sizeWidth, y: round((bounds.height - size.lineHeight) / 2), width: sizeWidth, height: size.lineHeight)
        let x = pad + side + Tokens.Space.x3
        let width = max(0, size.frame.minX - Tokens.Space.x4 - x) + Label.inset * 2
        let block = title.lineHeight + 2 + detail.lineHeight
        let top = round((bounds.height - block) / 2)
        title.frame = NSRect(x: x - Label.inset, y: top, width: width, height: title.lineHeight)
        detail.frame = NSRect(x: x - Label.inset, y: title.frame.maxY + 2, width: width, height: detail.lineHeight)
        line.frame = NSRect(x: x, y: bounds.height - Tokens.Metric.hairline, width: max(0, bounds.width - x - pad), height: Tokens.Metric.hairline)
    }

    /// What a site keeps, in a few plain words, as a label under its name: "Cookies, saved data and cache".
    static func describe(_ kinds: SiteDataKinds) -> String {
        // Each combination whole, so a language can say it its own way.
        switch (kinds.contains(.cookies), kinds.contains(.saved), kinds.contains(.cache)) {
        case (true, true, true): String(localized: "Cookies, saved data and cache", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (true, true, false): String(localized: "Cookies and saved data", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (true, false, true): String(localized: "Cookies and cache", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (true, false, false): String(localized: "Cookies", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (false, true, true): String(localized: "Saved data and cache", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (false, true, false): String(localized: "Saved data", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (false, false, true): String(localized: "Cache", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        case (false, false, false): String(localized: "Data", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac. A label, no full stop.")
        }
    }
}

/// Over the list: its search, the order, and Remove All. Sits at the right of the "Stored by Websites" heading,
/// lined up with the rows' trailing edge, as Feature Flags has its search.
final class SiteDataToolbar: NSView {
    let search = FilledField.search(String(localized: "Find a site", comment: "Placeholder of the search field over the list in Settings › Privacy › Stored by Websites: finds a site by its name."))
    let sort = DropdownButton()
    let removeAll = PillButton(title: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.isOutlined = true
        sort.options = [DropdownButton.Option(title: String(localized: "Sort by Name", comment: "A choice for the order of the list in Settings › Privacy › Stored by Websites.")),
                        DropdownButton.Option(title: String(localized: "Sort by Size", comment: "A choice for the order of the list in Settings › Privacy › Stored by Websites: largest first."))]
        sort.setAccessibilityLabel(String(localized: "Order", comment: "VoiceOver name of the menu that orders the list in Settings › Privacy › Stored by Websites."))
        [sort, removeAll, search].forEach(addSubview)
        setRemoveTitle(filtering: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setRemoveTitle(filtering: Bool) {
        let title = filtering ? String(localized: "Remove All Shown…", comment: "Button over the list in Settings › Privacy › Stored by Websites while it's searched: removes the data of the sites shown.")
            : String(localized: "Remove All…", comment: "Button over the list in Settings › Privacy › Stored by Websites: removes every site's data.")
        guard removeAll.title != title else { return }
        removeAll.title = title
        needsLayout = true
    }

    /// The search's width, a little narrower on a narrow page.
    var searchWidth: CGFloat = 200 { didSet { needsLayout = true } }
    var showsSort = true { didSet { sort.isHidden = !showsSort; needsLayout = true } }

    override var fittingSize: NSSize {
        let gap = Tokens.Space.x2
        var width = searchWidth
        if !removeAll.isHidden { width += gap + removeAll.fittingWidth }
        if showsSort { width += gap + sort.intrinsicContentSize.width }
        return NSSize(width: width, height: Tokens.Page.controlHeight)
    }

    override func layout() {
        super.layout()
        let h = Tokens.Page.controlHeight, gap = Tokens.Space.x2
        var right = bounds.width
        search.frame = NSRect(x: right - searchWidth, y: 0, width: searchWidth, height: h)
        right = search.frame.minX - gap
        if !removeAll.isHidden {
            let rw = removeAll.fittingWidth
            removeAll.frame = NSRect(x: right - rw, y: 0, width: rw, height: h)
            right = removeAll.frame.minX - gap
        }
        let sw = sort.intrinsicContentSize.width
        sort.frame = NSRect(x: right - sw, y: 0, width: sw, height: h)
    }
}

private extension FormRow {
    /// A message row's words changed in place.
    func update(title: String, detail: String?, quiet: Bool) {
        titleText = title
        detailText = detail ?? ""
        titleColor = quiet ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
    }
}
