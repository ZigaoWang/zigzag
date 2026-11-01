import AppKit

protocol SidebarListDelegate: AnyObject {
    var tabManager: TabManager { get }
    func listSelect(_ tab: Tab)
    func listOpenBookmark(_ bookmark: Bookmark)
    func listRenameBookmark(_ id: UUID, to name: String)
    func listClose(_ tab: Tab)
    func listNewTab()
    /// Clear: every tab in the space but the one you're on; with only that one left, it too.
    func listClearTabs()
    func listSetFolderOpen(_ id: UUID, _ open: Bool)
    func listRenameFolder(_ id: UUID, to name: String)
    /// Puts a pinned page at the end of a folder, or takes it out of any (nil).
    func listSetFolder(of bookmarkID: UUID, to folderID: UUID?)
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?)
    func listMoveFolder(_ id: UUID, to index: Int, in spaceID: UUID)
    func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?)
    func listMenu(for item: SidebarItem) -> NSMenu?
    /// The menu for several picked rows at once.
    func listMenu(forMarked items: [SidebarItem]) -> NSMenu?
    func listRenameSpace()
    func listEditSpace(anchor: NSView)
    /// Returns the space under a window point while dragging (the space dots), highlighting it.
    func listDragHoverSpace(at windowPoint: NSPoint) -> UUID?
    /// The drag is over: nothing is highlighted for it any more (the dots, the favorites, the page).
    func listDragEnded()
    /// The drop has been handled, whatever it did.
    func listDropFinished()
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID)
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID)
    func listUnbookmark(_ bookmarkID: UUID, to index: Int)
    /// While dragging, hovering a space's dot opens that space so the tab can be dropped into place.
    func listSwitchSpaceDuringDrag(_ spaceID: UUID)
    /// A tab dropped outside the window: into another window, or a new one. Returns true if handled.
    func listDropOutside(_ tab: Tab, at screenPoint: NSPoint) -> Bool
    /// A tab dropped into another window's sidebar at an index. Returns true if handled.
    func listMoveToWindow(_ tab: Tab, controller: BrowserWindowController, index: Int) -> Bool
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID)
    /// A tab or bookmark dragged over the favorites grid (nil: it's not over this window). Returns true while it's
    /// over the grid.
    func listDragOverFavorites(at windowPoint: NSPoint?, carrying: TabManager.SplitSide?) -> Bool
    /// A tab dropped on another tab's middle: the two open side by side.
    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool)
    /// A tab dropped on a pinned page's middle: a pinned split.
    func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool)
    /// A pinned page dropped on a tab's middle: a split of tabs.
    func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool)
    /// Dropped on the favorites grid. Returns true if it became a favorite.
    func listDropOnFavorites(_ tab: Tab) -> Bool
    /// A pinned page dropped on the favorites grid: it becomes a favorite, open or not.
    func listDropBookmarkOnFavorites(_ bookmarkID: UUID) -> Bool
    /// A favorite's tile, for a row that became one to land on.
    func listFavoriteTile(for bookmarkID: UUID) -> NSView?
    /// A tab dragged over the page: show which half it would open in (nil: it's not over the page).
    func listDragOverPage(at windowPoint: NSPoint?, tab: Tab)
    /// Dropped on the page: open it in split view beside the current page. Returns true if it did.
    func listDropOnPage(_ tab: Tab) -> Bool
}

enum SidebarItem: Hashable {
    case header
    case bookmark(UUID)
    /// A folder of pinned pages; its pages follow it, set in, while it's open.
    case folder(UUID)
    case separator
    case newTab
    case tab(UUID)
    case placeholder

    /// A tab or a pinned page, a split's two pages included (they become one split favorite): what the favorites
    /// grid takes.
    var canBeFavorite: Bool {
        switch self {
        case .tab, .bookmark: true
        default: false
        }
    }

    var height: CGFloat {
        switch self {
        case .header: Tokens.Space.x6 + Tokens.Space.x1
        // Room enough that Clear, on the line, isn't in the way of New Tab just below it.
        case .separator: Tokens.Space.x6
        case .placeholder, .bookmark, .folder, .newTab, .tab: Tokens.Metric.rowHeight
        }
    }

