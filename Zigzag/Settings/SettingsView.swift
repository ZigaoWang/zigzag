import AppKit
import WebKit

// MARK: - Groups of rows

/// A group of rows on the page: plain rows on the page's surface with hairlines between them, starting where their
/// text does. No card behind them.
final class FormGroup: NSView {
    private(set) var rows: [NSView] = []
    private var lines: [NSView] = []
    private let background = ColorView(color: Tokens.Color.surfaceGroup)

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
    }

    func removeAllRows() {
        (rows + lines).forEach { $0.removeFromSuperview() }
        rows = []
        lines = []
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
            row.isHidden = !available || (!all && !has((row as? SettingsSearchable)?.searchText ?? ""))
        }
        needsLayout = true
        return rows.filter { !$0.isHidden }.count
    }

    private func rowHeight(_ row: NSView, _ width: CGFloat) -> CGFloat { (row as? FormRow)?.height(for: width) ?? row.frame.height }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layer?.borderColor = background.cgColor(Tokens.Color.surfaceGroupEdge)
        var y: CGFloat = 0
        let shown = rows.filter { !$0.isHidden }
        lines.forEach { $0.isHidden = true }
        for (i, row) in shown.enumerated() {
            let h = rowHeight(row, bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
            if i < shown.count - 1 {
                // The hairline starts where the text does, past any picture, and runs to the group's edge.
                let x = (row as? FormRow)?.textInset ?? (row as? SpaceSettingsRow)?.textInset ?? Tokens.Page.groupPad
                lines[i].isHidden = false
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
    var searchText: String { [title.stringValue, detail.stringValue, keywords].joined(separator: " ") }
    /// More words "Find a setting" knows the row by, like its button's.
    var keywords = ""
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

    /// Where the row's text starts.
    var textInset: CGFloat { icon.isHidden ? pad : pad + Self.iconSide + Tokens.Space.x3 }

    /// Narrow (half of a split, a small window), the control goes under the text instead of squeezing it.
    private func isStacked(_ width: CGFloat) -> Bool {
        controlSize.width > 0 && width - pad - controlSize.width - Tokens.Space.x4 - textInset < Self.minimumTextWidth
    }
    private static let minimumTextWidth: CGFloat = 180

    private func textWidth(for width: CGFloat) -> CGFloat {
        let control = controlSize.width > 0 && !isStacked(width) ? controlSize.width + Tokens.Space.x4 : 0
        return max(0, width - pad - control - textInset)
    }

    private func detailHeight(for width: CGFloat) -> CGFloat {
        detail.isHidden ? 0 : ceil(detail.sizeThatFits(NSSize(width: textWidth(for: width), height: 400)).height)
    }

    /// The height this row needs at `width`.
    func height(for width: CGFloat) -> CGFloat {
        let stack = isStacked(width) ? Tokens.Space.x3 + controlSize.height : 0
        guard !detail.isHidden else { return stack > 0 ? Tokens.Page.groupRowPad * 2 + title.lineHeight + stack : Tokens.Page.groupRowHeight }
        return max(Tokens.Page.groupRowHeight, Tokens.Page.groupRowPad * 2 + title.lineHeight + Self.lineGap + detailHeight(for: width) + stack)
    }

    override func layout() {
        super.layout()
        let size = controlSize
        let stacked = isStacked(bounds.width)
        control.frame = stacked
            ? NSRect(x: textInset, y: bounds.height - Tokens.Page.groupRowPad - size.height, width: min(size.width, bounds.width - textInset - pad), height: size.height)
            : NSRect(x: bounds.width - pad - size.width, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
        if !icon.isHidden {
            let side = Self.iconSide
            icon.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        }
        let x = textInset - Label.inset
        let width = textWidth(for: bounds.width) + Label.inset * 2
        let detailHeight = detailHeight(for: bounds.width)
        let block = title.lineHeight + (detail.isHidden ? 0 : Self.lineGap + detailHeight)
        let top = stacked ? Tokens.Page.groupRowPad : round((bounds.height - block) / 2)
        title.frame = NSRect(x: x, y: top, width: width, height: title.lineHeight)
        detail.frame = NSRect(x: x, y: title.frame.maxY + Self.lineGap, width: width, height: detailHeight)
    }
}

/// The version of Zigzag you have, at the end of General: a quiet row like the rest, so the page's one brand moment
/// is the wordmark by its title.
enum SettingsVersionRow {
    static func make() -> FormRow {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let update = PillButton(title: String(localized: "Check for Updates…", comment: "Button in Settings › General, beside Zigzag's version."))
        update.onClick = { _ in Updater.shared.checkForUpdates() }
        let row = FormRow(title: "Zigzag", detail: String(localized: "Version \(version)", comment: "Zigzag's version, in Settings › General."), control: update)
        row.keywords = String(localized: "check for updates", comment: "Words that find the version row with Find a setting in Settings. Not shown.")
        return row
    }

    /// Betas first, for those who want to try new versions on their own tabs and data.
    static func betas() -> FormRow {
        let toggle = Toggle(isOn: Updater.getsBetas)
        toggle.onChange = { on in Updater.getsBetas = on }
        let row = FormRow(title: String(localized: "Beta updates", comment: "A setting in Settings › General."),
                          detail: String(localized: "Try new versions first, on your own tabs and data.", comment: "Explanation under “Beta updates” in Settings › General."),
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
    case general, appearance, tabs, spaces, profiles, search, mini, passwords, privacy, translation, extensions
    case websiteData = "website-data"
    case shortcuts

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "A section of Settings.")
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
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
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
        }
    }

    /// Its name in the page's address: zigzag://settings/privacy.
    var path: String { rawValue }

    /// The sections that show one profile's things. With a single profile there's nothing to tell apart: Extensions
    /// sits among the others and what Website Data holds stays in Privacy, as before there were profiles.
    static let perProfile: [SettingsPane] = [.extensions, .websiteData]

    /// The column's sections: the ones every profile shares, then, with more than one profile, the ones about
    /// the profile chosen there.
    static func column(manyProfiles: Bool) -> (shared: [SettingsPane], profile: [SettingsPane]) {
        guard manyProfiles else { return (allCases.filter { $0 != .websiteData }, []) }
        return (allCases.filter { !perProfile.contains($0) }, perProfile)
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
    private let column = FlippedView()
    /// The chosen section's fill, gliding to the one you pick.
    private let sectionSelection = SelectionGlide()
    /// The wordmark and "Settings" at the top of the column, where History has its own.
    private let columnTitle = PageTitleView(String(localized: "Settings", comment: "Title of the Settings page, also its tab's name."))
    /// Over the chosen section: its name, and the search at the right, as History's header has them.
    private let header = PageHeader()
    private let paneTitle = PageTitleView("")
    private let columnEdge = ColorView(color: Tokens.Color.separator)
    private let scroll = NSScrollView()
    private let documentView = FlippedView()
    private(set) var pane = SettingsPane.general
    /// Finds a setting in any section, at the top right of the page.
    private let settingSearch = FilledField.search(String(localized: "Find a setting", comment: "Placeholder of the search field at the top of Settings."))
    /// You picked another section: the tab's address follows, so the tab comes back to it.
    var onPaneChange: ((SettingsPane) -> Void)?

    private let versionGroup = FormGroup()
    private let generalGroup = FormGroup()
    private let automationGroup = FormGroup()
    private let tabsGroup = FormGroup()
    private let searchGroup = FormGroup()
    private let blockingGroup = FormGroup()
    private let spacesGroup = FormGroup()
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
    /// Each site keeping cookies, storage or a cache on this Mac, to remove one at a time.
    private let siteDataGroup = FormGroup()
    private var siteDataShowsAll = false
    /// Every site with a choice made for it, not only the first 30.
    private var sitesShowAll = false
    private var siteDataTask: Task<Void, Never>?
    /// Reset All beside the Sites heading, there only when something was chosen for a site.
    private var sitesReset: PillButton?
    private var alwaysReset: PillButton?
    private let translationGroup = FormGroup()
    private let alwaysGroup = FormGroup()
    private let extensionsGroup = FormGroup()
    private let developerGroup = FormGroup()
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
    private let darkPages = DropdownButton()
    private let newTabPlace = DropdownButton()
    private let pinOfferToggle = Toggle()
    private let nestToggle = Toggle()
    private let swipeToggle = Toggle()
    private let miniToggle = Toggle()
    private let energyToggle = Toggle()
    private let languagePicker = DropdownButton()
    private let defaultButton = PillButton(title: String(localized: "Set as Default", comment: "Button in Settings › General that makes Zigzag the default browser."))
    private let defaultStatus = StatusLabel(String(localized: "Zigzag is your default browser", comment: "In Settings › General, in place of Set as Default once it's done."))
    private let blockingToggle = Toggle()
    private let pipToggle = Toggle()
    private let suggestionsToggle = Toggle()
    private let borderlessToggle = Toggle()
    private let addressAboveToggle = Toggle()
    private let largeNamesToggle = Toggle()
    private let quitToggle = Toggle()
    private let scriptJavaScriptToggle = Toggle()
    private let motionToggle = Toggle()
    /// Where downloads go: Downloads, another folder, or ask each time.
    private let downloadPlace = DropdownButton()
    private var downloadPlaceToken: SignalToken?
    private let saveToggle = Toggle()
    private let fillToggle = Toggle()
    private let cardToggle = Toggle()
    private let translateOffer = Toggle()
    private let translateInto = DropdownButton()
    private var languages: [(id: String, name: String)] = []
    private let addSpaceButton = PillButton(title: String(localized: "New Space", comment: "Button beside Your Spaces in Settings › Spaces."))
    private let addProfileButton = PillButton(title: String(localized: "New Profile…", comment: "Button beside Your Profiles in Settings › Profiles: opens the sheet that makes a profile."))
    private let getExtensionsButton = PillButton(title: String(localized: "Get Extensions", comment: "Button in Settings › Extensions: opens the Chrome Web Store."))
    private let loadUnpackedButton = PillButton(title: String(localized: "Load Unpacked…", comment: "Button in Settings › Extensions, in developer mode: loads an extension from a folder."))
    private var spaceRows: [SpaceSettingsRow] = []
    private var token: SignalToken?
    private var extensionsToken: SignalToken?
    private var engineToken: SignalToken?

    private var keyToken: NSObjectProtocol?

    init(pane: SettingsPane = .general) {
        self.pane = pane.shown(manyProfiles: Library.shared.hasManyProfiles)
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        // Its own layer, so it paints the page's surface rather than showing whatever is under it.
        wantsLayer = true
        build()
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
                // One turned on or off may give a search engine, or take yours with it.
                self.refreshEngines()
                self.refreshCustomSearch()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Covering the page, it takes the keyboard from the web view underneath, so typing goes nowhere unexpected.
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cgColor(Tokens.Color.surface)
        column.layer?.backgroundColor = cgColor(Brand.Theme.for(self).wash)
    }

    private var themeToken: SignalToken?

    // MARK: Building

    private func build() {
        // The column of sections, under the page's title.
        column.addSubview(columnTitle)
        column.addSubview(sectionSelection)
        buildColumn()
        // The column of sections takes a light tint of the window's space, so Settings belongs to it.
        column.wantsLayer = true
        addSubview(column)
        addSubview(columnEdge)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.needsDisplay = true }

        // General
        defaultButton.onClick = { [weak self] _ in self?.makeDefault() }
        let defaultControl = NSStackView(views: [defaultStatus, defaultButton])
        defaultControl.spacing = Tokens.Space.x2
        versionGroup.add(SettingsVersionRow.make())
        versionGroup.add(SettingsVersionRow.betas())
        if let restore = SettingsVersionRow.restore() { versionGroup.add(restore) }
        generalGroup.add(FormRow(title: String(localized: "Default browser", comment: "A setting in Settings › General."),
                                 detail: String(localized: "Links from other apps open here.", comment: "Explanation under “Default browser” in Settings › General."),
                                 control: defaultControl))
        // Only once Zigzag speaks more than one language: macOS lists an app under Language & Region only then.
        if Self.hasLanguages {
            // Each language named in itself, so anyone finds theirs whatever Zigzag is in now.
            languagePicker.options = AppLanguage.choices.map { DropdownButton.Option(title: $0.title) }
            languagePicker.selectedIndex = AppLanguage.choices.firstIndex { $0.code == AppLanguage.chosen } ?? 0
            languagePicker.onSelect = { [weak self] index in self?.chooseLanguage(AppLanguage.choices[index].code) }
            generalGroup.add(FormRow(title: String(localized: "Language", comment: "A setting in Settings › General."),
                                     detail: String(localized: "Zigzag follows your Mac’s language unless you pick one here.",
                                                    comment: "Explanation under “Language” in Settings › General."),
                                     control: languagePicker))
        }
        downloadPlace.onSelect = { index in DownloadPlace.pick(index) }
        downloadPlaceToken = DownloadPlace.changed.observe { [weak self] in self?.refreshDownloadPlace() }
        generalGroup.add(FormRow(title: String(localized: "Save downloads to", comment: "A setting in Settings › General."),
                                 detail: String(localized: "Or have Zigzag ask where, each time.", comment: "Explanation under “Save downloads to” in Settings › General."),
                                 control: downloadPlace))
        let importButton = PillButton(title: String(localized: "Import…", comment: "Button in Settings › General that opens the Import window."))
        importButton.onClick = { _ in ImportWindowController.show() }
        generalGroup.add(FormRow(title: String(localized: "Import from another browser", comment: "A setting in Settings › General."),
                                 detail: String(localized: "Passwords, bookmarks and history. The other browser isn’t changed.", comment: "Explanation under “Import from another browser” in Settings › General."),
                                 control: importButton))
        quitToggle.onChange = { on in AppDelegate.asksBeforeQuitting = on }
        generalGroup.add(FormRow(title: String(localized: "Ask before quitting", comment: "A setting in Settings › General."),
                                 detail: String(localized: "So ⌘Q never closes everything by accident.", comment: "Explanation under “Ask before quitting” in Settings › General."),
                                 control: quitToggle))
        scriptJavaScriptToggle.onChange = { on in Scripting.allowsJavaScript = on }
        automationGroup.add(FormRow(title: String(localized: "Allow JavaScript from Apple Events", comment: "A setting in Settings › General, under Automation, as Safari names it."),
                                    detail: String(localized: "Scripts and apps you allow in Privacy & Security › Automation can then read and change any page you have open, signed in or not. Never in private windows.",
                                                   comment: "Explanation under “Allow JavaScript from Apple Events” in Settings › General."),
                                    control: scriptJavaScriptToggle))

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
        darkPages.options = DarkPages.Mode.allCases.map { mode in
            let title = switch mode {
            case .off: String(localized: "Off", comment: "A choice for “Dark pages” in Settings › Appearance: websites are shown as they are.")
            case .system: String(localized: "When the Mac Is Dark", comment: "A choice for “Dark pages” in Settings › Appearance: websites are drawn dark while macOS is in Dark Mode.")
            case .always: String(localized: "Always", comment: "A choice for “Dark pages” in Settings › Appearance: websites are always drawn dark.")
            }
            return DropdownButton.Option(title: title)
        }
        darkPages.onSelect = { index in DarkPages.mode = DarkPages.Mode.allCases[index] }
        let darkRow = FormRow(title: String(localized: "Dark pages", comment: "A setting in Settings › Appearance: websites without a dark look of their own are drawn dark."),
                              detail: String(localized: "Websites without a dark look of their own are drawn dark. Pictures and video stay as they are.",
                                             comment: "Explanation under “Dark pages” in Settings › Appearance."),
                              control: darkPages)
        darkRow.keywords = String(localized: "dark mode night theme black invert", comment: "Words that find the Dark pages setting with Find a setting in Settings. Not shown.")
        appearanceGroup.add(darkRow)
        motionToggle.onChange = { on in Tokens.Motion.reducesMotionHere = on }
        appearanceGroup.add(FormRow(title: String(localized: "Reduce motion", comment: "A setting in Settings › Appearance."),
                                    detail: String(localized: "Things appear in place instead of sliding or growing. Fades stay.", comment: "Explanation under “Reduce motion” in Settings › Appearance."),
                                    control: motionToggle))

        // Tabs
        newTabPlace.options = TabManager.NewTabPlace.allCases.map { place in
            let title = switch place {
            case .next: String(localized: "Next to the Current Tab", comment: "A choice for “New tabs open” in Settings › Tabs: just below the tab you're on, or the page a link came from.")
            case .top: String(localized: "At the Top", comment: "A choice for “New tabs open” in Settings › Tabs: above the other tabs.")
            case .bottom: String(localized: "At the Bottom", comment: "A choice for “New tabs open” in Settings › Tabs: below the other tabs.")
            }
            return DropdownButton.Option(title: title)
        }
        newTabPlace.onSelect = { index in TabManager.newTabPlace = TabManager.NewTabPlace.allCases[index] }
        tabsGroup.add(FormRow(title: String(localized: "New tabs open", comment: "A setting in Settings › Tabs: where a new tab goes in the sidebar's list."),
                              detail: String(localized: "Where ⌘T and links put a new tab in the sidebar.", comment: "Explanation under “New tabs open” in Settings › Tabs."),
                              control: newTabPlace))
        nestToggle.onChange = { on in TabManager.nestsOpenedLinks = on }
        let nestRow = FormRow(title: String(localized: "Open ⌘-clicked links under their tab", comment: "A setting in Settings › Tabs: a link opened in a new tab goes in the sidebar nested under the tab it came from. ⌘ is the Command key."),
                              detail: String(localized: "A link you open in a new tab sits under the page it came from. Drag a tab out to make it a tab of its own.", comment: "Explanation under “Open ⌘-clicked links under their tab” in Settings › Tabs."),
                              control: nestToggle)
        nestRow.keywords = String(localized: "nested tree child command click", comment: "Words that find the Open ⌘-clicked links under their tab setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(nestRow)
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
        let videoRow = FormRow(title: String(localized: "Keep videos playing when you switch tabs", comment: "A setting in Settings › Tabs."),
                               detail: String(localized: "A playing video follows you in a small player.", comment: "Explanation under “Keep videos playing when you switch tabs” in Settings › Tabs."),
                               control: pipToggle)
        videoRow.keywords = String(localized: "mini player picture in picture pip floating", comment: "Words that find the Keep videos playing setting with Find a setting in Settings. Not shown.")
        tabsGroup.add(videoRow)
        swipeToggle.onChange = { on in SwipeNavigator.isOn = on }
        tabsGroup.add(FormRow(title: String(localized: "Swipe to go back and forward", comment: "A setting in Settings › Tabs: two fingers sideways on the trackpad go back or forward."),
                              detail: String(localized: "Two fingers sideways on the trackpad. When off, websites get every swipe.", comment: "Explanation under “Swipe to go back and forward” in Settings › Tabs."),
                              control: swipeToggle))
        pinOfferToggle.onChange = { on in BrowserWindowController.offersToPinWanderedPage = on }
        tabsGroup.add(FormRow(title: String(localized: "Offer to pin the page you moved to", comment: "A setting in Settings › Tabs."),
                              detail: String(localized: "After you close a pinned tab that went to another page, like a new chat.", comment: "Explanation under “Offer to pin the page you moved to” in Settings › Tabs."),
                              control: pinOfferToggle))

        // Spaces
        addSpaceButton.onClick = { [weak self] _ in self?.addSpace() }
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
                                detail: String(localized: "Used when what you type isn’t an address.", comment: "Explanation under “Search engine” in Settings › Search."),
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
                              detail: String(localized: "Instead of in a new tab.", comment: "Explanation under “Open links from other apps in Zigzag Mini” in Settings › Zigzag Mini."),
                              control: miniToggle))

        // Privacy
        blockingToggle.onChange = { on in ContentBlocker.isEnabled = on }
        // EasyList's licence asks for credit; this is where people look for what does the blocking.
        blockingGroup.add(FormRow(title: String(localized: "Block ads and trackers", comment: "A setting in Settings › Privacy."),
                                  detail: String(localized: "Uses EasyList and EasyPrivacy, by the EasyList authors.", comment: "Explanation under “Block ads and trackers” in Settings › Privacy."),
                                  control: blockingToggle))

        // Passwords
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
        getExtensionsButton.onClick = { [weak self] _ in self?.getExtensions() }
        loadUnpackedButton.onClick = { [weak self] _ in self?.loadUnpacked() }

        // One search for everything, shortcuts included (by name or by keys).
        settingSearch.field.delegate = self
        header.leading = paneTitle
        header.trailing = [settingSearch]

        reloadPrivacy()

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
        reloadSpaces()
        reloadProfiles()
        reloadExtensions()
        show(pane)
    }

    // MARK: The page's layout

    /// How the sections sit: a column with their names, a rail of symbols when the page gets narrower, and a row of
    /// symbols across the top when it's too narrow for even that (half of a split in a small window).
    private enum Arrangement { case column, rail, row }
    private var arrangement: Arrangement { bounds.width >= 720 ? .column : bounds.width >= 520 ? .rail : .row }
    private var laidOutWidth: CGFloat = -1

    /// The page's edge to its content: the same as History's, and tighter on a narrow page.
    private var gutter: CGFloat { bounds.width < Tokens.Page.narrowWidth ? Tokens.Page.narrowGutter : Tokens.Page.gutter }

    /// Where the pane's content runs across the scroll view: as wide as the page allows up to the shared maximum,
    /// centered past it.
    private func contentSpan(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inner = max(0, min(Tokens.Page.maxWidth, width - gutter * 2))
        return (round((width - inner) / 2), inner)
    }

    override func layout() {
        super.layout()
        let arrangement = arrangement
        let line = Tokens.Metric.hairline
        let headerHeight = Tokens.Page.headerHeight
        var area = bounds
        switch arrangement {
        case .column, .rail:
            let width = arrangement == .column ? Tokens.Page.columnWidth : Tokens.Space.x16
            column.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            columnEdge.frame = NSRect(x: width, y: 0, width: line, height: bounds.height)
            area = NSRect(x: width + line, y: 0, width: max(0, bounds.width - width - line), height: bounds.height)
            header.frame = NSRect(x: area.minX, y: 0, width: area.width, height: headerHeight)
        case .row:
            // The header across the top, then the sections as a row of symbols under it.
            let height = Tokens.Space.x10 + Tokens.Space.x2
            header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            column.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: height)
            columnEdge.frame = NSRect(x: 0, y: column.frame.maxY, width: bounds.width, height: line)
            area = NSRect(x: 0, y: column.frame.maxY + line, width: bounds.width, height: max(0, bounds.height - column.frame.maxY - line))
        }
        // The page scrolls under the header; in a row, under the sections too.
        let top = arrangement == .row ? area.minY : headerHeight
        scroll.frame = NSRect(x: area.minX, y: top, width: area.width, height: max(0, bounds.height - top))
        let span = contentSpan(in: header.frame.width)
        // Rows have no card now, so their text sits a group's padding in: the title and search line up with it.
        header.contentFrame = (span.x + Tokens.Page.groupPad, span.x + span.width - Tokens.Page.groupPad)
        // With no column to carry it, the wordmark heads the pane's own title.
        refreshTitle()
        placeProfilePicker(arrangement)
        settingSearch.tint = Brand.Theme.for(self).accent
        layoutColumn(arrangement)
        // The pane's rows depend only on the width, so a change of height just stretches the page under them,
        // instead of rebuilding every row (Shortcuts has about a hundred).
        if scroll.frame.width != laidOutWidth {
            layoutDocument()
        } else {
            documentView.frame.size.height = max(contentHeight, scroll.contentSize.height)
        }
    }

    /// The header's title: the chosen section, or "results" while a search goes through all of them (the column
    /// already says "settings").
    private func refreshTitle() {
        paneTitle.title = isSearching ? String(localized: "Results", comment: "Title of Settings while it shows what Find a setting found.") : pane.title
        header.needsLayout = true
    }

    @objc private func scrolled() {
        header.showsEdge = scroll.contentView.bounds.minY > 0
    }

    private func layoutColumn(_ arrangement: Arrangement) {
        columnTitle.isHidden = arrangement != .column
        items.forEach { $0.isCompact = arrangement != .column }
        // With names beside them, the sections about one profile stand under a heading and the menu that chooses it;
        // as symbols alone they follow the others, and the menu is beside the search (`placeProfilePicker`).
        let grouped = arrangement == .column && columnHasProfiles
        profileHeading.isHidden = !grouped
        // The heading and the menu take about two sections' room.
        let count = CGFloat(items.count + (grouped ? 2 : 0))
        // In the row they shrink to fit, rather than run off the page's edge.
        let side = arrangement == .row ? min(Tokens.Space.x10, floor((column.bounds.width - Tokens.Space.x2 * 2) / count)) : Tokens.Space.x10
        // Down the column, a short page (a small window) takes some height off each section, never below a control's,
        // so all of them fit under the title.
        let top = Tokens.Page.headerHeight + Tokens.Space.x1
        func height(_ tallest: CGFloat) -> CGFloat {
            max(Tokens.Page.controlHeight, min(tallest, floor((column.bounds.height - top - Tokens.Space.x2) / count) - 2))
        }
        switch arrangement {
        case .column:
            // The title sits where History's does; the sections' text lines up under it, their fills reaching past.
            let gutter = Tokens.Page.gutter, inset = Tokens.Page.rowInset
            columnTitle.frame = NSRect(x: gutter, y: Tokens.Page.headerTop, width: column.bounds.width - gutter * 2, height: Tokens.Page.controlHeight)
            let rowHeight = height(Tokens.Page.rowHeight)
            var y = top
            for item in items {
                if grouped, item.pane == SettingsPane.perProfile.first {
                    y += Tokens.Space.x3
                    profileHeading.frame = NSRect(x: gutter - Label.inset, y: y, width: column.bounds.width - gutter * 2, height: profileHeading.lineHeight)
                    y = profileHeading.frame.maxY + Tokens.Space.x2
                    profilePicker.frame = NSRect(x: gutter - inset, y: y, width: column.bounds.width - (gutter - inset) * 2, height: Tokens.Page.controlHeight)
                    y = profilePicker.frame.maxY + Tokens.Space.x2
                }
                item.frame = NSRect(x: gutter - inset, y: y, width: column.bounds.width - (gutter - inset) * 2, height: rowHeight)
                y += rowHeight + 2
            }
        case .rail:
            let rowHeight = height(side)
            var y = top
            for item in items {
                item.frame = NSRect(x: (column.bounds.width - side) / 2, y: y, width: side, height: rowHeight)
                y += rowHeight + 2
            }
        case .row:
            // Spread evenly across, but never further apart than the rail has them.
            let gap = min(Tokens.Space.x2, max(0, (column.bounds.width - Tokens.Space.x4 * 2 - side * count) / (count - 1)))
            let total = side * count + gap * (count - 1)
            var x = max(0, round((column.bounds.width - total) / 2))
            for item in items {
                item.frame = NSRect(x: x, y: (column.bounds.height - side) / 2, width: side, height: side)
                x += side + gap
            }
        }
        moveSectionSelection(animated: false)
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
        refreshTitle()
        if showsWebsiteData { reloadPrivacy() }
        if pane == .shortcuts { reloadShortcuts() }
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
            reloadPasswords()
            reloadTranslation()
            if showsWebsiteData { reloadPrivacy() }
            layoutDocument()
        }
    }

    /// Its picture, for the tab's preview and switcher.
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
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
            if showsWebsiteData { reloadPrivacy() }
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
            if showsWebsiteData { reloadPrivacy() }
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

    // MARK: Groups

    private func reloadExtensions() {
        extensionsGroup.removeAllRows()
        developerGroup.removeAllRows()
        defer { if pane == .extensions || isSearching { layoutDocument() } }
        guard #available(macOS 15.4, *) else { return }
        loadUnpackedButton.isHidden = !ExtensionStore.developerMode
        let installed = profile.extensions.installed.sorted {
            ($0.value.displayName ?? $0.key).localizedCaseInsensitiveCompare($1.value.displayName ?? $1.key) == .orderedAscending
        }
        if installed.isEmpty {
            let get = PillButton(title: String(localized: "Get Extensions", comment: "Button in Settings › Extensions: opens the Chrome Web Store."))
            get.onClick = { [weak self] _ in self?.getExtensions() }
            extensionsGroup.add(FormRow(title: String(localized: "No extensions yet", comment: "A setting in Settings › Extensions."),
                                        detail: String(localized: "Find one in the Chrome Web Store and choose Add to Zigzag.", comment: "Explanation under “No extensions yet” in Settings › Extensions."),
                                        control: get))
        }
        for (id, ext) in installed { extensionsGroup.add(extensionRow(id: id, ext: ext)) }
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
        let developer = Toggle(isOn: ExtensionStore.developerMode)
        developer.onChange = { [weak self] on in
            ExtensionStore.developerMode = on
            self?.reloadExtensions()
        }
        developerGroup.add(FormRow(title: String(localized: "Developer mode", comment: "A setting in Settings › Extensions."),
                                   detail: String(localized: "Load an extension from a folder to test it.", comment: "Explanation under “Developer mode” in Settings › Extensions."),
                                   control: developer))
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
                                toolTip: String(localized: "Remove from Zigzag", comment: "Tooltip of the trash button on an extension's row in Settings › Extensions."))
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
        if ExtensionStore.isUnpacked(id) {
            detail.append(String(localized: "Unpacked", comment: "Under an extension's name in Settings › Extensions: it was loaded from a folder."))
        }
        if ExtensionStore.needsApproval(id) {
            detail.append(String(localized: "Update wants more access", comment: "Under an extension's name in Settings › Extensions."))
        }
        var limitsNote: String?
        if let manifest = ExtensionStore.manifest(for: id) {
            let limits = ExtensionReport(extension: ext, manifest: manifest, id: id).limits
            if !limits.isEmpty {
                detail.append(String(localized: "\(limits.count) features won’t work here", comment: "Under an extension's name in Settings › Extensions."))
                let names = Words.list(limits.map { $0.prefix(1).lowercased() + $0.dropFirst() })
                limitsNote = String(localized: "Won’t work in Zigzag: \(names).",
                                    comment: "Tooltip of an extension's row in Settings › Extensions: a list of the features Zigzag lacks.")
            }
        }
        let row = FormRow(title: ext.displayName ?? id, detail: detail.isEmpty ? "" : Words.list(detail), icon: ext.icon(for: NSSize(width: 24, height: 24)), control: stack)
        row.revealsOnHover(remove)
        row.toolTip = limitsNote
        return row
    }

    private func loadUnpacked() {
        guard #available(macOS 15.4, *), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Load", comment: "Button of the panel that loads an unpacked extension from a folder.")
        panel.message = String(localized: "Choose the folder that contains the extension’s manifest.json.",
                               comment: "Message of the panel that loads an unpacked extension. manifest.json is a file name.")
        let profile = profile
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await ExtensionStore.loadUnpacked(url, in: profile) == nil, let host = self {
                    ConfirmSheet.notice(in: host, title: String(localized: "Couldn’t load this extension", comment: "Title of the notice when an unpacked extension can't load."),
                                        message: String(localized: "That folder needs a manifest.json that Zigzag can read. Choose the folder that holds it.",
                                                        comment: "Message of the notice when an unpacked extension can't load. manifest.json is a file name."))
                }
            }
        }
    }

    /// The profiles there are, each with what it holds and the ways to change it. The first has no trash: there's
    /// always one profile.
    private func reloadProfiles() {
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
            let detail = Words.list([String(localized: "\(spaces) spaces", comment: "Under a profile's name in Settings › Profiles: how many spaces are on it."),
                                     String(localized: "\(extensions) extensions", comment: "Under a profile's name in Settings › Profiles: how many extensions it has.")])
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
        Task { @MainActor [weak self] in
            let found = await Profiles.shared.orphans()
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

    private func reloadSpaces() {
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
    private func reloadPasswords() {
        passwordsGroup.removeAllRows()
        cardGroup.removeAllRows()
        passwordsWindowGroup.removeAllRows()
        // Saving and filling are chosen for each profile: a password manager is an extension, and those are a profile's.
        let profile = profile
        let saves = PasswordCapture.offersToSave(in: profile), fills = Autofill.isOn(in: profile)
        saveToggle.isOn = saves
        fillToggle.isOn = fills
        let manager = PasswordManagers.active(in: profile)
        let managerNote = manager.map {
            String(localized: "Off while \($0) handles passwords. Turn on to use both.",
                   comment: "Under a password setting in Settings › Passwords, while a password manager extension (its name, like 1Password) is on.")
        }
        let saveNote = manager != nil && !saves ? managerNote!
            : String(localized: "After you sign in. Kept in your Keychain, synced with iCloud.", comment: "Explanation under “Offer to save passwords” in Settings › Passwords.")
        let fillNote = manager != nil && !fills ? managerNote!
            : String(localized: "Under sign-in fields, only on the site each was saved for. Passwords… there opens the Passwords app and password manager apps.", comment: "Explanation under “Fill saved passwords” in Settings › Passwords. Passwords… is the row in the fill-password menu; the Passwords app is Apple’s, password manager apps are ones like 1Password.")
        passwordsGroup.add(FormRow(title: String(localized: "Offer to save passwords", comment: "A setting in Settings › Passwords."),
                                   detail: saveNote,
                                   control: saveToggle))
        passwordsGroup.add(FormRow(title: String(localized: "Fill saved passwords", comment: "A setting in Settings › Passwords."),
                                   detail: fillNote,
                                   control: fillToggle))
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
        let always = PageTranslator.alwaysLanguages.map { PageTranslator.name(of: Locale.Language(identifier: $0)) }.sorted()
        // Laid out like Sites in Privacy: a heading, Reset All beside it only when there's something to reset.
        let reset = PillButton(title: String(localized: "Reset All", comment: "Button beside Always Translate in Settings › Translation."))
        reset.onClick = { [weak self] _ in
            PageTranslator.alwaysLanguages = []
            self?.reloadTranslation()
            self?.layoutDocument()
        }
        alwaysReset = always.isEmpty ? nil : reset
        alwaysGroup.add(always.isEmpty
            ? FormRow(title: String(localized: "None yet", comment: "Under Always Translate in Settings › Translation, when there's no language."),
                      detail: String(localized: "To always translate a language, choose it in a page’s site controls.", comment: "Under Always Translate in Settings › Translation."),
                      control: NSView())
            : FormRow(title: Words.list(always),
                      detail: String(localized: "Pages in these languages are translated as soon as they open.", comment: "Under the list of languages in Settings › Translation."),
                      control: NSView()))
    }

    // MARK: Shortcuts

    /// Every shortcut, read from the menu bar itself so the list is always right.
    private func reloadShortcuts() {
        var groups: [(String, FormGroup)] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            let group = FormGroup()
            func walk(_ menu: NSMenu, prefix: String) {
                for item in menu.items where !item.isSeparatorItem {
                    if let sub = item.submenu { walk(sub, prefix: item.title + " › "); continue }
                    // Items with keys, and ones whose keys you took away (so you can give them back).
                    guard !item.isAlternate, !item.keyEquivalent.isEmpty || Shortcuts.isCustom(item),
                          !item.isHidden || item.action == #selector(BrowserWindowController.closeTabsBelow(_:)) else { continue }
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

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === settingSearch.field { searchChanged() }
    }

    // MARK: Finding a setting

    private var searchWords: [String] { settingSearch.stringValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var isSearching: Bool { !searchWords.isEmpty }

    private func searchChanged() {
        items.forEach { $0.isSelected = !isSearching && $0.pane == pane }
        moveSectionSelection(animated: false)
        refreshTitle()
        reloadShortcuts()
        layoutDocument()
        documentView.scroll(.zero)
    }

    /// Escape empties the search, and the section you were on comes back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === settingSearch.field, selector == #selector(cancelOperation(_:)), isSearching else { return false }
        settingSearch.stringValue = ""
        searchChanged()
        return true
    }

    #if DEBUG
    func debugFind(_ text: String) {
        settingSearch.stringValue = text
        searchChanged()
    }

    /// What a scripted check reads: the section and profile shown, the column as it's built, the headings of the
    /// section's groups, and whether Zigzag saves and fills passwords in that profile.
    /// How many times the page has been laid out, for a check that it isn't laid out more than it needs.
    private(set) var debugLayouts = 0

    var debugState: [String: Any] {
        let profile = profile
        return ["layouts": debugLayouts, "inOtherProfiles": otherProfilesGroup.rows.count,
                "pane": pane.rawValue, "profile": Library.shared.directory.profile(profile.id)?.name ?? "",
                "column": items.map(\.pane.rawValue), "grouped": columnHasProfiles,
                "menu": profilePicker.superview === column ? "column" : profilePicker.superview === header ? "header" : "none",
                "headings": groups(of: pane).map { $0.title ?? "" },
                "saves": PasswordCapture.offersToSave(in: profile), "fills": Autofill.isOn(in: profile),
                "manager": PasswordManagers.active(in: profile) ?? ""]
    }
    #endif

    /// ⌘F on Settings finds a setting, rather than text in the empty page under it.
    @objc func showFindBar(_ sender: Any?) {
        window?.makeFirstResponder(settingSearch.field)
    }

    // The groups' headings, each said once for the page and its search.
    private static var updatesHeading: String { String(localized: "Updates", comment: "A heading in Settings › General: Zigzag's version and how it updates.") }
    private static var automationHeading: String { String(localized: "Automation", comment: "A heading in Settings › General: what scripts and Shortcuts may do in Zigzag.") }
    private static var spacesHeading: String { String(localized: "Your Spaces", comment: "A heading in Settings › Spaces.") }
    private static var profilesHeading: String { String(localized: "Your Profiles", comment: "A heading in Settings › Profiles.") }
    private static var unlistedHeading: String { String(localized: "Not Listed", comment: "A heading in Settings › Profiles, over data left on this Mac by profiles that are no longer in the list.") }
    private static var sitesHeading: String { String(localized: "Site Permissions", comment: "A heading in Settings › Privacy: camera, location, pop-ups and other choices made for single sites.") }
    private static var alwaysTranslateHeading: String { String(localized: "Always Translate", comment: "A heading in Settings › Translation.") }
    private static var fillingHeading: String { String(localized: "AutoFill", comment: "A heading in Settings › Passwords: when Zigzag offers to save and fill passwords and forms.") }
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
    /// What a button says for a moment once it has cleared something.
    private static var cleared: String { String(localized: "Cleared", comment: "Shown on a Clear button in Settings › Privacy for a moment after it clears.") }

    /// A permission chosen for a site, as Settings › Privacy › Sites lists it: "camera allowed".
    private static func siteChoice(_ kind: String, allowed: Bool) -> String? {
        switch (kind, allowed) {
        case ("camera", true): String(localized: "camera allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("camera", false): String(localized: "camera blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("microphone", true): String(localized: "microphone allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("microphone", false): String(localized: "microphone blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("cameraAndMicrophone", true): String(localized: "camera and microphone allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("cameraAndMicrophone", false): String(localized: "camera and microphone blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("location", true): String(localized: "location allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("location", false): String(localized: "location blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("notifications", true): String(localized: "notifications allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("notifications", false): String(localized: "notifications blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("popups", true): String(localized: "pop-ups allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        case ("popups", false): String(localized: "pop-ups blocked", comment: "A choice made for a site in Settings › Privacy, in a list of them.")
        default: nil
        }
    }

    /// Each section's groups and their headings, as a search goes through them.
    private func groups(of pane: SettingsPane) -> [(title: String?, group: FormGroup)] {
        switch pane {
        case .general: [(nil, generalGroup), (Self.automationHeading, automationGroup), (Self.updatesHeading, versionGroup)]
        case .appearance: [(nil, appearanceGroup)]
        case .tabs: [(nil, tabsGroup)]
        case .search: [(nil, searchGroup)]
        case .mini: [(nil, miniGroup)]
        case .spaces: [(Self.spacesHeading, spacesGroup)]
        case .profiles: [(Self.profilesHeading, profilesGroup), (Self.unlistedHeading, unlistedGroup)]
        case .passwords: [(nil, passwordsWindowGroup), (savingHeading, passwordsGroup)] + (hasManyProfiles ? [(Self.fillingHeading, cardGroup)] : [])
        case .privacy: [(nil, blockingGroup), (Self.sitesHeading, sitesGroup)] + (SettingsPane.websiteData(manyProfiles: hasManyProfiles) == .privacy ? websiteDataGroups : [])
        case .websiteData: SettingsPane.websiteData(manyProfiles: hasManyProfiles) == .websiteData ? websiteDataGroups : []
        case .translation: [(nil, translationGroup), (Self.alwaysTranslateHeading, alwaysGroup)]
        case .extensions: [(installedHeading, extensionsGroup), (Self.otherProfilesHeading, otherProfilesGroup), (nil, developerGroup)]
        case .shortcuts: shortcutGroups.map { ($0.0, $0.1) }
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
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let width = scroll.contentSize.width
        laidOutWidth = scroll.frame.width
        // The pane lines up with the header over it: the shared margins and maximum width, centered past it.
        let span = contentSpan(in: width)
        let pad = span.x, contentWidth = span.width
        var y: CGFloat = Tokens.Space.x3

        // A section: a quiet label low in its slot, standing in for a divider, then the group. A button that acts on the
        // whole group (New Space, Reset All) sits at the label's right, lined up with the rows' own controls.
        func section(_ title: String?, _ group: FormGroup, accessory: NSView? = nil) {
            if title != nil || accessory != nil {
                let size = accessory.map { $0.fittingSize } ?? .zero
                let slot = max(Tokens.Metric.sectionLabelHeight, size.height + Tokens.Space.x2)
                let label = Label.groupHeading(title ?? "")
                let labelY = y + slot - Tokens.Space.x2 - label.lineHeight
                label.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: labelY,
                                     width: max(0, contentWidth - size.width - Tokens.Space.x4 - Tokens.Page.groupPad), height: label.lineHeight)
                documentView.addSubview(label)
                if let accessory {
                    accessory.frame = NSRect(x: pad + contentWidth - Tokens.Page.groupPad - size.width, y: round(label.frame.midY - size.height / 2),
                                             width: size.width, height: size.height)
                    documentView.addSubview(accessory)
                }
                y += slot
            }
            group.frame = NSRect(x: pad, y: y, width: contentWidth, height: group.fittingHeight(for: contentWidth))
            group.needsLayout = true
            documentView.addSubview(group)
            y = group.frame.maxY + Tokens.Page.groupGap
        }

        // A line said once under a group, in the rows' own explanation style, wrapping on a narrow page.
        func note(_ text: String) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = Tokens.Font.detail()
            label.textColor = Tokens.Color.textSecondary
            label.isSelectable = false
            let textWidth = max(0, contentWidth - Tokens.Page.groupPad * 2) + Label.inset * 2
            let height = ceil(label.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
            label.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y - Tokens.Page.groupGap + Tokens.Space.x2, width: textWidth, height: height)
            documentView.addSubview(label)
            y = label.frame.maxY + Tokens.Page.groupGap
        }

        // A search: what matches, from every section, under the section's name.
        let words = searchWords
        for pane in SettingsPane.allCases {
            for (title, group) in groups(of: pane) { group.filter(words, names: [pane.title, title ?? ""]) }
        }
        if isSearching {
            var found = false
            for pane in SettingsPane.allCases {
                let shown = groups(of: pane).filter { $0.group.rows.contains { !$0.isHidden } }
                guard !shown.isEmpty else { continue }
                found = true
                let heading = Label(pane.title, font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
                heading.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y, width: contentWidth - Tokens.Page.groupPad, height: heading.lineHeight)
                documentView.addSubview(heading)
                y = heading.frame.maxY + Tokens.Space.x3
                for (title, group) in shown { section(title, group) }
                y += Tokens.Space.x2
            }
            if !found {
                let words = settingSearch.stringValue.trimmingCharacters(in: .whitespaces)
                let none = Label(String(localized: "No settings match “\(words)”.", comment: "In Settings when Find a setting finds nothing; what was typed."),
                                 font: Tokens.Font.row(), color: Tokens.Color.textSecondary)
                none.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y, width: contentWidth - Tokens.Page.groupPad, height: none.lineHeight)
                documentView.addSubview(none)
                y = none.frame.maxY + Tokens.Space.x6
            }
            finishDocument(y, width: width)
            return
        }

        switch pane {
        case .general, .appearance, .tabs, .search, .mini:
            for (title, group) in groups(of: pane) { section(title, group) }
        case .spaces:
            section(Self.spacesHeading, spacesGroup, accessory: addSpaceButton)
            // Said once, under the list, and only when there's an order to change.
            if spaceRows.count > 1 {
                note(String(localized: "Drag a space to change its order.", comment: "Hint under Your Spaces in Settings › Spaces."))
            }
        case .profiles:
            section(Self.profilesHeading, profilesGroup, accessory: addProfileButton)
            note(String(localized: "Each profile has its own extensions, sign-ins, history and favorites. Spaces on the same profile share them.", comment: "Under the list in Settings › Profiles."))
            if !unlistedGroup.rows.isEmpty { section(Self.unlistedHeading, unlistedGroup) }
        case .passwords, .websiteData:
            for (title, group) in groups(of: pane) { section(title, group) }
        case .privacy:
            section(nil, blockingGroup)
            section(Self.sitesHeading, sitesGroup, accessory: sitesReset)
            for (title, group) in groups(of: pane).dropFirst(2) { section(title, group) }
        case .translation:
            section(nil, translationGroup)
            section(Self.alwaysTranslateHeading, alwaysGroup, accessory: alwaysReset)
        case .extensions:
            // With nothing installed, the empty row already offers Get Extensions; once said is enough.
            getExtensionsButton.isHidden = !hasExtensions
            let buttons = NSStackView(views: [loadUnpackedButton, getExtensionsButton])
            buttons.spacing = Tokens.Space.x2
            section(installedHeading, extensionsGroup, accessory: buttons)
            if !otherProfilesGroup.rows.isEmpty { section(Self.otherProfilesHeading, otherProfilesGroup) }
            section(nil, developerGroup)
        case .shortcuts:
            let resetAll = PillButton(title: String(localized: "Reset All…", comment: "Button in Settings › Shortcuts that puts every shortcut back."))
            resetAll.isHidden = !Shortcuts.hasChanges
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
            let rw = resetAll.fittingWidth, rh = Tokens.Page.controlHeight
            resetAll.frame = NSRect(x: pad + contentWidth - Tokens.Page.groupPad - rw, y: y, width: rw, height: rh)
            documentView.addSubview(resetAll)
            let hint = Label(String(localized: "Click a shortcut to change or remove it. To find one, type its name or keys in Find a setting.",
                                    comment: "Hint at the top of Settings › Shortcuts. “Find a setting” is the search field's placeholder."),
                             font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
            hint.lineBreakMode = .byTruncatingTail
            hint.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y + (rh - hint.lineHeight) / 2,
                                width: max(0, contentWidth - Tokens.Page.groupPad * 2 - (resetAll.isHidden ? 0 : rw + Tokens.Space.x4)), height: hint.lineHeight)
            documentView.addSubview(hint)
            y += rh + Tokens.Space.x2
            for (title, group) in shortcutGroups { section(title, group) }
        }
        finishDocument(y, width: width)
    }

    private func finishDocument(_ y: CGFloat, width: CGFloat) {
        contentHeight = y
        let height = max(y, scroll.contentSize.height)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private var contentHeight: CGFloat = 0

    private var hasExtensions: Bool {
        if #available(macOS 15.4, *) { return !profile.extensions.installed.isEmpty }
        return false
    }

    private func refreshDownloadPlace() { DownloadPlace.configure(downloadPlace) }

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
        pipToggle.isOn = PictureInPicture.followsTabs
        suggestionsToggle.isOn = SuggestionFetcher.isOn
        borderlessToggle.isOn = BrowserRootView.isBorderless
        addressAboveToggle.isOn = BrowserRootView.addressAbovePage
        largeNamesToggle.isOn = SpaceHeaderView.isLarge
        quitToggle.isOn = AppDelegate.asksBeforeQuitting
        scriptJavaScriptToggle.isOn = Scripting.allowsJavaScript
        newTabPlace.selectedIndex = TabManager.NewTabPlace.allCases.firstIndex(of: TabManager.newTabPlace) ?? 0
        pinOfferToggle.isOn = BrowserWindowController.offersToPinWanderedPage
        nestToggle.isOn = TabManager.nestsOpenedLinks
        swipeToggle.isOn = SwipeNavigator.isOn
        miniToggle.isOn = MiniWindowController.opensExternalLinks
        miniKeys.keys = Shortcuts.allItems.first { $0.action == #selector(AppDelegate.newMiniWindow(_:)) }.map(Shortcuts.caps) ?? []
        energyToggle.isOn = EnergyWatch.sleepsBusyTabs
        motionToggle.isOn = Tokens.Motion.reducesMotionHere
        refreshDownloadPlace()
        archiveAfter.selectedIndex = TabArchive.After.allCases.firstIndex(of: TabArchive.after) ?? 0
        favoritesPerRow.selectedIndex = FavoritesView.perRowChoices.firstIndex(of: FavoritesView.perRow) ?? 0
        darkPages.selectedIndex = DarkPages.Mode.allCases.firstIndex(of: DarkPages.mode) ?? 0
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
        DefaultBrowser.make()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(); self?.layoutDocument() }
    }

    /// On the profile of the space the window is on, as one made from the sidebar is.
    private func addSpace() {
        let profile = browser?.tabManager.profile.id ?? Profile.defaultID
        BrowserWindowController.changeLibrary(String(localized: "New Space", comment: "What Edit › Undo undoes after a space is added.")) { Library.shared.addSpace(profile: profile) }
    }

    // MARK: Privacy

    /// History, website data, and every per-site decision you've made, in one place. Each button says what it
    /// did, right where you clicked.
    private func reloadPrivacy() {
        privacyGroup.removeAllRows()
        sitesGroup.removeAllRows()
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
                                 detail: String(localized: "The pages you’ve visited, used for suggestions in the command bar.", comment: "Explanation under “History” in Settings › Privacy."),
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
            self?.confirm(title: String(localized: "Clear cookies for every site?", comment: "Title of the sheet that clears cookies."),
                          message: Words.sentences(String(localized: "You’ll be signed out of every site. Your passwords, pinned tabs and history stay.", comment: "Message of the sheet that clears cookies."), only),
                          action: String(localized: "Clear Cookies", comment: "Button of the sheet that clears cookies.")) {
                Task { @MainActor in
                    await WebsiteData.clear(.cookies, in: store)
                    cookies?.flash(Self.cleared)
                    self?.reloadSiteData()
                }
            }
        }
        let data = NSStackView(views: [cache, cookies])
        data.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: String(localized: "Website data", comment: "A setting in Settings › Privacy."),
                                 detail: String(localized: "The cache makes pages load faster. Cookies keep you signed in.", comment: "Explanation under “Website data” in Settings › Privacy."),
                                 control: data))

        // The choices made one site at a time, which otherwise have nowhere to be seen.
        let nothingChosen = ContentBlocker.allowedSites.isEmpty && ExtensionStore.extensionsOffSites.isEmpty && SitePermissions.sites.isEmpty
            && ZoomLevels.count == 0 && DarkPages.sitesOn.isEmpty && DarkPages.sitesOff.isEmpty && KeepAwake.sites.isEmpty
        let reset = PillButton(title: String(localized: "Reset All…", comment: "Button beside Sites in Settings › Privacy: forgets the choices made for single sites."))
        sitesReset = nothingChosen ? nil : reset
        reset.onClick = { [weak self] _ in
            self?.confirm(title: String(localized: "Reset choices made for single sites?", comment: "Title of the sheet that forgets the choices made for single sites."),
                          message: String(localized: "Ads are blocked again everywhere, extensions run on every site, sites ask again for your camera, microphone, location and notifications, zoom goes back to 100%, dark pages follow your setting again, and every site’s tabs can sleep in the background.",
                                          comment: "Message of the sheet that forgets the choices made for single sites."),
                          action: String(localized: "Reset All", comment: "Button of the sheet that forgets the choices made for single sites.")) {
                ContentBlocker.allowedSites = []
                ExtensionStore.extensionsOffSites = []
                SitePermissions.forgetAll()
                ZoomLevels.resetAll()
                DarkPages.forgetAll()
                KeepAwake.sites = []
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
        }
        if nothingChosen {
            sitesGroup.add(FormRow(title: String(localized: "None yet", comment: "A setting in Settings › Privacy."),
                                   detail: String(localized: "Choices you make for one site, like allowing ads, a camera or notifications, show up here.", comment: "Explanation under “None yet” in Settings › Privacy."),
                                   control: NSView()))
        }

        // Then each site, with what was chosen for it, and a way to forget just that one.
        // Permissions are kept per origin and named by its label: an https site on its own port by its host, so it
        // shares a row with the host's other choices, and anything else in full (http://localhost:3000).
        let origins = Dictionary(SitePermissions.sites.map { (SiteOrigin.label($0), $0) }, uniquingKeysWith: { a, _ in a })
        let sites = Set(origins.keys).union(ContentBlocker.allowedSites).union(ExtensionStore.extensionsOffSites).union(ZoomLevels.all.keys)
            .union(DarkPages.sitesOn).union(DarkPages.sitesOff).union(KeepAwake.sites)
        var listed = 0, more = 0
        for site in sites.sorted() {
            var said: [String] = []
            let origin = origins[site]
            let choices = origin.map { SitePermissions.choices(origin: $0) } ?? [:]
            for kind in ["camera", "microphone", "cameraAndMicrophone", "location", "notifications", "popups"] {
                // A frame from elsewhere answered on the site's page: shown on the site's row when it has none of its own.
                let allowed = choices[kind] ?? choices.first { $0.key.hasPrefix("embed:") && $0.key.hasSuffix("|" + kind) }?.value
                if let allowed, let choice = Self.siteChoice(kind, allowed: allowed) { said.append(choice) }
            }
            for (kind, allowed) in choices.sorted(by: { $0.key < $1.key }) where allowed && kind.hasPrefix("app:") {
                let app = ExternalLinks.appName(forScheme: String(kind.dropFirst(4)))
                said.append(String(localized: "opens \(app)", comment: "A choice made for a site in Settings › Privacy: its links of this kind open in an app, by name."))
            }
            if ContentBlocker.allowedSites.contains(site) {
                said.append(String(localized: "ads allowed", comment: "A choice made for a site in Settings › Privacy, in a list of them."))
            }
            if ExtensionStore.extensionsOffSites.contains(site) {
                said.append(String(localized: "extensions off", comment: "A choice made for a site in Settings › Privacy, in a list of them."))
            }
            if let zoom = ZoomLevels.all[site] {
                let percent = Int((zoom * 100).rounded())
                said.append(String(localized: "zoom \(percent)%", comment: "A choice made for a site in Settings › Privacy, in a list of them: its zoom, like “zoom 125%”."))
            }
            if DarkPages.sitesOn.contains(site) {
                said.append(String(localized: "dark page on", comment: "A choice made for a site in Settings › Privacy, in a list of them: its pages are drawn dark."))
            } else if DarkPages.sitesOff.contains(site) {
                said.append(String(localized: "dark page off", comment: "A choice made for a site in Settings › Privacy, in a list of them: its pages are never drawn dark."))
            }
            if KeepAwake.sites.contains(site) {
                said.append(String(localized: "tabs kept awake", comment: "A choice made for a site in Settings › Privacy, in a list of them: its tabs never go to sleep in the background."))
            }
            guard !said.isEmpty else { continue }
            // The first 30 by name, as with site data, then the rest on request.
            guard sitesShowAll || listed < 30 else { more += 1; continue }
            listed += 1
            let forget = PillButton(title: String(localized: "Forget", comment: "Button on a site's row in Settings › Privacy › Sites: forgets the choices made for it."))
            forget.onClick = { [weak self] _ in
                if let origin {
                    SitePermissions.forgetEverything(origin: origin)
                    WebNotifications.shared.removeAll(origin: origin)
                }
                ContentBlocker.allowedSites.remove(site)
                var off = ExtensionStore.extensionsOffSites
                off.remove(site)
                ExtensionStore.extensionsOffSites = off
                ZoomLevels.forget(host: site)
                DarkPages.setChoice(nil, for: URL(string: "https://\(site)"))
                var awake = KeepAwake.sites
                awake.remove(site)
                KeepAwake.sites = awake
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
            let line = said.joined(separator: String(localized: "site-choices.separator", defaultValue: ", ",
                                                     comment: "Between the choices made for a site in Settings › Privacy › Sites, like “camera allowed, zoom 125%”."))
            let siteURL = URL(string: origin ?? "https://\(site)")
            let favicon = siteURL.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            let sentence = line.prefix(1).localizedUppercase + line.dropFirst()
            sitesGroup.add(FormRow(title: site,
                                   detail: String(localized: "site-choices.sentence", defaultValue: "\(sentence).",
                                                  comment: "Under a site in Settings › Privacy › Sites: the choices made for it, as one sentence."),
                                   icon: favicon, control: forget))
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
        // What websites keep is read where it's listed: with more than one profile that's Website Data, and
        // Privacy has no use for it.
        if !(pane == .privacy && hasManyProfiles) { reloadSiteData() }
    }

    /// What each site keeps on this Mac, read from WebKit (it takes a moment, so the list fills in when it's ready),
    /// with Remove for that site alone. The first 30 by name, then the rest on request.
    private func reloadSiteData() {
        siteDataTask?.cancel()
        let store = profile.store
        siteDataTask = Task { @MainActor [weak self] in
            let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            guard let self, !Task.isCancelled else { return }
            self.siteDataGroup.removeAllRows()
            let sorted = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if sorted.isEmpty {
                self.siteDataGroup.add(FormRow(title: String(localized: "None yet", comment: "A setting in Settings › Privacy."),
                                               detail: String(localized: "Sites you visit can keep cookies and files here, to keep you signed in and load faster.", comment: "Explanation under “None yet” in Settings › Privacy."),
                                               control: NSView()))
            }
            let shown = self.siteDataShowsAll ? sorted[...] : sorted.prefix(30)
            for record in shown {
                let site = record.displayName
                let remove = PillButton(title: String(localized: "Remove…", comment: "Button on a site's row in Settings › Privacy › Site Data."))
                let signsOut = record.dataTypes.contains(WKWebsiteDataTypeCookies)
                remove.onClick = { [weak self] _ in
                    self?.confirm(title: String(localized: "Remove data for \(site)?", comment: "Title of the sheet that removes one site's data; the site, like apple.com."),
                                  message: signsOut
                                      ? String(localized: "You’ll be signed out of \(site), and its pages load fresh next time.", comment: "Message of the sheet that removes one site's data.")
                                      : String(localized: "Its pages load fresh next time.", comment: "Message of the sheet that removes one site's data."),
                                  action: String(localized: "Remove", comment: "Button of the sheet that removes one site's data.")) {
                        Task { @MainActor in
                            await store.removeData(ofTypes: record.dataTypes, for: [record])
                            self?.reloadSiteData()
                        }
                    }
                }
                let icon = URL(string: "https://\(site)").flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
                self.siteDataGroup.add(FormRow(title: site, detail: Self.describe(record.dataTypes), icon: icon, control: remove))
            }
            if shown.count < sorted.count {
                let more = PillButton(title: String(localized: "Show All", comment: "Button under the first 30 sites in Settings › Privacy."))
                more.onClick = { [weak self] _ in
                    self?.siteDataShowsAll = true
                    self?.reloadSiteData()
                }
                let rest = sorted.count - shown.count
                self.siteDataGroup.add(FormRow(title: String(localized: "\(rest) more sites", comment: "Under the first 30 sites in Settings › Privacy, beside Show All."), control: more))
            }
            self.layoutDocument()
        }
    }

    /// What a site keeps, in a few plain words: "Cookies, saved data and cache."
    private static func describe(_ types: Set<String>) -> String {
        let cache: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
        let cookies = types.contains(WKWebsiteDataTypeCookies)
        let saved = !types.subtracting(cache).subtracting([WKWebsiteDataTypeCookies]).isEmpty
        let cached = !types.isDisjoint(with: cache)
        // Each combination a whole sentence, so a language can say it its own way.
        switch (cookies, saved, cached) {
        case (true, true, true): return String(localized: "Cookies, saved data and cache.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (true, true, false): return String(localized: "Cookies and saved data.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (true, false, true): return String(localized: "Cookies and cache.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (true, false, false): return String(localized: "Cookies.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (false, true, true): return String(localized: "Saved data and cache.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (false, true, false): return String(localized: "Saved data.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (false, false, true): return String(localized: "Cache.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        case (false, false, false): return String(localized: "Data.", comment: "Under a site in Settings › Privacy › Site Data: what it keeps on this Mac.")
        }
    }

    private func confirm(title: String, message: String, action: String, destructive: Bool = true, then run: @escaping () -> Void) {
        ConfirmSheet.show(in: self, title: title, message: message, confirmTitle: action, destructive: destructive) { confirmed in
            if confirmed { run() }
        }
    }


    private func getExtensions() {
        guard let controller = browser else { return }
        controller.tabManager.newTab(url: ExtensionStore.webStoreURL)
        controller.window?.makeKeyAndOrderFront(nil)
    }

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
        let names = ["⌘": "command cmd", "⇧": "shift", "⌥": "option alt", "⌃": "control ctrl"]
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
            fieldLabel.frame = NSRect(x: Tokens.Space.x2, y: (h - fieldLabel.lineHeight) / 2, width: w - Tokens.Space.x4, height: fieldLabel.lineHeight)
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
            fieldLabel.frame = NSRect(x: 0, y: (h - fieldLabel.lineHeight) / 2, width: w, height: fieldLabel.lineHeight)
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
            title.frame = NSRect(x: pad - Label.inset, y: (bounds.height - title.lineHeight) / 2, width: width, height: title.lineHeight)
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
        if flags.contains(.control) { held += "⌃" }
        if flags.contains(.option) { held += "⌥" }
        if flags.contains(.shift) { held += "⇧" }
        if flags.contains(.command) { held += "⌘" }
        fieldLabel.stringValue = held.isEmpty ? String(localized: "Type a shortcut", comment: "In Settings › Shortcuts while recording a new shortcut.") : held + " …"
        fieldLabel.textColor = held.isEmpty ? Tokens.Color.textSecondary : Tokens.Color.textPrimary
    }

    private func finish(taken: NSMenuItem?) {
        stopRecording()
        let name = taken.map { $0.title.hasSuffix("…") ? String($0.title.dropLast()) : $0.title }
        onChange?()
        if let name { ShortcutRow.lastTaken = (item, name) }
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

    static func make() {
        let app = Bundle.main.bundleURL
        // macOS asks once, for http, and that answer makes Zigzag the web browser. Asking for https at the same time
        // put a second, identical question on screen; it's only asked after, and only if the first didn't cover it.
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                guard let https = URL(string: "https://example.com"),
                      NSWorkspace.shared.urlForApplication(toOpen: https)?.standardizedFileURL != app.standardizedFileURL else { return }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
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
