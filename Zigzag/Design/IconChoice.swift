import AppKit

/// A folder or space icon: an SF Symbol from a short list, or an emoji. Pages may also use an image file
/// (`PageImageIcon`).
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

    /// An emoji: neither a symbol nor an image file.
    static func isEmoji(_ icon: String) -> Bool { !PageImageIcon.isImage(icon) && !isSymbol(icon) }

    /// Symbols as templates, taking the surrounding text color; emoji and images in their own colors.
    static func image(_ icon: String, size: CGFloat) -> NSImage {
        if isSymbol(icon) { return Tokens.Symbol.image(icon, size: size) }
        if PageImageIcon.isImage(icon) { return PageImageIcon.image(icon, points: size) ?? Tokens.Symbol.image("globe", size: size) }
        return emoji(icon, size: size)
    }

    /// The icons made for pages so far, by icon: each one made once and kept, so a row set again with the same icon
    /// gets the same image and draws nothing new.
    private static var pageIcons: [String: NSImage] = [:]
    private static var pageIconIDs: Set<ObjectIdentifier> = []

    /// A tab, pinned page or favorite icon in a favicon square: symbols as templates, emoji and images in their own
    /// colors. A missing image file shows the globe.
    static func pageIcon(_ icon: String) -> NSImage {
        if let made = pageIcons[icon] { return made }
        let side: CGFloat = 16
        let image: NSImage
        if PageImageIcon.isImage(icon) {
            guard let kept = PageImageIcon.image(icon, points: side) else { return pageIcon("globe") }
            image = kept
        } else if isSymbol(icon) {
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
        centered(emojiText(text, fontSize: size * 0.8), key: "emoji \(text) \(size * 0.8)", side: size, template: false)
    }

    /// An emoji set at `fontSize` on an image of its own, with room around it.
    private static func emojiText(_ text: String, fontSize: CGFloat) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let side = ceil(fontSize * 2)
        let box = string.boundingRect(with: NSSize(width: side * 2, height: side * 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            string.draw(at: NSPoint(x: rect.midX - box.midX, y: rect.midY - box.midY))
            return true
        }
    }

    /// `image` on a `side` square with its ink, not its image, in the middle.
    private static func centered(_ image: NSImage, key: String, side: CGFloat, template: Bool) -> NSImage {
        // Measured as drawn at 2x, then moved by whole pixels so it draws the same.
        let ink = Tokens.Symbol.inkOffset(of: placed(image, side: side, shift: .zero), key: "placed \(key) \(side)", scale: 2)
        let result = placed(image, side: side, shift: CGSize(width: (ink.width * 2).rounded() / 2, height: (ink.height * 2).rounded() / 2))
        result.isTemplate = template
        return result
    }

    /// `image` in the middle of a `side` square, moved by `shift`.
    private static func placed(_ image: NSImage, side: CGFloat, shift: CGSize) -> NSImage {
        let size = image.size
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: NSRect(x: rect.midX - size.width / 2 - shift.width, y: rect.midY - size.height / 2 - shift.height,
                                  width: size.width, height: size.height))
            return true
        }
    }

    /// How much of a mark's square its ink takes, by the ink's geometric mean side.
    static let markInk: CGFloat = 0.8

    /// The scale that brings `ink`'s geometric mean side to `markInk` of `side`, its longer side never past `side`.
    static func markScale(ink: CGSize, side: CGFloat) -> CGFloat {
        guard ink.width > 0, ink.height > 0 else { return 1 }
        return min(markInk * side / (ink.width * ink.height).squareRoot(), side / max(ink.width, ink.height))
    }

    /// A space's icon on a `side` square: sized by its ink, so a flame and a book read alike, with its ink in the middle.
    static func mark(_ icon: String, side: CGFloat) -> NSImage {
        if PageImageIcon.isImage(icon) { return image(icon, size: side) }
        let symbol = isSymbol(icon)
        let draw: (CGFloat) -> NSImage = { symbol ? Tokens.Symbol.image(icon, size: $0) : emojiText(icon, fontSize: $0) }
        let key: (CGFloat) -> String = { "mark \(icon) \($0)" }
        let base = side
        let ink = Tokens.Symbol.inkSize(of: placed(draw(base), side: side * 2, shift: .zero), key: "placed \(key(base)) \(side * 2)", scale: 2)
        let size = (base * markScale(ink: ink, side: side) * 4).rounded() / 4
        return centered(draw(size), key: key(size), side: side, template: symbol)
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

/// The choices in a grid, with the plain look first and a field under them that takes an emoji, or finds one by
/// name (#163): while there's a search, the grid shows the emoji that match in the symbols' place.
final class IconGrid: NSView, NSTextFieldDelegate {
    /// What "none" looks like here: a folder, or a space's dot.
    private let noneSymbol: String
    var selected: String? { didSet { refresh() } }
    var onPick: ((String?) -> Void)?

    private var cells: [IconButton] = []
    private let emojiField = FilledField(placeholder: String(localized: "Search or type an emoji", comment: "Placeholder of the field under the icon choices (a space's, a folder's or a page's icon): type an emoji's name to find it, or the emoji itself."))
    /// The emoji the field shows as the icon, if it's one: letters typed beside it start a search.
    private var shownEmoji: String?
    /// What's being searched for, as typed; nil when the field is empty or shows the icon.
    private(set) var query: String?
    /// The emoji found, best first, in the grid's place.
    private(set) var results: [EmojiSearch.Entry] = []
    private let resultsScroll = NSScrollView()
    private let resultsList = FlippedView()
    private var resultCells: [IconButton] = []
    private let noResults = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)

    static let columns = 8
    static let cell: CGFloat = 30
    static let gap: CGFloat = Tokens.Space.x1
    static let fieldHeight: CGFloat = 30
    /// How big an emoji found by name is drawn in its cell.
    static let resultSide: CGFloat = 20

    static var width: CGFloat { CGFloat(columns) * cell + CGFloat(columns - 1) * gap }
    static var gridHeight: CGFloat {
        let rows = (IconChoice.symbols.count + 1 + columns - 1) / columns
        return CGFloat(rows) * cell + CGFloat(rows - 1) * gap
    }
    static var height: CGFloat { gridHeight + Tokens.Space.x3 + fieldHeight }

    /// `noneToolTip`: what the plain choice says it is, where that's more than no icon (a page's: its site's).
    /// `noneImage`: what the plain choice shows when it's a picture of its own (a page's: its site's icon, so it reads
    /// as "the site's icon" rather than one more icon to pick).
    init(noneSymbol: String, noneImage: NSImage? = nil, noneToolTip: String? = nil, selected: String?) {
        self.noneSymbol = noneSymbol
        self.selected = selected
        super.init(frame: .zero)
        let none = IconButton(symbol: noneSymbol, size: Self.cell, symbolSize: Tokens.Symbol.row,
                              toolTip: noneToolTip ?? String(localized: "No Icon", comment: "Tooltip of the choice that takes a space's or a folder's icon away."))
        if let noneImage { none.image = noneImage }
        none.onClick = { [weak self] _ in self?.pick(nil) }
        cells = [none] + IconChoice.symbols.map { name in
            let button = IconButton(symbol: name, size: Self.cell, symbolSize: Tokens.Symbol.row, toolTip: nil)
            // Clicking the chosen one again takes it away, back to no icon (a page's own site icon).
            button.onClick = { [weak self] _ in self.map { $0.pick(Self.toggled(name, from: $0.selected)) } }
            return button
        }
        // The chosen icon is the soft card, as the chosen row is anywhere.
        cells.forEach { $0.selectsAsCard = true; addSubview($0) }
        resultsScroll.drawsBackground = false
        resultsScroll.documentView = resultsList
        resultsScroll.useSlimScroller()
        resultsScroll.isHidden = true
        addSubview(resultsScroll)
        noResults.alignment = .center
        noResults.isHidden = true
        addSubview(noResults)
        emojiField.field.delegate = self
        if let selected, IconChoice.isEmoji(selected) { emojiField.stringValue = selected; shownEmoji = selected }
        addSubview(emojiField)
        refresh()
        // Made now, while the grid is looked at, so it's there by the time a name is typed.
        EmojiSearch.index { _ in }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Picks it, as a click on its cell does.
    func pick(_ icon: String?) {
        selected = icon
        if let icon, !IconChoice.isSymbol(icon) {
            emojiField.stringValue = icon
            shownEmoji = icon
        } else {
            emojiField.stringValue = ""
            shownEmoji = nil
        }
        search(nil)
        onPick?(icon)
    }

    private func refresh() {
        for (i, cell) in cells.enumerated() {
            let name: String? = i == 0 ? nil : IconChoice.symbols[i - 1]
            cell.isSelected = name == selected || (i == 0 && selected == nil)
        }
        for (i, cell) in resultCells.enumerated() where i < results.count { cell.isSelected = results[i].emoji == selected }
    }

    override func layout() {
        super.layout()
        for (i, cell) in cells.enumerated() { cell.frame = Self.cellFrame(i) }
        resultsScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.gridHeight)
        layoutResults()
        let h = noResults.lineHeight
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: Self.gridHeight)
        noResults.frame = NSRect(x: 0, y: Tokens.EmptyState.noMatchY(in: area, lineHeight: h), width: bounds.width, height: h)
        emojiField.frame = NSRect(x: 0, y: Self.gridHeight + Tokens.Space.x3, width: bounds.width, height: Self.fieldHeight)
    }

    private static func cellFrame(_ i: Int) -> NSRect {
        let row = i / columns, column = i % columns
        return NSRect(x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
    }

    private func layoutResults() {
        for (i, cell) in resultCells.enumerated() { cell.frame = Self.cellFrame(i) }
        let rows = (results.count + Self.columns - 1) / Self.columns
        resultsList.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(CGFloat(rows) * (Self.cell + Self.gap) - Self.gap, 0))
    }

    // MARK: Search

    /// Shows what matches `text` in the grid's place, or the symbols again for nil or nothing but spaces.
    private func search(_ text: String?) {
        query = text
        let searching = text.map { !EmojiSearch.normalized($0).isEmpty } == true
        cells.forEach { $0.isHidden = searching }
        resultsScroll.isHidden = !searching
        guard searching, let text else {
            results = []
            noResults.isHidden = true
            return
        }
        guard let index = EmojiSearch.madeIndex else {
            // Still being made (only just after the grid opened): the matches come when it is.
            results = []
            showResults()
            noResults.isHidden = true
            EmojiSearch.index { [weak self] _ in
                guard let self, self.query == text else { return }
                self.search(text)
            }
            return
        }
        results = EmojiSearch.search(text, in: index)
        showResults()
        let typed = text.trimmingCharacters(in: .whitespaces)
        noResults.stringValue = String(localized: "No emoji match “\(typed)”.", comment: "In the icon choices, when no emoji's name matches what's typed in the field under them; what was typed.")
        noResults.isHidden = !results.isEmpty
    }

    private func showResults() {
        while resultCells.count < results.count {
            let i = resultCells.count
            let button = IconButton(symbol: "", size: Self.cell, symbolSize: Tokens.Symbol.row, toolTip: nil)
            button.selectsAsCard = true
            button.imageSide = Self.resultSide
            button.onClick = { [weak self] _ in
                guard let self, self.results.indices.contains(i) else { return }
                self.pick(self.results[i].emoji)
            }
            resultCells.append(button)
            resultsList.addSubview(button)
        }
        for (i, cell) in resultCells.enumerated() {
            cell.isHidden = i >= results.count
            guard i < results.count else { continue }
            let entry = results[i]
            if cell.toolTip != entry.name {
                cell.image = IconChoice.image(entry.emoji, size: Self.resultSide)
                cell.toolTip = entry.name
            }
        }
        refresh()
        layoutResults()
        resultsList.scroll(.zero)
    }

    /// Esc while searching: the search goes, and the field shows the icon again if it's an emoji. False when there's
    /// no search, so Esc closes what the grid is in, as before.
    @discardableResult func endSearch() -> Bool {
        guard query != nil else { return false }
        if let selected, IconChoice.isEmoji(selected) {
            emojiField.stringValue = selected
            shownEmoji = selected
        } else {
            emojiField.stringValue = ""
        }
        search(nil)
        return true
    }

    /// Return while searching picks the best match.
    @discardableResult func pickFirstResult() -> Bool {
        guard query != nil, let first = results.first else { return false }
        pick(first.emoji)
        return true
    }

    /// Puts `text` in the field as if it were typed (the debug bridge's `iconsearch`).
    func type(_ text: String) {
        emojiField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: emojiField.field))
    }

    func controlTextDidChange(_ obj: Notification) {
        // Mid-word in an input method (pinyin, kana), the text isn't settled: it's left as it is.
        guard (emojiField.field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        switch Self.fieldState(emojiField.stringValue, shown: shownEmoji) {
        case .empty:
            let wasEmoji = shownEmoji != nil
            shownEmoji = nil
            search(nil)
            // The emoji deleted: back to no icon (a page's own site icon), as the plain choice does.
            if wasEmoji, Self.clearsEmoji(text: "", selected: selected) { pick(nil) }
        case .emoji(let emoji):
            emojiField.stringValue = emoji
            shownEmoji = emoji
            search(nil)
            selected = emoji
            onPick?(emoji)
        case .search(let text):
            if emojiField.stringValue != text { emojiField.stringValue = text }
            shownEmoji = nil
            search(text)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { return pickFirstResult() }
        if selector == #selector(NSResponder.cancelOperation(_:)) { return endSearch() }
        return false
    }

    /// What the field holds: nothing, an emoji to make the icon, or a name to find one by.
    enum FieldState: Equatable {
        case empty
        case emoji(String)
        /// The text to keep in the field and search for.
        case search(String)
    }

    /// The field's text read as one of those. `shown`: the emoji it showed as the icon before this edit, so letters
    /// typed beside it are a search (and it steps aside for them), where a new emoji typed or pasted, even among
    /// words, is the icon, as it always was.
    static func fieldState(_ text: String, shown: String?) -> FieldState {
        if text.isEmpty { return .empty }
        let typed = shown.map { text.replacingOccurrences(of: $0, with: "") } ?? text
        if let emoji = lastEmoji(in: typed) { return .emoji(emoji) }
        if typed.isEmpty, let shown { return .emoji(shown) }
        return .search(typed)
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
    let grid: IconGrid
    private var monitor: Any?
    private let pad = Tokens.Space.x3
    static weak var current: IconPickerPanel?
    /// How wide it is: the grid and its padding.
    var preferredWidth: CGFloat { IconGrid.width + pad * 2 }

    /// Pages get Choose Image… and, with an icon set, Use Site Icon (#303); folders get neither.
    private let chooseImage: PillButton?
    private let useSite = PillButton(title: SidebarMenus.useSiteIconTitle, style: .quiet)
    /// Footer row: a gap under the search field, then the buttons, then the panel's own margin below them.
    private var footHeight: CGFloat { chooseImage == nil ? 0 : Tokens.Space.x2 + Tokens.Space.x7Height }
    var preferredHeight: CGFloat { IconGrid.height + pad * 2 + footHeight }

    /// `onChooseImage`: a page's picker, which also accepts image files and can revert to the site icon.
    init(noneSymbol: String, noneImage: NSImage? = nil, noneToolTip: String? = nil, selected: String?,
         onChooseImage: (() -> Void)? = nil, onPick: @escaping (String?) -> Void) {
        grid = IconGrid(noneSymbol: noneSymbol, noneImage: noneImage, noneToolTip: noneToolTip, selected: selected)
        chooseImage = onChooseImage.map { _ in PillButton(title: SidebarMenus.chooseImageTitle, style: .quiet) }
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        grid.onPick = { [weak self] icon in
            onPick(icon)
            self?.useSite.isHidden = icon == nil
        }
        addSubview(grid)
        if let chooseImage, let onChooseImage {
            chooseImage.onClick = { _ in onChooseImage() }
            useSite.onClick = { [weak self] _ in self?.grid.pick(nil) }
            useSite.isHidden = selected == nil
            addSubview(chooseImage)
            addSubview(useSite)
        }
        onLayout = { [weak self] in self?.layoutParts() }
    }

    private func layoutParts() {
        grid.frame = NSRect(x: pad, y: pad, width: IconGrid.width, height: IconGrid.height)
        guard let chooseImage else { return }
        // The buttons' hover fill keeps to the grid's edges, as the search field does, never out toward the panel's.
        let y = pad + IconGrid.height + Tokens.Space.x2, h = Tokens.Space.x7Height
        let chooseWidth = min(ceil(chooseImage.fittingWidth), IconGrid.width / 2)
        chooseImage.frame = NSRect(x: pad, y: y, width: chooseWidth, height: h)
        let siteWidth = min(ceil(useSite.fittingWidth), IconGrid.width / 2)
        useSite.frame = NSRect(x: pad + IconGrid.width - siteWidth, y: y, width: siteWidth, height: h)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A folder's grid: its plain choice is the folder itself.
    static func forFolder(selected: String?, onPick: @escaping (String?) -> Void) -> IconPickerPanel {
        IconPickerPanel(noneSymbol: "folder", selected: selected, onPick: onPick)
    }

    /// Beside the sidebar, level with the row it's for.
    func show(beside row: NSView, in overlay: NSView, x: CGFloat) {
        let rowFrame = row.convert(row.bounds, to: overlay)
        // Opens away from the sidebar edge, left or right.
        show(at: NSPoint(x: x, y: rowFrame.minY - Tokens.Space.x2), in: overlay, growsFrom: CGPoint(x: x < rowFrame.minX ? 1 : 0, y: 0.1))
    }

    /// Top-left at `point`, clamped to the overlay; where Site Controls was, for site icons (#310).
    func show(at point: NSPoint, in overlay: NSView, growsFrom: CGPoint) {
        IconPickerPanel.current?.close()
        let size = NSSize(width: preferredWidth, height: preferredHeight)
        let top = max(Tokens.Space.x2, min(point.y, overlay.bounds.height - size.height - Tokens.Space.x2))
        let x = max(Tokens.Space.x2, min(point.x, overlay.bounds.width - size.width - Tokens.Space.x2))
        frame = NSRect(origin: NSPoint(x: x, y: top), size: size)
        overlay.addSubview(self)
        self.growsFrom = growsFrom
        present(arrival: .pop)
        IconPickerPanel.current = self
        monitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Mid-word in an input method (the emoji field takes any text), Esc belongs to it.
                // Esc ends a search first, then closes the panel.
                if event.keyCode == 53, event.window === self.window,
                   (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                    if !self.grid.endSearch() { self.close() }
                    return nil
                }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    func close() {
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        dismiss()
        if IconPickerPanel.current === self { IconPickerPanel.current = nil }
    }
}
