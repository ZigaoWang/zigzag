import AppKit

protocol SidebarListDelegate: AnyObject {
    var tabManager: TabManager { get }
    func listSelect(_ tab: Tab)
    func listOpenBookmark(_ bookmark: Bookmark)
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
        case .placeholder, .bookmark, .newTab, .tab, .bookmarkDropZone: Tokens.Metric.rowHeight
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
        var grabOffset: CGFloat
        var targetSection: Section
        var targetIndex: Int
        var hoverSpace: UUID?
    }

    enum Section { case bookmarks, tabs }

    override var isFlipped: Bool { true }

    // MARK: Model

    private var manager: TabManager? { delegate?.tabManager }

    private func buildItems(includeEmptyBookmarkSection: Bool = false) -> [SidebarItem] {
        guard let manager else { return [] }
        var result: [SidebarItem] = [.header]
        let spaceID = spaceOverride ?? manager.currentSpaceID
        let bookmarks = Library.shared.bookmarks(in: spaceID)
        result += bookmarks.map { .bookmark($0.id) }
        if bookmarks.isEmpty && includeEmptyBookmarkSection { result.append(.bookmarkDropZone) }
        if !bookmarks.isEmpty || includeEmptyBookmarkSection { result.append(.separator) }
        result.append(.newTab)
        result += manager.tabs(in: spaceID).map { .tab($0.id) }
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
        apply(items: items, animated: animated)
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
            if item == .placeholder { continue }
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
            header.onClick = { [weak self, weak header] _ in
                guard let header else { return }
                self?.delegate?.listEditSpace(anchor: header)
            }
            header.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: .header) }
            return header
        case .separator, .placeholder:
            return SeparatorRowView()
        case .bookmarkDropZone:
            return DropZoneView(text: "Drop here to bookmark")
        case .newTab:
            let row = NewTabRowView()
            row.onClick = { [weak self] _ in self?.delegate?.listNewTab() }
            return row
        case .tab(let id):
            let row = TabRowView()
            row.onClick = { [weak self, weak row] event in
                guard let self, let tab = row?.tab else { return }
                self.delegate?.listSelect(tab)
                _ = id
            }
            row.onMiddleClick = { [weak self, weak row] in
                if let tab = row?.tab { self?.delegate?.listClose(tab) }
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
        case .bookmark(let id):
            let row = TabRowView()
            row.isBookmark = true
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
            let spaceName = Library.shared.space(shownSpaceID ?? manager.currentSpaceID)?.name ?? ""
            (view as? SpaceHeaderView)?.label.stringValue = privateLabel ? "Private · \(spaceName)" : spaceName
            view.needsLayout = true

        case .tab(let id):
            guard let row = view as? TabRowView, let tab = manager.tab(with: id) else { return }
            row.configure(tab: tab)
            row.isSelected = tab === selected
            row.freshness = SiteTint.freshness(lastActivated: tab.lastActivated)
        case .bookmark(let id):
            guard let row = view as? TabRowView, let bookmark = Library.shared.bookmark(id) else { return }
            let tab = manager.bookmarkTab(for: id)
            row.bookmarkIcon = FaviconStore.shared.cachedIcon(for: bookmark.url)
            if row.bookmarkIcon == nil { FaviconStore.shared.prefetch(for: bookmark.url) }
            row.fixedTitle = bookmark.title
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

    private func displayItems() -> [SidebarItem] {
        guard let drag else { return items }
        var base = buildItems(includeEmptyBookmarkSection: true).filter { $0 != drag.item }
        switch drag.targetSection {
        case .bookmarks:
            if let zone = base.firstIndex(of: .bookmarkDropZone) {
                base[zone] = .placeholder
            } else {
                let start = (base.firstIndex(of: .header) ?? 0) + 1
                base.insert(.placeholder, at: start + drag.targetIndex)
            }
        case .tabs:
            let start = (base.firstIndex(of: .newTab) ?? base.count - 1) + 1
            base.insert(.placeholder, at: min(start + drag.targetIndex, base.count))
        }
        return base
    }

    /// Works out where the dragged row would land from the pointer position, against the list without it.
    private func target(at y: CGFloat, dragging item: SidebarItem) -> (Section, Int) {
        let base = buildItems(includeEmptyBookmarkSection: true).filter { $0 != item }
        let layout = frames(for: base)
        let separatorMid = layout.first { $0.0 == .separator }.map { $0.1.midY } ?? 0
        if y < separatorMid {
            let count = layout.filter { if case .bookmark = $0.0 { return $0.1.midY < y } else { return false } }.count
            return (.bookmarks, count)
        }
        let count = layout.filter { if case .tab = $0.0 { return $0.1.midY < y } else { return false } }.count
        return (.tabs, count)
    }

    private func beginDrag(_ item: SidebarItem, view: NSView, event: NSEvent) -> Bool {
        guard let window, item.isDraggable else { return false }
        delegate?.listHover(nil, row: nil, bookmark: nil)
        let start = convert(event.locationInWindow, from: nil)
        let (section, index) = target(at: start.y, dragging: item)
        drag = DragState(item: item, view: view, grabOffset: start.y - view.frame.minY, targetSection: section, targetIndex: index)
        (view as? SidebarRowView)?.isLifted = true
        view.removeFromSuperview()
        addSubview(view)
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

    private func dragMoved(to event: NSEvent) {
        guard var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let maxY = max(0, contentHeight - drag.view.frame.height)
        Tokens.Motion.withoutAnimation {
            drag.view.frame.origin.y = min(max(point.y - drag.grabOffset, 0), maxY)
        }
        autoscroll(with: event)

        let hovered = delegate?.listDragHoverSpace(at: event.locationInWindow)
        if hovered != drag.hoverSpace {
            springWork?.cancel()
            if let hovered, hovered != manager?.currentSpaceID {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.drag?.hoverSpace == hovered else { return }
                        self.delegate?.listSwitchSpaceDuringDrag(hovered)
                        self.drag?.hoverSpace = nil
                        self.apply(items: self.displayItems(), animated: false)
                    }
                }
                springWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
        }
        drag.hoverSpace = hovered
        let (section, index) = target(at: point.y, dragging: drag.item)
        let changed = section != drag.targetSection || index != drag.targetIndex
        drag.targetSection = section
        drag.targetIndex = index
        self.drag = drag
        if changed { apply(items: displayItems(), animated: true) }
    }

    private func endDrag(with event: NSEvent) {
        guard let drag, let manager else { return }
        self.drag = nil
        springWork?.cancel()
        (drag.view as? SidebarRowView)?.isLifted = false
        delegate?.listDragEnded()

        if let space = drag.hoverSpace, space != manager.currentSpaceID {
            // Dropped on another space's dot.
            switch drag.item {
            case .tab(let id): if let tab = manager.tab(with: id) { delegate?.listMove(tab, to: 0, in: space) }
            case .bookmark(let id): Library.shared.moveBookmark(id, to: Int.max, in: space)
            default: break
            }
            reload(animated: true)
            return
        }

        switch (drag.item, drag.targetSection) {
        case (.tab(let id), .tabs):
            if let tab = manager.tab(with: id) { delegate?.listMove(tab, to: drag.targetIndex, in: manager.currentSpaceID) }
        case (.tab(let id), .bookmarks):
            if let tab = manager.tab(with: id) {
                if tab.spaceID != manager.currentSpaceID { delegate?.listMove(tab, to: 0, in: manager.currentSpaceID) }
                delegate?.listBookmark(tab, at: drag.targetIndex, in: manager.currentSpaceID)
            }
        case (.bookmark(let id), .bookmarks):
            Library.shared.moveBookmark(id, to: drag.targetIndex, in: manager.currentSpaceID)
        case (.bookmark(let id), .tabs):
            // The row changes identity; the new tab row takes the placeholder's spot.
            rows[.bookmark(id)] = nil
            drag.view.removeFromSuperview()
            delegate?.listUnbookmark(id, to: drag.targetIndex)
        default:
            break
        }
        reload(animated: true)
    }
}
