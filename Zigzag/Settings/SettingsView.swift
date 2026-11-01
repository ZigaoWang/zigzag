import AppKit
import WebKit

// MARK: - Groups of rows

/// A group of rows on the page: one quiet card (`Tokens.Color.surfaceGroup`, a hairline edge, `Tokens.Radius.group`)
/// with hairlines between its rows, starting where their text does.
final class FormGroup: NSView {
    private(set) var rows: [NSView] = []
    private var lines: [NSView] = []
    private let background = ColorView(color: Tokens.Color.surfaceGroup)

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = Tokens.Radius.group
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = Tokens.Metric.hairline
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
        for row in rows { row.isHidden = !all && !has((row as? SettingsSearchable)?.searchText ?? "") }
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
                lines[i].frame = NSRect(x: x, y: y, width: bounds.width - x, height: Tokens.Metric.hairline)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A row "Find a setting" can find, by the words it shows.
protocol SettingsSearchable { var searchText: String { get } }

/// A row of settings: its name (and a line saying more, which wraps) at the left, its control at the right. Rows grow
/// to fit what they say, so nothing is cut off. A picture goes before the name only where the row is a thing with a
/// face of its own: an extension, a site.
final class FormRow: NSView, SettingsSearchable {
    var searchText: String { [title.stringValue, detail.stringValue, keywords].joined(separator: " ") }
    /// More words "Find a setting" knows the row by, like its button's.
    var keywords = ""
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
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
        self.detail.font = Tokens.Font.small()
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

    private let pad = Tokens.Page.groupPad
    /// A picture's side: an extension's icon, a site's favicon.
    private static let iconSide = Tokens.Space.x6

    private var controlSize: NSSize {
        let size = control.fittingSize
        return size.width > 0 ? size : control.intrinsicContentSize
    }

    /// Where the row's text starts.
    var textInset: CGFloat { icon.isHidden ? pad : pad + Self.iconSide + Tokens.Space.x3 }

    private func textWidth(for width: CGFloat) -> CGFloat {
        let control = controlSize.width > 0 ? controlSize.width + Tokens.Space.x4 : 0
        return max(Tokens.Space.x16 * 2, width - pad - control - textInset)
    }

    private func detailHeight(for width: CGFloat) -> CGFloat {
        detail.isHidden ? 0 : ceil(detail.sizeThatFits(NSSize(width: textWidth(for: width), height: 400)).height)
    }

    /// The height this row needs at `width`.
    func height(for width: CGFloat) -> CGFloat {
        guard !detail.isHidden else { return Tokens.Page.groupRowHeight }
        return max(Tokens.Page.groupRowHeight, Tokens.Space.x3 * 2 + title.lineHeight + 2 + detailHeight(for: width))
    }

    override func layout() {
        super.layout()
        let size = controlSize
        control.frame = NSRect(x: bounds.width - pad - size.width, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
        if !icon.isHidden {
            let side = Self.iconSide
            icon.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        }
        let x = textInset - Label.inset
        let width = textWidth(for: bounds.width) + Label.inset * 2
        let detailHeight = detailHeight(for: bounds.width)
        let block = title.lineHeight + (detail.isHidden ? 0 : 2 + detailHeight)
        let top = round((bounds.height - block) / 2)
        title.frame = NSRect(x: x, y: top, width: width, height: title.lineHeight)
        detail.frame = NSRect(x: x, y: title.frame.maxY + 2, width: width, height: detailHeight)
    }
}

/// The version of Zigzag you have, at the end of General: a quiet row like the rest, so the page's one brand moment
/// is the wordmark by its title.
enum SettingsVersionRow {
    static func make() -> FormRow {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let update = PillButton(title: "Check for Updates…")
        update.onClick = { _ in Updater.shared.checkForUpdates() }
        let row = FormRow(title: "Zigzag", detail: "Version \(version)", control: update)
        row.keywords = "check for updates"
        return row
    }

    /// Betas first, for those who want to try new versions on their own tabs and data.
    static func betas() -> FormRow {
        let toggle = Toggle(isOn: Updater.getsBetas)
        toggle.onChange = { on in Updater.getsBetas = on }
        let row = FormRow(title: "Beta updates", detail: "Try new versions first, on your own tabs and data.", control: toggle)
        row.keywords = "beta channel prerelease"
        return row
    }

