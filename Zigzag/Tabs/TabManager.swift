import AppKit
import WebKit

/// Owns every tab of one window, grouped by space. Views read from it; they never own web views.
final class TabManager {
    enum Change {
        /// Tabs added, removed or moved, or bookmarks changed.
        case structure
        case selection
        case space
        /// A tab navigated or changed title: nothing to redraw here, but worth saving.
        case content
    }

    private(set) var tabsBySpace: [UUID: [Tab]] = [:]
    private(set) var bookmarkTabs: [UUID: Tab] = [:]
    private var selectedBySpace: [UUID: UUID] = [:]
    private(set) var currentSpaceID: UUID
    /// Most recently used first. Drives Control+Tab.
    private(set) var recentTabIDs: [UUID] = []
    private var closedTabs: [ClosedTab] = []

    weak var host: TabHost? {
        didSet { allTabs.forEach { $0.host = host } }
    }
    let changed = Signal<Change>()

    private var libraryToken: SignalToken?
    private var tabTokens: [UUID: SignalToken] = [:]

    /// Watches a tab so navigation inside it gets saved for crash recovery. A page's own title saves at most every
    /// half minute: pages that count down or flash "(1) New message" would otherwise save the whole session every
    /// second or two. A name you give a tab saves at once.
    private func watch(_ tab: Tab) {
        tab.privateStore = privateStore
        var lastTitleSave = Date.distantPast
        tabTokens[tab.id] = tab.changed.observe { [weak self] change in
            switch change {
            case .url, .audio, .renamed:
                self?.changed.send(.content)
            case .title where Date().timeIntervalSince(lastTitleSave) > 30:
                lastTitleSave = Date()
                self?.changed.send(.content)
            default:
                break
            }
        }
    }
    private var suspendTimer: Timer?

    struct ClosedTab {
        /// The closed tab's own id, so undo brings back that tab, not just the latest closed one.
        var id = UUID()
        let url: URL?
        let title: String
        let spaceID: UUID
        let index: Int
        let interactionState: Data?
        var customTitle: String? = nil
    }

