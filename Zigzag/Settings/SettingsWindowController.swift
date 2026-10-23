import AppKit

/// A row of round color swatches. Clicking one picks it.
final class SwatchPicker: NSView {
    var selected: SpaceColor { didSet { needsDisplay = true; refresh() } }
    var onPick: ((SpaceColor) -> Void)?
    private var buttons: [SwatchButton] = []
    static let size = Tokens.Space.x5
    static let gap = Tokens.Space.x2

    init(selected: SpaceColor) {
        self.selected = selected
        super.init(frame: .zero)
        buttons = SpaceColor.allCases.map { color in
            let button = SwatchButton(color: color)
            button.onClick = { [weak self] _ in
                self?.selected = color
                self?.onPick?(color)
            }
            addSubview(button)
            return button
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat { CGFloat(buttons.count) * Self.size + CGFloat(buttons.count - 1) * Self.gap }

    override func layout() {
        super.layout()
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(i) * (Self.size + Self.gap), y: (bounds.height - Self.size) / 2, width: Self.size, height: Self.size)
        }
    }

    private func refresh() { buttons.forEach { $0.isSelected = $0.color == selected } }

    /// No curated tint is chosen (a custom hue is in use).
    func clearSelection() { buttons.forEach { $0.isSelected = false } }
}

final class SwatchButton: InteractiveView {
    let color: SpaceColor
    private let fill = CALayer()
    private let ring = CALayer()

    init(color: SpaceColor) {
        self.color = color
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        toolTip = color.name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(color.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            ring.frame = bounds
            ring.cornerRadius = bounds.width / 2
            ring.borderWidth = 2
            ring.borderColor = cgColor(isSelected ? Tokens.Color.textPrimary : (isHovered ? Tokens.Color.textTertiary : .clear))
            let inset: CGFloat = isSelected || isHovered ? 4 : 2
            fill.frame = bounds.insetBy(dx: inset, dy: inset)
            fill.cornerRadius = fill.frame.width / 2
            fill.backgroundColor = cgColor(color.swatch)
        }
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// A row in the settings window: a label on the left, a control on the right.
final class SettingsRow: NSView {
    let title: Label
    let detail: Label?
    let control: NSView

    init(title: String, detail: String? = nil, control: NSView) {
        self.title = Label(title, font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
        self.detail = detail.map { Label($0, font: Tokens.Font.small(), color: Tokens.Color.textSecondary) }
        self.control = control
        super.init(frame: .zero)
        addSubview(self.title)
        if let d = self.detail { addSubview(d) }
        addSubview(control)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let height = Tokens.Space.x12

    override func layout() {
        super.layout()
        let controlSize = control.fittingSize.width > 0 ? control.fittingSize : control.frame.size
        let cw = (control as? SwatchPicker)?.fittingWidth ?? (control as? TextButton)?.fittingWidth ?? (control as? SettingsMenuButton)?.fittingWidth ?? (control as? Label)?.textWidth ?? controlSize.width
        let ch = (control is SwatchPicker) ? SwatchPicker.size + 8 : Tokens.Space.x8
        control.frame = NSRect(x: bounds.width - cw, y: (bounds.height - ch) / 2, width: cw, height: ch)
        let available = control.frame.minX - Tokens.Space.x4
        if let detail {
            let total = title.lineHeight + detail.lineHeight
            title.frame = NSRect(x: 0, y: (bounds.height - total) / 2, width: available, height: title.lineHeight)
            detail.frame = NSRect(x: 0, y: title.frame.maxY, width: available, height: detail.lineHeight)
        } else {
            title.frame = NSRect(x: 0, y: (bounds.height - title.lineHeight) / 2, width: available, height: title.lineHeight)
        }
    }
}

/// A button that shows the current choice and opens a native menu of options.
final class SettingsMenuButton: InteractiveView {
    private let label = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let chevron = NSImageView()
    var options: [(String, () -> Void)] = []
    var value: String = "" { didSet { label.stringValue = value; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        chevron.image = Tokens.Symbol.image("chevron.up.chevron.down", size: Tokens.TypeSize.small)
        chevron.contentTintColor = Tokens.Color.textSecondary
        chevron.imageScaling = .scaleNone
        addSubview(label)
        addSubview(chevron)
        onClick = { [weak self] _ in self?.showMenu() }
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { Tokens.Space.x3 + label.textWidth + Tokens.Space.x1 + Tokens.Space.x3 + Tokens.Space.x2 }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x3, y: (bounds.height - h) / 2, width: label.textWidth, height: h)
        chevron.frame = NSRect(x: bounds.width - Tokens.Space.x3 - Tokens.Space.x2, y: 0, width: Tokens.Space.x3, height: bounds.height)
    }

    override func stateDidChange(animated: Bool) {
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
    }

    private func showMenu() {
        let menu = NSMenu()
        for (title, action) in options {
            let item = SidebarMenus.Item(title, action)
            item.state = title == value ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: bounds.height - 4), in: self)
    }
}

/// A choice chip (search engines): filled when chosen.
final class ChipButton: InteractiveView {
    private let label: Label

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x5 }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: (bounds.width - label.textWidth) / 2, y: (bounds.height - h) / 2, width: label.textWidth, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor = isSelected ? Tokens.Color.accent : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: false)
        label.textColor = isSelected ? .white : Tokens.Color.textPrimary
        setAccessibilityValue(isSelected ? "selected" : nil)
    }
}

