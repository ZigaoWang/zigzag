import AppKit
import WebKit

// MARK: - Groups of rows

/// A group of rows on the page: plain rows on the page's surface with hairlines between them, starting where their
/// text does. No card behind them.
final class FormGroup: NSView {
    private(set) var rows: [NSView] = []
    private var lines: [NSView] = []
    private let background = ColorView(color: Tokens.Color.surfaceGroup)
    /// Shared width so the row menus' left edges line up.
    private let dropdowns = DropdownWidthGroup()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // No card: the rows sit on the page itself, a hairline between them. Space and type do the grouping.
        background.isHidden = true
        addSubview(background)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func add(_ row: NSView) {
        if !rows.isEmpty {
            let line = ColorView(color: Tokens.Color.separator)
            lines.append(line)
            addSubview(line)
        }
        rows.append(row)
        addSubview(row)
        // Menus nested in a row's stack (beside a ×) still join the group.
        func addMenus(_ view: NSView) {
            if let menu = view as? DropdownButton { dropdowns.add(menu) }
            view.subviews.forEach(addMenus)
        }
        if let control = (row as? FormRow)?.control { addMenus(control) }
        // A row added to a group already on the page takes the group's width at its next layout.
        needsLayout = true
    }

    func removeAllRows() {
        (rows + lines).forEach { $0.removeFromSuperview() }
        rows = []
        lines = []
    }

    /// Keep the focused row and its controls attached when rules change order.
    func setRows(_ ordered: [NSView]) {
        let kept = Set(ordered.map(ObjectIdentifier.init))
        for row in rows where !kept.contains(ObjectIdentifier(row)) { row.removeFromSuperview() }
        rows = ordered
        setAccessibilityChildren(ordered)
        setAccessibilityChildrenInNavigationOrder(ordered)
        let needed = max(0, ordered.count - 1)
        while lines.count > needed { lines.removeLast().removeFromSuperview() }
        while lines.count < needed {
            let line = ColorView(color: Tokens.Color.separator)
            lines.append(line)
            addSubview(line)
        }
        for row in ordered where row.superview !== self { addSubview(row) }
        needsLayout = true
    }

    func fittingHeight(for width: CGFloat) -> CGFloat { rows.filter { !$0.isHidden }.map { rowHeight($0, width) }.reduce(0, +) }

