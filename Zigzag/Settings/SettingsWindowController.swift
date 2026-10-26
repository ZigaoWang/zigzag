import AppKit
import WebKit

// MARK: - Grouped form, the way System Settings lays things out

/// A rounded group of rows separated by hairlines.
final class FormGroup: NSView {
    private(set) var rows: [NSView] = []
    private var lines: [NSView] = []
    private let background = ColorView(color: Tokens.Color.formGroup)

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = Tokens.Radius.panel - 2
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

    var fittingHeight: CGFloat { fittingHeight(for: frame.width > 0 ? frame.width : 492) }

    func fittingHeight(for width: CGFloat) -> CGFloat { rows.map { rowHeight($0, width) }.reduce(0, +) }

    private func rowHeight(_ row: NSView, _ width: CGFloat) -> CGFloat { (row as? FormRow)?.height(for: width) ?? row.frame.height }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layer?.borderColor = background.cgColor(Tokens.Color.formGroupEdge)
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let h = rowHeight(row, bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
            if i < lines.count {
                lines[i].frame = NSRect(x: Tokens.Space.x3, y: y, width: bounds.width - Tokens.Space.x3, height: Tokens.Metric.hairline)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A form row: a title (and optional explanation, which wraps) on the left, a control on the right. Rows grow to
/// fit their explanation, so nothing is ever cut off.
final class FormRow: NSView {
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    let control: NSView

    init(title: String, detail: String? = nil, icon: NSImage? = nil, control: NSView) {
        self.control = control
        self.icon.image = icon
        self.icon.imageScaling = .scaleProportionallyUpOrDown
        self.icon.isHidden = icon == nil
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: 44))
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.font = Tokens.Font.small()
        self.detail.textColor = Tokens.Color.textSecondary
        self.detail.isSelectable = false
        self.detail.isHidden = detail == nil
        [self.icon, self.title, self.detail, control].forEach { addSubview($0) }
        frame.size.height = height(for: frame.width)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private let pad = Tokens.Space.x3

    private var controlSize: NSSize {
        let size = control.fittingSize
        return size.width > 0 ? size : control.intrinsicContentSize
    }

    private func textX() -> CGFloat { icon.isHidden ? pad : pad + Tokens.Space.x6 + Tokens.Space.x3 }

    private func textWidth(for width: CGFloat) -> CGFloat { max(120, width - pad - controlSize.width - Tokens.Space.x4 - textX()) }

    /// The height this row needs at `width`.
    func height(for width: CGFloat) -> CGFloat {
        let titleHeight = title.lineHeight
        guard !detail.isHidden else { return max(44, titleHeight + Tokens.Space.x6) }
        let detailHeight = ceil(detail.sizeThatFits(NSSize(width: textWidth(for: width), height: 400)).height)
        return max(52, Tokens.Space.x3 + titleHeight + 2 + detailHeight + Tokens.Space.x3)
    }

    override func layout() {
        super.layout()
        let size = controlSize
        control.frame = NSRect(x: bounds.width - pad - size.width, y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
        let x = textX()
        if !icon.isHidden {
            let side = Tokens.Space.x6
            icon.frame = NSRect(x: pad, y: round((bounds.height - side) / 2), width: side, height: side)
        }
        let width = textWidth(for: bounds.width)
        if detail.isHidden {
            title.frame = NSRect(x: x, y: round((bounds.height - title.lineHeight) / 2), width: width, height: title.lineHeight)
        } else {
            let detailHeight = ceil(detail.sizeThatFits(NSSize(width: width, height: 400)).height)
            let top = round((bounds.height - title.lineHeight - 2 - detailHeight) / 2)
            title.frame = NSRect(x: x, y: top, width: width, height: title.lineHeight)
            detail.frame = NSRect(x: x, y: title.frame.maxY + 2, width: width, height: detailHeight)
        }
    }
}

// MARK: - Spaces list

/// A space in Settings: its color (click to change), its name (edit in place), delete on hover, drag to reorder.
final class SpaceSettingsRow: InteractiveView {
    let spaceID: UUID
    private let dot = ColorView(color: .clear)
    private let name: Label
    private let editButton = TextButton.form("Edit")
    private let deleteButton = IconButton(symbol: "trash", size: Tokens.Space.x7Height, symbolSize: Tokens.TypeSize.small, toolTip: "Delete Space")
    /// True while the row is being dragged; it draws as lifted.
    var isLifted = false { didSet { stateDidChange(animated: true) } }

    init(space: SpaceInfo) {
        spaceID = space.id
        name = Label(space.name, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Space.x12))
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        dot.wantsLayer = true
        dot.color = space.swatch
        deleteButton.isHidden = true
        deleteButton.isEnabled = Library.shared.spaces.count > 1
        [dot, name, deleteButton, editButton].forEach { addSubview($0) }
        // The row and its Edit button both open the same editor the sidebar uses.
        onClick = { [weak self] _ in self?.openEditor() }
        editButton.onClick = { [weak self] _ in self?.openEditor() }
        deleteButton.onClick = { [weak self] _ in
            guard let self, let window = self.window else { return }
            SpaceSettingsRow.confirmDelete(self.spaceID, window: window)
        }
        toolTip = "Click to edit, drag to reorder"
        setAccessibilityRole(.row)
        setAccessibilityLabel(space.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let d = Tokens.Space.x5
        dot.frame = NSRect(x: pad, y: (bounds.height - d) / 2, width: d, height: d)
        dot.layer?.cornerRadius = d / 2
        let ew = editButton.fittingWidth
        editButton.frame = NSRect(x: bounds.width - pad - ew, y: (bounds.height - Tokens.Space.x7Height) / 2, width: ew, height: Tokens.Space.x7Height)
        let b = deleteButton.frame.width
        deleteButton.frame.origin = NSPoint(x: editButton.frame.minX - Tokens.Space.x1 - b, y: (bounds.height - b) / 2)
        let x = dot.frame.maxX + Tokens.Space.x3
        name.frame = NSRect(x: x, y: (bounds.height - name.lineHeight) / 2, width: max(0, deleteButton.frame.minX - x - Tokens.Space.x2), height: name.lineHeight)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: isLifted ? .closedHand : .pointingHand) }

    override func stateDidChange(animated: Bool) {
        deleteButton.isHidden = !isHovered || isLifted
        let fill: NSColor? = isLifted ? Tokens.Color.formGroup : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
        layer?.shadowOpacity = isLifted ? 1 : 0
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.borderWidth = isLifted ? 1 : 0
        layer?.borderColor = cgColor(Brand.Theme.brand.accent.withAlphaComponent(0.5))
    }

    func openEditor() {
        guard let host = window?.contentView else { return }
        if let open = SpaceEditorPanel.current {
            let same = open.spaceID == spaceID
            open.close()
            if same { return }
        }
        let editor = SpaceEditorPanel(spaceID: spaceID, controller: nil)
        SpaceEditorPanel.current = editor
        editor.show(in: host, below: editButton)
    }

    static func confirmDelete(_ id: UUID, window: NSWindow) {
        guard let space = Library.shared.space(id), Library.shared.spaces.count > 1 else { return }
        // Its tabs can come back with Undo in the browser, but it's still a big step, so it asks first.
        guard let host = window.contentView else { return }
        ConfirmSheet.show(in: host, title: "Delete “\(space.name)”?",
                          message: "Its bookmarks and tabs close. You can bring it back with Undo in the browser window.",
                          confirmTitle: "Delete Space", destructive: true) { confirmed in
            if confirmed { BrowserWindowController.undoTarget?.removeSpaceWithUndo(id) }
        }
    }
}

// MARK: - Window

/// The parts of Settings, each a pane of its own, picked from the toolbar at the top.
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

    var subtitle: String {
        switch self {
        case .general: "Search, your default browser, and how pages behave."
        case .spaces: "Each space keeps its own tabs, pins and color. Drag a space to reorder."
        case .passwords: "Saved in your Keychain and synced with iCloud Keychain."
        case .privacy: "What sites keep on this Mac, and the choices you’ve made for them."
        case .translation: "Pages in other languages, translated on this Mac by Apple."
        case .extensions: "Extensions from the Chrome Web Store, running in Zigzag."
        case .shortcuts: "Every keyboard shortcut in Zigzag, and yours to change."
        }
    }
}

/// One pane button in the toolbar: its symbol over its name, a soft fill of the space's accent when chosen.
private final class PaneTab: InteractiveView {
    let pane: SettingsPane
    private let icon = NSImageView()
    private let label: Label

