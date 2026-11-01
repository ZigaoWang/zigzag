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
    /// A tab or bookmark dragged over the favorites grid. Returns true while it's over it.
    func listDragOverFavorites(at windowPoint: NSPoint, canSplit: Bool) -> Bool
    /// Dropped on the favorites grid. Returns true if it became a favorite.
    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool)
    func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool)
    func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool)
    func listDropOnFavorites(_ tab: Tab) -> Bool
    /// A pinned page dropped on the favorites grid: it becomes a favorite, open or not.
    func listDropBookmarkOnFavorites(_ bookmarkID: UUID) -> Bool
    /// A tab dragged over the page: show which half it would open in.
    func listDragOverPage(at windowPoint: NSPoint, tab: Tab)
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
    /// Shown while dragging a tab when there are no bookmarks yet: drop here to bookmark.
    case bookmarkDropZone

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
        case .placeholder, .bookmark, .folder, .newTab, .tab, .bookmarkDropZone: Tokens.Metric.rowHeight
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
        /// Pointer position relative to the floating row's corner, in screen points.
        var grab: NSPoint
        /// Where it would land in this list; nil while the pointer is somewhere else.
        var targetSection: Section?
        var targetIndex: Int
        var hoverSpace: UUID?
        let panel: NSPanel
        /// A folder row the dragged page or tab rests on: dropping puts it in that folder.
        var folderTarget: UUID?
        /// A tab row the dragged tab rests on: dropping opens them side by side.
        var splitTarget: SplitDrop?
        /// Where it was picked up from; dropping there changes nothing, so no line shows.
        var originSection: Section? = nil
        var originIndex = 0
        /// The space it was picked up in; carried to another, it's no longer in the list on show.
        var originSpace: UUID? = nil
        /// Where the pointer is across the list: set in past a folder's last page, a drop stays in the folder.
        var pointX: CGFloat = 0
        /// The other picked rows going along with this one.
        var group: [SidebarItem] = []
    }

    /// The bookmark area (and its drop zone) opens only once a drag heads up toward it, so rows don't jump when a drag starts.
    private var bookmarkZoneOpen = false

    /// A tab being carried in from another window: where its gap opens in this list.
    private var externalIndex: Int?
    /// Which part of the list it would land in: a favorite can become a pinned tab, a tab from elsewhere a tab.
    private var externalSection: Section = .tabs

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
        let folders = Library.shared.folders(in: spaceID)
        indented = []
        // The right page of a pinned split rides in its left page's row, as a split among tabs does.
        let riders = Set(Library.shared.pinnedSplits(in: spaceID).map(\.right))
        let current = manager.selectedTab?.bookmarkID.map(Self.rowID)
        // A folder being dragged travels shut: its pages go with it, not left behind in the list.
        let lifted: UUID? = { if case .folder(let id)? = drag?.item { id } else { nil } }()
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
                let members = folder.id == lifted ? [] : folder.isOpen ? folder.bookmarkIDs.filter { !riders.contains($0) } : folder.bookmarkIDs.filter { $0 == current }
                for id in members { result.append(.bookmark(id)); indented.insert(id) }
            }
        }
        let hasPinnedRows = result.contains { if case .bookmark = $0 { true } else if case .folder = $0 { true } else { false } }
        if bookmarks.isEmpty && folders.isEmpty && includeEmptyBookmarkSection { result.append(.bookmarkDropZone) }
        // The line above today's tabs, which carries Clear: there when there are pinned tabs above it or tabs to clear.
        let tabs = manager.tabs(in: spaceID)
        if hasPinnedRows || includeEmptyBookmarkSection || !tabs.isEmpty { result.append(.separator) }
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

    /// How many pinned pages a row holds, for working out where a drop lands: two for a pinned split.
    private static func pageCount(_ item: SidebarItem) -> Int {
        guard case .bookmark(let id) = item else { return 0 }
        return Library.shared.pinnedSplit(containing: id)?.left == id ? 2 : 1
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
        (frames(for: drag == nil ? items : displayItems()).last?.1.maxY ?? 0) + Tokens.Space.x2
    }

    func reload(animated: Bool) {
        defer { marked = marked.filter { items.contains($0) }; if marked.count < 2 { marked = [] } }
        guard drag == nil else { return }
        items = buildItems()
        apply(items: displayItems(), animated: animated)
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
        var carried = false
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
                    carried = true
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
            if !carried, Tokens.Motion.isKeyboardDriven {
                // From the keyboard (⌘W, ⌘T) the list simply is in its new order, as the rest of Zigzag answers keys.
                view.layer?.removeAnimation(forKey: "glide")
                Tokens.Motion.withoutAnimation { view.frame = frame }
            } else if carried {
                Tokens.Motion.glide(view, to: frame, duration: 0.3, timing: Self.carryCurve)
            } else {
                Tokens.Motion.glide(view, to: frame, duration: Tokens.Motion.standard, timing: Tokens.Motion.easeInOut)
            }
        }
        if !changes.isEmpty { Tokens.Motion.animate { changes.forEach { $0() } } }
        // The carried row's faint stand-in shows only in its own space.
        drag?.view.isHidden = !carriedRowShown
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
        lift.duration = 0.3
        layer?.add(lift, forKey: "lift")
        Tokens.Motion.glide(view, to: frame, duration: 0.3, timing: Self.carryCurve)
    }

    /// How solid a carried row or favorite is: enough to read, light enough to see what's under it.
    static let carriedOpacity: CGFloat = 0.7

    private static let carryCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

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

    // MARK: Folders

    /// Pinned pages shown inside an open folder, set in by this much.
    static let folderIndent: CGFloat = 14
    /// The pinned pages drawn inside a folder in the list as last built.
    private var indented: Set<UUID> = []

    /// Pages of closed folders that aren't shown: they still count when working out where a drop lands.
    private func hiddenCount(_ folderID: UUID, shown items: [SidebarItem]) -> Int {
        guard let folder = Library.shared.folder(folderID), !folder.isOpen else { return 0 }
        let dragged: UUID? = { if case .bookmark(let id)? = drag?.item { id } else { nil } }()
        // A pinned split's right page is counted with its row.
        return folder.bookmarkIDs.filter { Self.rowID($0) != dragged && !items.contains(.bookmark(Self.rowID($0))) }.count
    }

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
        case .bookmarkDropZone:
            return DropZoneView(text: "Drop here to pin")
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
    func folderRow(_ id: UUID) -> NSView? { rows[.folder(id)] }

    /// Starts renaming a pinned page right in its row.
    func beginRenaming(bookmark id: UUID) -> Bool {
        guard let row = rows[.bookmark(id)] as? TabRowView else { return false }
        row.beginRename()
        return true
    }

    /// The row showing a tab, for pointing at it (the Getting started guide).
    func rowView(for tab: Tab) -> NSView? { tab.bookmarkID.flatMap { rows[.bookmark(Self.rowID($0))] } ?? rows[.tab(tab.id)] }

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

    func row(for tab: Tab) -> NSView? {
        if let bookmarkID = tab.bookmarkID { return rows[.bookmark(Self.rowID(bookmarkID))] }
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
        // Nothing moves while something is carried over the list, as in Arc: a line says where it will land.
        if let drag { return buildItems(includeEmptyBookmarkSection: bookmarkZoneOpen && drag.targetSection != nil) }
        return items
    }

    private func withPlaceholder(_ items: [SidebarItem], section: Section?, index: Int) -> [SidebarItem] {
        var base = items
        switch section {
        case .bookmarks:
            if let zone = base.firstIndex(of: .bookmarkDropZone) {
                base[zone] = .placeholder
            } else {
                // The index counts pinned pages, including ones tucked in closed folders; folder rows sit between.
                var at = (base.firstIndex(of: .header) ?? 0) + 1
                var count = 0
                while at < base.count, count < index {
                    switch base[at] {
                    case .bookmark: count += Self.pageCount(base[at])
                    case .folder(let id): count += hiddenCount(id, shown: base)
                    default: break
                    }
                    if case .separator = base[at] { break }
                    at += 1
                }
                base.insert(.placeholder, at: min(at, base.count))
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
        // A folder stays among the pinned pages, and lands between groups, not inside one.
        let folder: UUID? = { if case .folder(let id)? = item { id } else { nil } }()
        if item != nil, y < separatorMid || folder != nil {
            var count = 0
            for (row, frame) in layout where frame.midY < y {
                count += Self.pageCount(row)
                if case .folder(let id) = row { count += hiddenCount(id, shown: base) }
            }
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

    /// Another window's tab hovering this list: open a gap where it would land (nil to close it).
    /// `allowsPinned`: what's carried can land among the pinned tabs too (a favorite), not only among the tabs.
    func externalHover(at screenPoint: NSPoint?, allowsPinned: Bool = false) {
        var landing: (Section, Int)?
        if let screenPoint { landing = dropTarget(at: screenPoint, allowsPinned: allowsPinned) }
        guard landing?.1 != externalIndex || landing?.0 != externalSection else { return }
        externalIndex = landing?.1
        externalSection = landing?.0 ?? .tabs
        placeLine()
    }

    /// Where something from outside the list lands, at a point on screen.
    func dropTarget(at screenPoint: NSPoint, allowsPinned: Bool) -> (Section, Int) {
        guard let window else { return (.tabs, 0) }
        let y = convert(window.convertPoint(fromScreen: screenPoint), from: nil).y
        // Targeting counts pinned tabs only for something being carried; a stand-in item says so.
        return target(at: y, dragging: allowsPinned ? .placeholder : nil)
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
        // Nothing in the list reacts to the pointer while a row is carried over it.
        for case let row as InteractiveView in rows.values { row.isHovered = false }
        (rows[.separator] as? SeparatorRowView)?.showsClear = false
        // Dragging one of several picked rows carries them all; the others dim where they are until the drop.
        if marked.count > 1, marked.contains(item) {
            drag?.group = marked.filter { $0 != item }
            for other in drag?.group ?? [] { rows[other]?.alphaValue = 0.35 }
        } else {
            clearMarks()
        }
        // A folder's pages leave the list with it, so where it lands is counted without them.
        if case .folder = item {
            let landing = target(at: start.y, dragging: item)
            drag?.targetSection = landing.0
            drag?.targetIndex = landing.1
        }
        if let landing = drag {
            drag?.originSection = landing.targetSection
            drag?.originIndex = landing.targetIndex
            drag?.originSpace = shownSpaceID ?? manager?.currentSpaceID
        }
        // It stays in its place, faint, until it's dropped somewhere else.
        view.alphaValue = 0.35
        panel.alphaValue = 1
        panel.orderFront(nil)
        // Picked up: it lifts a touch and turns see-through, so the line and the row it's over show beneath it.
        Tokens.Motion.animate(Tokens.Motion.feedback) {
            panel.animator().setFrame(rowScreen.insetBy(dx: -3, dy: -1), display: true)
            panel.animator().alphaValue = Self.carriedOpacity
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

    /// Which slot the pointer is over, counted in the list without the carried row (which stays where it was
    /// while you drag): below the carried row, every row sits one row lower than it will.
    private func reorderTarget(pointerY y: CGFloat, dragging drag: DragState) -> (Section, Int) {
        var y = y
        if carriedRowShown, let view = rows[drag.item], view === drag.view {
            if y > view.frame.maxY { y -= view.frame.height + rowGap } else if y >= view.frame.minY { y = view.frame.minY }
        }
        return target(at: y, dragging: drag.item)
    }

    /// Whether the carried row and a row it's over can open side by side: a tab with a tab, or a tab with a pinned
    /// page (neither a favorite nor already half of a pinned split). Two pinned pages are a pinned split's to make.
    private func canSplit(_ carried: SidebarItem, onto target: SidebarItem) -> Bool {
        guard let manager, carried != target else { return false }
        func freePin(_ id: UUID) -> Bool { !Library.shared.isFavorite(id) && Library.shared.pinnedSplit(containing: id) == nil }
        switch (carried, target) {
        case let (.tab(a), .tab(b)):
            guard let t = manager.tab(with: a), let u = manager.tab(with: b), u.url != nil else { return false }
            return manager.canSplit(t, with: u)
        case let (.tab(a), .bookmark(b)), let (.bookmark(b), .tab(a)):
            guard let t = manager.tab(with: a), t.url != nil, manager.split(for: t) == nil || target == .tab(a) || carried == .tab(a) else { return false }
            return freePin(b)
        default:
            return false
        }
    }

    /// Whether the carried row can open beside a favorite, as one split favorite: a page of its own, not already
    /// half of a split.
    private func canJoinFavorite(_ item: SidebarItem) -> Bool {
        guard let manager else { return false }
        switch item {
        case .tab(let id):
            guard let tab = manager.tab(with: id), tab.url != nil else { return false }
            return manager.split(for: tab) == nil
        case .bookmark(let id):
            return !Library.shared.isFavorite(id) && Library.shared.pinnedSplit(containing: id) == nil
        default:
            return false
        }
    }

    /// The row whose middle the pointer is on: most of a row's height, so it's easy to hit and holds still. Its
    /// top and bottom edges are for reordering.
    private func splitTarget(pointer: NSPoint, dragging item: SidebarItem) -> SplitDrop? {
        for (candidate, view) in rows where view !== drag?.view {
            guard let row = view as? TabRowView, row.partner == nil else { continue }
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
        guard let drag, let manager else { return false }
        return (shownSpaceID ?? manager.currentSpaceID) == drag.originSpace
    }

    /// The line between the rows where the carried row (or a tab from elsewhere) would land, set in when it would
    /// go into a folder. Hidden when it would land where it already is, or while a split is on offer.
    private func placeLine() {
        let section: Section?, index: Int, pointX: CGFloat
        if let drag {
            let home = carriedRowShown && drag.targetSection == drag.originSection && drag.targetIndex == drag.originIndex
            section = home || drag.folderTarget != nil || splitCandidate != nil || drag.splitTarget != nil ? nil : drag.targetSection
            index = drag.targetIndex
            pointX = drag.pointX
        } else if let externalIndex {
            (section, index, pointX) = (externalSection, externalIndex, 0)
        } else {
            section = nil; index = 0; pointX = 0
        }
        let shown = displayItems().filter { $0 != drag?.item }
        let placed = withPlaceholder(shown, section: section, index: index)
        guard let section = section as Section?, let gap = placed.firstIndex(of: .placeholder),
              !shown.contains(.bookmarkDropZone) || section != .bookmarks else {
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

    /// The row the carried tab is resting on, before it lights up as a split.
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
        if drag.item.canBeFavorite, Self.window(at: mouse) === window.windowController {
            overFavorites = delegate?.listDragOverFavorites(at: window.convertPoint(fromScreen: mouse), canSplit: canJoinFavorite(drag.item)) ?? false
        }
        if overFavorites, !wasOverFavorites { Haptics.snap() }
        wasOverFavorites = overFavorites

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
            drag.pointX = point.x
            // Resting on a folder row: it lights up to take the page, and the gap stays where it was.
            let isPage: Bool = { switch drag.item { case .bookmark, .tab: true; default: false } }()
            let folderHit = isPage ? folderRow(at: point) : nil
            if folderHit != drag.folderTarget {
                drag.folderTarget = folderHit
                showFolderTarget(folderHit)
            }
            if folderHit != nil {
                // No gap: the lit folder is where it goes.
                section = nil
            } else {
                // On a row's middle: offer to open the two side by side, the line out of the way. On its edges: the
                // line shows where it would go.
                candidate = splitTarget(pointer: point, dragging: drag.item)
                if candidate == nil {
                    (section, index) = reorderTarget(pointerY: point.y, dragging: drag)
                } else {
                    (section, index) = (drag.targetSection, drag.targetIndex)
                }
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
        if hovered != nil, hovered != drag.hoverSpace { Haptics.snap() }
        drag.hoverSpace = hovered
        // On the space dots it's going to another space, not to the end of this list: no line meanwhile.
        if hovered != nil { section = nil }
        // Crossing between pinned tabs and tabs is a different kind of place: a tap says so.
        if let section, let old = drag.targetSection, section != old { Haptics.snap() }
        let changed = section != drag.targetSection || index != drag.targetIndex
        drag.targetSection = section
        drag.targetIndex = index
        self.drag = drag
        // Only the empty pinned section's drop zone ever appears; nothing else in the list moves.
        if changed { apply(items: displayItems(), animated: true) }
        placeLine()
    }

    private func endDrag(with event: NSEvent) {
        guard let drag else { return }
        drop(drag, event: event)
        delegate?.listDropFinished()
        settle(drag)
        layoutSubtreeIfNeeded()
        syncHover()
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
        // Worked out against the list as it looked at the drop, gap and all.
        let gapFolder: UUID? = drag.targetSection == .bookmarks
            ? folderForGap(in: withPlaceholder(buildItems(includeEmptyBookmarkSection: bookmarkZoneOpen).filter { $0 != drag.item },
                                               section: drag.targetSection, index: drag.targetIndex), pointX: drag.pointX)
            : nil
        showFolderTarget(nil)
        self.drag = nil
        drag.view.isHidden = false
        insertionLine.isHidden = true
        for other in drag.group { rows[other]?.alphaValue = 1 }
        // The picked rows, in the order they were in the list; they land together, in that order.
        let together = drag.group.isEmpty ? [drag.item]
            : (drag.group + [drag.item]).sorted { (items.firstIndex(of: $0) ?? 0) < (items.firstIndex(of: $1) ?? 0) }
        if !drag.group.isEmpty { marked = [] }
        springWork?.cancel()
        edgeWork?.cancel()
        edgeDirection = nil
        splitWork?.cancel()
        splitCandidate = nil
        for view in rows.values { (view as? TabRowView)?.splitDropSide = nil }

        // Onto the middle of a tab's or pinned page's row: the two open side by side. The pair takes the kind of the
        // row it was dropped on, so it shows once: on a pinned page, a pinned split; on a tab, a split among tabs.
        if let split = drag.splitTarget {
            drag.view.alphaValue = 1
            let ontoTab = manager.tab(with: split.id)
            switch drag.item {
            case .tab(let id):
                guard let carried = manager.tab(with: id) else { break }
                if let ontoTab {
                    delegate?.listSplit(ontoTab, with: carried, otherOnRight: split.onRight)
                } else {
                    delegate?.listPinSplit(carried, onto: split.id, tabOnRight: split.onRight)
                }
                reload(animated: true)
                return
            case .bookmark(let id):
                guard let ontoTab else { break }
                delegate?.listUnpinSplit(id, onto: ontoTab, pinnedOnRight: split.onRight)
                reload(animated: true)
                return
            default: break
            }
        }

        // Onto the favorites grid.
        if case .tab(let id) = drag.item, let tab = manager.tab(with: id), delegate?.listDropOnFavorites(tab) == true {
            rows[drag.item] = nil
            drag.view.removeFromSuperview()
            reload(animated: true)
            return
        }
        if case .bookmark(let id) = drag.item, drag.item.canBeFavorite, delegate?.listDropBookmarkOnFavorites(id) == true {
            rows[drag.item] = nil
            drag.view.removeFromSuperview()
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
            for item in together {
                switch item {
                case .tab(let id): if let tab = manager.tab(with: id) { delegate?.listMove(tab, to: together.count == 1 ? 0 : Int.max, in: space) }
                case .bookmark(let id): delegate?.listMoveBookmark(id, to: Int.max, in: space)
                case .folder(let id): delegate?.listMoveFolder(id, to: Int.max, in: space)
                default: break
                }
            }
            reload(animated: true)
            return
        }

        // Onto a folder row: in it goes, at its end (a tab is pinned first).
        if let folder = drag.folderTarget {
            for item in together {
                if let id = pin(item, in: manager.currentSpaceID) { delegate?.listSetFolder(of: id, to: folder) }
            }
            if case .tab(let id) = drag.item { rows[.tab(id)] = nil; drag.view.removeFromSuperview() }
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
                // Among a folder's pages: into that folder.
                if let folder = gapFolder, let bookmarkID = tab.bookmarkID {
                    delegate?.listMoveBookmark(bookmarkID, to: drag.targetIndex, in: manager.currentSpaceID, folder: folder)
                }
            }
        case (.bookmark(let id), .bookmarks?):
            delegate?.listMoveBookmark(id, to: drag.targetIndex, in: manager.currentSpaceID, folder: gapFolder)
        case (.folder(let id), .bookmarks?):
            delegate?.listMoveFolder(id, to: drag.targetIndex, in: manager.currentSpaceID)
        case (.bookmark(let id), .tabs?):
            // The row changes identity; the new tab row takes the placeholder's spot.
            rows[.bookmark(id)] = nil
            drag.view.removeFromSuperview()
            delegate?.listUnbookmark(id, to: drag.targetIndex)
        default:
            break
        }
        if together.count > 1, let section = drag.targetSection {
            carry(together, around: drag.item, to: section, at: drag.targetIndex, folder: gapFolder)
        }
        reload(animated: true)
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
        apply(items: displayItems(), animated: false)
    }

    /// Where a tab from another window would land, for a screen point over this list.
    func dropIndex(at screenPoint: NSPoint) -> Int {
        guard let window else { return 0 }
        return target(at: convert(window.convertPoint(fromScreen: screenPoint), from: nil).y, dragging: nil).1
    }
}
