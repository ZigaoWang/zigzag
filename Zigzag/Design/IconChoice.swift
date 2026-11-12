import AppKit

/// An icon you can give a folder or a space: one of a short list of SF Symbols, or any emoji.
enum IconChoice {
    /// Enough to tell work, study, money, making things and the rest apart at a glance.
    static let symbols: [String] = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "moon.fill", "sun.max.fill", "sparkles",
        "house.fill", "briefcase.fill", "building.2.fill", "graduationcap.fill", "book.fill", "bookmark.fill", "newspaper.fill", "lightbulb.fill",
        "chevron.left.forwardslash.chevron.right", "terminal.fill", "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.fill", "paintpalette.fill", "camera.fill", "film.fill",
        "music.note", "gamecontroller.fill", "figure.run", "airplane", "car.fill", "map.fill", "globe.americas.fill", "cloud.fill",
        "cart.fill", "bag.fill", "creditcard.fill", "chart.bar.fill", "envelope.fill", "bubble.left.fill", "person.2.fill", "calendar",
        "checkmark.circle.fill", "brain.head.profile", "cup.and.saucer.fill", "fork.knife", "pawprint.fill", "flag.fill", "lock.fill",
    ]

    static func isSymbol(_ icon: String) -> Bool { NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil }

    /// The icon at `size`: a symbol as a template, so it takes the color of the text around it; an emoji in its own.
    static func image(_ icon: String, size: CGFloat) -> NSImage {
        if isSymbol(icon) { return Tokens.Symbol.image(icon, size: size) }
        return emoji(icon, size: size)
    }

    /// The icons made for pages so far, by icon: each one made once and kept, so a row set again with the same icon
    /// gets the same image and draws nothing new.
    private static var pageIcons: [String: NSImage] = [:]
    private static var pageIconIDs: Set<ObjectIdentifier> = []

    /// An icon you gave a tab, a pinned page or a favorite, in a favicon's square: a symbol as a template, so whatever
    /// draws it gives it the ink around it; an emoji in its own colors.
    static func pageIcon(_ icon: String) -> NSImage {
        if let made = pageIcons[icon] { return made }
        let side = Tokens.Sidebar.favicon
        let image: NSImage
        if isSymbol(icon) {
            let symbol = Tokens.Symbol.image(icon, size: Tokens.Symbol.row)
            // A wide symbol shrinks to fit the square rather than spilling out of it.
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let size = symbol.size, scale = min(1, rect.width / max(size.width, 1), rect.height / max(size.height, 1))
                let w = size.width * scale, h = size.height * scale
                symbol.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                return true
            }
            image.isTemplate = true
        } else {
            image = emoji(icon, size: side)
        }
        pageIcons[icon] = image
        pageIconIDs.insert(ObjectIdentifier(image))
        return image
    }

    /// Whether an image is one of `pageIcon`'s: drawn as chosen, never taken for a site's icon.
    static func isPageIcon(_ image: NSImage) -> Bool { pageIconIDs.contains(ObjectIdentifier(image)) }

    /// Exactly `size` square, like a symbol of that size, so it lines up wherever a symbol would. An emoji's glyph
    /// runs wider than its font size, so it's set a little smaller and centered on its own ink.
    private static func emoji(_ text: String, size: CGFloat) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
        let ink = string.boundingRect(with: NSSize(width: size * 4, height: size * 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            string.draw(at: NSPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY))
            return true
        }
    }

    /// A folder with its icon inside. Closed, the folder is solid and the icon cut out of it; open, it's an outline
    /// with the icon drawn in. An emoji can't take the folder's color, so it stands on its own.
    static func folder(_ icon: String?, open: Bool, size: CGFloat) -> NSImage {
        let folder = Tokens.Symbol.image(open ? "folder" : "folder.fill", size: size)
        guard let icon else { return folder }
        guard isSymbol(icon) else { return emoji(icon, size: size) }
        let glyph = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.46, weight: .bold)) ?? NSImage()
        let image = NSImage(size: folder.size, flipped: false) { rect in
            folder.draw(in: rect)
            // Into the body of the folder, below its tab.
            let g = glyph.size
            let spot = NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2 - rect.height * 0.06, width: g.width, height: g.height)
            if open {
                glyph.draw(in: spot)
            } else {
                glyph.draw(in: spot, from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The choices in a grid, with the plain look first and a field for an emoji under them.
final class IconGrid: NSView, NSTextFieldDelegate {
    /// What "none" looks like here: a folder, or a space's dot.
    private let noneSymbol: String
    var selected: String? { didSet { refresh() } }
    var onPick: ((String?) -> Void)?

    private var cells: [IconButton] = []
    private let emojiField = FilledField(placeholder: String(localized: "Or type an emoji", comment: "Placeholder of the field under the icon choices, for a space's or a folder's icon."))

    static let columns = 8
    static let cell: CGFloat = 30
    static let gap: CGFloat = Tokens.Space.x1
    static let fieldHeight: CGFloat = 30

    static var width: CGFloat { CGFloat(columns) * cell + CGFloat(columns - 1) * gap }
    static var height: CGFloat {
        let rows = (IconChoice.symbols.count + 1 + columns - 1) / columns
        return CGFloat(rows) * cell + CGFloat(rows - 1) * gap + Tokens.Space.x3 + fieldHeight
    }

    /// `noneToolTip`: what the plain choice says it is, where that's more than no icon (a page's: its site's).
    init(noneSymbol: String, noneToolTip: String? = nil, selected: String?) {
        self.noneSymbol = noneSymbol
        self.selected = selected
        super.init(frame: .zero)
        let none = IconButton(symbol: noneSymbol, size: Self.cell, symbolSize: Tokens.Symbol.row,
                              toolTip: noneToolTip ?? String(localized: "No Icon", comment: "Tooltip of the choice that takes a space's or a folder's icon away."))
        none.onClick = { [weak self] _ in self?.pick(nil) }
        cells = [none] + IconChoice.symbols.map { name in
            let button = IconButton(symbol: name, size: Self.cell, symbolSize: Tokens.Symbol.row, toolTip: nil)
            // Clicking the chosen one again takes it away, back to no icon (a page's own site icon).
            button.onClick = { [weak self] _ in self.map { $0.pick(Self.toggled(name, from: $0.selected)) } }
            return button
        }
        // The chosen icon is the soft card, as the chosen row is anywhere.
        cells.forEach { $0.selectsAsCard = true; addSubview($0) }
        emojiField.field.delegate = self
        if let selected, !IconChoice.isSymbol(selected) { emojiField.stringValue = selected }
        addSubview(emojiField)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func pick(_ icon: String?) {
        selected = icon
        if icon.map(IconChoice.isSymbol) != false { emojiField.stringValue = "" }
        onPick?(icon)
    }

    private func refresh() {
        for (i, cell) in cells.enumerated() {
            let name: String? = i == 0 ? nil : IconChoice.symbols[i - 1]
            cell.isSelected = name == selected || (i == 0 && selected == nil)
        }
    }

    override func layout() {
        super.layout()
        for (i, cell) in cells.enumerated() {
            let row = i / Self.columns, column = i % Self.columns
            cell.frame = NSRect(x: CGFloat(column) * (Self.cell + Self.gap), y: CGFloat(row) * (Self.cell + Self.gap),
                                width: Self.cell, height: Self.cell)
        }
        let y = (cells.last?.frame.maxY ?? 0) + Tokens.Space.x3
        emojiField.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.fieldHeight)
    }

    /// The last emoji typed is the icon; anything that isn't one is left out.
    func controlTextDidChange(_ obj: Notification) {
        let composing = (emojiField.field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        guard let emoji = Self.lastEmoji(in: emojiField.stringValue) else {
            // Letters, or a digit or a symbol on its own, don't stay in the field as if they were the icon.
            // (Not while an input method is still composing: that text isn't settled.)
            guard !composing else { return }
            emojiField.stringValue = ""
            // The emoji deleted: back to no icon (a page's own site icon), as the plain choice does.
            if Self.clearsEmoji(text: emojiField.stringValue, selected: selected) { pick(nil) }
            return
        }
        emojiField.stringValue = emoji
        selected = emoji
        onPick?(emoji)
    }

    /// What a click on a symbol picks: that symbol, or nothing when it's the one already chosen.
    static func toggled(_ symbol: String, from selected: String?) -> String? {
        symbol == selected ? nil : symbol
    }

    /// Whether an edit to the field takes the icon away: an emoji was the icon and the field is now empty. A symbol
    /// chosen from the grid isn't in the field, so emptying it leaves that alone.
    static func clearsEmoji(text: String, selected: String?) -> Bool {
        text.isEmpty && selected.map { !IconChoice.isSymbol($0) } == true
    }

    /// The last emoji in some text: one that shows as an emoji on its own (😀), a symbol asked to (❤️ ☀️ ✈️, with
    /// U+FE0F) or a keycap (1️⃣); never a plain digit, "#" or "*", which Unicode also counts as emoji.
    static func lastEmoji(in text: String) -> String? {
        text.reversed().first { character in
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
            return scalars.contains { $0.properties.isEmoji } && scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
        }.map(String.init)
    }
}

/// The grid in a small floating panel, for a folder, a tab, a pinned page or a favorite in the sidebar.
final class IconPickerPanel: FloatingPanelView {
    private let grid: IconGrid
    private var monitor: Any?
    private let pad = Tokens.Space.x3
    static weak var current: IconPickerPanel?

    init(noneSymbol: String, noneToolTip: String? = nil, selected: String?, onPick: @escaping (String?) -> Void) {
        grid = IconGrid(noneSymbol: noneSymbol, noneToolTip: noneToolTip, selected: selected)
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        grid.onPick = onPick
        addSubview(grid)
        onLayout = { [weak self] in
            guard let self else { return }
            self.grid.frame = NSRect(x: self.pad, y: self.pad, width: IconGrid.width, height: IconGrid.height)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Beside the sidebar, level with the row it's for.
    func show(beside row: NSView, in overlay: NSView, x: CGFloat) {
        IconPickerPanel.current?.close()
        let rowFrame = row.convert(row.bounds, to: overlay)
        let size = NSSize(width: IconGrid.width + pad * 2, height: IconGrid.height + pad * 2)
        let top = max(Tokens.Space.x2, min(rowFrame.minY - Tokens.Space.x2, overlay.bounds.height - size.height - Tokens.Space.x2))
        frame = NSRect(origin: NSPoint(x: x, y: top), size: size)
        overlay.addSubview(self)
        growsFrom = CGPoint(x: 0, y: 0.1)
        present(arrival: .pop)
        IconPickerPanel.current = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Mid-word in an input method (the emoji field takes any text), Esc belongs to it.
                if event.keyCode == 53, event.window === self.window,
                   (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true { self.close(); return nil }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dismiss()
        if IconPickerPanel.current === self { IconPickerPanel.current = nil }
    }
}
