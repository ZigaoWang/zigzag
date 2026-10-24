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
final class SpaceSettingsRow: InteractiveView, NSTextFieldDelegate {
    let spaceID: UUID
    private let swatchButton = InteractiveView()
    private let swatchFill = NSView()
    private let name = NSTextField()
    private let grip = NSImageView()
    private let deleteButton = IconButton(symbol: "trash", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Delete Space")

    init(space: SpaceInfo) {
        spaceID = space.id
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Space.x10 + Tokens.Space.x1))
        name.stringValue = space.name
        name.isBordered = false
        name.drawsBackground = false
        name.focusRingType = .none
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.delegate = self
        name.placeholderString = "Name"
        grip.image = Tokens.Symbol.image("line.3.horizontal", size: Tokens.TypeSize.small)
        grip.contentTintColor = .tertiaryLabelColor
        grip.imageScaling = .scaleNone
        grip.toolTip = "Drag to reorder"
        deleteButton.isHidden = true
        deleteButton.isEnabled = Library.shared.spaces.count > 1
        swatchFill.wantsLayer = true
        swatchButton.addSubview(swatchFill)
        [swatchButton, name, grip, deleteButton].forEach { addSubview($0) }
        swatchFill.layer?.backgroundColor = swatchFill.cgColor(space.swatch)
        swatchButton.toolTip = "Change color"
        swatchButton.onClick = { [weak self] _ in self?.openColorPicker() }
        deleteButton.onClick = { [weak self] _ in
            guard let self, let window = self.window else { return }
            SpaceSettingsRow.confirmDelete(self.spaceID, window: window)
        }
        setAccessibilityRole(.row)
        setAccessibilityLabel(space.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let swatch = Tokens.Space.x5
        swatchButton.frame = NSRect(x: pad - 2, y: (bounds.height - swatch - 4) / 2, width: swatch + 4, height: swatch + 4)
        swatchButton.layer?.cornerRadius = (swatch + 4) / 2
        swatchFill.frame = swatchButton.bounds.insetBy(dx: 2, dy: 2)
        swatchFill.layer?.cornerRadius = swatch / 2
        grip.frame = NSRect(x: bounds.width - pad - Tokens.Space.x4, y: 0, width: Tokens.Space.x4, height: bounds.height)
        let b = deleteButton.frame.width
        deleteButton.frame.origin = NSPoint(x: grip.frame.minX - Tokens.Space.x1 - b, y: (bounds.height - b) / 2)
        let nameHeight = name.fittingSize.height
        let x = swatchButton.frame.maxX + Tokens.Space.x2
        name.frame = NSRect(x: x, y: round((bounds.height - nameHeight) / 2), width: deleteButton.frame.minX - x - Tokens.Space.x2, height: nameHeight)
    }

    override func stateDidChange(animated: Bool) {
        deleteButton.isHidden = !isHovered
        grip.alphaValue = isHovered ? 1 : 0.5
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let name = name.stringValue
        guard name != Library.shared.space(spaceID)?.name else { return }
        BrowserWindowController.undoTarget?.libraryChange("Rename Space") { Library.shared.renameSpace(spaceID, to: name) }
    }

