import AppKit

/// A group row that says how tall it is at a width, as a `FormRow` does.
protocol SettingsSizedRow: NSView { func height(for width: CGFloat) -> CGFloat }

/// A group row that "Find a setting" searches inside: it shows what in it matches, and says whether anything does.
protocol SettingsFilteredRow: NSView { func find(_ words: [String]) -> Bool }

/// Settings' list of what websites keep (#207): every site, as tall as all its boxes, inside the page's own scroll,
/// with views made only for the part in view and reused as it scrolls, so thousands of sites open at once and
/// scroll at the display's rate. Each site is a box that folds, as Site Permissions has them (#368): its icon, its
/// name (what a search matched marked), what it keeps, its size and the trash on hover; opened, a row for its
/// cookies and one for its cache, each cleared on its own.
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
    /// What's shown changed; true when its height did too, so the page lays out again.
    var changed: ((_ heightChanged: Bool) -> Void)?
    /// The trash on a site's box.
    var onRemove: ((SiteDataEntry) -> Void)?
    /// Clear… on one kind of what a site keeps.
    var onClear: ((SiteDataEntry, WebsiteData.Kind) -> Void)?

    var searchText: String {
        String(localized: "website data cookies cache storage sites remove", comment: "Words that find the list of what websites keep with Find a setting in Settings. Not shown.")
    }

    /// A box's header: a title and the line under it, as every row with a line under its name.
    static let rowHeight: CGFloat = {
        let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
        return max(Tokens.Page.groupRowHeight, Tokens.Page.groupRowPad * 2 + title.lineHeight + 2 + detail.lineHeight)
    }()
    /// A kind of data inside an open box: one line, as a plain row.
    static let kindHeight = Tokens.Page.groupRowHeight
    /// Views made past each edge of what's in view, so a quick scroll finds them there.
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
    /// Sites opened or folded while Settings stays open; the rest as a list of their length starts.
    private var opened: [String: Bool] = [:]
    /// Where each box listed starts, and where the last one ends.
    private var tops: [CGFloat] = []
    private var boxesHeight: CGFloat = 0

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
    /// How many boxes are listed: all matches while searching, else the first until Show All.
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

    /// Whether a site's box is open: as it was left, else open in a short list and folded in a long one.
    func isOpen(_ site: String) -> Bool { opened[site] ?? FoldStyle.opensByDefault(count: entries.count) }

    /// A site's box opened or folded, by a click or a key: the boxes under it move to make room.
    func setOpen(_ site: String, _ open: Bool) {
        guard isOpen(site) != open else { return }
        opened[site] = open
        let rows = visible.values.filter { $0.site == site }
        FoldStyle.animate(in: enclosingScrollView?.documentView ?? self, { [weak self] in
            rows.forEach { $0.isOpen = open }
            self?.boxesChanged()
        }, completion: { rows.forEach { $0.settle() } })
    }

    /// The kinds a box opens to: its cookies and saved data, cleared together as Clear Cookies… does, and its cache.
    static func kinds(of entry: SiteDataEntry) -> [WebsiteData.Kind] {
        (entry.kinds.isDisjoint(with: [.cookies, .saved]) ? [] : [.cookies]) + (entry.kinds.contains(.cache) ? [.cache] : [])
    }

    private func boxHeight(_ entry: SiteDataEntry) -> CGFloat {
        Self.rowHeight + (isOpen(entry.site) ? CGFloat(Self.kinds(of: entry).count) * Self.kindHeight : 0)
    }

    /// Where each box goes, a gap between them.
    private func measure() {
        let shown = entries
        var y: CGFloat = 0
        tops = []
        tops.reserveCapacity(count)
        for index in 0..<count {
            tops.append(y)
            y += boxHeight(shown[index]) + (index < count - 1 ? FoldStyle.gap : 0)
        }
        boxesHeight = y
    }

    func height(for width: CGFloat) -> CGFloat {
        if case .none = messageShown {
            return boxesHeight + (hasFooter ? FoldStyle.gap + footer.height(for: width) : 0)
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
        boxesChanged()
    }

    /// The boxes moved or grew: measured again, and the page told if the list's height changed.
    private func boxesChanged() {
        measure()
        needsLayout = true
        let height = height(for: bounds.width > 0 ? bounds.width : 600)
        let grew = height != lastHeight
        lastHeight = height
        changed?(grew)
        // Laid out now, inside a fold's animation, so the boxes glide to their places with the page.
        layoutSubtreeIfNeeded()
    }

    // MARK: Boxes for what's in view

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
        footer.frame = NSRect(x: 0, y: boxesHeight + FoldStyle.gap, width: bounds.width, height: footer.height(for: bounds.width))
        for (index, row) in visible { place(row, at: index) }
        tile()
    }

    /// The box at or after `y`: the first whose bottom is past it.
    private func index(atOrAfter y: CGFloat) -> Int {
        var low = 0, high = tops.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + boxHeight(entries[mid]) < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The boxes in view (and a little past) made or reused; the rest put back for later.
    private func tile() {
        guard message.isHidden, count > 0, tops.count == count else {
            visible.values.forEach(recycle)
            visible = [:]
            return
        }
        let area = visibleRect.insetBy(dx: 0, dy: -Self.overscan)
        guard !area.isEmpty else { return }
        let first = index(atOrAfter: area.minY)
        var last = first
        while last + 1 < count, tops[last + 1] <= area.maxY { last += 1 }
        guard first < count else { visible.values.forEach(recycle); visible = [:]; return }
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
            // A box taken from the pool starts in its place, not gliding there from where it was last.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                place(row, at: index)
                row.layoutSubtreeIfNeeded()
            }
        }
    }

    private func makeRow() -> SiteDataRow {
        let row = SiteDataRow(frame: NSRect(x: 0, y: 0, width: bounds.width, height: Self.rowHeight))
        row.onRemove = { [weak self, weak row] in
            guard let self, let entry = row.flatMap({ row in self.entries.first { $0.site == row.site } }) else { return }
            self.onRemove?(entry)
        }
        row.onClear = { [weak self, weak row] kind in
            guard let self, let entry = row.flatMap({ row in self.entries.first { $0.site == row.site } }) else { return }
            self.onClear?(entry, kind)
        }
        row.onToggle = { [weak self, weak row] open in
            guard let self, let site = row?.site else { return }
            self.setOpen(site, open)
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
        guard tops.indices.contains(index) else { return }
        let frame = NSRect(x: 0, y: tops[index], width: bounds.width, height: boxHeight(entries[index]))
        if row.frame != frame { row.frame = frame }
    }

    private func configure(_ row: SiteDataRow, at index: Int) {
        let entry = entries[index]
        row.show(entry, words: model?.words ?? [], icon: icon(for: entry.site), open: isOpen(entry.site))
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

    /// The page scrolled under a still pointer: the box under it now is the hovered one.
    private func followPointer() {
        guard let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) { hover(at: point) } else { hovered = nil }
    }

    private func hover(at point: NSPoint) {
        guard message.isHidden, point.y >= 0, bounds.contains(point), !tops.isEmpty else { hovered = nil; return }
        let index = index(atOrAfter: point.y)
        hovered = index < count && tops[index] <= point.y ? index : nil
    }

    private func refreshHover(_ index: Int) { visible[index]?.isHovered = index == hovered }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visible.values.forEach { $0.needsLayout = true }
    }

    #if DEBUG
    /// How many box views exist, in view and kept for reuse.
    var debugRowViews: Int { visible.count + pool.count }
    var debugExpanded: Bool { showsAll }
    var debugListed: Int { count }
    /// The box views in view, top to bottom.
    var debugRows: [SiteDataRow] { visible.sorted { $0.key < $1.key }.map(\.value) }
    #endif
}

