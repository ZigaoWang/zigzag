import AppKit

protocol SidebarListDelegate: AnyObject {
    var tabManager: TabManager { get }
    func listSelect(_ tab: Tab)
    func listOpenBookmark(_ bookmark: Bookmark)
    func listRenameBookmark(_ id: UUID, to name: String)
    func listClose(_ tab: Tab)
    func listNewTab()
    func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?)
    func listMenu(for item: SidebarItem) -> NSMenu?
    func listRenameSpace()
    func listEditSpace(anchor: NSView)
    /// Returns the space under a window point while dragging (the space dots), highlighting it.
    func listDragHoverSpace(at windowPoint: NSPoint) -> UUID?
    func listDragEnded()
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID)
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID)
    func listUnbookmark(_ bookmarkID: UUID, to index: Int)
    /// While dragging, hovering a space's dot opens that space so the tab can be dropped into place.
    func listSwitchSpaceDuringDrag(_ spaceID: UUID)
    /// A tab dropped outside the window: into another window, or a new one. Returns true if handled.
    func listDropOutside(_ tab: Tab, at screenPoint: NSPoint) -> Bool
    /// A tab dropped into another window's sidebar at an index. Returns true if handled.
    func listMoveToWindow(_ tab: Tab, controller: BrowserWindowController, index: Int) -> Bool
    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool)
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID)
    /// A tab or bookmark dragged over the favorites grid. Returns true while it's over it.
    func listDragOverFavorites(at windowPoint: NSPoint) -> Bool
    /// Dropped on the favorites grid. Returns true if it became a favorite.
    func listDropOnFavorites(_ tab: Tab) -> Bool
    /// A tab dragged over the page: show which half it would open in.
    func listDragOverPage(at windowPoint: NSPoint, tab: Tab)
    /// Dropped on the page: open it in split view beside the current page. Returns true if it did.
    func listDropOnPage(_ tab: Tab) -> Bool
}

enum SidebarItem: Hashable {
    case header
    case bookmark(UUID)
    case separator
    case newTab
    case tab(UUID)
    case placeholder
    /// Shown while dragging a tab when there are no bookmarks yet: drop here to bookmark.
    case bookmarkDropZone

    var height: CGFloat {
        switch self {
        case .header: Tokens.Space.x6 + Tokens.Space.x1
        case .separator: Tokens.Space.x3
        case .placeholder: Tokens.Space.x2
        case .bookmark, .newTab, .tab, .bookmarkDropZone: Tokens.Metric.rowHeight
        }
    }

    var isDraggable: Bool {
        switch self {
        case .bookmark, .tab: true
        default: false
        }
    }
}

/// The scrolling list of bookmarks and tabs. Rows are reused by identity and animate between layouts.
final class SidebarListView: NSView {
    weak var delegate: SidebarListDelegate?
    /// Shows this space instead of the current one (the neighbor that slides in during a swipe).
    var spaceOverride: UUID?
    /// In a private window, the header says "Private" instead of the space name.
    var privateLabel = false
    private var shownSpaceID: UUID? { spaceOverride ?? manager?.currentSpaceID }

    private var items: [SidebarItem] = []
    private var rows: [SidebarItem: NSView] = [:]
    private var drag: DragState?
    private var springWork: DispatchWorkItem?
    var isDragging: Bool { drag != nil }
    private let rowGap: CGFloat = Tokens.Space.x1

    struct DragState {
        let item: SidebarItem
        let view: NSView
        /// Pointer position relative to the floating row's corner, in screen points.
        var grab: NSPoint
        /// Where it would land in this list; nil while the pointer is somewhere else.
        var targetSection: Section?
        var targetIndex: Int
        var hoverSpace: UUID?
        let panel: NSPanel
        /// A tab row the dragged tab rests on: dropping opens them side by side.
        var splitTarget: SplitDrop?
    }