    private func openColorPicker() {
        let popover = NSPopover()
        popover.contentViewController = TintPickerController(spaceID: spaceID)
        popover.behavior = .transient
        popover.show(relativeTo: swatchButton.bounds, of: swatchButton, preferredEdge: .maxY)
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

/// The tint row and custom hue slider in a popover, for Settings.
final class TintPickerController: NSViewController {
    private let spaceID: UUID
    private var swatches: [TintSwatch] = []
    private let slider = HueSlider()

    init(spaceID: UUID) {
        self.spaceID = spaceID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let size = Tokens.Space.x6
        let gap = Tokens.Space.x2
        let pad = Tokens.Space.x4
        swatches = SpaceColor.allCases.map { TintSwatch(kind: .tint($0)) } + [TintSwatch(kind: .custom)]
        let width = CGFloat(swatches.count) * size + CGFloat(swatches.count - 1) * gap + pad * 2
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: pad * 2 + size + Tokens.Space.x3 + size))
        for (i, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (size + gap), y: pad, width: size, height: size)
            view.addSubview(swatch)
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let swatch else { return }
                switch swatch.kind {
                case .tint(let color):
                    BrowserWindowController.undoTarget?.libraryChange("Space Color") { Library.shared.setColor(color, for: self.spaceID) }
                    self.slider.hue = color.hue
                case .custom:
                    Library.shared.setHue(self.slider.hue, for: self.spaceID)
                }
                self.refresh()
            }
        }
        slider.frame = NSRect(x: pad, y: pad + size + Tokens.Space.x3, width: width - pad * 2, height: size)
        let space = Library.shared.space(spaceID)
        slider.hue = space?.hue ?? space?.color.hue ?? 0.6
        slider.onChange = { [weak self] hue, final in
            guard let self, final else { return }
            Library.shared.setHue(hue, for: self.spaceID)
            self.refresh()
        }
        view.addSubview(slider)
        self.view = view
        refresh()
    }

    private func refresh() {
        let space = Library.shared.space(spaceID)
        for swatch in swatches {
            switch swatch.kind {
            case .tint(let color): swatch.isSelected = space?.hue == nil && space?.color == color
            case .custom: swatch.isSelected = space?.hue != nil
            }
        }
    }
}

// MARK: - Window