/// A rounded group of rows with hairlines between them.
final class SettingsCard: ColorView {
    private var rows: [NSView] = []
    private var lines: [ColorView] = []

    init() {
        super.init(color: Tokens.Color.fieldFill)
        layer?.cornerRadius = Tokens.Radius.panel
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ row: NSView) {
        if !rows.isEmpty {
            let line = ColorView(color: Tokens.Color.separator)
            lines.append(line)
            addSubview(line)
        }
        rows.append(row)
        addSubview(row)
    }

    var fittingHeight: CGFloat { CGFloat(rows.count) * SettingsRow.height }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x4
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: pad, y: CGFloat(i) * SettingsRow.height, width: bounds.width - pad * 2, height: SettingsRow.height)
        }
        for (i, line) in lines.enumerated() {
            line.frame = NSRect(x: pad, y: CGFloat(i + 1) * SettingsRow.height, width: bounds.width - pad, height: Tokens.Metric.hairline)
        }
    }
}

/// Settings: the search engine, default browser and Arc import. Spaces are edited where they live,
/// at the dots in the sidebar. Nothing else, on purpose.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let content = ColorView(color: Tokens.Color.panelBackground)
    private let width: CGFloat = 480

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        rebuild()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func rebuild() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let pad = Tokens.Space.x6
        var y: CGFloat = Tokens.Space.x12

        // Identity: icon, name, version.
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.frame = NSRect(x: (width - 64) / 2, y: y, width: 64, height: 64)
        content.addSubview(icon)
        y = icon.frame.maxY + Tokens.Space.x2
        let name = Label("Zigzag", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
        name.alignment = .center
        name.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: name.lineHeight)
        content.addSubview(name)
        y = name.frame.maxY
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = Label("Version \(version)", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: pad, y: y + Tokens.Space.x1, width: width - pad * 2, height: versionLabel.lineHeight)
        content.addSubview(versionLabel)
        y = versionLabel.frame.maxY + Tokens.Space.x8

        // Search engine: chips, one tap to choose.
        let searchTitle = Label("Search with", font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
        searchTitle.frame = NSRect(x: pad + Tokens.Space.x1, y: y, width: 200, height: searchTitle.lineHeight)
        content.addSubview(searchTitle)
        y = searchTitle.frame.maxY + Tokens.Space.x2
        let chips = SearchEngine.allCases.map { engine -> ChipButton in
            let chip = ChipButton(title: engine.name)
            chip.isSelected = Library.shared.searchEngine == engine
            chip.onClick = { [weak self] _ in
                Library.shared.searchEngine = engine
                self?.rebuild()
            }
            return chip
        }
        let chipHeight = Tokens.Space.x8
        let gap = Tokens.Space.x2
        var x = pad
        for chip in chips {
            let w = chip.fittingWidth
            if x + w > width - pad { x = pad; y += chipHeight + gap }
            chip.frame = NSRect(x: x, y: y, width: w, height: chipHeight)
            content.addSubview(chip)
            x += w + gap
        }
        y += chipHeight + Tokens.Space.x6

        // Default browser and Arc, grouped.
        let card = SettingsCard()
        let isDefault = Self.isDefaultBrowser
        let defaultControl: NSView
        if isDefault {
            let done = Label("Default", font: Tokens.Font.body(.medium), color: Tokens.Color.textTertiary)
            done.frame.size = NSSize(width: done.textWidth, height: Tokens.Space.x8)
            defaultControl = done
        } else {
            let button = TextButton(title: "Make Default", font: Tokens.Font.body(.medium))
            button.showsFillAtRest = true
            button.onClick = { [weak self] _ in
                DefaultBrowser.make()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.rebuild() }
            }
            defaultControl = button
        }
        card.add(SettingsRow(title: "Default browser", detail: "Links from other apps open here.", control: defaultControl))
        if ArcImporter.isAvailable {
            let arc = TextButton(title: Library.shared.importedFromArc ? "Import Again" : "Import", font: Tokens.Font.body(.medium))
            arc.showsFillAtRest = true
            arc.onClick = { _ in ArcImporter.runInteractive() }
            card.add(SettingsRow(title: "Arc", detail: "Spaces, pinned tabs and history.", control: arc))
        }
        card.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: card.fittingHeight)
        content.addSubview(card)
        y = card.frame.maxY + Tokens.Space.x4

        let hint = Label("Click a space’s dot in the sidebar to rename it or change its color.", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
        hint.alignment = .center
        hint.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: hint.lineHeight)
        content.addSubview(hint)
        y = hint.frame.maxY + Tokens.Space.x6

        guard let window else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: y))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true)
        content.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    static var isDefaultBrowser: Bool {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

enum DefaultBrowser {
    static func make() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
    }
}