    /// Shows only the rows that have every word of a search (all of them when `names`, its heading or its pane,
    /// has them, or there are no words). Returns how many show.
    @discardableResult
    func filter(_ words: [String], names: [String] = []) -> Int {
        func has(_ text: String) -> Bool { words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        let all = words.isEmpty || has(names.joined(separator: " "))
        for row in rows {
            // A row that's off for now (the custom search address, until Custom is chosen) stays hidden whatever matches.
            let available = (row as? FormRow)?.isAvailable ?? true
            let named = all || has((row as? SettingsSearchable)?.searchText ?? "")
            // A list searched inside (the sites keeping data): found by its own words, it shows whole; else it
            // shows what in it matches, if anything does.
            if let list = row as? SettingsFilteredRow {
                let some = list.find(named ? [] : words)
                row.isHidden = !available || !(named || some)
                continue
            }
            row.isHidden = !available || !named
        }
        needsLayout = true
        return rows.filter { !$0.isHidden }.count
    }

    private func rowHeight(_ row: NSView, _ width: CGFloat) -> CGFloat {
        (row as? FormRow)?.height(for: width) ?? (row as? SettingsSizedRow)?.height(for: width) ?? row.frame.height
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layer?.borderColor = background.cgColor(Tokens.Color.surfaceGroupEdge)
        var y: CGFloat = 0
        let shown = rows.filter { !$0.isHidden }
        // A line between each two rows shown, the rest hidden. Each is only told when that changes: hidden and shown
        // again, it would fade out and in when the page changes size inside an animation.
        for (i, line) in lines.enumerated() where line.isHidden != (i >= shown.count - 1) { line.isHidden.toggle() }
        for (i, row) in shown.enumerated() {
            let h = rowHeight(row, bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
            if i < shown.count - 1 {
                // The hairline starts where the text does, past any picture, and runs to the group's edge.
                let x = (row as? FormRow)?.textInset ?? (row as? SpaceSettingsRow)?.textInset ?? Tokens.Page.groupPad
                lines[i].frame = NSRect(x: x, y: y, width: bounds.width - x - Tokens.Page.groupPad, height: Tokens.Metric.hairline)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// What a group lists when its rows are read a moment after they're asked for (from disk, from WebKit). The group is
/// read and filled again only when what it lists changes: asked again for the same, its rows stay as they are, so
/// they never go and come back while you look at them.
nonisolated struct GroupListing<Key: Equatable> {
    /// What the group's rows are of.
    private(set) var shown: Key?
    /// What's being read for it, to take its rows' place once it's in.
    private(set) var reading: Key?

    /// Whether rows for `key` have to be read: not while they're showing, or already being read.
    mutating func needs(_ key: Key) -> Bool {
        guard key != shown, key != reading else { return false }
        reading = key
        return true
    }

    /// The rows read for `key` are in. False when something else has been asked for since: they're dropped.
    mutating func arrived(_ key: Key) -> Bool {
        guard reading == key else { return false }
        shown = key
        reading = nil
        return true
    }

    /// The group shows `key` now, with nothing to wait for. What was being read is no longer wanted.
    mutating func show(_ key: Key) {
        shown = key
        reading = nil
    }

    /// The group's rows were taken out: whatever is asked for next has to be read.
    mutating func forget() {
        shown = nil
        reading = nil
    }
}

/// A row "Find a setting" can find, by the words it shows.
protocol SettingsSearchable { var searchText: String { get } }

/// A row's delete button (a space's, a profile's, an extension's trash): one rule for all of them. It shows while
/// the row is pointed at or something in it has keyboard focus, and always while VoiceOver is on, which has no
/// pointer to bring it. Hidden, it keeps its place, so nothing in the row moves when it comes; with Full Keyboard
/// Access on it stays in the Tab order, see-through until Tab reaches it.
enum RowDelete {
    static func shows(hovered: Bool, focused: Bool, voiceOver: Bool) -> Bool { hovered || focused || voiceOver }

    static func apply(_ button: NSView, shows: Bool, keyboardAccess: Bool = InteractiveView.keyboardAccess) {
        button.alphaValue = shows ? 1 : 0
        button.isHidden = !shows && !keyboardAccess
    }

    static var voiceOver: Bool { NSWorkspace.shared.isVoiceOverEnabled }
}

/// A row of settings: its name (and a line saying more, which wraps) at the left, its control at the right. Rows grow
/// to fit what they say, so nothing is cut off. A picture goes before the name only where the row is a thing with a
/// face of its own: an extension, a site.
final class FormRow: NSView, SettingsSearchable {
    /// Off for now: hidden, and kept hidden by "Find a setting".
    var isAvailable = true { didSet { isHidden = !isAvailable } }
    /// Its delete button, if it has one, shown by `RowDelete`'s rule.
    private weak var deleteButton: InteractiveView?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false { didSet { if oldValue != isHovered { refreshDelete() } } }
    /// Strips word joiners translations use (开\u{2060}启) so search matches.
    var searchText: String { [title.stringValue, detail.stringValue, keywords].joined(separator: " ").replacingOccurrences(of: "\u{2060}", with: "") }
    /// More words "Find a setting" knows the row by, like its button's.
    var keywords = ""
    /// The line under its title, which can change while it shows (an address, what went wrong).
    var detailText: String {
        get { detail.stringValue }
        set {
            guard detail.stringValue != newValue else { return }
            detail.stringValue = newValue
            detail.isHidden = newValue.isEmpty
            needsLayout = true
        }
    }
    /// Its title, which can change while it shows (a count).
    var titleText: String {
        get { title.stringValue }
        set {
            guard title.stringValue != newValue else { return }
            title.stringValue = newValue
            needsLayout = true
        }
    }
    var titleColor: NSColor {
        get { title.textColor ?? Tokens.Color.textPrimary }
        set { title.textColor = newValue }
    }
    #if DEBUG
    var debugTitle: String { title.stringValue }
    var debugDetail: NSTextField { detail }
    #endif
    private let title = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    let control: NSView

    init(title: String, detail: String? = nil, icon: NSImage? = nil, control: NSView) {
        self.control = control
        self.icon.image = icon
        self.icon.imageScaling = icon?.isTemplate == true ? .scaleNone : .scaleProportionallyUpOrDown
        self.icon.contentTintColor = Tokens.Color.icon
        self.icon.isHidden = icon == nil
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: Tokens.Page.groupRowHeight))
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.font = Tokens.Font.detail()
        self.detail.textColor = Tokens.Color.textSecondary
        self.detail.isSelectable = false
        self.detail.isHidden = (detail ?? "").isEmpty
        [self.icon, self.title, self.detail, control].forEach { addSubview($0) }
        // The row's title names its switch or menu for VoiceOver, which otherwise reads just "checkbox, 1".
        if (control.accessibilityLabel() ?? "").isEmpty { control.setAccessibilityLabel(title) }
        frame.size.height = height(for: frame.width)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The row's trash, in its control: shown on hover, with keyboard focus anywhere in the row, and to VoiceOver.
    /// The stack it's in keeps its room while it's hidden.
    func revealsOnHover(_ button: InteractiveView) {
        deleteButton = button
        (button.superview as? NSStackView)?.detachesHiddenViews = false
        var controls: [InteractiveView] = []
        func collect(_ view: NSView) {
            if let control = view as? InteractiveView { controls.append(control) }
            view.subviews.forEach(collect)
        }
        collect(control)
        for control in controls where control === button || control.keyboardFocusChanged == nil {
            control.keyboardFocusChanged = { [weak self] _ in self?.refreshDelete() }
        }
        refreshDelete()
    }

    private func refreshDelete() {
        guard let deleteButton else { return }
        var focused = false
        func scan(_ view: NSView) {
            if (view as? InteractiveView)?.hasKeyboardFocus == true { focused = true }
            view.subviews.forEach(scan)
        }
        scan(control)
        RowDelete.apply(deleteButton, shows: RowDelete.shows(hovered: isHovered, focused: focused, voiceOver: RowDelete.voiceOver))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard deleteButton != nil else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        if let window, window.isVisible { isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshDelete()
    }

    private let pad = Tokens.Page.groupPad
    /// A picture's side: an extension's icon, a site's favicon.
    private static let iconSide = Tokens.Metric.favicon
    /// Between a row's title and its explanation.
    private static let lineGap: CGFloat = 2

    private var controlSize: NSSize {
        let size = control.fittingSize
        return size.width > 0 ? size : control.intrinsicContentSize
    }

    /// A row about the row above it (a site's permission, under the site): its text starts where that row's does,
    /// past the picture it doesn't have.
    var isIndented = false { didSet { needsLayout = true } }

    /// Where the row's text starts.
    var textInset: CGFloat { icon.isHidden && !isIndented ? pad : pad + Self.iconSide + Tokens.Space.x3 }

    /// Narrow (half of a split, a small window), the control goes under the text instead of squeezing it.
    private func isStacked(_ width: CGFloat, _ control: NSSize) -> Bool {
        control.width > 0 && width - pad - control.width - Tokens.Space.x4 - textInset < Self.minimumTextWidth
    }
    private static let minimumTextWidth: CGFloat = 180

    private func textWidth(for width: CGFloat, _ control: NSSize) -> CGFloat {
        let room = control.width > 0 && !isStacked(width, control) ? control.width + Tokens.Space.x4 : 0
        return max(0, width - pad - room - textInset)
    }

    /// Measured at the layout width including inset; narrower, a line that just fits counts as two and leaves a blank
    /// line.
    private func detailHeight(for width: CGFloat, _ control: NSSize) -> CGFloat {
        detail.isHidden ? 0 : ceil(detail.sizeThatFits(NSSize(width: textWidth(for: width, control) + Label.inset * 2, height: 400)).height)
    }

    private var titleAndGap: CGFloat { title.stringValue.isEmpty ? 0 : title.lineHeight + Self.lineGap }

    /// The height this row needs at `width`.
    func height(for width: CGFloat) -> CGFloat {
        let size = controlSize
        let stack = isStacked(width, size) ? Tokens.Space.x3 + size.height : 0
        guard !detail.isHidden else { return stack > 0 ? Tokens.Page.groupRowPad * 2 + title.lineHeight + stack : Tokens.Page.groupRowHeight }
        return max(Tokens.Page.groupRowHeight, Tokens.Page.groupRowPad * 2 + titleAndGap + detailHeight(for: width, size) + stack)
    }

    override func layout() {
        super.layout()
        let size = controlSize
        let stacked = isStacked(bounds.width, size)
        control.frame = stacked
            ? NSRect(x: textInset, y: bounds.height - Tokens.Page.groupRowPad - size.height, width: min(size.width, bounds.width - textInset - pad), height: size.height)
            : NSRect(x: bounds.width - pad - size.width, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
        if !icon.isHidden {
            let side = Self.iconSide
            icon.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        }
        let x = textInset - Label.inset
        let width = textWidth(for: bounds.width, size) + Label.inset * 2
        let detailHeight = detailHeight(for: bounds.width, size)
        let block = detail.isHidden ? title.lineHeight : titleAndGap + detailHeight
        // A lone title centers its caps, level with the control's text.
        let top = stacked ? Tokens.Page.groupRowPad : detail.isHidden ? title.centeredY(in: bounds.height) : round((bounds.height - block) / 2)
        title.frame = NSRect(x: x, y: top, width: width, height: title.lineHeight)
        detail.frame = NSRect(x: x, y: top + titleAndGap, width: width, height: detailHeight)
    }
}

/// The version of Zigzag you have, at the end of General: a quiet row like the rest, so the page's one brand moment
/// is the wordmark by its title.
enum SettingsVersionRow {
    /// Shows a ready update with Restart instead of Check for Updates…, live.
    static func make() -> FormRow {
        let update = PillButton(title: checkTitle)
        update.onClick = { _ in Updater.shared.checkForUpdates() }
        let row = FormRow(title: "Zigzag", detail: "", control: update)
        row.keywords = String(localized: "check for updates", comment: "Words that find the version row with Find a setting in Settings. Not shown.")
        let refresh = { [weak row, weak update] in
            guard let row, let update else { return }
            let ready = Updater.shared.readiness.staged?.version
            row.detailText = detail(ready: ready, coming: Updater.shared.activity)
            update.title = ready == nil ? checkTitle
                : String(localized: "Restart", comment: "Button that restarts Zigzag into an update that's ready: on the sidebar's update card, in a toast and in Settings › General.")
        }
        refresh()
        // Lives as long as the row.
        objc_setAssociatedObject(row, &watchKey, Updater.changed.observe { refresh() }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return row
    }

    /// The version, plus the ready or downloading one, as the update card says.
    static func detail(ready: String?, coming: UpdateCardState? = nil) -> String {
        let version = VersionName.display(VersionName.running)
        switch coming {
        case .downloading(let new, _, _):
            return String(localized: "Downloading version \(VersionName.display(new))…",
                          comment: "Under Zigzag's name in Settings › General while an update you asked for downloads. The placeholder is the new version.")
        case .preparing(let new):
            return String(localized: "Preparing version \(VersionName.display(new))…",
                          comment: "Under Zigzag's name in Settings › General once an update has downloaded, while it's unpacked and checked. The placeholder is the new version.")
        default: break
        }
        guard let ready = ready.map(VersionName.display) else { return String(localized: "Version \(version)", comment: "Zigzag's version, in Settings › General.") }
        return String(localized: "Version \(ready) is ready to install. You have \(version).",
                      comment: "Under Zigzag's name in Settings › General while an update is ready, beside Restart. The placeholders are the new version and the one running.")
    }

    private static var checkTitle: String { String(localized: "Check for Updates…", comment: "Button in Settings › General, beside Zigzag's version.") }
    private static var watchKey = 0

    /// Betas first, for those who want to try new versions on their own tabs and data.
    static func betas() -> FormRow {
        let toggle = Toggle(isOn: Updater.getsBetas)
        toggle.onChange = { on in Updater.getsBetas = on }
        let row = FormRow(title: String(localized: "Beta updates", comment: "A setting in Settings › General."),
                          detail: String(localized: "A beta can break.", comment: "Explanation under “Beta updates” in Settings › General."),
                          control: toggle)
        row.keywords = String(localized: "beta channel prerelease", comment: "Words that find the Beta updates setting with Find a setting in Settings. Not shown.")
        return row
    }

    /// Your data as it was before the last update, put back. Only there when a backup is.
    static func restore() -> FormRow? {
        guard let date = UpdateBackup.latestDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Words.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        let saved = formatter.string(from: date)
        var detail = String(localized: "Saved \(saved)", comment: "Under “Restore from before the last update” in Settings › General: when the backup was made.")
        if let name = UpdateBackup.latest?.lastPathComponent, let space = name.firstIndex(of: " ") {
            let version = String(name[name.index(after: space)...])
            detail = String(localized: "Saved \(saved), before updating from \(version)",
                            comment: "Under “Restore from before the last update” in Settings › General: when the backup was made, and the version updated from.")
        }
        let button = PillButton(title: String(localized: "Restore…", comment: "Button in Settings › General that restores the backup from before the last update."))
        button.onClick = { [weak button] _ in
            guard let host = button?.window?.contentView else { return }
            ConfirmSheet.show(in: host, title: String(localized: "Restore from before the last update?", comment: "Title of the sheet that restores the backup."),
                              message: String(localized: "Your spaces, tabs, favorites and history go back to how they were before the last update, and Zigzag restarts. Logins and passwords aren’t affected.",
                                              comment: "Message of the sheet that restores the backup."),
                              confirmTitle: String(localized: "Restore and Restart", comment: "Button of the sheet that restores the backup.")) { confirmed in
                if confirmed { UpdateBackup.restoreLatestAndRelaunch() }
            }
        }
        let row = FormRow(title: String(localized: "Restore from before the last update", comment: "A setting in Settings › General."), detail: detail, control: button)
        row.keywords = String(localized: "backup undo update rollback", comment: "Words that find the restore row with Find a setting in Settings. Not shown.")
        return row
    }
}

/// A symbol in a settings row, where a picture is missing (a site with no favicon): the app's icon color.
enum SettingsIcon {
    static func symbol(_ name: String) -> NSImage {
        let image = Tokens.Symbol.image(name, size: Tokens.Symbol.row)
        image.isTemplate = true
        return image
    }
}

/// Settings › Extensions: where an extension may read and change pages, Chrome's three choices, in rows under its own
/// (#324). The same answers as Site Access in its menu by the address.
enum ExtensionSiteAccessRows {
    static let choices: [ExtensionInstalls.SiteAccess] = [.all, .click, .sites]

    static func title(_ access: ExtensionInstalls.SiteAccess) -> String {
        switch access {
        case .all: String(localized: "On All Sites", comment: "Site Access choice: the extension works on every site.")
        case .click: String(localized: "On Click", comment: "Site Access choice: the extension works on a site only after its button is clicked.")
        case .sites: String(localized: "On Specific Sites", comment: "Site Access choice in Settings › Extensions: the extension works only on the sites listed under it.")
        }
    }

    /// The Site access row, then each listed site with its ×. `changed` hears the site that changed, nil for all.
    static func make(id: String, name: String, installs: ExtensionInstalls, add: @escaping () -> Void, changed: @escaping (String?) -> Void) -> [FormRow] {
        let access = installs.siteAccess(id)
        let sites = access == .sites ? installs.accessSites(id) : []
        let menu = DropdownButton()
        menu.options = choices.map { DropdownButton.Option(title: title($0)) }
        menu.selectedIndex = choices.firstIndex(of: access) ?? 0
        menu.setAccessibilityLabel(String(localized: "Site access for \(name)", comment: "VoiceOver name of the Site access menu in Settings › Extensions. The placeholder is the extension's name."))
        menu.onSelect = { index in
            guard choices.indices.contains(index), choices[index] != installs.siteAccess(id) else { return }
            installs.chooseSiteAccess(id, choices[index])
            changed(nil)
        }
        var controls: [NSView] = [menu]
        if access == .sites {
            let addButton = PillButton(title: String(localized: "Add Site…", comment: "Button beside Site access in Settings › Extensions, with On Specific Sites chosen: opens the sheet that adds a site the extension may use."))
            addButton.onClick = { _ in add() }
            controls.insert(addButton, at: 0)
        }
        let stack = NSStackView(views: controls)
        stack.spacing = Tokens.Space.x2
        let note = access == .sites && sites.isEmpty
            ? String(localized: "It runs on no site until you add one.", comment: "Under Site access in Settings › Extensions, when On Specific Sites is chosen and no site is listed yet.") : nil
        let row = FormRow(title: String(localized: "Site access", comment: "A setting under an extension in Settings › Extensions: which sites the extension may read and change."),
                          detail: note, control: stack)
        row.isIndented = true
        row.keywords = name
        return [row] + sites.map { site in
            let remove = IconButton(symbol: "xmark", size: .compact,
                                    toolTip: String(localized: "Remove \(site)", comment: "VoiceOver name of the Remove button on a row in Settings › Developer: a site, like localhost, or a page size, like iPhone."))
            remove.onClick = { _ in
                installs.removeAccessSite(id, site)
                changed(site)
            }
            let row = FormRow(title: site, control: remove)
            row.isIndented = true
            row.keywords = name
            return row
        }
    }

    /// Asks for a site the extension may use, and adds it.
    @discardableResult
    static func addSite(id: String, name: String, installs: ExtensionInstalls, in host: NSView, added: @escaping (String) -> Void) -> FormSheet {
        let field = FilledField(placeholder: "github.com")
        return FormSheet.show(in: host, title: String(localized: "Add a Site for \(name)", comment: "Title of the sheet that adds a site an extension may use, from Settings › Extensions. The placeholder is the extension's name."), symbol: "globe",
                              message: String(localized: "It can read and change pages on this site and its subdomains.", comment: "Under the title of the sheet that adds a site an extension may use, from Settings › Extensions."),
                              rows: [FormSheet.Row(label: nil, view: field)],
                              confirmTitle: String(localized: "Add", comment: "Button that adds the site, in the sheet that adds a site an extension may use."),
                              canConfirm: { [weak field] in SiteRoutes.entry(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let site = SiteRoutes.entry(from: field.stringValue) else { return }
            installs.addAccessSite(id, site)
            added(site)
        }
    }
}

/// Settings › Extensions: whether an extension runs in private windows too, off until you turn it on (#353).
enum ExtensionPrivateRow {
    static func make(id: String, name: String, installs: ExtensionInstalls) -> FormRow {
        let toggle = Toggle(isOn: installs.allowsPrivate(id))
        toggle.setAccessibilityLabel(String(localized: "Allow \(name) in private windows", comment: "VoiceOver name of the switch that lets an extension run in private windows, in Settings › Extensions. The placeholder is the extension's name."))
        toggle.onChange = { on in installs.setAllowsPrivate(id, on) }
        let row = FormRow(title: String(localized: "Allow in private windows", comment: "A setting under an extension in Settings › Extensions: whether it runs in private windows too. Off at first."),
                          control: toggle)
        row.isIndented = true
        let words = String(localized: "incognito private browsing", comment: "Words that find an extension's Allow in private windows setting with Find a setting in Settings. Not shown.")
        row.keywords = "\(name) \(words)"
        return row
    }
}

// MARK: - A row that can be dragged

/// A draggable group row. `FormRow`s are plain views, so the row sits inside this one, which is the drag surface; its
/// controls keep their clicks (`InteractiveView`'s hit test).
final class DraggableRow: InteractiveView, SettingsSizedRow, SettingsSearchable {
    /// The row it carries.
    let row: NSView
    var searchText: String { (row as? SettingsSearchable)?.searchText ?? "" }
    /// While dragged, drawn as a card above the others, like a dragged space row.
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    init(_ row: NSView) {
        self.row = row
        super.init(frame: row.frame)
        addSubview(row)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        (row as? FormRow)?.height(for: width)
            ?? (row as? SettingsSizedRow)?.height(for: width)
            ?? row.frame.height
    }

    override func layout() {
        super.layout()
        row.frame = bounds
    }

    override func resetCursorRects() { if isLifted { addCursorRect(bounds, cursor: .closedHand) } }

    override func stateDidChange(animated: Bool) {
        // No fill at rest, like other Settings rows; a solid card while dragged.
        layer?.backgroundColor = isLifted ? cgColor(Tokens.Color.surfaceGroup) : nil
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowOpacity = isLifted ? 1 : 0
        layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
        layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
        layer?.borderWidth = isLifted ? Tokens.Metric.hairline : 0
        layer?.borderColor = cgColor(Tokens.Color.surfaceGroupEdge)
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Spaces list

/// A space in Settings: its color (click to change), its name (edit in place), delete on hover, drag to reorder.
final class SpaceSettingsRow: InteractiveView, SettingsSearchable {
    var searchText: String { name.stringValue + " " + detail.stringValue }
    let spaceID: UUID
    /// Its color as a tile with its first letter, the same size and shape as the icons on every other row.
    private let tile = NSImageView()
    private let name: Label
    private let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let editButton = PillButton(title: String(localized: "Edit…", comment: "Button on a space's row in Settings › Spaces: opens its editor."))
    private let deleteButton = IconButton(symbol: "trash", size: .compact,
                                          toolTip: String(localized: "Delete Space", comment: "Tooltip of the trash button on a space's row in Settings › Spaces."))
    /// True while the row is being dragged; it draws as lifted.
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    /// True while any space is carried: rows sliding under the pointer don't count as hovered.
    static var isReordering = false

    init(space: SpaceInfo) {
        spaceID = space.id
        name = Label(space.name, font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        tile.image = Self.tile(for: space)
        detail.stringValue = Self.summary(of: space)
        RowDelete.apply(deleteButton, shows: false)
        deleteButton.isEnabled = Library.shared.spaces.count > 1
        [tile, name, detail, deleteButton, editButton].forEach { addSubview($0) }
        // The row and its Edit button both open the same editor the sidebar uses.
        onClick = { [weak self] _ in self?.openEditor() }
        onRightClick = { [weak self] _ in self?.actionsMenu() }
        editButton.onClick = { [weak self] _ in self?.openEditor() }
        // Every row has an Edit: VoiceOver says which space it edits.
        editButton.setAccessibilityLabel(String(localized: "Edit “\(space.name)”", comment: "VoiceOver label of the Edit button on a space's row in Settings › Spaces; the space's name."))
        deleteButton.onClick = { [weak self] _ in
            guard let self, let host = self.host else { return }
            SpaceSettingsRow.confirmDelete(self.spaceID, in: host)
        }
        deleteButton.keyboardFocusChanged = { [weak self] _ in self?.stateDidChange(animated: false) }
        editButton.keyboardFocusChanged = { [weak self] _ in self?.stateDidChange(animated: false) }
        setAccessibilityRole(.row)
        setAccessibilityLabel(space.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Between the name and the line under it, as in every other row.
    private static let lineGap: CGFloat = 2
    /// As tall as any other row with a line under its name (a profile's), so the two lists read alike.
    private static var height: CGFloat {
        let name = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
        return max(Tokens.Page.groupRowHeight, Tokens.Page.groupRowPad * 2 + name.lineHeight + lineGap + detail.lineHeight)
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Page.groupPad
        let d = Tokens.Metric.favicon
        tile.frame = NSRect(x: pad, y: (bounds.height - d) / 2, width: d, height: d)
        let ew = editButton.fittingWidth, eh = Tokens.Page.controlHeight
        editButton.frame = NSRect(x: bounds.width - pad - ew, y: (bounds.height - eh) / 2, width: ew, height: eh)
        let b = deleteButton.frame.width
        deleteButton.frame.origin = NSPoint(x: editButton.frame.minX - Tokens.Space.x2 - b, y: (bounds.height - b) / 2)
        let x = tile.frame.maxX + Tokens.Space.x3 - Label.inset
        // The name has the room up to Edit while Delete isn't showing: a narrow page cuts it short only on hover.
        let end = deleteButton.alphaValue > 0 ? deleteButton.frame.minX : editButton.frame.minX
        let width = max(0, end - x - Tokens.Space.x2)
        let top = round((bounds.height - name.lineHeight - Self.lineGap - detail.lineHeight) / 2)
        name.frame = NSRect(x: x, y: top, width: width, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: name.frame.maxY + Self.lineGap, width: width, height: detail.lineHeight)
        // The lifted row's shadow has a set shape: without one, it's worked out from the row's contents on every frame
        // of a drag, which is what made reordering stutter.
        let radius = layer?.cornerRadius ?? 0
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Where the row's text starts, for the divider under it.
    var textInset: CGFloat { Tokens.Page.groupPad + Tokens.Metric.favicon + Tokens.Space.x3 }

    private static func tile(for space: SpaceInfo) -> NSImage { tile(name: space.name, swatch: space.swatch, icon: space.icon) }

    /// A color as a tile with a name's first letter, or an icon: a space's, and a profile's.
    static func tile(name: String, swatch: NSColor, icon: String?) -> NSImage {
        let side = Tokens.Metric.favicon
        let letter = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? ""
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let radius = Tokens.Radius.control
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let base = swatch.usingColorSpace(.sRGB) ?? swatch
            NSGradient(starting: base.highlight(withLevel: 0.12) ?? base, ending: base)?.draw(in: shape, angle: -90)
            // A fine edge, so a white or pale space still shows its tile.
            Tokens.Color.keyCapEdge.setStroke()
            let half = Tokens.Metric.hairline / 4
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: half, dy: half), xRadius: radius - half, yRadius: radius - half)
            edge.lineWidth = Tokens.Metric.hairline / 2
            edge.stroke()
            // White on a color, dark on a pale one.
            let ink = Tokens.Color.ink(on: base)
            // Its icon if it has one, white on the color like the letter; an emoji in its own colors.
            if let icon {
                let image = IconChoice.image(icon, size: Tokens.Symbol.inline)
                let size = image.size
                let spot = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
                if IconChoice.isSymbol(icon), let tinted = image.copy() as? NSImage {
                    tinted.lockFocus()
                    ink.set()
                    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
                    tinted.unlockFocus()
                    tinted.draw(in: spot)
                } else {
                    image.draw(in: spot)
                }
                return true
            }
            let text = NSAttributedString(string: letter, attributes: [.font: Tokens.Font.small(.bold), .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            return true
        }
    }

    /// What's in it, said plainly.
    private static func summary(of space: SpaceInfo) -> String {
        let pinned = space.bookmarks.count
        let open = BrowserWindowController.undoTarget?.tabManager.tabs(in: space.id).count ?? 0
        let pinnedTabs = String(localized: "\(pinned) pinned tabs", comment: "Under a space's name in Settings › Spaces.")
        let openTabs = String(localized: "\(open) open tabs", comment: "Under a space's name in Settings › Spaces.")
        let holds: String
        switch (pinned, open) {
        case (0, 0): holds = String(localized: "Empty", comment: "Under a space's name in Settings › Spaces: it has no tabs.")
        case (_, 0): holds = pinnedTabs
        case (0, _): holds = openTabs
        default: holds = String(localized: "\(pinnedTabs) and \(openTabs)",
                                comment: "Under a space's name in Settings › Spaces: its pinned tabs, then its open tabs, like “3 pinned tabs and 2 open tabs”.")
        }
        // Which profile it's on, once there's more than one to be on.
        guard Library.shared.hasManyProfiles, let profile = Library.shared.directory.profile(Library.shared.profileID(ofSpace: space.id)) else { return holds }
        return String(localized: "\(holds), in \(profile.displayName)", comment: "Under a space's name in Settings › Spaces, with more than one profile: what the space holds, then the profile it's on, like “3 open tabs, in Work”.")
    }

    private func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(SidebarMenus.Item(String(localized: "Edit Space…", comment: "Item in the menu of a space's row in Settings › Spaces.")) { [weak self] in
            self?.openEditor()
        })
        menu.addItem(SidebarMenus.useDefaultColorsItem(for: spaceID) { BrowserWindowController.changeLibrary($0, $1) })
        if Library.shared.spaces.count > 1 {
            menu.addItem(SidebarMenus.Item(String(localized: "Delete Space…", comment: "Item in the menu of a space's row in Settings › Spaces.")) { [weak self] in
                guard let self, let host = self.host else { return }
                SpaceSettingsRow.confirmDelete(self.spaceID, in: host)
            })
        }
        return menu
    }

    override func resetCursorRects() { if isLifted { addCursorRect(bounds, cursor: .closedHand) } }

    override func stateDidChange(animated: Bool) {
        // Delete as on every row with one (`RowDelete`), never while the row is carried.
        let focused = deleteButton.hasKeyboardFocus || editButton.hasKeyboardFocus
        let showsDelete = RowDelete.shows(hovered: isHovered, focused: focused, voiceOver: RowDelete.voiceOver) && !isLifted && !Self.isReordering
        RowDelete.apply(deleteButton, shows: showsDelete, keyboardAccess: InteractiveView.keyboardAccess && !isLifted)
        needsLayout = true
        // At rest a space reads like every other row in Settings: no fill of its own. Carried, it's a card above
        // the others, solid at once so nothing shows through it.
        layer?.backgroundColor = isLifted ? cgColor(Tokens.Color.surfaceGroup) : nil
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowOpacity = isLifted ? 1 : 0
        layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
        layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
        layer?.borderWidth = isLifted ? Tokens.Metric.hairline : 0
        layer?.borderColor = cgColor(Tokens.Color.surfaceGroupEdge)
        window?.invalidateCursorRects(for: self)
    }

    /// Settings, in the page it's on: what floats over a row (the editor, a confirmation) stays in that page.
    private var host: NSView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? SettingsView }.first ?? window?.contentView
    }

    func openEditor() {
        guard let host else { return }
        if let open = SpaceEditorPanel.current {
            let same = open.spaceID == spaceID
            open.close()
            if same { return }
        }
        let editor = SpaceEditorPanel(spaceID: spaceID, controller: nil)
        SpaceEditorPanel.current = editor
        editor.show(in: host, below: editButton)
    }

    static func confirmDelete(_ id: UUID, in host: NSView) {
        guard let space = Library.shared.space(id), Library.shared.spaces.count > 1 else { return }
        // The sidebar deletes right away, ⌘Z being right there. Here Undo is in a browser window, or with none open
        // nowhere at all, so it asks first and says which.
        let undoable = BrowserWindowController.undoTarget != nil
        ConfirmSheet.show(in: host, title: String(localized: "Delete “\(space.name)”?", comment: "Title of the sheet that deletes a space from Settings; the space's name."),
                          message: undoable
                              ? String(localized: "Its tabs and pinned tabs close. You can bring them back with Undo in a browser window.",
                                       comment: "Message of the sheet that deletes a space from Settings.")
                              : String(localized: "Its tabs and pinned tabs close. This can’t be undone.", comment: "Message of the sheet that deletes a space from Settings."),
                          confirmTitle: String(localized: "Delete Space", comment: "Button of the sheet that deletes a space from Settings."),
                          destructive: true) { confirmed in
            guard confirmed else { return }
            if let controller = BrowserWindowController.undoTarget { controller.removeSpaceWithUndo(id) } else { Library.shared.removeSpace(id) }
        }
    }
}

// MARK: - The page

/// The parts of Settings, each a pane of its own, picked from the column of sections at the left. The raw value is
/// its name in the page's address (zigzag://settings/privacy), which a tab keeps with the session: a pane can be
/// added anywhere in the column, but a name never changes.
enum SettingsPane: String, CaseIterable {
    case general, downloads, appearance, tabs, spaces, profiles, search, mini, translation, passwords, privacy
    case websiteData = "website-data"
    case extensions, shortcuts, automation, developer

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "A section of Settings.")
        case .downloads: String(localized: "Downloads", comment: "A section of Settings: where files go, and rules that hand downloads and links to other apps.")
        case .appearance: String(localized: "Appearance", comment: "A section of Settings: how the window and sidebar look.")
        case .tabs: String(localized: "Tabs", comment: "A section of Settings.")
        case .spaces: String(localized: "Spaces", comment: "A section of Settings.")
        case .profiles: String(localized: "Profiles", comment: "A section of Settings: profiles, each with its own extensions and sign-ins.")
        case .search: String(localized: "Search", comment: "A section of Settings: the search engine and suggestions.")
        case .mini: MiniWindowController.name
        case .passwords: String(localized: "Passwords", comment: "A section of Settings.")
        case .privacy: String(localized: "Privacy", comment: "A section of Settings.")
        case .translation: String(localized: "Translation", comment: "A section of Settings: translating web pages.")
        case .extensions: String(localized: "Extensions", comment: "A section of Settings.")
        case .websiteData: String(localized: "Website Data", comment: "A section of Settings, there with more than one profile: what websites keep on this Mac in the profile chosen, and clearing it.")
        case .shortcuts: String(localized: "Shortcuts", comment: "A section of Settings: keyboard shortcuts.")
        case .automation: String(localized: "Automation", comment: "A section of Settings: AI apps over MCP, and what scripts and Shortcuts may do in Zigzag.")
        case .developer: String(localized: "Developer", comment: "A section of Settings: tools for people who build websites, and the sites they build.")
        }
    }

    /// More words "Find a setting" knows the whole section by.
    var keywords: String {
        switch self {
        case .downloads: String(localized: "aria2 motrix torrent rtorrent yt-dlp mpv iina rule handoff script download", comment: "Words that find Settings › Downloads with Find a setting, separated by spaces. Add your language's words for them. Not shown.")
        case .automation: String(localized: "mcp ai agent automation api", comment: "Words that find Settings › Automation with Find a setting, separated by spaces. Add your language's words for them. Not shown.")
        case .developer: String(localized: "devtools web development localhost", comment: "Words that find Settings › Developer with Find a setting, separated by spaces. Add your language's words for them. Not shown.")
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .appearance: "paintbrush"
        case .tabs: "square.on.square"
        case .spaces: "square.stack"
        case .profiles: "person"
        case .search: "magnifyingglass"
        case .mini: "macwindow"
        case .passwords: "key"
        case .privacy: "hand.raised"
        case .translation: "translate"
        case .extensions: "puzzlepiece.extension"
        case .websiteData: "internaldrive"
        case .shortcuts: "command"
        case .automation: "point.3.connected.trianglepath.dotted"
        case .developer: DeveloperTool.modeSymbol
        }
    }

    /// Its name in the page's address: zigzag://settings/privacy.
    var path: String { rawValue }

    /// The sections that show one profile's things. With a single profile there's nothing to tell apart: Extensions
    /// sits among the others and what Website Data holds stays in Privacy, as before there were profiles.
    static let perProfile: [SettingsPane] = [.extensions, .websiteData]

    /// The column's sections in groups, a small gap between each, as System Settings has them: the browser itself,
    /// finding and reading, what's kept safe, and adding to Zigzag. With more than one profile, the sections about
    /// the profile chosen there follow under their own heading.
    static func columnGroups(manyProfiles: Bool) -> (shared: [[SettingsPane]], profile: [SettingsPane]) {
        let groups: [[SettingsPane]] = [[.general, .downloads, .appearance, .tabs, .spaces, .profiles], [.search, .mini, .translation],
                                        [.passwords, .privacy], [.extensions, .shortcuts, .automation, .developer]]
        guard manyProfiles else { return (groups, []) }
        return (groups.map { $0.filter { !perProfile.contains($0) } }.filter { !$0.isEmpty }, perProfile)
    }

    /// The column's sections: the ones every profile shares, then, with more than one profile, the ones about
    /// the profile chosen there.
    static func column(manyProfiles: Bool) -> (shared: [SettingsPane], profile: [SettingsPane]) {
        let groups = columnGroups(manyProfiles: manyProfiles)
        return (groups.shared.flatMap { $0 }, groups.profile)
    }

    /// The sections that start a group after the first, so the column leaves a gap before each.
    static func groupStarts(manyProfiles: Bool) -> Set<SettingsPane> {
        Set(columnGroups(manyProfiles: manyProfiles).shared.dropFirst().compactMap(\.first))
    }

    /// The heading over the group a section starts, in the column with names beside the symbols.
    static func groupTitle(startingAt pane: SettingsPane) -> String? {
        switch pane {
        case .general: String(localized: "Browser", comment: "A heading in the column of Settings, over General, Appearance, Tabs, Spaces and Profiles.")
        case .search: String(localized: "Tools", comment: "A heading in the column of Settings, over Search, Zigzag Mini and Translation.")
        case .passwords: String(localized: "Privacy & Security", comment: "A heading in the column of Settings, over Passwords and Privacy.")
        case .extensions, .shortcuts: String(localized: "Advanced", comment: "A heading in the column of Settings, over Extensions, Shortcuts, Automation and Developer.")
        default: nil
        }
    }

    /// The sections that have a heading over them: the first of each group.
    static func headed(manyProfiles: Bool) -> [SettingsPane] {
        columnGroups(manyProfiles: manyProfiles).shared.compactMap(\.first).filter { groupTitle(startingAt: $0) != nil }
    }

    /// The section that's shown when this one is asked for: Website Data is part of Privacy until there's a
    /// second profile, so an address kept from when there was one still opens.
    func shown(manyProfiles: Bool) -> SettingsPane { self == .websiteData && !manyProfiles ? .privacy : self }

    /// Where the groups that clear and list what websites keep are.
    static func websiteData(manyProfiles: Bool) -> SettingsPane { manyProfiles ? .websiteData : .privacy }
}

/// One section in the column: a list item, as every list of places in Zigzag draws them.
private final class SectionItem: ListItem {
    let pane: SettingsPane

    init(_ pane: SettingsPane) {
        self.pane = pane
        super.init(title: pane.title, symbol: pane.symbol)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }
}
/// Settings, as a page in a tab (zigzag://settings): the sections in a column at the left, the chosen one filling the
/// rest of the page, built from Zigzag's own controls and laid out as every Zigzag page is (`Tokens.Page`): the
/// wordmark and title at the top left, the search at the top right. It takes whatever width the page has, a whole
/// window or half of a split, and the column folds down to symbols when that gets narrow.
final class SettingsView: NSView, NSTextFieldDelegate {
    private var items: [SectionItem] = []
    /// With more than one profile: over the sections that are about one profile, with the menu that chooses it.
    private let profileHeading = Label.groupHeading(String(localized: "For This Profile", comment: "A heading in the column of Settings, with more than one profile, over the menu that chooses a profile and the sections that show that profile's things."))
    /// Whether the column was built for more than one profile.
    private var columnHasProfiles = false
    /// The sections that start a group in the column, with a gap before each.
    private var groupStarts: Set<SettingsPane> = []
    /// Over each group, in the column with names: what its sections are about.
    private var groupHeadings: [SettingsPane: Label] = [:]
    private let column = FlippedView()
    /// Scrolls the column when a short window can't fit every section in it.
    private let columnScroll = OverlayScrollView()
    /// The column's tint, behind the sections. Its own view, placed by the page's layout: on the sections' document
    /// it was only as large as that, and the document doesn't follow the page while it changes size.
    private let columnWash = ColorView()
    /// The chosen section's fill, gliding to the one you pick.
    private let sectionSelection = SelectionGlide()
    /// The wordmark and "Settings" at the top of the column, where History has its own.
    private let columnTitle = PageTitleView(String(localized: "Settings", comment: "Title of the Settings page, also its tab's name."))
    /// Over the chosen section: its name, and the search at the right, as History's header has them.
    private let header = PageHeader()
    private let paneTitle = PageTitleView("")
    private let columnEdge = ColorView(color: Tokens.Color.separator)
    private let scroll = OverlayScrollView()
    private let documentView = FlippedView()
    private(set) var pane = SettingsPane.general
    /// Finds a setting in any section, at the top right of the page.
    private let settingSearch = FilledField.search(String(localized: "Find a setting", comment: "Placeholder of the search field at the top of Settings."))
    /// You picked another section: the tab's address follows, so the tab comes back to it.
    var onPaneChange: ((SettingsPane) -> Void)?

    private let versionGroup = FormGroup()
    private let generalGroup = FormGroup()
    /// Settings › Downloads: the folder and handoff rules.
    private let downloadPlaceGroup = FormGroup()
    /// Per-extension destinations under Save downloads to. They never cancel a download, so they're kept apart from
    /// handoff rules.
    private let downloadTypesGroup = FormGroup()
    private let addFileTypeButton = PillButton(title: String(localized: "Add File Type…", comment: "Button beside the file types in Settings › Downloads: opens the sheet that makes a per-extension destination."))
    private let downloadPlaceRules = DropdownButton()
    private let downloadRulesGroup = FormGroup()
    private let downloadTestGroup = FormGroup()
    private let downloadRuleTest: FilledField = {
        let field = FilledField(placeholder: String(localized: "https://example.com/file.zip", comment: "Placeholder of the test address in Settings › Downloads: an address to see which rule takes it."))
        // Rows size controls by fitting size: a fixed width that fits an address.
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Tokens.Page.searchWidth).isActive = true
        field.heightAnchor.constraint(equalToConstant: Tokens.Page.controlHeight).isActive = true
        return field
    }()
    private var downloadRuleTestRow: FormRow?
    private let addDownloadRuleButton = PillButton(title: String(localized: "Add Rule…", comment: "Button beside the download rules in Settings › Downloads: opens the menu of actions and presets a new rule can start from."))
    private var downloadRulesToken: SignalToken?
    /// Sites installed as apps, each with Remove. Only there when there's one.
    private let webAppsGroup = FormGroup()
    private var webAppsToken: SignalToken?
    /// Settings › Automation: AI apps, connecting one, and scripts.
    private let aiGroup = FormGroup()
    private let connectGroup = FormGroup()
    private let scriptsGroup = FormGroup()
    /// Settings › Developer (#141): the switch, and the sites you develop on.
    private let developerToolsGroup = FormGroup()
    private let developmentSitesGroup = FormGroup()
    /// The sizes the developer tools offer for a page.
    private let pageSizesGroup = FormGroup()
    private let addSizeButton = PillButton(title: String(localized: "Add Size…", comment: "Button beside Page Sizes in Settings › Developer: opens the sheet that adds a size to the list."))
    private let developerToolsToggle = Toggle()
    private let developerBarToggle = Toggle()
    private let developerTrustToggle = Toggle()
    private let localServersGroup = FormGroup()
    /// Local servers whose certificate you chose to trust for good, with Remove for each.
    private let trustedCertificatesGroup = FormGroup()
    private let trustedCertificatesAddSite = PillButton(title: String(localized: "Add Site…", comment: "Button beside Trusted Certificates in Settings › Developer: opens the sheet that opens a local server so its certificate can be trusted."))
    private let addSiteButton = PillButton(title: String(localized: "Add Site…", comment: "Button beside Sites in Developer Mode in Settings › Developer: opens the sheet that turns Developer Mode on for a site."))
    private var developerToken: SignalToken?
    private var trustedCertificatesToken: SignalToken?
    /// Kept cookies' sites, changed in Site Controls or here (#334).
    private var keptCookiesToken: SignalToken?
    private var sitePermissionsToken: SignalToken?
    /// Clear Cookies…, Add Site… and the quit switch, for the debug bridge.
    private weak var clearCookiesButton: PillButton?
    private weak var addKeptButton: PillButton?
    private weak var clearOnQuitToggle: Toggle?
    /// Settings › Developer › Feature Flags (#173): WebKit's flags, a group for each status, made the first time the
    /// group shows. There only while Developer Mode is on and WebKit lists them.
    private var flagGroups: [FeatureFlags.Status: FormGroup] = [:]
    /// Each flag's row, switch and "Changed", by key, to follow a change made anywhere.
    private var flagControls: [String: (flag: FeatureFlags.Flag, row: FormRow, toggle: Toggle, changed: Label)] = [:]
    private let flagSearch = FilledField.search(String(localized: "Find a flag", comment: "Placeholder of the search field beside Feature Flags in Settings › Developer: finds a WebKit feature flag by its name or key."))
    private let flagsReset = PillButton(title: String(localized: "Reset to Defaults", comment: "Button beside Feature Flags in Settings › Developer: every WebKit feature flag you changed goes back to WebKit's default. Also the button of the sheet that asks first."))
    private let flagsReload = PillButton(title: String(localized: "Reload All Tabs", comment: "Button in Settings › Developer › Feature Flags: reloads every open web page, so changed flags take effect."))
    /// Mature, unstable and internal flags, folded. The fold names its contents, like Effects in the space editor; Show
    /// All is for long lists (Privacy's sites).
    private let flagsMore = DisclosureRow(title: String(localized: "featureflags.more", defaultValue: "More Flags",
                                                        comment: "A folding heading under the feature flags in Settings › Developer: shows WebKit's mature, unstable and internal flags too."))
    private var flagsShowAll = false
    private var flagsToken: SignalToken?
    private var shortcutsToken: SignalToken?
    private let tabsGroup = FormGroup()
    private let searchGroup = FormGroup()
    private let blockingGroup = FormGroup()
    private let spacesGroup = FormGroup()
    /// Whether new spaces get their own profile (#291).
    private let newSpacesGroup = FormGroup()
    private let ownProfileToggle = Toggle()
    /// Sites that always open in a space (#286).
    private let routesGroup = FormGroup()
    private let routeHint = FormRow(title: "", detail: String(localized: "The first enabled match chooses the space. Drag to reorder.", comment: "Byline under Sites in Spaces."),
                                    control: SiteRouteSheet.matchHelpButton())
    private var routeRows: [(id: UUID, row: SiteRouteRow)] = []
    private let profilesGroup = FormGroup()
    private let appearanceGroup = FormGroup()
    private let miniGroup = FormGroup()
    /// Zigzag Mini's shortcut, as the menu has it now.
    private let miniKeys = KeyCaps()
    private let passwordsGroup = FormGroup()
    /// With more than one profile, what fills forms and isn't a profile's has a group of its own.
    private let cardGroup = FormGroup()
    private let passwordsWindowGroup = FormGroup()
    private let privacyGroup = FormGroup()
    private let sitesGroup = FormGroup()
    /// The one master switch for a page reaching an app on this Mac, above the sites' own answers.
    private let localReceiversGroup = FormGroup()
    /// Each site keeping cookies, storage or a cache on this Mac, to remove one at a time (#207): one list, with
    /// rows only for what's in view, and its search and Remove All by its heading.
    private let siteDataGroup = FormGroup()
    private let siteDataList = SiteDataList()
    private let siteDataToolbar = SiteDataToolbar()
    /// Each profile's list as read while Settings is open, so showing it again is instant.
    private var siteDataModels: [UUID: SiteDataModel] = [:]
    /// While the page is laid out: a list that changes height then is measured by that layout already.
    private var isLayingOutDocument = false
    /// Whether sizes were in when the toolbar was last set: Sort shows once they are.
    private var siteDataHadSizes = false
    /// Every site with a choice made for it, not only the first 30.
    private var sitesShowAll = false
    /// Permissions changed here while Settings is open ("origin|permission"): set back to Ask, a row stays, so the
    /// choice you just made doesn't vanish under the pointer.
    private var permissionsChangedHere: Set<String> = []
    /// Reset All beside the Sites heading, there only when something was chosen for a site.
    private var sitesReset: PillButton?
    private var alwaysReset: PillButton?
    private var neverReset: PillButton?
    private let translationGroup = FormGroup()
    private let alwaysGroup = FormGroup()
    private let neverGroup = FormGroup()
    private let extensionsGroup = FormGroup()
    /// Extensions that come inside apps on this Mac (#194), each with Install. Looked for when the page opens.
    private let appExtensionsGroup = FormGroup()
    private var appExtensionsFound: [AppBundledExtensions.Found] = []
    private var appExtensionsTask: Task<Void, Never>?
    private var appExtensionsListing = GroupListing<[String]>()
    /// Extensions another profile has and this one doesn't, each with a way to add it here.
    private let otherProfilesGroup = FormGroup()
    /// What's on disk from a profile that's in no list, to bring back or delete. Only there when there's any.
    private let unlistedGroup = FormGroup()
    private var otherProfilesTask: Task<Void, Never>?
    /// Which profile's missing extensions "In Other Profiles" lists, and which they are.
    private struct OtherProfilesKey: Equatable { let profile: UUID; let ids: [String] }
    private var otherProfilesListing = GroupListing<OtherProfilesKey>()
    /// The IDs "Not Listed" shows data for.
    private var unlistedListing = GroupListing<[UUID]>()
    /// Reloads that are being gathered into one layout (`layingOutOnce`), and whether any of them asked for it.
    private var heldLayouts = 0
    private var layoutIsWanted = false
    private var shortcutGroups: [(String, FormGroup)] = []
    private var listedShortcuts: [String] = []

    private let engine = DropdownButton()
    /// The engines extensions give, listed after Zigzag's own, in the order the menu shows them.
    private var engineProviders: [ExtensionSearchProvider] = []
    /// Your own search address, shown when the engine is Custom.
    private let customSearch: FilledField = {
        let field = FilledField(placeholder: "https://example.com/search?q=%s")
        // Rows size their control by its fitting size: a fixed width, wide enough for a typical address.
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        field.heightAnchor.constraint(equalToConstant: Tokens.Page.controlHeight).isActive = true
        return field
    }()
    private lazy var customSearchRow = FormRow(title: String(localized: "Search address", comment: "A setting in Settings › Search, shown when the search engine is Custom."),
                                               detail: String(localized: "Put %s where the words you search for go.",
                                                              comment: "Explanation under “Search address” in Settings › Search. Keep %s as it is: it's what the address uses."),
                                               control: customSearch)
    private let archiveAfter = DropdownButton()
    private let favoritesPerRow = DropdownButton()
    private let pageZoom = DropdownButton()
    private let sidebarSize = DropdownButton()
    /// The size of your own beside Sidebar size, there while Custom is chosen (#361).
    private let sidebarSizeStepper = ZoomStepper()
    private var sidebarSizeRow: FormRow?
    private let darkPages = DropdownButton()
    private let pureBlackToggle = Toggle()
    private lazy var pureBlackRow: FormRow = {
        let row = FormRow(title: String(localized: "Pure black backgrounds", comment: "A setting in Settings › Appearance, under Dark pages and shown while it's on: darkened websites are black instead of dark gray."),
                          detail: String(localized: "Black, not dark gray.", comment: "Explanation under “Pure black backgrounds” in Settings › Appearance."),
                          control: pureBlackToggle)
        row.keywords = String(localized: "black pure true black oled amoled dark mode", comment: "Words that find the Pure black backgrounds setting with Find a setting in Settings. Not shown.")
        return row
    }()
    private let newTabPlace = DropdownButton()
    private var newTabRow: FormRow!
    private let controlTabOrder = DropdownButton()
    private let pinOfferToggle = Toggle()
    private let nestToggle = Toggle()
    private let shareTabsToggle = Toggle()
    private let swipeToggle = Toggle()
    private let miniToggle = Toggle()
    private let energyToggle = Toggle()
    private let languagePicker = DropdownButton()
    private let launchChoice = DropdownButton()
    private let defaultButton = PillButton(title: String(localized: "Set as Default", comment: "Button in Settings › General that makes Zigzag the default browser."))
    private let defaultStatus = StatusLabel(String(localized: "Zigzag is your default browser", comment: "In Settings › General, in place of Set as Default once it's done."))
    private let blockingToggle = Toggle()
    private let webRTCToggle = Toggle()
    private let javaScript = DropdownButton()
    private let downloadsAskToggle = Toggle()
    private let cookieBanners = DropdownButton()
    private let pipToggle = Toggle()
    private let leavePipToggle = Toggle()
    private let fullScreenFill = DropdownButton()
    private let suggestionsToggle = Toggle()
    private let borderlessToggle = Toggle()
    private let addressAboveToggle = Toggle()
    private let sidebarSide = DropdownButton()
    /// Sidebar position's choices, Left then Right, as whether the sidebar is on the right (#360).
    static let sidebarSides = [false, true]
    private let doubleClickTabToggle = Toggle()
    private var sideToken: NSObjectProtocol?
    private let largeNamesToggle = Toggle()
    private let quitToggle = Toggle()
    private let scriptJavaScriptToggle = Toggle()
    private let aiAppsToggle = Toggle()
    private var aiAppsToken: SignalToken?
    /// The server's address and its key, there while AI apps may use Zigzag.
    private lazy var aiAddressRow: FormRow = {
        let copy = PillButton(title: String(localized: "Copy", comment: "Button that copies something to the clipboard."))
        copy.onClick = { [weak copy] _ in
            Self.copy(MCPService.address)
            copy?.flash(String(localized: "Copied", comment: "Shown on a Copy button for a moment after it copies."))
        }
        let row = FormRow(title: String(localized: "Server address", comment: "A row in Settings › Automation, shown while AI apps may use Zigzag: the MCP server's address, to give an app."),
                          detail: MCPService.address, control: copy)
        row.keywords = Self.aiAppsKeywords
        return row
    }()
    private lazy var aiKeyRow: FormRow = {
        let copy = PillButton(title: String(localized: "Copy Header", comment: "Button in Settings › Automation: copies the Authorization header, with the key, that an AI app sends."))
        copy.onClick = { [weak copy] _ in
            Self.copy(MCPService.authorizationHeader, concealed: true)
            copy?.flash(String(localized: "Copied", comment: "Shown on a Copy button for a moment after it copies."))
        }
        let reset = PillButton(title: String(localized: "Reset Key", comment: "Button in Settings › Automation: makes a new key for AI apps, which disconnects every app using the old one."))
        reset.onClick = { [weak reset] _ in
            MCPService.resetKey()
            reset?.flash(String(localized: "Key Reset", comment: "Shown on the Reset Key button for a moment after it makes a new key."))
        }
        let buttons = NSStackView(views: [copy, reset])
        buttons.spacing = Tokens.Space.x2
        let row = FormRow(title: String(localized: "Key", comment: "A row in Settings › Automation, shown while AI apps may use Zigzag: the secret key an app sends."),
                          detail: String(localized: "Apps send it in the Authorization header. A new key disconnects every app.",
                                         comment: "Explanation under “Key” in Settings › Automation."),
                          control: buttons)
        row.keywords = Self.aiAppsKeywords
        return row
    }()
    /// The setup most MCP apps take as JSON, with the address and key filled in.
    private lazy var aiSetupRow: FormRow = {
        let copy = PillButton(title: String(localized: "Copy Setup", comment: "Button in Settings › Automation › Connect an App: copies the JSON setup, with the address and key, that MCP apps take."))
        copy.onClick = { [weak copy] _ in
            Self.copy(MCPSetup.configuration(address: MCPService.address, token: MCPService.token), concealed: true)
            copy?.flash(String(localized: "Copied", comment: "Shown on a Copy button for a moment after it copies."))
        }
        let row = FormRow(title: String(localized: "Setup", comment: "A row in Settings › Automation › Connect an App: the JSON setup to paste into an AI app."),
                          detail: String(localized: "Paste it where the app adds MCP servers. Most apps take this form.",
                                         comment: "Explanation under “Setup” in Settings › Automation › Connect an App."),
                          control: copy)
        row.keywords = Self.aiAppsKeywords + " json config"
        return row
    }()
    /// A short prompt for an app's chat, so the app connects itself.
    private lazy var aiPromptRow: FormRow = {
        let copy = PillButton(title: String(localized: "Copy Prompt", comment: "Button in Settings › Automation › Connect an App: copies a prompt to paste into an AI app's chat, so it connects to Zigzag."))
        copy.onClick = { [weak copy] _ in
            Self.copy(MCPSetup.prompt(address: MCPService.address, token: MCPService.token), concealed: true)
            copy?.flash(String(localized: "Copied", comment: "Shown on a Copy button for a moment after it copies."))
        }
        let row = FormRow(title: String(localized: "Prompt", comment: "A row in Settings › Automation › Connect an App: a prompt to paste into an AI app's chat."),
                          detail: String(localized: "Or paste this into the app’s chat, and it can set itself up.",
                                         comment: "Explanation under “Prompt” in Settings › Automation › Connect an App."),
                          control: copy)
        row.keywords = Self.aiAppsKeywords
        return row
    }()
    private let motionToggle = Toggle()
    /// Where downloads go: Downloads, another folder, or ask each time.
    private let downloadPlace = DropdownButton()
    private var downloadPlaceToken: SignalToken?
    /// Zigzag or iCloud Passwords for the shown profile (#248).
    private let passwordFiller = DropdownButton()
    private let saveToggle = Toggle()
    private let fillToggle = Toggle()
    private let cardToggle = Toggle()
    private let translateOffer = Toggle()
    private let translateInto = DropdownButton()
    private var languages: [(id: String, name: String)] = []
    private let addSpaceButton = PillButton(title: String(localized: "New Space", comment: "Button beside Your Spaces in Settings › Spaces."))
    private let addRouteButton = PillButton(title: String(localized: "Add Rule…", comment: "Add a space routing rule in Settings."))
    private let addProfileButton = PillButton(title: String(localized: "New Profile…", comment: "Button beside Your Profiles in Settings › Profiles: opens the sheet that makes a profile."))
    private let getExtensionsButton = PillButton(title: String(localized: "Get Extensions", comment: "Button in Settings › Extensions: opens a menu of the Chrome Web Store and Firefox Add-ons."))
    private let loadUnpackedButton = PillButton(title: String(localized: "Install from File…", comment: "Button in Settings › Extensions: installs an extension from a folder or a Firefox package file (.xpi) on this Mac."))
    private let checkUpdatesButton = PillButton(title: String(localized: "Check for Updates", comment: "Button in Settings › Extensions: checks every extension from the Chrome Web Store for a new version now."))
    private var spaceRows: [SpaceSettingsRow] = []
    /// Download rule rows in order with their rule ids, for drag reordering.
    private var downloadRuleRows: [(id: UUID, row: DraggableRow)] = []
    private var token: SignalToken?
    private var extensionsToken: SignalToken?
    private var engineToken: SignalToken?

    private var keyToken: NSObjectProtocol?

    init(pane: SettingsPane = .general) {
        let timing = SettingsTiming.begin("init"); defer { timing.end() }
        self.pane = pane.shown(manyProfiles: Library.shared.hasManyProfiles)
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        // Its own layer, so it paints the page's surface rather than showing whatever is under it.
        wantsLayer = true
        build()
        if self.pane == .extensions { findAppExtensions() }
        token = Library.shared.changed.observe { [weak self] in
            guard let self, self.window != nil else { return }
            self.layingOutOnce {
                self.profilesChanged()
                self.reloadSpaces()
                self.reloadProfiles()
                self.reloadExtensions()
            }
        }
        // An extension's engine chosen from its toast, or gone with it, while Settings is open.
        engineToken = ExtensionSearchProvider.changed.observe { [weak self] in
            self?.refreshEngines()
            self?.refreshCustomSearch()
        }
        if #available(macOS 15.4, *) {
            extensionsToken = ExtensionCenter.changed.observe { [weak self] in
                guard let self, self.window != nil else { return }
                self.reloadExtensions()
                // An ad blocker turned on or off takes YouTube over from Zigzag, or hands it back.
                self.reloadBlocking()
                // iCloud Passwords added, disabled or removed changes the filler.
                self.reloadPasswords()
                if self.pane == .privacy || self.pane == .passwords || self.isSearching { self.layoutDocument() }
                // One turned on or off may give a search engine, or take yours with it.
                self.refreshEngines()
                self.refreshCustomSearch()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { sideToken.map(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    /// Covering the page, it takes the keyboard from the web view underneath, so typing goes nowhere unexpected.
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cgColor(Tokens.Color.surface)
        SettingsTiming.drew()
        // Drawn: what the sections asked for is read after this frame, not before it.
        if !sectionsToRead.isEmpty, !readIsQueued {
            readIsQueued = true
            DispatchQueue.main.async { [weak self] in self?.readWaitingSections() }
        }
        columnWash.color = Brand.Theme.for(self).wash
    }

    private var themeToken: SignalToken?

    // MARK: Building

    private func build() {
        let timing = SettingsTiming.begin("build"); defer { timing.end() }
        buildSiteData()
        // The column of sections, under the page's title.
        column.addSubview(columnTitle)
        column.addSubview(sectionSelection)
        buildColumn()
        // The column of sections takes a light tint of the window's space, so Settings belongs to it.
        addSubview(columnWash)
        columnScroll.drawsBackground = false
        // The column starts at the window's top, under the traffic lights, as it did before it scrolled.
        columnScroll.automaticallyAdjustsContentInsets = false
        columnScroll.hasVerticalScroller = true
        columnScroll.autohidesScrollers = true
        columnScroll.scrollerStyle = .overlay
        columnScroll.verticalScrollElasticity = .allowed
        columnScroll.documentView = column
        addSubview(columnScroll)
        addSubview(columnEdge)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.needsDisplay = true }

        // General
        defaultButton.onClick = { [weak self] _ in self?.makeDefault() }
        let defaultControl = NSStackView(views: [defaultStatus, defaultButton])
        defaultControl.spacing = Tokens.Space.x2
        versionGroup.add(SettingsVersionRow.make())
        versionGroup.add(SettingsVersionRow.betas())
        if let restore = SettingsVersionRow.restore() { versionGroup.add(restore) }
        let defaultRow = FormRow(title: String(localized: "Default browser", comment: "A setting in Settings › General."),
                                 control: defaultControl)
        defaultRow.keywords = String(localized: "default app links open launch", comment: "Words that find the Default browser setting with Find a setting in Settings. Not shown.")
        generalGroup.add(defaultRow)
        launchChoice.options = LaunchChoice.allCases.map { choice in
            switch choice {
            case .resume: DropdownButton.Option(title: String(localized: "Pick Up Where You Left Off", comment: "A choice for “On launch” in Settings › General: the last session's windows come back."))
            case .fresh: DropdownButton.Option(title: String(localized: "Start Fresh", comment: "A choice for “On launch” in Settings › General: one new window, the last session left for History › Reopen Last Session."))
            }
        }
        launchChoice.selectedIndex = LaunchChoice.allCases.firstIndex(of: LaunchChoice.choice) ?? 0
        launchChoice.onSelect = { index in LaunchChoice.choice = LaunchChoice.allCases[index] }
        let launchRow = FormRow(title: String(localized: "On launch", comment: "A setting in Settings › General: what a launch does with the last session."),
                                detail: String(localized: "Pick Up Where You Left Off brings the windows and tabs you had back. Start Fresh opens one new window and keeps the last session for History › Reopen Last Session.", comment: "Explanation under “On launch” in Settings › General."),
                                control: launchChoice)
        launchRow.keywords = String(localized: "startup launch on start restore session reopen windows fresh blank resume", comment: "Words that find the On launch setting with Find a setting in Settings. Not shown.")
        generalGroup.add(launchRow)
        // Only once Zigzag speaks more than one language: macOS lists an app under Language & Region only then.
        if Self.hasLanguages {
            // Each language named in itself, so anyone finds theirs whatever Zigzag is in now.
            languagePicker.options = AppLanguage.choices.map { DropdownButton.Option(title: $0.title) }
            languagePicker.selectedIndex = AppLanguage.choices.firstIndex { $0.code == AppLanguage.chosen } ?? 0
            languagePicker.onSelect = { [weak self] index in self?.chooseLanguage(AppLanguage.choices[index].code) }
            generalGroup.add(FormRow(title: String(localized: "Language", comment: "A setting in Settings › General."),
                                     control: languagePicker))
        }
        downloadPlace.onSelect = { index in DownloadPlace.pick(index) }
        downloadPlaceToken = DownloadPlace.changed.observe { [weak self] in
            self?.refreshDownloadPlace()
            self?.refreshDownloadPlaceRules()
        }
        generalGroup.add(FormRow(title: String(localized: "Save downloads to", comment: "A setting in Settings › General."),
                                 detail: String(localized: "Or have Zigzag ask where, each time.", comment: "Explanation under “Save downloads to” in Settings › General."),
                                 control: downloadPlace))

        // Downloads: folder and handoff rules.
        downloadPlaceRules.onSelect = { index in DownloadPlace.pick(index) }
        let rulesPlaceRow = FormRow(title: String(localized: "Save downloads to", comment: "A setting in Settings › Downloads."),
                                    detail: String(localized: "Or have Zigzag ask where, each time.", comment: "Explanation under “Save downloads to” in Settings › Downloads."),
                                    control: downloadPlaceRules)
        rulesPlaceRow.keywords = String(localized: "folder location downloads", comment: "Words that find the Save downloads to setting with Find a setting. Not shown.")
        downloadPlaceGroup.add(rulesPlaceRow)
        addDownloadRuleButton.onClick = { [weak self] _ in self?.showDownloadRuleMenu() }
        addFileTypeButton.onClick = { [weak self] _ in
            guard let self else { return }
            DownloadRuleSheet.show(in: self, kind: .saveToFolder)
        }
        downloadRulesToken = DownloadRulesStore.shared.changed.observe { [weak self] in
            guard let self else { return }
            self.reloadDownloadRules()
            if self.pane == .downloads || self.isSearching { self.layoutDocument() }
        }
        refreshDownloadPlaceRules()
        downloadRuleTest.field.delegate = self
        let testRow = FormRow(title: String(localized: "Test an address", comment: "A setting in Settings › Downloads: a field to type an address and see which rule takes it."),
                              control: downloadRuleTest)
        testRow.keywords = String(localized: "check preview rule test", comment: "Words that find the download rule test with Find a setting. Not shown.")
        downloadRuleTestRow = testRow
        downloadTestGroup.add(testRow)
        reloadDownloadRules()
        let importButton = PillButton(title: String(localized: "Import…", comment: "Button in Settings › General that opens the Import window."))
        importButton.onClick = { _ in ImportWindowController.show() }
        generalGroup.add(FormRow(title: String(localized: "Import from another browser", comment: "A setting in Settings › General."),
                                 detail: String(localized: "Passwords, bookmarks and history. The other browser isn’t changed.", comment: "Explanation under “Import from another browser” in Settings › General."),
                                 control: importButton))
        quitToggle.onChange = { on in AppDelegate.asksBeforeQuitting = on }
        let quitRow = FormRow(title: String(localized: "Ask before quitting", comment: "A setting in Settings › General."),
                              control: quitToggle)
        quitRow.keywords = String(localized: "quit quitting close command q ask confirm", comment: "Words that find the Ask before quitting setting with Find a setting in Settings. Not shown.")
        generalGroup.add(quitRow)
        reloadWebApps()
        webAppsToken = WebAppStore.shared.changed.observe { [weak self] in
            guard let self else { return }
            self.reloadWebApps()
            if self.pane == .general || self.isSearching { self.layoutDocument() }
        }

        // Automation
        aiAppsToggle.onChange = { [weak self] on in
            MCPService.setOn(on)
            self?.refreshAIApps()
        }
        let aiRow = FormRow(title: String(localized: "Let AI apps use Zigzag", comment: "A setting in Settings › Automation: turns on Zigzag's MCP server, for AI apps on this Mac."),
                            detail: String(localized: "Apps you connect over MCP, on this Mac only, can open, read and use your tabs. Never private windows, passwords or Zigzag’s own pages.",
                                           comment: "Explanation under “Let AI apps use Zigzag” in Settings › Automation."),
                            control: aiAppsToggle)
        aiRow.keywords = Self.aiAppsKeywords
        aiGroup.add(aiRow)
        aiGroup.add(aiAddressRow)
        aiGroup.add(aiKeyRow)
        connectGroup.add(aiSetupRow)
        connectGroup.add(aiPromptRow)
        let guide = PillButton(title: String(localized: "Learn More", comment: "Button in Settings › Automation: opens the guide to AI apps and MCP in a new tab."))
        guide.onClick = { [weak self] _ in self?.openAutomationGuide() }
        let guideRow = FormRow(title: String(localized: "How it works", comment: "A row in Settings › Automation, beside Learn More, which opens the guide."),
                               detail: String(localized: "What apps can do, what they never touch, and what to try when one can’t connect.",
                                              comment: "Explanation under “How it works” in Settings › Automation."),
                               control: guide)
        guideRow.keywords = Self.aiAppsKeywords + " help docs guide"
        connectGroup.add(guideRow)
        aiAppsToken = MCPService.changed.observe { [weak self] in self?.refreshAIApps() }
        scriptJavaScriptToggle.onChange = { on in Scripting.allowsJavaScript = on }
        let scriptRow = FormRow(title: String(localized: "Allow JavaScript from Apple Events", comment: "A setting in Settings › Automation, under Scripts, as Safari names it."),
                                detail: String(localized: "Scripts and apps you allow in Privacy & Security › Automation can then read and change any page you have open, signed in or not. Never in private windows.",
                                               comment: "Explanation under “Allow JavaScript from Apple Events” in Settings › Automation."),
                                control: scriptJavaScriptToggle)
        scriptRow.keywords = String(localized: "applescript osascript shortcuts apple events", comment: "Words that find the Allow JavaScript from Apple Events setting with Find a setting in Settings. Not shown.")
        scriptsGroup.add(scriptRow)

        // Developer
        developerToolsToggle.onChange = { on in DeveloperTools.isOn = on }
        let developerRow = FormRow(title: DeveloperTool.modeName,
                                   detail: String(localized: "Tools for building websites, on the sites in Developer Mode and nowhere else. Turn it on for any site in its Site Controls, in the command bar or with View › Developer. A tab in Developer Mode has a dashed outline in the sidebar.",
                                                  comment: "Explanation under the Developer Mode switch in Settings › Developer."),
                                   control: developerToolsToggle)
        developerToolsGroup.add(developerRow)
        developerBarToggle.onChange = { on in DeveloperTools.showsInBar = on }
        let developerBarRow = FormRow(title: String(localized: "Tools above the page", comment: "A setting in Settings › Developer: on a site in Developer Mode, the developer tools are in the bar above the page, with its full address."),
                                      detail: String(localized: "In the bar above a page in Developer Mode: its full address, the console, inspecting an element, the page’s look and size, and more. Off, they’re in the site’s controls.",
                                                     comment: "Explanation under “Tools above the page” in Settings › Developer."),
                                      control: developerBarToggle)
        developerBarRow.keywords = String(localized: "toolbar top bar tools buttons copy link console inspect dark light page size reload developer bar", comment: "Words that find the Tools above the page setting with Find a setting in Settings. Not shown.")
        developerToolsGroup.add(developerBarRow)
        developerTrustToggle.onChange = { on in DeveloperTools.trustsLocalServers = on }
        localServersGroup.add(FormRow(title: String(localized: "Trust certificates of servers on this Mac", comment: "A setting in Settings › Developer, under Local Servers: a development site served from this Mac over https with a certificate of its own opens without the warning."),
                                      detail: String(localized: "A development site at localhost or 127.0.0.1 that uses its own certificate for https opens without the warning. Only for servers on this Mac, and only the certificate first shown.",
                                                     comment: "Explanation under “Trust certificates of servers on this Mac” in Settings › Developer."),
                                      control: developerTrustToggle))
        addSiteButton.onClick = { [weak self] _ in if let self { DevelopmentSiteSheet.add(in: self) } }
        addSizeButton.onClick = { [weak self] _ in if let self { PageSizeSheet.add(in: self) } }
        keptCookiesToken = KeptCookies.changed.observe { [weak self] in
            guard let self, self.showsWebsiteData else { return }
            self.reloadPrivacy()
            self.layoutDocument()
        }
        // Changed in Site Controls, maybe in another window: the site rows follow (#420).
        sitePermissionsToken = SitePermissions.changed.observe { [weak self] in
            guard let self, self.showsWebsiteData else { return }
            self.reloadPrivacy()
            self.layoutDocument()
        }
        // Changed here or in another window's Settings: the switch and the list follow.
        developerToken = DeveloperTools.changed.observe { [weak self] in
            guard let self else { return }
            if self.developerToolsToggle.isOn != DeveloperTools.isOn { self.developerToolsToggle.isOn = DeveloperTools.isOn }
            if self.developerBarToggle.isOn != DeveloperTools.showsInBar { self.developerBarToggle.isOn = DeveloperTools.showsInBar }
            if self.developerTrustToggle.isOn != DeveloperTools.trustsLocalServers { self.developerTrustToggle.isOn = DeveloperTools.trustsLocalServers }
            self.reloadDevelopmentSites()
            self.reloadPageSizes()
            if self.pane == .developer || self.isSearching { self.layoutDocument() }
        }
        reloadDevelopmentSites()
        reloadPageSizes()
        // A local server's certificate trusted on its warning page, here or in another window: the list follows.
        trustedCertificatesAddSite.onClick = { [weak self] _ in
            guard let self else { return }
            TrustedCertificateSheet.add(in: self) { [weak self] url in
                self?.browser?.open(url, disposition: .foregroundTab, allowSwitch: false)
            }
        }
        trustedCertificatesToken = CertificateExceptions.changed.observe { [weak self] in
            guard let self else { return }
            self.reloadTrustedCertificates()
            if self.pane == .developer || self.isSearching { self.layoutDocument() }
        }
        reloadTrustedCertificates()
        flagSearch.isOutlined = true
        flagSearch.isPill = true
        flagSearch.field.delegate = self
        flagsReset.onClick = { [weak self] _ in
            self?.confirm(title: String(localized: "Reset all feature flags?", comment: "Title of the sheet that puts every WebKit feature flag back to its default, in Settings › Developer."),
                          message: String(localized: "Every flag you changed goes back to WebKit’s default, for pages you open or reload.",
                                          comment: "Message of the sheet that puts every WebKit feature flag back to its default."),
                          action: String(localized: "Reset to Defaults", comment: "Button beside Feature Flags in Settings › Developer: every WebKit feature flag you changed goes back to WebKit's default. Also the button of the sheet that asks first.")) {
                FeatureFlags.reset()
            }
        }
        flagsReload.onClick = { _ in FeatureFlags.reloadAllTabs() }
        flagsMore.onClick = { [weak self] _ in
            guard let self else { return }
            self.flagsShowAll.toggle()
            self.flagsMore.isOpen = self.flagsShowAll
            self.layoutDocument()
        }
        // Changed here, in another window's Settings or by Reset to Defaults: the switches and their marks follow.
        flagsToken = FeatureFlags.changed.observe { [weak self] in self?.refreshFlags() }
        // The menu bar gained or lost items (Developer tools turned on or off): the list of shortcuts is of what's there.
        shortcutsToken = Shortcuts.changed.observe { [weak self] in
            guard let self, self.pane == .shortcuts || self.isSearching else { return }
            self.reloadShortcuts()
            self.layoutDocument()
        }

        // Appearance
        borderlessToggle.onChange = { on in BrowserRootView.isBorderless = on }
        appearanceGroup.add(FormRow(title: String(localized: "Borderless page", comment: "A setting in Settings › Appearance."),
                                    detail: String(localized: "The page meets the window’s edges instead of floating inside it. Hold ⌥⌘ and drag anywhere on the page to move the window.", comment: "Explanation under “Borderless page” in Settings › Appearance. ⌥⌘ are the Option and Command keys."),
                                    control: borderlessToggle))
        addressAboveToggle.onChange = { on in BrowserRootView.addressAbovePage = on }
        let addressRow = FormRow(title: String(localized: "Address bar above the page", comment: "A setting in Settings › Appearance."),
                                 detail: String(localized: "Back, forward, reload and the address move from the sidebar to a bar above the page, and stay in view with the sidebar hidden.", comment: "Explanation under “Address bar above the page” in Settings › Appearance."),
                                 control: addressAboveToggle)
        addressRow.keywords = String(localized: "toolbar top bar url location", comment: "Words that find the Address bar above the page setting with Find a setting in Settings. Not shown.")
        appearanceGroup.add(addressRow)
        sidebarSide.options = [
            DropdownButton.Option(title: String(localized: "Left", comment: "A choice for “Sidebar position” in Settings › Appearance: the sidebar along the window's left edge.")),
            DropdownButton.Option(title: String(localized: "Right", comment: "A choice for “Sidebar position” in Settings › Appearance: the sidebar along the window's right edge.")),
        ]
        sidebarSide.onSelect = { index in BrowserRootView.sidebarOnRight = Self.sidebarSides[index] }
        let sideRow = FormRow(title: String(localized: "Sidebar position", comment: "A setting in Settings › Appearance: which edge of the window the sidebar runs along, Left or Right."),
                              control: sidebarSide)
        // 侧边栏 is what people type, though Zigzag says 边栏 (docs/i18n/glossary.md): found by it, never shown.
        sideRow.keywords = String(localized: "sidebar right left side position move", comment: "Words that find the Sidebar position setting with Find a setting in Settings. Not shown.") + " 侧边栏"
        appearanceGroup.add(sideRow)
        doubleClickTabToggle.onChange = { on in SidebarView.doubleClickOpensNewTab = on }
        let doubleClickRow = FormRow(title: String(localized: "Double-click the sidebar for a new tab", comment: "A setting in Settings › Appearance."),
                                     detail: String(localized: "A double-click on the empty space below your tabs opens a new tab. Turned off, it zooms the window, as a title bar does.", comment: "Explanation under “Double-click the sidebar for a new tab” in Settings › Appearance."),
                                     control: doubleClickTabToggle)
        doubleClickRow.keywords = String(localized: "double click new tab empty space zoom", comment: "Words that find the Double-click the sidebar for a new tab setting with Find a setting in Settings. Not shown.") + " 侧边栏 双击"
        appearanceGroup.add(doubleClickRow)
        // The View menu moves it too, with Settings open.
        sideToken = NotificationCenter.default.addObserver(forName: BrowserRootView.sidebarSideChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarSide.selectedIndex = BrowserRootView.sidebarOnRight ? 1 : 0 }
        }
        // As macOS's System Settings › Appearance › Sidebar icon size, and a size of your own (#361): Medium as
        // Zigzag has always been.
        sidebarSize.options = Tokens.Sidebar.Size.allCases.map { size in
            let title = switch size {
            case .small: String(localized: "Small", comment: "A choice for “Sidebar size” in Settings › Appearance.")
            case .medium: String(localized: "Medium", comment: "A choice for “Sidebar size” in Settings › Appearance: the usual size.")
            case .large: String(localized: "Large", comment: "A choice for “Sidebar size” in Settings › Appearance.")
            case .custom: String(localized: "Custom", comment: "A choice for “Sidebar size” in Settings › Appearance: a percentage of Medium that you set.")
            }
            return DropdownButton.Option(title: title)
        }
        sidebarSizeStepper.steps = Tokens.Sidebar.customSteps
        sidebarSizeStepper.reset = { 1 }
        sidebarSizeStepper.lessTip = String(localized: "Smaller Sidebar", comment: "Tooltip of the − button on the Sidebar size row of Settings › Appearance: a smaller size of your own.")
        sidebarSizeStepper.moreTip = String(localized: "Larger Sidebar", comment: "Tooltip of the + button on the Sidebar size row of Settings › Appearance: a larger size of your own.")
        sidebarSizeStepper.resetTip = String(localized: "Usual Size", comment: "Tooltip of the percentage on the Sidebar size row of Settings › Appearance: sets the size of your own back to 100%.")
        sidebarSizeStepper.typingTip = nil
        sidebarSizeStepper.percentName = String(localized: "Sidebar size %@, Usual Size", comment: "VoiceOver name of the percentage on the Sidebar size row of Settings › Appearance: the size now, then what pressing it does.")
        sidebarSizeStepper.onChange = { value in Tokens.Sidebar.customScale = value }
        let sizeControls = NSStackView(views: [sidebarSize, sidebarSizeStepper])
        sizeControls.spacing = Tokens.Space.x2
        sizeControls.alignment = .centerY
        sizeControls.detachesHiddenViews = true
        let sizeRow = FormRow(title: String(localized: "Sidebar size", comment: "A setting in Settings › Appearance: how large the sidebar's tabs, folders, space names, favorites and address are, as macOS's Sidebar icon size."),
                              detail: String(localized: "The size of the tabs, folders, favorites and address. To make everything on your Mac larger, use Larger Text in System Settings › Displays.",
                                             comment: "Explanation under “Sidebar size” in Settings › Appearance. Larger Text and System Settings › Displays are macOS's own names."),
                              control: sizeControls)
        sidebarSizeRow = sizeRow
        // The menu and the percentage both set the size; the row shows whichever is chosen.
        sidebarSize.onSelect = { [weak self] index in
            Tokens.Sidebar.size = Tokens.Sidebar.Size.allCases[index]
            self?.refreshSidebarSize()
            self?.laidOutWidth = -1
            self?.needsLayout = true
        }
        // 侧边栏 is what people type, though Zigzag says 边栏 (docs/i18n/glossary.md): found by it, never shown.
        sizeRow.keywords = String(localized: "text size font bigger larger smaller scale zoom interface ui", comment: "Words that find the Sidebar size setting with Find a setting in Settings. Not shown.") + " 侧边栏"
        appearanceGroup.add(sizeRow)
        largeNamesToggle.onChange = { on in SpaceHeaderView.isLarge = on }
        appearanceGroup.add(FormRow(title: String(localized: "Large space names", comment: "A setting in Settings › Appearance."),
                                    detail: String(localized: "Shows the space’s name large and light above its tabs. When off, it’s a plain heading.", comment: "Explanation under “Large space names” in Settings › Appearance."),
                                    control: largeNamesToggle))
        favoritesPerRow.options = FavoritesView.perRowChoices.map { count in
            DropdownButton.Option(title: count == 0 ? String(localized: "Automatic", comment: "A choice for “Favorites per row” in Settings › Appearance: as many as fit the sidebar's width.") : count.formatted())
        }
        favoritesPerRow.onSelect = { index in FavoritesView.perRow = FavoritesView.perRowChoices[index] }
        appearanceGroup.add(FormRow(title: String(localized: "Favorites per row", comment: "A setting in Settings › Appearance: how many favorites' tiles sit side by side in the sidebar."),
                                    detail: String(localized: "Automatic fits fewer, larger ones in a narrow sidebar.", comment: "Explanation under “Favorites per row” in Settings › Appearance."),
                                    control: favoritesPerRow))
        // Default zoom for sites without their own, as in Chrome and Safari.
        pageZoom.options = ZoomLevels.steps.map { DropdownButton.Option(title: ZoomLevels.percent($0)) }
        pageZoom.onSelect = { index in ZoomLevels.defaultZoom = ZoomLevels.steps[index] }
        let zoomRow = FormRow(title: String(localized: "Page zoom", comment: "A setting in Settings › Appearance: the zoom websites open at, like 110%."),
                              detail: String(localized: "How large websites are shown. A site you zoom with ⌘+ or ⌘− keeps its own zoom.",
                                             comment: "Explanation under “Page zoom” in Settings › Appearance."),
                              control: pageZoom)
        zoomRow.keywords = String(localized: "default zoom size bigger larger smaller scale text", comment: "Words that find the Page zoom setting with Find a setting in Settings. Not shown.") + " 缩放 默认缩放"
        appearanceGroup.add(zoomRow)
        darkPages.options = DarkPages.Mode.allCases.map { mode in
            let title = switch mode {
            case .off: String(localized: "Off", comment: "A choice for “Dark pages” in Settings › Appearance: websites are shown as they are.")
            case .system: String(localized: "When the Mac Is Dark", comment: "A choice for “Dark pages” in Settings › Appearance: websites are drawn dark while macOS is in Dark Mode.")
            case .always: String(localized: "Always", comment: "A choice for “Dark pages” in Settings › Appearance: websites are always drawn dark.")
            }
            return DropdownButton.Option(title: title)
        }
        darkPages.onSelect = { [weak self] index in
            DarkPages.mode = DarkPages.Mode.allCases[index]
            self?.refreshPureBlack()
        }
        // Dark Reader's license asks for its notice, which is in Acknowledgments; this is where people look for what
        // draws pages dark.
        let darkDetail = Words.sentences(String(localized: "Websites without a dark look of their own are drawn dark. Pictures and video stay as they are.",
                                                comment: "Explanation under “Dark pages” in Settings › Appearance."),
                                         String(localized: "Uses Dark Reader, by Dark Reader Ltd.", comment: "After the explanation under “Dark pages” in Settings › Appearance. Dark Reader is the name of the open-source dark mode engine, Dark Reader Ltd. its maker: keep both as they are."))
        let darkRow = FormRow(title: String(localized: "Dark pages", comment: "A setting in Settings › Appearance: websites without a dark look of their own are drawn dark."),
                              detail: darkDetail, control: darkPages)
        darkRow.keywords = String(localized: "dark mode light appearance night theme black invert", comment: "Words that find the Dark pages setting with Find a setting in Settings. Not shown.")
        appearanceGroup.add(darkRow)
        pureBlackToggle.onChange = { on in DarkPages.pureBlack = on }
        appearanceGroup.add(pureBlackRow)
        refreshPureBlack()
        motionToggle.onChange = { on in Tokens.Motion.reducesMotionHere = on }
        appearanceGroup.add(FormRow(title: String(localized: "Reduce motion", comment: "A setting in Settings › Appearance."),
                                    control: motionToggle))

        // Tabs
        newTabPlace.options = TabManager.NewTabPlace.allCases.map { place in
            let title = switch place {
            case .next: String(localized: "Next to the Current Tab", comment: "A choice for “New tabs open” in Settings › Tabs: just below the tab you're on, or the page a link came from.")
            case .top: String(localized: "At the Top", comment: "A choice for “New tabs open” in Settings › Tabs: above the other tabs.")
            case .bottom: String(localized: "At the Bottom", comment: "A choice for “New tabs open” in Settings › Tabs: below the other tabs.")
            case .sameSite: String(localized: "Next to Tabs from the Same Site", comment: "A choice for “New tabs open” in Settings › Tabs: a page goes right after the tabs already open from its website, like other github.com pages.")
            }
            return DropdownButton.Option(title: title)
        }
        newTabPlace.onSelect = { [weak self] index in
            TabManager.newTabPlace = TabManager.NewTabPlace.allCases[index]
            self?.refreshNewTabPlace()
        }
        newTabRow = FormRow(title: String(localized: "New tabs open", comment: "A setting in Settings › Tabs: where a new tab goes in the sidebar's list."),
                            detail: nil, control: newTabPlace)
        // There's no homepage: a new tab opens the address bar. This is the setting nearest to one.
        newTabRow.keywords = String(localized: "new tab homepage home page start page position order same site domain group organize", comment: "Words that find the New tabs open setting with Find a setting in Settings. Zigzag has no homepage, so words about one find this row. Not shown.")
        tabsGroup.add(newTabRow)
        refreshNewTabPlace()
        controlTabOrder.options = TabSwitcher.Order.allCases.map { order in
            let title = switch order {
            case .recent: String(localized: "Recent Tabs", comment: "A choice for “⌃Tab switches to” in Settings › Tabs: Control-Tab shows the tabs you used last, most recent first.")
            case .sidebar: String(localized: "Next Tab in the Sidebar", comment: "A choice for “⌃Tab switches to” in Settings › Tabs: Control-Tab goes to the tab below in the sidebar, as in Chrome.")
            }
            return DropdownButton.Option(title: title)
        }
        controlTabOrder.onSelect = { index in TabSwitcher.order = TabSwitcher.Order.allCases[index] }
        let controlTabRow = FormRow(title: String(localized: "⌃Tab switches to", comment: "A setting in Settings › Tabs: what Control-Tab does. ⌃ is the Control key. Followed by Recent Tabs or Next Tab in the Sidebar."),
                                    detail: String(localized: "Recent Tabs shows the tabs you used last, as ⌘Tab does with apps. ⌥⌘↓ and ⌥⌘↑ always go down and up the sidebar.",
                                                   comment: "Explanation under “⌃Tab switches to” in Settings › Tabs. ⌘, ⌥ are the Command and Option keys."),
                                    control: controlTabOrder)
        controlTabRow.keywords = String(localized: "control tab ctrl tab switcher recent order next previous cycle keyboard shortcut chrome arc", comment: "Words that find the ⌃Tab switches to setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(controlTabRow)
        nestToggle.onChange = { on in TabManager.nestsOpenedLinks = on }
        let nestRow = FormRow(title: String(localized: "Open ⌘-clicked links under their tab", comment: "A setting in Settings › Tabs: a link opened in a new tab goes in the sidebar nested under the tab it came from. ⌘ is the Command key."),
                              detail: String(localized: "Drag a tab out to make it a tab of its own.", comment: "Explanation under “Open ⌘-clicked links under their tab” in Settings › Tabs."),
                              control: nestToggle)
        nestRow.keywords = String(localized: "nested tree child command click", comment: "Words that find the Open ⌘-clicked links under their tab setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(nestRow)
        shareTabsToggle.onChange = { on in TabStore.windowsShareTabs = on }
        let shareRow = FormRow(title: String(localized: "Windows share a space’s tabs", comment: "A setting in Settings › Tabs: every window showing the same space lists the same open tabs, as in Arc, instead of each window having tabs of its own."),
                               detail: String(localized: "Every window on a space lists the same tabs, each showing its own. A page can be on screen in one window at a time.", comment: "Explanation under “Windows share a space’s tabs” in Settings › Tabs."),
                               control: shareTabsToggle)
        shareRow.keywords = String(localized: "windows share same tabs sync arc sidebar another window", comment: "Words that find the Windows share a space’s tabs setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(shareRow)
        archiveAfter.options = TabArchive.After.allCases.map { DropdownButton.Option(title: $0.title) }
        archiveAfter.onSelect = { index in TabArchive.after = TabArchive.After.allCases[index] }
        tabsGroup.add(FormRow(title: String(localized: "Archive tabs you haven’t used", comment: "A setting in Settings › Tabs."),
                              detail: String(localized: "They leave the sidebar. Type a few letters in the address bar to bring one back.", comment: "Explanation under “Archive tabs you haven’t used” in Settings › Tabs."),
                              control: archiveAfter))
        energyToggle.onChange = { on in EnergyWatch.sleepsBusyTabs = on }
        let energyRow = FormRow(title: String(localized: "Put busy background tabs to sleep", comment: "A setting in Settings › Tabs."),
                                detail: String(localized: "A tab you’re not using that keeps working hard sleeps until you open it again. To keep a site’s tabs awake, turn on Keep tabs awake in its site controls.",
                                               comment: "Explanation under “Put busy background tabs to sleep” in Settings › Tabs. Keep tabs awake is the row in the site panel; site controls is the panel by the address."),
                                control: energyToggle)
        energyRow.keywords = String(localized: "sleep asleep memory energy keep awake active exclude site", comment: "Words that find the Put busy background tabs to sleep setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(energyRow)
        pipToggle.onChange = { on in PictureInPicture.followsTabs = on }
        let videoRow = FormRow(title: String(localized: "Show a mini player when you switch tabs", comment: "A setting in Settings › Tabs."),
                               detail: String(localized: "The mini player’s right-click menu can turn this off too.", comment: "Explanation under “Show a mini player when you switch tabs” in Settings › Tabs."),
                               control: pipToggle)
        videoRow.keywords = String(localized: "mini player picture in picture pip floating", comment: "Words that find the Show a mini player setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(videoRow)
        leavePipToggle.onChange = { on in AutoPictureInPicture.isOn = on }
        let leaveRow = FormRow(title: String(localized: "Show a mini player when you leave Zigzag", comment: "A setting in Settings › Tabs, below “Show a mini player when you switch tabs”: a playing video moves into Zigzag's small player, over other apps, when you switch to another app or desktop."),
                               detail: String(localized: "The video floats over other apps and desktops, and goes back in its page when you return.", comment: "Explanation under “Show a mini player when you leave Zigzag” in Settings › Tabs."),
                               control: leavePipToggle)
        leaveRow.keywords = String(localized: "mini player picture in picture pip floating video other app desktop space leave switch away background automatic", comment: "Words that find the Show a mini player when you leave Zigzag setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(leaveRow)
        fullScreenFill.options = PageFullScreen.Fill.allCases.map { fill in
            let title = switch fill {
            case .screen: String(localized: "The Whole Screen", comment: "A choice for “Full screen videos fill” in Settings › Tabs: a video in full screen covers the whole screen, as usual.")
            case .page: String(localized: "The Page", comment: "A choice for “Full screen videos fill” in Settings › Tabs: a video in full screen fills the page's area in the window, with the sidebar and the rest of the window still there.")
            }
            return DropdownButton.Option(title: title)
        }
        fullScreenFill.onSelect = { index in PageFullScreen.fill = PageFullScreen.Fill.allCases[index] }
        let fullScreenRow = FormRow(title: String(localized: "Full screen videos fill", comment: "A setting in Settings › Tabs: whether a video put in full screen covers the whole screen or only the page's area in the window. Followed by The Whole Screen or The Page."),
                                    detail: String(localized: "Choose for a single site in its site controls.",
                                                   comment: "Explanation under “Full screen videos fill” in Settings › Tabs. Site controls is the panel by the address."),
                                    control: fullScreenFill)
        fullScreenRow.keywords = String(localized: "full screen fullscreen window tab pane video youtube in window", comment: "Words that find the Full screen videos fill setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(fullScreenRow)
        swipeToggle.onChange = { on in SwipeNavigator.isOn = on }
        tabsGroup.add(FormRow(title: String(localized: "Swipe to go back and forward", comment: "A setting in Settings › Tabs: two fingers sideways on the trackpad go back or forward."),
                              detail: String(localized: "Two fingers sideways on the trackpad. When off, websites get every swipe.", comment: "Explanation under “Swipe to go back and forward” in Settings › Tabs."),
                              control: swipeToggle))
        pinOfferToggle.onChange = { on in BrowserWindowController.offersToPinWanderedPage = on }
        tabsGroup.add(FormRow(title: String(localized: "Offer to pin the page you moved to", comment: "A setting in Settings › Tabs."),
                              detail: String(localized: "After you close a pinned tab that went to another page, like a new chat.", comment: "Explanation under “Offer to pin the page you moved to” in Settings › Tabs."),
                              control: pinOfferToggle))

        // Spaces
        ownProfileToggle.onChange = { on in Library.newSpacesGetOwnProfile = on }
        let ownProfileRow = FormRow(title: String(localized: "Give new spaces their own profile", comment: "A setting in Settings › Spaces: a space you make gets a new profile of its own, named after the space."),
                                    detail: String(localized: "A space you make gets a profile named after it, with its own sign-ins, extensions and history. Spaces you have now stay on theirs.",
                                                   comment: "Explanation under “Give new spaces their own profile” in Settings › Spaces."),
                                    control: ownProfileToggle)
        ownProfileRow.keywords = String(localized: "separate profile per space each own container isolate new space", comment: "Words that find the Give new spaces their own profile setting with Find a setting in Settings. Not shown.")
        newSpacesGroup.add(ownProfileRow)
        addSpaceButton.onClick = { [weak self] _ in self?.addSpace() }
        addRouteButton.onClick = { [weak self] _ in self?.addRoute() }
        addProfileButton.onClick = { [weak self] _ in if let self { ProfileSheets.new(in: self) } }
        profilePicker.onSelect = { [weak self] index in self?.choseProfile(at: index) }
        refreshProfilePicker()

        // Search
        refreshEngines()
        SearchEngine.builtIn.forEach { if FaviconStore.shared.cachedIcon(for: $0.homeURL) == nil { FaviconStore.shared.prefetch(for: $0.homeURL) } }
        engine.onSelect = { [weak self] index in
            guard let self else { return }
            let builtIn = SearchEngine.builtIn
            if index >= builtIn.count {
                ExtensionSearchProvider.use(self.engineProviders[index - builtIn.count])
            } else {
                Library.shared.searchEngine = builtIn[index]
            }
            self.refreshCustomSearch()
            // Choosing Custom with no address yet: straight into the field to type one.
            if index < builtIn.count, builtIn[index] == .custom, SearchEngine.customTemplate.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.customSearch.field) }
            }
        }
        customSearch.stringValue = SearchEngine.customTemplate
        customSearch.field.target = self
        customSearch.field.action = #selector(customSearchChanged)
        searchGroup.add(FormRow(title: String(localized: "Search engine", comment: "A setting in Settings › Search."),
                                control: engine))
        searchGroup.add(customSearchRow)
        refreshCustomSearch()
        suggestionsToggle.onChange = { on in SuggestionFetcher.isOn = on }
        // Searching a site with Tab is taught where it's used (the address bar shows the key), not listed here.
        searchGroup.add(FormRow(title: String(localized: "Search suggestions", comment: "A setting in Settings › Search."),
                                detail: String(localized: "What you type in the address bar is sent to your search engine for suggestions.", comment: "Explanation under “Search suggestions” in Settings › Search."),
                                control: suggestionsToggle))

        // Zigzag Mini: what it is and how to open it, then where links from other apps go.
        miniGroup.add(FormRow(title: String(localized: "New Zigzag Mini", comment: "A row in Settings › Zigzag Mini, showing its keyboard shortcut. Zigzag Mini is a name, kept in Latin letters."),
                              detail: String(localized: "A small window for a quick look at a page. Esc closes it, and ⌘O moves it into your browser window to keep it.", comment: "Explanation under “New Zigzag Mini” in Settings › Zigzag Mini: what Zigzag Mini is."),
                              control: miniKeys))
        miniToggle.onChange = { on in MiniWindowController.opensExternalLinks = on }
        miniGroup.add(FormRow(title: String(localized: "Open links from other apps in Zigzag Mini", comment: "A setting in Settings › Zigzag Mini."),
                              detail: String(localized: "Sign-in pages and links from scripts and other apps open in a small window instead of a new tab.", comment: "Explanation under “Open links from other apps in Zigzag Mini” in Settings › Zigzag Mini."),
                              control: miniToggle))

        // Privacy
        blockingToggle.onChange = { [weak self] on in
            ContentBlocker.isEnabled = on
            // The row is made again: it's laid out to the page's width at once, or its switch sits where a new row starts.
            self?.reloadBlocking()
            self?.layoutDocument()
        }
        // Open pages keep their setting until reload (`WebRTCProtection`).
        webRTCToggle.onChange = { on in WebRTCProtection.isOn = on }
        // Same for JavaScript (#282): applies on reload.
        javaScript.options = [SitePanel.javaScriptAllowed, SitePanel.javaScriptNotAllowed].map { DropdownButton.Option(title: $0) }
        javaScript.onSelect = { index in SiteJavaScript.isAllowed = index == 0 }
        cookieBanners.options = CookieBanners.Mode.allCases.map { mode in
            let title = switch mode {
            case .reject: String(localized: "Reject When Possible", comment: "A choice for “Cookie banners” in Settings › Privacy: Zigzag says no to a site's cookie consent pop-up, or hides one that only needs hiding.")
            case .leave: String(localized: "Leave Alone", comment: "A choice for “Cookie banners” in Settings › Privacy: sites' cookie consent pop-ups are left for you to answer.")
            }
            return DropdownButton.Option(title: title)
        }
        cookieBanners.onSelect = { index in CookieBanners.mode = CookieBanners.Mode.allCases[index] }
        reloadBlocking()

        // Passwords
        passwordFiller.options = [DropdownButton.Option(title: "Zigzag"),
                                  DropdownButton.Option(title: Self.iCloudPasswordsName)]
        passwordFiller.onSelect = { [weak self] index in self?.choosePasswordFiller(index == 1 ? .iCloud : .zigzag) }
        saveToggle.onChange = { [weak self] on in
            guard let self else { return }
            PasswordCapture.setOffersToSave(on, in: self.profile)
            self.reloadPasswords()
            self.layoutDocument()
        }
        fillToggle.onChange = { [weak self] on in
            guard let self else { return }
            Autofill.setOn(on, in: self.profile)
            if !on { Autofill.shared.hide() }
            self.reloadPasswords()
            self.layoutDocument()
        }
        reloadPasswords()

        // Translation
        translateOffer.onChange = { on in PageTranslator.offers = on }
        translateInto.onSelect = { [weak self] index in
            guard let self else { return }
            PageTranslator.chosenLanguage = index == 0 ? nil : self.languages[index - 1].id
        }
        reloadTranslation()
        Task { @MainActor in
            languages = await PageTranslator.targetLanguages()
            reloadTranslation()
        }

        // Extensions
        getExtensionsButton.onClick = { [weak self] _ in if let self { self.showGetExtensionsMenu(from: self.getExtensionsButton) } }
        loadUnpackedButton.onClick = { [weak self] _ in self?.loadUnpacked() }
        checkUpdatesButton.onClick = { [weak self] _ in self?.checkForUpdates() }

        // One search for everything, shortcuts included (by name or by keys).
        settingSearch.field.delegate = self
        header.leading = paneTitle
        header.trailing = [settingSearch]

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        scroll.useSlimScroller()
        addSubview(scroll)
        addSubview(header)
        // The header's hairline shows once the page has scrolled under it, as History's does.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        show(pane)
    }

    // MARK: The page's layout

    /// How the sections sit: a column with their names, a rail of symbols when the page gets narrower, and a row of
    /// symbols across the top when it's too narrow for even that (half of a split in a small window).
    private enum Arrangement { case column, rail, row }
    private var arrangement: Arrangement { bounds.width >= 720 ? .column : bounds.width >= 520 ? .rail : .row }

    /// The page's edge to its content: the same as History's, and tighter on a narrow page.
    private var gutter: CGFloat { bounds.width < Tokens.Page.narrowWidth ? Tokens.Page.narrowGutter : Tokens.Page.gutter }

    /// Where the pane's content runs across the scroll view: as wide as the page allows up to the shared maximum,
    /// centered past it.
    private func contentSpan(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inner = max(0, min(Tokens.Page.maxWidth, width - gutter * 2))
        return (round((width - inner) / 2), inner)
    }

    /// Everything here is placed from the page's own bounds, and nothing is read back from a view just placed. The
    /// page changes size inside animations (the sidebar hidden, Borderless page turned on or off): there, a view
    /// still answers with the frame it had, and a layout built on such answers is the last size's, not this one's.
    override func layout() {
        super.layout()
        let arrangement = arrangement
        let line = Tokens.Metric.hairline
        let headerHeight = Tokens.Page.headerHeight
        // Where the sections go, and where the chosen one's pane goes. The column's tint and its edge run past the
        // page's far side, as far as a card grows in one move: the page hangs from its card's top, and its far side
        // follows the card's in an animation of its own. A frame behind, the card's ground showed there as a line.
        let columnFrame: NSRect, area: NSRect
        let past = Tokens.Metric.cardInset * 2
        switch arrangement {
        case .column, .rail:
            let width = arrangement == .column ? Tokens.Page.columnWidth : Tokens.Space.x16
            columnFrame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            columnWash.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height + past)
            columnEdge.frame = NSRect(x: width, y: 0, width: line, height: bounds.height + past)
            area = NSRect(x: width + line, y: 0, width: max(0, bounds.width - width - line), height: bounds.height)
        case .row:
            // The header across the top, then the sections as a row of symbols under it.
            columnFrame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: Tokens.Space.x10 + Tokens.Space.x2)
            columnWash.frame = NSRect(x: 0, y: headerHeight, width: bounds.width + past, height: columnFrame.height)
            columnEdge.frame = NSRect(x: 0, y: columnFrame.maxY, width: bounds.width + past, height: line)
            area = NSRect(x: 0, y: columnFrame.maxY + line, width: bounds.width, height: max(0, bounds.height - columnFrame.maxY - line))
        }
        columnScroll.frame = columnFrame
        header.frame = NSRect(x: area.minX, y: 0, width: area.width, height: headerHeight)
        // The page scrolls under the header; in a row, under the sections too.
        let top = arrangement == .row ? area.minY : headerHeight
        scroll.frame = NSRect(x: area.minX, y: top, width: area.width, height: max(0, bounds.height - top))
        let span = contentSpan(in: area.width)
        // Rows have no card now, so their text sits a group's padding in: the title and search line up with it.
        header.contentFrame = (span.x + Tokens.Page.groupPad, span.x + span.width - Tokens.Page.groupPad)
        // With no column to carry it, the wordmark heads the pane's own title.
        refreshTitle()
        placeProfilePicker(arrangement)
        settingSearch.tint = Brand.Theme.for(self).accent
        // The sections are laid out for the height in view; what still doesn't fit scrolls. Their document is as
        // tall as they are and no taller, so it only ever scrolls when they don't fit.
        let sectionsBottom = layoutColumn(arrangement, in: columnFrame.size)
        column.frame = NSRect(x: 0, y: 0, width: columnFrame.width, height: arrangement == .row ? columnFrame.height : ceil(sectionsBottom))
        // The pane's rows depend only on the width, so a change of height leaves them be, instead of rebuilding
        // every row (Shortcuts has about a hundred).
        paneWidth = area.width
        if paneWidth != laidOutWidth { layoutDocument() }
    }

    /// The width the pane has for its rows: the scroll view's, as the last layout placed it.
    private var paneWidth: CGFloat = 0
    /// The width the rows were last laid out for; -1 has the next layout do them again.
    private var laidOutWidth: CGFloat = -1

    /// The header's title: the chosen section, or "results" while a search goes through all of them (the column
    /// already says "settings").
    private func refreshTitle() {
        paneTitle.title = isSearching ? String(localized: "Results", comment: "Title of Settings while it shows what Find a setting found.") : pane.title
        header.needsLayout = true
    }

    @objc private func scrolled() {
        header.showsEdge = scroll.contentView.bounds.minY > 0
    }

    /// Lays the sections out down `column` and returns where the last one ends.
    @discardableResult
    private func layoutColumn(_ arrangement: Arrangement, in room: NSSize) -> CGFloat {
        columnTitle.isHidden = arrangement != .column
        items.forEach { $0.isCompact = arrangement != .column }
        // With names beside them, the sections about one profile stand under a heading and the menu that chooses it;
        // as symbols alone they follow the others, and the menu is beside the search (`placeProfilePicker`).
        let grouped = arrangement == .column && columnHasProfiles
        profileHeading.isHidden = !grouped
        // Each group's heading shows only with names beside the symbols; as symbols alone, the gaps say it.
        let headed = arrangement == .column
        groupHeadings.values.forEach { $0.isHidden = !headed }
        let headingRoom = headed ? (groupHeadings.values.first?.lineHeight ?? 0) + Tokens.Space.x1 : 0
        // The heading and the menu take about two sections' room.
        let count = CGFloat(items.count + (grouped ? 2 : 0))
        // A small gap before each group after the first, no label: how System Settings sets its groups apart.
        let gaps = CGFloat(items.filter { groupStarts.contains($0.pane) }.count)
        let gap = arrangement == .row ? Tokens.Space.x2 : Tokens.Space.x3
        // In the row they shrink to fit, rather than run off the page's edge.
        let side = arrangement == .row ? min(Tokens.Space.x10, floor((room.width - Tokens.Space.x2 * 2 - gaps * gap) / count)) : Tokens.Space.x10
        // Down the column, a short page (a small window) takes some height off each section, never below a control's,
        // so all of them fit under the title.
        let top = Tokens.Page.headerHeight + Tokens.Space.x1
        func height(_ tallest: CGFloat) -> CGFloat {
            let headings = CGFloat(groupHeadings.count) * headingRoom
            return max(Tokens.Page.controlHeight, min(tallest, floor((room.height - top - Tokens.Space.x2 - gaps * gap - headings) / count) - 2))
        }
        var bottom: CGFloat = 0
        switch arrangement {
        case .column:
            // The title sits where History's does; the sections' text lines up under it, their fills reaching past.
            let gutter = Tokens.Page.gutter, inset = Tokens.Page.rowInset
            columnTitle.frame = NSRect(x: gutter, y: Tokens.Page.headerTop, width: room.width - gutter * 2, height: Tokens.Page.controlHeight)
            let rowHeight = height(Tokens.Page.rowHeight)
            var y = top
            for item in items {
                if grouped, item.pane == SettingsPane.perProfile.first {
                    y += Tokens.Space.x3
                    profileHeading.frame = NSRect(x: gutter - Label.inset, y: y, width: room.width - gutter * 2, height: profileHeading.lineHeight)
                    y = profileHeading.frame.maxY + Tokens.Space.x2
                    profilePicker.frame = NSRect(x: gutter - inset, y: y, width: room.width - (gutter - inset) * 2, height: Tokens.Page.controlHeight)
                    y = profilePicker.frame.maxY + Tokens.Space.x2
                }
                if groupStarts.contains(item.pane) { y += gap }
                if let heading = groupHeadings[item.pane] {
                    heading.frame = NSRect(x: gutter - Label.inset, y: y, width: room.width - gutter * 2, height: heading.lineHeight)
                    y = heading.frame.maxY + Tokens.Space.x1
                }
                item.frame = NSRect(x: gutter - inset, y: y, width: room.width - (gutter - inset) * 2, height: rowHeight)
                y += rowHeight + 2
            }
            bottom = y + Tokens.Space.x2
        case .rail:
            let rowHeight = height(side)
            var y = top
            for item in items {
                if groupStarts.contains(item.pane) { y += gap }
                item.frame = NSRect(x: (room.width - side) / 2, y: y, width: side, height: rowHeight)
                y += rowHeight + 2
            }
            bottom = y + Tokens.Space.x2
        case .row:
            // Spread evenly across, but never further apart than the rail has them.
            let spacing = min(Tokens.Space.x2, max(0, (room.width - Tokens.Space.x4 * 2 - side * count - gaps * gap) / (count - 1)))
            let total = side * count + spacing * (count - 1) + gaps * gap
            var x = max(0, round((room.width - total) / 2))
            for item in items {
                if groupStarts.contains(item.pane) { x += gap }
                item.frame = NSRect(x: x, y: (room.height - side) / 2, width: side, height: side)
                x += side + spacing
            }
        }
        moveSectionSelection(animated: false)
        return bottom
    }

    private func moveSectionSelection(animated: Bool) {
        sectionSelection.tint = Brand.Theme.for(self).accent
        sectionSelection.move(to: items.first { $0.isSelected }?.frame ?? .zero, animated: animated)
    }
    /// Opens a pane.
    func show(_ pane: SettingsPane) {
        let pane = pane.shown(manyProfiles: Library.shared.hasManyProfiles)
        self.pane = pane
        settingSearch.stringValue = ""
        items.forEach { $0.isSelected = $0.pane == pane }
        moveSectionSelection(animated: true)
        // Opened from a search or a link while the column is scrolled: the chosen section comes into view.
        if let item = items.first(where: { $0.isSelected }) { column.scrollToVisible(item.frame.insetBy(dx: 0, dy: -Tokens.Space.x2)) }
        refreshTitle()
        if showsWebsiteData { reloadPrivacy(); reloadListedSiteData() }
        readSoon([pane])
        if pane == .shortcuts { readShortcuts() }
        if pane == .extensions { findAppExtensions() }
        layoutDocument()
        documentView.scroll(.zero)
    }

    /// A section picked in the column.
    private func pick(_ pane: SettingsPane) {
        guard pane != self.pane || isSearching else { return }
        show(pane)
        onPaneChange?(pane)
    }

    /// Shown again (its tab chosen, or moved to another window): what may have changed elsewhere is read afresh.
    override func viewDidMoveToWindow() {
        let timing = SettingsTiming.begin("viewDidMoveToWindow"); defer { timing.end() }
        super.viewDidMoveToWindow()
        needsDisplay = true
        if let keyToken { NotificationCenter.default.removeObserver(keyToken) }
        keyToken = nil
        guard let window else { return }
        keyToken = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        layingOutOnce {
            refresh()
            // A profile made or removed while this tab wasn't showing.
            followProfiles()
            reloadSpaces()
            reloadProfiles()
            reloadExtensions()
            reloadBlocking()
            reloadPasswords()
            reloadTranslation()
            if showsWebsiteData { reloadPrivacy(); reloadListedSiteData() }
            layoutDocument()
        }
    }

    /// Its picture, for the tab's preview and switcher. Shadows are off while it's taken: `cacheDisplay` blurs each on the CPU (#379).
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let shadowed = Self.shadowedLayers(in: self)
        let opacities = shadowed.map(\.shadowOpacity)
        Tokens.Motion.withoutAnimation {
            shadowed.forEach { $0.shadowOpacity = 0 }
            cacheDisplay(in: bounds, to: rep)
            zip(shadowed, opacities).forEach { $0.shadowOpacity = $1 }
        }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Every layer with a shadow, walking views as well as sublayers.
    static func shadowedLayers(in view: NSView) -> [CALayer] {
        func all(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(all) }
        return (view.layer.map(all) ?? []).filter { $0.shadowOpacity > 0 } + view.subviews.flatMap(shadowedLayers)
    }

    // MARK: The profile shown

    /// The profile chosen in the menu, for as long as Settings stays open. Nil: the one of the space it's used in.
    private var chosenProfile: UUID?
    /// The profile whose things the sections about one profile show: the one chosen in the menu, else the one of
    /// the space the window is on. One that's removed gives way to that space's again.
    private var profile: Profile {
        if let chosenProfile, Library.shared.directory.profile(chosenProfile) != nil { return Profiles.shared.profile(chosenProfile) }
        return browser?.tabManager.profile ?? Profiles.shared.default
    }
    /// Its name, as headings say it.
    private var profileName: String { Library.shared.directory.profile(profile.id)?.displayName ?? "" }
    private var hasManyProfiles: Bool { Library.shared.hasManyProfiles }
    /// Chooses that profile, once there's more than one: under its heading in the column, or beside the search
    /// when the column is only symbols.
    private let profilePicker = DropdownButton()
    /// The profiles as its menu lists them.
    private var pickerIDs: [UUID] = []

    private func refreshProfilePicker() {
        pickerIDs = ProfileChoice.fill(profilePicker, selected: profile.id)
        profilePicker.setAccessibilityLabel(ProfileChoice.label)
    }

    private func choseProfile(at index: Int) {
        guard pickerIDs.indices.contains(index) else { return }
        choose(profile: pickerIDs[index])
    }

    /// Shows a profile's things: chosen in the menu, or the one of the space Settings was asked for in.
    func choose(profile id: UUID) {
        guard id != profile.id, Library.shared.directory.profile(id) != nil else { return }
        chosenProfile = id
        profileChanged()
    }

    /// Another profile is the one shown: everything that's about one profile is read again.
    private func profileChanged() {
        layingOutOnce {
            refreshProfilePicker()
            reloadExtensions()
            reloadBlocking()
            if showsWebsiteData { reloadPrivacy(); reloadListedSiteData() }
            reloadPasswords()
            layoutDocument()
        }
    }

    /// The sections, in the column. Built again when a second profile is made or the last other one goes.
    private func buildColumn() {
        items.forEach { $0.removeFromSuperview() }
        let many = hasManyProfiles
        let sections = SettingsPane.column(manyProfiles: many)
        columnHasProfiles = many
        groupStarts = SettingsPane.groupStarts(manyProfiles: many)
        groupHeadings.values.forEach { $0.removeFromSuperview() }
        groupHeadings = Dictionary(uniqueKeysWithValues: SettingsPane.headed(manyProfiles: many).compactMap { pane in
            SettingsPane.groupTitle(startingAt: pane).map { title in
                let label = Label.groupHeading(title)
                column.addSubview(label)
                return (pane, label)
            }
        })
        items = (sections.shared + sections.profile).map { pane in
            let item = SectionItem(pane)
            item.drawsSelection = false
            item.isSelected = pane == self.pane
            item.onClick = { [weak self] _ in self?.pick(pane) }
            column.addSubview(item)
            return item
        }
        if profileHeading.superview == nil { column.addSubview(profileHeading) }
    }

    /// Where the menu is: in the column under its heading, beside the search when the column has no room for it,
    /// nowhere with a single profile.
    private func placeProfilePicker(_ arrangement: Arrangement) {
        let inColumn = columnHasProfiles && arrangement == .column
        let inHeader = columnHasProfiles && !inColumn
        // Beside the search there's room for the profile's tile, not its name too: the section's title comes first.
        profilePicker.showsPictureOnly = inHeader
        if inColumn, profilePicker.superview !== column { header.trailing = [settingSearch]; column.addSubview(profilePicker) }
        if inHeader, profilePicker.superview !== header { header.trailing = [profilePicker, settingSearch] }
        if !columnHasProfiles, profilePicker.superview != nil { header.trailing = [settingSearch]; profilePicker.removeFromSuperview() }
    }

    /// A profile made, renamed or removed while Settings is open.
    private func profilesChanged() {
        layingOutOnce {
            followProfiles()
            if showsWebsiteData { reloadPrivacy(); reloadListedSiteData() }
            reloadPasswords()
            layoutDocument()
        }
    }

    /// The column and the menu as the profiles are now: grouped or not, the profile chosen still there.
    private func followProfiles() {
        if chosenProfile.map({ Library.shared.directory.profile($0) == nil }) == true { chosenProfile = nil }
        if columnHasProfiles != hasManyProfiles {
            buildColumn()
            // Website Data went back into Privacy with the last other profile.
            let shown = pane.shown(manyProfiles: hasManyProfiles)
            if shown != pane { show(shown); onPaneChange?(shown) }
            needsLayout = true
        }
        refreshProfilePicker()
    }

    /// Whether the section shown has what websites keep, which is read when it's looked at.
    private var showsWebsiteData: Bool { pane == .privacy || pane == .websiteData }

    /// The browser window it's in, for what it opens there (History, the Chrome Web Store).
    private var browser: BrowserWindowController? {
        (window?.windowController as? BrowserWindowController) ?? WindowManager.shared.keyController ?? WindowManager.shared.controllers.first
    }

    // MARK: Reading a section's rows

    /// The sections whose rows were read from disk, WebKit or the extension host. Each is read the first time it's
    /// shown or searched, after the page has drawn, so opening Settings waits for none of them (#357).
    private var readSections: Set<SettingsPane> = []
    /// Sections asked for and not read yet.
    private var sectionsToRead: Set<SettingsPane> = []
    private var readIsQueued = false

    /// Privacy and Website Data are read together: one list makes both.
    private static func readKey(_ pane: SettingsPane) -> SettingsPane { pane == .websiteData ? .privacy : pane }

    private func isRead(_ pane: SettingsPane) -> Bool { readSections.contains(Self.readKey(pane)) }

    /// Reads these sections' rows once the page has drawn.
    private func readSoon(_ panes: [SettingsPane]) {
        sectionsToRead.formUnion(panes.map(Self.readKey).filter { !readSections.contains($0) })
        if !sectionsToRead.isEmpty { needsDisplay = true }
    }

    /// Reads the sections asked for, then lays the page out again, its scroll kept.
    private func readWaitingSections() {
        readIsQueued = false
        let panes = sectionsToRead
        sectionsToRead = []
        guard !panes.isEmpty else { return }
        readSections.formUnion(panes)
        let timing = SettingsTiming.begin("readSections"); defer { timing.end() }
        layingOutOnce {
            for pane in SettingsPane.allCases where panes.contains(pane) {
                switch pane {
                case .general: reloadWebApps()
                case .spaces: reloadSpaces()
                case .profiles: reloadProfiles()
                case .extensions: reloadExtensions()
                case .privacy: reloadPrivacy(); reloadListedSiteData()
                default: break
                }
            }
            layoutDocument()
        }
    }

    private func counted(_ read: String) {
        #if DEBUG
        debugReads[read, default: 0] += 1
        #endif
    }

    // MARK: Groups

    private func reloadExtensions() {
        guard isRead(.extensions) else { return }
        let timing = SettingsTiming.begin("reloadExtensions"); defer { timing.end() }
        counted("extensions")
        extensionsGroup.removeAllRows()
        defer { if pane == .extensions || isSearching { layoutDocument() } }
        guard #available(macOS 15.4, *) else { return }
        listAppExtensions()
        let installed = profile.extensions.installed.sorted {
            ($0.value.displayName ?? $0.key).localizedCaseInsensitiveCompare($1.value.displayName ?? $1.key) == .orderedAscending
        }
        if installed.isEmpty {
            let get = PillButton(title: String(localized: "Get Extensions", comment: "Button in Settings › Extensions: opens a menu of the Chrome Web Store and Firefox Add-ons."))
            get.onClick = { [weak self, weak get] _ in if let get { self?.showGetExtensionsMenu(from: get) } }
            extensionsGroup.add(FormRow(title: String(localized: "No extensions yet", comment: "A setting in Settings › Extensions."),
                                        detail: String(localized: "Find one in the Chrome Web Store or Firefox Add-ons and choose Add to Zigzag.", comment: "Explanation under “No extensions yet” in Settings › Extensions. Firefox Add-ons is addons.mozilla.org."),
                                        control: get))
        }
        for (id, ext) in installed {
            extensionsGroup.add(extensionRow(id: id, ext: ext))
            // Only while the feature is on: a switch under every extension is a lot of rows for a door most people
            // never open, and the master switch in Privacy reads as the one place it starts.
            if LocalReceivers.isEnabled { extensionsGroup.add(localReceiversRow(id: id)) }
            let name = ext.displayName ?? id
            // Only for one that asks to read and change sites.
            if !ext.allRequestedMatchPatterns.isEmpty {
                ExtensionSiteAccessRows.make(id: id, name: name, installs: profile.installs,
                                             add: { [weak self] in if let self { ExtensionSiteAccessRows.addSite(id: id, name: name, installs: self.profile.installs, in: self) { self.siteAccessChanged($0) } } },
                                             changed: { [weak self] in self?.siteAccessChanged($0) }).forEach(extensionsGroup.add)
            }
            extensionsGroup.add(ExtensionPrivateRow.make(id: id, name: name, installs: profile.installs))
        }
        // What your other profiles have that this one doesn't, to add without another trip to the store. Read from
        // each package, not from the other profile's running extensions: looking here starts none of them.
        let here = profile, has = Set(here.installs.installedIDs)
        let offered = Array(Set(Profiles.shared.all.filter { $0 !== here }.flatMap { $0.installs.installedIDs }).subtracting(has)).sorted()
        let listed = OtherProfilesKey(profile: here.id, ids: offered)
        // Another profile's rows never stand under this one's name while its own are read.
        if otherProfilesListing.shown?.profile != here.id {
            otherProfilesGroup.removeAllRows()
            otherProfilesListing.forget()
        }
        if offered.isEmpty {
            otherProfilesTask?.cancel()
            otherProfilesGroup.removeAllRows()
            otherProfilesListing.show(listed)
        } else if otherProfilesListing.needs(listed) {
            // Each package is read for its name and icon, which takes a moment. The rows showing stay until the new
            // ones are in, and the same extensions asked for again (any extension's change brings us here) read nothing.
            otherProfilesTask?.cancel()
            otherProfilesTask = Task { @MainActor [weak self] in
                var rows: [FormRow] = []
                for id in offered {
                    guard let folder = ExtensionStore.packageDirectory(for: id), let ext = try? await WKWebExtension(resourceBaseURL: folder) else { continue }
                    let add = PillButton(title: String(localized: "Add", comment: "Button on an extension another profile has, in Settings › Extensions: adds it to the profile shown."))
                    add.onClick = { [weak self] _ in Task { await ExtensionStore.add(id, to: here); self?.reloadExtensions() } }
                    rows.append(FormRow(title: ext.displayName ?? id,
                                        detail: String(localized: "Starts fresh here: nothing it stored in another profile comes along.", comment: "Under an extension another profile has, in Settings › Extensions."),
                                        icon: ext.icon(for: NSSize(width: 24, height: 24)), control: add))
                }
                guard let self, !Task.isCancelled, self.otherProfilesListing.arrived(listed) else { return }
                self.otherProfilesGroup.removeAllRows()
                rows.forEach(self.otherProfilesGroup.add)
                if self.pane == .extensions || self.isSearching { self.layoutDocument() }
            }
        }
    }

    /// An extension's site access changed here: the front page, if it's on a site that changed, loads again, as from
    /// the address menu. Nil is every site.
    private func siteAccessChanged(_ site: String?) {
        if let tabs = browser?.tabManager, tabs.profile === profile, let tab = tabs.selectedTab, let front = SiteRoutes.site(of: tab.url),
           site.map({ SiteRoutes.covers($0, front) }) ?? true {
            tab.reload()
        }
        reloadExtensions()
    }

    /// Looks through the apps in Applications for extensions that come inside them, off the main thread, then lists
    /// them. When the Extensions page opens, and only then.
    private func findAppExtensions() {
        appExtensionsTask?.cancel()
        appExtensionsTask = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { AppBundledExtensions.find() }.value
            guard let self, !Task.isCancelled else { return }
            self.appExtensionsFound = found
            if #available(macOS 15.4, *) { self.listAppExtensions() }
        }
    }

    /// From Apps on This Mac: what was found, less what this profile has installed already, each with Install. Read
    /// from each folder for its name and icon; the rows showing stay until the new ones are in.
    @available(macOS 15.4, *)
    private func listAppExtensions() {
        let here = profile, has = Set(here.installs.installedIDs)
        let offered = appExtensionsFound.filter { !has.contains(ExtensionStore.unpackedID(for: $0.folder)) }
        let key = offered.map(\.folder.path)
        if offered.isEmpty {
            appExtensionsGroup.removeAllRows()
            appExtensionsListing.show(key)
            return
        }
        guard appExtensionsListing.needs(key) else { return }
        Task { @MainActor [weak self] in
            var rows: [FormRow] = []
            for found in offered {
                guard let ext = try? await WKWebExtension(resourceBaseURL: found.folder) else { continue }
                let install = PillButton(title: String(localized: "Install", comment: "Button on an extension that comes inside an app, in Settings › Extensions › From Apps on This Mac."))
                install.onClick = { [weak self] _ in self?.install(found) }
                rows.append(FormRow(title: ext.displayName ?? found.appName,
                                    detail: String(localized: "Comes with \(found.appName)", comment: "Under an extension in Settings › Extensions › From Apps on This Mac: the app on this Mac it comes inside, like StopTheMadness Pro."),
                                    icon: ext.icon(for: NSSize(width: 24, height: 24)), control: install))
            }
            guard let self, self.appExtensionsListing.arrived(key) else { return }
            self.appExtensionsGroup.removeAllRows()
            rows.forEach(self.appExtensionsGroup.add)
            if self.pane == .extensions || self.isSearching { self.layoutDocument() }
        }
    }

    /// Installs an extension from its host app, read in place so app updates update it. Shows its permissions first, as
    /// for store installs.
    private func install(_ found: AppBundledExtensions.Found) {
        let profile = profile
        confirmUnpacked(found.folder, from: found.appName) { [weak self] in
            if await ExtensionStore.loadUnpacked(found.folder, in: profile) == nil, let host = self {
                ConfirmSheet.notice(in: host, title: String(localized: "Couldn’t load this extension", comment: "Title of the notice when an unpacked extension can't load."),
                                    message: String(localized: "\(found.appName) may have changed or moved. Open it once, then try again.",
                                                    comment: "Message of the notice when an extension that comes inside an app can't install. The placeholder is the app, like StopTheMadness Pro."))
            }
            self?.reloadExtensions()
        }
    }

    /// Confirms an unpacked extension: its permissions, Add or Cancel. Unreadable ones go straight to the load error.
    private func confirmUnpacked(_ folder: URL, from appName: String?, install: @escaping @MainActor () async -> Void) {
        // Only on Settings' own window, never another (private, another profile's).
        guard #available(macOS 15.4, *), let window, let host = window.contentView else { return }
        Task { @MainActor in
            guard let (info, report) = await ExtensionStore.reviewUnpacked(folder) else { await install(); return }
            let content = ExtensionSheet.Content(
                icon: info.icon(for: NSSize(width: 40, height: 40)),
                title: info.displayName.map { String(localized: "Add \($0)?", comment: "Title of the sheet that asks before adding an extension. The name is the extension's.") }
                    ?? String(localized: "Add this extension?", comment: "Title of the sheet that asks before adding an extension that has no name."),
                subtitle: appName.map { String(localized: "Comes inside \($0) on this Mac", comment: "Under the title of the sheet that asks before adding an extension that comes inside an app. The placeholder is the app, like StopTheMadness Pro.") }
                    ?? String(localized: "From a folder on this Mac", comment: "Under the title of the sheet that asks before adding an extension from a folder (Install from Folder in Settings › Extensions)."),
                heading: String(localized: "It will be able to", comment: "Heading over the list of what an extension can do, in the sheet that asks before adding it."),
                report: report,
                confirm: String(localized: "Add Extension", comment: "Button that adds the extension, in the sheet that asks first."),
                cancel: String(localized: "Cancel", comment: "Button that closes a sheet without doing anything."))
            guard let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            let confirmed = { Task { @MainActor in await install() } }
            if let controller = window.windowController as? BrowserWindowController {
                ExtensionSheet.present(content, in: controller, onConfirm: { _ = confirmed() })
            } else {
                ExtensionSheet.present(content, over: host, onConfirm: { _ = confirmed() })
            }
        }
    }

    /// What a package's record says about where it came from, beyond its version: a Firefox package says it is one.
    /// Its gecko ID and its signature file tell the person nothing they can act on, and a signature file's presence
    /// isn't a verification, so neither is said. A Chrome package adds nothing.
    static func packageKindDetail(_ id: String) -> [String] {
        guard ExtensionStore.kind(of: id) == .firefox, ExtensionStore.package(id) != nil else { return [] }
        return [String(localized: "Firefox", comment: "Under an extension's name in Settings › Extensions: it is a Firefox extension (.xpi).")]
    }

    @available(macOS 15.4, *)
    private func extensionRow(id: String, ext: WKWebExtension) -> FormRow {
        var controls: [NSView] = []
        if ExtensionStore.needsApproval(id) {
            let review = PillButton(title: String(localized: "Review Update", comment: "Button on an extension's row in Settings › Extensions, when its update asks for more access."))
            review.onClick = { [weak self] _ in
                guard let controller = self?.browser else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                controller.reviewExtensionUpdate(id)
            }
            controls.append(review)
        }
        if ExtensionStore.isUnpacked(id) {
            let reload = IconButton(symbol: "arrow.clockwise", size: .compact, toolTip: String(localized: "Reload from Its Folder", comment: "Tooltip of the reload button on an unpacked extension's row in Settings › Extensions."))
            reload.onClick = { _ in Task { await ExtensionStore.reloadUnpacked(id) } }
            controls.append(reload)
        }
        let remove = IconButton(symbol: "trash", size: .compact,
                                toolTip: String(localized: "Remove from Zigzag", comment: "The Chrome Web Store's own button once an extension is in, and the tooltip of the trash button on an extension's row in Settings › Extensions."))
        remove.onClick = { [weak self] _ in if let self { ConfirmSheet.removeExtension(id: id, name: ext.displayName, from: self.profile, in: self) } }
        controls.append(remove)
        let installs = profile.installs
        let toggle = Toggle(isOn: installs.isEnabled(id))
        toggle.setAccessibilityLabel(ext.displayName ?? id)
        toggle.onChange = { on in installs.setEnabled(id, on) }
        controls.append(toggle)
        let stack = NSStackView(views: controls)
        stack.spacing = Tokens.Space.x2

        // What matters about it at a glance, as one plain sentence.
        var detail: [String] = [ext.version.map { String(localized: "Version \($0)", comment: "An extension's version, under its name in Settings › Extensions.") } ?? ""]
            .filter { !$0.isEmpty }
        if let path = ExtensionStore.package(id)?.unpackedPath {
            if let app = AppBundledExtensions.app(containing: path) {
                detail.append(String(localized: "From \(app)", comment: "Under an extension's name in Settings › Extensions: it was installed from inside an app on this Mac, like StopTheMadness Pro."))
            } else {
                detail.append(String(localized: "Unpacked", comment: "Under an extension's name in Settings › Extensions: it was loaded from a folder."))
            }
        }
        if ExtensionStore.needsApproval(id) {
            detail.append(String(localized: "Update wants more access", comment: "Under an extension's name in Settings › Extensions."))
        }
        // A Firefox package adds one word, "Firefox"; a Chrome one adds nothing. Neither its gecko ID nor its
        // signature file is shown.
        detail += Self.packageKindDetail(id)
        // The features it asks for that Zigzag lacks, named right in the row rather than counted: "2 features"
        // says something is missing without saying what.
        var summary = detail.isEmpty ? "" : Words.list(detail)
        if let manifest = ExtensionStore.manifest(for: id) {
            // The lines only: the overlay is decoded once, behind ExtensionCompatibility.shared, and each row does
            // not build a whole report for them.
            let limits = ExtensionReport.limits(for: ext, manifest: manifest, id: id)
            if let first = limits.first {
                let names = Words.list([first.text] + limits.dropFirst().map { Words.lowercasedForList($0.text) })
                let note = String(localized: "\(names) won’t work in Zigzag.",
                                  comment: "Under an extension's name in Settings › Extensions, after its version: the features it uses that Zigzag lacks, like “Side panel and notifications won’t work in Zigzag.”")
                summary = summary.isEmpty ? note : summary + "\n" + note
            }
        }
        let row = FormRow(title: ext.displayName ?? id, detail: summary, icon: ext.icon(for: NSSize(width: 24, height: 24)), control: stack)
        row.revealsOnHover(remove)
        return row
    }

    /// Its own switch, indented under it: a grant the person gives one extension, with the reason in plain words.
    private func localReceiversRow(id: String) -> FormRow {
        let installs = profile.installs
        let toggle = Toggle(isOn: installs.localReceivers(id))
        toggle.setAccessibilityLabel(String(localized: "Let this extension reach apps on this Mac",
                                            comment: "Accessibility label of the apps-on-this-Mac switch under an extension in Settings › Extensions."))
        // Read where each call is made, so the switch takes effect at once: nothing to reload.
        toggle.onChange = { on in installs.setLocalReceivers(on, for: id) }
        let row = FormRow(title: String(localized: "Apps on This Mac",
                                        comment: "A switch under an extension in Settings › Extensions: its own code may reach a program listening on this Mac."),
                          detail: String(localized: "Lets this extension’s own code read what a program listening on this Mac answers, over loopback only. Without it, the program’s own CORS rules decide. Off until you turn it on.",
                                         comment: "Explanation under the apps-on-this-Mac switch on an extension’s row in Settings › Extensions. CORS is a web API name: keep it as it is."),
                          control: toggle)
        row.isIndented = true
        return row
    }

    private func loadUnpacked() {
        guard #available(macOS 15.4, *), let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ExtensionFilePicker.types
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Install", comment: "Button of the panel that installs an extension from a folder or a package file.")
        panel.message = String(localized: "Choose a folder that holds the extension’s manifest.json, or a Firefox extension (.xpi) file.",
                               comment: "Message of the panel that installs an extension from a folder or a .xpi file. manifest.json and .xpi are file names.")
        let profile = profile
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            // A Firefox package is installed from its file; a folder as before.
            if url.pathExtension.lowercased() == "xpi" { installPickedXPI(url, in: profile); return }
            if ExtensionStore.folderIsThemeOnly(url) { noticeCouldNotAdd(ExtensionStore.InstallError.theme.message); return }
            confirmUnpacked(url, from: nil) { [weak self] in
                if await ExtensionStore.loadUnpacked(url, in: profile) == nil, let host = self {
                    ConfirmSheet.notice(in: host, title: String(localized: "Couldn’t load this extension", comment: "Title of the notice when an unpacked extension can't load."),
                                        message: String(localized: "That folder needs a manifest.json that Zigzag can read. Choose the folder that holds it.",
                                                        comment: "Message of the notice when an unpacked extension can't load. manifest.json is a file name."))
                }
            }
        }
    }

    /// A picked `.xpi`: prepared as the store prepares a package, offered with the store's own sheet, then added.
    private func installPickedXPI(_ url: URL, in profile: Profile) {
        guard #available(macOS 15.4, *), let host = window?.contentView else { return }
        Task { @MainActor in
            switch await ExtensionStore.prepareInstallXPI(at: url) {
            case .failure(let error): noticeCouldNotAdd(error.message)
            case .success(let prepared):
                ExtensionSheet.offer(prepared, in: profile, over: host, onInstalled: { [weak self] result in
                    if case .failure(let error) = result { self?.noticeCouldNotAdd(error.message) }
                    self?.reloadExtensions()
                })
            }
        }
    }

    /// Why a picked extension file couldn't be added, in the app's own words.
    private func noticeCouldNotAdd(_ message: String) {
        guard let host = window?.contentView else { return }
        ConfirmSheet.notice(in: host, title: String(localized: "Couldn’t add this extension", comment: "Title of the notice when a picked extension file can't be added."),
                            message: message)
    }

    /// The profiles there are, each with what it holds and the ways to change it. The first has no trash: there's
    /// always one profile.
    private func reloadProfiles() {
        guard isRead(.profiles) else { return }
        let timing = SettingsTiming.begin("reloadProfiles"); defer { timing.end() }
        profilesGroup.removeAllRows()
        let library = Library.shared
        for profile in library.profiles {
            var controls: [NSView] = []
            var trash: IconButton?
            if !profile.isDefault {
                let delete = IconButton(symbol: "trash", size: .compact,
                                        toolTip: String(localized: "Delete Profile", comment: "Button of the sheet that deletes a profile, and tooltip of the trash button on a profile's row in Settings › Profiles."))
                delete.onClick = { [weak self] _ in if let self { ProfileSheets.confirmDelete(profile.id, in: self) } }
                controls.append(delete)
                trash = delete
            }
            let edit = PillButton(title: String(localized: "Edit…", comment: "Button on a profile's row in Settings › Profiles: opens the sheet that renames it and changes its color."))
            edit.onClick = { [weak self] _ in if let self { ProfileSheets.edit(profile.id, in: self) } }
            edit.setAccessibilityLabel(String(localized: "Edit “\(profile.displayName)”", comment: "VoiceOver label of the Edit button on a profile's row in Settings › Profiles; the profile's name."))
            controls.append(edit)
            let stack = NSStackView(views: controls)
            stack.spacing = Tokens.Space.x2
            let spaces = library.spaces(in: profile.id).count
            let extensions = Profiles.shared.profile(profile.id).installs.installedIDs.count
            // No "0 extensions": a profile without any lists only its spaces.
            let detail = Words.list([String(localized: "\(spaces) spaces", comment: "Under a profile's name in Settings › Profiles: how many spaces are on it.")]
                                    + (extensions == 0 ? [] : [String(localized: "\(extensions) extensions", comment: "Under a profile's name in Settings › Profiles: how many extensions it has.")]))
            let row = FormRow(title: profile.displayName, detail: detail, icon: ProfileSheets.tile(for: profile), control: stack)
            if let trash { row.revealsOnHover(trash) }
            profilesGroup.add(row)
        }
        layoutSubtreeIfNeeded()
        if pane == .profiles || isSearching { layoutDocument() }
        reloadUnlisted()
    }

    /// Data on this Mac from a profile that's in no list: a Profiles.json put back from an older backup, or one
    /// that couldn't be read, leaves it. Shown so it can be made a profile again or deleted, never deleted unasked.
    private func reloadUnlisted() {
        guard isRead(.profiles) else { return }
        counted("orphans")
        Task { @MainActor [weak self] in
            let orphans = SettingsTiming.begin("orphans")
            let found = await Profiles.shared.orphans()
            orphans.end()
            // The same data as is listed: its rows stay as they are.
            guard let self, self.unlistedListing.shown != found else { return }
            self.unlistedListing.show(found)
            self.unlistedGroup.removeAllRows()
            for id in found {
                let restore = PillButton(title: String(localized: "Restore", comment: "Button in Settings › Profiles, on data left by a profile that's no longer listed: makes it a profile again."))
                restore.onClick = { [weak self] _ in
                    Library.shared.restoreProfile(id, name: String(localized: "Restored Profile", comment: "Name a profile gets when it's made again from data left on this Mac. People can rename it."))
                    self?.reloadProfiles()
                }
                let delete = IconButton(symbol: "trash", size: .compact,
                                        toolTip: String(localized: "Delete", comment: "Tooltip of the trash button in Settings › Profiles, on data left by a profile that's no longer listed."))
                delete.onClick = { [weak self] _ in
                    self?.confirm(title: String(localized: "Delete this profile’s data?", comment: "Title of the sheet that asks before deleting data left by a profile that's no longer listed."),
                                  message: String(localized: "Its extensions and everything they hold, including any wallets, are deleted, along with its sign-ins and history. Make sure you have your recovery phrases. This can’t be undone.", comment: "Message of the sheet that asks before deleting data left by a profile that's no longer listed."),
                                  action: String(localized: "Delete", comment: "Button of the sheet that deletes data left by a profile that's no longer listed.")) {
                        Task { @MainActor in
                            await Profiles.shared.eraseOrphan(id)
                            self?.reloadUnlisted()
                        }
                    }
                }
                let stack = NSStackView(views: [delete, restore])
                stack.spacing = Tokens.Space.x2
                let row = FormRow(title: String(localized: "Data from a profile that’s no longer listed", comment: "Title of a row in Settings › Profiles, for data left on this Mac by a profile that's in no list."),
                                  detail: String(localized: "Extensions, sign-ins and history kept on this Mac", comment: "Under the title of a row in Settings › Profiles, for data left by a profile that's in no list."),
                                  icon: NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil), control: stack)
                row.revealsOnHover(delete)
                self.unlistedGroup.add(row)
            }
            self.layoutSubtreeIfNeeded()
            if self.pane == .profiles || self.isSearching { self.layoutDocument() }
        }
    }

    private func addRoute() {
        let library = Library.shared
        guard let spaceID = BrowserWindowController.undoTarget?.tabManager.currentSpaceID ?? library.spaces.first?.id else { return }
        guard let host = window?.contentView else { return }
        SiteRouteSheet.edit(.init(site: "", spaceID: spaceID), in: host, isNew: true)
    }

    private func reloadRoutes() {
        let library = Library.shared
        let rules = library.siteRoutes
        let existing = Dictionary(uniqueKeysWithValues: routeRows.map { ($0.id, $0.row) })
        routeRows = rules.enumerated().map { index, rule in
            let row = existing[rule.id] ?? SiteRouteRow(rule)
            row.refresh(rule, spaces: library.spaces, number: index + 1)
            row.onDraftChange = { [weak self] in
                self?.updateRouteWarnings()
                self?.layoutDocument()
            }
            row.onSave = library.saveRoute
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row, !row.isEditing else { return false }
                return self.beginRouteDrag(row, event: event)
            }
            return (rule.id, row)
        }
        routesGroup.setRows([routeHint] + routeRows.map(\.row))
        updateRouteWarnings()
    }

    private func updateRouteWarnings() {
        let rows = routeRows.map(\.row)
        let rules = rows.map(\.ruleForValidation)
        for (row, result) in zip(rows, SiteRoutes.coverage(in: rules)) { row.setWarning(result.warning(in: rules)) }
    }

    private func reloadSpaces() {
        guard isRead(.spaces) else { return }
        let timing = SettingsTiming.begin("reloadSpaces"); defer { timing.end() }
        reloadRoutes()
        spacesGroup.removeAllRows()
        spaceRows = Library.shared.spaces.map { space in
            let row = SpaceSettingsRow(space: space)
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDrag(row, event: event)
            }
            spacesGroup.add(row)
            return row
        }
        layoutSubtreeIfNeeded()
        syncSpaceHover()
        if pane == .spaces || isSearching { layoutDocument() }
    }

    /// When a password-manager extension is on, Zigzag's own saving and filling start off, and say why.
    /// Block ads, and, while an ad blocker extension in the profile shown handles YouTube in Zigzag's place, which.
    #if DEBUG
    /// For the debug bridge: Block ads and trackers flipped, as a click on its switch does.
    func debugFlipBlocking() {
        blockingToggle.isOn.toggle()
        blockingToggle.onChange?(blockingToggle.isOn)
    }
    #endif

    /// One switch, off, and a briefing before it can be turned on. The same words are the site row's name, so the two
    /// places read as one feature.
    private func reloadLocalReceivers() {
        localReceiversGroup.removeAllRows()
        let toggle = Toggle(isOn: LocalReceivers.isEnabled)
        toggle.setAccessibilityLabel(String(localized: "Allow websites to reach apps on this Mac",
                                            comment: "Accessibility label of the master switch in Settings › Privacy."))
        let more = PillButton(title: String(localized: "What This Allows…",
                                            comment: "Button on the apps-on-this-Mac setting in Settings › Privacy: reopens the briefing."))
        more.onClick = { [weak self] _ in if let self { self.explainLocalReceivers(reason: nil) } }
        toggle.onChange = { [weak self] on in
            guard let self else { return }
            guard on else {
                LocalReceivers.isEnabled = false
                // The switches under the extensions go with it.
                self.reloadExtensions()
                return
            }
            // The knob has already moved; the setting follows only the acknowledgement.
            toggle.isOn = LocalReceivers.isEnabled
            self.explainLocalReceivers(reason: { [weak self] in
                LocalReceivers.isEnabled = true
                toggle.isOn = true
                self?.reloadExtensions()
            })
        }
        let controls = NSStackView(views: [more, toggle])
        controls.spacing = Tokens.Space.x2
        let row = FormRow(title: String(localized: "Allow websites to reach apps on this Mac",
                                        comment: "A setting in Settings › Privacy: the master switch for a site's scripts reaching a program listening on this Mac."),
                          detail: String(localized: "A site you switch on in Site Controls can use fetch, XMLHttpRequest and WebSocket to talk to a program on this Mac, over loopback only. Never the local network, and a page can’t switch itself on.",
                                         comment: "Explanation under the apps-on-this-Mac setting in Settings › Privacy. fetch, XMLHttpRequest and WebSocket are API names: keep them as they are."),
                          control: controls)
        row.keywords = String(localized: "localhost loopback local server app fetch websocket xmlhttprequest",
                              comment: "Words that find the apps-on-this-Mac setting with Find a setting. Not shown.")
        localReceiversGroup.add(row)
    }

    /// The briefing the master switch needs before it goes on. `reason` runs only after "I understand"; without one
    /// this is the row's link, read-only.
    private func explainLocalReceivers(reason: (() -> Void)?) {
        let message = String(localized: "Websites you switch on in Site Controls can use fetch, XMLHttpRequest and WebSocket to reach programs listening on this Mac, over loopback only.\n\nThe local network, other machines, images, scripts and stylesheets are not included, and a page cannot switch itself on.\n\nA local program may not have been written to be reachable by a web page, and a site you grant could use it in ways you did not intend. Only grant sites you trust.\n\nTurn one site off in its Site Controls, or turn this setting off for every site.",
                          comment: "The briefing shown before websites may reach apps on this Mac. fetch, XMLHttpRequest and WebSocket are API names: keep them as they are.")
        guard let reason else {
            ConfirmSheet.notice(in: self, title: String(localized: "Apps on This Mac", comment: "Title of the briefing about the apps-on-this-Mac setting."),
                                message: message)
            return
        }
        ConfirmSheet.show(in: self, title: String(localized: "Before You Allow This", comment: "Title of the briefing shown before the apps-on-this-Mac setting can be turned on."),
                          message: message,
                          confirmTitle: String(localized: "I Understand", comment: "Button that acknowledges the briefing and turns the setting on.")) { agreed in
            guard agreed else { return }
            reason()
        }
    }

    private func reloadBlocking() {
        blockingGroup.removeAllRows()
        // EasyList's license asks for credit, and uBlock Origin's lists do the rest; this is where people look for what
        // does the blocking.
        var detail = String(localized: "Uses EasyList and EasyPrivacy, by the EasyList authors, and uBlock Origin’s filter lists.", comment: "Explanation under “Block ads and trackers” in Settings › Privacy. EasyList, EasyPrivacy and uBlock Origin are names of open-source filter lists: keep them as they are.")
        if ContentBlocker.isEnabled, let blocker = AdBlockers.active(in: profile) {
            detail += " " + String(localized: "\(blocker) is blocking ads on YouTube.",
                                   comment: "After the explanation under “Block ads and trackers” in Settings › Privacy, while an ad blocker extension (its name, like uBlock Origin Lite) handles YouTube instead of Zigzag.")
        }
        blockingGroup.add(FormRow(title: String(localized: "Block ads and trackers", comment: "A setting in Settings › Privacy."),
                                  detail: detail, control: blockingToggle))
        // Autoconsent's license is in Acknowledgments; this is where people look for what answers the pop-ups.
        cookieBanners.selectedIndex = CookieBanners.Mode.allCases.firstIndex(of: CookieBanners.mode) ?? 0
        let bannersDetail = Words.sentences(String(localized: "Says no to the cookies a site’s pop-up asks for, or hides a pop-up that only needs hiding. Never says yes.",
                                                   comment: "Explanation under “Cookie banners” in Settings › Privacy."),
                                            String(localized: "Uses Autoconsent, by DuckDuckGo.", comment: "After the explanation under “Cookie banners” in Settings › Privacy. Autoconsent is the name of DuckDuckGo's open-source library: keep both names as they are."))
        let bannersRow = FormRow(title: String(localized: "Cookie banners", comment: "A setting in Settings › Privacy: what Zigzag does with a site's cookie consent pop-up."),
                                 detail: bannersDetail, control: cookieBanners)
        bannersRow.keywords = String(localized: "cookies consent gdpr pop-up popup notice reject accept privacy banner", comment: "Words that find the Cookie banners setting with Find a setting in Settings. Not shown.")
        blockingGroup.add(bannersRow)
        // WebRTC (#229): only where WebKit still has the switch.
        if WebRTCProtection.isAvailable {
            webRTCToggle.isOn = WebRTCProtection.isOn
            let webRTCRow = FormRow(title: String(localized: "Protect IP address from WebRTC", comment: "A setting in Settings › Privacy: turns WebRTC off, except on sites you allow. WebRTC is a name: keep it as it is."),
                                    detail: String(localized: "WebRTC, which sites use for calls, can show them your real IP address even while you use a proxy or VPN. When on, it’s off except on sites you allow in Site Controls.",
                                                   comment: "Explanation under “Protect IP address from WebRTC” in Settings › Privacy. WebRTC is a name: keep it as it is. Site Controls is the panel from the address."),
                                    control: webRTCToggle)
            webRTCRow.keywords = String(localized: "webrtc ip address leak proxy vpn calls privacy", comment: "Words that find the Protect IP address from WebRTC setting with Find a setting in Settings. Not shown.")
            blockingGroup.add(webRTCRow)
        }
        javaScript.selectedIndex = SiteJavaScript.isAllowed ? 0 : 1
        let javaScriptRow = FormRow(title: String(localized: "JavaScript", comment: "A setting in Settings › Privacy: whether pages may run their scripts. A name: keep it as it is."),
                                    detail: String(localized: "Whether pages may run their scripts. Sites you change in Site Controls keep their own choice.",
                                                   comment: "Explanation under “JavaScript” in Settings › Privacy. Site Controls is the panel from the address."),
                                    control: javaScript)
        javaScriptRow.keywords = String(localized: "javascript js scripts disable block noscript privacy", comment: "Words that find the JavaScript setting with Find a setting in Settings. Not shown.")
        blockingGroup.add(javaScriptRow)
    }

    private func reloadPasswords() {
        passwordsGroup.removeAllRows()
        cardGroup.removeAllRows()
        passwordsWindowGroup.removeAllRows()
        // Saving and filling are chosen for each profile: a password manager is an extension, and those are a profile's.
        let profile = profile
        let saves = PasswordCapture.offersToSave(in: profile), fills = Autofill.isOn(in: profile)
        saveToggle.isOn = saves
        fillToggle.isOn = fills
        let filler = ICloudPasswords.filler(in: profile)
        passwordFiller.selectedIndex = filler == .iCloud ? 1 : 0
        let installs = profile.installs
        let fillerNote: String? = switch filler {
        case .iCloud: String(localized: "Passwords are filled by the iCloud Passwords extension. Click its icon by the address and enter the code from macOS to connect.",
                             comment: "Under “Password manager” in Settings › Passwords, with iCloud Passwords chosen. iCloud Passwords is Apple's extension, by the name Apple gives it; the code is the one the Passwords app on the Mac shows when the extension connects.")
        case .zigzag: installs.hasRecord(ICloudPasswords.id)
            ? String(localized: "The iCloud Passwords extension is installed too. You can remove it in Settings › Extensions.",
                     comment: "Under “Password manager” in Settings › Passwords, with Zigzag chosen while Apple's iCloud Passwords extension is still installed.")
            : nil
        }
        let fillerRow = FormRow(title: String(localized: "Password manager", comment: "A setting in Settings › Passwords: whether Zigzag or Apple's iCloud Passwords extension saves and fills passwords."),
                                detail: fillerNote, control: passwordFiller)
        fillerRow.keywords = String(localized: "icloud apple keychain passwords app extension autofill manager", comment: "Words that find the Password manager setting with Find a setting in Settings. Not shown.")
        passwordsGroup.add(fillerRow)
        if filler == .iCloud {
            // Chosen, then disabled or removed in Extensions: nothing fills until it's back.
            if !ICloudPasswords.isOn(in: profile) {
                let removed = !installs.isInstalled(ICloudPasswords.id)
                let button = PillButton(title: removed ? String(localized: "Add", comment: "Button in Settings › Passwords that adds Apple's iCloud Passwords extension again, after it was removed.")
                                                       : String(localized: "Turn On", comment: "Button in Settings › Passwords that turns Apple's iCloud Passwords extension back on."))
                button.onClick = { [weak self] _ in self?.choosePasswordFiller(.iCloud) }
                passwordsGroup.add(FormRow(title: String(localized: "iCloud Passwords extension", comment: "A row in Settings › Passwords, with iCloud Passwords chosen but its extension off or removed."),
                                           detail: removed ? String(localized: "Removed, so nothing fills passwords.", comment: "Under “iCloud Passwords extension” in Settings › Passwords, when the extension was removed.")
                                                           : String(localized: "Off, so nothing fills passwords.", comment: "Under “iCloud Passwords extension” in Settings › Passwords, when the extension is turned off."),
                                           control: button))
            }
        }
        let manager = PasswordManagers.active(in: profile)
        let managerNote = manager.map {
            String(localized: "Off while \($0) handles passwords. Turn on to use both.",
                   comment: "Under a password setting in Settings › Passwords, while a password manager extension (its name, like 1Password) is on.")
        }
        let saveNote = manager != nil && !saves ? managerNote!
            : String(localized: "After you sign in. Kept in your Keychain, synced with iCloud.", comment: "Explanation under “Offer to save passwords” in Settings › Passwords.")
        let fillNote = manager != nil && !fills ? managerNote!
            : String(localized: "Under sign-in fields, only on the site each was saved for. Passwords… there opens the Passwords app and password manager apps.", comment: "Explanation under “Fill saved passwords” in Settings › Passwords. Passwords… is the row in the fill-password menu; the Passwords app is Apple’s, password manager apps are ones like 1Password.")
        // With iCloud, Zigzag's two toggles are off and restored when Zigzag is chosen.
        if filler == .zigzag {
            passwordsGroup.add(FormRow(title: String(localized: "Offer to save passwords", comment: "A setting in Settings › Passwords."),
                                       detail: saveNote,
                                       control: saveToggle))
            passwordsGroup.add(FormRow(title: String(localized: "Fill saved passwords", comment: "A setting in Settings › Passwords."),
                                       detail: fillNote,
                                       control: fillToggle))
        }
        cardToggle.isOn = ContactCard.isOn
        cardToggle.onChange = { on in ContactCard.isOn = on }
        // Not a profile's: with more than one, it stands apart from the two that are.
        (hasManyProfiles ? cardGroup : passwordsGroup).add(FormRow(title: String(localized: "Fill forms from My Card", comment: "A setting in Settings › Passwords."),
                                   detail: String(localized: "Your name, email, phone and address, from your own card in Contacts.", comment: "Explanation under “Fill forms from My Card” in Settings › Passwords."),
                                   control: cardToggle))
        let open = PillButton(title: String(localized: "Open Passwords", comment: "Button in Settings › Passwords that opens the Passwords window."))
        open.onClick = { _ in PasswordsWindowController.show() }
        // Importing is in General and in the Passwords window itself; once here would be a third time.
        passwordsWindowGroup.add(FormRow(title: String(localized: "Saved passwords", comment: "A setting in Settings › Passwords."),
                                         detail: String(localized: "See, edit, import and export them.", comment: "Explanation under “Saved passwords” in Settings › Passwords."),
                                         control: open))
    }

    private static var iCloudPasswordsName: String {
        String(localized: "iCloud Passwords", comment: "A choice for “Password manager” in Settings › Passwords: Apple's iCloud Passwords extension, by the name Apple gives it.")
    }

    /// Switches the profile to iCloud Passwords, installing (the usual sheet) or re-enabling its extension, or back to
    /// Zigzag. Switching back leaves the extension installed.
    private func choosePasswordFiller(_ filler: PasswordFiller) {
        let profile = profile
        let id = ICloudPasswords.id
        switch filler {
        case .zigzag:
            ICloudPasswords.useZigzag(in: profile)
        case .iCloud:
            let installs = profile.installs
            switch PasswordFiller.need(installed: installs.isInstalled(id), enabled: installs.isEnabled(id)) {
            case .nothing:
                ICloudPasswords.use(in: profile)
            case .turnOn:
                installs.setEnabled(id, true)
                ICloudPasswords.use(in: profile)
            case .install:
                // Only once installed; cancelled or failed keeps Zigzag.
                guard let browser else { break }
                browser.installExtension(id, into: profile, also: { [weak self] stage in
                    switch stage {
                    case .added: if ICloudPasswords.isOn(in: profile) { ICloudPasswords.use(in: profile) }
                    case .failed, .cancelled, .theme: break
                    case .downloading, .reviewing, .adding: return
                    }
                    self?.reloadPasswords()
                    self?.layoutDocument()
                })
                return
            }
        }
        reloadPasswords()
        layoutDocument()
    }

    private func reloadTranslation() {
        translationGroup.removeAllRows()
        alwaysGroup.removeAllRows()
        let system = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        let systemName = PageTranslator.name(of: system)
        translateInto.options = [DropdownButton.Option(title: String(localized: "\(systemName) (System)",
                                                                     comment: "The first choice of Translate pages into, in Settings › Translation: the Mac's language, by name."), image: nil)]
            + languages.map { DropdownButton.Option(title: $0.name, image: nil) }
        translateInto.selectedIndex = PageTranslator.chosenLanguage.flatMap { chosen in languages.firstIndex { $0.id == chosen }.map { $0 + 1 } } ?? 0
        translateOffer.isOn = PageTranslator.offers
        translationGroup.add(FormRow(title: String(localized: "Translate pages into", comment: "A setting in Settings › Translation."),
                                     detail: String(localized: "The language you read.", comment: "Explanation under “Translate pages into” in Settings › Translation."),
                                     control: translateInto))
        translationGroup.add(FormRow(title: String(localized: "Offer to translate", comment: "A setting in Settings › Translation."),
                                     detail: String(localized: "When a page is in another language, Zigzag asks once per site.", comment: "Explanation under “Offer to translate” in Settings › Translation."),
                                     control: translateOffer))
        neverGroup.removeAllRows()
        let choices = PageTranslator.Choices()
        let name = { (code: String) in PageTranslator.name(of: Locale.Language(identifier: code)) }
        let (always, never) = choices.entries(name: name)
        // Laid out like Sites in Privacy: a heading, Reset All beside it only when there's something to reset.
        func resetAll(_ entries: [PageTranslator.Choices.Entry]) -> PillButton? {
            guard !entries.isEmpty else { return nil }
            let reset = PillButton(title: String(localized: "Reset All", comment: "Button beside Always Translate in Settings › Translation."))
            reset.onClick = { [weak self] _ in
                entries.forEach(choices.remove)
                self?.reloadTranslation()
                self?.layoutDocument()
            }
            return reset
        }
        alwaysReset = resetAll(always)
        neverReset = resetAll(never)
        func row(_ entry: PageTranslator.Choices.Entry) -> FormRow {
            let title: String, icon: NSImage
            switch entry {
            case .always(let code), .neverLanguage(let code):
                title = name(code)
                icon = SettingsIcon.symbol("translate")
            case .neverSite(let site):
                title = site
                icon = URL(string: "https://\(site)").flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            }
            let remove = PillButton(title: String(localized: "Remove", comment: "Button on a row in Settings › Developer: takes the site or the page size off its list."))
            remove.setAccessibilityLabel(String(localized: "Remove \(title)", comment: "VoiceOver name of the Remove button on a row in Settings › Developer: a site, like localhost, or a page size, like iPhone."))
            remove.onClick = { [weak self] _ in
                choices.remove(entry)
                self?.reloadTranslation()
                self?.layoutDocument()
            }
            return FormRow(title: title, icon: icon, control: remove)
        }
        if always.isEmpty {
            alwaysGroup.add(FormRow(title: String(localized: "None yet", comment: "Under Always Translate in Settings › Translation, when there's no language."),
                                    detail: String(localized: "To always translate a language, choose it from the translate button in the address bar.", comment: "Under Always Translate in Settings › Translation, when there's no language. The translate button is in the address bar on pages in another language."),
                                    control: NSView()))
        }
        always.map(row).forEach(alwaysGroup.add)
        if never.isEmpty {
            neverGroup.add(FormRow(title: String(localized: "None yet", comment: "Under Always Translate in Settings › Translation, when there's no language."),
                                   detail: String(localized: "Languages and sites you never translate show up here.", comment: "Under Never Translate in Settings › Translation, when there's no language or site."),
                                   control: NSView()))
        }
        never.map(row).forEach(neverGroup.add)
    }

    // MARK: Shortcuts

    /// Every shortcut, read from the menu bar itself so the list is always right.
    private func reloadShortcuts() {
        let timing = SettingsTiming.begin("reloadShortcuts"); defer { timing.end() }
        counted("shortcuts")
        listedShortcuts = shortcutsInMenu
        var groups: [(String, FormGroup)] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            let group = FormGroup()
            func walk(_ menu: NSMenu, prefix: String) {
                for item in menu.items where !item.isSeparatorItem {
                    if let sub = item.submenu { walk(sub, prefix: item.title + " › "); continue }
                    guard Shortcuts.isListed(item) else { continue }
                    // A list of what each key does doesn't need the menu's "…".
                    let title = prefix + (item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title)
                    let row = ShortcutRow(title: title, item: item)
                    row.onChange = { [weak self] in
                        self?.reloadShortcuts()
                        self?.layoutDocument()
                    }
                    row.showTakenNoteIfNeeded()
                    group.add(row)
                }
            }
            walk(menu, prefix: "")
            // The View menu, found by what it holds rather than by its name.
            if menu.items.contains(where: { $0.action == #selector(BrowserWindowController.selectTabByNumber(_:)) }) {
                for (title, keys) in [(String(localized: "Go to Tab 1 to 8 or the Last Tab", comment: "A shortcut in Settings › Shortcuts, under View."), ["⌘", "1–9"]),
                                      (String(localized: "Go to Space 1 to 9", comment: "A shortcut in Settings › Shortcuts, under View."), ["⌃", "1–9"])] {
                    group.add(ShortcutRow(title: title, keys: keys))
                }
            }
            if !group.rows.isEmpty { groups.append((top.title == "Zigzag" ? "Zigzag" : top.title, group)) }
        }
        shortcutGroups = groups
    }

    /// Each shortcut's menu item, name and keys as the menus have them now: a row holds its item.
    private var shortcutsInMenu: [String] {
        Shortcuts.allItems.map { "\(ObjectIdentifier($0).hashValue) \($0.title) \($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue) \($0.isHidden)" }
    }

    /// Makes the rows again only when the menus' shortcuts changed, not at every key typed in the search.
    private func readShortcuts() {
        if listedShortcuts != shortcutsInMenu { reloadShortcuts() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === settingSearch.field { searchChanged() }
        if (obj.object as? NSTextField) === flagSearch.field { layoutDocument() }
        if (obj.object as? NSTextField) === siteDataToolbar.search.field { siteDataList.model?.query = siteDataToolbar.search.stringValue }
        if (obj.object as? NSTextField) === downloadRuleTest.field { updateDownloadRuleTest() }
    }

    // MARK: Finding a setting

    private var searchWords: [String] { settingSearch.stringValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var isSearching: Bool { !searchWords.isEmpty }

    private func searchChanged() {
        items.forEach { $0.isSelected = !isSearching && $0.pane == pane }
        moveSectionSelection(animated: false)
        refreshTitle()
        readShortcuts()
        if isSearching { readSoon(SettingsPane.allCases) }
        // "Find a setting" finds sites by name too: the list is read if no pane with it has been shown yet.
        if isSearching, siteDataList.model == nil || siteDataList.model?.state == .idle { reloadSiteData() }
        layoutDocument()
        documentView.scroll(.zero)
    }

    /// Escape empties the search, and the section you were on comes back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === flagSearch.field, selector == #selector(cancelOperation(_:)), !flagSearch.stringValue.isEmpty {
            flagSearch.stringValue = ""
            layoutDocument()
            return true
        }
        if control === siteDataToolbar.search.field, selector == #selector(cancelOperation(_:)), !siteDataToolbar.search.stringValue.isEmpty {
            siteDataToolbar.search.stringValue = ""
            siteDataList.model?.query = ""
            return true
        }
        guard control === settingSearch.field, selector == #selector(cancelOperation(_:)), isSearching else { return false }
        settingSearch.stringValue = ""
        searchChanged()
        return true
    }

    #if DEBUG
    /// The titles of the rows a search shows, from every section.
    var debugFound: [String] {
        SettingsPane.allCases.flatMap { groups(of: $0) }.flatMap { $0.group.rows }
            .compactMap { $0.isHidden ? nil : ($0 as? FormRow)?.debugTitle }
    }

    /// The headings on the page, top to bottom.
    var debugHeadings: [String] {
        documentView.subviews.compactMap { $0 as? Label }.filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.stringValue)
    }

    /// The space between the Site Permissions heading and its rows.
    var debugSitesGap: CGFloat? {
        documentView.subviews.compactMap { $0 as? Label }.first { $0.stringValue == Self.sitesHeading }
            .map { sitesGroup.frame.minY - $0.frame.maxY }
    }

    /// Site Permissions' rows: a title, then ": " and the dropdown's choice where it has one.
    var debugSiteRows: [String] {
        sitesGroup.rows.compactMap { $0 as? FormRow }.map { row in
            let dropdown = (row.control as? NSStackView)?.arrangedSubviews.first as? DropdownButton
            return dropdown.map { "\(row.debugTitle): \($0.options[$0.selectedIndex].title)" } ?? row.debugTitle
        }
    }

    /// Picks a choice in a site's permission dropdown, as a click there does.
    func debugChooseSitePermission(_ title: String, _ choice: String) {
        guard let row = sitesGroup.rows.compactMap({ $0 as? FormRow }).first(where: { $0.debugTitle == title }),
              let dropdown = (row.control as? NSStackView)?.arrangedSubviews.first as? DropdownButton,
              let index = dropdown.options.firstIndex(where: { $0.title == choice }) else { return }
        dropdown.selectedIndex = index
        dropdown.onSelect?(index)
    }

    var debugScroll: NSScrollView? { scroll }
    var debugSiteDataReady: Bool { siteDataList.model?.state == .loaded && siteDataList.debugListed > 0 }
    var debugSiteDataCount: Int { siteDataList.model?.entries.count ?? 0 }
    var debugSiteDataTop: CGFloat { siteDataGroup.frame.minY }
    var debugSiteDataHeight: CGFloat { siteDataGroup.frame.height }
    var debugSiteDataExpanded: Bool { siteDataList.debugExpanded && siteDataGroup.frame.height > SiteDataList.rowHeight * CGFloat(SiteDataList.collapsedCount + 2) }
    func debugSiteDataShowAll() { siteDataList.showsAll = true }

    /// sitedata find <text> | sort name|size | state <path>: the list's search typed, its order chosen, or what it
    /// shows written as JSON.
    func debugSiteData(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = f.count > 1 ? f[1] : ""
        switch f.first ?? "" {
        case "find":
            siteDataToolbar.search.stringValue = rest
            siteDataList.model?.query = rest
        case "sort":
            siteDataToolbar.sort.selectedIndex = rest == "size" ? 1 : 0
            siteDataList.model?.order = rest == "size" ? .size : .name
        case "showall": siteDataList.showsAll = true
        case "remove":
            // As the sheet's Remove does once you've said yes, then the list read again from WebKit.
            guard let model = siteDataList.model, let entry = model.entries.first(where: { $0.site == rest }) else { break }
            Task {
                await model.remove([entry])
                model.refresh()
            }
        case "top":
            documentView.scroll(NSPoint(x: 0, y: max(0, siteDataGroup.frame.minY - 120)))
        case "state":
            let model = siteDataList.model
            let state: [String: Any] = ["sites": model?.entries.count ?? 0, "shown": model?.shown.count ?? 0, "listed": siteDataList.debugListed,
                                        "rowViews": siteDataList.debugRowViews, "first": model?.shown.prefix(5).map(\.site) ?? [],
                                        "sizes": model?.hasSizes ?? false, "height": siteDataGroup.frame.height, "remove": siteDataToolbar.removeAll.title]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: rest)) }
        default: break
        }
    }

    /// keptcookies clear | add | quit on|off | top: Clear Cookies… or Add Site… pressed, the quit switch flipped as a
    /// click does, or the page scrolled to them.
    func debugKeptCookies(_ arg: String) {
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        switch arg {
        case "clear": if let click { clearCookiesButton?.onClick?(click) }
        case "add": if let click { addKeptButton?.onClick?(click) }
        case "quit on", "quit off":
            guard let toggle = clearOnQuitToggle else { break }
            toggle.isOn = arg == "quit on"
            toggle.onChange?(toggle.isOn)
        case "top":
            guard let button = clearCookiesButton else { break }
            documentView.scroll(NSPoint(x: 0, y: max(0, button.convert(button.bounds, to: documentView).minY - 160)))
        default: break
        }
    }

    /// Chooses the password filler, as the menu does.
    func debugChoosePasswordFiller(_ name: String) {
        if let filler = PasswordFiller(rawValue: name) { choosePasswordFiller(filler) }
    }

    func debugFind(_ text: String) {
        settingSearch.stringValue = text
        searchChanged()
        debugReadNow()
    }

    /// How many times each slow read has run: site data, extensions, profile orphans, web apps, privacy.
    private(set) var debugReads: [String: Int] = [:]

    /// Reads the sections waiting for the page to draw, as the next frame would.
    func debugReadNow() { readWaitingSections() }

    /// flags find <text> | all | top: Settings › Developer › Feature Flags searched, Show All opened, or scrolled to.
    func debugFlags(_ arg: String) {
        let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch f.first ?? "" {
        case "find":
            flagSearch.stringValue = f.count > 1 ? f[1] : ""
            layoutDocument()
        case "all":
            flagsShowAll = true
            layoutDocument()
        default: break
        }
        if let heading = documentView.subviews.compactMap({ $0 as? Label }).first(where: { $0.stringValue == Self.featureFlagsHeading }) {
            documentView.scroll(NSPoint(x: 0, y: max(0, heading.frame.minY - Tokens.Space.x4)))
        }
    }

    /// The rows the feature flags show: each key, with whether its switch is on and "Changed" shows.
    var debugFlagRows: [String] {
        flagControls.values.filter { !$0.row.isHidden && $0.row.superview?.superview != nil }
            .map { "\($0.flag.key) \($0.toggle.isOn ? "on" : "off")\($0.changed.isHidden ? "" : " changed")" }.sorted()
    }

    /// What a scripted check reads: the section and profile shown, the column as it's built, the headings of the
    /// section's groups, and whether Zigzag saves and fills passwords in that profile.
    /// How many times the page has been laid out, for a check that it isn't laid out more than it needs.
    private(set) var debugLayouts = 0

    var debugState: [String: Any] {
        let profile = profile
        return ["layouts": debugLayouts, "flags": debugFlagRows, "flagsAvailable": FeatureFlags.isAvailable, "inOtherProfiles": otherProfilesGroup.rows.count,
                "pane": pane.rawValue, "profile": Library.shared.directory.profile(profile.id)?.name ?? "",
                "column": items.map(\.pane.rawValue), "grouped": columnHasProfiles,
                "menu": profilePicker.superview === column ? "column" : profilePicker.superview === header ? "header" : "none",
                "headings": groups(of: pane).map { $0.title ?? "" },
                "saves": PasswordCapture.offersToSave(in: profile), "fills": Autofill.isOn(in: profile), "found": debugFound,
                "manager": PasswordManagers.active(in: profile) ?? "", "filler": ICloudPasswords.filler(in: profile).rawValue]
    }
    #endif

    /// ⌘F on Settings finds a setting, rather than text in the empty page under it.
    @objc func showFindBar(_ sender: Any?) {
        window?.makeFirstResponder(settingSearch.field)
    }

    // The groups' headings, each said once for the page and its search.
    private static var webAppsHeading: String { String(localized: "Installed Apps", comment: "A heading in Settings › General: the sites installed as apps with File › Install as App.") }
    private static var updatesHeading: String { String(localized: "Updates", comment: "A heading in Settings › General: Zigzag's version and how it updates.") }
    private static var downloadRulesHeading: String { String(localized: "Hand Off Downloads and Links", comment: "A heading in Settings › Downloads, over the rules that send a download or a link to another app.") }
    private static var downloadTypesHeading: String { String(localized: "File Types", comment: "A heading in Settings › Downloads, over the file types and where their downloads go.") }
    private static var downloadTestHeading: String { String(localized: "Test a Rule", comment: "A heading in Settings › Downloads, over the address field that shows which rule would take it.") }
    private static var connectHeading: String { String(localized: "Connect an App", comment: "A heading in Settings › Automation: how to connect an AI app to Zigzag over MCP.") }
    private static var localServersHeading: String { String(localized: "Local Servers", comment: "A heading in Settings › Developer: development servers running on this Mac.") }
    private static var trustedCertificatesHeading: String { String(localized: "Trusted Certificates", comment: "A heading in Settings › Developer: local servers whose certificate you chose to trust, so Zigzag doesn't warn again.") }
    private static var pageSizesHeading: String { String(localized: "Page Sizes", comment: "A heading in Settings › Developer: the sizes the developer tools offer for a page.") }
    private static var developmentSitesHeading: String { String(localized: "Sites in Developer Mode", comment: "A heading in Settings › Developer: the sites the developer tools show on.") }
    private static var featureFlagsHeading: String { String(localized: "Feature Flags", comment: "A heading in Settings › Developer, as Safari's Develop menu names them: WebKit's switches for new and experimental features.") }
    private static var scriptsHeading: String { String(localized: "Scripts", comment: "A heading in Settings › Automation: what AppleScript and Shortcuts may do in Zigzag.") }
    private static var spacesHeading: String { String(localized: "Your Spaces", comment: "A heading in Settings › Spaces.") }
    private static var routesHeading: String { String(localized: "Sites in Spaces", comment: "A heading in Settings › Spaces, over the sites that always open in a space you chose, whatever space or app the link came from.") }
    private static var profilesHeading: String { String(localized: "Your Profiles", comment: "A heading in Settings › Profiles.") }
    private static var unlistedHeading: String { String(localized: "Not Listed", comment: "A heading in Settings › Profiles, over data left on this Mac by profiles that are no longer in the list.") }
    private static var sitesHeading: String { String(localized: "Site Permissions", comment: "A heading in Settings › Privacy: camera, location, pop-ups and other choices made for single sites.") }
    private static var localReceiversHeading: String {
        String(localized: "Apps on This Mac", comment: "A heading in Settings › Privacy, over the master switch that lets websites reach programs on this Mac.")
    }
    private static var alwaysTranslateHeading: String { String(localized: "Always Translate", comment: "A heading in Settings › Translation.") }
    private static var neverTranslateHeading: String { String(localized: "Never Translate", comment: "A heading in Settings › Translation, over the languages and sites never offered or translated on their own.") }
    private static var fillingHeading: String { String(localized: "AutoFill", comment: "A heading in Settings › Passwords: when Zigzag offers to save and fill passwords and forms.") }
    /// With more than one profile, over the one row every profile shares: what it fills, named plainly, so it doesn't
    /// read as a second heading for what the one over saving and filling passwords already says.
    private static var formsHeading: String { String(localized: "Forms", comment: "A heading in Settings › Passwords, with more than one profile, over “Fill forms from My Card”, which every profile shares.") }
    // Over what's one profile's, a heading names the profile once there's more than one: it's the one chosen in the
    // column's menu. A heading that names none is over what every profile shares.
    private var browsingDataHeading: String {
        hasManyProfiles ? String(localized: "Clear Browsing Data in \(profileName)", comment: "A heading in Settings › Website Data, with more than one profile: buttons that clear history, cache and cookies. The placeholder is a profile's name.")
            : String(localized: "Clear Browsing Data", comment: "A heading in Settings › Privacy: buttons that clear history, cache and cookies.")
    }
    private var siteDataHeading: String {
        hasManyProfiles ? String(localized: "Stored by Websites in \(profileName)", comment: "A heading in Settings › Website Data, with more than one profile: what each site keeps on this Mac, with a Remove button each. The placeholder is a profile's name.")
            : String(localized: "Stored by Websites", comment: "A heading in Settings › Privacy: what each site keeps on this Mac, with a Remove button each.")
    }
    private var installedHeading: String {
        hasManyProfiles ? String(localized: "Installed in \(profileName)", comment: "A heading in Settings › Extensions, with more than one profile: the extensions the profile has. The placeholder is a profile's name.")
            : String(localized: "Installed", comment: "A heading in Settings › Extensions: the extensions you have.")
    }
    private var savingHeading: String {
        hasManyProfiles ? String(localized: "Saving and Filling in \(profileName)", comment: "A heading in Settings › Passwords, with more than one profile: whether Zigzag offers to save and fill passwords in the profile. The placeholder is a profile's name.")
            : Self.fillingHeading
    }
    /// The groups that clear and list what websites keep: in Privacy, or in a section of their own once there's
    /// more than one profile (`SettingsPane.websiteData(manyProfiles:)`).
    private var websiteDataGroups: [(title: String?, group: FormGroup)] { [(browsingDataHeading, privacyGroup), (siteDataHeading, siteDataGroup)] }
    private static var otherProfilesHeading: String { String(localized: "In Other Profiles", comment: "A heading in Settings › Extensions: extensions your other profiles have and the one shown doesn't.") }
    private static var appExtensionsHeading: String { String(localized: "From Apps on This Mac", comment: "A heading in Settings › Extensions: extensions that come inside apps installed on this Mac, to install from there.") }
    /// What a button says for a moment once it has cleared something.
    private static var cleared: String { String(localized: "Cleared", comment: "Shown on a Clear button in Settings › Privacy for a moment after it clears.") }

    /// Each section's groups and their headings, as a search goes through them.
    private func groups(of pane: SettingsPane) -> [(title: String?, group: FormGroup)] {
        switch pane {
        case .general: [(nil, generalGroup)] + (webAppsGroup.rows.isEmpty ? [] : [(Self.webAppsHeading, webAppsGroup)]) + [(Self.updatesHeading, versionGroup)]
        case .downloads: [(nil, downloadPlaceGroup), (Self.downloadTypesHeading, downloadTypesGroup), (Self.downloadRulesHeading, downloadRulesGroup), (Self.downloadTestHeading, downloadTestGroup)]
        case .appearance: [(nil, appearanceGroup)]
        case .tabs: [(nil, tabsGroup)]
        case .search: [(nil, searchGroup)]
        case .mini: [(nil, miniGroup)]
        case .spaces: [(nil, newSpacesGroup), (Self.spacesHeading, spacesGroup)] + (Library.shared.spaces.count > 1 ? [(Self.routesHeading, routesGroup)] : [])
        case .profiles: [(Self.profilesHeading, profilesGroup), (Self.unlistedHeading, unlistedGroup)]
        case .passwords: [(nil, passwordsWindowGroup), (savingHeading, passwordsGroup)] + (hasManyProfiles ? [(Self.formsHeading, cardGroup)] : [])
        case .privacy: [(nil, blockingGroup), (Self.localReceiversHeading, localReceiversGroup), (Self.sitesHeading, sitesGroup)] + (SettingsPane.websiteData(manyProfiles: hasManyProfiles) == .privacy ? websiteDataGroups : [])
        case .websiteData: SettingsPane.websiteData(manyProfiles: hasManyProfiles) == .websiteData ? websiteDataGroups : []
        case .translation: [(nil, translationGroup), (Self.alwaysTranslateHeading, alwaysGroup), (Self.neverTranslateHeading, neverGroup)]
        case .extensions: [(installedHeading, extensionsGroup), (Self.appExtensionsHeading, appExtensionsGroup), (Self.otherProfilesHeading, otherProfilesGroup)]
        case .shortcuts: shortcutGroups.map { ($0.0, $0.1) }
        case .automation: [(nil, aiGroup), (Self.connectHeading, connectGroup), (Self.scriptsHeading, scriptsGroup)]
        case .developer: [(nil, developerToolsGroup), (Self.developmentSitesHeading, developmentSitesGroup), (Self.localServersHeading, localServersGroup), (Self.trustedCertificatesHeading, trustedCertificatesGroup), (Self.pageSizesHeading, pageSizesGroup)]
        }
    }

    // MARK: Layout

    /// Several things read again, the page laid out once: what `reloads` reads may each ask for a layout, and one
    /// is done at the end if any did. Without it, choosing another profile laid the page out three times over.
    private func layingOutOnce(_ reloads: () -> Void) {
        heldLayouts += 1
        reloads()
        heldLayouts -= 1
        guard heldLayouts == 0, layoutIsWanted else { return }
        layoutIsWanted = false
        layoutDocument()
    }

    private func layoutDocument() {
        guard heldLayouts == 0 else { layoutIsWanted = true; return }
        #if DEBUG
        debugLayouts += 1
        #endif
        isLayingOutDocument = true
        defer { isLayingOutDocument = false }
        // What's on the page stays on it and is only moved: taken off and put back, everything would fade out and in
        // when the page changes size inside an animation, instead of gliding to its place.
        var placed = Set<ObjectIdentifier>()
        func place(_ view: NSView) {
            if view.superview !== documentView { documentView.addSubview(view) }
            placed.insert(ObjectIdentifier(view))
        }
        var part = 0
        // A label or button made for this layout: the one made last time for the same place, if it says the same.
        func made<Part: NSView>(_ says: String, _ make: () -> Part) -> Part {
            part += 1
            let key = "\(part) \(says)"
            if let part = madeParts[key] as? Part { return part }
            let new = make()
            madeParts[key] = new
            return new
        }
        let width = paneWidth
        laidOutWidth = width
        // Whatever the last layout placed and this one didn't comes off. The page is as tall as its rows and no
        // taller, so it scrolls only when they don't fit, whatever the height in view.
        func finish(_ y: CGFloat) {
            for view in documentView.subviews where !placed.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
            madeParts = madeParts.filter { placed.contains(ObjectIdentifier($0.value)) }
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: y)
        }
        // The pane lines up with the header over it: the shared margins and maximum width, centered past it.
        let span = contentSpan(in: width)
        let pad = span.x, contentWidth = span.width
        var y: CGFloat = Tokens.Space.x3

        // A section: a quiet label low in its slot, standing in for a divider, then the group. A button that acts on the
        // whole group (New Space, Reset All) sits at the label's right, lined up with the rows' own controls.
        func section(_ title: String?, _ group: FormGroup, accessory: NSView? = nil, groupTopInset: CGFloat = 0) {
            var accessory = accessory
            // The sites' list has its search and Remove All by its heading, narrower on a narrow page.
            if group === siteDataGroup {
                siteDataToolbar.searchWidth = min(200, max(120, round(contentWidth / 3)))
                siteDataToolbar.showsSort = (siteDataList.model?.hasSizes ?? false) && contentWidth > 560
                accessory = siteDataToolbar
            }
            if title != nil || accessory != nil {
                let size = accessory.map { $0.fittingSize } ?? .zero
                let slot = max(Tokens.Metric.sectionLabelHeight, size.height + Tokens.Space.x2)
                let label = made(title ?? "") { Label.groupHeading(title ?? "") }
                let labelY = y + slot - Tokens.Space.x2 - label.lineHeight
                label.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: labelY,
                                     width: max(0, contentWidth - size.width - Tokens.Space.x4 - Tokens.Page.groupPad), height: label.lineHeight)
                place(label)
                if let accessory {
                    // Centered on the heading's caps, which the system font draws below the line's middle.
                    let capsMiddle = label.frame.midY + Label.capsBelowMiddle(of: label.font ?? Tokens.Font.label(), lineHeight: label.lineHeight)
                    accessory.frame = NSRect(x: pad + contentWidth - Tokens.Page.groupPad - size.width, y: round(capsMiddle - size.height / 2),
                                             width: size.width, height: size.height)
                    place(accessory)
                }
                y += slot
            }
            y += groupTopInset
            group.frame = NSRect(x: pad, y: y, width: contentWidth, height: group.fittingHeight(for: contentWidth))
            group.needsLayout = true
            place(group)
            y = group.frame.maxY + Tokens.Page.groupGap
        }