/// Settings in the System Settings style: grouped rows and native controls. What lives here:
/// the search engine, default browser, spaces, extensions, and importing from Arc. Nothing else, on purpose.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let scroll = NSScrollView()
    private let documentView = FlippedView()
    private let generalGroup = FormGroup()
    private let spacesGroup = FormGroup()
    private let importGroup = FormGroup()
    private let passwordsGroup = FormGroup()
    private let privacyGroup = FormGroup()
    private let saveSwitch = NSSwitch()
    private let fillSwitch = NSSwitch()
    private let openPasswordsButton = TextButton.form("Open Passwords…")
    private let blockingSwitch = NSSwitch()
    private let pipSwitch = NSSwitch()
    private let extensionsGroup = FormGroup()
    private let getExtensionsButton = TextButton.form("Get Extensions…")
    private let loadUnpackedButton = TextButton.form("Load Unpacked…")
    private var extensionsToken: SignalToken?
    private let engine = NSPopUpButton()
    private let defaultButton = TextButton.form("Make Default")
    private let defaultStatus = NSTextField(labelWithString: "")
    private let addSpaceButton = TextButton.form("Add Space")
    private var token: SignalToken?
    private let width: CGFloat = 540
    private let banner = BrandBanner()
    private var spaceRows: [SpaceSettingsRow] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = Tokens.Color.formBackground
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

    private func build() {
        engine.addItems(withTitles: SearchEngine.allCases.map(\.name))
        for (item, engine) in zip(engine.itemArray, SearchEngine.allCases) {
            if let icon = FaviconStore.shared.cachedIcon(for: engine.homeURL) { item.image = Self.menuIcon(icon) } else { FaviconStore.shared.prefetch(for: engine.homeURL) }
        }
        engine.target = self
        engine.action = #selector(engineChanged)
        defaultButton.onClick = { [weak self] _ in self?.makeDefault() }
        defaultStatus.textColor = .secondaryLabelColor

        generalGroup.add(FormRow(title: "Search engine", detail: "Used when what you type isn’t an address.", control: engine))
        let defaultControl = NSStackView(views: [defaultStatus, defaultButton])
        defaultControl.spacing = Tokens.Space.x2
        generalGroup.add(FormRow(title: "Default browser", detail: "Links from other apps open here.", control: defaultControl))
        blockingSwitch.controlSize = .small
        blockingSwitch.target = self
        blockingSwitch.action = #selector(blockingChanged)
        // EasyList's licence asks for credit; this is where people look for what does the blocking.
        generalGroup.add(FormRow(title: "Block ads and trackers", detail: "Uses EasyList and EasyPrivacy, by the EasyList authors.", control: blockingSwitch))
        pipSwitch.controlSize = .small
        pipSwitch.target = self
        pipSwitch.action = #selector(pipChanged)
        generalGroup.add(FormRow(title: "Keep videos playing when you switch tabs", detail: "A playing video floats in its own window until you come back.", control: pipSwitch))

        addSpaceButton.onClick = { [weak self] _ in self?.addSpace() }

        getExtensionsButton.onClick = { [weak self] _ in self?.getExtensions() }
        loadUnpackedButton.onClick = { [weak self] _ in self?.loadUnpacked() }

        for toggle in [saveSwitch, fillSwitch] {
            toggle.controlSize = .small
            toggle.target = self
        }
        saveSwitch.action = #selector(saveChanged)
        fillSwitch.action = #selector(fillChanged)
        openPasswordsButton.onClick = { [weak self] _ in self?.openPasswords() }
        reloadPasswords()
        reloadPrivacy()

        let importButton = TextButton.form("Import…")
        importButton.onClick = { [weak self] _ in self?.importBrowser() }
        importGroup.add(FormRow(title: "Import from another browser", detail: "Passwords, bookmarks and history. The other browser isn’t changed.", control: importButton))

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        scroll.useSlimScroller()
        window?.contentView = scroll
        reloadSpaces()
        reloadExtensions()
    }

    private func reloadExtensions() {
        extensionsGroup.removeAllRows()
        defer { layoutDocument() }
        guard #available(macOS 15.4, *) else { return }
        loadUnpackedButton.isHidden = !ExtensionStore.developerMode
        let installed = ExtensionHost.shared.installed.sorted {
            ($0.value.displayName ?? $0.key).localizedCaseInsensitiveCompare($1.value.displayName ?? $1.key) == .orderedAscending
        }
        if installed.isEmpty {
            extensionsGroup.add(FormRow(title: "No extensions yet", detail: "Open one in the Chrome Web Store and choose Add to Zigzag.", control: NSView()))
        }
        for (id, ext) in installed { extensionsGroup.add(extensionRow(id: id, ext: ext)) }
        let developer = NSSwitch()
        developer.controlSize = .small
        developer.state = ExtensionStore.developerMode ? .on : .off
        let developerTarget = SidebarMenus.Handler { [weak self, weak developer] in
            ExtensionStore.developerMode = developer?.state == .on
            self?.reloadExtensions()
        }
        developer.target = developerTarget
        developer.action = #selector(SidebarMenus.Handler.runAction(_:))
        let developerRow = FormRow(title: "Developer mode", detail: "Load an extension from a folder to test it.", control: developer)
        objc_setAssociatedObject(developerRow, "target", developerTarget, .OBJC_ASSOCIATION_RETAIN)
        extensionsGroup.add(developerRow)
    }

    @available(macOS 15.4, *)
    private func extensionRow(id: String, ext: WKWebExtension) -> FormRow {
        var controls: [NSView] = []
        var targets: [AnyObject] = []
        if ExtensionStore.needsApproval(id) {
            let review = TextButton.form("Review Update…")
            review.onClick = { _ in
                guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
                controller.window?.makeKeyAndOrderFront(nil)
                controller.reviewExtensionUpdate(id)
            }
            controls.append(review)
        }
        if ExtensionStore.isUnpacked(id) {
            let reload = IconButton(symbol: "arrow.clockwise", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Reload from Its Folder")
            reload.onClick = { _ in Task { await ExtensionStore.reloadUnpacked(id) } }
            controls.append(reload)
        }
        let remove = IconButton(symbol: "trash", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Remove from Zigzag")
        remove.onClick = { [weak self] _ in self?.confirmRemove(id: id, name: ext.displayName ?? "this extension") }
        controls.append(remove)
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = ExtensionStore.isEnabled(id) ? .on : .off
        let toggleTarget = SidebarMenus.Handler { [weak toggle] in ExtensionStore.setEnabled(id, toggle?.state == .on) }
        toggle.target = toggleTarget
        toggle.action = #selector(SidebarMenus.Handler.runAction(_:))
        controls.append(toggle)
        targets.append(toggleTarget)
        let stack = NSStackView(views: controls)
        stack.spacing = Tokens.Space.x2

        // "Version 1.2 · Unpacked · Won't work here: side panel" — what matters about it at a glance.
        var detail: [String] = [ext.version.map { "Version \($0)" } ?? ""].filter { !$0.isEmpty }
        if ExtensionStore.isUnpacked(id) { detail.append("Unpacked") }
        if ExtensionStore.needsApproval(id) { detail.append("Update wants more access") }
        var limitsNote: String?
        if let manifest = ExtensionStore.manifest(for: id) {
            let limits = ExtensionReport(extension: ext, manifest: manifest, id: id).limits
            if !limits.isEmpty {
                // The count fits the row; the names are a hover away.
                detail.append(limits.count == 1 ? "1 feature won’t work here" : "\(limits.count) features won’t work here")
                let names = limits.map { $0.prefix(1).lowercased() + $0.dropFirst() }
                limitsNote = "Won’t work in Zigzag: " + ListFormatter.localizedString(byJoining: names) + "."
            }
        }
        let row = FormRow(title: ext.displayName ?? id, detail: detail.joined(separator: " · "),
                          icon: ext.icon(for: NSSize(width: 24, height: 24)), control: stack)
        row.toolTip = limitsNote
        objc_setAssociatedObject(row, "targets", targets, .OBJC_ASSOCIATION_RETAIN)
        return row
    }

    @objc private func loadUnpacked() {
        guard #available(macOS 15.4, *), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose the folder that contains the extension’s manifest.json."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await ExtensionStore.loadUnpacked(url) == nil {
                    if let host = window.contentView {
                        ConfirmSheet.notice(in: host, title: "Couldn’t load this extension", message: "That folder needs a manifest.json that Zigzag can read. Choose the folder that holds it.")
                    }
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
        layoutDocument()
    }

    private func layoutDocument() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let pad = Tokens.Space.x6
        let contentWidth = width - pad * 2
        // The header: a wash of the space's color under the title, fading into the form.
        banner.title = "Settings"
        banner.titleSize = 30
        banner.contentInset = pad + Tokens.Space.x1
        banner.frame = NSRect(x: 0, y: 0, width: width, height: 104)
        documentView.addSubview(banner, positioned: .below, relativeTo: nil)
        var y: CGFloat = banner.frame.maxY + Tokens.Space.x2

        func section(_ title: String?, _ group: FormGroup, accessory: NSView? = nil) {
            if let title {
                let label = header(title)
                label.frame = NSRect(x: pad + Tokens.Space.x1, y: y, width: contentWidth - (accessory?.fittingSize.width ?? 0) - Tokens.Space.x4, height: label.lineHeight)
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

        section(nil, generalGroup)
        section("Spaces", spacesGroup, accessory: addSpaceButton)
        if #available(macOS 15.4, *) {
            let buttons = NSStackView(views: [loadUnpackedButton, getExtensionsButton])
            buttons.spacing = Tokens.Space.x2
            section("Extensions", extensionsGroup, accessory: buttons)
        }
        section("Passwords", passwordsGroup, accessory: openPasswordsButton)
        section("Privacy", privacyGroup)
        if !importGroup.rows.isEmpty { section(nil, importGroup) }

        documentView.frame = NSRect(x: 0, y: 0, width: width, height: y)
        guard let window else { return }
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(y, maxHeight * 0.85)
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: width, height: height))
        if window.isVisible { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private func refresh() {
        for (item, engine) in zip(engine.itemArray, SearchEngine.allCases) where item.image == nil {
            item.image = FaviconStore.shared.cachedIcon(for: engine.homeURL).map(Self.menuIcon)
        }
        engine.selectItem(withTitle: Library.shared.searchEngine.name)
        let isDefault = Self.isDefaultBrowser
        defaultStatus.stringValue = "Zigzag opens your links"
        defaultStatus.isHidden = !isDefault
        blockingSwitch.state = ContentBlocker.isEnabled ? .on : .off
        pipSwitch.state = PictureInPicture.followsTabs ? .on : .off
        saveSwitch.state = PasswordCapture.offersToSave ? .on : .off
        fillSwitch.state = Autofill.isOn ? .on : .off
        defaultButton.isHidden = isDefault
        generalGroup.rows.forEach { $0.needsLayout = true }
    }

    func show() {
        refresh()
        reloadSpaces()
        reloadExtensions()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        row.layer?.backgroundColor = row.cgColor(Tokens.Color.formGroup)
        row.layer?.cornerRadius = Tokens.Radius.row
        row.layer?.shadowOpacity = 1
        row.layer?.shadowRadius = 8
        row.layer?.shadowColor = row.cgColor(Tokens.Color.panelShadow)
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

    @objc private func engineChanged() {
        if let engine = SearchEngine.allCases.first(where: { $0.name == engine.titleOfSelectedItem }) {
            Library.shared.searchEngine = engine
        }
    }

    @objc private func makeDefault() {
        DefaultBrowser.make()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    @objc private func addSpace() { BrowserWindowController.undoTarget?.libraryChange("New Space") { Library.shared.addSpace() } }

    @objc private func importBrowser() { ImportWindowController.show() }

    @objc private func blockingChanged() { ContentBlocker.isEnabled = blockingSwitch.state == .on }

    @objc private func pipChanged() { PictureInPicture.followsTabs = pipSwitch.state == .on }

    /// When a password-manager extension is on, Zigzag's own saving and filling start off, and say why.
    private func reloadPasswords() {
        passwordsGroup.removeAllRows()
        saveSwitch.state = PasswordCapture.offersToSave ? .on : .off
        fillSwitch.state = Autofill.isOn ? .on : .off
        let manager = PasswordManagers.active
        let saveNote = manager != nil && !PasswordCapture.offersToSave ? "Off while \(manager!) handles passwords. Turn on to use both." : "After you sign in. Kept in your Keychain, synced with iCloud."
        let fillNote = manager != nil && !Autofill.isOn ? "Off while \(manager!) handles passwords. Turn on to use both." : "Under sign-in fields, only on the site each was saved for."
        passwordsGroup.add(FormRow(title: "Offer to save passwords", detail: saveNote, control: saveSwitch))
        passwordsGroup.add(FormRow(title: "Fill saved passwords", detail: fillNote, control: fillSwitch))
    }

    @objc private func saveChanged() {
        PasswordCapture.offersToSave = saveSwitch.state == .on
        reloadPasswords()
        layoutDocument()
    }

    @objc private func fillChanged() {
        Autofill.isOn = fillSwitch.state == .on
        if !Autofill.isOn { Autofill.shared.hide() }
        reloadPasswords()
        layoutDocument()
    }

    @objc private func openPasswords() { PasswordsWindowController.show() }

    // MARK: Privacy

    /// History, website data, and every per-site decision you've made, in one place. Each button says what it
    /// did, right where you clicked.
    private func reloadPrivacy() {
        privacyGroup.removeAllRows()
        let history = TextButton.form("Clear History…")
        history.onClick = { [weak self, weak history] _ in
            self?.confirm(title: "Clear all history?", message: "Every page you’ve visited is forgotten on this Mac, and the command bar stops suggesting them. Tabs, bookmarks and passwords stay.",
                          action: "Clear History") {
                HistoryStore.shared.clearAll()
                history?.flash("Cleared")
            }
        }
        privacyGroup.add(FormRow(title: "History", detail: "The pages you’ve visited, used for suggestions in the command bar.", control: history))

        let cache = TextButton.form("Clear Cache")
        cache.onClick = { [weak cache] _ in
            Task { @MainActor in
                await WebsiteData.clear(.cache)
                cache?.flash("Cleared")
            }
        }
        let cookies = TextButton.form("Clear Cookies…")
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
        let parts = [phrase(ads, "Ads allowed"), phrase(extensions, "extensions off"), phrase(media, "camera and microphone choices"), phrase(zoom, "zoom set")].compactMap { $0 }
        let reset = TextButton.form("Reset All…")
        reset.isEnabled = !parts.isEmpty
        reset.onClick = { [weak self] _ in
            self?.confirm(title: "Reset every site’s exceptions?", message: "Ads are blocked again everywhere, extensions run on every site, sites ask again for your camera and microphone, and zoom goes back to 100%.",
                          action: "Reset All") {
                ContentBlocker.allowedSites = []
                ExtensionStore.extensionsOffSites = []
                SitePermissions.forgetAll()
                ZoomLevels.resetAll()
                self?.reloadPrivacy()
                self?.layoutDocument()
            }
        }
        let summary = parts.isEmpty ? "None yet. Choices you make for one site, like allowing ads or a camera, show up here."
            : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst() + "."
        privacyGroup.add(FormRow(title: "Site exceptions", detail: summary, control: reset))
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

    @objc private func getExtensions() {
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
