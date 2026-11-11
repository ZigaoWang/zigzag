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
    /// Closed tabs brought back, by the id each had: the new tab's id.
    private var reopenedAs: [UUID: UUID] = [:]
    /// How many closed tabs ⇧⌘T and ⌘Z can bring back: fifty more than the biggest lot closed at once. It never
    /// shrinks back, or closing two more after Clear took sixty would leave ⌘Z on the sixty short.
    private var closedLimit = 50

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

    /// A tab closed by a change elsewhere (a space or pinned page deleted): no longer watched or among the recent.
    private func forget(_ tab: Tab) {
        tabTokens[tab.id] = nil
        recentTabIDs.removeAll { $0 == tab.id }
    }

    struct ClosedTab {
        /// The closed tab's own id, so undo brings back that tab, not just the latest closed one.
        var id = UUID()
        let url: URL?
        let title: String
        let spaceID: UUID
        let index: Int
        let interactionState: Data?
        var customTitle: String? = nil
        /// The split it was half of, so bringing it back puts it beside its partner again.
        var split: SplitPair? = nil
        /// When it was last looked at: brought back, it's as recent as it was, so Clear and the fading see it so too.
        var lastActivated = Date()
        /// The tab it sat under, and the tabs that sat under it (they moved up a level): brought back, it goes under
        /// the one again and takes the others back, if they're still where it left them.
        var parentID: UUID? = nil
        var childIDs: [UUID] = []
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
            MainActor.assumeIsolated { self?.sleepIdleTabs() }
        }
        // Slack, so the system can fold it into other wake-ups instead of waking the Mac for it.
        suspendTimer?.tolerance = 10
    }

    func invalidate() {
        suspendTimer?.invalidate()
        allTabs.forEach { $0.close(keepingSnapshot: !isPrivate) }
        tabsBySpace = [:]
        bookmarkTabs = [:]
    }

    // MARK: Reading

    /// The profile of the space you're in.
    var profile: Profile { Profiles.shared.profile(forSpace: currentSpaceID) }

    /// A space on this profile for something that belongs there (a page one of its extensions opens): the one
    /// you're in if it's on that profile, else one with tabs in this window, else the profile's first.
    func space(for profile: Profile) -> UUID? {
        if self.profile === profile { return currentSpaceID }
        let spaces = Library.shared.spaces(in: profile.id).map(\.id)
        return spaces.first { !tabs(in: $0).isEmpty } ?? spaces.first
    }
    /// That profile's extensions; none in a private window, where extensions don't run.
    @available(macOS 15.4, *)
    var extensionHost: ExtensionHost? { isPrivate ? nil : profile.extensions }
    var currentSpace: SpaceInfo { Library.shared.space(currentSpaceID) ?? Library.shared.spaces[0] }
    var currentTabs: [Tab] { tabs(in: currentSpaceID) }
    func tabs(in spaceID: UUID) -> [Tab] { tabsBySpace[spaceID] ?? [] }

    var allTabs: [Tab] { tabsBySpace.values.flatMap { $0 } + Array(bookmarkTabs.values) }

    var selectedTab: Tab? { selectedTab(in: currentSpaceID) }

    func selectedTab(in spaceID: UUID) -> Tab? {
        guard let id = selectedBySpace[spaceID] else { return nil }
        return tab(with: id)
    }

    /// Asked once per sidebar row on every refresh: looks through the lists in place rather than building `allTabs`.
    func tab(with id: UUID) -> Tab? {
        for list in tabsBySpace.values { if let tab = list.first(where: { $0.id == id }) { return tab } }
        return bookmarkTabs.values.first { $0.id == id }
    }

    func bookmarkTab(for bookmarkID: UUID) -> Tab? { bookmarkTabs[bookmarkID] }

    /// Tabs in most-recently-used order across all spaces.
    var recentTabs: [Tab] {
        // One pass to index the tabs, not a search for each id.
        let byID = Dictionary(allTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recentTabIDs.compactMap { byID[$0] }
    }

    // MARK: Creating

    /// Where a new tab goes in the list (Settings › Tabs). Next to the current tab is what Chrome and Safari do, so
    /// a tab shows up where you were looking; Arc's way, on top, and the bottom are choices.
    enum NewTabPlace: String, CaseIterable { case next, top, bottom }
    static var newTabPlace: NewTabPlace {
        get { UserDefaults.standard.string(forKey: "NewTabPlace").flatMap(NewTabPlace.init(rawValue:)) ?? .next }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "NewTabPlace") }
    }

    /// Where a new tab lands in a space's list: next to the tab it came from (after the others it already opened, so a
    /// row of links stays in reading order), or below the tab you're on; on top when neither is in the list. Next to
    /// a tab means after the tabs nested under it too.
    private func newTabIndex(in space: UUID, opener: Tab?, select: Bool) -> Int {
        let list = tabsBySpace[space] ?? []
        let nodes = treeNodes(in: space)
        switch Self.newTabPlace {
        case .top: return 0
        case .bottom: return list.count
        case .next:
            if let opener, let at = list.firstIndex(where: { $0 === opener }) {
                var index = TabTree.subtreeEnd(at: at, in: nodes)
                while index < list.count, list[index].opener === opener { index = TabTree.subtreeEnd(at: index, in: nodes) }
                return index
            }
            if space == currentSpaceID, let here = selectedTab, let at = list.firstIndex(where: { $0 === here }) {
                // Several opened in a row beside the same tab (an extension opening a few pages) keep their order:
                // each goes after the last one placed there, not in front of it.
                if !select, let beside = placedBeside, beside.anchor === here, let last = beside.last,
                   let after = list.firstIndex(where: { $0 === last }), after > at { return TabTree.subtreeEnd(at: after, in: nodes) }
                return TabTree.subtreeEnd(at: at, in: nodes)
            }
            return 0
        }
    }

    /// Settings › Tabs: a link opened in a new tab from a page (⌘-click, a middle-click, Open Link in New Tab, a link
    /// that opens a new window) goes under that page's tab, as Horse does. Off unless you turn it on.
    static var nestsOpenedLinks: Bool {
        get { UserDefaults.standard.bool(forKey: "NestsOpenedLinks") }
        set { UserDefaults.standard.set(newValue, forKey: "NestsOpenedLinks") }
    }

    /// Where a new tab goes and the tab it goes under. With nested tabs on, a link goes under the tab it came from,
    /// after what that tab already opened; otherwise it stands beside the tab it came from (or the one you're on),
    /// at that tab's level, and never breaks into another tab's group.
    private func newTabPlacement(in space: UUID, opener: Tab?, select: Bool) -> (index: Int, parent: UUID?) {
        let nodes = treeNodes(in: space)
        if Self.nestsOpenedLinks, let opener, opener.bookmarkID == nil, !opener.isPeek, opener.spaceID == space,
           let at = TabTree.childIndex(of: opener.id, in: nodes) {
            return (at, opener.id)
        }
        let index = newTabIndex(in: space, opener: opener, select: select)
        let anchor = opener ?? (space == currentSpaceID ? selectedTab : nil)
        return (index, TabTree.parent(at: index, preferring: anchor?.bookmarkID == nil ? anchor?.parentID : nil, in: nodes))
    }

    /// The last tab put beside the current one with nothing that opened it, so the next lands after it.
    private var placedBeside: PlacedBeside?
    private struct PlacedBeside { weak var anchor: Tab?; weak var last: Tab? }

    @discardableResult
    func newTab(url: URL?, spaceID: UUID? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil,
                opener: Tab? = nil, title: String? = nil) -> Tab {
        // A page another page opened stays with it: WebKit made it in that page's profile.
        // One WebKit made for a page with no tab of its own here (a Zigzag Mini's, a sign-in window's) goes to a
        // space on that page's profile, not to whichever space this window happens to show.
        let made = configuration.flatMap { Profiles.shared.profile(ofStore: $0.websiteDataStore) }
        let space = spaceID ?? (configuration != nil ? opener?.spaceID : nil) ?? made.flatMap { self.space(for: $0) } ?? currentSpaceID
        let tab = Tab(url: url, title: title, spaceID: space, configuration: configuration)
        tab.host = host
        watch(tab)
        tab.opener = opener
        // Placed once, as Settings says; the list never reorders itself after that.
        let place = newTabPlacement(in: space, opener: opener, select: select)
        tab.parentID = place.parent
        tabsBySpace[space, default: []].insert(tab, at: place.index)
        unfold(place.parent)
        if opener == nil, !select, Self.newTabPlace == .next, space == currentSpaceID { placedBeside = PlacedBeside(anchor: selectedTab, last: tab) } else { placedBeside = nil }
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        // Opened in front from a page in split view: it takes that page's pane, so the split stays on screen and
        // the page it came from waits in the list. A pinned split keeps its pages; the new tab shows on its own.
        if select, let opener, opener.bookmarkID == nil, opener.spaceID == space, let index = splits.firstIndex(where: { $0.left == opener.id || $0.right == opener.id }) {
            if splits[index].left == opener.id { splits[index].left = tab.id } else { splits[index].right = tab.id }
            // Half of the split now, it's a row of its own, not one nested under the page it came from.
            liftToTopLevel(tab)
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
        liftChildren(of: tab)
        tabsBySpace[tab.spaceID]?.remove(at: index)
        recentTabIDs.removeAll { $0 == tab.id }
        tabTokens[tab.id] = nil
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    /// A pinned page's or favorite's open page out of this window, still loaded, so another window can adopt it.
    func detachBookmarkTab(_ bookmarkID: UUID) -> Tab? {
        guard let tab = bookmarkTabs[bookmarkID] else { return nil }
        splits.removeAll { $0.left == tab.id || $0.right == tab.id }
        let wasSelected = selectedTab === tab
        bookmarkTabs[bookmarkID] = nil
        recentTabIDs.removeAll { $0 == tab.id }
        tabTokens[tab.id] = nil
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: 0) }
        return tab
    }

    /// A pinned page's or favorite's open page from another window, in the space you're in.
    func insertBookmarkTab(_ tab: Tab, bookmarkID: UUID) {
        tab.setSpace(currentSpaceID)
        adoptBookmarkTab(tab, bookmarkID: bookmarkID)
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
    }

    /// Adds a tab that already has a page (a promoted peek) to the top of the list and shows it.
    func insert(_ tab: Tab, at index: Int = 0) {
        tab.host = host
        tab.setSpace(currentSpaceID)
        watch(tab)
        var list = tabsBySpace[currentSpaceID] ?? []
        let at = min(max(index, 0), list.count)
        // It joins the group it lands in, if any, so the group stays whole.
        tab.parentID = TabTree.parentForInsertion(at: at, in: treeNodes(in: currentSpaceID))
        list.insert(tab, at: at)
        tabsBySpace[currentSpaceID] = list
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        changed.send(.structure)
        select(tab)
    }

    /// A page that comes in from outside the list (Zigzag Mini's), placed where a new tab would go, and shown.
    func insertAsNewTab(_ tab: Tab) {
        insert(tab, at: newTabIndex(in: currentSpaceID, opener: nil, select: true))
    }

    /// Inserts already-built tabs (session restore, imports) without selecting.
    func adopt(_ tabs: [Tab], in spaceID: UUID) {
        for tab in tabs { tab.host = host; watch(tab) }
        tabsBySpace[spaceID, default: []].append(contentsOf: tabs)
        // A session from before nested tabs has no parents; a tab whose parent didn't come back goes to the top level.
        repairTree(in: spaceID)
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
        // A tab closed since (one an old undo step or a stale button still points at) never comes back from here.
        guard !tab.isClosed else { return }
        Autofill.shared.hide()
        // Favorites belong to every space of their profile: they open in the one you're in. Reached from a space
        // on another profile (the command bar, an extension), one opens in a space of its own profile.
        if tab.isFavorite {
            let home = tab.homeProfile
            if profile === home {
                tab.setSpace(currentSpaceID)
            } else if Profiles.shared.profile(forSpace: tab.spaceID) !== home, let space = space(for: home) {
                tab.setSpace(space)
            }
        }
        if tab.spaceID != currentSpaceID {
            currentSpaceID = tab.spaceID
            changed.send(.space)
        }
        let previous = selectedTab
        previous?.captureSnapshot()
        // Where you were and what you'd typed, in case its page has to load again while you're away.
        if previous !== tab { previous?.readPageState() }
        // Idle counts from when you last saw a tab, not when you first opened it: a page you read for an hour
        // and just left isn't unloaded the moment you look away.
        if previous !== tab { previous?.markActivated() }
        selectedBySpace[tab.spaceID] = tab.id
        tab.markActivated()
        promote(tab)
        tab.ensureWebView()
        tab.reloadIfItStopped()
        tab.shown()
        if #available(macOS 15.4, *), previous !== tab { ExtensionCenter.tabActivated(tab, previous: previous) }
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

    /// Favorites, bookmarks, then tabs, in sidebar order: what Cmd+Option+Up/Down walk.
    var navigableTabs: [Tab] {
        let favoriteLive = Library.shared.favorites(in: profile.id).compactMap { bookmarkTabs[$0.id] }
        let bookmarkLive = Library.shared.bookmarks(in: currentSpaceID).compactMap { bookmarkTabs[$0.id] }
        return favoriteLive + bookmarkLive + currentTabs
    }

    /// Turns a tab into a favorite at a tile's place. Its page stays open behind the tile.
    func favoriteTab(_ tab: Tab, at index: Int? = nil) {
        guard let url = address(of: tab) else { return }
        // Half of a split brings the other half: the two become one favorite, side by side. A half with no page to
        // keep can't come along, so the split ends and the tab goes on its own.
        if let pair = split(for: tab) {
            if favoriteSplit(pair, at: index) { return }
            unsplit(tab, notify: false)
        }
        if let bookmarkID = tab.bookmarkID {
            Library.shared.makeFavorite(bookmarkID, at: index, in: profile.id)
            tab.isFavorite = true
            return
        }
        removeFromList(tab)
        let id = UUID()
        tab.bookmarkID = id
        tab.isFavorite = true
        bookmarkTabs[id] = tab
        Library.shared.addFavorite(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), at: index, id: id, in: profile.id)
    }

    /// A pinned page into the favorites at a tile's place, open or not; open, a split it's in comes along.
    func favoriteBookmark(_ bookmarkID: UUID, at index: Int?) {
        if let tab = bookmarkTabs[bookmarkID] { favoriteTab(tab, at: index) } else { Library.shared.makeFavorite(bookmarkID, at: index, in: profile.id) }
    }

    /// Where a page is, or, for a pinned page not loaded yet, where it's pinned to.
    private func address(of tab: Tab) -> URL? { tab.url ?? tab.bookmarkID.flatMap { Library.shared.bookmark($0)?.url } }

    /// A bookmark's page, made (not yet shown) if it isn't open.
    func pageTab(for bookmark: Bookmark) -> Tab { liveTab(for: bookmark) }

    /// A tab (or a pinned page's tab) joins a favorite: the two become one favorite, side by side where the favorite
    /// was, and open together.
    func joinFavorite(_ tab: Tab, onto favoriteID: UUID, onRight: Bool) {
        // A pinned page that isn't loaded has no address of its own yet: its pinned one stands in.
        guard let url = address(of: tab), Library.shared.isFavorite(favoriteID),
              Self.canSplit(splitSide(of: tab), onto: splitSide(ofBookmark: favoriteID)) else { return }
        let mark: Bookmark
        if let id = tab.bookmarkID, let pinned = Library.shared.detachBookmark(id) {
            mark = pinned
        } else {
            removeFromList(tab)
            mark = Bookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url))
            tab.bookmarkID = mark.id
            bookmarkTabs[mark.id] = tab
        }
        tab.isFavorite = true
        Library.shared.joinFavorite(mark, onto: favoriteID, onRight: onRight)
        openBookmark(mark)
    }

    /// A split view as one favorite. Pinned halves keep their ids (and so their pages); a tab becomes one. False
    /// when it can't (a page with no address yet).
    private func favoriteSplit(_ pair: SplitPair, at index: Int?) -> Bool {
        guard let left = tab(with: pair.left) ?? bookmarkTabs.values.first(where: { $0.id == pair.left }),
              let right = tab(with: pair.right) ?? bookmarkTabs.values.first(where: { $0.id == pair.right }),
              address(of: left) != nil, address(of: right) != nil else { return false }
        // Already a pinned split: it moves up as it is.
        if let l = left.bookmarkID, let r = right.bookmarkID, Library.shared.pinnedSplit(containing: l)?.contains(r) == true {
            if Library.shared.isFavorite(l) {
                if let index { Library.shared.moveFavorite(l, to: index) }
            } else {
                Library.shared.makeFavorite(l, at: index, in: profile.id)
            }
            left.isFavorite = true
            right.isFavorite = true
            return true
        }
        var marks: [Bookmark] = []
        for half in [left, right] {
            let url = address(of: half)!
            if let id = half.bookmarkID, let mark = Library.shared.detachBookmark(id) ?? Library.shared.bookmark(id) {
                marks.append(mark)
            } else {
                removeFromList(half)
                let mark = Bookmark(url: url, title: Self.bookmarkTitle(half.displayTitle, url: url))
                half.bookmarkID = mark.id
                bookmarkTabs[mark.id] = half
                marks.append(mark)
            }
            half.isFavorite = true
        }
        Library.shared.addFavoriteSplit(marks[0], marks[1], at: index, ratio: pair.ratio, vertical: pair.vertical, in: profile.id)
        changed.send(.structure)
        return true
    }

    // MARK: Spaces

    func switchToSpace(_ id: UUID) {
        // A private window keeps to one space: a swipe or ⌃1 there would leave its tabs out of sight.
        guard !isPrivate, id != currentSpaceID, Library.shared.space(id) != nil else { return }
        // Making a space switches to it on its own; going somewhere after that is the guide's last step.
        if !isPrivate, Tutorial.done.contains("space") { Tutorial.complete("switch") }
        let left = selectedTab
        left?.captureSnapshot()
        left?.markActivated()
        currentSpaceID = id
        changed.send(.space)
        Brand.themeChanged.send(())
        // Where you were on the page you left, as selecting another tab notes it, in case it has to load again while
        // you're away (a favorite you left this way stays open behind the other space).
        if left !== selectedTab { left?.readPageState() }
        if let tab = selectedTab {
            tab.markActivated()
            promote(tab)
            tab.ensureWebView()
            if tab !== left { tab.shown() }
        }
        changed.send(.selection)
    }

    /// What Clear closes in a space and why. `unused`: the tabs you've drifted away from, keeping the ones you're
    /// working with now; once there are none, `others`: every tab but the one you're on (and the page beside it in a
    /// split); once those are all that's left, `last`: them too, leaving the space empty. Never a tab playing sound
    /// or in a call.
    enum ClearKind { case unused, others, last }

    func tabsToClear(in spaceID: UUID, now: Date = Date()) -> (tabs: [Tab], kind: ClearKind) {
        let tabs = self.tabs(in: spaceID)
        let current = selectedTab(in: spaceID)
        let partner = current.flatMap { self.partner(of: $0) }
        let busy = Set(tabs.filter { $0.isPlayingAudio || $0.isInUse }.map(\.id))
        let ages = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, now.timeIntervalSince($0.lastActivated)) })
        let (ids, kind) = Self.clearing(tabs.map(\.id), current: current?.id, partner: partner?.id, busy: busy, ages: ages)
        return (tabs.filter { ids.contains($0.id) }, kind)
    }

    /// Clear's choice, by id. While other tabs are left, even only busy ones, yours stay.
    nonisolated static func clearing(_ tabs: [UUID], current: UUID?, partner: UUID?, busy: Set<UUID>,
                                     ages: [UUID: TimeInterval]) -> (ids: Set<UUID>, kind: ClearKind) {
        let others = tabs.filter { $0 != current && $0 != partner }
        guard !others.isEmpty else { return (Set(tabs.filter { !busy.contains($0) }), .last) }
        let closable = others.filter { !busy.contains($0) }
        let newestFirst = closable.sorted { ages[$0, default: 0] < ages[$1, default: 0] }
        let kept = keptByActivity(newestFirst.map { ages[$0, default: 0] })
        let unused = Set(newestFirst.dropFirst(kept))
        return unused.isEmpty ? (Set(closable), .others) : (unused, .unused)
    }

    /// How many tabs to keep as the ones you're working with now, given how long ago each was last looked at (or
    /// opened, for one never looked at), newest first. People work in bursts: the tabs of what you're doing now were
    /// all seen within a short while of each other, and the rest much longer ago. That break shows as the biggest
    /// jump in age from one tab to the next, measured as a ratio, so 15 minutes against 45 counts as much as 1 hour
    /// against 3. What counts as "a short while" follows your own pace rather than a fixed time: ages closer together
    /// than an eighth of the span looked at count as equal, so after hours away a few minutes between tabs is never a
    /// break, while in a quick session a few minutes can be. The break is looked for among the newest dozen, since no
    /// one works with more at once; a jump of less than 3 times is just steady browsing, with no break, and then the
    /// newest five stay.
    nonisolated static func keptByActivity(_ ages: [TimeInterval]) -> Int {
        let clearJump = 3.0, mostAtOnce = 12, keptWithoutBreak = 5
        guard let span = ages.prefix(mostAtOnce + 1).last else { return 0 }
        let floor = max(2 * 60, span / 8)
        let a = ages.map { max($0, floor) }
        var best = (ratio: clearJump, kept: -1)
        for i in 0..<min(mostAtOnce, max(a.count - 1, 0)) {
            let ratio = a[i + 1] / a[i]
            // The bigger jump wins; between equal ones, the later, keeping more.
            if ratio >= best.ratio { best = (ratio, i + 1) }
        }
        return best.kept >= 0 ? best.kept : min(keptWithoutBreak, a.count)
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
        guard !isPrivate, id != currentSpaceID, Library.shared.space(id) != nil else { return }
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
            tabs.forEach { $0.close(); forget($0) }
            tabsBySpace[id] = nil
        }
        // A removed bookmark keeps its page around as a normal tab, so nothing disappears unexpectedly.
        let bookmarkIDs = Library.shared.allBookmarkIDs
        for (id, tab) in bookmarkTabs where !bookmarkIDs.contains(id) {
            bookmarkTabs[id] = nil
            tab.bookmarkID = nil
            tab.parentID = nil
            if spaceIDs.contains(tab.spaceID) {
                if tabsBySpace[tab.spaceID]?.contains(where: { $0 === tab }) != true { tabsBySpace[tab.spaceID, default: []].insert(tab, at: 0) }
            } else {
                tab.close()
                forget(tab)
            }
        }
        // Bookmarks moved to another space carry their live tab; one that became, or stopped being, a favorite
        // (undo, another window) says so.
        for (id, tab) in bookmarkTabs {
            if let space = Library.shared.spaceID(ofBookmark: id) { tab.setSpace(space) }
            tab.isFavorite = Library.shared.isFavorite(id)
        }
        // Pinned pages stop being a pinned split (separated, one made a favorite, undo, another window): the split on
        // screen ends with it.
        let splitCount = splits.count
        splits.removeAll { pair in
            guard let left = tab(with: pair.left), let right = tab(with: pair.right) else { return false }
            return !canSplit(left, with: right) || left.spaceID != right.spaceID
        }
        if !spaceIDs.contains(currentSpaceID) {
            currentSpaceID = Library.shared.spaces[0].id
            changed.send(.space)
            changed.send(.selection)
        }
        // A space put on another profile takes its open pages there. Not a favorite that was open in it: that
        // stays its own profile's, in another of that profile's spaces, and the space shows a page of its own.
        var reselected = false
        for tab in bookmarkTabs.values where tab.isFavorite && Profiles.shared.profile(forSpace: tab.spaceID) !== tab.homeProfile {
            for (space, id) in selectedBySpace where id == tab.id && Profiles.shared.profile(forSpace: space) !== tab.homeProfile {
                selectedBySpace[space] = tabs(in: space).first?.id
                reselected = reselected || space == currentSpaceID
            }
            if let space = space(for: tab.homeProfile) { tab.setSpace(space) }
        }
        for tab in allTabs { tab.settleProfile() }
        if reselected { changed.send(.selection) }
        changed.send(.structure)
        if splits.count != splitCount { changed.send(.selection) }
    }

    // MARK: Bookmarks

    /// Opens the bookmark's live tab, creating it on first use. Half of a pinned split opens with its other half,
    /// side by side again.
    func openBookmark(_ bookmark: Bookmark) {
        let tab = liveTab(for: bookmark)
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
                half.setSpace(space)
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
        tab.setSpace(space)
        bookmarkTabs[bookmarkID] = tab
        Library.shared.addBookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), to: space, at: index, id: bookmarkID)
    }

    /// A tab dropped on a pinned page: it's pinned beside it as a pinned split, where the page is and in its folder.
    /// The page keeps its pin as it is, and the two open side by side.
    func pinSplit(_ tab: Tab, with bookmarkID: UUID, tabOnRight: Bool) {
        guard let url = tab.url, let space = Library.shared.spaceID(ofBookmark: bookmarkID),
              Self.canSplit(splitSide(of: tab), onto: splitSide(ofBookmark: bookmarkID)) else { return }
        let mark = Bookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url))
        removeFromList(tab)
        tab.bookmarkID = mark.id
        tab.setSpace(space)
        bookmarkTabs[mark.id] = tab
        Library.shared.pinBeside(mark, bookmarkID, onRight: tabOnRight)
        openBookmark(mark)
    }

    /// A pinned page dropped on another in the same space: the two become one pinned split where the other is, in its
    /// folder, and open side by side.
    func joinPinned(_ bookmarkID: UUID, onto targetID: UUID, onRight: Bool) {
        guard let space = Library.shared.spaceID(ofBookmark: targetID), Library.shared.spaceID(ofBookmark: bookmarkID) == space,
              Self.canSplit(splitSide(ofBookmark: bookmarkID), onto: splitSide(ofBookmark: targetID)) else { return }
        Library.shared.joinPinned(bookmarkID, beside: targetID, onRight: onRight)
        if let page = Library.shared.bookmark(bookmarkID) { openBookmark(page) }
    }

    /// Turns a bookmark's live tab back into a normal tab, removing the bookmark. Returns the tab now in the list:
    /// the live one, or, for an unloaded bookmark dropped at an index, a new one. `spaceID`: where a favorite goes
    /// (nil: the space you're in); a pinned page stays in its own.
    /// `parent`: the tab it goes under, where that keeps the groups whole (a drop among nested tabs).
    @discardableResult
    func unbookmark(_ bookmarkID: UUID, toIndex index: Int? = nil, in spaceID: UUID? = nil, under parent: UUID? = nil) -> Tab? {
        let isFavorite = Library.shared.isFavorite(bookmarkID)
        let space = (isFavorite ? spaceID : nil) ?? Library.shared.spaceID(ofBookmark: bookmarkID) ?? currentSpaceID
        if let pinned = Library.shared.pinnedSplit(containing: bookmarkID) { return unpin(pinned, returning: bookmarkID, toIndex: index, in: space) }
        if isFavorite {
            bookmarkTabs[bookmarkID]?.setSpace(space)
            bookmarkTabs[bookmarkID]?.isFavorite = false
        }
        var result: Tab?
        if let tab = bookmarkTabs[bookmarkID] {
            bookmarkTabs[bookmarkID] = nil
            tab.bookmarkID = nil
            let at = min(index ?? 0, tabsBySpace[tab.spaceID]?.count ?? 0)
            tab.parentID = TabTree.parent(at: at, preferring: parent, in: treeNodes(in: tab.spaceID))
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
            result = tab
        } else if let bookmark = Library.shared.bookmark(bookmarkID), let index {
            let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
            tab.host = host
            watch(tab)
            let at = min(index, tabsBySpace[tab.spaceID]?.count ?? 0)
            tab.parentID = TabTree.parent(at: at, preferring: parent, in: treeNodes(in: tab.spaceID))
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
            result = tab
        }
        Library.shared.removeBookmark(bookmarkID)
        return result
    }

    /// Either half of a pinned split unpins the pair, back to two tabs in split view. Open pages come along as they
    /// are; one that isn't open opens fresh beside the other.
    private func unpin(_ pinned: PinnedSplit, returning bookmarkID: UUID, toIndex index: Int?, in space: UUID) -> Tab? {
        let anyOpen = bookmarkTabs[pinned.left] != nil || bookmarkTabs[pinned.right] != nil
        var halves: [(id: UUID, tab: Tab)] = []
        for id in [pinned.left, pinned.right] {
            if let tab = bookmarkTabs[id] {
                bookmarkTabs[id] = nil
                tab.bookmarkID = nil
                // A split favorite comes back as tabs in the space you're in.
                tab.isFavorite = false
                tab.setSpace(space)
                halves.append((id, tab))
            } else if anyOpen || index != nil, let bookmark = Library.shared.bookmark(id) {
                let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
                tab.host = host
                watch(tab)
                halves.append((id, tab))
            }
        }
        let at = min(index ?? 0, tabsBySpace[space]?.count ?? 0)
        let parent = TabTree.parentForInsertion(at: at, in: treeNodes(in: space))
        halves.forEach { $0.tab.parentID = parent }
        tabsBySpace[space, default: []].insert(contentsOf: halves.map(\.tab), at: at)
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
        tab.setSpace(currentSpaceID)
        tab.parentID = nil
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

    /// A site's home page is named for the site ("Inbox (3) - Gmail" is kept as "Gmail"): the page title there says
    /// little. Any other page keeps the title its tab showed, which says which page it is ("ZigaoWang/zigzag: A browser
    /// - GitHub" stays, never just "GitHub").
    static func bookmarkTitle(_ title: String, url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty, url.query == nil else { return title }
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
        // Opened from half of a split, it took that pane: the page it came from goes back in, as Back does.
        if selectedTab === tab, let opener = tab.opener, !opener.isClosed, self.tab(with: opener.id) === opener {
            returnPane(of: tab, to: opener)
        }
        let partnerTab = partner(of: tab)
        let pair = split(for: tab)
        splits.removeAll { $0.left == tab.id || $0.right == tab.id }
        // Closing one half of a split shows the other half.
        if selectedTab === tab, let partnerTab {
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
            closeKeepingSelection(tab, split: pair)
            select(partnerTab)
            return
        }
        let wasSelected = selectedTab === tab
        // The half of a split that wasn't focused: the pane it was in goes too, though the selection stays.
        defer { if pair != nil, !wasSelected { changed.send(.selection) } }
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        if let bookmarkID = tab.bookmarkID {
            // Closing a pinned page closes it, wherever it had got to: one ⌘W, never two. The pin stays, and
            // opens fresh at its own address next time.
            bookmarkTabs[bookmarkID] = nil
            recentTabIDs.removeAll { $0 == tab.id }
            tabTokens[tab.id] = nil
            tab.close()
            changed.send(.structure)
            if wasSelected { selectAfterClosing(tab, index: 0) }
            return
        }
        guard var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) else { return }
        closedTabs.append(closedRecord(of: tab, at: index, split: pair))
        if closedTabs.count > closedLimit { closedTabs.removeFirst(closedTabs.count - closedLimit) }
        // The tabs under it move up a level rather than close with it.
        liftChildren(of: tab)
        list.remove(at: index)
        tabsBySpace[tab.spaceID] = list
        recentTabIDs.removeAll { $0 == tab.id }
        tabTokens[tab.id] = nil
        tab.close()
        changed.send(.structure)
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    /// Removes a tab without choosing a new selection (the caller does).
    private func closeKeepingSelection(_ tab: Tab, split pair: SplitPair? = nil) {
        if let bookmarkID = tab.bookmarkID {
            bookmarkTabs[bookmarkID] = nil
        } else if var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) {
            closedTabs.append(closedRecord(of: tab, at: index, split: pair))
            liftChildren(of: tab)
            list.remove(at: index)
            tabsBySpace[tab.spaceID] = list
        }
        recentTabIDs.removeAll { $0 == tab.id }
        tabTokens[tab.id] = nil
        tab.close()
        changed.send(.structure)
    }

    private func closedRecord(of tab: Tab, at index: Int, split pair: SplitPair?) -> ClosedTab {
        ClosedTab(id: tab.id, url: tab.url, title: tab.displayTitle, spaceID: tab.spaceID, index: index,
                  interactionState: tab.interactionStateForSaving, customTitle: tab.customTitle, split: pair, lastActivated: tab.lastActivated,
                  parentID: tab.parentID, childIDs: tabs(in: tab.spaceID).filter { $0.parentID == tab.id }.map(\.id))
    }

    /// Returns the ordinary tabs' ids in the order they closed: reopening in reverse puts each back where it was.
    @discardableResult
    func close(_ tabs: [Tab]) -> [UUID] {
        let selected = selectedTab
        let closingSelected = tabs.contains { $0 === selected }
        let order = tabs.filter { $0 !== selected } + (closingSelected ? [selected].compactMap { $0 } : [])
        let ids = order.filter { $0.bookmarkID == nil }.map(\.id)
        closedLimit = max(closedLimit, ids.count + 50)
        together { order.forEach { close($0) } }
        return ids
    }

    /// Set while many tabs open or close at once: the window redraws once, at the end, not once for each.
    private(set) var isBatching = false

    func together(_ body: () -> Void) {
        if isBatching { body(); return }
        isBatching = true
        body()
        isBatching = false
        changed.send(.structure)
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

    /// Where you land after closing the tab you were on: the page it was opened from, else the tab you were on before
    /// it in this space (as a browser's Back would), else its neighbor in the list.
    private func selectAfterClosing(_ closed: Tab, index: Int) {
        let list = tabs(in: closed.spaceID)
        if let opener = closed.opener, list.contains(where: { $0 === opener }) {
            select(opener)
        } else if !leavesSpaceEmpty, let previous = recentTabs.first(where: { $0 !== closed && $0.spaceID == closed.spaceID && !$0.isClosed }) {
            select(previous)
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
        let tab = Tab(url: closed.url, title: closed.title, spaceID: space, interactionState: closed.interactionState,
                      lastActivated: closed.lastActivated)
        tab.customTitle = closed.customTitle
        tab.host = host
        watch(tab)
        let at = min(closed.index, tabs(in: space).count)
        // The tabs that were under it and moved up a level when it closed go back under it, if they still follow it.
        // Its parent and those tabs may have closed and come back too (closing many at once, then ⌘Z): they're found
        // by the ids they have now.
        let nodes = TabTree.reinserting(tab.id, at: at, parent: space == closed.spaceID ? closed.parentID.map(reopenedID) : nil,
                                        children: Set(closed.childIDs.map(reopenedID)), in: treeNodes(in: space))
        tabsBySpace[space, default: []].insert(tab, at: at)
        applyTree(nodes, in: space)
        // A reopened tab is a new tab: its partner, closed with it and back first, is found by the id it had.
        reopenedAs[closed.id] = tab.id
        if reopenedAs.count > 500 { reopenedAs = [closed.id: tab.id] }
        // Half of a split: back beside its partner, on the same side and at the same size, if that's still free.
        let otherID = closed.split.map { $0.left == closed.id ? $0.right : $0.left }
        if let pair = closed.split, let otherID, let other = self.tab(with: reopenedAs[otherID] ?? otherID),
           other.spaceID == space, split(for: other) == nil, canSplit(tab, with: other) {
            var restored = pair
            let onLeft = pair.left == closed.id
            restored.left = onLeft ? tab.id : other.id
            restored.right = onLeft ? other.id : tab.id
            splits.append(restored)
        }
        changed.send(.structure)
        if select { self.select(tab) } else { recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count)) }
        return tab
    }

    // MARK: Moving

    /// The id a closed tab has now: itself, or the tab it reopened as (and so on, if that one closed and came back).
    private func reopenedID(_ id: UUID) -> UUID {
        var id = id
        var seen: Set<UUID> = [id]
        while let next = reopenedAs[id], seen.insert(next).inserted { id = next }
        return id
    }

    /// Takes a tab out of its list (pinned, made a favorite, moved away): the tabs under it move up a level.
    private func removeFromList(_ tab: Tab) {
        liftChildren(of: tab)
        tabsBySpace[tab.spaceID]?.removeAll { $0 === tab }
    }

    /// What a move does with a tab's level: `fit` keeps it at its level if it can, else it joins the group it lands
    /// in; `under` puts it under that tab (nil: the top level), as a drop between nested rows says.
    enum Nesting: Equatable {
        case fit
        case under(UUID?)
    }

    /// Within its list, a tab moves with every tab nested under it. `index` counts the list without the tab alone,
    /// as before nesting; a place among its own nested tabs lands just after them. Into another space it goes on its
    /// own, and the tabs under it stay behind, a level up.
    func move(_ tab: Tab, to index: Int, in spaceID: UUID? = nil, nesting: Nesting = .fit) {
        guard tab.bookmarkID == nil else { return }
        let target = spaceID ?? tab.spaceID
        // A split of two tabs goes to another space as one, still side by side.
        if target != tab.spaceID, let pair = split(for: tab), let other = partner(of: tab), other.bookmarkID == nil {
            let halves = pair.left == tab.id ? [tab, other] : [other, tab]
            halves.forEach { removeFromList($0) }
            for half in halves {
                half.setSpace(target)
                for (space, id) in selectedBySpace where id == half.id && space != target { selectedBySpace[space] = nil }
            }
            var list = tabsBySpace[target] ?? []
            let at = max(0, min(index, list.count))
            let parent = TabTree.parentForInsertion(at: at, in: treeNodes(in: target))
            halves.forEach { $0.parentID = parent }
            list.insert(contentsOf: halves, at: at)
            tabsBySpace[target] = list
            changed.send(.structure)
            return
        }
        if target != tab.spaceID {
            // A split with a pinned page can't span two spaces: moving the tab out ends it.
            splits.removeAll { $0.left == tab.id || $0.right == tab.id }
            removeFromList(tab)
            tab.setSpace(target)
            var list = tabsBySpace[target] ?? []
            let at = max(0, min(index, list.count))
            tab.parentID = TabTree.parentForInsertion(at: at, in: treeNodes(in: target))
            list.insert(tab, at: at)
            tabsBySpace[target] = list
        } else {
            let nodes = treeNodes(in: target)
            let at = TabTree.indexWithoutRun(index, moving: tab.id, in: nodes)
            let parent: UUID? = switch nesting {
            case .fit: tab.parentID
            case .under(let id): id
            }
            applyTree(TabTree.moving(tab.id, to: at, parent: parent, in: nodes), in: target)
            if case .under = nesting { unfold(tab.parentID) }
        }
        // No other space keeps it selected, whichever one is showing.
        for (space, id) in selectedBySpace where id == tab.id && space != target { selectedBySpace[space] = nil }
        changed.send(.structure)
    }

    /// Into another space: at `index` where it was dropped, else at the top.
    func moveTabToSpace(_ tab: Tab, spaceID: UUID, at index: Int = 0) {
        // Either half of a split moving together counts: the page you were on leaves with it.
        let wasSelected = selectedTab === tab || (partner(of: tab).map { selectedTab === $0 } ?? false)
        let oldIndex = tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        move(tab, to: index, in: spaceID)
        if wasSelected { selectAfterClosing(Tab(url: nil, spaceID: currentSpaceID), index: oldIndex) }
    }

    // MARK: Duplicates

    static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased() == "http" ? "https" : components.scheme?.lowercased()
        if let host = components.host?.lowercased() { components.host = host.withoutWWW }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? url.absoluteString
    }

    /// An open tab (or live bookmark) already showing this address in the profile you're in, preferring the
    /// current space. The same address open in another profile is another page: other sign-ins, other extensions.
    func existingTab(for url: URL) -> Tab? {
        let key = Self.normalize(url)
        let candidates = navigableTabs + allTabs
        return candidates.first { tab in tab.url.map(Self.normalize) == key && (isPrivate || tab.homeProfile === profile) }
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

    /// Ordinary tabs split, the two pinned pages of a pinned split, and a pinned page with a tab: the tab's row
    /// carries that pair. A favorite belongs to every space, and two pinned pages to rows of their own, so neither
    /// has one row to carry it.
    func canSplit(_ tab: Tab, with other: Tab) -> Bool {
        guard tab !== other else { return false }
        switch (tab.bookmarkID, other.bookmarkID) {
        case (nil, nil): return true
        case let (a?, b?): return Library.shared.pinnedSplit(containing: a)?.contains(b) == true
        case let (pinned?, nil), let (nil, pinned?):
            return !Library.shared.isFavorite(pinned) && Library.shared.pinnedSplit(containing: pinned) == nil
        }
    }

    /// One side of a drop that would open two pages side by side: a row in the list or a tile in the grid.
    struct SplitSide {
        enum Kind { case tab, pinned, favorite }
        var kind: Kind
        /// Already half of a split (of tabs, of pinned pages, or a split favorite): it moves as one, never split again.
        var inSplit: Bool
        /// A tab still on its new-tab page has nothing to show beside another.
        var hasPage = true
    }

    /// The one rule for dropping a page on another's middle: two tabs, a tab and a pinned page (the pair takes the
    /// kind of the one dropped on), or anything with a page onto a favorite. Never half of a split, either side.
    nonisolated static func canSplit(_ carried: SplitSide, onto target: SplitSide) -> Bool {
        guard !carried.inSplit, !target.inSplit, carried.hasPage, target.hasPage else { return false }
        switch (carried.kind, target.kind) {
        case (.tab, .tab), (.tab, .pinned), (.pinned, .tab), (.pinned, .pinned), (_, .favorite): return true
        case (.favorite, _): return false
        }
    }

    func splitSide(of tab: Tab) -> SplitSide {
        if let id = tab.bookmarkID { return splitSide(ofBookmark: id) }
        return SplitSide(kind: .tab, inSplit: split(for: tab) != nil, hasPage: tab.url != nil)
    }

    func splitSide(ofBookmark id: UUID) -> SplitSide {
        let open = bookmarkTabs[id].map { split(for: $0) != nil } ?? false
        return SplitSide(kind: Library.shared.isFavorite(id) ? .favorite : .pinned,
                         inSplit: open || Library.shared.pinnedSplit(containing: id) != nil)
    }

    /// Puts `other` beside `tab` (on the right or left), ending any splits either was in.
    func makeSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool = true) {
        // A pinned page stays in its space; only a tab moves to join the other.
        guard canSplit(tab, with: other), other.spaceID == tab.spaceID || other.bookmarkID == nil else { return }
        unsplit(tab, notify: false)
        unsplit(other, notify: false)
        if other.spaceID != tab.spaceID {
            removeFromList(other)
            other.setSpace(tab.spaceID)
            tabsBySpace[tab.spaceID, default: []].insert(other, at: 0)
        }
        // A split is one row at the top level: tabs nested under either half move up a level, where they are, as
        // they do when their page is pinned or leaves for another space.
        liftToTopLevel(tab)
        liftToTopLevel(other)
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

    // MARK: Undo

    /// Where every tab of the window is: each space's list, which pinned page or favorite each live page belongs to,
    /// and which pages are side by side. ⌘Z puts it back exactly, with the library.
    struct Arrangement {
        fileprivate var lists: [UUID: [UUID]]
        fileprivate var pinned: [UUID: UUID]
        fileprivate var pairs: [[UUID]]
        fileprivate var splits: [SplitPair]
        fileprivate var tabs: [UUID: Tab]
        fileprivate var spaces: [UUID: UUID]
        fileprivate var selected: [UUID: UUID]
        /// Which tab each nested tab is under.
        fileprivate var parents: [UUID: UUID] = [:]

        /// The same tabs in the same places, whatever else opened since; selection and split sizes don't count.
        fileprivate func matches(_ now: Arrangement) -> Bool {
            let ids = Set(tabs.keys)
            return lists.filter { !$0.value.isEmpty } == now.lists.mapValues { $0.filter(ids.contains) }.filter { !$0.value.isEmpty }
                && pinned == now.pinned.filter { ids.contains($0.value) }
                && pairs == now.pairs.filter { $0.allSatisfy(ids.contains) }
                && parents == now.parents.filter { ids.contains($0.key) }
                && now.tabs.keys.filter(ids.contains).count == ids.count
        }

        /// The same tabs, in the same places.
        func isSame(as other: Arrangement) -> Bool { matches(other) && other.matches(self) }
    }

    var arrangement: Arrangement {
        let tabs = allTabs
        return Arrangement(lists: tabsBySpace.mapValues { $0.map(\.id) }, pinned: bookmarkTabs.mapValues(\.id),
                           pairs: splits.map { [$0.left, $0.right] }, splits: splits,
                           tabs: Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                           spaces: Dictionary(tabs.map { ($0.id, $0.spaceID) }, uniquingKeysWith: { a, _ in a }), selected: selectedBySpace,
                           parents: Dictionary(tabs.compactMap { tab in tab.parentID.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a }))
    }

    /// Whether the tabs `done` placed are still where it left them.
    func isUnchanged(since done: Arrangement) -> Bool { done.matches(arrangement) }

    /// Puts the tabs back as `target` had them, undoing `done`: tabs `done` made are closed, ones opened since stay.
    func restore(_ target: Arrangement, undoing done: Arrangement) {
        let now = arrangement
        for (id, tab) in now.tabs where target.tabs[id] == nil && done.tabs[id] != nil {
            tab.close()
            tabTokens[id] = nil
            recentTabIDs.removeAll { $0 == id }
        }
        let since = now.tabs.filter { target.tabs[$0.key] == nil && done.tabs[$0.key] == nil }
        let alive = target.tabs.filter { now.tabs[$0.key] != nil }
        var lists = target.lists.mapValues { $0.compactMap { alive[$0] } }
        for (space, ids) in now.lists {
            for (i, id) in ids.enumerated() { if let tab = since[id] { lists[space, default: []].insert(tab, at: min(i, lists[space]?.count ?? 0)) } }
        }
        tabsBySpace = lists
        bookmarkTabs = target.pinned.compactMapValues { alive[$0] }
        for (bookmark, id) in now.pinned { if let tab = since[id], bookmarkTabs[bookmark] == nil { bookmarkTabs[bookmark] = tab } }
        for (id, tab) in alive {
            tab.setSpace(target.spaces[id] ?? tab.spaceID)
            tab.bookmarkID = target.pinned.first { $0.value == id }?.key
            tab.isFavorite = tab.bookmarkID.map(Library.shared.isFavorite) ?? false
            tab.parentID = tab.bookmarkID == nil ? target.parents[id] : nil
        }
        for space in Array(tabsBySpace.keys) { repairTree(in: space) }
        splits = target.splits.filter { alive[$0.left] != nil && alive[$0.right] != nil }
            + now.splits.filter { since[$0.left] != nil || since[$0.right] != nil }
        for (space, id) in target.selected where alive[id] != nil { selectedBySpace[space] = id }
        selectedBySpace = selectedBySpace.filter { tab(with: $0.value) != nil }
        changed.send(.structure)
        changed.send(.selection)
    }

    // MARK: Nesting

    /// A space's tabs as the tree sees them: ids and parents, in list order.
    func treeNodes(in spaceID: UUID) -> [TabTree.Node] {
        tabs(in: spaceID).map { TabTree.Node(id: $0.id, parent: $0.parentID) }
    }

    /// Puts a space's list in the tree's order, each tab under the parent the tree gives it.
    private func applyTree(_ nodes: [TabTree.Node], in spaceID: UUID) {
        let byID = Dictionary(tabs(in: spaceID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tabsBySpace[spaceID] = nodes.compactMap { node in
            let tab = byID[node.id]
            tab?.parentID = node.parent
            return tab
        }
    }

    private func repairTree(in spaceID: UUID) {
        applyTree(TabTree.repaired(treeNodes(in: spaceID)), in: spaceID)
    }

    /// A tab about to leave its list: the tabs right under it move up a level, under its own parent, where they are.
    private func liftChildren(of tab: Tab) {
        if tab.bookmarkID == nil {
            for child in tabs(in: tab.spaceID) where child.parentID == tab.id { child.parentID = tab.parentID }
        }
        tab.parentID = nil
    }

    /// Half of a split: one row of its own at the top level. See `TabTree.liftingToTopLevel`.
    private func liftToTopLevel(_ tab: Tab) {
        guard tab.bookmarkID == nil else { tab.parentID = nil; return }
        applyTree(TabTree.liftingToTopLevel(tab.id, in: treeNodes(in: tab.spaceID)), in: tab.spaceID)
    }

    /// A tab put under a folded one shows: unfolded, so a link opened under it doesn't vanish into the fold.
    private func unfold(_ parent: UUID?) {
        guard let parent, let tab = tab(with: parent), tab.isCollapsed else { return }
        tab.isCollapsed = false
    }

    func hasNestedTabs(_ tab: Tab) -> Bool { tab.bookmarkID == nil && tabs(in: tab.spaceID).contains { $0.parentID == tab.id } }

    /// Every tab nested under this one, at any depth, in list order.
    func nestedTabs(under tab: Tab) -> [Tab] {
        let ids = Set(TabTree.descendants(of: tab.id, in: treeNodes(in: tab.spaceID)))
        return tabs(in: tab.spaceID).filter { ids.contains($0.id) }
    }

    /// Folds the tabs under this one away in the sidebar, or shows them again.
    func setNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) {
        guard tab.isCollapsed != collapsed else { return }
        tab.isCollapsed = collapsed
        changed.send(.structure)
    }

    /// Move Tab Up and Down: past the tab beside it at its level, both with the tabs under them. The index counts the
    /// list without the tab alone, as `move` takes it; nil at either end of its group.
    func siblingMoveTarget(_ tab: Tab, by offset: Int) -> Int? {
        guard tab.bookmarkID == nil else { return nil }
        let nodes = treeNodes(in: tab.spaceID)
        guard let target = TabTree.siblingMoveTarget(tab.id, by: offset, in: nodes),
              let start = nodes.firstIndex(where: { $0.id == tab.id }) else { return nil }
        // `target` counts the list without the whole run: as a place in the list without the tab alone, the tabs under
        // it that come before that place count too.
        let rest = nodes.filter { $0.id != tab.id }
        let runCount = TabTree.subtreeEnd(at: start, in: nodes) - start - 1
        return target <= start ? target : min(target + runCount, rest.count)
    }

    // MARK: Suspension

    /// Background tabs nobody has looked at in a while give their memory back (TabSleep says when): every minute,
    /// and at once when macOS says memory is short.
    func sleepIdleTabs() {
        // Kept awake: what's on screen (both halves of a split), anything in a call or floating, and sites that notify.
        // Favorites and sites kept awake too, unless memory is critically short (TabSleep). Other spaces' pages sleep
        // like any tab once idle; their snapshots still show while you swipe to them.
        var selectedIDs = Set([selectedTab?.id].compactMap { $0 })
        for id in Array(selectedIDs) { if let tab = tab(with: id), let other = partner(of: tab) { selectedIDs.insert(other.id) } }
        let live = allTabs.filter { !$0.isSuspended }
        let now = Date()
        let memory = MemoryPressure.shared.level
        let candidates = live.map {
            TabSleep.Candidate(id: $0.id, unseen: now.timeIntervalSince($0.lastActivated),
                               mustStay: selectedIDs.contains($0.id) || $0.isPlayingAudio || $0.isInUse || $0.notifiesUser,
                               hasTypedText: $0.pageState?.hasTypedText == true, isFavorite: $0.isFavorite,
                               keptAwake: KeepAwake.isOn(for: $0.url))
        }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in TabSleep.sleepers(candidates, awake: live.count, memory: memory) {
            guard let tab = byID[id] else { continue }
            let unseen = now.timeIntervalSince(tab.lastActivated)
            // A favorite or a site kept awake sleeps only for memory, however long unseen.
            let shielded = tab.isFavorite || KeepAwake.isOn(for: tab.url)
            let reason = unseen > TabSleep.idle && !shielded ? "unseen for an hour"
                : memory != .normal ? "Mac low on memory" : "more than \(TabSleep.crowd) tabs awake"
            // A few at a time; one you've gone back to meanwhile stays awake.
            TabSleep.queue.add(tab.id) { [weak tab] in
                guard let tab, Self.mayStillSleep(tab) else { return }
                tab.suspend(because: reason)
            }
        }
        // Each space keeps the page it shows out of the archive, as before.
        archiveStaleTabs(keeping: selectedIDs.union(selectedBySpace.values))
    }

    /// Whether a tab on its way to sleep (TabSleep.queue) still may: it's open and awake, and no window has come to
    /// show it, alone or beside another in a split, since it was chosen.
    static func mayStillSleep(_ tab: Tab) -> Bool {
        guard !tab.isClosed, !tab.isSuspended else { return false }
        return !WindowManager.shared.controllers.contains { controller in
            guard let selected = controller.tabManager.selectedTab else { return false }
            return selected === tab || controller.tabManager.partner(of: selected) === tab
        }
    }

    /// Ordinary tabs unseen for longer than the setting move to the archive. Never pinned pages or favorites,
    /// what's on screen, a split, anything playing or in a call, a site that sends notifications, one with something you
    /// typed still in it, or a private window's tabs.
    private func archiveStaleTabs(keeping onScreen: Set<UUID>) {
        if !isPrivate { TabArchive.offerIfCrowded(tabCount: tabsBySpace.values.map(\.count).max() ?? 0) }
        guard !isPrivate, let limit = TabArchive.after.interval else { return }
        let now = Date()
        let stale = tabsBySpace.values.flatMap { $0 }.filter {
            $0.bookmarkID == nil && !onScreen.contains($0.id) && partner(of: $0) == nil && !$0.isPlayingAudio && !$0.isInUse && !$0.notifiesUser
                && $0.pageState?.hasTypedText != true && now.timeIntervalSince($0.lastActivated) > limit && $0.url != nil
        }
        guard !stale.isEmpty else { return }
        var archived: [ArchivedTab] = []
        defer { TabArchive.shared.add(contentsOf: archived) }
        for tab in stale {
            guard let url = tab.url, var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) else { continue }
            archived.append(ArchivedTab(url: url, title: tab.displayTitle, spaceID: tab.spaceID, archivedAt: now))
            liftChildren(of: tab)
            list.remove(at: index)
            tabsBySpace[tab.spaceID] = list
            recentTabIDs.removeAll { $0 == tab.id }
            tabTokens[tab.id] = nil
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
            tab.close()
        }
        changed.send(.structure)
    }
}