        // A line in the rows' own explanation style, wrapping on a narrow page.
        func explanation(_ text: String) -> NSTextField {
            made(text) {
                let label = NSTextField(wrappingLabelWithString: text)
                label.font = Tokens.Font.detail()
                label.textColor = Tokens.Color.textSecondary
                label.isSelectable = false
                return label
            }
        }
        // One said once under a group.
        func note(_ text: String) {
            let label = explanation(text)
            let textWidth = max(0, contentWidth - Tokens.Page.groupPad * 2) + Label.inset * 2
            let height = ceil(label.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
            label.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y - Tokens.Page.groupGap + Tokens.Space.x2, width: textWidth, height: height)
            place(label)
            y = label.frame.maxY + Tokens.Page.groupGap
        }

        // A search: what matches, from every section, under the section's name.
        let words = searchWords
        for pane in SettingsPane.allCases {
            for (title, group) in groups(of: pane) { group.filter(words, names: [pane.title, pane.keywords, title ?? ""]) }
        }
        if isSearching {
            var found = false
            for pane in SettingsPane.allCases {
                let shown = groups(of: pane).filter { $0.group.rows.contains { !$0.isHidden } }
                guard !shown.isEmpty else { continue }
                found = true
                let heading = made(pane.title) { Label(pane.title, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary) }
                heading.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y, width: contentWidth - Tokens.Page.groupPad, height: heading.lineHeight)
                place(heading)
                y = heading.frame.maxY + Tokens.Space.x3
                for (title, group) in shown { section(title, group) }
                y += Tokens.Space.x2
            }
            if !found {
                let words = settingSearch.stringValue.trimmingCharacters(in: .whitespaces)
                let none = made(words) {
                    Label(String(localized: "No settings match “\(words)”.", comment: "In Settings when Find a setting finds nothing; what was typed."),
                          font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
                }
                none.alignment = .center
                none.frame = NSRect(x: pad, y: y + Tokens.EmptyState.noMatchTop, width: contentWidth, height: none.lineHeight)
                place(none)
                y = none.frame.maxY + Tokens.Space.x6
            }
            finish(y)
            return
        }