    /// Private windows share one throwaway store between their tabs, gone when the window closes.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    init(spaceID: UUID? = nil, isPrivate: Bool = false) {
        privateStore = isPrivate ? .nonPersistent() : nil
        let requested = spaceID.flatMap { Library.shared.space($0)?.id }
        currentSpaceID = requested ?? Library.shared.spaces[0].id
        libraryToken = Library.shared.changed.observe { [weak self] in
            self?.libraryDidChange()
            Brand.themeChanged.send(())
        }
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendIdleTabs() }
        }
    }

    func invalidate() {
        suspendTimer?.invalidate()
        allTabs.forEach { $0.close(keepingSnapshot: !isPrivate) }
        tabsBySpace = [:]
        bookmarkTabs = [:]
    }

    // MARK: Reading

    var currentSpace: SpaceInfo { Library.shared.space(currentSpaceID) ?? Library.shared.spaces[0] }
    var currentTabs: [Tab] { tabs(in: currentSpaceID) }
    func tabs(in spaceID: UUID) -> [Tab] { tabsBySpace[spaceID] ?? [] }

    var allTabs: [Tab] { tabsBySpace.values.flatMap { $0 } + Array(bookmarkTabs.values) }

    var selectedTab: Tab? { selectedTab(in: currentSpaceID) }

    func selectedTab(in spaceID: UUID) -> Tab? {
        guard let id = selectedBySpace[spaceID] else { return nil }
        return tab(with: id)
    }

    func tab(with id: UUID) -> Tab? { allTabs.first { $0.id == id } }

    func bookmarkTab(for bookmarkID: UUID) -> Tab? { bookmarkTabs[bookmarkID] }

    /// Tabs in most-recently-used order across all spaces.
    var recentTabs: [Tab] { recentTabIDs.compactMap { tab(with: $0) } }

    // MARK: Creating

    @discardableResult
    func newTab(url: URL?, spaceID: UUID? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil,
                opener: Tab? = nil, title: String? = nil) -> Tab {
        let space = spaceID ?? currentSpaceID
        let tab = Tab(url: url, title: title, spaceID: space, configuration: configuration)
        tab.host = host
        watch(tab)
        tab.opener = opener
        // New tabs go on top. The list never reorders itself after that.
        tabsBySpace[space, default: []].insert(tab, at: 0)
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        // Opened in front from a page in split view: it takes that page's pane, so the split stays on screen and
        // the page it came from waits in the list. A pinned split keeps its pages; the new tab shows on its own.
        if select, let opener, opener.bookmarkID == nil, opener.spaceID == space, let index = splits.firstIndex(where: { $0.left == opener.id || $0.right == opener.id }) {
            if splits[index].left == opener.id { splits[index].left = tab.id } else { splits[index].right = tab.id }
        }
        changed.send(.structure)
        if select {
            self.select(tab)
        } else {
            recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count))
            // Background tabs start loading right away, so they're ready when you get to them.
            if url != nil || configuration != nil { tab.ensureWebView() }
        }
        return tab
    }

    /// Takes a tab out of this window without closing its page, so another window can adopt it.
    func detach(_ tab: Tab) {
        guard tab.bookmarkID == nil, let index = tabs(in: tab.spaceID).firstIndex(where: { $0 === tab }) else { return }
        splits.removeAll { $0.left == tab.id || $0.right == tab.id }
        let wasSelected = selectedTab === tab
        tabsBySpace[tab.spaceID]?.remove(at: index)
        recentTabIDs.removeAll { $0 == tab.id }
        tabTokens[tab.id] = nil
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    /// Adds a tab that already has a page (a promoted peek) to the top of the list and shows it.
    func insert(_ tab: Tab, at index: Int = 0) {
        tab.host = host
        tab.spaceID = currentSpaceID
        watch(tab)
        var list = tabsBySpace[currentSpaceID] ?? []
        list.insert(tab, at: min(max(index, 0), list.count))
        tabsBySpace[currentSpaceID] = list
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
        changed.send(.structure)
        select(tab)
    }

    /// Inserts already-built tabs (session restore, imports) without selecting.
    func adopt(_ tabs: [Tab], in spaceID: UUID) {
        for tab in tabs { tab.host = host; watch(tab) }
        tabsBySpace[spaceID, default: []].append(contentsOf: tabs)
        recentTabIDs.append(contentsOf: tabs.sorted { $0.lastActivated > $1.lastActivated }.map(\.id))
    }

    func adoptBookmarkTab(_ tab: Tab, bookmarkID: UUID) {
        tab.host = host
        tab.bookmarkID = bookmarkID
        bookmarkTabs[bookmarkID] = tab
        recentTabIDs.append(tab.id)
        watch(tab)
    }

    func restoreSelection(_ selection: [UUID: UUID], currentSpaceID: UUID) {
        selectedBySpace = selection
        if Library.shared.space(currentSpaceID) != nil { self.currentSpaceID = currentSpaceID }
        if let tab = selectedTab { promote(tab) }
        changed.send(.structure)
        changed.send(.space)
        changed.send(.selection)
    }

    // MARK: Selecting

    func select(_ tab: Tab) {
        Autofill.shared.hide()
        if tab.spaceID != currentSpaceID {
            currentSpaceID = tab.spaceID
            changed.send(.space)
        }
        let previous = selectedTab
        previous?.captureSnapshot()
        // Idle counts from when you last saw a tab, not when you first opened it: a page you read for an hour
        // and just left isn't unloaded the moment you look away.
        if previous !== tab { previous?.markActivated() }
        selectedBySpace[tab.spaceID] = tab.id
        tab.markActivated()
        promote(tab)
        tab.ensureWebView()
        tab.reloadIfItStopped()
        if #available(macOS 15.4, *), previous !== tab { ExtensionHost.shared.tabActivated(tab, previous: previous) }
        changed.send(.selection)
    }

    private func promote(_ tab: Tab) {
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
    }

    func clearSelection() {
        selectedBySpace[currentSpaceID] = nil
        changed.send(.selection)
    }

    func selectNext(offset: Int) {
        let list = navigableTabs
        guard !list.isEmpty else { return }
        guard let current = selectedTab, let index = list.firstIndex(where: { $0 === current }) else {
            select(list[0]); return
        }
        select(list[(index + offset + list.count) % list.count])
    }

    func select(at index: Int) {
        let list = navigableTabs
        guard !list.isEmpty else { return }
        select(index >= list.count ? list[list.count - 1] : list[index])
    }

    /// ⌘1–⌘9: every favorite, this space's pinned pages, then its tabs, numbered as the sidebar lists them whether
    /// open or not. An index past the end means the last.
    func selectByNumber(_ index: Int) {
        let bookmarks = Library.shared.favorites + Library.shared.bookmarks(in: currentSpaceID)
        let tabs = currentTabs
        guard !bookmarks.isEmpty || !tabs.isEmpty else { return }
        let i = min(index, bookmarks.count + tabs.count - 1)
        if i < bookmarks.count { openBookmark(bookmarks[i]) } else { select(tabs[i - bookmarks.count]) }
    }

    /// Favorites, bookmarks, then tabs, in sidebar order: what Cmd+Option+Up/Down walk.
    var navigableTabs: [Tab] {
        let favoriteLive = Library.shared.favorites.compactMap { bookmarkTabs[$0.id] }
        let bookmarkLive = Library.shared.bookmarks(in: currentSpaceID).compactMap { bookmarkTabs[$0.id] }
        return favoriteLive + bookmarkLive + currentTabs
    }

    /// Turns a tab into a favorite at a position. Its page stays open behind the tile.
    func favoriteTab(_ tab: Tab, at index: Int? = nil) {
        guard let url = tab.url else { return }
        // A favorite has no row to carry a split, so it leaves the one it was in.
        unsplit(tab)
        if let bookmarkID = tab.bookmarkID {
            Library.shared.makeFavorite(bookmarkID)
            if let index { Library.shared.moveFavorite(bookmarkID, to: index) }
            tab.isFavorite = true
            return
        }
        removeFromList(tab)
        let id = UUID()
        tab.bookmarkID = id
        tab.isFavorite = true
        bookmarkTabs[id] = tab
        Library.shared.addFavorite(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), at: index, id: id)
    }

    // MARK: Spaces

    func switchToSpace(_ id: UUID) {
        guard id != currentSpaceID, Library.shared.space(id) != nil else { return }
        // Making a space switches to it on its own; going somewhere after that is the guide's last step.
        if !isPrivate, Tutorial.done.contains("space") { Tutorial.complete("switch") }
        selectedTab?.captureSnapshot()
        selectedTab?.markActivated()
        currentSpaceID = id
        changed.send(.space)
        Brand.themeChanged.send(())
        if let tab = selectedTab {
            tab.markActivated()
            promote(tab)
            tab.ensureWebView()
        }
        changed.send(.selection)
    }

    /// What Clear closes in a space, in steps: first the faded tabs (unseen long enough to fade, not playing), keeping
    /// today's; once none are faded, every tab but the one you're on; once that's the last, it too. `faded` says
    /// which step it is, so the button can say so.
    func tabsToClear(in spaceID: UUID, now: Date = Date()) -> (tabs: [Tab], faded: Bool) {
        let tabs = self.tabs(in: spaceID)
        let current = selectedTab(in: spaceID)
        let partner = current.flatMap { self.partner(of: $0) }
        let others = tabs.filter { $0 !== current && $0 !== partner }
        let faded = others.filter { now.timeIntervalSince($0.lastActivated) > Tokens.Fade.start && !$0.isPlayingAudio }
        if !faded.isEmpty { return (faded, true) }
        return (others.isEmpty ? tabs.filter { $0 === current || $0 === partner } : others, false)
    }

    /// Ends a drag that opened another space and was dropped there: it becomes the space you're in, its colors and
    /// its own page with it, the rest of what a switch does.
    func settleInShownSpace() {
        Brand.themeChanged.send(())
        if let tab = selectedTab {
            tab.markActivated()
            promote(tab)
            tab.ensureWebView()
        }
        changed.send(.selection)
    }

    /// Shows another space's list without leaving the page you're on (used while dragging a tab).
    func showSpaceKeepingPage(_ id: UUID) {
        guard id != currentSpaceID, Library.shared.space(id) != nil else { return }
        currentSpaceID = id
        changed.send(.space)
    }

    func switchSpace(by offset: Int) {
        let spaces = Library.shared.spaces
        guard let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = index + offset
        guard spaces.indices.contains(next) else { return }
        switchToSpace(spaces[next].id)
    }

    private func libraryDidChange() {
        let spaceIDs = Set(Library.shared.spaces.map(\.id))
        // A removed space takes its tabs with it.
        for (id, tabs) in tabsBySpace where !spaceIDs.contains(id) {
            tabs.forEach { $0.close() }
            tabsBySpace[id] = nil
        }
        // A removed bookmark keeps its page around as a normal tab, so nothing disappears unexpectedly.
        let bookmarkIDs = Library.shared.allBookmarkIDs
        for (id, tab) in bookmarkTabs where !bookmarkIDs.contains(id) {
            bookmarkTabs[id] = nil
            tab.bookmarkID = nil
            if spaceIDs.contains(tab.spaceID) {
                tabsBySpace[tab.spaceID, default: []].insert(tab, at: 0)
            } else {
                tab.close()
            }
        }
        // Bookmarks moved to another space carry their live tab; one that became, or stopped being, a favorite
        // (undo, another window) says so.
        for (id, tab) in bookmarkTabs {
            if let space = Library.shared.spaceID(ofBookmark: id) { tab.spaceID = space }
            tab.isFavorite = Library.shared.isFavorite(id)
        }
        // Pinned pages stop being a pinned split (separated, one made a favorite, undo, another window): the split on
        // screen ends with it.
        let splitCount = splits.count
        splits.removeAll { pair in
            guard let left = tab(with: pair.left), let right = tab(with: pair.right) else { return false }
            return !canSplit(left, with: right)
        }
        if !spaceIDs.contains(currentSpaceID) {
            currentSpaceID = Library.shared.spaces[0].id
            changed.send(.space)
            changed.send(.selection)
        }
        changed.send(.structure)
        if splits.count != splitCount { changed.send(.selection) }
    }

    // MARK: Bookmarks

    /// Opens the bookmark's live tab, creating it on first use. Half of a pinned split opens with its other half,
    /// side by side again.
    func openBookmark(_ bookmark: Bookmark) {
        let tab = liveTab(for: bookmark)
        // Favorites belong to every space: they open in the one you're in.
        if Library.shared.isFavorite(bookmark.id) { tab.spaceID = currentSpaceID }
        if let pinned = Library.shared.pinnedSplit(containing: bookmark.id), split(for: tab) == nil,
           let otherBookmark = Library.shared.bookmark(pinned.left == bookmark.id ? pinned.right : pinned.left) {
            let other = liveTab(for: otherBookmark)
            unsplit(other, notify: false)
            var pair = pinned.left == bookmark.id ? SplitPair(left: tab.id, right: other.id) : SplitPair(left: other.id, right: tab.id)
            pair.ratio = pinned.ratio
            pair.vertical = pinned.vertical
            splits.append(pair)
            other.ensureWebView()
            changed.send(.structure)
        }
        select(tab)
    }

    /// A bookmark's live tab, made (not yet shown) if it isn't open.
    private func liveTab(for bookmark: Bookmark) -> Tab {
        if let tab = bookmarkTabs[bookmark.id] { return tab }
        let spaceID = Library.shared.spaceID(ofBookmark: bookmark.id) ?? currentSpaceID
        let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: spaceID)
        tab.isFavorite = Library.shared.isFavorite(bookmark.id)
        tab.host = host
        watch(tab)
        tab.bookmarkID = bookmark.id
        tab.landingUntil = Date().addingTimeInterval(8)
        bookmarkTabs[bookmark.id] = tab
        changed.send(.structure)
        return tab
    }

    /// Turns a tab into a bookmark at the given position. Its page stays open behind the bookmark. Half of a split
    /// pins the pair: both pages, side by side, still open together.
    func bookmarkTab(_ tab: Tab, at index: Int? = nil, in spaceID: UUID? = nil) {
        guard tab.bookmarkID == nil, let url = tab.url else { return }
        let space = spaceID ?? tab.spaceID
        if let pair = split(for: tab), let other = partner(of: tab), other.bookmarkID == nil, other.url != nil {
            let (left, right) = pair.left == tab.id ? (tab, other) : (other, tab)
            let marks = [left, right].map { half in
                let mark = Bookmark(url: half.url ?? url, title: Self.bookmarkTitle(half.displayTitle, url: half.url ?? url))
                removeFromList(half)
                half.bookmarkID = mark.id
                half.spaceID = space
                bookmarkTabs[mark.id] = half
                return mark
            }
            Library.shared.addPinnedSplit(marks[0], marks[1], to: space, at: index, ratio: pair.ratio, vertical: pair.vertical)
            return
        }
        unsplit(tab)
        removeFromList(tab)
        let bookmarkID = UUID()
        tab.bookmarkID = bookmarkID
        tab.spaceID = space
        bookmarkTabs[bookmarkID] = tab
        Library.shared.addBookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), to: space, at: index, id: bookmarkID)
    }

    /// Turns a bookmark's live tab back into a normal tab, removing the bookmark. Returns the tab now in the list:
    /// the live one, or, for an unloaded bookmark dropped at an index, a new one.
    @discardableResult
    func unbookmark(_ bookmarkID: UUID, toIndex index: Int? = nil) -> Tab? {
        if let pinned = Library.shared.pinnedSplit(containing: bookmarkID) { return unpin(pinned, returning: bookmarkID, toIndex: index) }
        if Library.shared.isFavorite(bookmarkID) {
            // A favorite comes back as a tab in the space you're in.
            bookmarkTabs[bookmarkID]?.spaceID = currentSpaceID
            bookmarkTabs[bookmarkID]?.isFavorite = false
        }
        var result: Tab?
        if let tab = bookmarkTabs[bookmarkID] {
            bookmarkTabs[bookmarkID] = nil
            tab.bookmarkID = nil
            let at = min(index ?? 0, tabsBySpace[tab.spaceID]?.count ?? 0)
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
            result = tab
        } else if let bookmark = Library.shared.bookmark(bookmarkID), let index {
            let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: Library.shared.spaceID(ofBookmark: bookmarkID) ?? currentSpaceID)
            tab.host = host
            watch(tab)
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: min(index, tabsBySpace[tab.spaceID]?.count ?? 0))
            result = tab
        }
        Library.shared.removeBookmark(bookmarkID)
        return result
    }

    /// Either half of a pinned split unpins the pair, back to two tabs in split view. Open pages come along as they
    /// are; one that isn't open opens fresh beside the other.
    private func unpin(_ pinned: PinnedSplit, returning bookmarkID: UUID, toIndex index: Int?) -> Tab? {
        let space = Library.shared.spaceID(ofBookmark: bookmarkID) ?? currentSpaceID
        let anyOpen = bookmarkTabs[pinned.left] != nil || bookmarkTabs[pinned.right] != nil
        var halves: [(id: UUID, tab: Tab)] = []
        for id in [pinned.left, pinned.right] {
            if let tab = bookmarkTabs[id] {
                bookmarkTabs[id] = nil
                tab.bookmarkID = nil
                halves.append((id, tab))
            } else if anyOpen || index != nil, let bookmark = Library.shared.bookmark(id) {
                let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
                tab.host = host
                watch(tab)
                halves.append((id, tab))
            }
        }
        tabsBySpace[space, default: []].insert(contentsOf: halves.map(\.tab), at: min(index ?? 0, tabsBySpace[space]?.count ?? 0))
        if halves.count == 2, partner(of: halves[0].tab) !== halves[1].tab {
            unsplit(halves[0].tab, notify: false)
            unsplit(halves[1].tab, notify: false)
            var pair = SplitPair(left: halves[0].tab.id, right: halves[1].tab.id)
            pair.ratio = pinned.ratio
            pair.vertical = pinned.vertical
            splits.append(pair)
        }
        Library.shared.removeBookmarks([pinned.left, pinned.right])
        // A pinned split that was on screen stays there, now as tabs.
        if halves.contains(where: { $0.tab === selectedTab }) { changed.send(.selection) }
        return halves.first { $0.id == bookmarkID }?.tab
    }

    /// True when a pinned tab has moved on from its pinned page.
    func isAway(_ bookmarkID: UUID) -> Bool {
        guard let tab = bookmarkTabs[bookmarkID], let url = tab.url, let bookmark = Library.shared.bookmark(bookmarkID) else { return false }
        let here = TabManager.normalize(url)
        return here != TabManager.normalize(bookmark.url) && here != tab.pinnedLanding.map(TabManager.normalize)
    }

    /// Turns the page a pinned tab moved on to into a tab of its own; the pinned item stays as it was, unloaded.
    func separateBookmarkTab(_ bookmarkID: UUID) {
        guard let tab = bookmarkTabs[bookmarkID] else { return }
        // Out of a pinned split too: an ordinary tab can't share a pinned one's split.
        unsplit(tab, notify: false)
        bookmarkTabs[bookmarkID] = nil
        tab.bookmarkID = nil
        tab.isFavorite = false
        tab.spaceID = currentSpaceID
        tabsBySpace[currentSpaceID, default: []].insert(tab, at: 0)
        changed.send(.structure)
        select(tab)
    }

    /// Sends a bookmark's page back to the bookmarked address.
    func resetBookmarkTab(_ bookmarkID: UUID) {
        guard let tab = bookmarkTabs[bookmarkID], let bookmark = Library.shared.bookmark(bookmarkID) else { return }
        // Already where it lands on its own: nothing to go back to.
        if let landing = tab.pinnedLanding, let url = tab.url, TabManager.normalize(url) == TabManager.normalize(landing) { return }
        tab.landingUntil = Date().addingTimeInterval(8)
        tab.load(bookmark.url)
    }

    /// Page titles make long bookmark names ("GitHub · Change is constant"). Keep the site's name when it leads.
    static func bookmarkTitle(_ title: String, url: URL) -> String {
        let separators = [" · ", " | ", " - ", " — ", " – ", ": "]
        let host = HistoryStore.normalizedHost(url).split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        for separator in separators {
            let parts = title.components(separatedBy: separator)
            guard parts.count > 1 else { continue }
            if let first = parts.first, first.lowercased().replacingOccurrences(of: " ", with: "").contains(host), !host.isEmpty { return first }
            if let last = parts.last, last.lowercased().replacingOccurrences(of: " ", with: "").contains(host), !host.isEmpty { return last }
        }
        return title
    }

    // MARK: Closing

    func close(_ tab: Tab) {
        let partnerTab = partner(of: tab)
        splits.removeAll { $0.left == tab.id || $0.right == tab.id }
        // Closing one half of a split shows the other half.
        if selectedTab === tab, let partnerTab {
            if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
            closeKeepingSelection(tab)
            select(partnerTab)
            return
        }
        let wasSelected = selectedTab === tab
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        if let bookmarkID = tab.bookmarkID {
            // Closing a pinned page closes it, wherever it had got to: one ⌘W, never two. The pin stays, and
            // opens fresh at its own address next time.
            bookmarkTabs[bookmarkID] = nil
            recentTabIDs.removeAll { $0 == tab.id }
            tab.close()
            changed.send(.structure)
            if wasSelected { selectAfterClosing(tab, index: 0) }
            return
        }
        guard var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) else { return }
        closedTabs.append(ClosedTab(id: tab.id, url: tab.url, title: tab.displayTitle, spaceID: tab.spaceID, index: index,
                                    interactionState: tab.interactionStateForSaving, customTitle: tab.customTitle))
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        list.remove(at: index)
        tabsBySpace[tab.spaceID] = list
        recentTabIDs.removeAll { $0 == tab.id }
        tab.close()
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    /// Removes a tab without choosing a new selection (the caller does).
    private func closeKeepingSelection(_ tab: Tab) {
        if let bookmarkID = tab.bookmarkID {
            bookmarkTabs[bookmarkID] = nil
        } else if var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) {
            closedTabs.append(ClosedTab(id: tab.id, url: tab.url, title: tab.displayTitle, spaceID: tab.spaceID, index: index,
                                        interactionState: tab.interactionStateForSaving, customTitle: tab.customTitle))
            list.remove(at: index)
            tabsBySpace[tab.spaceID] = list
        }
        recentTabIDs.removeAll { $0 == tab.id }
        tab.close()
        changed.send(.structure)
    }

    /// Returns the ordinary tabs' ids in the order they closed: reopening in reverse puts each back where it was.
    @discardableResult
    func close(_ tabs: [Tab]) -> [UUID] {
        let selected = selectedTab
        let closingSelected = tabs.contains { $0 === selected }
        let order = tabs.filter { $0 !== selected } + (closingSelected ? [selected].compactMap { $0 } : [])
        let ids = order.filter { $0.bookmarkID == nil }.map(\.id)
        order.forEach { close($0) }
        return ids
    }

    /// Set while Clear closes the last tabs: the space is left empty rather than opening a pinned page you
    /// visited earlier, which would look like a tab from nowhere.
    private var leavesSpaceEmpty = false

    /// Closes tabs; if that empties the space, nothing else gets picked to show.
    @discardableResult
    func closeLeavingSpaceEmpty(_ tabs: [Tab]) -> [UUID] {
        leavesSpaceEmpty = true
        defer { leavesSpaceEmpty = false }
        return close(tabs)
    }

    private func selectAfterClosing(_ closed: Tab, index: Int) {
        let list = tabs(in: closed.spaceID)
        if let opener = closed.opener, list.contains(where: { $0 === opener }) {
            select(opener)
        } else if !list.isEmpty {
            select(list[min(index, list.count - 1)])
        } else if !leavesSpaceEmpty, let recent = recentTabs.first(where: { $0.spaceID == closed.spaceID }) {
            select(recent)
        } else {
            selectedBySpace[closed.spaceID] = nil
            changed.send(.selection)
        }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    @discardableResult
    /// The latest closed tab (⇧⌘T), or, with an id, that one (⌘Z after closing it).
    func reopenClosedTab(_ id: UUID? = nil, select: Bool = true) -> Tab? {
        let found: Int? = id.map { id in closedTabs.lastIndex { $0.id == id } } ?? (closedTabs.isEmpty ? nil : closedTabs.count - 1)
        guard let index = found else { return nil }
        let closed = closedTabs.remove(at: index)
        let space = Library.shared.space(closed.spaceID) != nil ? closed.spaceID : currentSpaceID
        let tab = Tab(url: closed.url, title: closed.title, spaceID: space, interactionState: closed.interactionState)
        tab.customTitle = closed.customTitle
        tab.host = host
        watch(tab)
        var list = tabsBySpace[space] ?? []
        list.insert(tab, at: min(closed.index, list.count))
        tabsBySpace[space] = list
        changed.send(.structure)
        if select { self.select(tab) } else { recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count)) }
        return tab
    }

    // MARK: Moving

    private func removeFromList(_ tab: Tab) {
        tabsBySpace[tab.spaceID]?.removeAll { $0 === tab }
    }

    func move(_ tab: Tab, to index: Int, in spaceID: UUID? = nil) {
        guard tab.bookmarkID == nil else { return }
        let target = spaceID ?? tab.spaceID
        // A split can't span two spaces: moving either half out ends it.
        if target != tab.spaceID { splits.removeAll { $0.left == tab.id || $0.right == tab.id } }
        removeFromList(tab)
        tab.spaceID = target
        var list = tabsBySpace[target] ?? []
        list.insert(tab, at: max(0, min(index, list.count)))
        tabsBySpace[target] = list
        // No other space keeps it selected, whichever one is showing.
        for (space, id) in selectedBySpace where id == tab.id && space != target { selectedBySpace[space] = nil }
        changed.send(.structure)
    }

    /// Into another space: at `index` where it was dropped, else at the top.
    func moveTabToSpace(_ tab: Tab, spaceID: UUID, at index: Int = 0) {
        let wasSelected = selectedTab === tab
        let oldIndex = tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        move(tab, to: index, in: spaceID)
        if wasSelected { selectAfterClosing(Tab(url: nil, spaceID: currentSpaceID), index: oldIndex) }
    }

    // MARK: Duplicates

    static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased() == "http" ? "https" : components.scheme?.lowercased()
        if let host = components.host?.lowercased() { components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? url.absoluteString
    }

    /// An open tab (or live bookmark) already showing this address, preferring the current space.
    func existingTab(for url: URL) -> Tab? {
        let key = Self.normalize(url)
        let candidates = navigableTabs + allTabs
        return candidates.first { tab in tab.url.map(Self.normalize) == key }
    }

    // MARK: Split view

    struct SplitPair: Codable, Equatable {
        var left: UUID
        var right: UUID
        /// Share of the width (or height, when vertical) the first pane gets.
        var ratio: Double = 0.5
        /// Stacked top and bottom instead of side by side.
        var vertical = false

        init(left: UUID, right: UUID) {
            self.left = left
            self.right = right
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            left = try c.decode(UUID.self, forKey: .left)
            right = try c.decode(UUID.self, forKey: .right)
            ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            vertical = try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? false
        }
    }

    private(set) var splits: [SplitPair] = []

    func split(for tab: Tab) -> SplitPair? {
        splits.first { $0.left == tab.id || $0.right == tab.id }
    }

    func partner(of tab: Tab) -> Tab? {
        guard let pair = split(for: tab) else { return nil }
        return self.tab(with: pair.left == tab.id ? pair.right : pair.left)
    }

    /// Ordinary tabs split, and the two pinned pages of a pinned split; a pinned page and a tab, or a favorite, have
    /// no one row to carry the pair.
    func canSplit(_ tab: Tab, with other: Tab) -> Bool {
        guard tab !== other else { return false }
        guard let a = tab.bookmarkID, let b = other.bookmarkID else { return tab.bookmarkID == nil && other.bookmarkID == nil }
        return Library.shared.pinnedSplit(containing: a)?.contains(b) == true
    }

    /// Puts `other` beside `tab` (on the right or left), ending any splits either was in.
    func makeSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool = true) {
        guard canSplit(tab, with: other) else { return }
        unsplit(tab, notify: false)
        unsplit(other, notify: false)
        if other.spaceID != tab.spaceID {
            removeFromList(other)
            other.spaceID = tab.spaceID
            tabsBySpace[tab.spaceID, default: []].insert(other, at: 0)
        }
        splits.append(otherOnRight ? SplitPair(left: tab.id, right: other.id) : SplitPair(left: other.id, right: tab.id))
        Tutorial.complete("split")
        other.ensureWebView()
        changed.send(.structure)
        select(other)
    }

    /// A tab a link opened in a split took its opener's pane; going back from it puts the opener back there.
    func returnPane(of tab: Tab, to opener: Tab) {
        guard let index = splits.firstIndex(where: { $0.left == tab.id || $0.right == tab.id }), split(for: opener) == nil,
              canSplit(tab, with: opener), opener.spaceID == tab.spaceID else { return }
        if splits[index].left == tab.id { splits[index].left = opener.id } else { splits[index].right = opener.id }
        opener.ensureWebView()
    }

    func unsplit(_ tab: Tab, notify: Bool = true) {
        let before = splits.count
        splits.removeAll { $0.left == tab.id || $0.right == tab.id }
        if notify, splits.count != before {
            changed.send(.structure)
            changed.send(.selection)
        }
    }

    /// Takes one pane out of its split and shows the other on its own.
    func unsplit(_ tab: Tab, keep other: Tab) {
        unsplit(tab, notify: false)
        changed.send(.structure)
        select(other)
    }

    func toggleSplitOrientation(for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.left == tab.id || $0.right == tab.id }) else { return }
        splits[index].vertical.toggle()
        rememberPinnedLayout(splits[index])
        changed.send(.selection)
    }

    /// The two pages trade places; each keeps the size it had.
    func swapSplit(for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.left == tab.id || $0.right == tab.id }) else { return }
        let pair = splits[index]
        splits[index].left = pair.right
        splits[index].right = pair.left
        splits[index].ratio = 1 - pair.ratio
        rememberPinnedLayout(splits[index])
        changed.send(.structure)
    }

    func setSplitRatio(_ ratio: Double, for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.left == tab.id || $0.right == tab.id }) else { return }
        splits[index].ratio = min(max(ratio, 0.2), 0.8)
        rememberPinnedLayout(splits[index])
    }

    /// A pinned split keeps how it was last laid out, so it opens that way again.
    private func rememberPinnedLayout(_ pair: SplitPair) {
        guard let left = tab(with: pair.left)?.bookmarkID, let right = tab(with: pair.right)?.bookmarkID else { return }
        var layout = PinnedSplit(left: left, right: right)
        layout.ratio = pair.ratio
        layout.vertical = pair.vertical
        Library.shared.setPinnedSplitLayout(layout)
    }

    /// Puts back a split exactly as it was (undo).
    func restoreSplit(_ pair: SplitPair) {
        guard let left = tab(with: pair.left), let right = tab(with: pair.right) else { return }
        unsplit(left, notify: false)
        unsplit(right, notify: false)
        splits.append(pair)
        changed.send(.structure)
        changed.send(.selection)
    }

    func restoreSplits(_ pairs: [SplitPair]) {
        splits = pairs.filter { pair in
            guard let left = tab(with: pair.left), let right = tab(with: pair.right) else { return false }
            return canSplit(left, with: right)
        }
    }

    // MARK: Suspension

    /// Background tabs nobody has looked at in a while give their memory back.
    private func suspendIdleTabs() {
        // Kept awake: what's on screen (both halves of a split), anything in a call or floating, and sites that notify.
        // Other spaces' pages sleep like any tab once idle; their snapshots still show while you swipe to them.
        var selectedIDs = Set([selectedTab?.id].compactMap { $0 })
        for id in Array(selectedIDs) { if let tab = tab(with: id), let other = partner(of: tab) { selectedIDs.insert(other.id) } }
        let live = allTabs.filter { !$0.isSuspended }
        let idleLimit: TimeInterval = 15 * 60
        let maxLive = 10
        let now = Date()
        let candidates = live
            .filter { !selectedIDs.contains($0.id) && !$0.isPlayingAudio && !$0.isInUse && !$0.notifiesUser }
            .sorted { $0.lastActivated < $1.lastActivated }
        var liveCount = live.count
        for tab in candidates {
            // Over the cap a tab still gets five minutes: a half-written message in one you just left survives.
            let idle = now.timeIntervalSince(tab.lastActivated)
            if idle > idleLimit || (liveCount > maxLive && idle > 5 * 60) {
                tab.suspend()
                liveCount -= 1
            }
        }
        // Each space keeps the page it shows out of the archive, as before.
        archiveStaleTabs(keeping: selectedIDs.union(selectedBySpace.values))
    }

    /// Ordinary tabs unseen for longer than the setting move to the archive. Never pinned pages or favorites,
    /// what's on screen, a split, anything playing or in a call, a site that sends notifications, or a private window's tabs.
    private func archiveStaleTabs(keeping onScreen: Set<UUID>) {
        if !isPrivate { TabArchive.offerIfCrowded(tabCount: tabsBySpace.values.map(\.count).max() ?? 0) }
        guard !isPrivate, let limit = TabArchive.after.interval else { return }
        let now = Date()
        let stale = tabsBySpace.values.flatMap { $0 }.filter {
            $0.bookmarkID == nil && !onScreen.contains($0.id) && partner(of: $0) == nil && !$0.isPlayingAudio && !$0.isInUse && !$0.notifiesUser
                && now.timeIntervalSince($0.lastActivated) > limit && $0.url != nil
        }
        guard !stale.isEmpty else { return }
        for tab in stale {
            guard let url = tab.url, var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) else { continue }
            TabArchive.shared.add(ArchivedTab(url: url, title: tab.displayTitle, spaceID: tab.spaceID, archivedAt: now))
            list.remove(at: index)
            tabsBySpace[tab.spaceID] = list
            recentTabIDs.removeAll { $0 == tab.id }
            tab.close()
        }
        changed.send(.structure)
    }
}