    init(_ pane: SettingsPane) {
        self.pane = pane
        label = Label(pane.title, font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.panel - 2
        layer?.cornerCurve = .continuous
        icon.image = Tokens.Symbol.image(pane.symbol, size: 18)
        label.alignment = .center
        [icon, label].forEach { addSubview($0) }
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(pane.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let size = NSSize(width: 76, height: 54)

    override func layout() {
        super.layout()
        let side: CGFloat = 22
        // Flipped: the symbol on top, its name under it.
        icon.frame = NSRect(x: (bounds.width - side) / 2, y: 7, width: side, height: side)
        label.frame = NSRect(x: 0, y: bounds.height - 6 - label.lineHeight, width: bounds.width, height: label.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let accent = Brand.Theme.brand.accent
        let fill: NSColor? = isSelected ? accent.withAlphaComponent(isPressed ? 0.22 : 0.14) : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        icon.contentTintColor = isSelected ? accent : Tokens.Color.icon
        label.textColor = isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
    }
}

/// Settings: a pane toolbar, then each pane's header and its groups, built from Zigzag's own controls.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()
    private let root = FlippedView()
    private var tabs: [PaneTab] = []
    private let toolbarEdge = ColorView(color: Tokens.Color.separator)
    private let scroll = NSScrollView()
    private let documentView = FlippedView()
    private let banner = BrandBanner()
    private(set) var pane = SettingsPane.general

    private let generalGroup = FormGroup()
    private let behaviorGroup = FormGroup()
    private let importGroup = FormGroup()
    private let spacesGroup = FormGroup()
    private let windowGroup = FormGroup()
    private let passwordsGroup = FormGroup()
    private let passwordsWindowGroup = FormGroup()
    private let privacyGroup = FormGroup()
    private let translationGroup = FormGroup()
    private let alwaysGroup = FormGroup()
    private let extensionsGroup = FormGroup()
    private let developerGroup = FormGroup()
    private var shortcutGroups: [(String, FormGroup)] = []
    private let shortcutSearch = FilledField(placeholder: "Search shortcuts")

    private let engine = MenuButton()
    private let archiveAfter = MenuButton()
    private let defaultButton = TextButton.form("Make Default")
    private let defaultStatus = StatusLabel("Zigzag is your default browser")
    private let blockingToggle = Toggle()
    private let pipToggle = Toggle()
    private let borderlessToggle = Toggle()
    private let quitToggle = Toggle()
    /// Where downloads go: Downloads, another folder, or ask each time.
    private let downloadPlace = MenuButton()
    private let saveToggle = Toggle()
    private let fillToggle = Toggle()
    private let cardToggle = Toggle()
    private let translateOffer = Toggle()
    private let translateInto = MenuButton()
    private var languages: [(id: String, name: String)] = []
    private let addSpaceButton = TextButton.form("Add Space")
    private let getExtensionsButton = TextButton.form("Get Extensions")
    private let loadUnpackedButton = TextButton.form("Load Unpacked")
    private var spaceRows: [SpaceSettingsRow] = []
    private var token: SignalToken?
    private var extensionsToken: SignalToken?

    private let width: CGFloat = 720
    private let toolbarHeight: CGFloat = 96

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = Tokens.Color.formBackground
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.contentMaxSize = NSSize(width: 720, height: 2000)
        super.init(window: window)
        window.delegate = self
        build()
        token = Library.shared.changed.observe { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.reloadSpaces()
        }
        if #available(macOS 15.4, *) {
            extensionsToken = ExtensionHost.shared.changed.observe { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.reloadExtensions()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func header(_ text: String) -> Label {
        Label(text, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    }

    // MARK: Building

    private func build() {
        // The toolbar of panes.
        tabs = SettingsPane.allCases.map { pane in
            let tab = PaneTab(pane)
            tab.onClick = { [weak self] _ in self?.show(pane) }
            root.addSubview(tab)
            return tab
        }
        root.addSubview(toolbarEdge)

        // General
        engine.options = SearchEngine.allCases.map { MenuButton.Option(title: $0.name, image: FaviconStore.shared.cachedIcon(for: $0.homeURL).map(Self.menuIcon)) }
        SearchEngine.allCases.forEach { if FaviconStore.shared.cachedIcon(for: $0.homeURL) == nil { FaviconStore.shared.prefetch(for: $0.homeURL) } }
        engine.onSelect = { index in Library.shared.searchEngine = SearchEngine.allCases[index] }
        defaultButton.onClick = { [weak self] _ in self?.makeDefault() }
        let defaultControl = NSStackView(views: [defaultStatus, defaultButton])
        defaultControl.spacing = Tokens.Space.x2
        generalGroup.add(FormRow(title: "Search engine", detail: "Used when what you type isn’t an address.", control: engine))
        let search = FormRow(title: "Search a site", detail: "In the address bar, type a site’s name, then press Tab.", control: KeyHint("Tab"))
        search.toolTip = SiteSearch.all.map(\.name).joined(separator: ", ")
        generalGroup.add(search)
        generalGroup.add(FormRow(title: "Default browser", detail: "Links from other apps open here.", control: defaultControl))
        blockingToggle.onChange = { on in ContentBlocker.isEnabled = on }
        pipToggle.onChange = { on in PictureInPicture.followsTabs = on }
        downloadPlace.onSelect = { [weak self] index in self?.pickDownloadPlace(index) }
        archiveAfter.options = TabArchive.After.allCases.map { MenuButton.Option(title: $0.title) }
        archiveAfter.onSelect = { index in TabArchive.after = TabArchive.After.allCases[index] }
        behaviorGroup.add(FormRow(title: "Archive tabs you haven’t used", detail: "They leave the sidebar. Type a few letters in the address bar to bring one back.", control: archiveAfter))
        // EasyList's licence asks for credit; this is where people look for what does the blocking.
        behaviorGroup.add(FormRow(title: "Block ads and trackers", detail: "Uses EasyList and EasyPrivacy, by the EasyList authors.", control: blockingToggle))
        behaviorGroup.add(FormRow(title: "Save downloads to", detail: "Or have Zigzag ask where, each time.", control: downloadPlace))
        behaviorGroup.add(FormRow(title: "Keep videos playing when you switch tabs", detail: "A playing video floats in its own window until you come back.", control: pipToggle))
        quitToggle.onChange = { on in AppDelegate.asksBeforeQuitting = on }
        behaviorGroup.add(FormRow(title: "Ask before quitting", detail: "So ⌘Q never closes everything by accident.", control: quitToggle))
        let importButton = TextButton.form("Import")
        importButton.onClick = { _ in ImportWindowController.show() }
        importGroup.add(FormRow(title: "Import from another browser", detail: "Passwords, bookmarks and history. The other browser isn’t changed.", control: importButton))

        // Spaces
        addSpaceButton.onClick = { [weak self] _ in self?.addSpace() }
        borderlessToggle.onChange = { on in BrowserRootView.isBorderless = on }
        windowGroup.add(FormRow(title: "Borderless page", detail: "With the sidebar hidden, the page fills the whole window.", control: borderlessToggle))

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

        // Shortcuts
        shortcutSearch.field.delegate = self

        reloadPrivacy()

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        scroll.useSlimScroller()
        root.addSubview(scroll)
        window?.contentView = root
        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rootResized), name: NSView.frameDidChangeNotification, object: root)
        reloadSpaces()
        reloadExtensions()
        show(.general)
    }

    @objc private func rootResized() { layoutRoot() }

    private func layoutRoot() {
        let size = PaneTab.size
        let gap: CGFloat = 2
        let total = CGFloat(tabs.count) * size.width + CGFloat(tabs.count - 1) * gap
        var x = round((root.bounds.width - total) / 2)
        for tab in tabs {
            tab.frame = NSRect(x: x, y: toolbarHeight - size.height - Tokens.Space.x2, width: size.width, height: size.height)
            x += size.width + gap
        }
        toolbarEdge.frame = NSRect(x: 0, y: toolbarHeight, width: root.bounds.width, height: Tokens.Metric.hairline)
        scroll.frame = NSRect(x: 0, y: toolbarHeight + Tokens.Metric.hairline, width: root.bounds.width, height: max(0, root.bounds.height - toolbarHeight - Tokens.Metric.hairline))
        layoutDocument()
    }

    /// Opens a pane.
    func show(_ pane: SettingsPane) {
        self.pane = pane
        tabs.forEach { $0.isSelected = $0.pane == pane }
        if pane == .privacy { reloadPrivacy() }
        if pane == .shortcuts { reloadShortcuts() }
        layoutRoot()
        documentView.scroll(.zero)

    }

    // MARK: Groups

    private func reloadExtensions() {
        extensionsGroup.removeAllRows()
        developerGroup.removeAllRows()
        defer { if pane == .extensions { layoutDocument() } }
        guard #available(macOS 15.4, *) else { return }
        loadUnpackedButton.isHidden = !ExtensionStore.developerMode
        let installed = ExtensionHost.shared.installed.sorted {
            ($0.value.displayName ?? $0.key).localizedCaseInsensitiveCompare($1.value.displayName ?? $1.key) == .orderedAscending
        }
        if installed.isEmpty {
            let get = TextButton.form("Get Extensions")
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
            let review = TextButton.form("Review Update")
            review.onClick = { _ in
                guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
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
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await ExtensionStore.loadUnpacked(url) == nil, let host = window.contentView {
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
        if pane == .spaces { layoutDocument() }
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
        let open = TextButton.form("Open Passwords")
        open.onClick = { _ in PasswordsWindowController.show() }
        passwordsWindowGroup.add(FormRow(title: "Your passwords", detail: "See, edit and export them. Also in Window › Passwords" + Shortcuts.hint(for: #selector(AppDelegate.showPasswords(_:))) + ".", control: open))
        let bring = TextButton.form("Import")
        bring.onClick = { _ in ImportWindowController.show() }
        passwordsWindowGroup.add(FormRow(title: "Import from another browser", detail: "Or from a password export file.", control: bring))
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
        let reset = TextButton.form("Reset")
        reset.isEnabled = !always.isEmpty
        reset.onClick = { [weak self] _ in
            PageTranslator.alwaysLanguages = []
            self?.reloadTranslation()
            self?.layoutDocument()
        }
        alwaysGroup.add(FormRow(title: "Always translate",
                                detail: always.isEmpty ? "None yet. Turn on Always Translate from a page’s site controls." : ListFormatter.localizedString(byJoining: always) + ".",
                                control: reset))
    }

    // MARK: Shortcuts

    /// Every shortcut, read from the menu bar itself so the list is always right.
    private func reloadShortcuts() {
        let query = shortcutSearch.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
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
                    guard query.isEmpty || title.lowercased().contains(query) else { continue }
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
                for (title, keys) in [("Go to tab 1 to 8, or the last tab", ["⌘", "1–9"]), ("Go to space 1 to 9", ["⌃", "1–9"])] where query.isEmpty || title.lowercased().contains(query) {
                    group.add(ShortcutRow(title: title, keys: keys))
                }
            }
            if !group.rows.isEmpty { groups.append((top.title == "Zigzag" ? "Zigzag" : top.title, group)) }
        }
        shortcutGroups = groups
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadShortcuts()
        layoutDocument()
    }

    // MARK: Layout

    private func layoutDocument() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let pad = Tokens.Space.x8
        let contentWidth = width - pad * 2
        banner.title = pane.title
        banner.subtitle = pane.subtitle
        banner.titleSize = 26
        banner.contentInset = pad + Tokens.Space.x1
        banner.washOverhang = 0
        banner.frame = NSRect(x: 0, y: 0, width: width, height: 92)
        documentView.addSubview(banner, positioned: .below, relativeTo: nil)
        var y: CGFloat = banner.frame.maxY + Tokens.Space.x2

        func section(_ title: String?, _ group: FormGroup, accessory: NSView? = nil) {
            if title != nil || accessory != nil {
                let label = header(title ?? "")
                let accessoryWidth = accessory?.fittingSize.width ?? 0
                label.frame = NSRect(x: pad + Tokens.Space.x1, y: y, width: contentWidth - accessoryWidth - Tokens.Space.x4, height: label.lineHeight)
                documentView.addSubview(label)
                if let accessory {
                    let size = accessory.fittingSize
                    accessory.frame = NSRect(x: width - pad - size.width, y: y + (label.frame.height - size.height) / 2, width: size.width, height: size.height)
                    documentView.addSubview(accessory)
                }
                y = label.frame.maxY + Tokens.Space.x2
            }
            group.frame = NSRect(x: pad, y: y, width: contentWidth, height: group.fittingHeight(for: contentWidth))
            group.needsLayout = true
            documentView.addSubview(group)
            y = group.frame.maxY + Tokens.Space.x6
        }

        switch pane {
        case .general:
            section(nil, generalGroup)
            section(nil, behaviorGroup)
            section(nil, importGroup)
        case .spaces:
            section("Your spaces", spacesGroup, accessory: addSpaceButton)
            section(nil, windowGroup)
        case .passwords:
            section(nil, passwordsGroup)
            section(nil, passwordsWindowGroup)
        case .privacy:
            section(nil, privacyGroup)
        case .translation:
            section(nil, translationGroup)
            section(nil, alwaysGroup)
        case .extensions:
            let buttons = NSStackView(views: [loadUnpackedButton, getExtensionsButton])
            buttons.spacing = Tokens.Space.x2
            section("Installed", extensionsGroup, accessory: buttons)
            section(nil, developerGroup)
        case .shortcuts:
            let resetAll = TextButton.form("Reset All")
            resetAll.isEnabled = Shortcuts.hasChanges
            resetAll.onClick = { [weak self] _ in
                Shortcuts.resetAll()
                ShortcutRow.lastTaken = nil
                self?.reloadShortcuts()
                self?.layoutDocument()
            }
            let rw = resetAll.fittingWidth
            resetAll.frame = NSRect(x: width - pad - rw, y: y, width: rw, height: Tokens.Space.x8)
            documentView.addSubview(resetAll)
            let hint = Label("Click a shortcut to change it.", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
            hint.frame = NSRect(x: pad + Tokens.Space.x1, y: y + (Tokens.Space.x8 - hint.lineHeight) / 2, width: contentWidth - rw - Tokens.Space.x4, height: hint.lineHeight)
            documentView.addSubview(hint)
            y += Tokens.Space.x8 + Tokens.Space.x3
            shortcutSearch.frame = NSRect(x: pad, y: y, width: contentWidth, height: Tokens.Space.x8)
            shortcutSearch.tint = Brand.Theme.brand.accent
            documentView.addSubview(shortcutSearch)
            y = shortcutSearch.frame.maxY + Tokens.Space.x5
            if shortcutGroups.isEmpty {
                let none = Label("No shortcuts match “\(shortcutSearch.stringValue)”.", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
                none.frame = NSRect(x: pad + Tokens.Space.x1, y: y, width: contentWidth, height: none.lineHeight)
                documentView.addSubview(none)
                y = none.frame.maxY + Tokens.Space.x6
            }
            for (title, group) in shortcutGroups { section(title, group) }
        }

        let height = max(y, scroll.contentSize.height)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    /// The menu: the folder downloads go to (with its own icon), Ask Each Time, and Other… to pick a folder.
    private func refreshDownloadPlace() {
        let folder = DownloadManager.folder
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        downloadPlace.options = [MenuButton.Option(title: FileManager.default.displayName(atPath: folder.path), image: icon),
                                 MenuButton.Option(title: "Ask Each Time", image: nil),
                                 MenuButton.Option(title: "Other…", image: nil)]
        downloadPlace.selectedIndex = DownloadManager.asksWhereToSave ? 1 : 0
    }

    private func pickDownloadPlace(_ index: Int) {
        switch index {
        case 0: DownloadManager.asksWhereToSave = false
        case 1: DownloadManager.asksWhereToSave = true
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.directoryURL = DownloadManager.folder
            if panel.runModal() == .OK, let url = panel.url {
                DownloadManager.folder = url
                DownloadManager.asksWhereToSave = false
            }
        }
        refreshDownloadPlace()
    }

    private func refresh() {
        engine.options = SearchEngine.allCases.map { MenuButton.Option(title: $0.name, image: FaviconStore.shared.cachedIcon(for: $0.homeURL).map(Self.menuIcon)) }
        engine.selectedIndex = SearchEngine.allCases.firstIndex(of: Library.shared.searchEngine) ?? 0
        let isDefault = Self.isDefaultBrowser
        defaultStatus.isHidden = !isDefault
        defaultButton.isHidden = isDefault
        blockingToggle.isOn = ContentBlocker.isEnabled
        pipToggle.isOn = PictureInPicture.followsTabs
        borderlessToggle.isOn = BrowserRootView.isBorderless
        quitToggle.isOn = AppDelegate.asksBeforeQuitting
        refreshDownloadPlace()
        archiveAfter.selectedIndex = TabArchive.After.allCases.firstIndex(of: TabArchive.after) ?? 0
        saveToggle.isOn = PasswordCapture.offersToSave
        fillToggle.isOn = Autofill.isOn
        translateOffer.isOn = PageTranslator.offers
        generalGroup.rows.forEach { $0.needsLayout = true }
    }

    func show() {
        refresh()
        reloadSpaces()
        reloadExtensions()
        reloadPasswords()
        reloadTranslation()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        layoutRoot()
        // Nothing is focused until you click it; a settings window shouldn't start in edit mode.
        window?.makeFirstResponder(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: Reordering spaces

    private func beginDrag(_ row: SpaceSettingsRow, event: NSEvent) -> Bool {
        guard let window, let startIndex = spaceRows.firstIndex(where: { $0 === row }) else { return false }
        let start = spacesGroup.convert(event.locationInWindow, from: nil)
        let rowHeight = row.frame.height
        row.removeFromSuperview()
        spacesGroup.addSubview(row)
        SpaceEditorPanel.current?.close()
        row.isLifted = true
        let originY = row.frame.minY
        var target = startIndex
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            let point = self.spacesGroup.convert(event.locationInWindow, from: nil)
            let y = min(max(originY + point.y - start.y, 0), self.spacesGroup.bounds.height - rowHeight)
            Tokens.Motion.withoutAnimation { row.frame.origin.y = y }
            let newTarget = min(max(Int((y + rowHeight / 2) / rowHeight), 0), self.spaceRows.count - 1)
            if newTarget != target {
                target = newTarget
                var others = self.spaceRows.filter { $0 !== row }
                others.insert(row, at: target)
                Tokens.Motion.animate(Tokens.Motion.snappy) {
                    for (i, other) in others.enumerated() where other !== row {
                        other.animator().frame.origin.y = CGFloat(i) * rowHeight
                    }
                }
            }
        }
        if target != startIndex {
            BrowserWindowController.undoTarget?.libraryChange("Move Space") { Library.shared.moveSpace(row.spaceID, to: target) }
        } else {
            reloadSpaces()
        }
        return true
    }

    // MARK: Actions

    private func makeDefault() {
        DefaultBrowser.make()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(); self?.layoutDocument() }
    }

    private func addSpace() { BrowserWindowController.undoTarget?.libraryChange("New Space") { Library.shared.addSpace() } }

    // MARK: Privacy

    /// History, website data, and every per-site decision you've made, in one place. Each button says what it
    /// did, right where you clicked.
    private func reloadPrivacy() {
        privacyGroup.removeAllRows()
        let history = TextButton.form("Clear History")
        history.onClick = { [weak self, weak history] _ in
            self?.confirm(title: "Clear all history?", message: "Every page you’ve visited is forgotten on this Mac, and the command bar stops suggesting them. Tabs, bookmarks and passwords stay.",
                          action: "Clear History") {
                HistoryStore.shared.clearAll()
                history?.flash("Cleared")
            }
        }
        let showHistory = TextButton.form("Show History")
        showHistory.onClick = { _ in HistoryWindowController.show() }
        let historyButtons = NSStackView(views: [showHistory, history])
        historyButtons.spacing = Tokens.Space.x2
        privacyGroup.add(FormRow(title: "History", detail: "The pages you’ve visited, used for suggestions in the command bar.", control: historyButtons))

        let cache = TextButton.form("Clear Cache")
        cache.onClick = { [weak cache] _ in
            Task { @MainActor in
                await WebsiteData.clear(.cache)
                cache?.flash("Cleared")
            }
        }
        let cookies = TextButton.form("Clear Cookies")
        cookies.onClick = { [weak self, weak cookies] _ in
            self?.confirm(title: "Clear cookies for every site?", message: "You’ll be signed out of every website. Your passwords, bookmarks and history stay.", action: "Clear Cookies") {
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
        let reset = TextButton.form("Reset All")
        reset.isEnabled = !parts.isEmpty
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
        let summary = parts.isEmpty ? "None yet. Choices you make for one site, like allowing ads, a camera or notifications, show up here."
            : ListFormatter.localizedString(byJoining: parts).prefix(1).uppercased() + ListFormatter.localizedString(byJoining: parts).dropFirst() + "."
        privacyGroup.add(FormRow(title: "Site choices", detail: summary, control: reset))

        // Then each site, with what was chosen for it, and a way to forget just that one.
        let sites = SitePermissions.sites.union(ContentBlocker.allowedSites).union(ExtensionStore.extensionsOffSites).union(ZoomLevels.all.keys)
        for site in sites.sorted().prefix(40) {
            var said: [String] = []
            let choices = SitePermissions.choices(host: site)
            for (kind, name) in [("camera", "camera"), ("microphone", "microphone"), ("cameraAndMicrophone", "camera and microphone"),
                                 ("location", "location"), ("notifications", "notifications")] {
                if let allowed = choices[kind] { said.append("\(name) \(allowed ? "allowed" : "blocked")") }
            }
            if ContentBlocker.allowedSites.contains(site) { said.append("ads allowed") }
            if ExtensionStore.extensionsOffSites.contains(site) { said.append("extensions off") }
            if let zoom = ZoomLevels.all[site] { said.append("zoom \(Int((zoom * 100).rounded()))%") }
            guard !said.isEmpty else { continue }
            let forget = TextButton.form("Forget")
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
            privacyGroup.add(FormRow(title: site, detail: line.prefix(1).uppercased() + line.dropFirst() + ".", control: forget))
        }
    }

    private func confirm(title: String, message: String, action: String, then run: @escaping () -> Void) {
        guard let host = window?.contentView else { return }
        ConfirmSheet.show(in: host, title: title, message: message, confirmTitle: action, destructive: true) { confirmed in
            if confirmed { run() }
        }
    }

    /// Removing an extension deletes its data too, and can't be undone, so it asks first.
    private func confirmRemove(id: String, name: String) {
        guard let host = window?.contentView else { return }
        ConfirmSheet.show(in: host, title: "Remove \(name)?", message: "Its settings and data on this Mac are deleted too. You can add it again from the Chrome Web Store.",
                          confirmTitle: "Remove", destructive: true) { confirmed in
            if confirmed { ExtensionStore.uninstall(id) }
        }
    }

    private func getExtensions() {
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
        controller.tabManager.newTab(url: ExtensionStore.webStoreURL)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Favicons come in at any size; a menu wants 16 points.
    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    static var isDefaultBrowser: Bool {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

/// One shortcut: what it does, and its keys drawn as small keycaps. Click it to give it new keys.
final class ShortcutRow: InteractiveView {
    private let item: NSMenuItem?
    private let title: Label
    private let note = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private var caps: [(ColorView, Label)] = []
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
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: 40))
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
        super.init(frame: NSRect(x: 0, y: 0, width: 492, height: 40))
        setup(keys: keys)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func setup(keys: [String]) {
        layer?.cornerRadius = Tokens.Radius.row
        addSubview(title)
        addSubview(note)
        note.isHidden = true
        for key in keys {
            let cap = ColorView(color: Tokens.Color.fieldFill)
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 5
            cap.layer?.cornerCurve = .continuous
            let label = Label(key, font: .systemFont(ofSize: Tokens.TypeSize.small, weight: .semibold), color: Tokens.Color.textSecondary)
            label.alignment = .center
            cap.addSubview(label)
            addSubview(cap)
            caps.append((cap, label))
        }
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.cornerCurve = .continuous
        field.layer?.borderWidth = 1.5
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
        let pad = Tokens.Space.x3
        let capHeight: CGFloat = 22
        var x = bounds.width - pad
        if isRecording {
            let w: CGFloat = 168
            x -= w
            field.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: w, height: 26)
            fieldLabel.frame = NSRect(x: Tokens.Space.x2, y: (26 - fieldLabel.lineHeight) / 2, width: w - Tokens.Space.x4, height: fieldLabel.lineHeight)
        } else if caps.isEmpty && item != nil {
            fieldLabel.stringValue = "None"
        } else {
            for (cap, label) in caps.reversed() {
                let w = max(capHeight, label.inkWidth + Tokens.Space.x3)
                x -= w
                cap.frame = NSRect(x: x, y: (bounds.height - capHeight) / 2, width: w, height: capHeight)
                label.frame = NSRect(x: 0, y: (capHeight - label.lineHeight) / 2, width: w, height: label.lineHeight)
                x -= 4
            }
        }
        if caps.isEmpty && item != nil && !isRecording {
            // No keys: a quiet "None" where the caps would be.
            let w = fieldLabel.inkWidth + Tokens.Space.x2
            x -= w
            field.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: w, height: 26)
            fieldLabel.frame = NSRect(x: 0, y: (26 - fieldLabel.lineHeight) / 2, width: w, height: fieldLabel.lineHeight)
        }
        if !resetButton.isHidden {
            let b = resetButton.frame.width
            x -= b + Tokens.Space.x2
            resetButton.frame.origin = NSPoint(x: x, y: (bounds.height - b) / 2)
        }
        let width = max(0, x - pad - Tokens.Space.x3)
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
        caps.forEach { $0.0.isHidden = isRecording }
        let none = caps.isEmpty && editable
        field.isHidden = !(isRecording || none)
        let accent = Brand.Theme.brand.accent
        field.layer?.borderColor = isRecording ? cgColor(accent) : nil
        field.layer?.borderWidth = isRecording ? 1.5 : 0
        field.layer?.backgroundColor = isRecording ? cgColor(accent.withAlphaComponent(0.08)) : nil
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
    static func make() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
    }
}