        switch pane {
        case .downloads:
            section(nil, downloadPlaceGroup)
            section(Self.downloadTypesHeading, downloadTypesGroup, accessory: addFileTypeButton)
            section(Self.downloadRulesHeading, downloadRulesGroup, accessory: addDownloadRuleButton)
            section(Self.downloadTestHeading, downloadTestGroup)
        case .general, .appearance, .tabs, .search, .mini, .automation:
            for (title, group) in groups(of: pane) { section(title, group) }
        case .spaces:
            section(nil, newSpacesGroup)
            section(Self.spacesHeading, spacesGroup, accessory: addSpaceButton)
            // Said once, under the list, and only when there's an order to change.
            if spaceRows.count > 1 {
                note(String(localized: "Drag a space to change its order.", comment: "Hint under Your Spaces in Settings › Spaces."))
                section(Self.routesHeading, routesGroup, accessory: addRouteButton)
            }
        case .profiles:
            section(Self.profilesHeading, profilesGroup, accessory: addProfileButton)
            note(String(localized: "Each profile has its own extensions, sign-ins, history and favorites. Spaces on the same profile share them.", comment: "Under the list in Settings › Profiles."))
            if !unlistedGroup.rows.isEmpty { section(Self.unlistedHeading, unlistedGroup) }
        case .passwords, .websiteData:
            for (title, group) in groups(of: pane) { section(title, group) }
        case .privacy:
            // Each group once, in groups(of:) order: counting them here laid Site Permissions out twice (#420).
            for (title, group) in groups(of: pane) { section(title, group, accessory: group === sitesGroup ? sitesReset : nil) }
        case .translation:
            section(nil, translationGroup)
            section(Self.alwaysTranslateHeading, alwaysGroup, accessory: alwaysReset)
            section(Self.neverTranslateHeading, neverGroup, accessory: neverReset)
        case .developer:
            section(nil, developerToolsGroup)
            // Sites rows are one line, while Page Sizes rows carry a second: lower this group so the first Remove
            // button lines up with Page Sizes.
            section(Self.developmentSitesHeading, developmentSitesGroup, accessory: addSiteButton, groupTopInset: 7)
            note(String(localized: "A site covers every port and its subdomains: localhost is localhost:3000 and app.localhost too.", comment: "Under the list in Settings › Developer."))
            section(Self.localServersHeading, localServersGroup)
            section(Self.trustedCertificatesHeading, trustedCertificatesGroup, accessory: trustedCertificatesAddSite, groupTopInset: 7)
            note(String(localized: "Local servers whose certificate you chose to trust. Zigzag doesn’t warn again while a server shows that certificate. Removing a server brings the warning back.",
                        comment: "Under Trusted Certificates in Settings › Developer."))
            section(Self.pageSizesHeading, pageSizesGroup, accessory: addSizeButton)
            guard DeveloperTools.isOn, let flags = FeatureFlags.flags, !flags.isEmpty else { break }
            // Feature Flags (#173): its name set as a heading over the groups by status, with Reset to Defaults and
            // its own search at its right; a line saying when a change takes effect, with Reload All Tabs; then
            // WebKit's flags, the ones for its own engineers folded under Show All.
            let h = Tokens.Page.controlHeight
            let heading = made(Self.featureFlagsHeading) { Label(Self.featureFlagsHeading, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary) }
            var right = pad + contentWidth - Tokens.Page.groupPad
            let searchWidth = min(Tokens.Page.searchWidth - Tokens.Space.x10, max(0, contentWidth / 3))
            flagSearch.frame = NSRect(x: right - searchWidth, y: y, width: searchWidth, height: h)
            place(flagSearch)
            right = flagSearch.frame.minX - Tokens.Space.x2
            if FeatureFlags.hasOverrides {
                let rw = flagsReset.fittingWidth
                flagsReset.frame = NSRect(x: right - rw, y: y, width: rw, height: h)
                place(flagsReset)
                right = flagsReset.frame.minX - Tokens.Space.x2
            }
            heading.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y + round((h - heading.lineHeight) / 2),
                                   width: max(0, right - pad - Tokens.Page.groupPad), height: heading.lineHeight)
            place(heading)
            y += h + Tokens.Space.x3
            let lw = flagsReload.fittingWidth
            flagsReload.frame = NSRect(x: pad + contentWidth - Tokens.Page.groupPad - lw, y: y, width: lw, height: h)
            place(flagsReload)
            let hint = explanation(String(localized: "Changes apply to pages you open or reload.", comment: "Under Feature Flags in Settings › Developer, beside Reload All Tabs."))
            let hintWidth = max(0, contentWidth - Tokens.Page.groupPad * 2 - lw - Tokens.Space.x4) + Label.inset * 2
            let hintHeight = ceil(hint.sizeThatFits(NSSize(width: hintWidth, height: 400)).height)
            let lineHeight = ceil(hint.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? hintHeight)
            hint.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y + round((h - lineHeight) / 2), width: hintWidth, height: hintHeight)
            place(hint)
            y = max(y + h, hint.frame.maxY)
            // A search goes through every flag, folded or not.
            let words = flagSearch.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
            var found = false
            func statuses(_ list: [FeatureFlags.Status]) {
                for status in list where flags.contains(where: { $0.status == status }) {
                    let group = flagGroup(status, flags)
                    guard group.filter(words) > 0 else { continue }
                    found = true
                    section(status.title, group)
                }
            }
            statuses(FeatureFlags.Status.listed)
            if !words.isEmpty {
                statuses(FeatureFlags.Status.more)
                if !found {
                    let typed = words.joined(separator: " ")
                    let none = made("noflags " + typed) {
                        Label(String(localized: "No flags match “\(typed)”.", comment: "In Settings › Developer › Feature Flags when its search finds nothing; what was typed."),
                              font: Tokens.Font.row(), color: Tokens.Color.textSecondary)
                    }
                    y += Tokens.Space.x4
                    none.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y, width: contentWidth - Tokens.Page.groupPad, height: none.lineHeight)
                    place(none)
                    y = none.frame.maxY + Tokens.Page.groupGap
                }
            } else if flags.contains(where: { FeatureFlags.Status.more.contains($0.status) }) {
                if !found { y += Tokens.Space.x4 }
                flagsMore.isOpen = flagsShowAll
                flagsMore.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y - Tokens.Space.x2, width: flagsMore.fittingWidth, height: h)
                place(flagsMore)
                y = flagsMore.frame.maxY + Tokens.Space.x2
                if flagsShowAll { statuses(FeatureFlags.Status.more) } else { y += Tokens.Page.groupGap - Tokens.Space.x2 }
            }
        case .extensions:
            // With nothing installed, the empty row already offers Get Extensions; once said is enough.
            getExtensionsButton.isHidden = !hasExtensions
            checkUpdatesButton.isHidden = !hasExtensions
            let buttons: NSStackView = made("buttons") {
                let buttons = NSStackView(views: [checkUpdatesButton, loadUnpackedButton, getExtensionsButton])
                buttons.spacing = Tokens.Space.x2
                return buttons
            }
            section(installedHeading, extensionsGroup, accessory: buttons)
            if !appExtensionsGroup.rows.isEmpty { section(Self.appExtensionsHeading, appExtensionsGroup) }
            if !otherProfilesGroup.rows.isEmpty { section(Self.otherProfilesHeading, otherProfilesGroup) }
        case .shortcuts:
            let resetAll: PillButton = made("reset") {
                let resetAll = PillButton(title: String(localized: "Reset All…", comment: "Button in Settings › Shortcuts that puts every shortcut back."))
                // Every shortcut you set, back to how Zigzag comes: asked first, as Sites' Reset All is.
                resetAll.onClick = { [weak self] _ in
                    self?.confirm(title: String(localized: "Reset all shortcuts?", comment: "Title of the sheet that puts every shortcut back."),
                                  message: String(localized: "Every shortcut you changed goes back to its default.", comment: "Message of the sheet that puts every shortcut back."),
                                  action: String(localized: "Reset All", comment: "Button of the sheet that puts every shortcut back.")) {
                        Shortcuts.resetAll()
                        ShortcutRow.lastTaken = nil
                        self?.reloadShortcuts()
                        self?.layoutDocument()
                    }
                }
                return resetAll
            }
            resetAll.isHidden = !Shortcuts.hasChanges
            let rw = resetAll.fittingWidth, rh = Tokens.Page.controlHeight
            resetAll.frame = NSRect(x: pad + contentWidth - Tokens.Page.groupPad - rw, y: y, width: rw, height: rh)
            place(resetAll)
            // Wraps on a narrow page rather than losing its end, its first line beside Reset All.
            let hint = explanation(String(localized: "Click a shortcut to change or remove it. To find one, type its name or keys in Find a setting.",
                                           comment: "Hint at the top of Settings › Shortcuts. “Find a setting” is the search field's placeholder."))
            let hintWidth = max(0, contentWidth - Tokens.Page.groupPad * 2 - (resetAll.isHidden ? 0 : rw + Tokens.Space.x4)) + Label.inset * 2
            let hintHeight = ceil(hint.sizeThatFits(NSSize(width: hintWidth, height: 400)).height)
            let lineHeight = ceil(hint.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? hintHeight)
            hint.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y + round((rh - lineHeight) / 2), width: hintWidth, height: hintHeight)
            place(hint)
            y = max(y + rh, hint.frame.maxY) + Tokens.Space.x2
            for (title, group) in shortcutGroups { section(title, group) }
        }
        finish(y)
    }

    /// The labels and buttons the last layout made for the page, by where they go and what they say.
    private var madeParts: [String: NSView] = [:]

    private var hasExtensions: Bool {
        // Before the rows are read, from what's installed, without starting the profile's extensions.
        guard isRead(.extensions) else { return !profile.installs.installedIDs.isEmpty }
        if #available(macOS 15.4, *) { return !profile.extensions.installed.isEmpty }
        return false
    }

    private func refreshDownloadPlace() { DownloadPlace.configure(downloadPlace) }

    private func refreshDownloadPlaceRules() { DownloadPlace.configure(downloadPlaceRules) }

    // MARK: Download rules

    /// Rule rows in order; each toggles, drags, edits or deletes its rule.
    private func reloadDownloadRules() {
        downloadRulesGroup.removeAllRows()
        downloadRuleRows = []
        updateDownloadRuleTest()
        reloadDownloadTypes()
        // File types have their own list below; only handoff rules here.
        let rules = DownloadRulesStore.shared.rules.filter { !$0.action.kind.isDestination }
        guard !rules.isEmpty else {
            let empty = FormRow(title: String(localized: "No rules yet", comment: "In Settings › Downloads, when no rule has been made."),
                                detail: String(localized: "Everything else is saved by Zigzag, as before.", comment: "Under “No rules yet” in Settings › Downloads."),
                                control: NSView())
            empty.keywords = String(localized: "add rule aria2 motrix rtorrent mpv", comment: "Words that find the empty download rules list with Find a setting. Not shown.")
            downloadRulesGroup.add(empty)
            return
        }
        for rule in rules {
            let toggle = Toggle(isOn: rule.isEnabled)
            toggle.onChange = { isOn in DownloadRulesStore.shared.setEnabled(isOn, for: rule.id) }
            toggle.setAccessibilityLabel(String(localized: "Turn \(rule.name) on or off", comment: "A download rule's switch for VoiceOver. The placeholder is the rule's name."))

            let edit = IconButton(symbol: "slider.horizontal.3", size: .compact,
                                  toolTip: String(localized: "Change Rule", comment: "Tooltip of the button that changes a download rule."))
            edit.onClick = { [weak self] _ in
                guard let self else { return }
                DownloadRuleSheet.show(in: self, kind: rule.action.kind, rule: rule)
            }
            let remove = IconButton(symbol: "trash", size: .compact,
                                    toolTip: String(localized: "Delete Rule", comment: "Tooltip of the button that deletes a download rule."))
            remove.onClick = { [weak self] _ in
                self?.confirm(title: String(localized: "Delete “\(rule.name)”?", comment: "Title of the sheet that deletes a download rule. The placeholder is its name."),
                              message: String(localized: "Its addresses are saved by Zigzag again, and nothing else changes.",
                                              comment: "Message of the sheet that deletes a download rule."),
                              action: String(localized: "Delete", comment: "Button of the sheet that deletes a download rule.")) {
                    DownloadRulesStore.shared.remove(id: rule.id)
                }
            }

            let controls = NSStackView(views: [toggle, edit, remove])
            controls.orientation = .horizontal
            controls.spacing = Tokens.Space.x1
            controls.distribution = .fill
            controls.alignment = .centerY
            let content = FormRow(title: rule.name.isEmpty ? String(localized: "Untitled Rule", comment: "A download rule with no name yet.") : rule.name,
                                  detail: rule.summarySentence, control: controls)
            content.keywords = "\(rule.pattern) \(rule.action.textFields.joined(separator: " "))"
            content.revealsOnHover(remove)
            let row = DraggableRow(content)
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDownloadRuleDrag(row, event: event)
            }
            downloadRulesGroup.add(row)
            downloadRuleRows.append((rule.id, row))
            // The rule's all-sites answer, stored on the rule so it travels with it and is cleared here, not per site.
            if let own = rule.handoffAnswer {
                let forget = IconButton(symbol: "xmark", size: .compact,
                                        toolTip: String(localized: "Forget the Answer for Every Site", comment: "Tooltip of the button that forgets a download rule's standing answer about handing off, which it was given for every site."))
                forget.onClick = { [weak self] _ in
                    var remembered = rule
                    remembered.handoffAnswer = nil
                    DownloadRulesStore.shared.update(remembered)
                    self?.reloadDownloadRules()
                }
                let answer = Self.handoffAnswerRow(ruleNamed: rule.name, answer: Self.handoffAnswerName(own),
                                                   sites: String(localized: "Every site", comment: "Under a download rule in Settings › Downloads: the answer beside it was given for every site, not just one."))
                let everySite = FormRow(title: answer.title, detail: answer.detail, control: forget)
                everySite.keywords = "\(answer.title) \(answer.detail)"
                downloadRulesGroup.add(everySite)
            }
            // Sites with a saved answer, grouped by answer (handed off, left to the browser, refused) so a refusal
            // doesn't read as a handoff. Each can be forgotten alone.
            for group in Self.handoffAnswerGroups(SitePermissions.decisions(prefix: PermissionSubject.handoff(rule.id))) {
                let perSite = NSStackView()
                perSite.orientation = .horizontal
                perSite.spacing = Tokens.Space.x2
                perSite.alignment = .centerY
                for site in group.sites {
                    let forget = IconButton(symbol: "xmark", size: .compact,
                                            toolTip: String(localized: "Forget \(SiteOrigin.label(site))", comment: "Tooltip of the button that forgets one site's answer about a download rule. The placeholder is the site's name."))
                    forget.onClick = { [weak self] _ in
                        SitePermissions.remember(nil, subject: PermissionSubject.handoff(rule.id), origin: site)
                        self?.reloadDownloadRules()
                    }
                    perSite.addArrangedSubview(forget)
                }
                let answer = Self.handoffAnswerRow(ruleNamed: rule.name, answer: group.title,
                                                   sites: group.sites.map(SiteOrigin.label).joined(separator: ", "))
                let sitesRow = FormRow(title: answer.title,
                                       detail: answer.detail, control: perSite)
                sitesRow.keywords = "\(answer.title) \(group.title) \(group.sites.joined(separator: " "))"
                downloadRulesGroup.add(sitesRow)
            }
        }
        // The one thing the list can't show: drag to reorder.
        let hint = FormRow(title: String(localized: "Rules run from the top", comment: "In Settings › Downloads, under the rules: the first match wins."),
                           detail: rules.count > 1 ? String(localized: "Drag one to change its order.",
                                                             comment: "Under the download rules in Settings › Downloads, when there is an order to change.") : nil,
                           control: NSView())
        downloadRulesGroup.add(hint)
    }

    /// A row for a saved answer: the rule as title, the answer and its sites as detail.
    static func handoffAnswerRow(ruleNamed name: String, answer: String, sites: String) -> (title: String, detail: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Untitled Rule", comment: "A download rule with no name yet.")
            : name
        return (title, String(localized: "\(sites): \(answer)", comment: "Under a download rule in Settings › Downloads: the sites, then the answer kept for them, like “youtube.com: Hand Off”."))
    }

    /// Answered sites grouped by answer in the prompt's order (handed off, browser, refused), empty groups dropped.
    static func handoffAnswerGroups(_ decided: [(origin: String, action: String)]) -> [(title: String, sites: [String])] {
        ["handOff", "browser", "deny"].compactMap { action in
            let sites = decided.filter { $0.action == action }.map(\.origin)
            return sites.isEmpty ? nil : (handoffAnswerName(action), sites)
        }
    }

    /// The answer's name: the prompt button's label.
    static func handoffAnswerName(_ action: String) -> String {
        switch action {
        case "handOff": String(localized: "Hand Off", comment: "Button that runs the named download rule for a link or download.")
        case "browser": String(localized: "Open in Browser", comment: "Button that lets a link or download stay in the browser instead of running a download rule.")
        default: String(localized: "Don’t Allow", comment: "Button on a site's permission question.")
        }
    }

    /// Per-extension destinations under Save downloads to, one row each. They are ordinary rules (same switch, Change
    /// and Delete), matching the file name and acting as a folder or the Mac's app.
    private func reloadDownloadTypes() {
        downloadTypesGroup.removeAllRows()
        let rules = DownloadRulesStore.shared.rules.filter { $0.action.kind.isDestination }
        guard !rules.isEmpty else {
            let empty = FormRow(title: String(localized: "No file types yet", comment: "In Settings › Downloads, when no file type has a destination of its own."),
                                detail: String(localized: "Every download is saved to the folder above, whatever kind of file it is.",
                                               comment: "Under “No file types yet” in Settings › Downloads."),
                                control: NSView())
            empty.keywords = String(localized: "extension type pdf epub save destination", comment: "Words that find the empty file types list with Find a setting. Not shown.")
            downloadTypesGroup.add(empty)
            return
        }
        for (index, rule) in rules.enumerated() {
            let types = DownloadRule.Match.extensions(in: rule.pattern).joined(separator: ", ")
            let toggle = Toggle(isOn: rule.isEnabled)
            toggle.onChange = { isOn in DownloadRulesStore.shared.setEnabled(isOn, for: rule.id) }
            toggle.setAccessibilityLabel(String(localized: "Turn \(types) on or off", comment: "A per-extension destination's switch for VoiceOver. The placeholder is the file extensions it names, like pdf, epub."))

            let previous = index > 0 ? rules[index - 1].id : nil
            let next = index < rules.count - 1 ? rules[index + 1].id : nil
            let up = IconButton(symbol: "chevron.up", size: .compact,
                                toolTip: String(localized: "Move Up", comment: "Tooltip of the button that moves a download rule up the list."))
            up.isEnabled = previous != nil
            up.onClick = { _ in if let previous { DownloadRulesStore.shared.move(rule.id, before: previous) } }
            let down = IconButton(symbol: "chevron.down", size: .compact,
                                  toolTip: String(localized: "Move Down", comment: "Tooltip of the button that moves a download rule down the list."))
            down.isEnabled = next != nil
            down.onClick = { _ in if let next { DownloadRulesStore.shared.move(next, before: rule.id) } }

            let edit = IconButton(symbol: "slider.horizontal.3", size: .compact,
                                  toolTip: String(localized: "Change File Type", comment: "Tooltip of the button that changes a per-extension destination."))
            edit.onClick = { [weak self] _ in
                guard let self else { return }
                DownloadRuleSheet.show(in: self, kind: rule.action.kind, rule: rule)
            }
            let remove = IconButton(symbol: "trash", size: .compact,
                                    toolTip: String(localized: "Delete File Type", comment: "Tooltip of the button that deletes a per-extension destination."))
            remove.onClick = { [weak self] _ in
                self?.confirm(title: String(localized: "Delete the \(types) file type?", comment: "Title of the sheet that deletes a per-extension destination. The placeholder is the extensions it names, like pdf, epub."),
                              message: String(localized: "Files of this type are saved where downloads go again.",
                                              comment: "Message of the sheet that deletes a per-extension destination."),
                              action: String(localized: "Delete", comment: "Button of the sheet that deletes a download rule.")) {
                    DownloadRulesStore.shared.remove(id: rule.id)
                }
            }

            let controls = NSStackView(views: [toggle, up, down, edit, remove])
            controls.orientation = .horizontal
            controls.spacing = Tokens.Space.x1
            controls.distribution = .fill
            controls.alignment = .centerY
            let content = FormRow(title: types.isEmpty ? String(localized: "Untitled File Type", comment: "A per-extension destination with no extensions yet.") : types,
                                  detail: rule.destinationSentence, control: controls)
            content.keywords = "\(rule.pattern) \(rule.action.textFields.joined(separator: " "))"
            content.revealsOnHover(remove)
            downloadTypesGroup.add(content)
        }
    }

    /// Tests the address as a link and as a download: the first matching rule and its expanded first field.
    private func updateDownloadRuleTest() {
        // A wrapping result adds a line, so relayout.
        defer { if pane == .downloads, paneWidth > 0 { layoutDocument() } }
        guard let row = downloadRuleTestRow else { return }
        let typed = downloadRuleTest.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            row.detailText = ""
            return
        }
        // Scheme-less input is https, as in the address bar.
        let url = URL(string: typed).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "https://\(typed)")
        guard let url, url.scheme != nil else {
            row.detailText = String(localized: "That isn’t an address.", comment: "Under the test address in Settings › Downloads, when what was typed can't be a URL.")
            return
        }
        let rules = DownloadRulesStore.shared.rules
        let linkMatch = DownloadRulesStore.firstMatch(in: rules, url: url, appliesToLinks: true)
        // As a download, list order decides: an earlier file type beats a later handoff.
        let name = url.lastPathComponent
        let downloadMatch = DownloadRulesStore.firstHandoffMatch(in: rules, url: url, filename: name, appliesToLinks: false)
        guard let rule = linkMatch ?? downloadMatch else {
            // Destinations match file names, so test those too.
            if !name.isEmpty, let (destination, _) = DownloadRulesStore.destination(in: rules, url: url, filename: name) {
                row.detailText = destination.destinationSentence
            } else {
                row.detailText = String(localized: "No rule matches, so Zigzag saves it in Downloads.", comment: "Under the test address in Settings › Downloads, when no rule takes it.")
            }
            return
        }
        let values = HandoffValues(link: url, filename: DownloadTokens.filename(for: url, suggested: ""), space: "")
        let preview = rule.action.textFields.first.map { DownloadTokens.expand($0, with: values) } ?? ""
        let detail = preview.isEmpty ? rule.summarySentence : "\(rule.summarySentence)\n\(preview)"
        // A downloads-only rule catches it as a file, not as a link.
        row.detailText = linkMatch == nil
            ? "\(String(localized: "As a download", comment: "Under the test address in Settings › Downloads, before the rule that would take the address if it were a file.")): \(detail)"
            : detail
    }

    /// Add Rule: presets first (most want aria2 or Motrix), then Custom… for the four manual actions.
    private func showDownloadRuleMenu() {
        let entries: [MenuPanel.Entry] = DownloadPreset.allCases.map { preset in
            .item(MenuPanel.Item(title: preset.title, symbol: preset.rule.action.kind.symbol) { [weak self] in
                guard let self else { return }
                DownloadRuleSheet.show(in: self, kind: preset.rule.action.kind, preset: preset)
            })
        } + [
            .separator,
            .item(MenuPanel.Item(title: String(localized: "Custom…", comment: "An item in the Add Rule menu of Settings › Downloads: the actions that aren't a ready-made rule — an app, a URL, a script or a JSON-RPC service."),
                                 symbol: "slider.horizontal.3") { [weak self] in
                guard let self else { return }
                self.showCustomRuleMenu()
            }),
        ]
        MenuPanel.show(entries, from: addDownloadRuleButton) { [weak addDownloadRuleButton] in
            addDownloadRuleButton?.isSelected = false
        }
    }

    /// Custom…: the four actions, none preselected. Destinations come from Add File Type under Save downloads to.
    private func showCustomRuleMenu() {
        let entries: [MenuPanel.Entry] = DownloadRuleAction.Kind.allCases.filter { !$0.isDestination }.map { kind in
            .item(MenuPanel.Item(title: kind.title, symbol: kind.symbol) { [weak self] in
                guard let self else { return }
                DownloadRuleSheet.show(in: self, kind: kind)
            })
        }
        let menu = MenuPanel.show(entries, from: addDownloadRuleButton) { [weak self] in
            self?.addDownloadRuleButton.isSelected = false
        }
        // Opening this closed the parent menu, which deselected the button; keep it selected.
        if menu != nil { addDownloadRuleButton.isSelected = true }
    }

    /// An engine's icon: its site's, or for Custom with no address yet, a plain magnifying glass (never Google's).
    private static func engineIcon(_ engine: SearchEngine) -> NSImage? {
        if engine == .custom, !SearchEngine.isValidTemplate(SearchEngine.customTemplate) {
            return Tokens.Symbol.image("magnifyingglass", size: Tokens.Symbol.inline)
        }
        return FaviconStore.shared.cachedIcon(for: engine.homeURL).map(menuIcon)
            ?? (engine == .custom ? Tokens.Symbol.image("magnifyingglass", size: Tokens.Symbol.inline) : nil)
    }

    /// Zigzag's engines, then those extensions give, with the one you search with picked.
    private func refreshEngines() {
        engineProviders = ExtensionSearchProvider.available
        engineProviders.forEach { if FaviconStore.shared.cachedIcon(for: $0.homeURL) == nil { FaviconStore.shared.prefetch(for: $0.homeURL) } }
        let builtIn = SearchEngine.builtIn
        engine.options = builtIn.map { DropdownButton.Option(title: $0.name, image: Self.engineIcon($0)) }
            + engineProviders.map { DropdownButton.Option(title: $0.name, image: FaviconStore.shared.cachedIcon(for: $0.homeURL).map(Self.menuIcon)) }
        let chosen = ExtensionSearchProvider.chosen.flatMap { engineProviders.firstIndex(of: $0) }.map { builtIn.count + $0 }
        engine.selectedIndex = chosen ?? builtIn.firstIndex(of: Library.shared.searchEngine) ?? 0
    }

    private static var aiAppsKeywords: String {
        String(localized: "mcp ai agent automation model context protocol server", comment: "Words that find the Let AI apps use Zigzag setting with Find a setting in Settings. Not shown.")
    }

    /// The guide to AI apps and MCP, docs/automation.md, in a new tab of the window Settings is in.
    static let automationGuide = URL(string: "https://github.com/ZigaoWang/zigzag/blob/main/docs/automation.md")!

    private func openAutomationGuide() {
        guard let controller = browser else { return }
        controller.tabManager.newTab(url: Self.automationGuide)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Copies with the AI apps' key are marked concealed and transient so clipboard managers skip them.
    static func copy(_ text: String, concealed: Bool = false, to board: NSPasteboard = .general) {
        Clipboard.write(text, marked: concealed, to: board)
    }

    /// The address and key show only while AI apps may use Zigzag; the address says so if the server couldn't start.
    private func refreshAIApps() {
        let shown = MCPService.isOn
        // Turned on or off elsewhere (another Settings tab): the switch follows.
        if aiAppsToggle.isOn != shown { aiAppsToggle.isOn = shown }
        let detail = MCPService.problem == nil ? MCPService.address
            : MCPService.replacedKeyForBusyPort
            ? String(localized: "Couldn’t start. Port \(Int(MCPService.port)) is in use by another app, so Zigzag made a new key. Give your AI apps the new key.",
                     comment: "Under “Server address” in Settings › Automation when another app holds the MCP server's port: Zigzag replaced the key, since an AI app connecting there may have sent the old one to that app. The placeholder is a port number.")
            : String(localized: "Couldn’t start. Port \(Int(MCPService.port)) may be in use by another app.",
                     comment: "Under “Server address” in Settings › Automation when Zigzag's MCP server couldn't start. The placeholder is a port number.")
        let rows = [aiAddressRow, aiKeyRow, aiSetupRow, aiPromptRow]
        guard rows.contains(where: { $0.isAvailable != shown }) || aiAddressRow.detailText != detail else { return }
        aiAddressRow.detailText = detail
        rows.forEach { $0.isAvailable = shown }
        laidOutWidth = -1
        needsLayout = true
    }

    /// Pure black backgrounds shows only while dark pages are on.
    /// Under “New tabs open”: with Next to Tabs from the Same Site, where a page from a site with no tabs open goes.
    private func refreshNewTabPlace() {
        guard let newTabRow else { return }
        let general = String(localized: "Where ⌘T and links put a new tab in the sidebar.", comment: "Explanation under “New tabs open” in Settings › Tabs.")
        guard TabManager.newTabPlace == .sameSite else { newTabRow.detailText = general; return }
        newTabRow.detailText = switch TabManager.otherNewTabPlace {
        case .top: String(localized: "A page from a site with no tabs open goes at the top.", comment: "Explanation under “New tabs open” in Settings › Tabs when Next to Tabs from the Same Site is chosen.")
        case .bottom: String(localized: "A page from a site with no tabs open goes at the bottom.", comment: "Explanation under “New tabs open” in Settings › Tabs when Next to Tabs from the Same Site is chosen.")
        case .next, .sameSite: String(localized: "A page from a site with no tabs open goes next to the current tab.", comment: "Explanation under “New tabs open” in Settings › Tabs when Next to Tabs from the Same Site is chosen.")
        }
    }

    private func refreshPureBlack() {
        let shown = DarkPages.mode != .off
        guard pureBlackRow.isAvailable != shown else { return }
        pureBlackRow.isAvailable = shown
        laidOutWidth = -1
        needsLayout = true
    }

    /// Sidebar size's row follows the size: the choice shown, and the percentage there only for Custom.
    private func refreshSidebarSize() {
        sidebarSize.selectedIndex = Tokens.Sidebar.Size.allCases.firstIndex(of: Tokens.Sidebar.size) ?? 1
        sidebarSizeStepper.zoom = Tokens.Sidebar.customScale
        sidebarSizeStepper.isHidden = Tokens.Sidebar.size != .custom
        sidebarSizeRow?.needsLayout = true
        appearanceGroup.needsLayout = true
    }

    /// The custom address row shows only with Custom chosen.
    private func refreshCustomSearch() {
        let shown = Library.shared.searchEngine == .custom
        guard customSearchRow.isAvailable != shown else { return }
        customSearchRow.isAvailable = shown
        // A row came or went: the page lays out again, not just stretched.
        laidOutWidth = -1
        needsLayout = true
    }

    @objc private func customSearchChanged() {
        let text = customSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || SearchEngine.isValidTemplate(text) else {
            Toast.show(String(localized: "Use a web address with %s where the words go.",
                              comment: "Toast when the custom search address in Settings › Search isn't valid. Keep %s as it is."),
                       symbol: "exclamationmark.triangle", duration: 3, over: self, area: bounds)
            return
        }
        SearchEngine.customTemplate = text
        // Its name and icon come from the address.
        FaviconStore.shared.prefetch(for: SearchEngine.custom.homeURL)
        refresh()
    }

    private func refresh() {
        refreshEngines()
        let isDefault = DefaultBrowser.isDefault
        defaultStatus.isHidden = !isDefault
        defaultButton.isHidden = isDefault
        blockingToggle.isOn = ContentBlocker.isEnabled
        webRTCToggle.isOn = WebRTCProtection.isOn
        javaScript.selectedIndex = SiteJavaScript.isAllowed ? 0 : 1
        cookieBanners.selectedIndex = CookieBanners.Mode.allCases.firstIndex(of: CookieBanners.mode) ?? 0
        pipToggle.isOn = PictureInPicture.followsTabs
        leavePipToggle.isOn = AutoPictureInPicture.isOn
        fullScreenFill.selectedIndex = PageFullScreen.Fill.allCases.firstIndex(of: PageFullScreen.fill) ?? 0
        suggestionsToggle.isOn = SuggestionFetcher.isOn
        borderlessToggle.isOn = BrowserRootView.isBorderless
        addressAboveToggle.isOn = BrowserRootView.addressAbovePage
        sidebarSide.selectedIndex = Self.sidebarSides.firstIndex(of: BrowserRootView.sidebarOnRight) ?? 0
        doubleClickTabToggle.isOn = SidebarView.doubleClickOpensNewTab
        largeNamesToggle.isOn = SpaceHeaderView.isLarge
        quitToggle.isOn = AppDelegate.asksBeforeQuitting
        scriptJavaScriptToggle.isOn = Scripting.allowsJavaScript
        aiAppsToggle.isOn = MCPService.isOn
        developerToolsToggle.isOn = DeveloperTools.isOn
        developerBarToggle.isOn = DeveloperTools.showsInBar
        developerTrustToggle.isOn = DeveloperTools.trustsLocalServers
        refreshAIApps()
        newTabPlace.selectedIndex = TabManager.NewTabPlace.allCases.firstIndex(of: TabManager.newTabPlace) ?? 0
        controlTabOrder.selectedIndex = TabSwitcher.Order.allCases.firstIndex(of: TabSwitcher.order) ?? 0
        refreshNewTabPlace()
        pinOfferToggle.isOn = BrowserWindowController.offersToPinWanderedPage
        nestToggle.isOn = TabManager.nestsOpenedLinks
        shareTabsToggle.isOn = TabStore.windowsShareTabs
        ownProfileToggle.isOn = Library.newSpacesGetOwnProfile
        swipeToggle.isOn = SwipeNavigator.isOn
        miniToggle.isOn = MiniWindowController.opensExternalLinks
        miniKeys.keys = Shortcuts.allItems.first { $0.action == #selector(AppDelegate.newMiniWindow(_:)) }.map(Shortcuts.caps) ?? []
        energyToggle.isOn = EnergyWatch.sleepsBusyTabs
        motionToggle.isOn = Tokens.Motion.reducesMotionHere
        refreshDownloadPlace()
        archiveAfter.selectedIndex = TabArchive.After.allCases.firstIndex(of: TabArchive.after) ?? 0
        favoritesPerRow.selectedIndex = FavoritesView.perRowChoices.firstIndex(of: FavoritesView.perRow) ?? 0
        // Sidebar size's dropdown, and whether the percentage beside it shows.
        refreshSidebarSize()
        pageZoom.selectedIndex = ZoomLevels.steps.firstIndex { abs($0 - ZoomLevels.defaultZoom) < 0.001 } ?? ZoomLevels.steps.firstIndex(of: 1) ?? 0
        darkPages.selectedIndex = DarkPages.Mode.allCases.firstIndex(of: DarkPages.mode) ?? 0
        pureBlackToggle.isOn = DarkPages.pureBlack
        refreshPureBlack()
        saveToggle.isOn = PasswordCapture.offersToSave(in: profile)
        fillToggle.isOn = Autofill.isOn(in: profile)
        translateOffer.isOn = PageTranslator.offers
        generalGroup.rows.forEach { $0.needsLayout = true }
    }

    // MARK: Reordering spaces

    /// Spaces drag the way tabs do in the sidebar: the space stays where it is, faint, a see-through copy follows
    /// the pointer, and a line shows where it will land. Nothing else moves until it's dropped.
    private func beginDrag(_ row: SpaceSettingsRow, event: NSEvent) -> Bool {
        guard let window, let startIndex = spaceRows.firstIndex(where: { $0 === row }) else { return false }
        SpaceEditorPanel.current?.close()
        SpaceSettingsRow.isReordering = true
        spaceRows.forEach { $0.isHovered = false }
        // Lifted for its picture: its own solid card, so the copy reads off the list.
        row.isLifted = true
        let copy = CarriedCopy(of: row, picture: CarriedCopy.picture(of: row), grabbedAt: window.convertPoint(toScreen: event.locationInWindow),
                               ground: nil, radius: Tokens.Radius.row)
        row.isLifted = false
        row.alphaValue = CarriedCopy.faint
        copy.lift()
        let line = InsertionLineView()
        line.isHidden = true
        spacesGroup.addSubview(line)
        let others = spaceRows.filter { $0 !== row }
        var target = startIndex
        let released = CarriedCopy.track(in: window) { event in
            copy.follow(window.convertPoint(toScreen: event.locationInWindow))
            self.documentView.autoscroll(with: event)
            // Its new place: after every other space whose middle is above the pointer.
            let y = self.spacesGroup.convert(event.locationInWindow, from: nil).y
            target = others.filter { $0.frame.midY < y }.count
            line.isHidden = target == startIndex
            let edge = target < others.count ? others[target].frame.minY : others.last?.frame.maxY ?? 0
            Tokens.Motion.withoutAnimation { line.frame = NSRect(x: 0, y: round(edge) - 3, width: self.spacesGroup.bounds.width, height: 6) }
        }
        line.removeFromSuperview()
        SpaceSettingsRow.isReordering = false
        let spaceID = row.spaceID
        if released != nil, target != startIndex {
            BrowserWindowController.changeLibrary(String(localized: "Move Space", comment: "What Edit › Undo undoes after a space is dragged to a new place.")) {
                Library.shared.moveSpace(spaceID, to: target)
            }
        }
        reloadSpaces()
        layoutSubtreeIfNeeded()
        row.alphaValue = 1
        copy.land(on: spaceRows.first { $0.spaceID == spaceID }) { [weak self] in self?.syncSpaceHover() }
        return true
    }

    /// Hover follows where the pointer really is, once rows have moved or been rebuilt under it.
    private func syncSpaceHover() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        for row in spaceRows {
            row.isHovered = row.window != nil && row.bounds.contains(row.convert(mouse, from: nil))
        }
    }

    // MARK: Reordering download rules

    /// Drags like a space: the rule stays faint in place, a translucent copy follows the pointer, and a line marks the
    /// drop. Nothing moves until drop.
    private func beginDownloadRuleDrag(_ row: DraggableRow, event: NSEvent) -> Bool {
        guard let window, let startIndex = downloadRuleRows.firstIndex(where: { $0.row === row }) else { return false }
        // Solid card for the drag image.
        row.isLifted = true
        let copy = CarriedCopy(of: row, picture: CarriedCopy.picture(of: row), grabbedAt: window.convertPoint(toScreen: event.locationInWindow),
                               ground: nil, radius: Tokens.Radius.row)
        row.isLifted = false
        row.alphaValue = CarriedCopy.faint
        copy.lift()
        let line = InsertionLineView()
        line.isHidden = true
        downloadRulesGroup.addSubview(line)
        let others = downloadRuleRows.filter { $0.row !== row }
        var target = startIndex
        let released = CarriedCopy.track(in: window) { event in
            copy.follow(window.convertPoint(toScreen: event.locationInWindow))
            self.documentView.autoscroll(with: event)
            // New index: after every other rule whose middle is above the pointer.
            let y = self.downloadRulesGroup.convert(event.locationInWindow, from: nil).y
            target = others.filter { $0.row.frame.midY < y }.count
            line.isHidden = target == startIndex
            let edge = target < others.count ? others[target].row.frame.minY : others.last?.row.frame.maxY ?? 0
            Tokens.Motion.withoutAnimation { line.frame = NSRect(x: 0, y: round(edge) - 3, width: self.downloadRulesGroup.bounds.width, height: 6) }
        }
        line.removeFromSuperview()
        let ruleID = downloadRuleRows[startIndex].id
        if released != nil, target != startIndex {
            // The store's change signal rebuilds the list. The list shows only handoff rules, so move before the target
            // rule's id, not an index.
            DownloadRulesStore.shared.move(ruleID, before: target < others.count ? others[target].id : nil)
        }
        layoutSubtreeIfNeeded()
        row.alphaValue = 1
        copy.land(on: downloadRuleRows.first { $0.id == ruleID }?.row)
        return true
    }

    // MARK: Reordering space rules

    private func beginRouteDrag(_ row: SiteRouteRow, event: NSEvent) -> Bool {
        let order = routeRows
        let visible = order.filter { !$0.row.isHidden }
        guard let window, visible.count > 1, let startIndex = visible.firstIndex(where: { $0.row === row }) else { return false }
        let id = visible[startIndex].id
        // Lifted for its picture: its own solid card, so the copy reads off the list.
        row.isLifted = true
        let copy = CarriedCopy(of: row, picture: CarriedCopy.picture(of: row), grabbedAt: window.convertPoint(toScreen: event.locationInWindow),
                               ground: nil, radius: Tokens.Radius.row)
        row.isLifted = false
        let originalOpacity = row.alphaValue
        row.alphaValue = CarriedCopy.faint
        copy.lift()
        let line = InsertionLineView()
        line.isHidden = true
        routesGroup.addSubview(line)
        let others = visible.filter { $0.row !== row }
        var target = startIndex
        let released = CarriedCopy.track(in: window) { event in
            copy.follow(window.convertPoint(toScreen: event.locationInWindow))
            self.documentView.autoscroll(with: event)
            // Its new place: after every other visible row whose middle is above the pointer.
            let y = self.routesGroup.convert(event.locationInWindow, from: nil).y
            target = others.filter { $0.row.frame.midY < y }.count
            line.isHidden = target == startIndex
            let edge = target < others.count ? others[target].row.frame.minY : others.last?.row.frame.maxY ?? 0
            Tokens.Motion.withoutAnimation { line.frame = NSRect(x: 0, y: round(edge) - 3, width: self.routesGroup.bounds.width, height: 6) }
        }
        line.removeFromSuperview()
        row.alphaValue = originalOpacity
        if released != nil, target != startIndex {
            // In search results the last visible row can have hidden rows below it. Drop just after that row.
            let before: UUID?
            if target < others.count {
                before = others[target].id
            } else if let last = others.last, let index = order.firstIndex(where: { $0.id == last.id }) {
                before = order.dropFirst(index + 1).first(where: { $0.id != id })?.id
            } else {
                before = nil
            }
            Library.shared.moveRoute(id, before: before)
        }
        layoutSubtreeIfNeeded()
        copy.land(on: routeRows.first { $0.id == id }?.row)
        return true
    }

    // MARK: Actions

    /// Whether the app has more than English to choose from.
    private static var hasLanguages: Bool { Set(Bundle.main.localizations.filter { $0 != "Base" }).count > 1 }

    /// A new language takes a fresh start: macOS gives an app its language as it launches. Asked once, with Later
    /// leaving it for the next time Zigzag opens.
    private func chooseLanguage(_ code: String?) {
        guard code != AppLanguage.chosen else { return }
        AppLanguage.chosen = code
        guard let host = window?.contentView else { return }
        let name = AppLanguage.choices.first { $0.code == code }.map { code == nil ? AppLanguage.systemName : $0.title } ?? ""
        ConfirmSheet.show(in: host, title: String(localized: "Restart Zigzag in \(name)?", comment: "Title of the sheet after picking a language in Settings › General. The placeholder is the language’s name."),
                          message: String(localized: "Your windows and tabs come back as they are. Or it switches the next time you open Zigzag.",
                                          comment: "Message of the sheet after picking a language in Settings › General."),
                          confirmTitle: String(localized: "Restart Now", comment: "Button of the sheet after picking a language in Settings › General.")) { confirmed in
            if confirmed { UpdateBackup.relaunch() }
        }
    }

    private func makeDefault() {
        DefaultBrowser.make { [weak self] in
            self?.refresh()
            self?.layoutDocument()
        }
    }

    /// On the profile of the space the window is on, as one made from the sidebar is. Its editor opens under it, as
    /// the sidebar's does: to name it, and to give it a profile of its own there (#201).
    private func addSpace() {
        let profile = browser?.tabManager.profile.id ?? Profile.defaultID
        let own = Library.newSpacesGetOwnProfile
        var made: SpaceInfo?
        BrowserWindowController.changeLibrary(String(localized: "New Space", comment: "What Edit › Undo undoes after a space is added.")) {
            made = Library.shared.addSpace(profile: profile, ownProfile: own)
        }
        // Made here rather than from the sidebar, it's still the guide's "make a space" step.
        Tutorial.complete("space")
        guard let made else { return }
        let madeProfile = own ? Library.shared.profileID(ofSpace: made.id) : nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let row = self.spaceRows.first(where: { $0.spaceID == made.id }) else { return }
            row.scrollToVisible(row.bounds)
            row.openEditor()
            if let madeProfile, SpaceEditorPanel.current?.spaceID == made.id { SpaceEditorPanel.current?.follow(madeProfile: madeProfile) }
        }
    }

    // MARK: Privacy

    /// History, website data, and every per-site decision you've made, in one place. Each button says what it
    /// did, right where you clicked.
    private func reloadPrivacy() {
        guard isRead(.privacy) else { return }
        let timing = SettingsTiming.begin("reloadPrivacy"); defer { timing.end() }
        counted("privacy")
        // Capture one profile: rows must change it even if the window switches, and it's read once.
        let profile = self.profile
        privacyGroup.removeAllRows()
        sitesGroup.removeAllRows()
        reloadLocalReceivers()
        // Ask on a site's first download, or always save.
        downloadsAskToggle.isOn = SitePermissions.asksBeforeDownloads
        downloadsAskToggle.onChange = { SitePermissions.asksBeforeDownloads = $0 }
        let downloadsAskRow = FormRow(
            title: String(localized: "Ask before a site downloads files", comment: "A setting in Settings › Privacy, under Site Permissions: whether a site's first download gets a question."),
            detail: String(localized: "With this on, the first file a site sends asks whether it may. A site you allow keeps its answer; with this off, downloads save as they always did.", comment: "Explanation under “Ask before a site downloads files” in Settings › Privacy."),
            control: downloadsAskToggle)
        downloadsAskRow.keywords = String(localized: "downloads files save block allow site permission ask", comment: "Words that find the Ask before a site downloads files setting. Not shown.")
        sitesGroup.add(downloadsAskRow)
        let history = PillButton(title: String(localized: "Clear History…", comment: "Button in Settings › Privacy."))
        history.onClick = { [weak self, weak history] _ in
            guard let profile = self?.profile else { return }
            self?.confirm(title: HistoryPage.clearTitle, message: Words.sentences(HistoryPage.clearMessage, HistoryPage.whoseNote(profile.id)),
                          action: String(localized: "Clear History", comment: "Button of the sheet that clears history.")) {
                BrowserWindowController.historyChange(String(localized: "Clear History", comment: "What Edit › Undo undoes after history is cleared.")) {
                    profile.history.remove()
                }
                if let controller = self?.browser { HistoryPage.clearedToast(in: controller) } else { history?.flash(Self.cleared) }
            }
        }
        let showHistory = PillButton(title: String(localized: "Show History", comment: "Button in Settings › Privacy that opens History."))
        showHistory.onClick = { [weak self] _ in
            guard let controller = self?.browser else { return }
            HistoryPage.open(in: controller)
        }
        let historyButtons = NSStackView(views: [showHistory, history])
        historyButtons.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: String(localized: "History", comment: "A setting in Settings › Privacy."),
                                 control: historyButtons))

        // What's cleared is the profile's shown here.
        let store = profile.store
        let only = ProfileSheets.onlyNote(profile.id)
        let cache = PillButton(title: String(localized: "Clear Cache…", comment: "Button in Settings › Privacy."))
        cache.onClick = { [weak self, weak cache] _ in
            self?.confirm(title: String(localized: "Clear the cache for every site?", comment: "Title of the sheet that clears the cache."),
                          message: Words.sentences(String(localized: "Pages load a little slower the first time you open them again. You stay signed in.", comment: "Message of the sheet that clears the cache."), only),
                          action: String(localized: "Clear Cache", comment: "Button of the sheet that clears the cache."), destructive: false) {
                Task { @MainActor in
                    await WebsiteData.clear(.cache, in: store)
                    cache?.flash(Self.cleared)
                    self?.reloadSiteData()
                }
            }
        }
        let cookies = PillButton(title: String(localized: "Clear Cookies…", comment: "Button in Settings › Privacy."))
        cookies.onClick = { [weak self, weak cookies] _ in
            // The sites you keep cookies for are left alone, and the sheet says so.
            let kept = KeptCookies.sites(in: profile.id)
            self?.confirm(title: kept.isEmpty ? String(localized: "Clear cookies for every site?", comment: "Title of the sheet that clears cookies.") : KeptCookies.clearTitle,
                          message: Words.sentences(kept.isEmpty ? String(localized: "You’ll be signed out of every site. Your passwords, pinned tabs and history stay.", comment: "Message of the sheet that clears cookies.")
                                                                : KeptCookies.clearMessage(keeping: kept.count), only),
                          action: String(localized: "Clear Cookies", comment: "Button of the sheet that clears cookies.")) {
                Task { @MainActor in
                    await WebsiteData.clear(.cookies, keeping: kept, in: store)
                    cookies?.flash(Self.cleared)
                    self?.reloadSiteData()
                }
            }
        }
        let data = NSStackView(views: [cache, cookies])
        data.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: String(localized: "Website data", comment: "A setting in Settings › Privacy."),
                                 control: data))

        // Sites whose cookies clearing leaves alone (#334), each with ×, then whether the rest go at quit.
        let kept = KeptCookies.sites(in: profile.id)
        let addKept = PillButton(title: String(localized: "Add Site…", comment: "Button beside “Keep cookies for these sites” in Settings › Privacy: opens the sheet that adds a site whose cookies are kept."))
        addKept.onClick = { [weak self] _ in if let self { KeptCookiesSheet.add(in: self, profile: profile.id) } }
        // Site controls offer Keep cookies only while quitting clears them (#383).
        func keptDetail(clearsOnQuit: Bool) -> String {
            kept.isEmpty && clearsOnQuit
                ? String(localized: "Clear Cookies… and quitting leave them alone, so you stay signed in. Add a site here, or turn on Keep cookies in its site controls.", comment: "Explanation under “Keep cookies for these sites” in Settings › Privacy, while no site is listed.")
                : String(localized: "Clear Cookies… and quitting leave them alone, so you stay signed in.", comment: "Explanation under “Keep cookies for these sites” in Settings › Privacy, over the sites listed.")
        }
        let keptRow = FormRow(title: String(localized: "Keep cookies for these sites", comment: "A setting in Settings › Privacy: the sites whose cookies Clear Cookies… and quitting leave alone, listed under it."),
                              detail: keptDetail(clearsOnQuit: KeptCookies.clearsOnQuit(in: profile.id)),
                              control: addKept)
        keptRow.keywords = String(localized: "cookies keep exceptions signed in sign-in allow sites", comment: "Words that find the Keep cookies for these sites setting. Not shown.")
        privacyGroup.add(keptRow)
        for site in kept.sorted() {
            let x = IconButton(symbol: "xmark", size: .compact,
                               toolTip: String(localized: "Stop Keeping Cookies for \(site)", comment: "Tooltip of the × on a site under “Keep cookies for these sites” in Settings › Privacy. The site is a domain, like github.com."))
            x.onClick = { _ in KeptCookies.remove(site, in: profile.id) }
            let favicon = URL(string: "https://\(site)").flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            let row = FormRow(title: site, icon: favicon, control: x)
            row.keywords = keptRow.keywords
            privacyGroup.add(row)
        }
        let quitToggle = Toggle(isOn: KeptCookies.clearsOnQuit(in: profile.id))
        quitToggle.onChange = { [weak self, weak keptRow] on in
            KeptCookies.setClearsOnQuit(on, in: profile.id)
            keptRow?.detailText = keptDetail(clearsOnQuit: on)
            self?.layoutDocument()
        }
        let quitRow = FormRow(title: String(localized: "Clear cookies when Zigzag quits", comment: "A setting in Settings › Privacy: every site's cookies and data are cleared as Zigzag quits, except the sites kept."),
                              detail: String(localized: "Each time you quit, every other site’s cookies and data are cleared, so you start signed out of them next time.", comment: "Explanation under “Clear cookies when Zigzag quits” in Settings › Privacy: every site but the ones kept."),
                              control: quitToggle)
        quitRow.keywords = keptRow.keywords
        privacyGroup.add(quitRow)
        clearCookiesButton = cookies
        addKeptButton = addKept
        clearOnQuitToggle = quitToggle

        // The choices made one site at a time, which otherwise have nowhere to be seen.
        let nothingChosen = permissionsChangedHere.isEmpty && ContentBlocker.allowedSites.isEmpty && ExtensionStore.extensionsOffSites(in: profile).isEmpty && SitePermissions.sites.isEmpty
            && ZoomLevels.count == 0 && DarkPages.sitesOn.isEmpty && DarkPages.sitesOff.isEmpty && DarkPages.sitesForced.isEmpty && KeepAwake.sites.isEmpty
            && PageFullScreen.pageSites.isEmpty && PageFullScreen.screenSites.isEmpty && CookieBanners.sitesHandled.isEmpty && CookieBanners.sitesLeft.isEmpty
            && SiteJavaScript.sitesOn.isEmpty && SiteJavaScript.sitesOff.isEmpty && ClientCertificates.sites.isEmpty && SiteBoosts.sites.isEmpty
            && SiteIcons.sites.isEmpty && SiteUserAgents.sites.isEmpty && kept.isEmpty
        let reset = PillButton(title: String(localized: "Reset All…", comment: "Button beside Sites in Settings › Privacy: forgets the choices made for single sites."))
        sitesReset = nothingChosen ? nil : reset
        reset.onClick = { [weak self] _ in
            self?.confirm(title: String(localized: "Reset choices made for single sites?", comment: "Title of the sheet that forgets the choices made for single sites."),
                          message: String(localized: "Ads are blocked again everywhere, extensions run on every site, sites ask again for your camera, microphone, location, notifications and certificates, zoom, JavaScript, dark pages, full screen and cookie banners follow your settings again, every site’s tabs can sleep in the background, no site keeps its cookies when they’re cleared, and zapped elements, site styles and site icons are removed.",
                                          comment: "Message of the sheet that forgets the choices made for single sites."),
                          action: String(localized: "Reset All", comment: "Button of the sheet that forgets the choices made for single sites.")) {
                ContentBlocker.allowedSites = []
                ExtensionStore.setExtensionsOffSites([], in: profile)
                self?.permissionsChangedHere = []
                SitePermissions.forgetAll()
                ZoomLevels.resetAll()
                DarkPages.forgetAll()
                KeepAwake.sites = []
                PageFullScreen.forgetAll()
                CookieBanners.forgetAll()
                SiteJavaScript.forgetAll()
                ClientCertificates.forgetAll()
                ClientCertificates.forgetAllSessions()
                SiteBoosts.forgetAll()
                SiteIcons.forgetAll()
                SiteUserAgents.forgetAll()
                KeptCookies.setSites([], in: profile.id)
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
        }
        if nothingChosen {
            sitesGroup.add(FormRow(title: String(localized: "None yet", comment: "A setting in Settings › Privacy."),
                                   detail: String(localized: "Choices you make for one site, like allowing ads, a camera or notifications, show up here.", comment: "Explanation under “None yet” in Settings › Privacy."),
                                   control: NSView()))
        }

        // Then each site, one row per choice; × forgets only that one. Permissions are per origin, labeled by host for
        // https on any port (sharing a row with the host's other choices) and in full otherwise
        // (http://localhost:3000). A permission reset to Ask here keeps its row until Settings closes.
        let origins = Dictionary((SitePermissions.sites + permissionsChangedHere.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
            .map { (SiteOrigin.label($0), $0) }, uniquingKeysWith: { a, _ in a })
        let sites = Set(origins.keys).union(ContentBlocker.allowedSites).union(ExtensionStore.extensionsOffSites(in: profile)).union(ZoomLevels.all.keys)
            .union(DarkPages.sitesOn).union(DarkPages.sitesOff).union(DarkPages.sitesForced).union(KeepAwake.sites)
            .union(PageFullScreen.pageSites).union(PageFullScreen.screenSites).union(CookieBanners.sitesHandled).union(CookieBanners.sitesLeft)
            .union(SiteJavaScript.sitesOn).union(SiteJavaScript.sitesOff).union(ClientCertificates.sites).union(SiteBoosts.sites)
            .union(SiteIcons.sites).union(SiteUserAgents.sites).union(kept)
        var listed = 0, more = 0
        for site in sites.sorted() {
            let origin = origins[site]
            let url = URL(string: origin ?? "https://\(site)")
            var rows: [FormRow] = []

            func makeRow(_ title: String, detail: String? = nil, control: NSView, clear: @escaping () -> Void) -> FormRow {
                let x = IconButton(symbol: "xmark", size: .compact,
                                   toolTip: String(localized: "Clear \(title)", comment: "Tooltip of the × on a site's row in Settings › Privacy › Sites: forgets that one choice for the site."))
                x.onClick = { [weak self] _ in
                    clear()
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                let stack = NSStackView(views: [control, x])
                stack.spacing = Tokens.Space.x2
                let row = FormRow(title: title, detail: detail, control: stack)
                row.isIndented = true
                row.keywords = site
                return row
            }

            if let origin {
                let permissions = SitePermission.allCases.filter {
                    SitePermissions.hasDecision($0, origin: origin) || permissionsChangedHere.contains("\(origin)|\($0.rawValue)")
                }
                for permission in permissions {
                    let options = permission.choices
                    let dropdown = DropdownButton()
                    dropdown.options = options.map { DropdownButton.Option(title: $0.title) }
                    dropdown.selectedIndex = options.firstIndex(of: SitePermissions.choice(permission, origin: origin)) ?? 0
                    dropdown.onSelect = { [weak self] index in
                        SitePermissions.setChoice(options[index], for: permission, origin: origin)
                        self?.permissionsChangedHere.insert("\(origin)|\(permission.rawValue)")
                        self?.reloadPrivacy()
                        self?.layoutDocument()
                    }
                    // Open apps names the app the site always opens, in one sentence.
                    var detail: String?
                    if permission == .apps {
                        let apps = SitePermissions.choices(origin: origin).sorted { $0.key < $1.key }
                            .filter { $0.value && $0.key.hasPrefix("app:") }
                            .map { String(localized: "opens \(ExternalLinks.appName(forScheme: String($0.key.dropFirst(4))))", comment: "A choice made for a site in Settings › Privacy: its links of this kind open in an app, by name.") }
                        if !apps.isEmpty {
                            let line = apps.joined(separator: String(localized: "site-choices.separator", defaultValue: ", ",
                                                                     comment: "Between the choices made for a site in Settings › Privacy › Sites, like “camera allowed, zoom 125%”."))
                            let sentence = line.prefix(1).localizedUppercase + line.dropFirst()
                            detail = String(localized: "site-choices.sentence", defaultValue: "\(sentence).",
                                            comment: "Under a site in Settings › Privacy › Sites: the choices made for it, as one sentence.")
                        }
                    }
                    rows.append(makeRow(permission.title, detail: detail, control: dropdown) { [weak self] in
                        SitePermissions.setChoice(.ask, for: permission, origin: origin)
                        self?.permissionsChangedHere.remove("\(origin)|\(permission.rawValue)")
                    })
                }
            }

            // JavaScript isn't a WebKit permission but lists and clears the same way: Allowed, Not Allowed, or default.
            if let javaScript = SiteJavaScript.choice(forSite: site) {
                let options = [String(localized: "Follow Setting", comment: "A choice for JavaScript in Settings › Privacy › Sites: the site follows Settings › Privacy › JavaScript."),
                               SitePanel.javaScriptAllowed, SitePanel.javaScriptNotAllowed]
                let dropdown = DropdownButton()
                dropdown.options = options.map { DropdownButton.Option(title: $0) }
                dropdown.selectedIndex = javaScript ? 1 : 2
                dropdown.onSelect = { [weak self] index in
                    let setting: Bool? = index == 0 ? nil : index == 1
                    SiteJavaScript.setChoice(setting, forSite: site)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "JavaScript", comment: "Row in Settings › Privacy › Sites: whether the site's pages run their scripts."),
                                    control: dropdown) { SiteJavaScript.forget(site: site) })
            }

            if let zoom = ZoomLevels.all[site], let url {
                let stepper = ZoomStepper()
                stepper.zoom = CGFloat(zoom)
                stepper.onChange = { [weak self] value in
                    ZoomLevels.set(value, for: url)
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Zoom", comment: "Row in Settings › Privacy › Sites: this site's page zoom."),
                                    control: stepper) { ZoomLevels.forget(host: site) })
            }

            if let url, DarkPages.sitesOn.contains(site) || DarkPages.sitesOff.contains(site) || DarkPages.sitesForced.contains(site) {
                let choices = DarkPages.SiteChoice.allCases
                let dropdown = DropdownButton()
                dropdown.options = choices.map { DropdownButton.Option(title: SitePanel.title(of: $0)) }
                dropdown.selectedIndex = choices.firstIndex(of: DarkPages.siteChoice(for: url)) ?? 0
                dropdown.onSelect = { [weak self] index in
                    DarkPages.setSiteChoice(choices[index], for: url)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Dark page", comment: "Row in Settings › Privacy › Sites: draws this site's pages dark."),
                                    control: dropdown) { DarkPages.setChoice(nil, for: url) })
            }

            if let url, KeepAwake.sites.contains(site) {
                let toggle = Toggle(isOn: true)
                toggle.onChange = { [weak self] on in
                    KeepAwake.set(on, for: url)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Keep tabs awake", comment: "Row in Settings › Privacy › Sites: this site's tabs never go to sleep in the background."),
                                    control: toggle) {
                    var awake = KeepAwake.sites
                    awake.remove(site)
                    KeepAwake.sites = awake
                })
            }

            // Same switches and names as Site Controls.
            // Kept from Clear Cookies… and quitting (#334).
            if kept.contains(site) {
                let toggle = Toggle(isOn: true)
                toggle.onChange = { on in on ? KeptCookies.add(site, in: profile.id) : KeptCookies.remove(site, in: profile.id) }
                rows.append(makeRow(String(localized: "Keep cookies", comment: "Row in Settings › Privacy › Sites: clearing every site's cookies, or clearing them when Zigzag quits, leaves this site's alone."),
                                    control: toggle) { KeptCookies.remove(site, in: profile.id) })
            }

            if let url, PageFullScreen.pageSites.contains(site) || PageFullScreen.screenSites.contains(site) {
                let toggle = Toggle(isOn: PageFullScreen.choice(for: url) == .page)
                toggle.onChange = { [weak self] on in
                    PageFullScreen.setChoice(on ? .page : .screen, for: url)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(SitePanel.fullScreenTitle,
                                    control: toggle) { PageFullScreen.setChoice(nil, for: url) })
            }

            if let url, CookieBanners.sitesHandled.contains(site) || CookieBanners.sitesLeft.contains(site) {
                let toggle = Toggle(isOn: CookieBanners.sitesHandled.contains(site))
                toggle.onChange = { [weak self] on in
                    CookieBanners.setChoice(on, for: url)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Cookie banners", comment: "Row in Settings › Privacy › Sites: what Zigzag does with the site's cookie consent pop-up."),
                                    control: toggle) { CookieBanners.setChoice(nil, for: url) })
            }

            if let url, ContentBlocker.allowedSites.contains(site) {
                let toggle = Toggle(isOn: false)
                toggle.onChange = { [weak self] on in
                    ContentBlocker.setAllowed(!on, on: url)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Ad blocking", comment: "Row in the site panel's This Site group."),
                                    control: toggle) {
                    var allowed = ContentBlocker.allowedSites
                    allowed.remove(site)
                    ContentBlocker.allowedSites = allowed
                })
            }

            if url != nil, ExtensionStore.extensionsOffSites(in: profile).contains(site) {
                let toggle = Toggle(isOn: false)
                toggle.onChange = { [weak self] on in
                    guard let self else { return }
                    var off = ExtensionStore.extensionsOffSites(in: profile)
                    if on { off.remove(site) } else { off.insert(site) }
                    ExtensionStore.setExtensionsOffSites(off, in: profile)
                    self.reloadPrivacy()
                    self.layoutDocument()
                }
                rows.append(makeRow(String(localized: "Extensions", comment: "Row in Settings › Privacy › Sites: whether extensions run on this site."),
                                    control: toggle) {
                    var off = ExtensionStore.extensionsOffSites(in: profile)
                    off.remove(site)
                    ExtensionStore.setExtensionsOffSites(off, in: profile)
                })
            }

            if let zaps = SiteBoosts.all[site]?.zaps.count, zaps > 0 {
                rows.append(makeRow(String(localized: "Zapped elements", comment: "Row in Settings › Privacy › Sites: elements hidden on this site."),
                                    detail: String(localized: "\(zaps) hidden", comment: "Under Zapped elements in Settings › Privacy › Sites: how many elements are hidden. The number is that count."),
                                    control: NSView()) { SiteBoosts.restoreZaps(forSite: site) })
            }

            if SiteBoosts.all[site]?.hasStyle == true {
                rows.append(makeRow(String(localized: "Custom style", comment: "Row in Settings › Privacy › Sites: CSS of your own on this site."),
                                    control: NSView()) {
                    guard var boost = SiteBoosts.all[site] else { return }
                    boost.style = ""
                    SiteBoosts.set(boost, forSite: site)
                })
            }
            if let agent = SiteUserAgents.choice(forSite: site) {
                let choices = SiteUserAgents.Choice.presets + (agent.isCustom ? [agent] : [])
                let dropdown = DropdownButton()
                dropdown.options = choices.map { DropdownButton.Option(title: $0.title) }
                dropdown.selectedIndex = choices.firstIndex(of: agent) ?? 0
                dropdown.onSelect = { [weak self] index in
                    SiteUserAgents.set(choices[index], forSite: site)
                    self?.reloadPrivacy()
                    self?.layoutDocument()
                }
                rows.append(makeRow(SiteUserAgents.title, control: dropdown) { SiteUserAgents.forget(site: site) })
            }
            if SiteIcons.all[site] != nil {
                rows.append(makeRow(String(localized: "Site icon", comment: "Row in Settings › Privacy › Sites: an icon you set for this site in Site Controls (Change Site Icon…), shown for its tabs, pinned tabs and favorites."),
                                    control: NSView()) { SiteIcons.forget(site: site) })
            }
            if let certificate = ClientCertificates.kept(host: site) {
                rows.append(makeRow(String(localized: "Certificate", comment: "Row in Settings › Privacy › Sites: the certificate from your Keychain this site is always sent."),
                                    detail: certificate.name, control: NSView()) {
                    ClientCertificates.forget(site: site)
                    ClientCertificates.forgetSessions(site: site)
                })
            }

            guard !rows.isEmpty else { continue }
            // The first 30 by name, as with site data, then the rest on request.
            guard sitesShowAll || listed < 30 else { more += 1; continue }
            listed += 1
            let forget = PillButton(title: String(localized: "Forget", comment: "Button on a site's row in Settings › Privacy › Sites: forgets every choice made for it."))
            forget.onClick = { [weak self] _ in
                if let origin {
                    SitePermissions.forgetEverything(origin: origin)
                    // Also clears session answers the card reads (postponed or denied apps, Site Controls rows).
                    ExternalLinks.forgetAnswers(origin: origin)
                    PopupNotice.forgetAnswers(origin: origin)
                    WebNotifications.shared.removeAll(origin: origin)
                }
                self?.forgetPermissionsChanged(for: site)
                ContentBlocker.allowedSites.remove(site)
                var off = ExtensionStore.extensionsOffSites(in: profile)
                off.remove(site)
                ExtensionStore.setExtensionsOffSites(off, in: profile)
                ZoomLevels.forget(host: site)
                DarkPages.setChoice(nil, for: URL(string: "https://\(site)"))
                var awake = KeepAwake.sites
                awake.remove(site)
                KeepAwake.sites = awake
                PageFullScreen.setChoice(nil, for: URL(string: "https://\(site)"))
                CookieBanners.setChoice(nil, for: URL(string: "https://\(site)"))
                SiteJavaScript.forget(site: site)
                ClientCertificates.forget(site: site)
                ClientCertificates.forgetSessions(site: site)
                SiteBoosts.forget(site: site)
                SiteIcons.forget(site: site)
                SiteUserAgents.forget(site: site)
                KeptCookies.remove(site, in: profile.id)
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
            let siteURL = URL(string: origin ?? "https://\(site)")
            let favicon = SiteIcons.all[site].map(IconChoice.pageIcon) ?? siteURL.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            sitesGroup.add(FormRow(title: site, icon: favicon, control: forget))
            for row in rows { sitesGroup.add(row) }
        }
        if more > 0 {
            let all = PillButton(title: String(localized: "Show All", comment: "Button under the first 30 sites in Settings › Privacy."))
            all.onClick = { [weak self] _ in
                self?.sitesShowAll = true
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
            sitesGroup.add(FormRow(title: String(localized: "\(more) more sites", comment: "Under the first 30 sites in Settings › Privacy, beside Show All."), control: all))
        }
    }

    /// What websites keep, read again where it's listed (with more than one profile that's Website Data, and
    /// Privacy has no use for it): when the pane is shown, not each time a site's permission changes.
    private func reloadListedSiteData() {
        guard isRead(.privacy) else { return }
        if !(pane == .privacy && hasManyProfiles) { reloadSiteData() }
    }

    /// Forgets a site's in-pane changes along with it, so it doesn't reappear briefly.
    private func forgetPermissionsChanged(for site: String) {
        permissionsChangedHere = permissionsChangedHere.filter { key in
            guard let origin = key.split(separator: "|", maxSplits: 1).first.map(String.init) else { return false }
            return SiteOrigin.label(origin) != site
        }
    }

    /// Settings › Developer's sizes: each with its width and height, and Remove.
    private func reloadPageSizes() {
        pageSizesGroup.removeAllRows()
        let sizes = PageSizes.all
        if sizes.isEmpty {
            pageSizesGroup.add(FormRow(title: String(localized: "None yet", comment: "A row in Settings › Developer, shown when no page size is listed."),
                                       detail: String(localized: "Sizes you add show up here.", comment: "Explanation under “None yet” in Settings › Developer › Page Sizes."),
                                       control: NSView()))
        }
        for size in sizes {
            let remove = PillButton(title: String(localized: "Remove", comment: "Button on a row in Settings › Developer: takes the site or the page size off its list."))
            remove.setAccessibilityLabel(String(localized: "Remove \(size.name)", comment: "VoiceOver name of the Remove button on a row in Settings › Developer: a site, like localhost, or a page size, like iPhone."))
            remove.onClick = { _ in PageSizes.remove(size) }
            pageSizesGroup.add(FormRow(title: size.name, detail: size.dimensions, control: remove))
        }
    }

    /// The rows of WebKit's flags of one status, each with its switch and, once changed, a quiet "Changed" before it.
    /// Made the first time they show.
    private func flagGroup(_ status: FeatureFlags.Status, _ flags: [FeatureFlags.Flag]) -> FormGroup {
        if let group = flagGroups[status] { return group }
        let group = FormGroup()
        for flag in FeatureFlags.flags(status, in: flags, matching: []) {
            let toggle = Toggle(isOn: FeatureFlags.isOn(flag))
            toggle.onChange = { on in FeatureFlags.set(on, for: flag) }
            toggle.setAccessibilityLabel(flag.name)
            let changed = Label(String(localized: "Changed", comment: "Beside the switch of a WebKit feature flag in Settings › Developer that you changed from WebKit's default."),
                                font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
            changed.isHidden = !FeatureFlags.isChanged(flag)
            let control = NSStackView(views: [changed, toggle])
            control.spacing = Tokens.Space.x3
            control.alignment = .centerY
            // WebKit's own words, never translated. A line that only says the name again isn't shown.
            let row = FormRow(title: flag.name, detail: flag.details == flag.name ? nil : flag.details, control: control)
            row.keywords = flag.key
            flagControls[flag.key] = (flag, row, toggle, changed)
            group.add(row)
        }
        flagGroups[status] = group
        return group
    }

    /// A flag changed, here or elsewhere: each switch shows what's in effect, and "Changed" where it isn't WebKit's default.
    private func refreshFlags() {
        for (flag, row, toggle, changed) in flagControls.values {
            let on = FeatureFlags.isOn(flag)
            if toggle.isOn != on { toggle.isOn = on }
            let unchanged = !FeatureFlags.isChanged(flag)
            if changed.isHidden != unchanged {
                changed.isHidden = unchanged
                row.needsLayout = true
            }
        }
        if pane == .developer, !isSearching { layoutDocument() }
    }

    /// Settings › Developer's list: each site you develop on, with Remove.
    private func reloadDevelopmentSites() {
        developmentSitesGroup.removeAllRows()
        let sites = DevelopmentSites.sites
        if sites.isEmpty {
            developmentSitesGroup.add(FormRow(title: String(localized: "None yet", comment: "A row in Settings › Developer, shown when no site is in Developer Mode."),
                                              detail: String(localized: "Sites you turn Developer Mode on for show up here.", comment: "Explanation under “None yet” in Settings › Developer."),
                                              control: NSView()))
        }
        for site in sites {
            let remove = PillButton(title: String(localized: "Remove", comment: "Button on a row in Settings › Developer: takes the site or the page size off its list."))
            remove.setAccessibilityLabel(String(localized: "Remove \(site)", comment: "VoiceOver name of the Remove button on a row in Settings › Developer: a site, like localhost, or a page size, like iPhone."))
            remove.onClick = { _ in DevelopmentSites.remove(site) }
            let favicon = URL(string: "http://\(site)").flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            developmentSitesGroup.add(FormRow(title: site, icon: favicon, control: remove))
        }
    }

    /// Settings › Developer's list of local servers whose certificate is trusted across launches, with Remove.
    private func reloadTrustedCertificates() {
        trustedCertificatesGroup.removeAllRows()
        for site in CertificateExceptions.rememberedSites {
            let remove = PillButton(title: String(localized: "Remove", comment: "Button on a row in Settings › Developer: takes the site or the page size off its list."))
            remove.setAccessibilityLabel(String(localized: "Remove \(site.name)", comment: "VoiceOver name of the Remove button on a row in Settings › Developer: a local server whose certificate is trusted, like 10.0.0.10:8443."))
            remove.onClick = { _ in CertificateExceptions.forgetRemembered(site) }
            trustedCertificatesGroup.add(FormRow(title: site.name, icon: SettingsIcon.symbol("lock"), control: remove))
        }
    }

    /// The list of what websites keep, its search, order and Remove All, wired once.
    private func buildSiteData() {
        siteDataGroup.add(siteDataList)
        siteDataList.changed = { [weak self] grew in self?.siteDataChanged(grew) }
        siteDataList.onRemove = { [weak self] entry in self?.confirmRemove([entry]) }
        siteDataToolbar.search.field.delegate = self
        siteDataToolbar.sort.onSelect = { [weak self] index in
            self?.siteDataList.model?.order = SiteDataSort(rawValue: index) ?? .name
        }
        siteDataToolbar.removeAll.onClick = { [weak self] _ in
            guard let self, let model = self.siteDataList.model else { return }
            self.confirmRemove(model.shown, all: !model.isFiltering)
        }
        siteDataChanged(false)
    }

    /// The profile's list: kept from the last time it was shown, and read again in the background, so it shows
    /// at once and never empties while it's looked at. Only read where it's listed.
    private func reloadSiteData() {
        let timing = SettingsTiming.begin("reloadSiteData"); defer { timing.end() }
        counted("siteData")
        let profile = profile
        let model = siteDataModels[profile.id] ?? {
            let model = SiteDataModel(source: WebKitSiteData(store: profile.store))
            siteDataModels[profile.id] = model
            return model
        }()
        if siteDataList.model !== model {
            model.query = siteDataToolbar.search.stringValue
            model.order = SiteDataSort(rawValue: siteDataToolbar.sort.selectedIndex) ?? .name
            siteDataList.showsAll = false
            siteDataList.model = model
        }
        model.refresh()
    }

    /// The list changed what it shows: the toolbar follows, and the page lays out again if the list's height or
    /// the toolbar's width changed.
    private func siteDataChanged(_ grew: Bool) {
        let model = siteDataList.model
        let before = (siteDataToolbar.removeAll.title, siteDataToolbar.removeAll.isHidden, siteDataHadSizes)
        siteDataToolbar.setRemoveTitle(filtering: model?.isFiltering ?? false)
        siteDataToolbar.removeAll.isHidden = model?.shown.isEmpty ?? true
        siteDataHadSizes = model?.hasSizes ?? false
        if siteDataToolbar.sort.selectedIndex != model?.order.rawValue ?? 0 { siteDataToolbar.sort.selectedIndex = model?.order.rawValue ?? 0 }
        let toolbarChanged = before != (siteDataToolbar.removeAll.title, siteDataToolbar.removeAll.isHidden, siteDataHadSizes)
        guard !isLayingOutDocument, grew || toolbarChanged, window != nil else { return }
        layoutDocument()
    }

    /// Asks before removing sites' data: one site by its name, the ones a search shows by how many, or all.
    private func confirmRemove(_ entries: [SiteDataEntry], all: Bool = false) {
        guard let model = siteDataList.model, !entries.isEmpty else { return }
        let signsOut = entries.contains { $0.kinds.contains(.cookies) }
        let title: String, message: String, action: String
        if all {
            title = String(localized: "Remove data for every site?", comment: "Title of the sheet that removes every site's data, from Remove All in Settings › Privacy › Stored by Websites.")
            message = Words.sentences(String(localized: "You’ll be signed out of every site, and pages load fresh next time. Your passwords, pinned tabs and history stay.",
                                             comment: "Message of the sheet that removes every site's data, from Remove All in Settings › Privacy › Stored by Websites."),
                                      ProfileSheets.onlyNote(profile.id))
            action = String(localized: "Remove All", comment: "Button of the sheet that removes every site's data, or every site a search shows, in Settings › Privacy.")
        } else if entries.count == 1, let site = entries.first?.site {
            title = String(localized: "Remove data for \(site)?", comment: "Title of the sheet that removes one site's data; the site, like apple.com.")
            message = signsOut
                ? String(localized: "You’ll be signed out of \(site), and its pages load fresh next time.", comment: "Message of the sheet that removes one site's data.")
                : String(localized: "Its pages load fresh next time.", comment: "Message of the sheet that removes one site's data.")
            action = String(localized: "Remove", comment: "Button of the sheet that removes one site's data.")
        } else {
            let count = entries.count
            title = String(localized: "Remove data for the \(count) sites shown?", comment: "Title of the sheet that removes the data of the sites a search shows in Settings › Privacy › Stored by Websites; how many, always more than one.")
            message = signsOut
                ? String(localized: "You’ll be signed out of them, and their pages load fresh next time.", comment: "Message of the sheet that removes the data of the sites a search shows in Settings › Privacy.")
                : String(localized: "Their pages load fresh next time.", comment: "Message of the sheet that removes the data of the sites a search shows in Settings › Privacy, none of them with cookies.")
            action = String(localized: "Remove All", comment: "Button of the sheet that removes every site's data, or every site a search shows, in Settings › Privacy.")
        }
        confirm(title: title, message: message, action: action) {
            Task { @MainActor in
                if all { await model.removeAllShown() } else { await model.remove(entries) }
            }
        }
    }

    /// Settings › General › Installed Apps: each site installed as an app, with its toolbar's switch and Remove, which
    /// asks first.
    private func reloadWebApps() {
        guard isRead(.general) else { return }
        let timing = SettingsTiming.begin("reloadWebApps"); defer { timing.end() }
        counted("webApps")
        webAppsGroup.removeAllRows()
        let store = WebAppStore.shared
        store.pruneMissing()
        for app in store.apps.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let remove = PillButton(title: String(localized: "Remove…", comment: "Button on an installed app's row in Settings › General › Installed Apps."))
            remove.setAccessibilityLabel(String(localized: "Remove “\(app.name)”", comment: "VoiceOver label of the Remove button on an installed app's row in Settings › General; the app's name."))
            remove.onClick = { [weak self] _ in
                self?.confirm(title: String(localized: "Remove \(app.name)?", comment: "Title of the sheet that removes a site installed as an app. The placeholder is the app's name."),
                              message: String(localized: "The app is deleted from your Applications folder. You stay signed in to the site in Zigzag.", comment: "Message of the sheet that removes a site installed as an app."),
                              action: String(localized: "Remove", comment: "Button of the sheet that removes a site installed as an app.")) {
                    WebAppStore.shared.remove(app.id)
                }
            }
            var detail = app.url.host() ?? app.url.absoluteString
            if hasManyProfiles, let profile = Library.shared.directory.profile(app.profileID) {
                detail = String(localized: "\(detail) on \(profile.displayName)", comment: "Under an installed app in Settings › General with more than one profile: the site, then the profile it uses, like “github.com on Work”.")
            }
            // Its toolbar, on or off: off, the app's window is just the page with the traffic lights over it.
            let toolbarLabel = Label(String(localized: "Toolbar", comment: "Beside the switch on an installed app's row in Settings › General: whether its window shows back, forward, reload and its name on top."),
                                     font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
            let toolbar = Toggle(isOn: app.showsToolbar)
            toolbar.setAccessibilityLabel(String(localized: "Show toolbar in “\(app.name)”", comment: "VoiceOver label of the switch on an installed app's row in Settings › General; the app's name."))
            toolbar.onChange = { on in WebAppStore.shared.setShowsToolbar(on, for: app.id) }
            // Where it is, without knowing the folder: the app selected in Finder.
            let finder = PillButton(title: String(localized: "Show in Finder", comment: "Button on an installed app's row in Settings › General: shows the app itself, selected in its folder in Finder."))
            finder.setAccessibilityLabel(String(localized: "Show “\(app.name)” in Finder", comment: "VoiceOver label of the Show in Finder button on an installed app's row in Settings › General; the app's name."))
            finder.onClick = { _ in WebAppStore.shared.revealInFinder(app) }
            let controls = NSStackView(views: [toolbarLabel, toolbar, Self.openButton(for: app), finder, remove])
            controls.spacing = Tokens.Space.x2
            controls.setCustomSpacing(Tokens.Space.x4, after: toolbar)
            let icon = store.bundle(of: app).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? SettingsIcon.symbol("app")
            let row = FormRow(title: app.name, detail: detail, icon: icon, control: controls)
            row.keywords = String(localized: "web app dock install application", comment: "Words that find Installed Apps with Find a setting in Settings. Not shown.")
            webAppsGroup.add(row)
        }
    }

    /// What an installed app's Open does: the same as its Dock icon, so an open window comes forward.
    static var openWebApp: @MainActor (WebApp) -> Void = { WebAppInstaller.launch($0) }

    /// Open on an installed app's row (#355), before Show in Finder.
    static func openButton(for app: WebApp) -> PillButton {
        let open = PillButton(title: String(localized: "Open", comment: "Button on an installed app's row in Settings › General: opens the app, or brings its window forward."))
        open.setAccessibilityLabel(String(localized: "Open “\(app.name)”", comment: "VoiceOver label of the Open button on an installed app's row in Settings › General; the app's name."))
        open.onClick = { _ in openWebApp(app) }
        return open
    }

    private func confirm(title: String, message: String, action: String, destructive: Bool = true, then run: @escaping () -> Void) {
        ConfirmSheet.show(in: self, title: title, message: message, confirmTitle: action, destructive: destructive) { confirmed in
            if confirmed { run() }
        }
    }


    /// Checks every extension from the store now and says what came of it; one update that wants more access opens
    /// its review sheet (#406).
    private func checkForUpdates() {
        guard checkUpdatesButton.isEnabled else { return }
        let title = checkUpdatesButton.title
        checkUpdatesButton.title = String(localized: "Checking…", comment: "The Check for Updates button in Settings › Extensions while it checks.")
        checkUpdatesButton.isEnabled = false
        layoutDocument()
        Task { @MainActor [weak self] in
            let check = await ExtensionStore.checkForUpdatesIfDue(force: true)
            guard let self else { return }
            checkUpdatesButton.title = title
            checkUpdatesButton.isEnabled = true
            layoutDocument()
            Toast.show(check.summary, symbol: check.failed > 0 ? "exclamationmark.triangle" : "checkmark", duration: 4, over: self, area: bounds)
            if check.waiting.count == 1, let id = check.waiting.first, let controller = browser {
                controller.reviewExtensionUpdate(id)
            }
        }
    }

    /// Get Extensions: which store to open.
    private func showGetExtensionsMenu(from button: PillButton) {
        let entries: [MenuPanel.Entry] = ExtensionStore.Shop.allCases.map { shop in
            .item(MenuPanel.Item(title: shop.title) { [weak self] in self?.getExtensions(from: shop) })
        }
        button.isSelected = true
        MenuPanel.show(entries, from: button) { [weak button] in button?.isSelected = false }
    }

    private func getExtensions(from shop: ExtensionStore.Shop) {
        guard let controller = browser else { return }
        controller.tabManager.newTab(url: shop.url)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// The bridge's getextensions: the Get Extensions menu, as a click opens it.
    func debugShowGetExtensionsMenu() {
        func pills(in view: NSView) -> [PillButton] { view.subviews.flatMap { ($0 as? PillButton).map { [$0] } ?? pills(in: $0) } }
        let title = getExtensionsButton.title
        guard let button = pills(in: self).first(where: { $0.title == title && !$0.isHidden && $0.window != nil }) else { return }
        showGetExtensionsMenu(from: button)
    }
    #endif

    /// Favicons come in at any size; a menu wants 16 points.
    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A shortcut's keys as small keycaps, as Settings › Shortcuts draws them, for a row elsewhere that names one.
final class KeyCaps: NSView {
    var keys: [String] = [] {
        didSet {
            guard keys != oldValue else { return }
            caps.forEach { $0.removeFromSuperview() }
            caps = keys.map { KeyCap($0) }
            caps.forEach(addSubview)
            setAccessibilityLabel(keys.joined(separator: " "))
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private var caps: [KeyCap] = []

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: caps.reduce(0) { $0 + $1.width } + Tokens.Space.x1 * CGFloat(max(0, caps.count - 1)), height: Tokens.Metric.keyCapHeight)
    }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for cap in caps {
            cap.frame = NSRect(x: x, y: (bounds.height - Tokens.Metric.keyCapHeight) / 2, width: cap.width, height: Tokens.Metric.keyCapHeight)
            x = cap.frame.maxX + Tokens.Space.x1
        }
    }
}

/// One shortcut: what it does, and its keys drawn as small keycaps. Click it to give it new keys.
final class ShortcutRow: InteractiveView, SettingsSearchable {
    /// By name, and by its keys whichever way you type them: "⌘L", "⌘ L", or "command L".
    var searchText: String {
        let names = [
            "⌘": "command cmd", "⇧": "shift", "⌥": "option alt", "⌃": "control ctrl",
            Shortcuts.globe: "fn globe",
            Shortcuts.hyper: "hyper hypr command cmd shift option alt control ctrl ⌃⌥⇧⌘",
        ]
        let spoken = keys.map { names[$0] ?? $0 }.joined(separator: " ")
        let shortcut = String(localized: "shortcut", comment: "A word that finds keyboard shortcuts with Find a setting in Settings. Not shown.")
        return title.stringValue + " " + shortcut + " " + keys.joined() + " " + keys.joined(separator: " ") + " " + spoken
    }
    private var keys: [String] = []
    private let item: NSMenuItem?
    private let title: Label
    private let note = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private var caps: [KeyCap] = []
    private let field = ColorView(color: .clear)
    private let fieldLabel = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let resetButton = IconButton(symbol: "arrow.uturn.backward", size: .compact, toolTip: String(localized: "Back to Zigzag’s Shortcut", comment: "Tooltip of the button that puts a changed shortcut back, in Settings › Shortcuts."))
    /// An × beside the keys while the pointer is on the row or you're typing new ones: the command keeps no shortcut,
    /// for one that gets in a page's way. Delete does the same while typing.
    private let removeButton = IconButton(symbol: "xmark", size: .compact, toolTip: String(localized: "Remove Shortcut", comment: "Tooltip of the × beside a shortcut in Settings › Shortcuts: the command is left with no keys."))
    private var monitor: Any?
    private var isRecording = false { didSet { refresh(); refreshRemove() } }
    /// Called after the keys change, so the list can redraw rows that lost theirs.
    var onChange: (() -> Void)?
    private static weak var recording: ShortcutRow?

    /// A row for a menu item, which you can change.
    init(title text: String, item: NSMenuItem) {
        self.item = item
        title = Label(text, font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: Tokens.Page.groupRowHeight))
        setup(keys: Shortcuts.caps(item))
        toolTip = String(localized: "Click to change", comment: "Tooltip of a shortcut in Settings › Shortcuts.")
        onClick = { [weak self] _ in self?.startRecording() }
        resetButton.onClick = { [weak self] _ in
            guard let self, let item = self.item else { return }
            Shortcuts.reset(item)
            self.onChange?()
        }
        removeButton.onClick = { [weak self] _ in
            guard let self, let item = self.item else { return }
            self.stopRecording()
            Shortcuts.set(Shortcuts.Combo.none, for: item)
            self.onChange?()
        }
    }

    /// A fixed row, like ⌘1–9, which can't be changed.
    init(title text: String, keys: [String]) {
        item = nil
        title = Label(text, font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: Tokens.Page.groupRowHeight))
        setup(keys: keys)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func setup(keys: [String]) {
        self.keys = keys
        layer?.cornerRadius = Tokens.Radius.group
        layer?.cornerCurve = .continuous
        addSubview(title)
        addSubview(note)
        note.isHidden = true
        for key in keys {
            let cap = KeyCap(key)
            addSubview(cap)
            caps.append(cap)
        }
        field.wantsLayer = true
        field.layer?.cornerRadius = Tokens.Radius.field
        field.layer?.cornerCurve = .continuous
        fieldLabel.alignment = .center
        field.addSubview(fieldLabel)
        field.isHidden = true
        addSubview(field)
        resetButton.isHidden = !(item.map(Shortcuts.isCustom) ?? false)
        addSubview(resetButton)
        removeButton.setAccessibilityLabel(String(localized: "Remove Shortcut", comment: "Tooltip of the × beside a shortcut in Settings › Shortcuts: the command is left with no keys."))
        addSubview(removeButton)
        refreshRemove()
        setAccessibilityRole(item == nil ? .staticText : .button)
        let name = title.stringValue, shortcut = keys.joined(separator: " ")
        setAccessibilityLabel(keys.isEmpty
            ? String(localized: "\(name): no shortcut", comment: "Accessibility label of a command with no keys in Settings › Shortcuts.")
            : String(localized: "\(name): \(shortcut)", comment: "Accessibility label of a shortcut in Settings › Shortcuts: the command, then its keys."))
        refresh()
    }

    /// Shown under the title after a change: which command the keys came from.
    func say(_ text: String) {
        note.stringValue = text
        note.textColor = Tokens.Color.caution
        note.isHidden = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Page.groupPad
        let h = Tokens.Page.controlHeight
        var x = bounds.width - pad
        if isRecording {
            let w: CGFloat = 168
            x -= w
            field.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            fieldLabel.frame = NSRect(x: Tokens.Space.x2, y: fieldLabel.centeredY(in: h), width: w - Tokens.Space.x4, height: fieldLabel.lineHeight)
        } else if caps.isEmpty && item != nil {
            fieldLabel.stringValue = String(localized: "None", comment: "In place of the keys of a command with no shortcut, in Settings › Shortcuts.")
        } else {
            for cap in caps.reversed() {
                x -= cap.width
                cap.frame = NSRect(x: x, y: (bounds.height - Tokens.Metric.keyCapHeight) / 2, width: cap.width, height: Tokens.Metric.keyCapHeight)
                x -= Tokens.Space.x1
            }
        }
        if caps.isEmpty && item != nil && !isRecording {
            // No keys: a quiet "None" where the caps would be.
            let w = fieldLabel.inkWidth + Tokens.Space.x2
            x -= w
            field.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            fieldLabel.frame = NSRect(x: 0, y: fieldLabel.centeredY(in: h), width: w, height: fieldLabel.lineHeight)
        }
        if !removeButton.isHidden {
            let b = removeButton.frame.width
            x -= b + Tokens.Space.x2
            removeButton.frame.origin = NSPoint(x: x, y: (bounds.height - b) / 2)
        }
        if !resetButton.isHidden {
            let b = resetButton.frame.width
            x -= b + Tokens.Space.x2
            resetButton.frame.origin = NSPoint(x: x, y: (bounds.height - b) / 2)
        }
        let width = max(0, x - pad - Tokens.Space.x4)
        if note.isHidden {
            title.frame = NSRect(x: pad - Label.inset, y: title.centeredY(in: bounds.height), width: width, height: title.lineHeight)
        } else {
            let block = title.lineHeight + note.lineHeight
            title.frame = NSRect(x: pad - Label.inset, y: (bounds.height - block) / 2, width: width, height: title.lineHeight)
            note.frame = NSRect(x: pad - Label.inset, y: title.frame.maxY, width: width, height: note.lineHeight)
        }
    }

    override func stateDidChange(animated: Bool) {
        refresh()
        refreshRemove()
    }

    private func refreshRemove() {
        let shown = item != nil && !caps.isEmpty && (isHovered || isRecording)
        guard removeButton.isHidden == shown else { return }
        removeButton.isHidden = !shown
        needsLayout = true
    }

    private func refresh() {
        let editable = item != nil
        let fill: NSColor? = isRecording ? nil : editable && isPressed ? Tokens.Color.pressedFill : editable && isHovered ? Tokens.Color.hoverFill : nil
        layer?.backgroundColor = fill.map { cgColor($0) }
        caps.forEach { $0.isHidden = isRecording }
        let none = caps.isEmpty && editable
        field.isHidden = !(isRecording || none)
        // Recording looks like a field being typed in: the soft fill and the window's accent ring.
        let accent = Brand.Theme.for(self).accent
        field.layer?.borderColor = isRecording ? cgColor(accent.withAlphaComponent(Tokens.Color.focusAlpha)) : nil
        field.layer?.borderWidth = isRecording ? Tokens.Metric.fieldRing : 0
        field.layer?.backgroundColor = isRecording ? cgColor(Tokens.Color.fieldFill) : nil
        if !isRecording && none { fieldLabel.stringValue = String(localized: "None", comment: "In place of the keys of a command with no shortcut, in Settings › Shortcuts."); fieldLabel.textColor = Tokens.Color.textTertiary }
        needsLayout = true
    }

    // MARK: Recording

    private func startRecording() {
        guard let item, !isRecording else { return }
        ShortcutRow.recording?.stopRecording()
        ShortcutRow.recording = self
        isRecording = true
        showHeld([])
        window?.makeFirstResponder(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                // A click anywhere else ends it, unchanged.
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stopRecording() }
                return event
            case .flagsChanged:
                self.showHeld(event.modifierFlags)
                return nil
            default:
                let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                if plain && event.keyCode == 53 { self.stopRecording(); return nil }
                if plain && (event.keyCode == 51 || event.keyCode == 117) {
                    Shortcuts.set(Shortcuts.Combo.none, for: item)
                    self.finish(taken: nil)
                    return nil
                }
                guard let combo = Shortcuts.combo(from: event) else {
                    self.fieldLabel.stringValue = String(localized: "Add ⌘, ⌥ or ⌃", comment: "In Settings › Shortcuts while recording, when the keys need a modifier.")
                    self.fieldLabel.textColor = Tokens.Color.caution
                    return nil
                }
                if let fixed = Shortcuts.reserved(combo) {
                    self.fieldLabel.stringValue = String(localized: "Used for “\(fixed)”", comment: "In Settings › Shortcuts while recording, when the keys belong to a fixed command; its name.")
                    self.fieldLabel.textColor = Tokens.Color.caution
                    return nil
                }
                let taken = Shortcuts.set(combo, for: item)
                self.finish(taken: taken)
                return nil
            }
        }
    }

    /// While recording: the modifiers you're holding, so you can see the shortcut forming.
    private func showHeld(_ flags: NSEvent.ModifierFlags) {
        var held = ""
        if flags.isSuperset(of: Shortcuts.hyperFlags) {
            held = Shortcuts.hyper
        } else {
            if flags.contains(.control) { held += "⌃" }
            if flags.contains(.option) { held += "⌥" }
            if flags.contains(.shift) { held += "⇧" }
            if flags.contains(.command) { held += "⌘" }
        }
        fieldLabel.stringValue = held.isEmpty ? String(localized: "Type a shortcut", comment: "In Settings › Shortcuts while recording a new shortcut.") : held + " …"
        fieldLabel.textColor = held.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
    }

    private func finish(taken: NSMenuItem?) {
        stopRecording()
        let name = taken.map { $0.title.hasSuffix("…") ? String($0.title.dropLast()) : $0.title }
        if let name { ShortcutRow.lastTaken = (item, name) }
        onChange?()
    }

    /// The last change that took keys from another command, said on the row once the list redraws.
    static var lastTaken: (item: NSMenuItem?, from: String)?

    func showTakenNoteIfNeeded() {
        guard let taken = ShortcutRow.lastTaken, taken.item === item else { return }
        say(String(localized: "Taken from “\(taken.from)”, which has no shortcut now",
                   comment: "Under a shortcut in Settings › Shortcuts, after it took keys from another command; that command's name."))
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if ShortcutRow.recording === self { ShortcutRow.recording = nil }
        isRecording = false
    }

    #if DEBUG
    func debugRecord() { startRecording() }
    var debugTitle: String { title.stringValue }
    #endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum DefaultBrowser {
    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func make(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        let app = Bundle.main.bundleURL
        // macOS asks once, for http, and that answer makes Zigzag the web browser. Asking for https at the same time
        // put a second, identical question on screen; it's only asked after, and only if the first didn't cover it.
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else {
                DispatchQueue.main.async { completion() }
                return
            }
            DispatchQueue.main.async {
                guard let https = URL(string: "https://example.com"),
                      NSWorkspace.shared.urlForApplication(toOpen: https)?.standardizedFileURL != app.standardizedFileURL else {
                    completion()
                    return
                }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                    DispatchQueue.main.async { completion() }
                }
            }
        }
    }
}