    /// The bookmark area (and its drop zone) opens only once a drag heads up toward it, so rows don't jump when a drag starts.
    private var bookmarkZoneOpen = false

    /// A tab being carried in from another window: where its gap opens in this list.
    private var externalIndex: Int?

    enum Section { case bookmarks, tabs }

    override var isFlipped: Bool { true }

    // MARK: Model

    private var manager: TabManager? { delegate?.tabManager }

    private func buildItems(includeEmptyBookmarkSection: Bool = false) -> [SidebarItem] {
        guard let manager else { return [] }
        var result: [SidebarItem] = [.header]
        let spaceID = spaceOverride ?? manager.currentSpaceID
        let bookmarks = Library.shared.bookmarks(in: spaceID)
        let collapsed = Self.isCollapsed(spaceID) && !includeEmptyBookmarkSection
        // Collapsed, the section still shows the pinned page you're on, so where you are never disappears.
        let shown = collapsed ? bookmarks.filter { $0.id == manager.selectedTab?.bookmarkID } : bookmarks
        result += shown.map { .bookmark($0.id) }
        if bookmarks.isEmpty && includeEmptyBookmarkSection { result.append(.bookmarkDropZone) }
        if !shown.isEmpty || includeEmptyBookmarkSection { result.append(.separator) }
        result.append(.newTab)
        // The right half of a split rides in its left half's row.
        let rightHalves = Set(manager.splits.map(\.right))
        result += manager.tabs(in: spaceID).filter { !rightHalves.contains($0.id) }.map { .tab($0.id) }
        return result
    }

    // MARK: Layout

    /// Frames for a list of items stacked top to bottom.
    private func frames(for items: [SidebarItem]) -> [(SidebarItem, NSRect)] {
        var y: CGFloat = 0
        var result: [(SidebarItem, NSRect)] = []
        for item in items {
            let h = item.height
            result.append((item, NSRect(x: 0, y: y, width: bounds.width, height: h)))
            y += h + (item == .separator || item == .header ? 0 : rowGap)
        }
        return result
    }

    var contentHeight: CGFloat {
        (frames(for: drag == nil ? items : displayItems()).last?.1.maxY ?? 0) + Tokens.Space.x2
    }

    func reload(animated: Bool) {
        guard drag == nil else { return }
        items = buildItems()
        apply(items: displayItems(), animated: animated)
    }

    private func apply(items displayed: [SidebarItem], animated: Bool) {
        let layout = frames(for: displayed)
        let visible = Set(displayed)

        // Leaving rows fade out where they are.
        for (item, view) in rows where !visible.contains(item) && view !== drag?.view {
            rows[item] = nil
            if animated {
                Tokens.Motion.animate(Tokens.Motion.feedback, { view.animator().alphaValue = 0 }, completion: { view.removeFromSuperview() })
            } else {
                view.removeFromSuperview()
            }
        }

        var changes: [() -> Void] = []
        for (item, frame) in layout {
            if let view = rows[item] {
                configure(view, for: item)
                if view === drag?.view { continue }
                if view.frame != frame {
                    if animated { changes.append { view.animator().frame = frame } } else { view.frame = frame }
                }
            } else {
                let view = makeView(for: item)
                rows[item] = view
                configure(view, for: item)
                view.frame = frame
                addSubview(view, positioned: .below, relativeTo: drag?.view)
                if animated {
                    view.alphaValue = 0
                    changes.append { view.animator().alphaValue = 1 }
                }
            }
        }
        if !changes.isEmpty {
            Tokens.Motion.animate { changes.forEach { $0() } }
        }
        updateDocumentHeight()
        pinHeader()
    }

    private func updateDocumentHeight() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let height = max(contentHeight, clip.bounds.height)
        if frame.height != height { setFrameSize(NSSize(width: clip.bounds.width, height: height)) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard oldSize.width != bounds.width else { return }
        for (item, frame) in frames(for: drag == nil ? items : displayItems()) {
            if let view = rows[item], view !== drag?.view { view.frame = frame }
        }
        drag?.view.frame.size.width = bounds.width
    }