/// One site's box in `SiteDataList`, reused for another site as the list scrolls: its header, and opened, a row
/// for each kind of what it keeps with Clear… on it.
final class SiteDataRow: NSView {
    var site: String?
    var onRemove: (() -> Void)?
    var onClear: ((WebsiteData.Kind) -> Void)?
    var onToggle: ((Bool) -> Void)?
    var icon: NSImage? {
        didSet {
            iconView.image = icon ?? SettingsIcon.symbol("globe")
            iconView.imageScaling = icon == nil ? .scaleNone : .scaleProportionallyUpOrDown
        }
    }
    var isHovered = false { didSet { if isHovered != oldValue { refreshDelete() } } }
    /// Open, its kinds showing; folding, they stay until the box has closed over them (`settle`).
    var isOpen = false {
        didSet {
            guard oldValue != isOpen else { return }
            if !isOpen { holdsKinds = true }
            header.isOpen = isOpen
            needsLayout = true
        }
    }
    private var holdsKinds = false

    private let headerContent = FlippedView()
    private(set) lazy var header = FoldHeader(content: headerContent)
    private let iconView = NSImageView()
    private let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let size = Label("", font: Tokens.Font.figures(Tokens.Font.detail().pointSize), color: Tokens.Color.textSecondary)
    private let remove = IconButton(symbol: "trash", size: .compact)
    /// Cookies and cache, each a row with Clear… and the hairline over it.
    private var kindRows: [(kind: WebsiteData.Kind, row: FormRow, clear: PillButton, line: ColorView)] = []
    private var kinds: [WebsiteData.Kind] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconView.contentTintColor = Tokens.Color.icon
        size.alignment = .right
        remove.onClick = { [weak self] _ in self?.onRemove?() }
        remove.keyboardFocusChanged = { [weak self] _ in self?.refreshDelete() }
        [iconView, title, detail, size, remove].forEach(headerContent.addSubview)
        addSubview(header)
        header.onToggle = { [weak self] open in self?.onToggle?(open) }
        for kind in [WebsiteData.Kind.cookies, .cache] {
            let clear = PillButton(title: String(localized: "Clear…", comment: "Button on a kind of data in a site's box in Settings › Privacy › Stored by Websites: clears it for that site, after asking."))
            clear.onClick = { [weak self] _ in self?.onClear?(kind) }
            let row = FormRow(title: "", control: clear)
            row.isIndented = true
            let line = ColorView(color: Tokens.Color.separator)
            addSubview(line)
            addSubview(row)
            kindRows.append((kind, row, clear, line))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        refreshDelete()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { FoldStyle.paint(self) }

    func show(_ entry: SiteDataEntry, words: [String], icon: NSImage?, open: Bool) {
        site = entry.site
        self.icon = icon
        let styled = NSMutableAttributedString(string: entry.site, attributes: [.font: Tokens.Font.row(), .foregroundColor: Tokens.Color.textPrimary])
        // What the search matched, a step bolder: the rest of the name stays as it is.
        for range in SiteDataListing.matchRanges(of: words, in: entry.site) { styled.addAttribute(.font, value: Tokens.Font.row(.semibold), range: range) }
        title.attributedStringValue = styled
        detail.stringValue = Self.describe(entry.kinds)
        size.stringValue = entry.size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? ""
        remove.toolTip = String(localized: "Remove Data for \(entry.site)…", comment: "Tooltip and VoiceOver name of the trash on a site's row in Settings › Privacy › Stored by Websites; the site, like apple.com.")
        kinds = SiteDataList.kinds(of: entry)
        for item in kindRows {
            switch item.kind {
            case .cookies:
                item.row.titleText = Self.describe(entry.kinds.intersection([.cookies, .saved]))
                item.clear.setAccessibilityLabel(String(localized: "Clear Cookies for \(entry.site)…", comment: "VoiceOver name of Clear… on the cookies row in a site's box in Settings › Privacy › Stored by Websites; the site, like apple.com."))
            case .cache:
                item.row.titleText = Self.describe(.cache)
                item.clear.setAccessibilityLabel(String(localized: "Clear Cache for \(entry.site)…", comment: "VoiceOver name of Clear… on the cache row in a site's box in Settings › Privacy › Stored by Websites; the site, like apple.com."))
            }
        }
        let label = [entry.site, detail.stringValue, size.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
        header.setAccessibilityLabel(label)
        setAccessibilityLabel(label)
        holdsKinds = false
        isOpen = open
        header.isOpen = open
        needsLayout = true
    }

    /// The box has closed over its kinds: they go, so neither Tab nor VoiceOver lands on what's folded.
    func settle() {
        guard holdsKinds else { return }
        holdsKinds = false
        needsLayout = true
    }

    private func refreshDelete() {
        RowDelete.apply(remove, shows: RowDelete.shows(hovered: isHovered, focused: remove.hasKeyboardFocus, voiceOver: RowDelete.voiceOver))
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Page.groupPad, side = Tokens.Metric.favicon
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SiteDataList.rowHeight)
        let h = SiteDataList.rowHeight, w = max(0, bounds.width - FoldStyle.chevronRoom)
        iconView.frame = NSRect(x: pad, y: round((h - side) / 2), width: side, height: side)
        let b = Tokens.Metric.compactIconButton
        remove.frame = NSRect(x: w - pad - b + Tokens.Space.x1, y: round((h - b) / 2), width: b, height: b)
        let sizeWidth: CGFloat = size.stringValue.isEmpty ? 0 : size.textWidth
        size.frame = NSRect(x: remove.frame.minX - Tokens.Space.x2 - sizeWidth, y: size.centeredY(in: h), width: sizeWidth, height: size.lineHeight)
        let x = pad + side + Tokens.Space.x3
        let width = max(0, size.frame.minX - Tokens.Space.x4 - x) + Label.inset * 2
        let block = title.lineHeight + 2 + detail.lineHeight
        let top = round((h - block) / 2)
        title.frame = NSRect(x: x - Label.inset, y: top, width: width, height: title.lineHeight)
        detail.frame = NSRect(x: x - Label.inset, y: title.frame.maxY + 2, width: width, height: detail.lineHeight)
        // Its kinds under the header while open, each under a hairline that starts where the text does.
        var y = h
        let showing = isOpen || holdsKinds
        var children: [Any] = [header, remove]
        for item in kindRows {
            let shown = showing && kinds.contains(item.kind)
            item.row.isHidden = !shown
            item.line.isHidden = !shown
            guard shown else { continue }
            item.line.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - pad), height: Tokens.Metric.hairline)
            item.row.frame = NSRect(x: 0, y: y, width: max(0, bounds.width - FoldStyle.chevronRoom), height: SiteDataList.kindHeight)
            y += SiteDataList.kindHeight
            children.append(item.clear)
        }
        setAccessibilityChildren(children)
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
        // Outlined and rounded, like every page's search.
        search.isOutlined = true
        search.isPill = true
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