/// The language Zigzag shows when you pick one in Settings instead of leaving it to the Mac. Kept where macOS keeps
/// an app's own language, which System Settings › Language & Region › Applications writes too, so both agree.
enum AppLanguage {
    struct Choice {
        /// Nil: whatever the Mac's own languages pick.
        let code: String?
        let title: String
    }

    /// Zigzag's languages, English first, each once: a release build lists each twice, from its Info.plist and from
    /// its .lproj folders.
    private static var languages: [String] {
        Set(Bundle.main.localizations.filter { $0 != "Base" }).sorted { $0 == "en" ? true : $1 == "en" ? false : $0 < $1 }
    }

    static var choices: [Choice] {
        [Choice(code: nil, title: String(localized: "System (\(systemName))", comment: "First choice of the Language menu in Settings › General. The placeholder is the language the Mac would pick, named in itself."))]
            + languages.map { Choice(code: $0, title: ownName($0)) }
    }

    /// A language as its speakers write it.
    static func ownName(_ code: String) -> String {
        switch code {
        case "en": "English"
        case "zh-Hans": "简体中文"
        default: Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        }
    }

    /// The language the Mac's own list picks from Zigzag's, ignoring a choice made here.
    static var systemName: String {
        let mac = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? ["en"]
        return ownName(Bundle.preferredLocalizations(from: languages, forPreferences: mac).first ?? "en")
    }

    /// The language picked for Zigzag alone, or nil to follow the Mac.
    static var chosen: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let own = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String], !own.isEmpty else { return nil }
            return Bundle.preferredLocalizations(from: languages, forPreferences: own).first
        }
        set {
            if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }
}