    // MARK: Rows

    private func makeView(for item: SidebarItem) -> NSView {
        switch item {
        case .header:
            let header = SpaceHeaderView()
            header.onClick = { [weak self] _ in self?.toggleCollapsed() }
            header.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: .header) }
            return header
        case .separator:
            return SeparatorRowView()
        case .placeholder:
            return InsertionLineView()
        case .bookmarkDropZone:
            return DropZoneView(text: "Drop here to bookmark")
        case .newTab:
            let row = NewTabRowView()
            row.onClick = { [weak self] _ in self?.delegate?.listNewTab() }
            return row
        case .tab(let id):
            let row = TabRowView()
            row.onClick = { [weak self, weak row] event in
                guard let self, let row, let tab = row.tab else { return }
                // A split row: each half selects its own page.
                if row.half(at: row.convert(event.locationInWindow, from: nil)) == 1, let partner = row.partner {
                    self.delegate?.listSelect(partner)
                } else {
                    self.delegate?.listSelect(tab)
                }
                _ = id
            }
            row.onMiddleClick = { [weak self, weak row] in
                if let tab = row?.tab { self?.delegate?.listClose(tab) }
            }
            row.onDoubleClick = { [weak row] in row?.beginRename() }
            row.onRename = { [weak row] name in row?.tab?.customTitle = name.isEmpty ? nil : name }
            row.onClose = { [weak self, weak row] in
                if let tab = row?.tab { self?.delegate?.listClose(tab) }
            }
            row.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: item) }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDrag(item, view: row, event: event)
            }
            observeHover(row)
            return row
        case .bookmark(let id):
            let row = TabRowView()
            row.isBookmark = true
            row.onDoubleClick = { [weak row] in row?.beginRename() }
            row.onRename = { [weak self] name in
                guard !name.isEmpty else { return }
                self?.delegate?.listRenameBookmark(id, to: name)
            }
            row.onClick = { [weak self] _ in
                guard let self, let bookmark = Library.shared.bookmark(id) else { return }
                self.delegate?.listOpenBookmark(bookmark)
            }
            row.onClose = { [weak self, weak row] in
                if let tab = row?.tab { self?.delegate?.listClose(tab) }
            }
            row.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: item) }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDrag(item, view: row, event: event)
            }
            observeHover(row)
            return row
        }
    }

    private func configure(_ view: NSView, for item: SidebarItem) {
        guard let manager else { return }
        let selected = manager.selectedTab(in: shownSpaceID ?? manager.currentSpaceID)
        switch item {
        case .header:
            let spaceID = shownSpaceID ?? manager.currentSpaceID
            let spaceName = Library.shared.space(spaceID)?.name ?? ""
            (view as? SpaceHeaderView)?.canCollapse = !Library.shared.bookmarks(in: spaceID).isEmpty
            (view as? SpaceHeaderView)?.isCollapsed = Self.isCollapsed(spaceID)
            (view as? SpaceHeaderView)?.label.stringValue = privateLabel ? "Private · \(spaceName)" : spaceName
            view.needsLayout = true

        case .tab(let id):
            guard let row = view as? TabRowView, let tab = manager.tab(with: id) else { return }
            row.configure(tab: tab)
            // Both halves of a split show as open.
            let partner = manager.partner(of: tab)
            row.configure(partner: partner)
            row.isSelected = tab === selected || (partner != nil && partner === selected)
            row.focusedHalf = partner != nil && partner === selected ? 1 : 0
            row.freshness = SiteTint.freshness(lastActivated: tab.lastActivated)
        case .bookmark(let id):
            guard let row = view as? TabRowView, let bookmark = Library.shared.bookmark(id) else { return }
            let tab = manager.bookmarkTab(for: id)
            row.bookmarkIcon = FaviconStore.shared.cachedIcon(for: bookmark.url)
            if row.bookmarkIcon == nil { FaviconStore.shared.prefetch(for: bookmark.url) }
            // Moved on from its pinned page: the row shows where it is now, and its button goes back.
            let away = manager.isAway(id)
            row.isAway = away
            row.fixedTitle = away ? nil : bookmark.title
            row.isUnloaded = tab == nil
            row.configure(tab: tab)
            row.isSelected = tab != nil && tab === selected
        default:
            break
        }
    }

    /// Refreshes selection, fading and content without changing layout.
    func refreshRows() {
        for (item, view) in rows { configure(view, for: item) }
    }

    var headerView: NSView? { rows[.header] }

    /// The space's name stays at the top while the list scrolls, so you can always fold its bookmarks. It gets the
    /// sidebar's own color behind it once rows pass under it.
    func pinHeader() {
        guard let header = rows[.header] as? SpaceHeaderView, header !== drag?.view else { return }
        let top = max(0, visibleRect.minY)
        let stuck = top > 0.5
        Tokens.Motion.withoutAnimation {
            header.frame.origin.y = top
            header.layer?.zPosition = 10
            let tint = (window?.windowController as? BrowserWindowController)?.root.sidebarContainer.tint
            header.layer?.backgroundColor = stuck ? tint.map { cgColor($0) } : nil
        }
    }

    // MARK: Folding bookmarks

    private static let collapsedKey = "CollapsedBookmarkSpaces"

    static func isCollapsed(_ spaceID: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []).contains(spaceID.uuidString)
    }

    private func toggleCollapsed() {
        guard let manager, !Library.shared.bookmarks(in: manager.currentSpaceID).isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        let id = manager.currentSpaceID.uuidString
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: Self.collapsedKey)
        reload(animated: true)
    }

    func row(for tab: Tab) -> NSView? {
        if let bookmarkID = tab.bookmarkID { return rows[.bookmark(bookmarkID)] }
        return rows[.tab(tab.id)]
    }

    private func observeHover(_ row: TabRowView) {
        row.hoverChanged = { [weak self, weak row] hovering in
            guard let self, let row, self.drag == nil else { return }
            if hovering {
                var bookmark: Bookmark?
                if case .bookmark(let id)? = self.rows.first(where: { $0.value === row })?.key { bookmark = Library.shared.bookmark(id) }
                self.delegate?.listHover(row.tab, row: row, bookmark: bookmark)
            } else {
                self.delegate?.listHover(nil, row: nil, bookmark: nil)
            }
        }
    }

    // MARK: Dragging
    //
    // The dragged row lifts into its own small floating window, so it moves freely above everything:
    // within the list, across spaces (hold over a dot), into another Zigzag window, or out to make a new one.

    private func displayItems() -> [SidebarItem] {
        if let drag {
            return withPlaceholder(buildItems(includeEmptyBookmarkSection: bookmarkZoneOpen && drag.targetSection != nil).filter { $0 != drag.item },
                                   section: drag.targetSection, index: drag.targetIndex)
        }
        if let externalIndex { return withPlaceholder(buildItems(), section: .tabs, index: externalIndex) }
        return items
    }

    private func withPlaceholder(_ items: [SidebarItem], section: Section?, index: Int) -> [SidebarItem] {
        var base = items
        switch section {
        case .bookmarks:
            if let zone = base.firstIndex(of: .bookmarkDropZone) {
                base[zone] = .placeholder
            } else {
                let start = (base.firstIndex(of: .header) ?? 0) + 1
                base.insert(.placeholder, at: start + index)
            }
        case .tabs:
            let start = (base.firstIndex(of: .newTab) ?? base.count - 1) + 1
            base.insert(.placeholder, at: min(start + index, base.count))
        case nil:
            base.removeAll { $0 == .bookmarkDropZone }
        }
        return base
    }

    /// Works out where the dragged row would land from the pointer position, against the list without it.
    private func target(at y: CGFloat, dragging item: SidebarItem?) -> (Section, Int) {
        let base = buildItems(includeEmptyBookmarkSection: item != nil && bookmarkZoneOpen).filter { $0 != item }
        let layout = frames(for: base)
        let separatorMid = layout.first { $0.0 == .separator }.map { $0.1.midY } ?? 0
        if item != nil, y < separatorMid {
            let count = layout.filter { if case .bookmark = $0.0 { return $0.1.midY < y } else { return false } }.count
            return (.bookmarks, count)
        }
        let count = layout.filter { if case .tab = $0.0 { return $0.1.midY < y } else { return false } }.count
        return (.tabs, count)
    }

    /// The sidebar list under a screen point, in whichever window is in front there.
    private static func list(at screenPoint: NSPoint) -> (BrowserWindowController, SidebarListView)? {
        for window in NSApp.orderedWindows where window.isVisible && window.frame.contains(screenPoint) {
            guard let controller = window.windowController as? BrowserWindowController else { return nil }
            let container = controller.root.sidebarContainer
            guard controller.root.sidebarVisible || controller.root.isSidebarFloatingVisible else { return nil }
            let local = container.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            return container.bounds.contains(local) ? (controller, controller.sidebar.list) : nil
        }
        return nil
    }

    private static func window(at screenPoint: NSPoint) -> BrowserWindowController? {
        NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(screenPoint) }?.windowController as? BrowserWindowController
    }

    /// Another window's tab hovering this list: open a gap where it would land (nil to close it).
    func externalHover(at screenPoint: NSPoint?) {
        var index: Int?
        if let screenPoint, let window {
            let y = convert(window.convertPoint(fromScreen: screenPoint), from: nil).y
            index = target(at: y, dragging: nil).1
        }
        guard index != externalIndex else { return }
        externalIndex = index
        apply(items: displayItems(), animated: true)
    }

    private func liftedImage(of view: NSView) -> NSImage? {
        guard let layer = view.layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Layers draw flipped relative to the bitmap; flip so the row isn't upside down.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func makePanel(for view: NSView, at screenRect: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: screenRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.appearance = window?.effectiveAppearance
        let content = ColorView(color: Tokens.Color.panelBackground)
        content.wantsLayer = true
        content.layer?.cornerRadius = Tokens.Radius.row
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: screenRect.size))
        (view as? SidebarRowView)?.isLifted = true
        imageView.image = liftedImage(of: view)
        (view as? SidebarRowView)?.isLifted = false
        content.addSubview(imageView)
        panel.contentView = content
        return panel
    }

    private func beginDrag(_ item: SidebarItem, view: NSView, event: NSEvent) -> Bool {
        guard let window, item.isDraggable else { return false }
        delegate?.listHover(nil, row: nil, bookmark: nil)
        bookmarkZoneOpen = !Library.shared.bookmarks(in: manager?.currentSpaceID ?? UUID()).isEmpty && !Self.isCollapsed(manager?.currentSpaceID ?? UUID())
        let start = convert(event.locationInWindow, from: nil)
        let (section, index) = target(at: start.y, dragging: item)
        let rowScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let panel = makePanel(for: view, at: rowScreen)
        drag = DragState(item: item, view: view, grab: NSPoint(x: mouse.x - rowScreen.minX, y: mouse.y - rowScreen.minY),
                         targetSection: section, targetIndex: index, panel: panel)
        view.alphaValue = 0
        panel.alphaValue = 1
        panel.orderFront(nil)
        // Picked up: it lifts a touch and turns see-through, so you can see where it's going.
        Tokens.Motion.animate(Tokens.Motion.feedback) {
            panel.animator().setFrame(rowScreen.insetBy(dx: -3, dy: -1), display: true)
            panel.animator().alphaValue = 0.6
        }
        apply(items: displayItems(), animated: true)

        var lastEvent = event
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            lastEvent = event
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.dragMoved(to: event)
        }
        endDrag(with: lastEvent)
        return true
    }

    struct SplitDrop: Equatable {
        let id: UUID
        let onRight: Bool
    }

    /// The tab row whose middle the pointer is over, and which half: where a split would open.
    /// The row's top and bottom edges stay free for reordering.
    private func splitTarget(at point: NSPoint, dragging item: SidebarItem) -> SplitDrop? {
        guard case .tab(let draggedID) = item, let manager else { return nil }
        for (candidate, view) in rows {
            guard case .tab(let id) = candidate, id != draggedID, let row = view as? TabRowView, row.partner == nil,
                  view.frame.insetBy(dx: 0, dy: 7).contains(point), manager.tab(with: id)?.url != nil else { continue }
            return SplitDrop(id: id, onRight: point.x > view.frame.midX)
        }
        return nil
    }

    /// The row the pointer is resting on; it becomes a split target after a short pause.
    private var splitCandidate: SplitDrop?
    private var splitWork: DispatchWorkItem?

    private func showSplitTarget(_ target: SplitDrop?) {
        drag?.splitTarget = target
        // One hint at a time: the gap stays, its line hides while a split is on offer.
        if let line = rows[.placeholder] {
            Tokens.Motion.animate(Tokens.Motion.feedback) { line.animator().alphaValue = target == nil ? 1 : 0 }
        }
        for (item, view) in rows {
            guard let row = view as? TabRowView else { continue }
            row.splitDropSide = target.flatMap { item == .tab($0.id) ? ($0.onRight ? 1 : 0) : nil }
        }
    }

    private weak var externalTarget: SidebarListView?
    private var edgeDirection: Int?
    private var edgeWork: DispatchWorkItem?

    /// Flips to the neighboring space after a short hold at the edge, and keeps flipping while held.
    private func scheduleEdgeFlip(_ direction: Int) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.drag != nil, self.edgeDirection == direction, let manager = self.manager else { return }
                let spaces = Library.shared.spaces
                guard let index = spaces.firstIndex(where: { $0.id == manager.currentSpaceID }), spaces.indices.contains(index + direction) else { return }
                self.delegate?.listSwitchSpaceDuringDrag(spaces[index + direction].id)
                self.scheduleEdgeFlip(direction)
            }
        }
        edgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func dragMoved(to event: NSEvent) {
        guard var drag, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        drag.panel.setFrameOrigin(NSPoint(x: mouse.x - drag.grab.x, y: mouse.y - drag.grab.y))

        let hit = Self.list(at: mouse)
        // Another window's list opens a gap for a tab; ours closes its gap meanwhile.
        if let (_, list) = hit, list !== self, case .tab = drag.item {
            if externalTarget !== list { externalTarget?.externalHover(at: nil) }
            externalTarget = list
            list.externalHover(at: mouse)
        } else if externalTarget != nil {
            externalTarget?.externalHover(at: nil)
            externalTarget = nil
        }

        // Over the favorites grid: it opens a slot for the tab, and the list closes its gap.
        var overFavorites = false
        if case .tab = drag.item, Self.window(at: mouse) === window.windowController {
            overFavorites = delegate?.listDragOverFavorites(at: window.convertPoint(fromScreen: mouse)) ?? false
        }

        // Over this window's page (not the sidebar): offer to open the tab beside it.
        if hit == nil, Self.window(at: mouse) === window.windowController, case .tab(let id) = drag.item, let tab = manager?.tab(with: id) {
            delegate?.listDragOverPage(at: window.convertPoint(fromScreen: mouse), tab: tab)
        } else if case .tab(let id) = drag.item, let tab = manager?.tab(with: id) {
            delegate?.listDragOverPage(at: NSPoint(x: -1000, y: -1000), tab: tab)
        }

        var section: Section? = nil
        var index = drag.targetIndex
        var candidate: SplitDrop?
        if let (_, list) = hit, list === self, !overFavorites {
            autoscroll(with: event)
            let point = convert(window.convertPoint(fromScreen: mouse), from: nil)
            if !bookmarkZoneOpen, let newTab = rows[.newTab], point.y < newTab.frame.maxY {
                bookmarkZoneOpen = true
            }
            candidate = self.splitTarget(at: point, dragging: drag.item)
            if candidate == nil {
                (section, index) = target(at: point.y, dragging: drag.item)
            } else {
                // Hold the gap still so the row under the pointer doesn't move away.
                (section, index) = (drag.targetSection, drag.targetIndex)
            }
        }
        if candidate != splitCandidate {
            splitCandidate = candidate
            splitWork?.cancel()
            if let active = drag.splitTarget, let candidate, active.id == candidate.id {
                // Already split-targeting this row: switching halves is immediate.
                drag.splitTarget = candidate
                self.drag = drag
                showSplitTarget(candidate)
            } else {
                drag.splitTarget = nil
                self.drag = drag
                showSplitTarget(nil)
                if let candidate {
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.drag != nil, self.splitCandidate == candidate else { return }
                            self.showSplitTarget(candidate)
                        }
                    }
                    splitWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                }
            }
            guard let refreshed = self.drag else { return }
            drag = refreshed
        }

        // Carry the tab to the sidebar's left or right edge and hold: the space flips that way.
        let container = (window.windowController as? BrowserWindowController)?.root.sidebarContainer
        let local = container.map { $0.convert(window.convertPoint(fromScreen: mouse), from: nil) }
        if let container, let local, local.y >= 0, local.y <= container.bounds.height,
           local.x > -Tokens.Space.x6, local.x < container.bounds.width + Tokens.Space.x12 {
            let zone = Tokens.Space.x10
            let edge: Int? = local.x < zone ? -1 : local.x > container.bounds.width - zone ? 1 : nil
            if edge != edgeDirection {
                edgeDirection = edge
                edgeWork?.cancel()
                if let edge { scheduleEdgeFlip(edge) }
            }
        } else if edgeDirection != nil {
            edgeDirection = nil
            edgeWork?.cancel()
        }

        // Holding over another space's dot opens that space, so you can drop the tab in place there.
        let hovered = delegate?.listDragHoverSpace(at: window.convertPoint(fromScreen: mouse))
        if hovered != drag.hoverSpace {
            springWork?.cancel()
            if let hovered, hovered != manager?.currentSpaceID {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.drag?.hoverSpace == hovered else { return }
                        self.delegate?.listSwitchSpaceDuringDrag(hovered)
                        self.drag?.hoverSpace = nil
                    }
                }
                springWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
        }
        drag.hoverSpace = hovered
        let changed = section != drag.targetSection || index != drag.targetIndex
        drag.targetSection = section
        drag.targetIndex = index
        self.drag = drag
        if changed { apply(items: displayItems(), animated: true) }
    }

    private func endDrag(with event: NSEvent) {
        guard let drag else { return }
        drop(drag, event: event)
        settle(drag)
    }

    /// The lifted row glides into the slot it landed in, then becomes the row again.
    /// If it went somewhere else (a split, favorites, another window), it just fades.
    private func settle(_ drag: DragState) {
        let panel = drag.panel
        if let row = rows[drag.item], row === drag.view, row.superview === self, let window, !Tokens.Motion.isKeyboardDriven {
            let target = window.convertToScreen(row.convert(row.bounds, to: nil))
            Tokens.Motion.animate(Tokens.Motion.snappy, {
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }, completion: {
                row.alphaValue = 1
                panel.orderOut(nil)
            })
        } else {
            drag.view.alphaValue = 1
            Tokens.Motion.animate(Tokens.Motion.feedback, { panel.animator().alphaValue = 0 }, completion: { panel.orderOut(nil) })
        }
    }

    private func drop(_ drag: DragState, event: NSEvent) {
        guard let manager else { return }
        self.drag = nil
        springWork?.cancel()
        edgeWork?.cancel()
        edgeDirection = nil
        splitWork?.cancel()
        splitCandidate = nil
        for view in rows.values { (view as? TabRowView)?.splitDropSide = nil }

        // Onto the favorites grid.
        if case .tab(let id) = drag.item, let tab = manager.tab(with: id), delegate?.listDropOnFavorites(tab) == true {
            rows[drag.item] = nil
            drag.view.removeFromSuperview()
            reload(animated: true)
            return
        }

        // Onto another tab's row: the two open side by side.
        if case .tab(let id) = drag.item, let split = drag.splitTarget,
           let tab = manager.tab(with: id), let target = manager.tab(with: split.id) {
            delegate?.listSplit(target, with: tab, otherOnRight: split.onRight)
            reload(animated: true)
            return
        }
        delegate?.listDragEnded()
        let mouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let external = externalTarget
        externalTarget = nil
        external?.externalHover(at: nil)

        // Onto this window's page: open it in split view beside what's showing.
        if case .tab(let id) = drag.item, let tab = manager.tab(with: id), Self.list(at: mouse) == nil,
           Self.window(at: mouse) === window?.windowController, delegate?.listDropOnPage(tab) == true {
            reload(animated: true)
            return
        }

        // Into another window's sidebar, at the gap that opened there.
        if case .tab(let id) = drag.item, let tab = manager.tab(with: id), let external,
           let (controller, list) = Self.list(at: mouse), list === external, controller.tabManager !== manager,
           delegate?.listMoveToWindow(tab, controller: controller, index: list.dropIndex(at: mouse)) == true {
            rows[drag.item] = nil
            drag.view.removeFromSuperview()
            reload(animated: true)
            return
        }

        // Somewhere that isn't any Zigzag window: the tab becomes a new window there.
        if case .tab(let id) = drag.item, let tab = manager.tab(with: id), Self.window(at: mouse) == nil,
           delegate?.listDropOutside(tab, at: mouse) == true {
            rows[drag.item] = nil
            drag.view.removeFromSuperview()
            reload(animated: true)
            return
        }

        if let space = drag.hoverSpace, space != manager.currentSpaceID {
            // Dropped on another space's dot.
            switch drag.item {
            case .tab(let id): if let tab = manager.tab(with: id) { delegate?.listMove(tab, to: 0, in: space) }
            case .bookmark(let id): delegate?.listMoveBookmark(id, to: Int.max, in: space)
            default: break
            }
            reload(animated: true)
            return
        }

        switch (drag.item, drag.targetSection) {
        case (.tab(let id), .tabs?):
            if let tab = manager.tab(with: id) { delegate?.listMove(tab, to: drag.targetIndex, in: manager.currentSpaceID) }
        case (.tab(let id), .bookmarks?):
            if let tab = manager.tab(with: id) {
                if tab.spaceID != manager.currentSpaceID { delegate?.listMove(tab, to: 0, in: manager.currentSpaceID) }
                delegate?.listBookmark(tab, at: drag.targetIndex, in: manager.currentSpaceID)
            }
        case (.bookmark(let id), .bookmarks?):
            delegate?.listMoveBookmark(id, to: drag.targetIndex, in: manager.currentSpaceID)
        case (.bookmark(let id), .tabs?):
            // The row changes identity; the new tab row takes the placeholder's spot.
            rows[.bookmark(id)] = nil
            drag.view.removeFromSuperview()
            delegate?.listUnbookmark(id, to: drag.targetIndex)
        default:
            break
        }
        reload(animated: true)
    }

    /// Redraws for a new space while a drag is in progress (the space slide is animated by the sidebar).
    func refreshDuringDrag() {
        guard drag != nil else { return }
        apply(items: displayItems(), animated: false)
    }

    /// Where a tab from another window would land, for a screen point over this list.
    func dropIndex(at screenPoint: NSPoint) -> Int {
        guard let window else { return 0 }
        return target(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil).y, dragging: nil).1
    }
}
