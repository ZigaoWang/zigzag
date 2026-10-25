import AppKit

/// A space's heading in desk view. Clicking it selects every tab in the space.
final class DeskHeaderView: InteractiveView {
    let dot = ColorView()
    let label = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    let count = Label("", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        [dot, label, count].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        dot.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - 8) / 2, width: 8, height: 8)
        label.frame = NSRect(x: dot.frame.maxX + Tokens.Space.x2, y: (bounds.height - h) / 2, width: label.textWidth, height: h)
        count.frame = NSRect(x: label.frame.maxX + Tokens.Space.x1, y: (bounds.height - h) / 2, width: count.textWidth, height: h)
    }

    var fittingWidth: CGFloat { Tokens.Space.x2 * 3 + 8 + label.textWidth + Tokens.Space.x1 + count.textWidth }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The desk's content: every tab as a card, grouped by space, in sidebar order.
final class DeskCanvasView: NSView {
    weak var desk: DeskController?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) { desk?.backgroundMouseDown(event) }
    override func keyDown(with event: NSEvent) { if desk?.keyDown(event) != true { super.keyDown(with: event) } }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Desk view: zoom out to see every tab at once and tidy up. Not for everyday switching.
final class DeskController {
    private weak var controller: BrowserWindowController?
    private let backdrop = ColorView()
    private let scrollView = NSScrollView()
    private let canvas = DeskCanvasView()
    private let actionBar = FloatingPanelView()
    private let closeButton = TextButton(title: "Close Tabs", font: Tokens.Font.body(.medium))
    private let doneButton = TextButton(title: "Done", font: Tokens.Font.body(.medium))
    private var headers: [UUID: DeskHeaderView] = [:]
    private var cards: [UUID: TabThumbnailView] = [:]
    private var selection: Set<UUID> = []
    private(set) var isVisible = false
    private var marquee: CAShapeLayer?
    private var magnifyTotal: CGFloat = 0
    private var gestureClaimed = false

    private let cardWidth = Tokens.Metric.deskCardWidth
    private let gap = Tokens.Space.x4
    private let margin = Tokens.Space.x10

    init(window: BrowserWindowController) {
        controller = window
        canvas.desk = self
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        scrollView.useSlimScroller()
        backdrop.addSubview(scrollView)
        actionBar.radius = Tokens.Radius.row + Tokens.Space.x1
        actionBar.addSubview(closeButton)
        actionBar.addSubview(doneButton)
        closeButton.onClick = { [weak self] _ in self?.closeSelected() }
        doneButton.onClick = { [weak self] _ in self?.hide(openingTab: nil) }
    }

    private var manager: TabManager? { controller?.tabManager }

    // MARK: Showing

    func toggle() { isVisible ? hide(openingTab: nil) : show() }