    var isDraggable: Bool {
        switch self {
        case .bookmark, .tab, .folder: true
        default: false
        }
    }
    /// Can be picked along with others (⌘-click, ⇧-click).
    var isPickable: Bool {
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
    /// Rows picked with ⌘-click or ⇧-click, in list order, to drag or act on together.
    private(set) var marked: [SidebarItem] = []
    private var springWork: DispatchWorkItem?
    private var wasOverFavorites = false
    private var lastFolderTarget: UUID?
    private var lastSplitTarget: SplitDrop?
    var isDragging: Bool { drag != nil }
    private let rowGap: CGFloat = Tokens.Space.x1

    struct DragState {
        let item: SidebarItem
        let view: NSView
        let copy: CarriedCopy
        /// What lands together, in list order: the picked rows, or just this one.
        let together: [SidebarItem]
        /// Rows that leave with it and so don't count where it lands: a folder's pages go with the folder.
        let carried: Set<SidebarItem>
        /// Rows left faint in their places meanwhile.
        let faint: [SidebarItem]
        /// Where it would land in this list; nil while the pointer is somewhere else.
        var targetSection: Section?
        var targetIndex: Int
        /// The space dot under the pointer: let go there, it moves into that space.
        var hoverSpace: UUID?
        /// A folder row the dragged page or tab rests on: dropping puts it in that folder.
        var folderTarget: UUID?
        /// A tab's or pinned page's row the dragged one rests on: dropping opens them side by side.
        var splitTarget: SplitDrop?
        /// Where it was picked up from; dropping there changes nothing, so no line shows.
        var originSection: Section?
        var originIndex = 0
        /// The space it was picked up in; carried to another, it's no longer in the list on show.
        let originSpace: UUID
        /// Where the pointer is across the list: set in past a folder's last page, a drop stays in the folder.
        var pointX: CGFloat = 0
    }

    /// Something carried in from elsewhere (another window's tab, a favorite): where the line shows it would land.
    private var external: (section: Section, index: Int, pointX: CGFloat)?

    enum Section { case bookmarks, tabs }

    override var isFlipped: Bool { true }

    // MARK: Model

    private var manager: TabManager? { delegate?.tabManager }

    private func buildItems() -> [SidebarItem] {
        guard let manager else { return [] }
        var result: [SidebarItem] = [.header]
        let spaceID = spaceOverride ?? manager.currentSpaceID
        let bookmarks = Library.shared.bookmarks(in: spaceID)
        let collapsed = Self.isCollapsed(spaceID)
        // Collapsed, the section still shows the pinned page you're on, so where you are never disappears.
        let folders = Library.shared.folders(in: spaceID)
        indented = []
        // The right page of a pinned split rides in its left page's row, as a split among tabs does.
        let riders = Set(Library.shared.pinnedSplits(in: spaceID).map(\.right))
        let current = manager.selectedTab?.bookmarkID.map(Self.rowID)
        if collapsed {
            result += bookmarks.filter { $0.id == current }.map { .bookmark($0.id) }
        } else {
            // A folder sits where its first page is, its pages after it; a closed one still shows the page you're on.
            var folderOf: [UUID: BookmarkFolder] = [:]
            for folder in folders { for id in folder.bookmarkIDs { folderOf[id] = folder } }
            var placed: Set<UUID> = []
            // A new, empty folder sits at the top, where you'll see it and can drop pages in.
            for folder in folders where folder.bookmarkIDs.isEmpty { result.append(.folder(folder.id)) }
            for bookmark in bookmarks where !riders.contains(bookmark.id) {
                guard let folder = folderOf[bookmark.id] else { result.append(.bookmark(bookmark.id)); continue }
                guard placed.insert(folder.id).inserted else { continue }
                result.append(.folder(folder.id))
                let members = folder.isOpen ? folder.bookmarkIDs.filter { !riders.contains($0) } : folder.bookmarkIDs.filter { $0 == current }
                for id in members { result.append(.bookmark(id)); indented.insert(id) }
            }
        }
        let hasPinnedRows = result.contains { if case .bookmark = $0 { true } else if case .folder = $0 { true } else { false } }
        // The line above today's tabs, which carries Clear: there when there are pinned tabs above it or tabs to clear.
        let tabs = manager.tabs(in: spaceID)
        if hasPinnedRows || !tabs.isEmpty { result.append(.separator) }
        result.append(.newTab)
        // The right half of a split rides in its left half's row, when that row is here to carry it.
        let rowIDs = Set(tabs.map(\.id))
        let rightHalves = Set(manager.splits.filter { rowIDs.contains($0.left) }.map(\.right))
        result += tabs.filter { !rightHalves.contains($0.id) }.map { .tab($0.id) }
        return result
    }

    /// The pinned page whose row shows this one: itself, or for the right half of a pinned split, its left half.
    static func rowID(_ bookmarkID: UUID) -> UUID {
        Library.shared.pinnedSplit(containing: bookmarkID)?.left ?? bookmarkID
    }

    // MARK: Layout

    /// Frames for a list of items stacked top to bottom.
    private func frames(for items: [SidebarItem]) -> [(SidebarItem, NSRect)] {
        var y: CGFloat = 0
        var result: [(SidebarItem, NSRect)] = []
        for item in items {
            let h = item.height
            var inset: CGFloat = 0
            if case .bookmark(let id) = item, indented.contains(id) { inset = Self.folderIndent }
            result.append((item, NSRect(x: inset, y: y, width: bounds.width - inset, height: h)))
            y += h + (item == .separator || item == .header ? 0 : rowGap)
        }
        return result
    }

    var contentHeight: CGFloat {
        (frames(for: items).last?.1.maxY ?? 0) + Tokens.Space.x2
    }

    func reload(animated: Bool) {
        defer { marked = marked.filter { items.contains($0) }; if marked.count < 2 { marked = [] } }
        guard drag == nil else { return }
        items = buildItems()
        apply(items: items, animated: animated)
    }

    private func apply(items displayed: [SidebarItem], animated: Bool) {
        let layout = frames(for: displayed)
        let visible = Set(displayed)

        // A page that changes kind (a tab pinned with ⌘D, or a pinned page made a tab again) keeps one row that
        // glides from where it was to where it now belongs, instead of one fading out and another fading in.
        // Which page a row shows; for rows that are leaving, the page it showed last time, since an unpinned page has
        // already left its pinned item by now.
        func pageID(_ item: SidebarItem) -> UUID? {
            switch item {
            case .tab(let id): id
            case .bookmark(let id): manager?.bookmarkTab(for: id)?.id ?? shownPages[item]
            default: nil
            }
        }
        var departing: [UUID: NSRect] = [:]
        for (item, view) in rows where !visible.contains(item) && view !== drag?.view {
            if animated, let id = pageID(item) { departing[id] = view.frame }
        }

        // Leaving rows fade out where they are.
        for (item, view) in rows where !visible.contains(item) && view !== drag?.view {
            rows[item] = nil
            if let id = pageID(item), departing[id] != nil, displayed.contains(where: { pageID($0) == id }) {
                view.removeFromSuperview()
                continue
            }
            if animated {
                Tokens.Motion.animate(Tokens.Motion.feedback, { view.animator().alphaValue = 0 }, completion: { view.removeFromSuperview() })
            } else {
                view.removeFromSuperview()
            }
        }

        var changes: [() -> Void] = []
        var moves: [(NSView, NSRect)] = []
        for (item, frame) in layout {
            if let view = rows[item] {
                configure(view, for: item)
                if view === drag?.view { continue }
                if view.frame != frame {
                    if animated { moves.append((view, frame)) } else { view.frame = frame }
                }
            } else {
                let view = makeView(for: item)
                rows[item] = view
                configure(view, for: item)
                addSubview(view, positioned: .below, relativeTo: drag?.view)
                if animated, let id = pageID(item), let from = departing[id] {
                    view.frame = from
                    carry(view, to: frame)
                } else {
                    view.frame = frame
                    if animated {
                        view.alphaValue = 0
                        changes.append { view.animator().alphaValue = 1 }
                    }
                }
            }
        }
        // Rows slide on the render server, so a gap that moves again mid-slide carries on from where things are.
        // The rest make room at the same pace as a page being carried.
        for (view, frame) in moves {
            if Tokens.Motion.isKeyboardDriven {
                // A new tab (⌘T) is for typing at once: the list simply is in its new order.
                view.layer?.removeAnimation(forKey: "glide")
                Tokens.Motion.withoutAnimation { view.frame = frame }
            } else {
                Tokens.Motion.glide(view, to: frame, duration: Tokens.Motion.standard, timing: Tokens.Motion.easeInOut)
            }
        }
        if !changes.isEmpty { Tokens.Motion.animate { changes.forEach { $0() } } }
        // The carried row's faint stand-in, and the rows going with it, show only in its own space.
        drag?.view.isHidden = !carriedRowShown
        if carriedRowShown { for item in drag?.faint ?? [] { rows[item]?.alphaValue = CarriedCopy.faint } }
        shownPages = [:]
        for item in displayed { if let id = pageID(item) { shownPages[item] = id } }
        updateDocumentHeight()
        pinHeader()
    }

    /// The page each row showed at the last update.
    private var shownPages: [SidebarItem: UUID] = [:]

    /// A page moving between the tabs and the pinned section travels there for you to see: it lifts above the other
    /// rows with a soft shadow, glides to its new place, and settles back down.
    private func carry(_ view: NSView, to frame: NSRect) {
        guard !Tokens.Motion.reduceMotion else { view.frame = frame; return }
        view.wantsLayer = true
        addSubview(view)
        let layer = view.layer
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 10
        // Its shape given up front, so the shadow costs nothing to draw while it moves.
        layer?.shadowPath = CGPath(roundedRect: view.bounds, cornerWidth: Tokens.Radius.control, cornerHeight: Tokens.Radius.control, transform: nil)
        layer?.shadowOffset = CGSize(width: 0, height: isFlipped ? 4 : -4)
        let lift = CAKeyframeAnimation(keyPath: "shadowOpacity")
        lift.values = [0, 0.14, 0.14, 0]
        lift.keyTimes = [0, 0.25, 0.7, 1]
        lift.duration = Tokens.Motion.standard
        layer?.add(lift, forKey: "lift")
        Tokens.Motion.glide(view, to: frame, duration: Tokens.Motion.standard, timing: Tokens.Motion.easeInOut)
    }

    private func updateDocumentHeight() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let height = max(contentHeight, clip.bounds.height)
        if frame.height != height { setFrameSize(NSSize(width: clip.bounds.width, height: height)) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard oldSize.width != bounds.width else { return }
        for (item, frame) in frames(for: items) {
            if let view = rows[item], view !== drag?.view { view.frame = frame }
        }
        drag?.view.frame.size.width = bounds.width
    }

    // MARK: Folders

    /// Pinned pages shown inside an open folder, set in by this much.
    static let folderIndent: CGFloat = 14
    /// The pinned pages drawn inside a folder in the list as last built.
    private var indented: Set<UUID> = []

    /// The folder a drop at the gap would go into: right under an open folder, between two of its pages, or just
    /// after its last page with the pointer set in.
    private func folderForGap(in items: [SidebarItem], pointX: CGFloat) -> UUID? {
        guard let gap = items.firstIndex(of: .placeholder) else { return nil }
        let before = gap > 0 ? items[gap - 1] : nil
        let after = gap + 1 < items.count ? items[gap + 1] : nil
        func folder(of item: SidebarItem?) -> UUID? {
            if case .bookmark(let id)? = item, indented.contains(id) { return Library.shared.folderID(containing: id) }
            return nil
        }
        if case .folder(let id)? = before, Library.shared.folder(id)?.isOpen == true { return id }
        if let above = folder(of: before), above == folder(of: after) { return above }
        if let above = folder(of: before), pointX > Self.folderIndent + Tokens.Space.x2 { return above }
        return nil
    }

    /// A folder row under the pointer's middle, to drop a page into.
    private func folderRow(at point: NSPoint) -> UUID? {
        for (item, view) in rows {
            if case .folder(let id) = item, view.frame.insetBy(dx: 0, dy: 6).contains(point) { return id }
        }
        return nil
    }

    private func showFolderTarget(_ id: UUID?) {
        if let id, id != lastFolderTarget { Haptics.snap() }
        lastFolderTarget = id
        for (item, view) in rows {
            guard case .folder(let folderID) = item, let row = view as? FolderRowView else { continue }
            row.isDropTarget = folderID == id
        }
    }

    /// With the pointer on Clear, the rows it would close sink back; off it, they come back up.
    private func previewClear(_ on: Bool) {
        guard let manager else { return }
        let closing = on ? manager.tabsToClear(in: shownSpaceID ?? manager.currentSpaceID).tabs : []
        for view in rows.values {
            guard let row = view as? TabRowView, !row.isBookmark else { continue }
            row.isAboutToClear = closing.contains { $0 === row.tab || (row.partner != nil && $0 === row.partner) }
        }
    }

    /// Starts renaming a folder's row (a new folder, or Rename… in its menu).
    func renameFolder(_ id: UUID) {
        layoutSubtreeIfNeeded()
        (rows[.folder(id)] as? FolderRowView)?.beginRename()
    }

    // MARK: Hover

    /// Over the list: the space header offers Clear.
    private(set) var isPointerInside = false {
        didSet { (rows[.separator] as? SeparatorRowView)?.showsClear = showsClear }
    }
    /// Clear is offered under the pointer, never while something is being dragged past it.
    private var showsClear: Bool { isPointerInside && drag == nil }

    /// Hover follows where the pointer really is, once rows have moved under it during a drag.
    private func syncHover() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        isPointerInside = bounds.contains(convert(mouse, from: nil))
        for case let row as InteractiveView in rows.values {
            row.isHovered = row.bounds.contains(row.convert(mouse, from: nil))
        }
    }
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    #if DEBUG
    func debugHover(_ on: Bool) { isPointerInside = on }
    #endif
    override func mouseExited(with event: NSEvent) { isPointerInside = false }

