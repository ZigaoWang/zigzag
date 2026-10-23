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

    /// Watches a tab so navigation inside it gets saved for crash recovery.
    private func watch(_ tab: Tab) {
        tab.privateStore = privateStore
        tabTokens[tab.id] = tab.changed.observe { [weak self] change in
            if change == .url || change == .title || change == .audio { self?.changed.send(.content) }
        }
    }
    private var suspendTimer: Timer?

    struct ClosedTab {
        let url: URL?
        let title: String
        let spaceID: UUID
        let index: Int
        let interactionState: Data?
    }

    /// Private windows share one throwaway store between their tabs, gone when the window closes.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    init(spaceID: UUID? = nil, isPrivate: Bool = false) {
        privateStore = isPrivate ? .nonPersistent() : nil
        let requested = spaceID.flatMap { Library.shared.space($0)?.id }
        currentSpaceID = requested ?? Library.shared.spaces[0].id
        libraryToken = Library.shared.changed.observe { [weak self] in self?.libraryDidChange() }
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendIdleTabs() }
        }
    }

    func invalidate() {
        suspendTimer?.invalidate()
        allTabs.forEach { $0.close() }
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
        if tab.spaceID != currentSpaceID {
            currentSpaceID = tab.spaceID
            changed.send(.space)
        }
        let previous = selectedTab
        previous?.captureSnapshot()
        selectedBySpace[tab.spaceID] = tab.id
        tab.markActivated()
        promote(tab)
        tab.ensureWebView()
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

    /// Bookmarks then tabs, in sidebar order: what Cmd+Option+Up/Down and Cmd+1…9 walk.
    var navigableTabs: [Tab] {
        let bookmarkLive = Library.shared.bookmarks(in: currentSpaceID).compactMap { bookmarkTabs[$0.id] }
        return bookmarkLive + currentTabs
    }

    // MARK: Spaces

    func switchToSpace(_ id: UUID) {
        guard id != currentSpaceID, Library.shared.space(id) != nil else { return }
        selectedTab?.captureSnapshot()
        currentSpaceID = id
        changed.send(.space)
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
        let bookmarkIDs = Set(Library.shared.allBookmarks.map(\.0.id))
        for (id, tab) in bookmarkTabs where !bookmarkIDs.contains(id) {
            bookmarkTabs[id] = nil
            tab.bookmarkID = nil
            if spaceIDs.contains(tab.spaceID) {
                tabsBySpace[tab.spaceID, default: []].insert(tab, at: 0)
            } else {
                tab.close()
            }
        }
        // Bookmarks moved to another space carry their live tab.
        for (id, tab) in bookmarkTabs {
            if let space = Library.shared.spaceID(ofBookmark: id) { tab.spaceID = space }
        }
        if !spaceIDs.contains(currentSpaceID) {
            currentSpaceID = Library.shared.spaces[0].id
            changed.send(.space)
            changed.send(.selection)
        }
        changed.send(.structure)
    }

    // MARK: Bookmarks

    /// Opens the bookmark's live tab, creating it on first use.
    func openBookmark(_ bookmark: Bookmark) {
        if let tab = bookmarkTabs[bookmark.id] {
            select(tab)
            return
        }
        let spaceID = Library.shared.spaceID(ofBookmark: bookmark.id) ?? currentSpaceID
        let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: spaceID)
        tab.host = host
        watch(tab)
        tab.bookmarkID = bookmark.id
        bookmarkTabs[bookmark.id] = tab
        changed.send(.structure)
        select(tab)
    }

    /// Turns a tab into a bookmark at the given position. Its page stays open behind the bookmark.
    func bookmarkTab(_ tab: Tab, at index: Int? = nil, in spaceID: UUID? = nil) {
        guard tab.bookmarkID == nil, let url = tab.url else { return }
        let space = spaceID ?? tab.spaceID
        removeFromList(tab)
        let bookmarkID = UUID()
        tab.bookmarkID = bookmarkID
        tab.spaceID = space
        bookmarkTabs[bookmarkID] = tab
        Library.shared.addBookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), to: space, at: index, id: bookmarkID)
    }

    /// Turns a bookmark's live tab back into a normal tab, removing the bookmark.
    func unbookmark(_ bookmarkID: UUID, toIndex index: Int? = nil) {
        if let tab = bookmarkTabs[bookmarkID] {
            bookmarkTabs[bookmarkID] = nil
            tab.bookmarkID = nil
            let at = min(index ?? 0, tabsBySpace[tab.spaceID]?.count ?? 0)
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
        } else if let bookmark = Library.shared.bookmark(bookmarkID), let index {
            let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: Library.shared.spaceID(ofBookmark: bookmarkID) ?? currentSpaceID)
            tab.host = host
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: min(index, tabsBySpace[tab.spaceID]?.count ?? 0))
        }
        Library.shared.removeBookmark(bookmarkID)
    }

    /// Sends a bookmark's page back to the bookmarked address.
    func resetBookmarkTab(_ bookmarkID: UUID) {
        guard let tab = bookmarkTabs[bookmarkID], let bookmark = Library.shared.bookmark(bookmarkID) else { return }
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
        let wasSelected = selectedTab === tab
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
        if let bookmarkID = tab.bookmarkID {
            // Closing a bookmark only unloads its page; the bookmark stays.
            bookmarkTabs[bookmarkID] = nil
            recentTabIDs.removeAll { $0 == tab.id }
            tab.close()
            changed.send(.structure)
            if wasSelected { selectAfterClosing(tab, index: 0) }
            return
        }
        guard var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) else { return }
        closedTabs.append(ClosedTab(url: tab.url, title: tab.displayTitle, spaceID: tab.spaceID, index: index,
                                    interactionState: tab.interactionStateForSaving))
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        list.remove(at: index)
        tabsBySpace[tab.spaceID] = list
        recentTabIDs.removeAll { $0 == tab.id }
        tab.close()
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    func close(_ tabs: [Tab]) {
        let selected = selectedTab
        let closingSelected = tabs.contains { $0 === selected }
        for tab in tabs where tab !== selected { close(tab) }
        if closingSelected, let selected { close(selected) }
    }

    private func selectAfterClosing(_ closed: Tab, index: Int) {
        let list = tabs(in: closed.spaceID)
        if let opener = closed.opener, list.contains(where: { $0 === opener }) {
            select(opener)
        } else if !list.isEmpty {
            select(list[min(index, list.count - 1)])
        } else if let recent = recentTabs.first(where: { $0.spaceID == closed.spaceID }) {
            select(recent)
        } else {
            selectedBySpace[closed.spaceID] = nil
            changed.send(.selection)
        }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    @discardableResult
    func reopenClosedTab() -> Tab? {
        guard let closed = closedTabs.popLast() else { return nil }
        let space = Library.shared.space(closed.spaceID) != nil ? closed.spaceID : currentSpaceID
        let tab = Tab(url: closed.url, title: closed.title, spaceID: space, interactionState: closed.interactionState)
        tab.host = host
        watch(tab)
        var list = tabsBySpace[space] ?? []
        list.insert(tab, at: min(closed.index, list.count))
        tabsBySpace[space] = list
        changed.send(.structure)
        select(tab)
        return tab
    }

    // MARK: Moving

    private func removeFromList(_ tab: Tab) {
        tabsBySpace[tab.spaceID]?.removeAll { $0 === tab }
    }

    func move(_ tab: Tab, to index: Int, in spaceID: UUID? = nil) {
        guard tab.bookmarkID == nil else { return }
        let target = spaceID ?? tab.spaceID
        removeFromList(tab)
        tab.spaceID = target
        var list = tabsBySpace[target] ?? []
        list.insert(tab, at: max(0, min(index, list.count)))
        tabsBySpace[target] = list
        if selectedBySpace.values.contains(tab.id), target != currentSpaceID {
            for (space, id) in selectedBySpace where id == tab.id { selectedBySpace[space] = nil }
        }
        changed.send(.structure)
    }

    func moveTabToSpace(_ tab: Tab, spaceID: UUID) {
        let wasSelected = selectedTab === tab
        let index = tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        move(tab, to: 0, in: spaceID)
        if wasSelected { selectAfterClosing(Tab(url: nil, spaceID: currentSpaceID), index: index) }
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

    // MARK: Suspension

    /// Background tabs nobody has looked at in a while give their memory back.
    private func suspendIdleTabs() {
        let selectedIDs = Set(selectedBySpace.values)
        let live = allTabs.filter { !$0.isSuspended }
        let idleLimit: TimeInterval = 15 * 60
        let maxLive = 10
        let now = Date()
        let candidates = live
            .filter { !selectedIDs.contains($0.id) && !$0.isPlayingAudio }
            .sorted { $0.lastActivated < $1.lastActivated }
        var liveCount = live.count
        for tab in candidates {
            if now.timeIntervalSince(tab.lastActivated) > idleLimit || liveCount > maxLive {
                tab.suspend()
                liveCount -= 1
            }
        }
    }
}