    /// The profile as it was before the last update, put back. Only there when a backup is.
    static func restore() -> FormRow? {
        guard let date = ProfileBackup.latestDate else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        var detail = "Saved \(formatter.string(from: date))"
        if let name = ProfileBackup.latest?.lastPathComponent, let space = name.firstIndex(of: " ") {
            detail += ", before updating from \(name[name.index(after: space)...])"
        }
        let button = PillButton(title: "Restore…")
        button.onClick = { [weak button] _ in
            guard let host = button?.window?.contentView else { return }
            ConfirmSheet.show(in: host, title: "Restore from before the last update?",
                              message: "Your spaces, tabs, favorites and history go back to how they were before the last update, and Zigzag restarts. Logins and passwords aren’t affected.",
                              confirmTitle: "Restore and Restart") { confirmed in
                if confirmed { ProfileBackup.restoreLatestAndRelaunch() }
            }
        }
        let row = FormRow(title: "Restore from before the last update", detail: detail, control: button)
        row.keywords = "backup undo update rollback"
        return row
    }
}

/// A symbol in a settings row, where a picture is missing (a site with no favicon): the app's icon color.
enum SettingsIcon {
    static func symbol(_ name: String) -> NSImage {
        let image = Tokens.Symbol.image(name, size: Tokens.TypeSize.row)
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
    private let detail = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let editButton = PillButton(title: "Edit")
    private let deleteButton = IconButton(symbol: "trash", size: Tokens.Space.x7Height, symbolSize: Tokens.TypeSize.small, toolTip: "Delete Space")
    /// True while the row is being dragged; it draws as lifted.
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    /// True while any space is carried: rows sliding under the pointer don't count as hovered.
    static var isReordering = false

    init(space: SpaceInfo) {
        spaceID = space.id
        name = Label(space.name, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Page.groupRowHeight + Tokens.Space.x2))
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        tile.image = Self.tile(for: space)
        detail.stringValue = Self.summary(of: space)
        deleteButton.isHidden = true
        deleteButton.isEnabled = Library.shared.spaces.count > 1
        [tile, name, detail, deleteButton, editButton].forEach { addSubview($0) }
        // The row and its Edit button both open the same editor the sidebar uses.
        onClick = { [weak self] _ in self?.openEditor() }
        editButton.onClick = { [weak self] _ in self?.openEditor() }
        deleteButton.onClick = { [weak self] _ in
            guard let self, let host = self.host else { return }
            SpaceSettingsRow.confirmDelete(self.spaceID, in: host)
        }
        deleteButton.keyboardFocusChanged = { [weak self] _ in self?.stateDidChange(animated: false) }
        setAccessibilityRole(.row)
        setAccessibilityLabel(space.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad = Tokens.Page.groupPad
        let d = Tokens.Space.x6
        tile.frame = NSRect(x: pad, y: (bounds.height - d) / 2, width: d, height: d)
        let ew = editButton.fittingWidth, eh = Tokens.Page.controlHeight
        editButton.frame = NSRect(x: bounds.width - pad - ew, y: (bounds.height - eh) / 2, width: ew, height: eh)
        let b = deleteButton.frame.width
        deleteButton.frame.origin = NSPoint(x: editButton.frame.minX - Tokens.Space.x1 - b, y: (bounds.height - b) / 2)
        let x = tile.frame.maxX + Tokens.Space.x3 - Label.inset
        // The name has the room up to Edit while Delete isn't showing: a narrow page cuts it short only on hover.
        let end = deleteButton.alphaValue > 0 ? deleteButton.frame.minX : editButton.frame.minX
        let width = max(0, end - x - Tokens.Space.x2)
        let top = round((bounds.height - name.lineHeight - 2 - detail.lineHeight) / 2)
        name.frame = NSRect(x: x, y: top, width: width, height: name.lineHeight)
        detail.frame = NSRect(x: x, y: name.frame.maxY + 2, width: width, height: detail.lineHeight)
        // The lifted row's shadow has a set shape: without one, it's worked out from the row's contents on every frame
        // of a drag, which is what made reordering stutter.
        let radius = layer?.cornerRadius ?? 0
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Where the row's text starts, for the divider under it.
    var textInset: CGFloat { Tokens.Page.groupPad + Tokens.Space.x6 + Tokens.Space.x3 }

    private static func tile(for space: SpaceInfo) -> NSImage {
        let side: CGFloat = 24
        let letter = space.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? ""
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let radius = Tokens.Radius.control
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let base = space.swatch.usingColorSpace(.sRGB) ?? space.swatch
            NSGradient(starting: base.highlight(withLevel: 0.12) ?? base, ending: base)?.draw(in: shape, angle: -90)
            // A fine edge, so a white or pale space still shows its tile.
            NSColor.black.withAlphaComponent(0.1).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius - 0.25, yRadius: radius - 0.25)
            edge.lineWidth = 0.5
            edge.stroke()
            // White on a color, dark on a pale one.
            let light = 0.2126 * base.redComponent + 0.7152 * base.greenComponent + 0.0722 * base.blueComponent > 0.7
            let ink = light ? NSColor(white: 0.2, alpha: 1) : NSColor.white
            // Its icon if it has one, white on the color like the letter; an emoji in its own colors.
            if let icon = space.icon {
                let image = IconChoice.image(icon, size: 12)
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
            let text = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            return true
        }
    }

    /// What's in it, said plainly.
    private static func summary(of space: SpaceInfo) -> String {
        let pinned = space.bookmarks.count
        let open = BrowserWindowController.undoTarget?.tabManager.tabs(in: space.id).count ?? 0
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        switch (pinned, open) {
        case (0, 0): return "Empty"
        case (_, 0): return count(pinned, "pinned tab", "pinned tabs")
        case (0, _): return count(open, "open tab", "open tabs")
        default: return count(pinned, "pinned tab", "pinned tabs") + " and " + count(open, "open tab", "open tabs")
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(SidebarMenus.Item("Edit…") { [weak self] in self?.openEditor() })
        if Library.shared.spaces.count > 1 {
            menu.addItem(SidebarMenus.Item("Delete Space…") { [weak self] in
                guard let self, let host = self.host else { return }
                SpaceSettingsRow.confirmDelete(self.spaceID, in: host)
            })
        }
        return menu
    }

    override func resetCursorRects() { if isLifted { addCursorRect(bounds, cursor: .closedHand) } }

    override func stateDidChange(animated: Bool) {
        // Delete shows on hover, or once Tab brings keyboard focus to it. With Full Keyboard Access on it stays in
        // the Tab order, see-through until then.
        let showsDelete = (isHovered || deleteButton.hasKeyboardFocus) && !isLifted && !Self.isReordering
        deleteButton.isHidden = !showsDelete && !(NSApp.isFullKeyboardAccessEnabled && !isLifted)
        deleteButton.alphaValue = showsDelete ? 1 : 0
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
        ConfirmSheet.show(in: host, title: "Delete “\(space.name)”?",
                          message: undoable ? "Its tabs and pinned tabs close. You can bring them back with Undo in a browser window."
                                            : "Its tabs and pinned tabs close. This can’t be undone.",
                          confirmTitle: "Delete Space", destructive: true) { confirmed in
            guard confirmed else { return }
            if let controller = BrowserWindowController.undoTarget { controller.removeSpaceWithUndo(id) } else { Library.shared.removeSpace(id) }
        }
    }
}

// MARK: - The page

/// The parts of Settings, each a pane of its own, picked from the column of sections at the left.
enum SettingsPane: Int, CaseIterable {
    case general, spaces, passwords, privacy, translation, extensions, shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .spaces: "Spaces"
        case .passwords: "Passwords"
        case .privacy: "Privacy"
        case .translation: "Translation"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .spaces: "square.stack"
        case .passwords: "key"
        case .privacy: "hand.raised"
        case .translation: "translate"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "command"
        }
    }