    // MARK: Rows

    private func makeView(for item: SidebarItem) -> NSView {
        switch item {
        case .header:
            let header = SpaceHeaderView()
            header.onClick = { [weak self] _ in self?.toggleCollapsed() }
            header.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: .header) }
            return header
        case .folder(let id):
            let row = FolderRowView()
            row.onClick = { [weak self] _ in
                guard let open = Library.shared.folder(id)?.isOpen else { return }
                self?.delegate?.listSetFolderOpen(id, !open)
            }
            row.onRename = { [weak self] name in self?.delegate?.listRenameFolder(id, to: name) }
            row.onRightClick = { [weak self] _ in self?.delegate?.listMenu(for: item) }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDrag(item, view: row, event: event)
            }
            return row
        case .separator:
            let separator = SeparatorRowView()
            separator.clearButton.onClick = { [weak self, weak separator] _ in
                guard separator?.clearIsArmed == true else { return }
                self?.previewClear(false)
                self?.delegate?.listClearTabs()
            }
            separator.clearButton.hoverChanged = { [weak self] on in self?.previewClear(on) }
            separator.showsClear = showsClear
            return separator
        case .placeholder:
            // The room the carried row will land in: empty, the row's own size.
            return NSView()
        case .newTab:
            let row = NewTabRowView()
            row.onClick = { [weak self] _ in self?.delegate?.listNewTab() }
            return row
        case .tab(let id):
            let row = TabRowView()
            row.onClick = { [weak self, weak row] event in
                guard let self, let row, let tab = row.tab else { return }
                if self.mark(item, with: event) { return }
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
                // Away from its page, the button says "Back to Pinned Page", and does that.
                if let manager = self?.manager, manager.isAway(id) { manager.resetBookmarkTab(id); return }
                if let tab = row?.tab { self?.delegate?.listClose(tab) }
            }
            row.onRightClick = { [weak self] _ in self?.menu(for: item) }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return false }
                return self.beginDrag(item, view: row, event: event)
            }
            observeHover(row)
            return row
        case .bookmark(let id):
            let row = TabRowView()
            row.isBookmark = true
            // Not a pinned split's row: it carries two pages, and a new name would only reach the left one.
            row.onDoubleClick = { [weak row] in if Library.shared.pinnedSplit(containing: id) == nil { row?.beginRename() } }
            row.onRename = { [weak self] name in
                guard !name.isEmpty else { return }
                self?.delegate?.listRenameBookmark(id, to: name)
            }
            row.onClick = { [weak self, weak row] event in
                guard let self, let row else { return }
                if self.mark(item, with: event) { return }
                // A pinned split row: each half opens its own page, and both open side by side.
                var opening = id
                if row.half(at: row.convert(event.locationInWindow, from: nil)) == 1, let pinned = Library.shared.pinnedSplit(containing: id) {
                    opening = pinned.right
                }
                if let bookmark = Library.shared.bookmark(opening) { self.delegate?.listOpenBookmark(bookmark) }
            }
            row.onClose = { [weak self, weak row] in
                guard let self, let row else { return }
                // A pinned split row unloads both its pages, the one you're not on first.
                let selected = self.manager?.selectedTab
                for tab in [row.partner, row.tab].compactMap({ $0 }).sorted(by: { $1 === selected && $0 !== selected }) {
                    self.delegate?.listClose(tab)
                }
            }
            row.onRightClick = { [weak self] _ in self?.menu(for: item) }
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
            (view as? SpaceHeaderView)?.label.stringValue = privateLabel ? "Private" : spaceName
            (view as? SpaceHeaderView)?.icon = privateLabel ? nil : Library.shared.space(spaceID)?.icon
            view.needsLayout = true

        case .separator:
            // For the space this list shows: the neighbor sliding in during a swipe has its own tabs.
            let space = shownSpaceID ?? manager.currentSpaceID
            let (closing, faded) = manager.tabsToClear(in: space)
            // Clear is there only when it has something to close, and says which: the old tabs, or all the others.
            (view as? SeparatorRowView)?.hasTabs = !closing.isEmpty
            (view as? SeparatorRowView)?.clearButton.step = faded ? .old(closing.count) : .others(closing.count)

        case .tab(let id):
            guard let row = view as? TabRowView, let tab = manager.tab(with: id) else { return }
            row.configure(tab: tab)
            // Both halves of a split show as open.
            let partner = manager.partner(of: tab)
            row.configure(partner: partner)
            row.partnerLeads = partner != nil && manager.split(for: tab)?.left == partner?.id
            row.isSelected = tab === selected || (partner != nil && partner === selected)
            row.focusedHalf = partner != nil && partner === selected ? 1 : 0
            row.freshness = SiteTint.freshness(lastActivated: tab.lastActivated)
            row.isMarked = marked.contains(item)
        case .folder(let id):
            guard let row = view as? FolderRowView, let folder = Library.shared.folder(id) else { return }
            row.configure(name: folder.name, open: folder.isOpen, count: folder.bookmarkIDs.count, icon: folder.icon)
        case .bookmark(let id):
            guard let row = view as? TabRowView, let bookmark = Library.shared.bookmark(id) else { return }
            let tab = manager.bookmarkTab(for: id)
            row.bookmarkIcon = FaviconStore.shared.cachedIcon(for: bookmark.url)
            if row.bookmarkIcon == nil { FaviconStore.shared.prefetch(for: bookmark.url) }
            // Moved on from its pinned page: the row shows where it is now, and its button goes back.
            let away = manager.isAway(id)
            row.isAway = away
            row.fixedTitle = away ? nil : bookmark.title
            row.configure(tab: tab)
            // A pinned split shows both its pages, open or not, the way a split among tabs does.
            let pinned = Library.shared.pinnedSplit(containing: id).flatMap { $0.left == id ? Library.shared.bookmark($0.right) : nil }
            let partner = pinned.flatMap { manager.bookmarkTab(for: $0.id) }
            if let pinned {
                let icon = FaviconStore.shared.cachedIcon(for: pinned.url)
                if icon == nil { FaviconStore.shared.prefetch(for: pinned.url) }
                row.configure(pinnedPartner: pinned.title, icon: icon, unloaded: partner == nil)
            } else {
                row.configure(pinnedPartner: nil, icon: nil, unloaded: false)
            }
            row.configure(partner: partner)
            row.isUnloaded = tab == nil && partner == nil
            // Beside a tab, it's on screen while that tab is: the tab's row carries the pair, and this one stays lit.
            let beside = tab.flatMap(manager.partner(of:))
            row.isSelected = (tab != nil && tab === selected) || (partner != nil && partner === selected) || (beside != nil && beside === selected)
            row.focusedHalf = partner != nil && partner === selected ? 1 : 0
            row.isMarked = marked.contains(item)
        default:
            break
        }
    }

    // MARK: Picking several

    /// ⌘-click adds or takes away one row, ⇧-click picks everything from the last picked (or the tab you're on) to
    /// here. A plain click lets go of them all. Returns true when the click was a pick, not an open.
    private func mark(_ item: SidebarItem, with event: NSEvent?) -> Bool {
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        guard flags.contains(.command) || flags.contains(.shift) else {
            if !marked.isEmpty { clearMarks() }
            return false
        }
        let pickable = items.filter(\.isPickable)
        // Starting a pick includes where you are, the way Finder keeps what's already selected.
        if marked.isEmpty, let current = currentItem, current != item { marked = [current] }
        if flags.contains(.shift), let anchor = marked.last ?? currentItem,
           let a = pickable.firstIndex(of: anchor), let b = pickable.firstIndex(of: item) {
            for picked in pickable[min(a, b)...max(a, b)] where !marked.contains(picked) { marked.append(picked) }
        } else if let i = marked.firstIndex(of: item) {
            marked.remove(at: i)
        } else {
            marked.append(item)
        }
        marked.sort { (items.firstIndex(of: $0) ?? 0) < (items.firstIndex(of: $1) ?? 0) }
        if marked.count < 2 { marked = [] }
        refreshRows()
        return true
    }

    #if DEBUG
    /// For the debug bridge: a ⌘-click (or ⇧-click) on the pickable row at this position.
    func debugMark(_ index: Int, shift: Bool) {
        let pickable = items.filter(\.isPickable)
        guard pickable.indices.contains(index) else { return }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: shift ? .shift : .command, timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        _ = mark(pickable[index], with: event)
    }
    #endif

    /// The row of the tab you're on, if it's in this list.
    private var currentItem: SidebarItem? {
        guard let tab = manager?.selectedTab else { return nil }
        if let id = tab.bookmarkID.map(Self.rowID), items.contains(.bookmark(id)) { return .bookmark(id) }
        return items.contains(.tab(tab.id)) ? .tab(tab.id) : nil
    }

    func clearMarks() {
        guard !marked.isEmpty else { return }
        marked = []
        refreshRows()
    }

    private func menu(for item: SidebarItem) -> NSMenu? {
        if marked.count > 1, marked.contains(item) { return delegate?.listMenu(forMarked: marked) }
        clearMarks()
        return delegate?.listMenu(for: item)
    }

    /// Refreshes selection, fading and content without changing layout.
    func refreshRows() {
        for (item, view) in rows { configure(view, for: item) }
    }

    /// Pinned pages show their icon as soon as one arrives, not only after a relaunch.
    private lazy var iconToken: SignalToken = FaviconStore.shared.updated.observe { [weak self] _ in
        guard let self, self.window != nil else { return }
        self.refreshRows()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = iconToken
    }

    var headerView: NSView? { rows[.header] }

    #if DEBUG
    /// Every row as it's laid out: a name a test can find it by, and where it is in the window.
    func debugRows() -> [(String, NSRect)] {
        guard let manager else { return [] }
        return rows.compactMap { item, view in
            guard view.superview === self, !view.isHidden, let window else { return nil }
            let name: String
            switch item {
            case .tab(let id): name = "tab:" + (manager.tab(with: id).map { tab in [tab] + (manager.partner(of: tab).map { [$0] } ?? []) }?.map(\.displayTitle).joined(separator: "|") ?? "")
            case .bookmark(let id):
                let ids = Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id]
                name = "pin:" + ids.compactMap { Library.shared.bookmark($0)?.title }.joined(separator: "|")
            case .folder(let id): name = "folder:" + (Library.shared.folder(id)?.name ?? "")
            case .newTab: name = "newtab"
            case .header: name = "header"
            case .separator: name = "separator"
            default: return nil
            }
            return (name, view.convert(view.bounds, to: nil).offsetBy(dx: 0, dy: 0).flippedIn(window))
        }
    }
    #endif
    func folderRow(_ id: UUID) -> NSView? { rows[.folder(id)] }

    /// Starts renaming a pinned page right in its row.
    func beginRenaming(bookmark id: UUID) -> Bool {
        guard let row = rows[.bookmark(id)] as? TabRowView else { return false }
        row.beginRename()
        return true
    }


    /// The space's name scrolls with the list like any row: a block of flat color pinned over the grain and
    /// gradient read as a smudge, and the line under the favorites already marks where the list begins.
    func pinHeader() {
        guard let header = rows[.header] as? SpaceHeaderView else { return }
        Tokens.Motion.withoutAnimation { header.layer?.backgroundColor = nil }
    }

    // MARK: Folding bookmarks

    private static let collapsedKey = "CollapsedBookmarkSpaces"

    static func isCollapsed(_ spaceID: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []).contains(spaceID.uuidString)
    }

    /// Opens or folds a space's pinned section (opened again for a new folder, so it shows).
    static func setCollapsed(_ spaceID: UUID, _ collapsed: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
        if collapsed { set.insert(spaceID.uuidString) } else { set.remove(spaceID.uuidString) }
        UserDefaults.standard.set(Array(set), forKey: collapsedKey)
    }

    private func toggleCollapsed() {
        guard let manager, !Library.shared.bookmarks(in: manager.currentSpaceID).isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        let id = manager.currentSpaceID.uuidString
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: Self.collapsedKey)
        reload(animated: true)
    }

    /// The row showing a tab: its own, its pinned page's, or for the right half of a split, the row of the pair.
    func row(for tab: Tab) -> NSView? {
        if let bookmarkID = tab.bookmarkID { return rows[.bookmark(Self.rowID(bookmarkID))] }
        return rows[.tab(tab.id)] ?? manager?.partner(of: tab).flatMap { rows[.tab($0.id)] }
    }

    /// The row showing a pinned page (a pinned split's row for either of its pages).
    func row(forBookmark id: UUID) -> NSView? { rows[.bookmark(Self.rowID(id))] }

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
    // The dragged row stays in its place, faint, and a copy of it follows the pointer (CarriedCopy), above
    // everything: within the list, across spaces (hold over a dot), into another Zigzag window, or out to make a new
    // one. Nothing else in the list moves meanwhile: a line says where it would land.

    /// The pinned pages of the space on show in order, without the ones being carried.
    private func pinnedOrder(without carried: Set<SidebarItem>) -> [UUID] {
        var moving: Set<UUID> = []
        for item in carried {
            switch item {
            case .bookmark(let id): moving.formUnion(Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id])
            case .folder(let id): moving.formUnion(Library.shared.folder(id)?.bookmarkIDs ?? [])
            default: break
            }
        }
        guard let space = shownSpaceID else { return [] }
        return Library.shared.bookmarks(in: space).map(\.id).filter { !moving.contains($0) }
    }

    /// How many pinned pages (in `order`) come before a row's place ends: up to its last page for a pinned page or a
    /// shut folder, up to its first page for an open folder, whose pages follow as rows of their own. Pages tucked in
    /// shut folders, and the ones a shut pinned section hides, count too.
    private func pinsThrough(_ row: SidebarItem, in order: [UUID]) -> Int {
        switch row {
        case .bookmark(let id):
            let ids = Library.shared.pinnedSplit(containing: id).map { [$0.left, $0.right] } ?? [id]
            return ids.compactMap(order.firstIndex(of:)).max().map { $0 + 1 } ?? 0
        case .folder(let id):
            guard let folder = Library.shared.folder(id) else { return 0 }
            let at = folder.bookmarkIDs.compactMap(order.firstIndex(of:))
            return (folder.isOpen ? at.min() : at.max().map { $0 + 1 }) ?? 0
        default:
            return 0
        }
    }

    /// The list with the gap where something would land: among the pinned rows after the last one that comes before
    /// pinned page `index`, or among the tabs.
    private func withPlaceholder(_ items: [SidebarItem], section: Section?, index: Int, carried: Set<SidebarItem>) -> [SidebarItem] {
        var base = items
        switch section {
        case .bookmarks:
            let order = pinnedOrder(without: carried)
            var at = (base.firstIndex(of: .header) ?? 0) + 1
            for i in at..<base.count {
                if base[i] == .separator || base[i] == .newTab { break }
                if pinsThrough(base[i], in: order) <= index { at = i + 1 }
            }
            base.insert(.placeholder, at: min(at, base.count))
        case .tabs:
            let start = (base.firstIndex(of: .newTab) ?? base.count - 1) + 1
            base.insert(.placeholder, at: min(start + index, base.count))
        case nil:
            break
        }
        return base
    }

    /// Where something would land from the pointer's height, against the list without what's carried.
    /// `allowsPinned`: it can land among the pinned pages too, not only among the tabs.
    private func target(at y: CGFloat, allowsPinned: Bool, carried: Set<SidebarItem>) -> (Section, Int) {
        let base = items.filter { !carried.contains($0) }
        let layout = frames(for: base)
        let boundary = layout.first { $0.0 == .separator || $0.0 == .newTab }.map { $0.1.midY } ?? 0
        // A folder stays among the pinned pages, and lands between groups, not inside one.
        let folder: UUID? = carried.lazy.compactMap { if case .folder(let id) = $0 { id } else { nil } }.first
        if allowsPinned, y < boundary || folder != nil {
            let order = pinnedOrder(without: carried)
            var count = layout.filter { $0.1.midY < y }.map { pinsThrough($0.0, in: order) }.max() ?? 0
            if let folder, let space = shownSpaceID {
                count = Library.shared.folderDropIndex(count, moving: folder, in: space)
            }
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

    /// Something from elsewhere hovering this list: the line shows where it would land (nil to hide it).
    /// `allowsPinned`: what's carried can land among the pinned tabs too (a favorite), not only among the tabs.
    func externalHover(at screenPoint: NSPoint?, allowsPinned: Bool = false) {
        var landing: (section: Section, index: Int, pointX: CGFloat)?
        if let screenPoint, let window {
            let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            let (section, index) = target(at: point.y, allowsPinned: allowsPinned, carried: [])
            landing = (section, index, point.x)
        }
        guard landing?.section != external?.section || landing?.index != external?.index || landing?.pointX != external?.pointX else { return }
        external = landing
        placeLine()
    }

    /// Where something from outside the list lands, at a point on screen, and the folder it goes into, if any.
    func dropTarget(at screenPoint: NSPoint, allowsPinned: Bool) -> (section: Section, index: Int, folder: UUID?) {
        guard let window else { return (.tabs, 0, nil) }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let (section, index) = target(at: point.y, allowsPinned: allowsPinned, carried: [])
        let folder = section == .bookmarks ? folderForGap(in: withPlaceholder(items, section: section, index: index, carried: []), pointX: point.x) : nil
        return (section, index, folder)
    }

    /// Where a tab from another window would land, for a screen point over this list.
    func dropIndex(at screenPoint: NSPoint) -> Int { dropTarget(at: screenPoint, allowsPinned: false).index }

    private func beginDrag(_ item: SidebarItem, view: NSView, event: NSEvent) -> Bool {
        guard let window, let manager, item.isDraggable else { return false }
        delegate?.listHover(nil, row: nil, bookmark: nil)
        // Dragging one of several picked rows carries them all, landing together in list order.
        let together = marked.count > 1 && marked.contains(item) ? marked : [item]
        if together.count == 1 { clearMarks() }
        // A folder's pages go with it.
        var carried: Set<SidebarItem> = [item]
        if case .folder(let id) = item { carried.formUnion((Library.shared.folder(id)?.bookmarkIDs ?? []).map { .bookmark(Self.rowID($0)) }) }
        let faint = Array(carried.union(together))
        (view as? SidebarRowView)?.isLifted = true
        let picture = CarriedCopy.picture(of: view)
        (view as? SidebarRowView)?.isLifted = false
        let copy = CarriedCopy(of: view, picture: picture, grabbedAt: window.convertPoint(toScreen: event.locationInWindow),
                               ground: Tokens.Color.panelBackground, radius: Tokens.Radius.row)
        drag = DragState(item: item, view: view, copy: copy, together: together, carried: carried, faint: faint,
                         targetSection: nil, targetIndex: 0, originSpace: shownSpaceID ?? manager.currentSpaceID)
        if let start = drag.map({ reorderTarget(pointerY: convert(event.locationInWindow, from: nil).y, dragging: $0) }) {
            drag?.targetSection = start.0
            drag?.targetIndex = start.1
            drag?.originSection = start.0
            drag?.originIndex = start.1
        }
        // Nothing in the list reacts to the pointer while a row is carried over it.
        for case let row as InteractiveView in rows.values { row.isHovered = false }
        (rows[.separator] as? SeparatorRowView)?.showsClear = false
        for item in faint { rows[item]?.alphaValue = CarriedCopy.faint }
        copy.lift()
        let released = CarriedCopy.track(in: window) { self.dragMoved(to: $0) }
        endDrag(released: released.map { window.convertPoint(toScreen: $0.locationInWindow) })
        return true
    }

    struct SplitDrop: Equatable {
        let id: UUID
        let onRight: Bool
    }

    /// Which slot the pointer is over, counted in the list without the carried rows (which stay where they were
    /// while you drag): below them, every row sits that much lower than it will.
    private func reorderTarget(pointerY y: CGFloat, dragging drag: DragState) -> (Section, Int) {
        var y = y
        if carriedRowShown, let block = drag.carried.compactMap({ rows[$0]?.frame }).reduce(nil, { $0?.union($1) ?? $1 }) {
            if y > block.maxY { y -= block.height + rowGap } else if y >= block.minY { y = block.minY }
        }
        return target(at: y, allowsPinned: true, carried: drag.carried)
    }

    /// The row as one side of a split drop (see TabManager.canSplit); nil for rows that aren't a page.
    private func splitSide(of item: SidebarItem) -> TabManager.SplitSide? {
        guard let manager else { return nil }
        switch item {
        case .tab(let id): return manager.tab(with: id).map(manager.splitSide(of:))
        case .bookmark(let id): return manager.splitSide(ofBookmark: id)
        default: return nil
        }
    }

    private func canSplit(_ carried: SidebarItem, onto target: SidebarItem) -> Bool {
        guard carried != target, let a = splitSide(of: carried), let b = splitSide(of: target) else { return false }
        return TabManager.canSplit(a, onto: b)
    }

    /// The row whose middle the pointer is on: most of a row's height, so it's easy to hit and holds still. Its
    /// top and bottom edges are for reordering.
    private func splitTarget(pointer: NSPoint, dragging item: SidebarItem) -> SplitDrop? {
        for (candidate, view) in rows where view !== drag?.view {
            guard view is TabRowView else { continue }
            let band = view.frame.insetBy(dx: 0, dy: view.frame.height * 0.22)
            guard band.contains(pointer), canSplit(item, onto: candidate) else { continue }
            switch candidate {
            case .tab(let id), .bookmark(let id): return SplitDrop(id: id, onRight: pointer.x > view.frame.midX)
            default: continue
            }
        }
        return nil
    }

    private let insertionLine = InsertionLineView()

    /// Whether the row being carried is in the list on show: in its own space it stays there, faint; carried to
    /// another space, it isn't there at all.
    private var carriedRowShown: Bool {
        guard let drag else { return false }
        return shownSpaceID == drag.originSpace
    }

    /// The line between the rows where the carried row (or something from elsewhere) would land, set in when it
    /// would go into a folder. Hidden when it would land where it already is, or while a split is on offer.
    private func placeLine() {
        let section: Section?, index: Int, pointX: CGFloat
        if let drag {
            let home = carriedRowShown && drag.targetSection == drag.originSection && drag.targetIndex == drag.originIndex
            section = home || drag.folderTarget != nil || splitCandidate != nil || drag.splitTarget != nil ? nil : drag.targetSection
            index = drag.targetIndex
            pointX = drag.pointX
        } else if let external {
            (section, index, pointX) = external
        } else {
            section = nil; index = 0; pointX = 0
        }
        let carried = drag?.carried ?? []
        let placed = withPlaceholder(items.filter { !carried.contains($0) }, section: section, index: index, carried: carried)
        guard section != nil, let gap = placed.firstIndex(of: .placeholder) else {
            insertionLine.isHidden = true
            return
        }
        let before = placed[..<gap].last { rows[$0] != nil }
        let after = placed[(gap + 1)...].first { rows[$0] != nil }
        var y: CGFloat
        if let after, after != .separator, let next = rows[after] {
            y = next.frame.minY - rowGap / 2
        } else if let before, let previous = rows[before] {
            y = previous.frame.maxY + rowGap / 2
        } else {
            insertionLine.isHidden = true
            return
        }
        y = round(y)
        let x = folderForGap(in: placed, pointX: pointX) != nil ? Self.folderIndent : 0
        if insertionLine.superview !== self { addSubview(insertionLine) }
        Tokens.Motion.withoutAnimation {
            insertionLine.frame = NSRect(x: x, y: y - 3, width: bounds.width - x, height: 6)
        }
        insertionLine.isHidden = false
        addSubview(insertionLine, positioned: .above, relativeTo: nil)
    }

    /// The row the carried row is resting on, before it lights up as a split.
    private var splitCandidate: SplitDrop?
    private var splitWork: DispatchWorkItem?

    private func showSplitTarget(_ target: SplitDrop?) {
        if let target, target != lastSplitTarget { Haptics.snap() }
        lastSplitTarget = target
        drag?.splitTarget = target
        for (item, view) in rows {
            guard let row = view as? TabRowView else { continue }
            row.splitDropSide = target.flatMap { item == .tab($0.id) || item == .bookmark($0.id) ? ($0.onRight ? 1 : 0) : nil }
        }
        placeLine()
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
        drag.copy.follow(mouse)
        let hit = Self.list(at: mouse)
        let inWindow = Self.window(at: mouse) === window.windowController

        // Another window's list shows where a tab would land there.
        if let (_, list) = hit, list !== self, case .tab = drag.item {
            if externalTarget !== list { externalTarget?.externalHover(at: nil) }
            externalTarget = list
            list.externalHover(at: mouse)
        } else if externalTarget != nil {
            externalTarget?.externalHover(at: nil)
            externalTarget = nil
        }

        // Over this window's favorites grid: a bar shows where it would go there, and the list's line goes.
        let overFavorites = drag.item.canBeFavorite && inWindow
            ? delegate?.listDragOverFavorites(at: window.convertPoint(fromScreen: mouse), carrying: splitSide(of: drag.item)) ?? false
            : delegate?.listDragOverFavorites(at: nil, carrying: nil) ?? false
        if overFavorites, !wasOverFavorites { Haptics.snap() }
        wasOverFavorites = overFavorites

        // Over this window's page (not the sidebar): offer to open the tab beside it.
        if case .tab(let id) = drag.item, let tab = manager?.tab(with: id) {
            delegate?.listDragOverPage(at: hit == nil && inWindow ? window.convertPoint(fromScreen: mouse) : nil, tab: tab)
        }

        var section: Section? = nil
        var index = drag.targetIndex
        var candidate: SplitDrop?
        if let (_, list) = hit, list === self, !overFavorites {
            autoscroll(with: event)
            let point = convert(window.convertPoint(fromScreen: mouse), from: nil)
            drag.pointX = point.x
            // Resting on a folder row: it lights up to take the page.
            let isPage: Bool = { switch drag.item { case .bookmark, .tab: true; default: false } }()
            let folderHit = isPage ? folderRow(at: point) : nil
            if folderHit != drag.folderTarget {
                drag.folderTarget = folderHit
                showFolderTarget(folderHit)
            }
            if folderHit == nil {
                // On a row's middle: offer to open the two side by side, the line out of the way. On its edges: the
                // line shows where it would go.
                candidate = splitTarget(pointer: point, dragging: drag.item)
                (section, index) = candidate == nil ? reorderTarget(pointerY: point.y, dragging: drag) : (drag.targetSection, drag.targetIndex)
            }
        } else if drag.folderTarget != nil {
            drag.folderTarget = nil
            showFolderTarget(nil)
        }

        if candidate != splitCandidate {
            splitCandidate = candidate
            splitWork?.cancel()
            if let active = drag.splitTarget, let candidate, active.id == candidate.id {
                // Already offered on this row: switching halves is immediate.
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
            }
            guard let refreshed = self.drag else { return }
            drag = refreshed
        }

        // Carry the row to the sidebar's left or right edge and hold: the space flips that way.
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

        // Holding over another space's dot opens that space, so you can drop it in place there. Let go on a dot,
        // it goes into that space, shown or not.
        let hovered = delegate?.listDragHoverSpace(at: window.convertPoint(fromScreen: mouse))
        if hovered != drag.hoverSpace {
            springWork?.cancel()
            if let hovered, hovered != manager?.currentSpaceID {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.drag?.hoverSpace == hovered else { return }
                        self.delegate?.listSwitchSpaceDuringDrag(hovered)
                    }
                }
                springWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
            if hovered != nil { Haptics.snap() }
        }
        drag.hoverSpace = hovered
        // On the space dots it's going to a space, not to a place in this list: no line meanwhile.
        if hovered != nil { section = nil }
        // Crossing between pinned tabs and tabs is a different kind of place: a tap says so.
        if let section, let old = drag.targetSection, section != old { Haptics.snap() }
        drag.targetSection = section
        drag.targetIndex = index
        self.drag = drag
        placeLine()
    }

    /// Ends a drag: let go at a point on screen, or called off with Esc (nil), changing nothing. The copy lands on
    /// the row in its new place, or back on the row it came from.
    private func endDrag(released mouse: NSPoint?) {
        guard let drag else { return }
        // Worked out against the list as it looked at the drop, gap and all.
        let gapFolder: UUID? = drag.targetSection == .bookmarks
            ? folderForGap(in: withPlaceholder(items.filter { !drag.carried.contains($0) }, section: .bookmarks, index: drag.targetIndex, carried: drag.carried),
                           pointX: drag.pointX)
            : nil
        let external = externalTarget
        self.drag = nil
        externalTarget = nil
        external?.externalHover(at: nil)
        showFolderTarget(nil)
        insertionLine.isHidden = true
        springWork?.cancel()
        edgeWork?.cancel()
        edgeDirection = nil
        splitWork?.cancel()
        splitCandidate = nil
        lastSplitTarget = nil
        wasOverFavorites = false
        for view in rows.values { (view as? TabRowView)?.splitDropSide = nil }
        if drag.together.count > 1 { clearMarks() }

        var landing: NSView?
        if let mouse {
            landing = drop(drag, at: mouse, into: external, folder: gapFolder)
        } else {
            delegate?.listDragEnded()
            if let manager, manager.currentSpaceID != drag.originSpace { delegate?.listSwitchSpaceDuringDrag(drag.originSpace) }
            landing = drag.view
        }
        delegate?.listDropFinished()
        reload(animated: true)
        drag.view.isHidden = false
        for item in drag.faint { rows[item]?.alphaValue = 1 }
        layoutSubtreeIfNeeded()
        drag.copy.land(on: landing)
        syncHover()
    }

    /// Does what the drop says, in the order a place takes it, and returns the row (or favorite) it landed as.
    private func drop(_ drag: DragState, at mouse: NSPoint, into external: SidebarListView?, folder gapFolder: UUID?) -> NSView? {
        guard let manager else { return nil }
        // Whatever it's over has had its say once the drop is done: nothing stays lit for it.
        defer { delegate?.listDragEnded() }
        let tab: Tab? = { if case .tab(let id) = drag.item { manager.tab(with: id) } else { nil } }()

        // Onto the middle of a tab's or pinned page's row: the two open side by side. The pair takes the kind of the
        // row it was dropped on, so it shows once: on a pinned page, a pinned split; on a tab, a split among tabs.
        if let split = drag.splitTarget {
            let ontoTab = manager.tab(with: split.id)
            if let tab {
                if let ontoTab { delegate?.listSplit(ontoTab, with: tab, otherOnRight: split.onRight) } else { delegate?.listPinSplit(tab, onto: split.id, tabOnRight: split.onRight) }
                return landingView(for: tab)
            }
            if case .bookmark(let id) = drag.item, let ontoTab {
                delegate?.listUnpinSplit(id, onto: ontoTab, pinnedOnRight: split.onRight)
                return row(for: ontoTab)
            }
        }

        // Onto the favorites grid.
        if let tab, delegate?.listDropOnFavorites(tab) == true { return landingView(for: tab) }
        if case .bookmark(let id) = drag.item, delegate?.listDropBookmarkOnFavorites(id) == true { return delegate?.listFavoriteTile(for: id) }

        // Onto this window's page: open it in split view beside what's showing.
        if let tab, Self.list(at: mouse) == nil, Self.window(at: mouse) === window?.windowController, delegate?.listDropOnPage(tab) == true {
            return nil
        }

        // Into another window's sidebar, where its line showed.
        if let tab, let external, let (controller, list) = Self.list(at: mouse), list === external, controller.tabManager !== manager,
           delegate?.listMoveToWindow(tab, controller: controller, index: list.dropIndex(at: mouse)) == true {
            return list.row(for: tab)
        }

        // Somewhere that isn't any Zigzag window: the tab becomes a new window there.
        if let tab, Self.window(at: mouse) == nil, delegate?.listDropOutside(tab, at: mouse) == true { return nil }

        // Onto a space's dot: into that space, whichever one is showing.
        if let space = drag.hoverSpace {
            for item in drag.together {
                switch item {
                case .tab(let id):
                    if let tab = manager.tab(with: id), tab.spaceID != space { delegate?.listMove(tab, to: drag.together.count == 1 ? 0 : Int.max, in: space) }
                case .bookmark(let id):
                    if Library.shared.spaceID(ofBookmark: id) != space { delegate?.listMoveBookmark(id, to: Int.max, in: space) }
                case .folder(let id):
                    if !Library.shared.folders(in: space).contains(where: { $0.id == id }) { delegate?.listMoveFolder(id, to: Int.max, in: space) }
                default: break
                }
            }
            return nil
        }

        let space = manager.currentSpaceID
        // Onto a folder row: in it goes, at its end (a tab is pinned first).
        if let folder = drag.folderTarget {
            for item in drag.together {
                if let id = pin(item, in: space) { delegate?.listSetFolder(of: id, to: folder) }
            }
            return tab.map(landingView(for:)) ?? rows[drag.item]
        }

        guard let section = drag.targetSection else { return carriedRowShown ? drag.view : nil }
        var landing: NSView?
        switch (drag.item, section) {
        case (.tab, .tabs):
            if let tab { delegate?.listMove(tab, to: drag.targetIndex, in: space) }
        case (.tab, .bookmarks):
            if let tab {
                if tab.spaceID != space { delegate?.listMove(tab, to: 0, in: space) }
                delegate?.listBookmark(tab, at: drag.targetIndex, in: space)
                // Among a folder's pages: into that folder.
                if let folder = gapFolder, let bookmarkID = tab.bookmarkID {
                    delegate?.listMoveBookmark(bookmarkID, to: drag.targetIndex, in: space, folder: folder)
                }
            }
        case (.bookmark(let id), .bookmarks):
            delegate?.listMoveBookmark(id, to: drag.targetIndex, in: space, folder: gapFolder)
            landing = row(forBookmark: id)
        case (.folder(let id), .bookmarks):
            delegate?.listMoveFolder(id, to: drag.targetIndex, in: space)
            landing = rows[.folder(id)]
        case (.bookmark(let id), .tabs):
            delegate?.listUnbookmark(id, to: drag.targetIndex)
            let tabs = manager.tabs(in: space)
            landing = tabs.indices.contains(drag.targetIndex) ? row(for: tabs[drag.targetIndex]) : nil
        default:
            break
        }
        if drag.together.count > 1 {
            carry(drag.together, around: drag.item, to: section, at: drag.targetIndex, folder: gapFolder)
        }
        return tab.map(landingView(for:)) ?? landing
    }

    /// Where a tab shows now: its row, or its tile once it's a favorite.
    private func landingView(for tab: Tab) -> NSView? {
        if tab.isFavorite, let id = tab.bookmarkID { return delegate?.listFavoriteTile(for: id) }
        return row(for: tab)
    }

    /// The pinned page a picked row is, pinning a tab (at the end of this space's pins) to get one.
    private func pin(_ item: SidebarItem, in space: UUID) -> UUID? {
        guard let manager else { return nil }
        switch item {
        case .bookmark(let id):
            if Library.shared.spaceID(ofBookmark: id) != space { delegate?.listMoveBookmark(id, to: Int.max, in: space) }
            return id
        case .tab(let id):
            guard let tab = manager.tab(with: id) else { return nil }
            if tab.spaceID != space { delegate?.listMove(tab, to: 0, in: space) }
            if tab.bookmarkID == nil { delegate?.listBookmark(tab, at: Int.max, in: space) }
            return tab.bookmarkID
        default:
            return nil
        }
    }

    /// The rest of a dragged group, placed around the row that was dragged (which has already landed), keeping
    /// their order: the ones above it just before it, the ones below just after.
    private func carry(_ together: [SidebarItem], around dragged: SidebarItem, to section: Section, at index: Int, folder: UUID?) {
        guard let manager, let p = together.firstIndex(of: dragged) else { return }
        let space = manager.currentSpaceID
        let below = Array(together[(p + 1)...]), above = Array(together[..<p].reversed())
        switch section {
        case .bookmarks:
            let landed: UUID? = {
                switch dragged {
                case .bookmark(let id): return id
                case .tab(let id): return manager.tab(with: id)?.bookmarkID
                default: return nil
                }
            }()
            guard let landed else { return }
            for (list, after) in [(below, true), (above, false)] {
                var neighbor = landed
                for item in list {
                    guard let id = pin(item, in: space) else { continue }
                    let rest = Library.shared.bookmarks(in: space).map(\.id).filter { $0 != id }
                    let at = rest.firstIndex(of: neighbor).map { after ? $0 + 1 : $0 } ?? rest.count
                    delegate?.listMoveBookmark(id, to: at, in: space, folder: folder)
                    neighbor = id
                }
            }
        case .tabs:
            let landed: Tab? = {
                if case .tab(let id) = dragged { return manager.tab(with: id) }
                let tabs = manager.tabs(in: space)
                return tabs.indices.contains(index) ? tabs[index] : nil
            }()
            for (list, after) in [(below, true), (above, false)] {
                var neighbor = landed
                for item in list {
                    let tabs = manager.tabs(in: space)
                    switch item {
                    case .tab(let id):
                        guard let tab = manager.tab(with: id) else { continue }
                        let rest = tabs.filter { $0 !== tab }
                        let at = neighbor.flatMap { n in rest.firstIndex { $0 === n } }.map { after ? $0 + 1 : $0 } ?? rest.count
                        delegate?.listMove(tab, to: at, in: space)
                        neighbor = tab
                    case .bookmark(let id):
                        let at = neighbor.flatMap { n in tabs.firstIndex { $0 === n } }.map { after ? $0 + 1 : $0 } ?? tabs.count
                        rows[.bookmark(id)] = nil
                        delegate?.listUnbookmark(id, to: at)
                        let now = manager.tabs(in: space)
                        neighbor = now.indices.contains(at) ? now[at] : neighbor
                    default:
                        continue
                    }
                }
            }
        }
    }

    /// Redraws for a new space while a drag is in progress (the space slide is animated by the sidebar).
    func refreshDuringDrag() {
        guard drag != nil else { return }
        items = buildItems()
        apply(items: items, animated: false)
    }
}
