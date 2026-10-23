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
        let cw = (control as? SwatchPicker)?.fittingWidth ?? (control as? TextButton)?.fittingWidth ?? (control as? SettingsMenuButton)?.fittingWidth ?? controlSize.width
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

/// Settings: the two things there are to set (search engine and space colors), plus Arc import
/// and making Zigzag your default browser. Nothing else, on purpose.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let content = ColorView(color: Tokens.Color.panelBackground)
    private var token: SignalToken?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = content
        token = Library.shared.changed.observe { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.rebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        rebuild()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func section(_ text: String) -> Label {
        Label(text, font: Tokens.Font.small(.semibold), color: Tokens.Color.textSecondary)
    }

    private func rebuild() {
        content.subviews.forEach { $0.removeFromSuperview() }
        let pad = Tokens.Space.x8
        let width: CGFloat = 520
        var y: CGFloat = Tokens.Space.x12

        func place(_ view: NSView, height: CGFloat) {
            view.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: height)
            content.addSubview(view)
            y += height
        }

        // Search engine
        let general = section("BROWSER")
        place(general, height: Tokens.Space.x6)
        let engine = SettingsMenuButton()
        engine.value = Library.shared.searchEngine.name
        engine.options = SearchEngine.allCases.map { e in (e.name, { Library.shared.searchEngine = e; engine.value = e.name }) }
        place(SettingsRow(title: "Search engine", detail: "Used when what you type isn’t an address.", control: engine), height: SettingsRow.height)

        let isDefault = Self.isDefaultBrowser
        let defaultButton = TextButton(title: isDefault ? "Zigzag is your default" : "Make Default", font: Tokens.Font.body(.medium))
        defaultButton.isEnabled = !isDefault
        defaultButton.showsFillAtRest = !isDefault
        defaultButton.onClick = { [weak self] _ in
            DefaultBrowser.make()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.rebuild() }
        }
        place(SettingsRow(title: "Default browser", detail: "Open links from other apps in Zigzag.", control: defaultButton), height: SettingsRow.height)

        if ArcImporter.isAvailable {
            let arc = TextButton(title: Library.shared.importedFromArc ? "Import Again" : "Import", font: Tokens.Font.body(.medium))
            arc.showsFillAtRest = true
            arc.onClick = { _ in ArcImporter.runInteractive() }
            place(SettingsRow(title: "Arc", detail: "Spaces, pinned tabs and history.", control: arc), height: SettingsRow.height)
        }

        y += Tokens.Space.x4
        place(section("SPACES"), height: Tokens.Space.x6)
        for space in Library.shared.spaces {
            let picker = SwatchPicker(selected: space.color)
            picker.onPick = { color in Library.shared.setColor(color, for: space.id) }
            place(SettingsRow(title: space.name, control: picker), height: SettingsRow.height)
        }
        y += Tokens.Space.x6

        // Fit the window to its content, keeping the top edge where it is.
        guard let window else { return }
        var frame = window.frame
        let contentHeight = y
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: window.isVisible)
        content.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
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