    /// Its name in the page's address: zigzag://settings/privacy.
    var path: String { "\(self)" }
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
    private let column = FlippedView()
    /// The wordmark and "Settings" at the top of the column, where History has its own.
    private let columnTitle = PageTitleView("Settings")
    /// Over the chosen section: its name, and the search at the right, as History's header has them.
    private let header = PageHeader()
    private let paneTitle = PageTitleView("")
    private let columnEdge = ColorView(color: Tokens.Color.separator)
    private let scroll = NSScrollView()
    private let documentView = FlippedView()
    private(set) var pane = SettingsPane.general
    /// Finds a setting in any section, at the top right of the page.
    private let settingSearch = FilledField.search("Find a setting")
    /// You picked another section: the tab's address follows, so the tab comes back to it.
    var onPaneChange: ((SettingsPane) -> Void)?

    private let versionGroup = FormGroup()
    private let generalGroup = FormGroup()
    private let tabsGroup = FormGroup()
    private let downloadsGroup = FormGroup()
    private let blockingGroup = FormGroup()
    private let importGroup = FormGroup()
    private let spacesGroup = FormGroup()
    private let windowGroup = FormGroup()
    private let passwordsGroup = FormGroup()
    private let passwordsWindowGroup = FormGroup()
    private let privacyGroup = FormGroup()
    private let sitesGroup = FormGroup()
    /// Reset All beside the Sites heading, there only when something was chosen for a site.
    private var sitesReset: PillButton?
    private var alwaysReset: PillButton?
    private let translationGroup = FormGroup()
    private let alwaysGroup = FormGroup()
    private let extensionsGroup = FormGroup()
    private let developerGroup = FormGroup()
    private var shortcutGroups: [(String, FormGroup)] = []

    private let engine = MenuButton()
    private let archiveAfter = MenuButton()
    private let defaultButton = PillButton(title: "Make Default")
    private let defaultStatus = StatusLabel("Zigzag is your default browser")
    private let blockingToggle = Toggle()
    private let pipToggle = Toggle()
    private let suggestionsToggle = Toggle()
    private let borderlessToggle = Toggle()
    private let quitToggle = Toggle()
    /// Where downloads go: Downloads, another folder, or ask each time.
    private let downloadPlace = MenuButton()
    private var downloadPlaceToken: SignalToken?
    private let saveToggle = Toggle()
    private let fillToggle = Toggle()
    private let cardToggle = Toggle()
    private let translateOffer = Toggle()
    private let translateInto = MenuButton()
    private var languages: [(id: String, name: String)] = []
    private let addSpaceButton = PillButton(title: "New Space")
    private let getExtensionsButton = PillButton(title: "Get Extensions")
    private let loadUnpackedButton = PillButton(title: "Load Unpacked")
    private var spaceRows: [SpaceSettingsRow] = []
    private var token: SignalToken?
    private var extensionsToken: SignalToken?

    private var keyToken: NSObjectProtocol?

    init(pane: SettingsPane = .general) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        // Its own layer, so it paints the page's surface rather than showing whatever is under it.
        wantsLayer = true
        build()
        token = Library.shared.changed.observe { [weak self] in
            guard let self, self.window != nil else { return }
            self.reloadSpaces()
        }
        if #available(macOS 15.4, *) {
            extensionsToken = ExtensionHost.shared.changed.observe { [weak self] in
                guard let self, self.window != nil else { return }
                self.reloadExtensions()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Covering the page, it takes the keyboard from the web view underneath, so typing goes nowhere unexpected.
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = cgColor(Tokens.Color.surface) }

    // MARK: Building