    func show() {
        guard !isVisible, let controller else { return }
        isVisible = true
        selection = []
        controller.previews.hide()
        controller.commandBar.dismiss(restoringFocus: false)
        controller.tabManager.selectedTab?.captureSnapshot { [weak self] in self?.cards.values.forEach { $0.refreshImage() } }
        let root = controller.root
        backdrop.color = controller.tabManager.currentSpace.background
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        scrollView.frame = backdrop.bounds.insetBy(dx: 0, dy: 0)
        scrollView.autoresizingMask = [.width, .height]
        root.overlay.addSubview(backdrop)
        reload()
        // The window's own controls would sit on top of the desk; tuck them away.
        (controller.window as? BrowserWindow)?.trafficLightsHidden = false
        controller.window?.makeFirstResponder(canvas)

        // Zoom out: the current page shrinks into its card while the others fade in.
        let current = controller.tabManager.selectedTab.flatMap { cards[$0.id] }
        if let current, let snapshot = current.tab?.snapshot {
            let ghost = NSImageView(image: snapshot)
            ghost.imageScaling = .scaleAxesIndependently
            ghost.wantsLayer = true
            ghost.layer?.cornerRadius = Tokens.Radius.card
            ghost.layer?.masksToBounds = true
            ghost.frame = root.cardFrame
            root.overlay.addSubview(ghost)
            let target = current.imageClip.convert(current.imageClip.bounds, to: root.overlay)
            current.alphaValue = 0
            backdrop.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.gentle, {
                ghost.animator().frame = target
                self.backdrop.animator().alphaValue = 1
            }, completion: {
                current.alphaValue = 1
                ghost.removeFromSuperview()
            })
        } else {
            backdrop.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.gentle) { self.backdrop.animator().alphaValue = 1 }
        }
    }

    func hide(openingTab tab: Tab?) {
        guard isVisible, let controller else { return }
        isVisible = false
        actionBar.removeFromSuperview()
        let root = controller.root
        let target = tab ?? controller.tabManager.selectedTab
        if let target, let card = cards[target.id], let image = target.snapshot ?? card.tab?.snapshot {
            // Zoom into the chosen card.
            let ghost = NSImageView(image: image)
            ghost.imageScaling = .scaleAxesIndependently
            ghost.wantsLayer = true
            ghost.layer?.cornerRadius = Tokens.Radius.card
            ghost.layer?.masksToBounds = true
            ghost.frame = card.imageClip.convert(card.imageClip.bounds, to: root.overlay)
            root.overlay.addSubview(ghost)
            card.alphaValue = 0
            if let tab { controller.tabManager.select(tab) }
            Tokens.Motion.animate(Tokens.Motion.gentle, {
                ghost.animator().frame = root.cardFrame
                self.backdrop.animator().alphaValue = 0
            }, completion: {
                ghost.removeFromSuperview()
                self.backdrop.removeFromSuperview()
                self.backdrop.alphaValue = 1
                card.alphaValue = 1
            })
        } else {
            if let tab { controller.tabManager.select(tab) }
            Tokens.Motion.animate(Tokens.Motion.snappy, { self.backdrop.animator().alphaValue = 0 }, completion: {
                self.backdrop.removeFromSuperview()
                self.backdrop.alphaValue = 1
            })
        }
        if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
    }

    // MARK: Layout

    private var cardHeight: CGFloat {
        guard let controller else { return 200 }
        let card = controller.root.cardFrame
        let aspect = min(max(card.height / max(card.width, 1), 0.5), 0.8)
        return round((cardWidth - Tokens.Space.x2) * aspect) + TabThumbnailView.titleHeight + Tokens.Space.x1
    }

    /// Lays out every space and its cards. Positions follow sidebar order, so they never move on their own.
    private func layoutFrames(dragging: (id: UUID, space: UUID, index: Int)? = nil) -> (headers: [UUID: NSRect], cards: [UUID: NSRect], height: CGFloat) {
        guard let manager else { return ([:], [:], 0) }
        let width = max(scrollView.contentSize.width, cardWidth + margin * 2)
        let columns = max(1, Int((width - margin * 2 + gap) / (cardWidth + gap)))
        let rowWidth = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
        let left = floor((width - rowWidth) / 2)
        var y = margin
        var headerFrames: [UUID: NSRect] = [:]
        var cardFrames: [UUID: NSRect] = [:]
        for space in Library.shared.spaces {
            var ids = manager.tabs(in: space.id).map(\.id)
            if let dragging {
                ids.removeAll { $0 == dragging.id }
                if dragging.space == space.id { ids.insert(dragging.id, at: min(dragging.index, ids.count)) }
            }
            if ids.isEmpty && dragging == nil && Library.shared.spaces.count > 1 { continue }
            headerFrames[space.id] = NSRect(x: left - Tokens.Space.x2, y: y, width: 320, height: Tokens.Space.x8)
            y += Tokens.Space.x8 + Tokens.Space.x3
            for (i, id) in ids.enumerated() {
                let col = i % columns, row = i / columns
                cardFrames[id] = NSRect(x: left + CGFloat(col) * (cardWidth + gap), y: y + CGFloat(row) * (cardHeight + gap), width: cardWidth, height: cardHeight)
            }
            let rows = max(1, Int(ceil(Double(ids.count) / Double(columns))))
            y += CGFloat(rows) * (cardHeight + gap) + Tokens.Space.x6
        }
        return (headerFrames, cardFrames, y + margin)
    }

    /// Tabs opened or closed while the desk is up (⌘W, a link opening a tab): the cards follow.
    func tabsChanged() { if isVisible { reload(animated: true) } }

    private func reload(animated: Bool = false) {
        guard let manager else { return }
        let allTabs = Library.shared.spaces.flatMap { manager.tabs(in: $0.id) }
        let ids = Set(allTabs.map(\.id))
        for (id, view) in cards where !ids.contains(id) {
            cards[id] = nil
            if animated {
                Tokens.Motion.animate(Tokens.Motion.feedback, { view.animator().alphaValue = 0 }, completion: { view.removeFromSuperview() })
            } else { view.removeFromSuperview() }
        }
        selection = selection.intersection(ids)
        // Cards kept from last time show what each tab is now.
        for tab in allTabs { cards[tab.id]?.configure(tab) }
        for tab in allTabs where cards[tab.id] == nil {
            let card = TabThumbnailView()
            card.inset = Tokens.Space.x1
            card.showsRing = true
            card.configure(tab)
            card.onClick = { [weak self, weak tab] event in
                guard let self, let tab else { return }
                self.cardClicked(tab, event: event)
            }
            card.onDragStart = { [weak self, weak tab] event in
                guard let self, let tab else { return false }
                return self.beginDrag(tab, event: event)
            }
            card.onRightClick = { [weak self, weak tab] _ in
                guard let self, let tab else { return nil }
                if !self.selection.contains(tab.id) { self.selection = [tab.id]; self.updateSelection() }
                let menu = NSMenu()
                menu.addItem(SidebarMenus.Item(self.selection.count > 1 ? "Close \(self.selection.count) Tabs" : "Close Tab") { self.closeSelected() })
                return menu
            }
            cards[tab.id] = card
            canvas.addSubview(card)
        }
        for space in Library.shared.spaces where headers[space.id] == nil {
            let header = DeskHeaderView()
            header.onClick = { [weak self] _ in self?.selectSpace(space.id) }
            headers[space.id] = header
            canvas.addSubview(header)
        }
        for (id, header) in headers where Library.shared.space(id) == nil { header.removeFromSuperview(); headers[id] = nil }
        applyLayout(animated: animated)
        updateSelection()
    }

    private func applyLayout(animated: Bool, dragging: (id: UUID, space: UUID, index: Int)? = nil) {
        let layout = layoutFrames(dragging: dragging)
        canvas.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(layout.height, scrollView.contentSize.height))
        var changes: [() -> Void] = []
        for (id, header) in headers {
            guard let space = Library.shared.space(id) else { continue }
            header.label.stringValue = space.name
            let count = manager?.tabs(in: id).count ?? 0
            header.count.stringValue = count == 1 ? "1 tab" : "\(count) tabs"
            header.dot.color = space.swatch
            if let frame = layout.headers[id] {
                header.isHidden = false
                var f = frame
                f.size.width = header.fittingWidth
                if animated { changes.append { header.animator().frame = f } } else { header.frame = f }
            } else {
                header.isHidden = true
            }
        }
        for (id, card) in cards {
            guard let frame = layout.cards[id], id != dragging?.id else { continue }
            if animated { changes.append { card.animator().frame = frame } } else { card.frame = frame }
        }
        if !changes.isEmpty { Tokens.Motion.animate(Tokens.Motion.snappy) { changes.forEach { $0() } } }
    }

    // MARK: Selection

    private func cardClicked(_ tab: Tab, event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            if selection.contains(tab.id) { selection.remove(tab.id) } else { selection.insert(tab.id) }
            updateSelection()
        } else if !selection.isEmpty {
            selection = [tab.id]
            updateSelection()
        } else {
            hide(openingTab: tab)
        }
    }

    private func selectSpace(_ id: UUID) {
        guard let manager else { return }
        let ids = Set(manager.tabs(in: id).map(\.id))
        selection = ids.isSubset(of: selection) ? selection.subtracting(ids) : selection.union(ids)
        updateSelection()
    }

    private func updateSelection() {
        for (id, card) in cards { card.isSelected = selection.contains(id) }
        guard let controller else { return }
        if selection.isEmpty {
            if actionBar.superview != nil { actionBar.dismiss() }
            return
        }
        closeButton.title = selection.count == 1 ? "Close Tab" : "Close \(selection.count) Tabs"
        doneButton.title = "Done"
        let cw = closeButton.fittingWidth, dw = doneButton.fittingWidth
        let pad = Tokens.Space.x2
        let height = Tokens.Space.x10 + Tokens.Space.x1
        let width = pad * 3 + cw + dw
        let root = controller.root.bounds
        actionBar.frame = NSRect(x: round(root.midX - width / 2), y: root.maxY - height - Tokens.Space.x6, width: width, height: height)
        closeButton.frame = NSRect(x: pad, y: (height - Tokens.Space.x8) / 2, width: cw, height: Tokens.Space.x8)
        doneButton.frame = NSRect(x: closeButton.frame.maxX + pad, y: closeButton.frame.minY, width: dw, height: Tokens.Space.x8)
        if actionBar.superview == nil {
            controller.root.overlay.addSubview(actionBar)
            actionBar.present()
        }
    }

    private func closeSelected() {
        guard let manager, !selection.isEmpty else { return }
        let tabs = manager.allTabs.filter { selection.contains($0.id) }
        selection = []
        // ⌘Z brings them back, like closing them from the sidebar.
        if let controller { controller.closeManyWithUndo(tabs) } else { manager.close(tabs) }
        reload(animated: true)
    }

    // MARK: Marquee selection

    func backgroundMouseDown(_ event: NSEvent) {
        guard let window = canvas.window else { return }
        let start = canvas.convert(event.locationInWindow, from: nil)
        let additive = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let base = additive ? selection : []
        if !additive { selection = []; updateSelection() }
        var moved = false
        let layer = CAShapeLayer()
        layer.fillColor = canvas.cgColor(Tokens.Color.accent.withAlphaComponent(0.12))
        layer.strokeColor = canvas.cgColor(Tokens.Color.accent.withAlphaComponent(0.6))
        layer.lineWidth = 1
        canvas.wantsLayer = true
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            let point = self.canvas.convert(event.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            if !moved, rect.width + rect.height > 4 {
                moved = true
                self.canvas.layer?.addSublayer(layer)
            }
            guard moved else { return }
            Tokens.Motion.withoutAnimation { layer.path = CGPath(rect: rect, transform: nil) }
            self.selection = base.union(self.cards.filter { $0.value.frame.intersects(rect) }.map(\.key))
            self.updateSelection()
        }
        layer.removeFromSuperlayer()
        if !moved && !additive { hide(openingTab: nil) }
    }

    // MARK: Dragging cards

    private func beginDrag(_ tab: Tab, event: NSEvent) -> Bool {
        guard let window = canvas.window, let card = cards[tab.id], let manager else { return false }
        let start = canvas.convert(event.locationInWindow, from: nil)
        let offset = NSPoint(x: start.x - card.frame.minX, y: start.y - card.frame.minY)
        card.removeFromSuperview()
        canvas.addSubview(card)
        card.layer?.shadowOpacity = 1
        card.layer?.shadowRadius = Tokens.Space.x3
        card.layer?.shadowColor = canvas.cgColor(Tokens.Color.panelShadow)
        var target = (id: tab.id, space: tab.spaceID, index: manager.tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            let point = self.canvas.convert(event.locationInWindow, from: nil)
            Tokens.Motion.withoutAnimation { card.frame.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y) }
            self.canvas.autoscroll(with: event)
            if let slot = self.slot(at: NSPoint(x: card.frame.midX, y: card.frame.midY), excluding: tab.id), slot.space != target.space || slot.index != target.index {
                target = (tab.id, slot.space, slot.index)
                self.applyLayout(animated: true, dragging: target)
            }
        }
        card.layer?.shadowOpacity = 0
        manager.move(tab, to: target.index, in: target.space)
        applyLayout(animated: true)
        return true
    }

    /// The space and position a dragged card would land in.
    private func slot(at point: NSPoint, excluding id: UUID) -> (space: UUID, index: Int)? {
        let layout = layoutFrames()
        let ordered = layout.headers.sorted { $0.value.minY < $1.value.minY }
        guard let space = ordered.last(where: { $0.value.minY <= point.y })?.key ?? ordered.first?.key, let manager else { return nil }
        let ids = manager.tabs(in: space).map(\.id).filter { $0 != id }
        var index = 0
        for (i, cardID) in ids.enumerated() {
            guard let frame = layout.cards[cardID] else { continue }
            if point.y > frame.maxY || (point.y >= frame.minY && point.x > frame.midX) { index = i + 1 }
        }
        return (space, index)
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc
            if !selection.isEmpty { selection = []; updateSelection() } else { hide(openingTab: nil) }
            return true
        case 51, 117: // delete, forward delete
            closeSelected()
            return true
        case 0 where event.modifierFlags.contains(.command): // cmd-A
            selection = Set(cards.keys)
            updateSelection()
            return true
        default:
            return false
        }
    }

    // MARK: Pinch

    /// Pinching out on a page (that isn't zoomed in) opens the desk; pinching in on a card opens it.
    func handleMagnify(_ event: NSEvent) -> Bool {
        guard event.type == .magnify, let controller else { return false }
        if event.phase == .began {
            magnifyTotal = 0
            gestureClaimed = false
        }
        magnifyTotal += event.magnification
        if isVisible {
            if event.phase == .ended || event.phase == .cancelled {
                defer { magnifyTotal = 0 }
                if magnifyTotal > 0.12 {
                    let point = canvas.convert(event.locationInWindow, from: nil)
                    let hit = cards.first { $0.value.frame.contains(point) }?.key
                    hide(openingTab: hit.flatMap { controller.tabManager.tab(with: $0) })
                }
            }
            return true
        }
        if gestureClaimed {
            if event.phase == .ended || event.phase == .cancelled { gestureClaimed = false }
            return true
        }
        let pageZoomed = (controller.selectedWebView?.magnification ?? 1) > 1.01
        guard !pageZoomed, magnifyTotal < -0.15 else { return false }
        gestureClaimed = true
        show()
        return true
    }
}
