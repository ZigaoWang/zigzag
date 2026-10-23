import AppKit

/// One result row: icon, title, quiet detail, and an action hint when selected.
final class CommandRowView: InteractiveView {
    private let icon = FaviconView()
    private let symbolView = NSImageView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private let action = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let returnKey = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        symbolView.imageScaling = .scaleNone
        symbolView.contentTintColor = Tokens.Color.icon
        returnKey.image = Tokens.Symbol.image("return", size: Tokens.TypeSize.small)
        returnKey.contentTintColor = Tokens.Color.textTertiary
        returnKey.imageScaling = .scaleNone
        [icon, symbolView, title, detail, action, returnKey].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ result: CommandResult) {
        title.stringValue = result.title
        detail.stringValue = result.detail
        action.stringValue = result.actionLabel
        if let image = result.icon {
            icon.image = image
            icon.isHidden = false
            symbolView.isHidden = true
        } else {
            icon.isHidden = true
            symbolView.isHidden = false
            symbolView.image = Tokens.Symbol.image(result.symbol ?? "globe")
        }
        setAccessibilityLabel(result.detail.isEmpty ? result.title : "\(result.title), \(result.detail)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let iconSize = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        symbolView.frame = icon.frame
        let showAction = isSelected
        action.isHidden = !showAction
        returnKey.isHidden = !showAction
        var right = bounds.width - pad
        if showAction {
            returnKey.frame = NSRect(x: right - Tokens.Space.x3, y: 0, width: Tokens.Space.x3, height: bounds.height)
            let w = action.textWidth
            let h = ceil(action.intrinsicContentSize.height)
            action.frame = NSRect(x: returnKey.frame.minX - Tokens.Space.x1 - w, y: (bounds.height - h) / 2, width: w, height: h)
            right = action.frame.minX - Tokens.Space.x3
        }
        let x = icon.frame.maxX + Tokens.Space.x3
        let h = ceil(title.intrinsicContentSize.height)
        let y = (bounds.height - h) / 2
        let available = right - x
        let titleWidth = min(title.textWidth, detail.stringValue.isEmpty ? available : available * 0.62)
        title.frame = NSRect(x: x, y: y, width: max(0, titleWidth), height: h)
        let detailX = title.frame.maxX + Tokens.Space.x2
        detail.frame = NSRect(x: detailX, y: y, width: max(0, right - detailX), height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isSelected ? Tokens.Color.highlight : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        needsLayout = true
    }
}

/// The floating command bar: one field for addresses, searches, tabs, bookmarks and history.
final class CommandBarController: NSObject, NSTextFieldDelegate {
    enum Mode { case newTab, editCurrent, history }

    private weak var controller: BrowserWindowController?
    private let scrim = ScrimView()
    private let panel = FloatingPanelView()
    private let field = PlainTextField(font: Tokens.Font.large(), placeholder: "Search or enter address")
    private let fieldIcon = NSImageView()
    private let divider = ColorView(color: Tokens.Color.separator)
    private var rows: [CommandRowView] = []
    private var results: [CommandResult] = []
    private var selectedIndex = 0
    private var mode: Mode = .newTab
    private var suggestions: [String] = []
    private let fetcher = SuggestionFetcher()
    /// Text the user actually typed; the field may also hold an inline completion after it.
    private var typed = ""
    private var completionURL: URL?
    private var suppressCompletion = false
    private(set) var isVisible = false
    private var mouseAtOpen = NSPoint.zero

    init(window: BrowserWindowController) {
        controller = window
        super.init()
        field.delegate = self
        fieldIcon.image = Tokens.Symbol.image("magnifyingglass", size: Tokens.TypeSize.large)
        fieldIcon.contentTintColor = Tokens.Color.textTertiary
        fieldIcon.imageScaling = .scaleNone
        panel.addSubview(fieldIcon)
        panel.addSubview(field)
        panel.addSubview(divider)
        panel.onLayout = { [weak self] in self?.layoutPanel() }
        scrim.onClick = { [weak self] in self?.dismiss() }
    }

    // MARK: Showing

    func show(mode: Mode) {
        guard let controller else { return }
        self.mode = mode
        mouseAtOpen = NSEvent.mouseLocation
        let card = controller.root.cardFrame
        if !isVisible {
            isVisible = true
            scrim.frame = card
            controller.root.overlay.addSubview(scrim)
            controller.root.overlay.addSubview(panel)
            scrim.show()
        }
        field.placeholderAttributedString = NSAttributedString(string: mode == .history ? "Search history" : "Search or enter address",
                                                               attributes: [.font: Tokens.Font.large(), .foregroundColor: Tokens.Color.textTertiary])
        if mode == .editCurrent, let url = controller.tabManager.selectedTab?.url {
            field.stringValue = url.absoluteString
        } else {
            field.stringValue = ""
        }
        typed = field.stringValue
        completionURL = nil
        suggestions = []
        refreshResults(animated: false)
        panel.frame = panelFrame()
        panel.present()
        controller.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss(restoringFocus: Bool = true) {
        guard isVisible, let controller else { return }
        isVisible = false
        fetcher.cancel()
        scrim.hide()
        panel.dismiss()
        if restoringFocus, let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }

    func reposition() {
        guard isVisible, let controller else { return }
        scrim.frame = controller.root.cardFrame
        panel.frame = panelFrame()
    }

    // MARK: Layout

    private var listHeight: CGFloat {
        guard !results.isEmpty else { return 0 }
        return CGFloat(results.count) * Tokens.Metric.commandBarRowHeight + Tokens.Space.x2 * 2
    }

    private func panelFrame() -> NSRect {
        guard let controller else { return .zero }
        let card = controller.root.cardFrame
        let width = min(Tokens.Metric.commandBarWidth, card.width - Tokens.Space.x16)
        let height = Tokens.Metric.commandBarFieldHeight + listHeight
        let top = card.minY + max(Tokens.Space.x12, floor(card.height * 0.18))
        return NSRect(x: floor(card.midX - width / 2), y: top, width: width, height: height)
    }

    private func layoutPanel() {
        let b = panel.bounds
        let fieldHeight = Tokens.Metric.commandBarFieldHeight
        let iconSize = Tokens.Space.x6
        fieldIcon.frame = NSRect(x: Tokens.Space.x4, y: (fieldHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let textHeight = ceil(field.intrinsicContentSize.height)
        let fieldX = fieldIcon.frame.maxX + Tokens.Space.x2
        field.frame = NSRect(x: fieldX, y: (fieldHeight - textHeight) / 2, width: b.width - fieldX - Tokens.Space.x4, height: textHeight)
        divider.frame = NSRect(x: 0, y: fieldHeight - Tokens.Metric.hairline, width: b.width, height: Tokens.Metric.hairline)
        divider.isHidden = results.isEmpty
        var y = fieldHeight + Tokens.Space.x2
        for row in rows {
            row.frame = NSRect(x: Tokens.Space.x2, y: y, width: b.width - Tokens.Space.x4, height: Tokens.Metric.commandBarRowHeight)
            y += Tokens.Metric.commandBarRowHeight
        }
    }

    // MARK: Results

    private func refreshResults(animated: Bool) {
        guard let controller else { return }
        let editing = mode == .editCurrent && typed == controller.tabManager.selectedTab?.url?.absoluteString
        results = CommandRanker.results(for: editing ? "" : typed, manager: controller.tabManager, suggestions: suggestions,
                                        editingCurrent: mode == .editCurrent, historyOnly: mode == .history)
        if editing { results = [] }
        // An inline completion becomes the first result.
        if let completionURL, !typed.isEmpty {
            var top = CommandResult(kind: .open(completionURL), title: CommandRanker.displayURL(completionURL), detail: "",
                                    icon: FaviconStore.shared.cachedIcon(for: completionURL), symbol: "globe")
            // Already open? Then the top hit is switching to it, not a second copy.
            if let existing = controller.tabManager.existingTab(for: completionURL) {
                top = CommandResult(kind: .switchTo(existing.id), title: existing.displayTitle,
                                    detail: CommandRanker.displayURL(completionURL), icon: existing.favicon)
            }
            results.removeAll { $0.kind == .open(completionURL) || $0.kind == top.kind || ($0.title == top.title) }
            results.insert(top, at: 0)
            results = Array(results.prefix(Tokens.Metric.commandBarMaxRows))
        }
        while rows.count < results.count {
            let row = CommandRowView()
            row.onClick = { [weak self, weak row] event in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.activate(self.results[index], modifiers: event.modifierFlags)
            }
            row.hoverChanged = { [weak self, weak row] hovering in
                // Only a mouse that actually moved picks a row; a resting cursor must not steal the selection.
                guard let self, let row, hovering, NSEvent.mouseLocation != self.mouseAtOpen,
                      let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.select(index)
            }
            rows.append(row)
            panel.addSubview(row)
        }
        while rows.count > results.count { rows.removeLast().removeFromSuperview() }
        for (row, result) in zip(rows, results) { row.configure(result) }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        if !results.isEmpty { selectedIndex = 0 }
        updateSelection()
        let frame = panelFrame()
        if animated && panel.frame.height != frame.height {
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.panel.animator().frame = frame }
        } else {
            panel.frame = frame
        }
        panel.needsLayout = true
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        updateSelection()
    }

    private func updateSelection() {
        for (i, row) in rows.enumerated() { row.isSelected = i == selectedIndex }
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field.currentEditor() else { return }
        let text = field.stringValue
        typed = text
        completionURL = nil
        // Inline completion: only when typing forward at the end, never after deleting.
        if !suppressCompletion, editor.selectedRange.location == (text as NSString).length,
           let controller, mode != .history,
           let (completion, url) = CommandRanker.inlineCompletion(for: text, manager: controller.tabManager),
           completion.lowercased().hasPrefix(text.lowercased()), completion.count > text.count {
            let suffix = String(completion.dropFirst(text.count))
            field.stringValue = text + suffix
            editor.selectedRange = NSRange(location: (text as NSString).length, length: (suffix as NSString).length)
            completionURL = url
        } else if !suppressCompletion, let controller, mode != .history,
                  let (completion, url) = CommandRanker.inlineCompletion(for: text, manager: controller.tabManager),
                  completion.lowercased() == text.lowercased() {
            completionURL = url
        }
        suppressCompletion = false
        refreshResults(animated: true)
        fetcher.fetch(text) { [weak self] list in
            guard let self, self.isVisible, self.typed == text else { return }
            self.suggestions = list
            let selected = self.results.indices.contains(self.selectedIndex) ? self.results[self.selectedIndex] : nil
            self.refreshResults(animated: true)
            if let selected, let index = self.results.firstIndex(of: selected) { self.select(index) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(selectedIndex + 1, results.count - 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(selectedIndex - 1, 0)); return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(modifiers: NSApp.currentEvent?.modifierFlags ?? []); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completionURL != nil, field.stringValue != typed {
                field.stringValue = typed
                completionURL = nil
                refreshResults(animated: true)
            } else {
                dismiss()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab accepts the inline completion.
            if completionURL != nil {
                textView.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                typed = field.stringValue
            } else {
                select(min(selectedIndex + 1, results.count - 1))
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Deleting removes the completion first, without re-completing.
            if textView.selectedRange.length > 0, completionURL != nil {
                suppressCompletion = true
            }
            suppressCompletion = true
            return false
        default:
            return false
        }
    }

    private func commit(modifiers: NSEvent.ModifierFlags) {
        if results.indices.contains(selectedIndex) {
            activate(results[selectedIndex], modifiers: modifiers)
        } else if let url = CommandRanker.url(from: field.stringValue) {
            activate(CommandResult(kind: .open(url), title: "", detail: ""), modifiers: modifiers)
        } else if mode == .editCurrent, field.stringValue == controller?.tabManager.selectedTab?.url?.absoluteString {
            controller?.tabManager.selectedTab?.reload()
            dismiss()
        }
    }

    private func activate(_ result: CommandResult, modifiers: NSEvent.ModifierFlags) {
        guard let controller else { return }
        let manager = controller.tabManager
        let inBackground = modifiers.contains(.command)
        let inCurrent = mode == .editCurrent && manager.selectedTab != nil
        dismiss(restoringFocus: false)
        func open(_ url: URL, search: Bool = false) {
            if inCurrent {
                manager.selectedTab?.load(url)
                manager.selectedTab?.isSearchTab = search
            } else if !search, !inBackground, let existing = manager.existingTab(for: url) {
                manager.select(existing)
            } else {
                let tab = manager.newTab(url: url, select: !inBackground)
                tab.isSearchTab = search
            }
        }
        switch result.kind {
        case .open(let url), .history(let url):
            open(url)
        case .search(let query), .suggestion(let query):
            open(Library.shared.searchEngine.searchURL(query), search: true)
        case .switchTo(let id):
            if let tab = manager.tab(with: id) { manager.select(tab) }
        case .bookmark(let id):
            if let bookmark = Library.shared.bookmark(id) {
                if Library.shared.spaceID(ofBookmark: id) != manager.currentSpaceID, let space = Library.shared.spaceID(ofBookmark: id) {
                    manager.switchToSpace(space)
                }
                manager.openBookmark(bookmark)
            }
        }
        if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }
}

extension CommandBarController {
    func debugEnter() { commit(modifiers: []) }

    func debugType(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
}

/// Dims the page under a floating panel; clicking it dismisses the panel.
final class ScrimView: ColorView {
    var onClick: (() -> Void)?

    init() {
        super.init(color: Tokens.Color.scrim)
        layer?.cornerRadius = Tokens.Radius.card
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    func show() {
        alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.animator().alphaValue = 1 }
    }

    func hide() {
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: {
            if self.alphaValue == 0 { self.removeFromSuperview() }
        })
    }
}