    private func build() {
        // The column of sections, under the page's title.
        column.addSubview(columnTitle)
        items = SettingsPane.allCases.map { pane in
            let item = SectionItem(pane)
            item.onClick = { [weak self] _ in self?.pick(pane) }
            column.addSubview(item)
            return item
        }
        addSubview(column)
        addSubview(columnEdge)

        // General
        engine.options = SearchEngine.allCases.map { MenuButton.Option(title: $0.name, image: FaviconStore.shared.cachedIcon(for: $0.homeURL).map(Self.menuIcon)) }
        SearchEngine.allCases.forEach { if FaviconStore.shared.cachedIcon(for: $0.homeURL) == nil { FaviconStore.shared.prefetch(for: $0.homeURL) } }
        engine.onSelect = { index in Library.shared.searchEngine = SearchEngine.allCases[index] }
        defaultButton.onClick = { [weak self] _ in self?.makeDefault() }
        let defaultControl = NSStackView(views: [defaultStatus, defaultButton])
        defaultControl.spacing = Tokens.Space.x2
        versionGroup.add(SettingsVersionRow.make())
        versionGroup.add(SettingsVersionRow.betas())
        if let restore = SettingsVersionRow.restore() { versionGroup.add(restore) }
        generalGroup.add(FormRow(title: "Search engine", detail: "Used when what you type isn’t an address.", control: engine))
        suggestionsToggle.onChange = { on in SuggestionFetcher.isOn = on }
        generalGroup.add(FormRow(title: "Search suggestions", detail: "What you type in the address bar is sent to your search engine for suggestions.", control: suggestionsToggle))
        // Searching a site with Tab is taught where it's used (the address bar shows the key), not listed here.
        generalGroup.add(FormRow(title: "Default browser", detail: "Links from other apps open here.", control: defaultControl))
        blockingToggle.onChange = { on in ContentBlocker.isEnabled = on }
        pipToggle.onChange = { on in PictureInPicture.followsTabs = on }
        downloadPlace.onSelect = { index in DownloadPlace.pick(index) }
        downloadPlaceToken = DownloadPlace.changed.observe { [weak self] in self?.refreshDownloadPlace() }
        archiveAfter.options = TabArchive.After.allCases.map { MenuButton.Option(title: $0.title) }
        archiveAfter.onSelect = { index in TabArchive.after = TabArchive.After.allCases[index] }
        tabsGroup.add(FormRow(title: "Archive tabs you haven’t used", detail: "They leave the sidebar. Type a few letters in the address bar to bring one back.", control: archiveAfter))
        tabsGroup.add(FormRow(title: "Keep videos playing when you switch tabs", detail: "A playing video floats in its own window until you come back.", control: pipToggle))
        downloadsGroup.add(FormRow(title: "Save downloads to", detail: "Or have Zigzag ask where, each time.", control: downloadPlace))
        // EasyList's licence asks for credit; this is where people look for what does the blocking.
        blockingGroup.add(FormRow(title: "Block ads and trackers", detail: "Uses EasyList and EasyPrivacy, by the EasyList authors.", control: blockingToggle))
        quitToggle.onChange = { on in AppDelegate.asksBeforeQuitting = on }
        let importButton = PillButton(title: "Import")
        importButton.onClick = { _ in ImportWindowController.show() }
        importGroup.add(FormRow(title: "Import from another browser", detail: "Passwords, bookmarks and history. The other browser isn’t changed.", control: importButton))

        // Spaces
        addSpaceButton.onClick = { [weak self] _ in self?.addSpace() }
        borderlessToggle.onChange = { on in BrowserRootView.isBorderless = on }
        windowGroup.add(FormRow(title: "Borderless page", detail: "The page meets the window’s edges instead of floating inside it.", control: borderlessToggle))
        windowGroup.add(FormRow(title: "Ask before quitting", detail: "So ⌘Q never closes everything by accident.", control: quitToggle))

        // Passwords
        saveToggle.onChange = { [weak self] on in
            PasswordCapture.offersToSave = on
            self?.reloadPasswords()
            self?.layoutDocument()
        }
        fillToggle.onChange = { [weak self] on in
            Autofill.isOn = on
            if !on { Autofill.shared.hide() }
            self?.reloadPasswords()
            self?.layoutDocument()
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
        header.contentFrame = (span.x, span.x + span.width)
        // With no column to carry it, the wordmark heads the pane's own title.
        paneTitle.showsWordmark = arrangement != .column
        refreshTitle()
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

    /// The header's title: the chosen section, or Settings while a search goes through all of them.
    private func refreshTitle() {
        paneTitle.title = isSearching ? "Settings" : pane.title
        header.needsLayout = true
    }

    @objc private func scrolled() {
        header.showsEdge = scroll.contentView.bounds.minY > 0
    }

    private func layoutColumn(_ arrangement: Arrangement) {
        columnTitle.isHidden = arrangement != .column
        items.forEach { $0.isCompact = arrangement != .column }
        let count = CGFloat(items.count)
        // In the row they shrink to fit, rather than run off the page's edge.
        let side = arrangement == .row ? min(Tokens.Space.x10, floor((column.bounds.width - Tokens.Space.x2 * 2) / count)) : Tokens.Space.x10
        switch arrangement {
        case .column:
            // The title sits where History's does; the sections' text lines up under it, their fills reaching past.
            let gutter = Tokens.Page.gutter, inset = Tokens.Page.rowInset
            columnTitle.frame = NSRect(x: gutter, y: Tokens.Page.headerTop, width: column.bounds.width - gutter * 2, height: Tokens.Page.controlHeight)
            var y = Tokens.Page.headerHeight + Tokens.Space.x1
            for item in items {
                item.frame = NSRect(x: gutter - inset, y: y, width: column.bounds.width - (gutter - inset) * 2, height: Tokens.Page.rowHeight)
                y += Tokens.Page.rowHeight + 2
            }
        case .rail:
            var y = Tokens.Page.headerHeight + Tokens.Space.x1
            for item in items {
                item.frame = NSRect(x: (column.bounds.width - side) / 2, y: y, width: side, height: side)
                y += side + 2
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
    }
    /// Opens a pane.
    func show(_ pane: SettingsPane) {
        self.pane = pane
        settingSearch.stringValue = ""
        items.forEach { $0.isSelected = $0.pane == pane }
        refreshTitle()
        if pane == .privacy { reloadPrivacy() }
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
        if let keyToken { NotificationCenter.default.removeObserver(keyToken) }
        keyToken = nil
        guard let window else { return }
        keyToken = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        reloadSpaces()
        reloadExtensions()
        reloadPasswords()
        reloadTranslation()
        if pane == .privacy { reloadPrivacy() }
        layoutDocument()
    }

    /// Its picture, for the tab's preview and switcher.
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

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
        let installed = ExtensionHost.shared.installed.sorted {
            ($0.value.displayName ?? $0.key).localizedCaseInsensitiveCompare($1.value.displayName ?? $1.key) == .orderedAscending
        }
        if installed.isEmpty {
            let get = PillButton(title: "Get Extensions")
            get.onClick = { [weak self] _ in self?.getExtensions() }
            extensionsGroup.add(FormRow(title: "No extensions yet", detail: "Find one in the Chrome Web Store and choose Add to Zigzag.", control: get))
        }
        for (id, ext) in installed { extensionsGroup.add(extensionRow(id: id, ext: ext)) }
        let developer = Toggle(isOn: ExtensionStore.developerMode)
        developer.onChange = { [weak self] on in
            ExtensionStore.developerMode = on
            self?.reloadExtensions()
        }
        developerGroup.add(FormRow(title: "Developer mode", detail: "Load an extension from a folder to test it.", control: developer))
    }

    @available(macOS 15.4, *)
    private func extensionRow(id: String, ext: WKWebExtension) -> FormRow {
        var controls: [NSView] = []
        if ExtensionStore.needsApproval(id) {
            let review = PillButton(title: "Review Update")
            review.onClick = { [weak self] _ in
                guard let controller = self?.browser else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                controller.reviewExtensionUpdate(id)
            }
            controls.append(review)
        }
        if ExtensionStore.isUnpacked(id) {
            let reload = IconButton(symbol: "arrow.clockwise", size: Tokens.Space.x7Height, symbolSize: Tokens.TypeSize.small, toolTip: "Reload from Its Folder")
            reload.onClick = { _ in Task { await ExtensionStore.reloadUnpacked(id) } }
            controls.append(reload)
        }
        let remove = IconButton(symbol: "trash", size: Tokens.Space.x7Height, symbolSize: Tokens.TypeSize.small, toolTip: "Remove from Zigzag")
        remove.onClick = { [weak self] _ in self?.confirmRemove(id: id, name: ext.displayName ?? "this extension") }
        controls.append(remove)
        let toggle = Toggle(isOn: ExtensionStore.isEnabled(id))
        toggle.onChange = { on in ExtensionStore.setEnabled(id, on) }
        controls.append(toggle)
        let stack = NSStackView(views: controls)
        stack.spacing = Tokens.Space.x2

        // What matters about it at a glance, as one plain sentence.
        var detail: [String] = [ext.version.map { "Version \($0)" } ?? ""].filter { !$0.isEmpty }
        if ExtensionStore.isUnpacked(id) { detail.append("Unpacked") }
        if ExtensionStore.needsApproval(id) { detail.append("Update wants more access") }
        var limitsNote: String?
        if let manifest = ExtensionStore.manifest(for: id) {
            let limits = ExtensionReport(extension: ext, manifest: manifest, id: id).limits
            if !limits.isEmpty {
                detail.append(limits.count == 1 ? "1 feature won’t work here" : "\(limits.count) features won’t work here")
                let names = limits.map { $0.prefix(1).lowercased() + $0.dropFirst() }
                limitsNote = "Won’t work in Zigzag: " + ListFormatter.localizedString(byJoining: names) + "."
            }
        }
        let row = FormRow(title: ext.displayName ?? id, detail: detail.isEmpty ? "" : ListFormatter.localizedString(byJoining: detail), icon: ext.icon(for: NSSize(width: 24, height: 24)), control: stack)
        row.toolTip = limitsNote
        return row
    }

    private func loadUnpacked() {
        guard #available(macOS 15.4, *), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose the folder that contains the extension’s manifest.json."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await ExtensionStore.loadUnpacked(url) == nil, let host = self {
                    ConfirmSheet.notice(in: host, title: "Couldn’t load this extension", message: "That folder needs a manifest.json that Zigzag can read. Choose the folder that holds it.")
                }
            }
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
        passwordsWindowGroup.removeAllRows()
        saveToggle.isOn = PasswordCapture.offersToSave
        fillToggle.isOn = Autofill.isOn
        let manager = PasswordManagers.active
        let saveNote = manager != nil && !PasswordCapture.offersToSave ? "Off while \(manager!) handles passwords. Turn on to use both." : "After you sign in. Kept in your Keychain, synced with iCloud."
        let fillNote = manager != nil && !Autofill.isOn ? "Off while \(manager!) handles passwords. Turn on to use both." : "Under sign-in fields, only on the site each was saved for."
        passwordsGroup.add(FormRow(title: "Offer to save passwords", detail: saveNote, control: saveToggle))
        passwordsGroup.add(FormRow(title: "Fill saved passwords", detail: fillNote, control: fillToggle))
        cardToggle.isOn = ContactCard.isOn
        cardToggle.onChange = { on in ContactCard.isOn = on }
        passwordsGroup.add(FormRow(title: "Fill forms from My Card", detail: "Your name, email, phone and address, from your own card in Contacts.", control: cardToggle))
        let open = PillButton(title: "Open Passwords")
        open.onClick = { _ in PasswordsWindowController.show() }
        // Importing is in General and in the Passwords window itself; once here would be a third time.
        passwordsWindowGroup.add(FormRow(title: "Saved passwords", detail: "See, edit, import and export them.", control: open))
    }

    private func reloadTranslation() {
        translationGroup.removeAllRows()
        alwaysGroup.removeAllRows()
        let system = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        translateInto.options = [MenuButton.Option(title: "\(PageTranslator.name(of: system)) (System)", image: nil)] + languages.map { MenuButton.Option(title: $0.name, image: nil) }
        translateInto.selectedIndex = PageTranslator.chosenLanguage.flatMap { chosen in languages.firstIndex { $0.id == chosen }.map { $0 + 1 } } ?? 0
        translateOffer.isOn = PageTranslator.offers
        translationGroup.add(FormRow(title: "Translate pages into", detail: "The language you read.", control: translateInto))
        translationGroup.add(FormRow(title: "Offer to translate", detail: "When a page is in another language, Zigzag asks once per site.", control: translateOffer))
        let always = PageTranslator.alwaysLanguages.map { PageTranslator.name(of: Locale.Language(identifier: $0)) }.sorted()
        // Laid out like Sites in Privacy: a heading, Reset beside it only when there's something to reset.
        let reset = PillButton(title: "Reset")
        reset.onClick = { [weak self] _ in
            PageTranslator.alwaysLanguages = []
            self?.reloadTranslation()
            self?.layoutDocument()
        }
        alwaysReset = always.isEmpty ? nil : reset
        alwaysGroup.add(always.isEmpty
            ? FormRow(title: "None yet", detail: "Turn on Always Translate from a page’s site controls.", control: NSView())
            : FormRow(title: ListFormatter.localizedString(byJoining: always), detail: "Translated as soon as they open.", control: NSView()))
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
                          !item.isHidden || item.title.hasPrefix("Close Tabs") else { continue }
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
            if top.title == "View" {
                for (title, keys) in [("Go to Tab 1 to 8 or the Last Tab", ["⌘", "1–9"]), ("Go to Space 1 to 9", ["⌃", "1–9"])] {
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
    #endif

    /// ⌘F on Settings finds a setting, rather than text in the empty page under it.
    @objc func showFindBar(_ sender: Any?) {
        window?.makeFirstResponder(settingSearch.field)
    }

    /// Each section's groups and their headings, as a search goes through them.
    private func groups(of pane: SettingsPane) -> [(title: String?, group: FormGroup)] {
        switch pane {
        case .general: [(nil, generalGroup), ("Tabs", tabsGroup), ("Window", windowGroup), ("Downloads", downloadsGroup), (nil, importGroup), (nil, versionGroup)]
        case .spaces: [("Your spaces", spacesGroup)]
        case .passwords: [(nil, passwordsGroup), (nil, passwordsWindowGroup)]
        case .privacy: [(nil, blockingGroup), ("Browsing data", privacyGroup), ("Sites", sitesGroup)]
        case .translation: [(nil, translationGroup), ("Always translate", alwaysGroup)]
        case .extensions: [("Installed", extensionsGroup), (nil, developerGroup)]
        case .shortcuts: shortcutGroups.map { ($0.0, $0.1) }
        }
    }

    // MARK: Layout

    private func layoutDocument() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let width = scroll.contentSize.width
        laidOutWidth = scroll.frame.width
        // The pane lines up with the header over it: the shared margins and maximum width, centered past it.
        let span = contentSpan(in: width)
        let pad = span.x, contentWidth = span.width
        var y: CGFloat = Tokens.Space.x3

        // A section: a quiet label low in its slot, standing in for a divider, then the group. A button that acts on the
        // whole group (New Space, Reset All) sits at the label's right, at the group's edge.
        func section(_ title: String?, _ group: FormGroup, accessory: NSView? = nil) {
            if title != nil || accessory != nil {
                let size = accessory.map { $0.fittingSize } ?? .zero
                let slot = max(Tokens.Metric.sectionLabelHeight, size.height + Tokens.Space.x2)
                let label = Label.section(title ?? "")
                let labelY = y + slot - Tokens.Space.x2 - label.lineHeight
                label.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: labelY,
                                     width: max(0, contentWidth - size.width - Tokens.Space.x4 - Tokens.Page.groupPad), height: label.lineHeight)
                documentView.addSubview(label)
                if let accessory {
                    accessory.frame = NSRect(x: pad + contentWidth - size.width, y: round(label.frame.midY - size.height / 2),
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
                heading.frame = NSRect(x: pad - Label.inset, y: y, width: contentWidth, height: heading.lineHeight)
                documentView.addSubview(heading)
                y = heading.frame.maxY + Tokens.Space.x3
                for (title, group) in shown { section(title, group) }
                y += Tokens.Space.x2
            }
            if !found {
                let none = Label("No settings match “\(settingSearch.stringValue.trimmingCharacters(in: .whitespaces))”.", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
                none.frame = NSRect(x: pad - Label.inset, y: y, width: contentWidth, height: none.lineHeight)
                documentView.addSubview(none)
                y = none.frame.maxY + Tokens.Space.x6
            }
            finishDocument(y, width: width)
            return
        }

        switch pane {
        case .general:
            section(nil, generalGroup)
            section("Tabs", tabsGroup)
            section("Window", windowGroup)
            section("Downloads", downloadsGroup)
            section(nil, importGroup)
            section(nil, versionGroup)
        case .spaces:
            section("Your spaces", spacesGroup, accessory: addSpaceButton)
            // Said once, under the list, and only when there's an order to change.
            if spaceRows.count > 1 {
                let hint = Label("Drag a space to change its order.", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
                hint.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y - Tokens.Page.groupGap + Tokens.Space.x2,
                                    width: contentWidth - Tokens.Page.groupPad, height: hint.lineHeight)
                documentView.addSubview(hint)
                y = hint.frame.maxY + Tokens.Page.groupGap
            }
        case .passwords:
            section(nil, passwordsGroup)
            section(nil, passwordsWindowGroup)
        case .privacy:
            section(nil, blockingGroup)
            section("Browsing data", privacyGroup)
            section("Sites", sitesGroup, accessory: sitesReset)
        case .translation:
            section(nil, translationGroup)
            section("Always translate", alwaysGroup, accessory: alwaysReset)
        case .extensions:
            // With nothing installed, the empty row already offers Get Extensions; once said is enough.
            getExtensionsButton.isHidden = !hasExtensions
            let buttons = NSStackView(views: [loadUnpackedButton, getExtensionsButton])
            buttons.spacing = Tokens.Space.x2
            section("Installed", extensionsGroup, accessory: buttons)
            section(nil, developerGroup)
        case .shortcuts:
            let resetAll = PillButton(title: "Reset All")
            resetAll.isHidden = !Shortcuts.hasChanges
            resetAll.onClick = { [weak self] _ in
                Shortcuts.resetAll()
                ShortcutRow.lastTaken = nil
                self?.reloadShortcuts()
                self?.layoutDocument()
            }
            let rw = resetAll.fittingWidth, rh = Tokens.Page.controlHeight
            resetAll.frame = NSRect(x: pad + contentWidth - rw, y: y, width: rw, height: rh)
            documentView.addSubview(resetAll)
            let hint = Label("Click a shortcut to change it. To find one, type its name or keys in Find a setting.", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
            hint.lineBreakMode = .byTruncatingTail
            hint.frame = NSRect(x: pad + Tokens.Page.groupPad - Label.inset, y: y + (rh - hint.lineHeight) / 2,
                                width: max(0, contentWidth - rw - Tokens.Space.x4 - Tokens.Page.groupPad), height: hint.lineHeight)
            documentView.addSubview(hint)
            y += rh
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
        if #available(macOS 15.4, *) { return !ExtensionHost.shared.installed.isEmpty }
        return false
    }

    private func refreshDownloadPlace() { DownloadPlace.configure(downloadPlace) }

    private func refresh() {
        engine.options = SearchEngine.allCases.map { MenuButton.Option(title: $0.name, image: FaviconStore.shared.cachedIcon(for: $0.homeURL).map(Self.menuIcon)) }
        engine.selectedIndex = SearchEngine.allCases.firstIndex(of: Library.shared.searchEngine) ?? 0
        let isDefault = DefaultBrowser.isDefault
        defaultStatus.isHidden = !isDefault
        defaultButton.isHidden = isDefault
        blockingToggle.isOn = ContentBlocker.isEnabled
        pipToggle.isOn = PictureInPicture.followsTabs
        suggestionsToggle.isOn = SuggestionFetcher.isOn
        borderlessToggle.isOn = BrowserRootView.isBorderless
        quitToggle.isOn = AppDelegate.asksBeforeQuitting
        refreshDownloadPlace()
        archiveAfter.selectedIndex = TabArchive.After.allCases.firstIndex(of: TabArchive.after) ?? 0
        saveToggle.isOn = PasswordCapture.offersToSave
        fillToggle.isOn = Autofill.isOn
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
            BrowserWindowController.changeLibrary("Move Space") { Library.shared.moveSpace(spaceID, to: target) }
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

    private func makeDefault() {
        DefaultBrowser.make()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(); self?.layoutDocument() }
    }

    private func addSpace() { BrowserWindowController.changeLibrary("New Space") { Library.shared.addSpace() } }

    // MARK: Privacy

    /// History, website data, and every per-site decision you've made, in one place. Each button says what it
    /// did, right where you clicked.
    private func reloadPrivacy() {
        privacyGroup.removeAllRows()
        sitesGroup.removeAllRows()
        let history = PillButton(title: "Clear History…")
        history.onClick = { [weak self, weak history] _ in
            self?.confirm(title: "Clear all history?", message: "Every page you’ve visited is forgotten on this Mac, and the command bar stops suggesting them. Tabs, pinned tabs and passwords stay.",
                          action: "Clear History") {
                HistoryStore.shared.clearAll()
                history?.flash("Cleared")
            }
        }
        let showHistory = PillButton(title: "Show History")
        showHistory.onClick = { [weak self] _ in
            guard let controller = self?.browser else { return }
            HistoryPage.open(in: controller)
        }
        let historyButtons = NSStackView(views: [showHistory, history])
        historyButtons.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: "History", detail: "The pages you’ve visited, used for suggestions in the command bar.", control: historyButtons))

        let cache = PillButton(title: "Clear Cache…")
        cache.onClick = { [weak self, weak cache] _ in
            self?.confirm(title: "Clear the cache for every site?", message: "Pages load a little slower the first time you open them again. You stay signed in.", action: "Clear Cache") {
                Task { @MainActor in
                    await WebsiteData.clear(.cache)
                    cache?.flash("Cleared")
                }
            }
        }
        let cookies = PillButton(title: "Clear Cookies…")
        cookies.onClick = { [weak self, weak cookies] _ in
            self?.confirm(title: "Clear cookies for every site?", message: "You’ll be signed out of every website. Your passwords, pinned tabs and history stay.", action: "Clear Cookies") {
                Task { @MainActor in
                    await WebsiteData.clear(.cookies)
                    cookies?.flash("Cleared")
                }
            }
        }
        let data = NSStackView(views: [cache, cookies])
        data.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: "Website data", detail: "The cache makes pages load faster. Cookies keep you signed in.", control: data))

        // The choices made one site at a time, which otherwise have nowhere to be seen.
        let ads = ContentBlocker.allowedSites.count, extensions = ExtensionStore.extensionsOffSites.count
        let media = SitePermissions.sites.count, zoom = ZoomLevels.count
        func phrase(_ n: Int, _ text: String) -> String? { n > 0 ? "\(text) on \(n) \(n == 1 ? "site" : "sites")" : nil }
        let parts = [phrase(ads, "Ads allowed"), phrase(extensions, "extensions off"), phrase(media, "permissions set"), phrase(zoom, "zoom set")].compactMap { $0 }
        let reset = PillButton(title: "Reset All")
        sitesReset = parts.isEmpty ? nil : reset
        reset.onClick = { [weak self] _ in
            self?.confirm(title: "Reset choices made for single sites?", message: "Ads are blocked again everywhere, extensions run on every site, sites ask again for your camera, microphone, location and notifications, and zoom goes back to 100%.",
                          action: "Reset All") {
                ContentBlocker.allowedSites = []
                ExtensionStore.extensionsOffSites = []
                SitePermissions.forgetAll()
                ZoomLevels.resetAll()
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
        }
        if parts.isEmpty {
            sitesGroup.add(FormRow(title: "None yet", detail: "Choices you make for one site, like allowing ads, a camera or notifications, show up here.", control: NSView()))
        }

        // Then each site, with what was chosen for it, and a way to forget just that one.
        let sites = SitePermissions.sites.union(ContentBlocker.allowedSites).union(ExtensionStore.extensionsOffSites).union(ZoomLevels.all.keys)
        for site in sites.sorted().prefix(40) {
            var said: [String] = []
            let choices = SitePermissions.choices(host: site)
            for (kind, name) in [("camera", "camera"), ("microphone", "microphone"), ("cameraAndMicrophone", "camera and microphone"),
                                 ("location", "location"), ("notifications", "notifications")] {
                if let allowed = choices[kind] { said.append("\(name) \(allowed ? "allowed" : "blocked")") }
            }
            for (kind, allowed) in choices.sorted(by: { $0.key < $1.key }) where allowed && kind.hasPrefix("app:") {
                said.append("opens \(ExternalLinks.appName(forScheme: String(kind.dropFirst(4))))")
            }
            if ContentBlocker.allowedSites.contains(site) { said.append("ads allowed") }
            if ExtensionStore.extensionsOffSites.contains(site) { said.append("extensions off") }
            if let zoom = ZoomLevels.all[site] { said.append("zoom \(Int((zoom * 100).rounded()))%") }
            guard !said.isEmpty else { continue }
            let forget = PillButton(title: "Forget")
            forget.onClick = { [weak self] _ in
                SitePermissions.forgetEverything(host: site)
                WebNotifications.shared.removeAll(host: site)
                ContentBlocker.allowedSites.remove(site)
                var off = ExtensionStore.extensionsOffSites
                off.remove(site)
                ExtensionStore.extensionsOffSites = off
                ZoomLevels.forget(host: site)
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
            let line = said.joined(separator: ", ")
            let siteURL = URL(string: "https://\(site)")
            let favicon = siteURL.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? SettingsIcon.symbol("globe")
            sitesGroup.add(FormRow(title: site, detail: line.prefix(1).uppercased() + line.dropFirst() + ".", icon: favicon, control: forget))
        }
    }

    private func confirm(title: String, message: String, action: String, then run: @escaping () -> Void) {
        ConfirmSheet.show(in: self, title: title, message: message, confirmTitle: action, destructive: true) { confirmed in
            if confirmed { run() }
        }
    }

    /// Removing an extension deletes its data too, and can't be undone, so it asks first.
    private func confirmRemove(id: String, name: String) {
        ConfirmSheet.show(in: self, title: "Remove \(name)?", message: "Its settings and data on this Mac are deleted too. You can add it again from the Chrome Web Store.",
                          confirmTitle: "Remove", destructive: true) { confirmed in
            if confirmed { ExtensionStore.uninstall(id) }
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

/// One shortcut: what it does, and its keys drawn as small keycaps. Click it to give it new keys.
final class ShortcutRow: InteractiveView, SettingsSearchable {
    /// By name, and by its keys whichever way you type them: "⌘L", "⌘ L", or "command L".
    var searchText: String {
        let names = ["⌘": "command cmd", "⇧": "shift", "⌥": "option alt", "⌃": "control ctrl"]
        let spoken = keys.map { names[$0] ?? $0 }.joined(separator: " ")
        return title.stringValue + " shortcut " + keys.joined() + " " + keys.joined(separator: " ") + " " + spoken
    }
    private var keys: [String] = []
    private let item: NSMenuItem?
    private let title: Label
    private let note = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private var caps: [KeyHint] = []
    private let field = ColorView(color: .clear)
    private let fieldLabel = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let resetButton = IconButton(symbol: "arrow.uturn.backward", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small - 1, toolTip: "Back to Zigzag’s Shortcut")
    private var monitor: Any?
    private var isRecording = false { didSet { refresh() } }
    /// Called after the keys change, so the list can redraw rows that lost theirs.
    var onChange: (() -> Void)?
    private static weak var recording: ShortcutRow?

    /// A row for a menu item, which you can change.
    init(title text: String, item: NSMenuItem) {
        self.item = item
        title = Label(text, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: Tokens.Page.groupRowHeight))
        setup(keys: Shortcuts.caps(item))
        toolTip = "Click to change"
        onClick = { [weak self] _ in self?.startRecording() }
        resetButton.onClick = { [weak self] _ in
            guard let self, let item = self.item else { return }
            Shortcuts.reset(item)
            self.onChange?()
        }
    }

    /// A fixed row, like ⌘1–9, which can't be changed.
    init(title text: String, keys: [String]) {
        item = nil
        title = Label(text, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
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
            let cap = KeyHint(key)
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
        setAccessibilityRole(item == nil ? .staticText : .button)
        setAccessibilityLabel("\(title.stringValue): \(keys.isEmpty ? "no shortcut" : keys.joined(separator: " "))")
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
            fieldLabel.stringValue = "None"
        } else {
            for cap in caps.reversed() {
                x -= cap.width
                cap.frame = NSRect(x: x, y: (bounds.height - KeyHint.height) / 2, width: cap.width, height: KeyHint.height)
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
        if !resetButton.isHidden {
            let b = resetButton.frame.width
            x -= b + Tokens.Space.x2
            resetButton.frame.origin = NSPoint(x: x, y: (bounds.height - b) / 2)
        }
        let width = max(0, x - pad - Tokens.Space.x4)
        if note.isHidden {
            title.frame = NSRect(x: pad, y: (bounds.height - title.lineHeight) / 2, width: width, height: title.lineHeight)
        } else {
            let block = title.lineHeight + note.lineHeight
            title.frame = NSRect(x: pad, y: (bounds.height - block) / 2, width: width, height: title.lineHeight)
            note.frame = NSRect(x: pad, y: title.frame.maxY, width: width, height: note.lineHeight)
        }
    }

    override func stateDidChange(animated: Bool) { refresh() }

    private func refresh() {
        let editable = item != nil
        let fill: NSColor? = isRecording ? nil : editable && isPressed ? Tokens.Color.pressedFill : editable && isHovered ? Tokens.Color.hoverFill : nil
        layer?.backgroundColor = fill.map { cgColor($0) }
        caps.forEach { $0.isHidden = isRecording }
        let none = caps.isEmpty && editable
        field.isHidden = !(isRecording || none)
        // Recording looks like a field being typed in: the soft fill and the window's accent ring.
        let accent = Brand.Theme.for(self).accent
        field.layer?.borderColor = isRecording ? cgColor(accent.withAlphaComponent(0.6)) : nil
        field.layer?.borderWidth = isRecording ? 1.5 : 0
        field.layer?.backgroundColor = isRecording ? cgColor(Tokens.Color.fieldFill) : nil
        if !isRecording && none { fieldLabel.stringValue = "None"; fieldLabel.textColor = Tokens.Color.textTertiary }
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
                    self.fieldLabel.stringValue = "Add ⌘, ⌥ or ⌃"
                    self.fieldLabel.textColor = Tokens.Color.caution
                    return nil
                }
                if let fixed = Shortcuts.reserved(combo) {
                    self.fieldLabel.stringValue = "Used for “\(fixed)”"
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
        fieldLabel.stringValue = held.isEmpty ? "Type a shortcut" : held + " …"
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
        say("Taken from “\(taken.from)”, which has no shortcut now")
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if ShortcutRow.recording === self { ShortcutRow.recording = nil }
        isRecording = false
    }

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
