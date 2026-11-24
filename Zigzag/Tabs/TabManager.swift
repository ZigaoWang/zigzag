import AppKit
import WebKit

/// One window's tabs by space. The tabs belong to its `TabStore`: the window's own, or shared by every everyday window
/// when Settings › Tabs shares them (#162). Current space, selection per space and MRU order are per window. Views read
/// from it; they never own web views.
final class TabManager {
    enum Change {
        /// Tabs added, removed or moved, or bookmarks changed.
        case structure
        case selection
        case space
        /// A tab navigated or changed title: nothing to redraw here, but worth saving.
        case content
    }

    /// Its own tabs, or every everyday window's while shared (#162).
    private(set) var store: TabStore
    // Any change resets the cached extension tab lists (`extensionList`) in every window showing them.
    private(set) var tabsBySpace: [UUID: [Tab]] {
        get { store.tabsBySpace }
        _modify { yield &store.tabsBySpace; store.listsChanged() }
    }
    private(set) var bookmarkTabs: [UUID: Tab] {
        get { store.bookmarkTabs }
        _modify { yield &store.bookmarkTabs; store.listsChanged() }
    }
    private var selectedBySpace: [UUID: UUID] = [:]
    private(set) var currentSpaceID: UUID { didSet { extensionLists.removeAll() } }
    /// MRU order in this window, for Control+Tab.
    private(set) var recentTabIDs: [UUID] = []
    /// Tabs opened from another since you last switched tabs: closing one goes back toward its opener, as in Chrome.
    private var openedSinceSwitch: Set<UUID> = []
    /// Set while a selection is Zigzag's own (a new tab, after a close), which keeps `openedSinceSwitch`.
    private var selectingQuietly = false
    private var closedTabs: [ClosedTab] {
        get { store.closedTabs }
        _modify { yield &store.closedTabs }
    }
    /// Closed tabs brought back, by the id each had: the new tab's id.
    private var reopenedAs: [UUID: UUID] {
        get { store.reopenedAs }
        _modify { yield &store.reopenedAs }
    }
    /// How many closed tabs ⇧⌘T and ⌘Z can reopen (`TabStore.closedLimit`).
    private var closedLimit: Int {
        get { store.closedLimit }
        set { store.closedLimit = newValue }
    }
    /// Tab groups (#209) by id; membership is on `Tab.groupID`.
    private(set) var groups: [UUID: TabGroup] {
        get { store.groups }
        _modify { yield &store.groups }
    }
    /// Groups removed with their last tab, so reopening the tab restores its group.
    private var emptiedGroups: [UUID: TabGroup] {
        get { store.emptiedGroups }
        _modify { yield &store.emptiedGroups }
    }

    weak var host: TabHost? {
        didSet {
            // All its tabs, or with shared tabs (#162) those no window shows yet.
            let alone = store.managers.count <= 1
            allTabs.forEach { if alone || $0.host == nil { $0.host = host } }
        }
    }
    let changed = Signal<Change>()

    private var libraryToken: SignalToken?

    /// Saves navigation for crash recovery (`TabStore.watch`).
    private func watch(_ tab: Tab) { store.watch(tab) }
    private var suspendTimer: Timer?

    /// A tab closed by a change elsewhere (a space or pinned page deleted): no longer watched or among the recent.
    private func forget(_ tab: Tab) {
        store.unwatch(tab.id)
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
        var customIcon: String? = nil
        /// The split it was half of, so bringing it back puts it beside its partner again.
        var split: SplitPair? = nil
        /// When it was last looked at: brought back, it's as recent as it was, so Clear and the fading see it so too.
        var lastActivated = Date()
        /// The tab it sat under, and the tabs that sat under it (they moved up a level): brought back, it goes under
        /// the one again and takes the others back, if they're still where it left them.
        var parentID: UUID? = nil
        var childIDs: [UUID] = []
        /// Whether the tabs under it were folded away, so they come back folded.
        var isCollapsed = false
        /// Its tab group; reopening restores it (and the group if it was removed).
        var groupID: UUID? = nil
        /// When it closed, so ⇧⌘T takes the latest closed anywhere, tab or window.
        var closedAt = Date()
    }

    /// Private windows share one throwaway store between their tabs, gone when the window closes.
    var privateStore: WKWebsiteDataStore? { store.privateStore }
    var isPrivate: Bool { privateStore != nil }
    /// The one profile whose spaces this window shows: AI apps' window keeps to theirs.
    let keepsToProfile: UUID?

    /// Whether the window may show a space: never from a private one, only those it keeps to.
    func mayShowSpace(_ space: UUID) -> Bool { !isPrivate && keepsTo(space) }

    /// Its profile's spaces when it keeps to one, else all but AI Apps'.
    func keepsTo(_ space: UUID) -> Bool { Self.keeps(space, to: keepsToProfile) }

    private static func keeps(_ space: UUID, to profile: UUID?) -> Bool {
        guard let profile else { return !Library.shared.isAIAppsSpace(space) }
        return Library.shared.profileID(ofSpace: space) == profile
    }

    /// The spaces the window lists to go to: yours, or its profile's when it keeps to one.
    var listedSpaces: [SpaceInfo] {
        guard let keepsToProfile else { return Library.shared.yourSpaces }
        return Library.shared.spaces(in: keepsToProfile)
    }

    /// `store`: a shared store (#162); nil creates one. Private windows always get their own.
    init(spaceID: UUID? = nil, isPrivate: Bool = false, store: TabStore? = nil, keepsToProfile: UUID? = nil) {
        self.keepsToProfile = keepsToProfile
        self.store = (isPrivate ? nil : store) ?? TabStore(isPrivate: isPrivate)
        let requested = spaceID.flatMap { Library.shared.space($0)?.id }.flatMap { Self.keeps($0, to: keepsToProfile) ? $0 : nil }
        currentSpaceID = requested ?? Self.firstSpace(keepingTo: keepsToProfile)
        self.store.attach(self)
        libraryToken = Library.shared.changed.observe { [weak self] in
            // Favorites and pinned pages count among the navigable tabs.
            self?.extensionLists.removeAll()
            self?.libraryDidChange()
            Brand.libraryChanged()
        }
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdleTabs() }
        }
        // Slack, so the system can fold it into other wake-ups instead of waking the Mac for it.
        suspendTimer?.tolerance = 10
    }

    /// Set once the window is closed.
    private(set) var isInvalidated = false

    /// True when no other window shows its tabs; closing it closes them.
    var isLastView: Bool { store.managers.allSatisfy { $0 === self } }

    /// The window closes. The last window of a store closes its tabs; with shared tabs (#162) they stay with the other
    /// windows, which can now show its pages and get its tabs' links.
    func invalidate() {
        guard !isInvalidated else { return }
        suspendTimer?.invalidate()
        isInvalidated = true
        store.detach(self)
        let others = store.managers
        guard let heir = others.first else {
            allTabs.forEach { $0.close(keepingSnapshot: !isPrivate) }
            tabsBySpace = [:]
            bookmarkTabs = [:]
            return
        }
        var released: [Tab] = []
        for tab in allTabs {
            if tab.shownBy === self { tab.shownBy = nil; released.append(tab) }
            if tab.host == nil || tab.host === host { Self.rehost(tab, to: heir.host) }
        }
        // Pages waiting in another window show there now.
        for other in others {
            other.listChanged()
            if released.contains(where: other.isShowing) { other.pageTaken() }
        }
    }

    // MARK: Windows sharing their tabs

    /// Set while applying another window's change, so it isn't relayed back.
    private var isRelaying = false

    /// Pages on screen at the last draw; another window's change redraws only if they differ.
    private var shownLastTime: [UUID] = []
    private var shownSignature: [UUID] {
        guard let tab = selectedTab else { return [] }
        return [tab.id] + (split(for: tab)?.ids ?? [])
    }

    /// Selection changed. Pages this window stopped showing appear in any shared window waiting for them.
    private func selectionChanged() {
        let before = shownLastTime
        shownLastTime = shownSignature
        changed.send(.selection)
        let released = Set(before).subtracting(shownLastTime)
        guard !released.isEmpty, !isInvalidated, store.isShared else { return }
        for other in store.managers where other !== self {
            guard let tab = other.selectedTab else { continue }
            if other.panes(of: tab).contains(where: { released.contains($0.id) && $0.shownBy !== other }) { other.pageTaken() }
        }
    }

    /// Another window changed the tabs: fix selections that lost their tab and redraw the list (and the page if it
    /// changed).
    func listChanged() {
        guard !isInvalidated else { return }
        isRelaying = true
        defer { isRelaying = false }
        extensionLists.removeAll()
        settleSelection()
        changed.send(.structure)
        if shownSignature != shownLastTime { selectionChanged() }
    }

    /// Replaces each space's selection that was closed or moved elsewhere with the previous tab there (preferring one
    /// no other window shows), else the first, else none.
    private func settleSelection() {
        for (space, id) in selectedBySpace {
            if let tab = tab(with: id), tab.isFavorite || tab.spaceID == space { continue }
            let list = tabs(in: space)
            let recent = recentTabs.filter { $0.spaceID == space && !$0.isFavorite && !$0.isClosed }
            let free = recent.first { !isShownElsewhere($0) } ?? list.first { !isShownElsewhere($0) }
            selectedBySpace[space] = (free ?? recent.first ?? list.first)?.id
        }
    }

    /// Whether this window shows the tab's page now (selected or beside it).
    func isShowing(_ tab: Tab) -> Bool {
        guard !isInvalidated, let selected = selectedTab else { return false }
        return selected === tab || panes(of: selected).contains { $0 === tab }
    }

    /// Pages on screen in this window.
    var allTabsShownNow: [Tab] { selectedTab.map(panes(of:)) ?? [] }

    /// Whether the tab is selected in any space here.
    func hasChosen(_ tab: Tab) -> Bool { selectedBySpace.values.contains(tab.id) }

    /// Another sharing window shows this page; this one shows a placeholder offering to bring it here.
    func isShownElsewhere(_ tab: Tab) -> Bool { store.isShared && store.isShownElsewhere(tab, than: self) }

    /// Takes these pages from the window showing them. Returns the windows to notify once they're here.
    private func claim(_ pages: [Tab]) -> [TabManager] {
        var losers: [TabManager] = []
        for page in pages {
            if let owner = page.shownBy, owner !== self, owner.isShowing(page), !losers.contains(where: { $0 === owner }) { losers.append(owner) }
            own(page)
        }
        // Another window's mini player releases the video.
        if store.isShared, pages.contains(where: \.isInMiniPlayer) {
            for other in store.managers where other !== self && !losers.contains(where: { $0 === other }) { losers.append(other) }
        }
        return losers
    }

    /// Called before drawing a page; takes it if no other window shows it.
    func mayShow(_ page: Tab) -> Bool {
        guard !isShownElsewhere(page) else { return false }
        own(page)
        return true
    }

    private func own(_ page: Tab) {
        page.shownBy = self
        Self.rehost(page, to: host)
    }

    /// Moves a tab to another window: its links open there and extensions are told.
    private static func rehost(_ tab: Tab, to host: TabHost?) {
        guard let host, tab.host !== host else { return }
        let old = tab.host as? BrowserWindowController
        tab.host = host
        tab.store?.listsChanged()
        if #available(macOS 15.4, *), let old, !old.tabManager.isPrivate,
           let place = old.tabManager.tabsForExtensions.firstIndex(where: { $0 === tab }) {
            ExtensionCenter.tabMoved(tab, from: place, in: old)
        }
    }

    /// Another window took a page shown here.
    private func pageTaken() {
        isRelaying = true
        defer { isRelaying = false }
        selectionChanged()
    }

    /// A new sharing window starts with this one's selections in other spaces and none in its own space (for a new tab
    /// or the command bar).
    func startSelection(from other: TabManager) {
        guard other.store === store, other !== self else { return }
        selectedBySpace = other.selectedBySpace
        selectedBySpace[currentSpaceID] = nil
        recentTabIDs = other.recentTabIDs
    }

    /// The page moved to another sharing window (Move to New Window, drag out): select the previous tab here,
    /// preferring one no other window shows, as if closed. The tab stays open.
    func moveOn(from tab: Tab) {
        guard let selected = selectedTab, isShowing(tab) else { return }
        let space = selected.spaceID
        let gone = Set(panes(of: selected).map(\.id) + [selected.id])
        let rest = recentTabs.filter { !gone.contains($0.id) && $0.spaceID == space && !$0.isClosed }
            + tabs(in: space).filter { !gone.contains($0.id) }
        if let next = rest.first(where: { !isShownElsewhere($0) }) {
            select(next, claiming: false)
        } else {
            selectedBySpace[space] = nil
            selectionChanged()
        }
    }

    /// Sharing turned on or off in Settings › Tabs (`TabStore.share`, `unshare`); now shows `store`'s tabs.
    func adopt(store new: TabStore) {
        guard new !== store else { return }
        store.detach(self)
        store = new
        new.attach(self)
    }

    /// The store changed: fix selections it no longer has and redraw.
    func storeChanged() {
        isRelaying = true
        defer { isRelaying = false }
        extensionLists.removeAll()
        recentTabIDs = recentTabIDs.filter { tab(with: $0) != nil }
        // Nested tabs whose parent moved to another window move to the top level.
        for space in Array(tabsBySpace.keys) { repairTree(in: space) }
        settleSelection()
        settleGroups()
        changed.send(.structure)
        shownLastTime = []
        selectionChanged()
    }

    func forgetExtensionLists() { extensionLists.removeAll() }

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

    /// Where a window starts or goes when its space is gone: its first listed space.
    static func firstSpace(keepingTo profile: UUID?) -> UUID {
        let listed = profile.map { Library.shared.spaces(in: $0) } ?? Library.shared.yourSpaces
        return listed.first?.id ?? Library.shared.spaces[0].id
    }
    var currentTabs: [Tab] { tabs(in: currentSpaceID) }
    func tabs(in spaceID: UUID) -> [Tab] { tabsBySpace[spaceID] ?? [] }

    var allTabs: [Tab] { tabsBySpace.values.flatMap { $0 } + Array(bookmarkTabs.values) }
    /// Whether any space has a tab open here. Pinned tabs and favorites aren't counted: every window has those.
    var hasTabs: Bool { tabsBySpace.values.contains { !$0.isEmpty } }

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

    /// MRU across spaces: this window's order, then with shared tabs (#162) tabs opened elsewhere, most recently viewed
    /// first.
    var recentTabs: [Tab] {
        // One pass to index the tabs, not a search for each id.
        let tabs = allTabs
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recentTabIDs.compactMap { byID[$0] }
        guard store.isShared, recent.count < tabs.count else { return recent }
        let seen = Set(recentTabIDs)
        return recent + tabs.filter { !seen.contains($0.id) }.sorted { $0.lastActivated > $1.lastActivated }
    }

    // MARK: Creating

    /// Where a new tab goes in the list (Settings › Tabs). Next to the current tab is what Chrome and Safari do, so
    /// a tab shows up where you were looking; Arc's way, on top, and the bottom are choices. Next to tabs from the
    /// same site (#188) puts a page with the tabs already open from its site, and one from a site with none open
    /// where the choice before it put tabs (`otherNewTabPlace`).
    enum NewTabPlace: String, CaseIterable { case next, top, bottom, sameSite }
    static var newTabPlace: NewTabPlace {
        get { UserDefaults.standard.string(forKey: "NewTabPlace").flatMap(NewTabPlace.init(rawValue:)) ?? .next }
        set {
            let was = newTabPlace
            if newValue == .sameSite, was != .sameSite { UserDefaults.standard.set(was.rawValue, forKey: "NewTabPlaceOtherwise") }
            UserDefaults.standard.set(newValue.rawValue, forKey: "NewTabPlace")
        }
    }

    /// Where a new tab goes that has no tab from its site to go beside: the choice made before Next to Tabs from the
    /// Same Site, or the one itself when that isn't on.
    static var otherNewTabPlace: NewTabPlace {
        let place = newTabPlace
        guard place == .sameSite else { return place }
        let before = UserDefaults.standard.string(forKey: "NewTabPlaceOtherwise").flatMap(NewTabPlace.init(rawValue:)) ?? .next
        return before == .sameSite ? .next : before
    }

    /// What counts as one site for placing tabs: the registrable domain (mail.google.com and docs.google.com are
    /// google.com), or the whole host where there isn't one (an IP address, localhost).
    nonisolated static func site(of url: URL?) -> String? {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return PublicSuffix.registrableDomain(host) ?? host
    }

    /// Where a new tab lands in a space's list: next to the tab it came from (after the others it already opened, so a
    /// row of links stays in reading order), or below the tab you're on; on top when neither is in the list. Next to
    /// a tab means after the tabs nested under it too.
    private func newTabIndex(in space: UUID, opener: Tab?, select: Bool) -> Int {
        let list = tabsBySpace[space] ?? []
        let nodes = treeNodes(in: space)
        switch Self.otherNewTabPlace {
        case .top, .sameSite: return 0
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
    /// With Next to Tabs from the Same Site, a page goes with its site's tabs in the space (never a pinned page or
    /// favorite: those keep their places), in the group the last of them is in.
    private func newTabPlacement(in space: UUID, opener: Tab?, select: Bool, site page: URL?) -> (index: Int, parent: UUID?) {
        let nodes = treeNodes(in: space)
        if Self.nestsOpenedLinks, let opener, opener.bookmarkID == nil, !opener.isOutsideTabList, opener.spaceID == space,
           let at = TabTree.childIndex(of: opener.id, in: nodes) {
            return (at, opener.id)
        }
        if let place = sameSitePlacement(in: space, opener: opener, site: page) { return place }
        let index = newTabIndex(in: space, opener: opener, select: select)
        let anchor = opener ?? (space == currentSpaceID ? selectedTab : nil)
        return (index, TabTree.parent(at: index, preferring: anchor?.bookmarkID == nil ? anchor?.parentID : nil, in: nodes))
    }

    /// Next to Tabs from the Same Site: where a page from `page`'s site goes among the space's tabs from it. Nil when
    /// that isn't the choice, or no tab is from that site.
    private func sameSitePlacement(in space: UUID, opener: Tab?, site page: URL?) -> (index: Int, parent: UUID?)? {
        guard Self.newTabPlace == .sameSite, let site = Self.site(of: page) else { return nil }
        var sites: [UUID: String] = [:]
        for tab in tabs(in: space) { if let other = Self.site(of: tab.url) { sites[tab.id] = other } }
        return TabTree.besideSameSite(site, sites: sites, opener: opener?.id, in: treeNodes(in: space))
    }

    /// The last tab put beside the current one with nothing that opened it, so the next lands after it.
    private var placedBeside: PlacedBeside?
    private struct PlacedBeside { weak var anchor: Tab?; weak var last: Tab? }

    /// `httpFallback`: `url` is https for a scheme-less address; retried over http if unreachable
    /// (`CommandRanker.Destination`).
    @discardableResult
    func newTab(url: URL?, spaceID: UUID? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil,
                opener: Tab? = nil, title: String? = nil, site: URL? = nil, by sender: Tab.LoadSender = .zigzag,
                httpFallback: Bool = false) -> Tab {
        // A page another page opened stays with it: WebKit made it in that page's profile.
        // One WebKit made for a page with no tab of its own here (a Zigzag Mini's, a sign-in window's) goes to a
        // space on that page's profile, not to whichever space this window happens to show.
        let made = configuration.flatMap { Profiles.shared.profile(ofStore: $0.websiteDataStore) }
        let asked = spaceID ?? (configuration != nil ? opener?.spaceID : nil) ?? made.flatMap { self.space(for: $0) } ?? currentSpaceID
        // A window that keeps to a profile makes its tabs in that profile's spaces, as it moves them (`moveTabToSpace`).
        let space = keepsTo(asked) ? asked : currentSpaceID
        let tab = Tab(url: url, title: title, spaceID: space, configuration: configuration)
        // Whoever gave the address loads it: a page's link in a new tab is the page's doing, a typed one yours.
        tab.firstLoad = Tab.FirstLoad(sender: sender, httpFallback: httpFallback)
        tab.host = host
        watch(tab)
        tab.opener = opener
        if opener != nil { openedSinceSwitch.insert(tab.id) }
        // Placed once, as Settings says; the list never reorders itself after that.
        // `site`: the page a tab made empty is about to load, for Next to Tabs from the Same Site.
        let place = newTabPlacement(in: space, opener: opener, select: select, site: url ?? site)
        tab.parentID = place.parent
        tabsBySpace[space, default: []].insert(tab, at: place.index)
        // Opened from a grouped tab right after the group's last tab: join the group. Inside the group it joins anyway.
        let anchor = opener ?? (space == currentSpaceID ? selectedTab : nil)
        if let group = anchor?.groupID, anchor?.spaceID == space, place.index > 0, tabs(in: space)[place.index - 1].groupID == group {
            tab.groupID = group
        }
        unfold(place.parent)
        if opener == nil, !select, Self.otherNewTabPlace == .next, space == currentSpaceID { placedBeside = PlacedBeside(anchor: selectedTab, last: tab) } else { placedBeside = nil }
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        // Opened in front from a page in split view: it takes that page's pane, so the split stays on screen and
        // the page it came from waits in the list. A pinned split keeps its pages; the new tab shows on its own.
        if select, let opener, opener.bookmarkID == nil, opener.spaceID == space, let index = splits.firstIndex(where: { $0.contains(opener.id) }) {
            splits[index].replace(opener.id, with: tab.id)
            // Half of the split now, it's a row of its own, not one nested under the page it came from.
            liftToTopLevel(tab)
        }
        structureChanged()
        if select {
            selectQuietly(tab)
        } else {
            recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count))
            // Background tabs start loading right away, so they're ready when you get to them.
            if url != nil || configuration != nil { tab.ensureWebView() }
        }
        return tab
    }

    /// Pages as new tabs side by side in this order, where one new tab would go (Open All in Tabs, #343). All start
    /// loading right away; the first shows.
    @discardableResult
    func newTabs(_ pages: [(url: URL, title: String)]) -> [Tab] {
        guard let firstURL = pages.first?.url else { return [] }
        let space = currentSpaceID
        let place = newTabPlacement(in: space, opener: nil, select: true, site: firstURL)
        let anchor = selectedTab?.spaceID == space ? selectedTab : nil
        let joins = anchor?.groupID.flatMap { group in place.index > 0 && tabs(in: space)[place.index - 1].groupID == group ? group : nil }
        let made = pages.map { page in
            let tab = Tab(url: page.url, title: page.title, spaceID: space)
            tab.firstLoad = Tab.FirstLoad(sender: .zigzag, httpFallback: false)
            tab.host = host
            watch(tab)
            tab.parentID = place.parent
            tab.groupID = joins
            return tab
        }
        tabsBySpace[space, default: []].insert(contentsOf: made, at: place.index)
        unfold(place.parent)
        placedBeside = nil
        if #available(macOS 15.4, *) { made.forEach { ExtensionCenter.tabOpened($0) } }
        structureChanged()
        for tab in made.dropFirst().reversed() {
            recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count))
            tab.ensureWebView()
        }
        select(made[0])
        return made
    }

    /// Where a tab stood in the list as it left without closing (into Zigzag Mini): `putBack` returns it there.
    struct Place {
        let spaceID: UUID
        let index: Int
        let parentID: UUID?
        /// The tabs that sat right under it, a level up while it's away.
        let childIDs: [UUID]
        /// The split or tile group it was in.
        let split: SplitPair?
        /// Its tab group.
        var groupID: UUID? = nil
    }

    /// Takes a tab out of the list, its page still open, for Zigzag Mini or another window to show: as for a closed
    /// tab, the tabs under it move up a level, its split or tile group closes up, and the window goes on to another
    /// tab. Returns where it was. Not for a pinned page's or favorite's: those belong to the sidebar. `toWindow`: it's
    /// going into another window, where extensions hear it moved (`ExtensionCenter.tabMoved`), not that it closed.
    @discardableResult
    func release(_ tab: Tab, toWindow: Bool = false) -> Place? {
        guard tab.bookmarkID == nil, let index = tabs(in: tab.spaceID).firstIndex(where: { $0 === tab }) else { return nil }
        let place = Place(spaceID: tab.spaceID, index: index, parentID: tab.parentID,
                          childIDs: tabs(in: tab.spaceID).filter { $0.parentID == tab.id }.map(\.id), split: split(for: tab),
                          groupID: tab.groupID)
        let wasSelected = selectedTab === tab
        // Half of a split shown here: the rest of it stays on screen, as when the page closes.
        let partner = leaveGroup(tab, notify: false)
        liftChildren(of: tab)
        tabsBySpace[tab.spaceID]?.remove(at: index)
        recentTabIDs.removeAll { $0 == tab.id }
        store.unwatch(tab.id)
        if #available(macOS 15.4, *), !toWindow { ExtensionCenter.tabClosed(tab) }
        structureChanged()
        if wasSelected {
            if let partner { select(partner) } else { selectAfterClosing(tab, index: index) }
        } else if place.split != nil {
            selectionChanged()
        }
        return place
    }

    /// A tab `release` took out comes back where it was (with the tabs that sat under it, in its split if the rest
    /// is still as it was), and shows.
    func putBack(_ tab: Tab, at place: Place) {
        guard !tab.isClosed, self.tab(with: tab.id) == nil else { return }
        let space = Library.shared.space(place.spaceID) != nil ? place.spaceID : currentSpaceID
        tab.host = host
        tab.setSpace(space)
        watch(tab)
        let at = min(place.index, tabs(in: space).count)
        let nodes = TabTree.reinserting(tab.id, at: at, parent: space == place.spaceID ? place.parentID.map(reopenedID) : nil,
                                        children: Set(place.childIDs.map(reopenedID)), in: treeNodes(in: space))
        tabsBySpace[space, default: []].insert(tab, at: at)
        applyTree(nodes, in: space)
        tab.groupID = space == place.spaceID ? place.groupID.flatMap(regroup) : nil
        if let pair = place.split { rejoin(tab, was: tab.id, in: pair, space: space) }
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        structureChanged()
        select(tab)
    }

    /// A pinned page's or favorite's open page out of this window, still loaded, so another window can adopt it.
    func detachBookmarkTab(_ bookmarkID: UUID) -> Tab? {
        guard let tab = bookmarkTabs[bookmarkID] else { return nil }
        splits.removeAll { $0.contains(tab.id) }
        let wasSelected = selectedTab === tab
        bookmarkTabs[bookmarkID] = nil
        recentTabIDs.removeAll { $0 == tab.id }
        store.unwatch(tab.id)
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        structureChanged()
        if wasSelected { selectAfterClosing(tab, index: 0) }
        return tab
    }

    /// A pinned page's or favorite's open page from another window, in the space you're in.
    func insertBookmarkTab(_ tab: Tab, bookmarkID: UUID) {
        tab.setSpace(currentSpaceID)
        adoptBookmarkTab(tab, bookmarkID: bookmarkID)
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
    }

    /// Adds a tab that already has a page (from another window or Zigzag Mini) at `index` and shows it.
    func insert(_ tab: Tab, at index: Int = 0, under parent: UUID?? = nil) {
        tab.host = host
        tab.setSpace(currentSpaceID)
        watch(tab)
        var list = tabsBySpace[currentSpaceID] ?? []
        let at = min(max(index, 0), list.count)
        // It joins the group it lands in, if any, so the group stays whole.
        tab.parentID = parent ?? TabTree.parentForInsertion(at: at, in: treeNodes(in: currentSpaceID))
        list.insert(tab, at: at)
        tabsBySpace[currentSpaceID] = list
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        structureChanged()
        // A page from Zigzag Mini made a tab still goes back to the page it came from.
        if tab.opener != nil { openedSinceSwitch.insert(tab.id) }
        selectQuietly(tab)
    }

    /// A tab from another window's list into this one at `index`, its page as it is, and shown (#167). Half of a
    /// split of two tabs brings the other half, and a page of a tile group the rest of it: they arrive as one, still
    /// side by side, so a group is never in two windows. A split with a pinned page stays there, and the tab leaves
    /// it. Returns the pages that came, each with its place among the other window's tabs as extensions count them.
    @discardableResult
    func take(_ tab: Tab, from other: TabManager, at index: Int) -> [(tab: Tab, from: Int)] {
        guard other !== self, other.store !== store, !tab.isClosed, tab.bookmarkID == nil, other.tab(with: tab.id) === tab else { return [] }
        let pair = other.split(for: tab)
        let panes = other.panes(of: tab)
        let together = pair != nil && panes.count == pair?.count && panes.allSatisfy { $0.bookmarkID == nil }
        let pages = together ? panes : [tab]
        let places = pages.map { page in other.tabsForExtensions.firstIndex { $0 === page } ?? 0 }
        pages.forEach { other.release($0, toWindow: true) }
        // Each in at the same place, last first, so they keep their order.
        for page in pages.reversed() { insert(page, at: index) }
        if together, let pair { restoreSplit(pair) }
        return Array(zip(pages, places))
    }

    /// A page that comes in from outside the list (Zigzag Mini's), placed where a new tab would go, and shown.
    func insertAsNewTab(_ tab: Tab) {
        if let place = sameSitePlacement(in: currentSpaceID, opener: nil, site: tab.url) { return insert(tab, at: place.index, under: place.parent) }
        insert(tab, at: newTabIndex(in: currentSpaceID, opener: nil, select: true))
    }

    /// A page from outside the list (a Zigzag Mini opened from a link) right after the tab it came from, and shown.
    /// False when that tab isn't in the space in front.
    @discardableResult
    func insert(_ tab: Tab, after anchor: Tab) -> Bool {
        guard let at = (tabsBySpace[currentSpaceID] ?? []).firstIndex(where: { $0 === anchor }) else { return false }
        tab.groupID = anchor.groupID
        insert(tab, at: TabTree.subtreeEnd(at: at, in: treeNodes(in: currentSpaceID)), under: .some(anchor.parentID))
        return true
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
        // Only tabs it has (a shared window chose among others', #162).
        selectedBySpace = selection.filter { tab(with: $0.value) != nil }
        if Library.shared.space(currentSpaceID) != nil { self.currentSpaceID = currentSpaceID }
        if let tab = selectedTab { promote(tab) }
        structureChanged()
        changed.send(.space)
        selectionChanged()
    }

    // MARK: Selecting

    /// `claiming`: show the page here even if another sharing window shows it (#162). Without it (an automatic
    /// selection after closing), the page stays there and this window shows a placeholder.
    func select(_ tab: Tab, claiming: Bool = true) {
        // A tab closed since (one an old undo step or a stale button still points at) never comes back from here.
        guard !tab.isClosed else { return }
        Autofill.shared.hide()
        // The Mac's Passwords list belongs to the page it opened on.
        if tab !== selectedTab { Autofill.shared.closeSystemPasswords() }
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
        // Switching tabs yourself forgets which tabs opened which, as in Chrome.
        if !selectingQuietly, previous !== tab { openedSinceSwitch.removeAll() }
        previous?.captureSnapshot()
        // Where you were and what you'd typed, in case its page has to load again while you're away.
        if previous !== tab { previous?.readPageState() }
        // Idle counts from when you last saw a tab, not when you first opened it: a page you read for an hour
        // and just left isn't unloaded the moment you look away.
        if previous !== tab { previous?.markActivated() }
        selectedBySpace[tab.spaceID] = tab.id
        let losers = claiming ? claim(panes(of: tab)) : []
        tab.markActivated()
        promote(tab)
        tab.ensureWebView()
        tab.reloadIfItStopped()
        tab.shown()
        if #available(macOS 15.4, *), previous !== tab { ExtensionCenter.tabActivated(tab, previous: previous) }
        selectionChanged()
        // After the pages arrive, so the losing window sees them gone.
        for loser in losers { loser.pageTaken() }
    }

    /// Selects without counting as your switch, so tabs opened from others still close back toward them.
    private func selectQuietly(_ tab: Tab, claiming: Bool = true) {
        let was = selectingQuietly
        selectingQuietly = true
        defer { selectingQuietly = was }
        select(tab, claiming: claiming)
    }

    private func promote(_ tab: Tab) {
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
    }

    func clearSelection() {
        selectedBySpace[currentSpaceID] = nil
        selectionChanged()
    }

    func select(at index: Int) {
        let list = navigableTabs
        guard !list.isEmpty else { return }
        select(index >= list.count ? list[list.count - 1] : list[index])
    }

    /// Open favorites, open pinned tabs, then tabs, in sidebar order.
    var navigableTabs: [Tab] {
        let favoriteLive = Library.shared.favorites(in: profile.id).compactMap { bookmarkTabs[$0.id] }
        let bookmarkLive = Library.shared.bookmarks(in: currentSpaceID).compactMap { bookmarkTabs[$0.id] }
        return favoriteLive + bookmarkLive + currentTabs
    }

    /// Every space's open pages, as Chrome lists a window's tabs: this space's first, then the others in sidebar order.
    var tabsForExtensions: [Tab] {
        var list = navigableTabs
        var listedFavorites: Set<UUID> = [profile.id]
        for space in Library.shared.spaces where space.id != currentSpaceID {
            let owner = Library.shared.profileID(ofSpace: space.id)
            if listedFavorites.insert(owner).inserted { list += Library.shared.favorites(in: owner).compactMap { bookmarkTabs[$0.id] } }
            list += Library.shared.bookmarks(in: space.id).compactMap { bookmarkTabs[$0.id] }
            list += tabs(in: space.id)
        }
        return list
    }

    /// Cached tabs per extension set, and their indexes, for `tabs(for:)` and `indexInWindow`. WebKit asks on
    /// every extension message and tab query, and rebuilding each time was slow (#89). Kept until anything here or in
    /// the library changes, or `extensionListLifetime` passes.
    private var extensionLists: [ObjectIdentifier: (tabs: [Tab], places: [ObjectIdentifier: Int])] = [:]
    private var extensionListsMade: TimeInterval = 0
    private var placesToken: SignalToken?
    /// Max cache age without a change notice: a backstop for unannounced changes.
    static let extensionListLifetime: TimeInterval = 1

    private func extensionList(seenBy key: ObjectIdentifier, isSeen: (Tab) -> Bool) -> (tabs: [Tab], places: [ObjectIdentifier: Int]) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - extensionListsMade > Self.extensionListLifetime { extensionLists.removeAll() }
        if extensionLists.isEmpty {
            placesToken = placesToken ?? changed.observe { [weak self] _ in self?.extensionLists.removeAll() }
            extensionListsMade = now
        }
        if let list = extensionLists[key] { return list }
        let tabs = tabsForExtensions.filter(isSeen)
        let list = (tabs, Self.places(tabs))
        extensionLists[key] = list
        return list
    }

    func extensionPlace(of tab: Tab, seenBy key: ObjectIdentifier, isSeen: (Tab) -> Bool) -> Int? {
        extensionList(seenBy: key, isSeen: isSeen).places[ObjectIdentifier(tab)]
    }

    func extensionTabs(seenBy key: ObjectIdentifier, isSeen: (Tab) -> Bool) -> [Tab] {
        extensionList(seenBy: key, isSeen: isSeen).tabs
    }

    /// Where each item is in the list: its first place, as `firstIndex` would say.
    static func places<Item: AnyObject>(_ list: [Item]) -> [ObjectIdentifier: Int] {
        var places: [ObjectIdentifier: Int] = [:]
        for (index, item) in list.enumerated() where places[ObjectIdentifier(item)] == nil { places[ObjectIdentifier(item)] = index }
        return places
    }

    /// Turns a tab into a favorite at a tile's place. Its page stays open behind the tile.
    func favoriteTab(_ tab: Tab, at index: Int? = nil) {
        guard let url = address(of: tab) else { return }
        // Half of a split brings the other half, and a page of a tile group the rest of it (#203): they become one
        // favorite, side by side as they are. A page with nothing to keep can't come along, so the split ends (or
        // the group closes up around this page's place) and the tab goes on its own.
        if let pair = split(for: tab) {
            if favoriteSplit(pair, at: index) { return }
            if pair.isGroup { leaveGroup(tab, notify: false) } else { unsplit(tab, notify: false) }
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
        tab.settleLandingIfLoading()
        bookmarkTabs[id] = tab
        Library.shared.addFavorite(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), icon: tab.customIcon, at: index, id: id, in: profile.id)
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
            mark = Bookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), icon: tab.customIcon)
            tab.bookmarkID = mark.id
            tab.settleLandingIfLoading()
            bookmarkTabs[mark.id] = tab
        }
        tab.isFavorite = true
        Library.shared.joinFavorite(mark, onto: favoriteID, onRight: onRight)
        openBookmark(mark)
    }

    /// A split view or tile group as one favorite, laid out as it is. Pinned pages keep their ids (and so their
    /// pages); a tab becomes one. False when it can't (a page with no address yet).
    private func favoriteSplit(_ pair: SplitPair, at index: Int?) -> Bool {
        let pages = pair.ids.compactMap { tab(with: $0) }
        guard pages.count == pair.count, pages.allSatisfy({ address(of: $0) != nil }) else { return false }
        // Already a pinned split or group: it moves up as it is.
        let pinned = pages.compactMap(\.bookmarkID)
        if pinned.count == pages.count, let split = Library.shared.pinnedSplit(containing: pinned[0]), Set(split.ids) == Set(pinned) {
            if Library.shared.isFavorite(split.left) {
                if let index { Library.shared.moveFavorite(split.left, to: index) }
            } else {
                Library.shared.makeFavorite(split.left, at: index, in: profile.id)
            }
            pages.forEach { $0.isFavorite = true }
            return true
        }
        var marks: [Bookmark] = []
        for page in pages {
            let url = address(of: page)!
            if let id = page.bookmarkID, let mark = Library.shared.detachBookmark(id) ?? Library.shared.bookmark(id) {
                marks.append(mark)
            } else {
                removeFromList(page)
                let mark = Bookmark(url: url, title: Self.bookmarkTitle(page.displayTitle, url: url), icon: page.customIcon)
                page.bookmarkID = mark.id
                page.settleLandingIfLoading()
                bookmarkTabs[mark.id] = page
                marks.append(mark)
            }
            page.isFavorite = true
        }
        if let layout = PinnedSplit(marks.map(\.id), as: pair) {
            Library.shared.addFavoriteSplit(marks, as: layout, at: index, in: profile.id)
        }
        structureChanged()
        return true
    }

    // MARK: Spaces

    func switchToSpace(_ id: UUID) {
        // A private window keeps to one space: a swipe or ⌃1 there would leave its tabs out of sight.
        guard mayShowSpace(id), id != currentSpaceID, Library.shared.space(id) != nil else { return }
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
        selectionChanged()
    }

    /// What Clear closes in a space. `unused`: tabs not used lately, keeping the current working set; then `others`:
    /// all but the current tab (and its split or tile group); then `last`: those too, emptying the space.
    ///
    /// Splits, tile groups and nests (while finding unused tabs) are one unit: aged by their newest page, kept or
    /// closed whole. `others` includes nests with yours. Units with audio, a call, or a pinned page are never closed:
    /// pinned pages are bookmarks.
    enum ClearKind { case unused, others, last }

    func tabsToClear(in spaceID: UUID, now: Date = Date()) -> (tabs: [Tab], kind: ClearKind) {
        let tabs = self.tabs(in: spaceID)
        let current = selectedTab(in: spaceID)
        let ids = Set(tabs.map(\.id))
        // Splits and groups with a page here, including those with a pinned page.
        let groups = splits.filter { !ids.isDisjoint(with: $0.ids) }.map(\.ids)
        let nested = Dictionary(tabs.compactMap { tab in tab.parentID.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a })
        // Tab groups (#209) are kept or closed whole, like nests.
        let parents = TabGroups.clearParents(nested, nodes: treeNodes(in: spaceID), groups: groupIDs(in: spaceID))
        // Pages another sharing window shows are in use (#162).
        let busy = Set(tabs.filter { $0.isPlayingAudio || $0.isInUse || isShownElsewhere($0) }.map(\.id))
        let ages = Dictionary(tabs.map { ($0.id, now.timeIntervalSince($0.lastActivated)) }, uniquingKeysWith: { a, _ in a })
        let (closing, kind) = Self.clearing(tabs.map(\.id), current: current?.id, groups: groups, parents: parents, busy: busy, ages: ages)
        return (tabs.filter { closing.contains($0.id) }, kind)
    }

    /// Clear's choice by id, for a lone tab or a two-page split (`partner` beside `current`).
    nonisolated static func clearing(_ tabs: [UUID], current: UUID?, partner: UUID?, busy: Set<UUID>,
                                     ages: [UUID: TimeInterval]) -> (ids: Set<UUID>, kind: ClearKind) {
        clearing(tabs, current: current, partners: partner.map { [$0] } ?? [], busy: busy, ages: ages)
    }

    /// The same, with every page beside yours in a split or tile group (`partners`) kept as yours.
    nonisolated static func clearing(_ tabs: [UUID], current: UUID?, partners: [UUID], busy: Set<UUID>,
                                     ages: [UUID: TimeInterval]) -> (ids: Set<UUID>, kind: ClearKind) {
        let groups = current.map { partners.isEmpty ? [] : [[$0] + partners] } ?? []
        return clearing(tabs, current: current, groups: groups, parents: [:], busy: busy, ages: ages)
    }

    /// Clear's choice by id. `groups`: splits and tile groups by page id; a member not in `tabs` (pinned) keeps the
    /// rest open. `parents`: each nested tab's parent. While other tabs remain, even busy ones, yours stay.
    nonisolated static func clearing(_ tabs: [UUID], current: UUID?, groups: [[UUID]], parents: [UUID: UUID],
                                     busy: Set<UUID>, ages: [UUID: TimeInterval]) -> (ids: Set<UUID>, kind: ClearKind) {
        let listed = Set(tabs)
        let pinnedIn = groups.filter { !$0.allSatisfy(listed.contains) }.flatMap { $0 }
        // A unit stays while any page plays, is in a call or is beside a pinned page.
        let held = { (unit: [UUID]) in unit.contains { busy.contains($0) || pinnedIn.contains($0) } }
        // The current tab and every page on screen with it.
        let yours = Set(current.map { id in groups.first { $0.contains(id) } ?? [id] } ?? [])
        let isYours = { (unit: [UUID]) in unit.contains(where: yours.contains) }
        let inGroups = units(tabs, groups: groups, parents: [:])
        let others = inGroups.filter { !isYours($0) }
        guard !others.isEmpty else { return (Set(inGroups.filter { !held($0) }.joined()), .last) }
        // Unused: whole nests, newest first by their newest tab, past the activity break. Your nest counts as yours.
        let age = { (unit: [UUID]) in unit.map { ages[$0, default: 0] }.min() ?? 0 }
        let nests = units(tabs, groups: groups, parents: parents).filter { !isYours($0) && !held($0) }
        let newestFirst = nests.sorted { age($0) < age($1) }
        let unused = Set(newestFirst.dropFirst(keptByActivity(newestFirst.map(age))).joined())
        guard unused.isEmpty else { return (unused, .unused) }
        return (Set(others.filter { !held($0) }.joined()), .others)
    }

    /// Units Clear treats as one, in list order: each split or group, and with `parents` each tab with its nested tabs.
    /// Pages not in `tabs` (pinned) are left out.
    nonisolated static func units(_ tabs: [UUID], groups: [[UUID]], parents: [UUID: UUID]) -> [[UUID]] {
        var root = Dictionary(tabs.map { ($0, $0) }, uniquingKeysWith: { a, _ in a })
        func find(_ id: UUID) -> UUID {
            var id = id
            while let up = root[id], up != id { root[id] = root[up]; id = up }
            return id
        }
        func join(_ a: UUID, _ b: UUID) {
            guard root[a] != nil, root[b] != nil else { return }
            let (ra, rb) = (find(a), find(b))
            if ra != rb { root[rb] = ra }
        }
        for group in groups {
            let pages = group.filter { root[$0] != nil }
            for id in pages.dropFirst() { join(pages[0], id) }
        }
        for (child, parent) in parents { join(parent, child) }
        var order: [UUID] = []
        var members: [UUID: [UUID]] = [:]
        for id in tabs {
            let r = find(id)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(id)
        }
        return order.map { members[$0] ?? [] }
    }

    /// How many tabs to keep as the working set, given ages since last viewed (or opened), newest first. The break is
    /// the biggest ratio jump between neighbors (15m vs 45m equals 1h vs 3h). Ages within an eighth of the span count
    /// as equal, so the threshold scales with the session. Anything under ten minutes counts as now. Only the newest
    /// dozen are checked; a jump under 3x means no break, and the newest five stay.
    nonisolated static func keptByActivity(_ ages: [TimeInterval]) -> Int {
        let clearJump = 3.0, mostAtOnce = 12, keptWithoutBreak = 5
        guard let span = ages.prefix(mostAtOnce + 1).last else { return 0 }
        let floor = max(10 * 60, span / 8)
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
        selectionChanged()
    }

    /// Shows another space's list without leaving the page you're on (used while dragging a tab).
    func showSpaceKeepingPage(_ id: UUID) {
        guard mayShowSpace(id), id != currentSpaceID, Library.shared.space(id) != nil else { return }
        currentSpaceID = id
        changed.send(.space)
    }

    func switchSpace(by offset: Int) {
        let spaces = listedSpaces
        guard let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = index + offset
        guard spaces.indices.contains(next) else { return }
        switchToSpace(spaces[next].id)
    }

    private func libraryDidChange() {
        guard !isInvalidated else { return }
        // Each window handles library changes itself; nothing is relayed.
        isRelaying = true
        defer { isRelaying = false }
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
        // (undo, another window) says so, as does one given an icon.
        for (id, tab) in bookmarkTabs {
            if let space = Library.shared.spaceID(ofBookmark: id) { tab.setSpace(space) }
            tab.isFavorite = Library.shared.isFavorite(id)
            tab.refreshChosenIcon()
        }
        // Pinned pages stop being a pinned split (separated, one made a favorite, undo, another window): the split on
        // screen ends with it.
        let splitCount = splits.count
        // A page that left its pinned split in another window: the rest close up around its place, as they did there.
        for index in splits.indices.reversed() where splits[index].isGroup {
            let pages = splits[index].ids.compactMap { tab(with: $0) }
            let marks = pages.compactMap(\.bookmarkID)
            guard marks.count == pages.count, marks.count == splits[index].count, !groupFits(pages) else { continue }
            guard let kept = marks.lazy.compactMap({ Library.shared.pinnedSplit(containing: $0) })
                .first(where: { Set($0.ids).isStrictSubset(of: marks) }) else { continue }
            for (page, mark) in zip(pages, marks) where !kept.contains(mark) && splits.indices.contains(index) && splits[index].contains(page.id) {
                _ = closeUp(index, without: page)
            }
        }
        // A tile group of more is ordinary tabs of one space or one pinned group's pages, or it ends too.
        splits.removeAll { pair in
            guard let left = tab(with: pair.left), let right = tab(with: pair.right) else { return false }
            if pair.isGroup { return !groupFits(pair.ids.compactMap { tab(with: $0) }) }
            return !canSplit(left, with: right) || left.spaceID != right.spaceID
        }
        if !spaceIDs.contains(currentSpaceID) || !keepsTo(currentSpaceID) {
            currentSpaceID = Self.firstSpace(keepingTo: keepsToProfile)
            changed.send(.space)
            selectionChanged()
        }
        // A space moved to another profile takes its open pages. Favorites stay in their profile, in another of its
        // spaces. (With shared tabs each window gets the change; the first moves them and each re-checks its
        // selection.)
        var reselected = false
        let favorites = Dictionary(bookmarkTabs.values.filter(\.isFavorite).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (space, id) in selectedBySpace {
            guard let tab = favorites[id], Profiles.shared.profile(forSpace: space) !== tab.homeProfile else { continue }
            selectedBySpace[space] = tabs(in: space).first?.id
            reselected = reselected || space == currentSpaceID
        }
        for tab in favorites.values where Profiles.shared.profile(forSpace: tab.spaceID) !== tab.homeProfile {
            if let space = space(for: tab.homeProfile) { tab.setSpace(space) }
        }
        for tab in allTabs { tab.settleProfile() }
        if store.isShared { settleSelection() }
        if reselected { selectionChanged() }
        structureChanged()
        if splits.count != splitCount || shownSignature != shownLastTime { selectionChanged() }
    }

    // MARK: Bookmarks

    /// Opens the bookmark's live tab, creating it on first use. A page of a pinned split or group opens with the
    /// rest of it, side by side again as it was laid out.
    func openBookmark(_ bookmark: Bookmark) {
        let tab = liveTab(for: bookmark)
        if let pinned = Library.shared.pinnedSplit(containing: bookmark.id), split(for: tab)?.count != pinned.ids.count {
            let marks = pinned.ids.compactMap { Library.shared.bookmark($0) }
            if marks.count == pinned.ids.count {
                let pages = marks.map { liveTab(for: $0) }
                pages.forEach { unsplit($0, notify: false) }
                if let pair = pinned.pair(of: pages.map(\.id)) {
                    splits.append(pair)
                    pages.forEach { if $0 !== tab { $0.ensureWebView() } }
                }
                structureChanged()
            }
        }
        // A live folder's new page, opened: read.
        if !isPrivate { LiveFolders.shared.markRead(bookmark: bookmark.id) }
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
        // Told to the extensions before its page loads: a content script that asks its extension about its tab as the
        // page starts (1Password's) otherwise hears "Tab not found".
        if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
        // Opened again after its folder was shut over it: it shows under the folder now, as a page opened there does.
        Library.shared.untuck(bookmark.id)
        structureChanged()
        return tab
    }

    /// Whether pinning pins the whole group (#209): every page has an address.
    func pinsGroup(_ tab: Tab) -> Bool {
        guard tab.bookmarkID == nil, let groupID = tab.groupID, group(groupID) != nil else { return false }
        let members = tabs(inGroup: groupID)
        return !members.isEmpty && members.allSatisfy { $0.url != nil }
    }

    /// Whether pinning this tab pins only pages that can be pinned (#472): its own, and the group's or split's pages
    /// that would be pinned with it. Zigzag's own views never go into Pinned or the favorites.
    func canPin(_ tab: Tab, keepingGroup: Bool = true) -> Bool {
        guard tab.bookmarkID == nil else { return true }
        let pinnable: (Tab) -> Bool = { $0.url.map(SavePath.Page.isPinnable) ?? false }
        guard pinnable(tab) else { return false }
        if keepingGroup, pinsGroup(tab), let groupID = tab.groupID { return tabs(inGroup: groupID).allSatisfy(pinnable) }
        let partners = split(for: tab)?.ids.compactMap { self.tab(with: $0) } ?? []
        return partners.filter { $0.bookmarkID == nil && $0.url != nil }.allSatisfy(pinnable)
    }

    /// Whether pinning this tab pins its split view or tile group with it, every page side by side: all its pages
    /// are tabs with a page, two of them or four.
    func pinsSplit(_ tab: Tab) -> Bool {
        guard tab.bookmarkID == nil, let pair = split(for: tab) else { return false }
        let pages = pair.ids.compactMap { self.tab(with: $0) }
        return pages.count == pair.count && pages.allSatisfy { $0.bookmarkID == nil && $0.url != nil }
    }

    /// Pins a whole tab group (#325) as one folder at a place among the pinned pages; nil if it can't be pinned whole.
    @discardableResult
    func pinGroup(_ id: UUID, at index: Int? = nil, in spaceID: UUID? = nil) -> BookmarkFolder? {
        guard let first = tabs(inGroup: id).first, pinsGroup(first) else { return nil }
        bookmarkTab(first, at: index, in: spaceID)
        return first.bookmarkID.flatMap(Library.shared.pinnedGroup(containing:))
    }

    /// Turns a tab into a bookmark at the given position. Its page stays open behind the bookmark. Half of a split
    /// pins the pair, and a page of a tile group the whole group (#203): every page, side by side as it is, still
    /// open together.
    func bookmarkTab(_ tab: Tab, at index: Int? = nil, in spaceID: UUID? = nil, keepingGroup: Bool = true) {
        guard tab.bookmarkID == nil, let url = tab.url else { return }
        let space = spaceID ?? tab.spaceID
        // A tab group (#209) pins as one named folder, splits kept.
        if keepingGroup, pinsGroup(tab), let groupID = tab.groupID, let group = group(groupID) {
            let members = tabs(inGroup: groupID)
            let memberIDs = Set(members.map(\.id))
            // Split pages in order, as a pinned split stores them.
            var ordered: [Tab] = []
            var placed: Set<UUID> = []
            var pairs: [SplitPair] = []
            for page in members where !placed.contains(page.id) {
                if let pair = split(for: page), pair.ids.allSatisfy(memberIDs.contains) {
                    pairs.append(pair)
                    for id in pair.ids { if let half = self.tab(with: id), placed.insert(id).inserted { ordered.append(half) } }
                } else {
                    placed.insert(page.id)
                    ordered.append(page)
                }
            }
            var markIDs: [UUID: UUID] = [:]
            let marks = ordered.map { page in
                let url = page.url ?? url
                let mark = Bookmark(url: url, title: Self.bookmarkTitle(page.displayTitle, url: url), icon: page.customIcon)
                removeFromList(page)
                page.bookmarkID = mark.id
                page.settleLandingIfLoading()
                page.setSpace(space)
                bookmarkTabs[mark.id] = page
                markIDs[page.id] = mark.id
                return mark
            }
            let layouts = pairs.compactMap { pair in PinnedSplit(pair.ids.compactMap { markIDs[$0] }, as: pair) }
            Library.shared.addPinnedGroup(marks, splits: layouts, named: group.name, group: groupID, isOpen: group.isOpen, to: space, at: index)
            structureChanged()
            return
        }
        if pinsSplit(tab), let pair = split(for: tab) {
            let pages = pair.ids.compactMap { self.tab(with: $0) }
            let marks = pages.map { page in
                let mark = Bookmark(url: page.url ?? url, title: Self.bookmarkTitle(page.displayTitle, url: page.url ?? url), icon: page.customIcon)
                removeFromList(page)
                page.bookmarkID = mark.id
                page.settleLandingIfLoading()
                page.setSpace(space)
                bookmarkTabs[mark.id] = page
                return mark
            }
            if let layout = PinnedSplit(marks.map(\.id), as: pair) {
                Library.shared.addPinnedSplit(marks, as: layout, to: space, at: index)
            } else {
                marks.forEach { Library.shared.addBookmark(url: $0.url, title: $0.title, icon: $0.icon, to: space, at: index, id: $0.id) }
            }
            return
        }
        // A page of a group whose others can't be pinned (one with no page yet) is pinned on its own; the group
        // closes up around its place.
        leaveGroup(tab)
        removeFromList(tab)
        let bookmarkID = UUID()
        tab.bookmarkID = bookmarkID
        tab.settleLandingIfLoading()
        tab.setSpace(space)
        bookmarkTabs[bookmarkID] = tab
        Library.shared.addBookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), icon: tab.customIcon, to: space, at: index, id: bookmarkID)
    }

    /// A tab dropped on a pinned page: it's pinned beside it as a pinned split, where the page is and in its folder.
    /// The page keeps its pin as it is, and the two open side by side.
    func pinSplit(_ tab: Tab, with bookmarkID: UUID, tabOnRight: Bool) {
        guard let space = Library.shared.spaceID(ofBookmark: bookmarkID),
              Self.canSplit(splitSide(of: tab), onto: splitSide(ofBookmark: bookmarkID)),
              let mark = pinInPlace(tab, in: space) else { return }
        Library.shared.pinBeside(mark, bookmarkID, onRight: tabOnRight)
        openBookmark(mark)
    }

    /// A tab out of the list as the live page of a new pinned page of `space`, which the caller puts in the library.
    private func pinInPlace(_ tab: Tab, in space: UUID) -> Bookmark? {
        guard let url = tab.url else { return nil }
        let mark = Bookmark(url: url, title: Self.bookmarkTitle(tab.displayTitle, url: url), icon: tab.customIcon)
        removeFromList(tab)
        tab.bookmarkID = mark.id
        tab.settleLandingIfLoading()
        tab.setSpace(space)
        bookmarkTabs[mark.id] = tab
        return mark
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
    func unbookmark(_ bookmarkID: UUID, toIndex index: Int? = nil, in spaceID: UUID? = nil, under parent: UUID? = nil, group: UUID? = nil) -> Tab? {
        let isFavorite = Library.shared.isFavorite(bookmarkID)
        let space = (isFavorite ? spaceID : nil) ?? Library.shared.spaceID(ofBookmark: bookmarkID) ?? currentSpaceID
        if let group = Library.shared.pinnedGroup(containing: bookmarkID) { return unpin(group, returning: bookmarkID, toIndex: index, in: space) }
        if let pinned = Library.shared.pinnedSplit(containing: bookmarkID) { return unpin(pinned, returning: bookmarkID, toIndex: index, in: space) }
        if isFavorite {
            bookmarkTabs[bookmarkID]?.setSpace(space)
            bookmarkTabs[bookmarkID]?.isFavorite = false
        }
        var result: Tab?
        // Back among the tabs, it keeps the icon it had pinned.
        let icon = Library.shared.bookmark(bookmarkID)?.icon
        if let tab = bookmarkTabs[bookmarkID] {
            bookmarkTabs[bookmarkID] = nil
            tab.customIcon = icon
            tab.bookmarkID = nil
            let at = min(index ?? 0, tabsBySpace[tab.spaceID]?.count ?? 0)
            tab.parentID = TabTree.parent(at: at, preferring: parent, in: treeNodes(in: tab.spaceID))
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
            tab.groupID = group
            result = tab
        } else if let bookmark = Library.shared.bookmark(bookmarkID), let index {
            let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
            tab.customIcon = icon
            tab.host = host
            watch(tab)
            if #available(macOS 15.4, *) { ExtensionCenter.tabOpened(tab) }
            let at = min(index, tabsBySpace[tab.spaceID]?.count ?? 0)
            tab.parentID = TabTree.parent(at: at, preferring: parent, in: treeNodes(in: tab.spaceID))
            tabsBySpace[tab.spaceID, default: []].insert(tab, at: at)
            tab.groupID = group
            result = tab
        }
        Library.shared.removeBookmark(bookmarkID)
        return result
    }

    /// Any page of a pinned split or group unpins all of it, back to tabs side by side as they were laid out. Open
    /// pages come along as they are; one that isn't open opens fresh beside the others.
    private func unpin(_ pinned: PinnedSplit, returning bookmarkID: UUID, toIndex index: Int?, in space: UUID) -> Tab? {
        let anyOpen = pinned.ids.contains { bookmarkTabs[$0] != nil }
        var halves: [(id: UUID, tab: Tab)] = []
        for id in pinned.ids {
            let icon = Library.shared.bookmark(id)?.icon
            if let tab = bookmarkTabs[id] {
                bookmarkTabs[id] = nil
                tab.customIcon = icon
                tab.bookmarkID = nil
                // A split favorite comes back as tabs in the space you're in.
                tab.isFavorite = false
                tab.setSpace(space)
                halves.append((id, tab))
            } else if anyOpen || index != nil, let bookmark = Library.shared.bookmark(id) {
                let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
                tab.customIcon = icon
                tab.host = host
                watch(tab)
                halves.append((id, tab))
            }
        }
        let at = min(index ?? 0, tabsBySpace[space]?.count ?? 0)
        let parent = TabTree.parentForInsertion(at: at, in: treeNodes(in: space))
        halves.forEach { $0.tab.parentID = parent }
        tabsBySpace[space, default: []].insert(contentsOf: halves.map(\.tab), at: at)
        if halves.count == pinned.ids.count, let pair = pinned.pair(of: halves.map(\.tab.id)), split(for: halves[0].tab)?.ids != pair.ids {
            halves.forEach { unsplit($0.tab, notify: false) }
            splits.append(pair)
        }
        Library.shared.removeBookmarks(pinned.ids)
        // A pinned split that was on screen stays there, now as tabs.
        if halves.contains(where: { $0.tab === selectedTab }) { selectionChanged() }
        return halves.first { $0.id == bookmarkID }?.tab
    }

    /// Unpins a pinned group (#209) back into a tab group, with its folder's name and fold state.
    private func unpin(_ folder: BookmarkFolder, returning bookmarkID: UUID, toIndex index: Int?, in space: UUID) -> Tab? {
        let ids = Library.shared.allBookmarkIDs(inFolder: folder.id)
        var pages: [(id: UUID, tab: Tab)] = []
        for id in ids {
            let icon = Library.shared.bookmark(id)?.icon
            if let tab = bookmarkTabs[id] {
                bookmarkTabs[id] = nil
                tab.customIcon = icon
                tab.bookmarkID = nil
                tab.isFavorite = false
                tab.setSpace(space)
                pages.append((id, tab))
            } else if let bookmark = Library.shared.bookmark(id) {
                let tab = Tab(url: bookmark.url, title: bookmark.title, spaceID: space)
                tab.customIcon = icon
                tab.host = host
                watch(tab)
                pages.append((id, tab))
            }
        }
        let at = min(index ?? 0, tabsBySpace[space]?.count ?? 0)
        let parent = TabTree.parentForInsertion(at: at, in: treeNodes(in: space))
        // Restore the original group with the folder's name and fold state.
        let groupID = folder.groupID
        if let groupID { groups[groupID] = TabGroup(id: groupID, name: folder.name, isOpen: folder.isOpen) }
        pages.forEach {
            $0.tab.parentID = parent
            $0.tab.groupID = groupID
        }
        tabsBySpace[space, default: []].insert(contentsOf: pages.map(\.tab), at: at)
        // Reopen pinned splits side by side.
        let tabsByMark = Dictionary(pages.map { ($0.id, $0.tab) }, uniquingKeysWith: { a, _ in a })
        for pinned in Library.shared.pinnedSplits(in: space) where pinned.ids.allSatisfy({ tabsByMark[$0] != nil }) {
            let halves = pinned.ids.compactMap { tabsByMark[$0] }
            guard let pair = pinned.pair(of: halves.map(\.id)) else { continue }
            halves.forEach { unsplit($0, notify: false) }
            splits.append(pair)
        }
        Library.shared.removeBookmarks(ids)
        Library.shared.removeFolder(folder.id)
        structureChanged()
        // If the pinned group was on screen, keep it there as the tab group.
        if pages.contains(where: { $0.tab === selectedTab }) { selectionChanged() }
        return pages.first { $0.id == bookmarkID }?.tab
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
        structureChanged()
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
        let pair = split(for: tab)
        let heir = pair.flatMap { rowHeir(closing: tab, in: $0) }
        // Closing one half of a split shows the other half; one page of a tile group of more, the rest, closed up
        // around its place, and you're in the page that took its room.
        let partnerTab = leaveGroup(tab, notify: false)
        if selectedTab === tab, let partnerTab {
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
            closeKeepingSelection(tab, split: pair, heir: heir)
            selectQuietly(partnerTab)
            return
        }
        let wasSelected = selectedTab === tab
        // The half of a split that wasn't focused: the pane it was in goes too, though the selection stays.
        defer { if pair != nil, !wasSelected { selectionChanged() } }
        if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
        if let bookmarkID = tab.bookmarkID {
            // Closing a pinned page closes it, wherever it had got to: one ⌘W, never two. The pin stays, and
            // opens fresh at its own address next time.
            bookmarkTabs[bookmarkID] = nil
            recentTabIDs.removeAll { $0 == tab.id }
            store.unwatch(tab.id)
            tab.close()
            structureChanged()
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
        if let heir { move(heir, toListIndex: index, in: tab.spaceID) }
        recentTabIDs.removeAll { $0 == tab.id }
        store.unwatch(tab.id)
        tab.close()
        structureChanged()
        if wasSelected { selectAfterClosing(tab, index: index) }
    }

    /// The page that takes a split's row when the page the row is at closes alone (#404): nil when it stays put.
    private func rowHeir(closing tab: Tab, in pair: SplitPair) -> Tab? {
        guard tab.bookmarkID == nil, let list = tabsBySpace[tab.spaceID],
              !pair.ids.contains(where: { id in bookmarkTabs.values.contains { $0.id == id } }) else { return nil }
        let listed = pair.ids.filter { id in list.contains { $0.id == id } }
        guard listed.first == tab.id, listed.count > 1, !closingTogether.contains(listed[1]),
              let heir = list.first(where: { $0.id == listed[1] }), heir.groupID == tab.groupID, heir.parentID == tab.parentID else { return nil }
        return heir
    }

    /// Puts a tab at a place in its space's list, as counted without it.
    private func move(_ tab: Tab, toListIndex index: Int, in spaceID: UUID) {
        guard var list = tabsBySpace[spaceID], let from = list.firstIndex(where: { $0 === tab }) else { return }
        list.remove(at: from)
        list.insert(tab, at: min(index, list.count))
        tabsBySpace[spaceID] = list
    }

    /// Tabs closing in one `close(_:)` of several: none moves to take another's place.
    private var closingTogether: Set<UUID> = []

    /// Removes a tab without choosing a new selection (the caller does).
    private func closeKeepingSelection(_ tab: Tab, split pair: SplitPair? = nil, heir: Tab? = nil) {
        if let bookmarkID = tab.bookmarkID {
            bookmarkTabs[bookmarkID] = nil
        } else if var list = tabsBySpace[tab.spaceID], let index = list.firstIndex(where: { $0 === tab }) {
            closedTabs.append(closedRecord(of: tab, at: index, split: pair))
            liftChildren(of: tab)
            list.remove(at: index)
            tabsBySpace[tab.spaceID] = list
            if let heir { move(heir, toListIndex: index, in: tab.spaceID) }
        }
        recentTabIDs.removeAll { $0 == tab.id }
        store.unwatch(tab.id)
        tab.close()
        structureChanged()
    }

    private func closedRecord(of tab: Tab, at index: Int, split pair: SplitPair?) -> ClosedTab {
        ClosedTab(tab, at: index, split: pair, childIDs: tabs(in: tab.spaceID).filter { $0.parentID == tab.id }.map(\.id))
    }

    /// Returns the ordinary tabs' ids in the order they closed: reopening in reverse puts each back where it was.
    @discardableResult
    func close(_ tabs: [Tab]) -> [UUID] {
        let selected = selectedTab
        let closingSelected = tabs.contains { $0 === selected }
        let order = tabs.filter { $0 !== selected } + (closingSelected ? [selected].compactMap { $0 } : [])
        let ids = order.filter { $0.bookmarkID == nil }.map(\.id)
        closedLimit = max(closedLimit, ids.count + 50)
        closingTogether = Set(order.map(\.id))
        defer { closingTogether = [] }
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
        structureChanged()
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

    /// After closing the current tab, as in Chrome: opened from another tab since you last switched, the next tab
    /// that one opened, else the opener; otherwise the tab below, else the one above. A pinned page or favorite
    /// goes to its opener, else the tab you were on before, else the top tab. With shared tabs (#162), prefer one no
    /// other window shows; if none, show a placeholder for it.
    private func selectAfterClosing(_ closed: Tab, index: Int) {
        let list = tabs(in: closed.spaceID)
        let recent = recentTabs
        let before = { (tab: Tab) in tab !== closed && tab.spaceID == closed.spaceID && !tab.isClosed }
        let openerCounts = openedSinceSwitch.remove(closed.id) != nil
        if closed.bookmarkID == nil, let next = heir(closing: closed, at: index, in: list, openerCounts: openerCounts) {
            selectQuietly(next, claiming: false)
        } else if closed.bookmarkID != nil, let opener = closed.opener, list.contains(where: { $0 === opener }), !isShownElsewhere(opener) {
            selectQuietly(opener, claiming: false)
        } else if closed.bookmarkID != nil, !leavesSpaceEmpty,
                  let previous = recent.first(where: { before($0) && !isShownElsewhere($0) }) ?? recent.first(where: before) {
            selectQuietly(previous, claiming: false)
        } else if !list.isEmpty {
            let near = list[min(index, list.count - 1)]
            selectQuietly(isShownElsewhere(near) ? list.first { !isShownElsewhere($0) } ?? near : near, claiming: false)
        } else if !leavesSpaceEmpty, let recent = recent.first(where: { $0.spaceID == closed.spaceID }) {
            selectQuietly(recent, claiming: false)
        } else {
            selectedBySpace[closed.spaceID] = nil
            selectionChanged()
        }
    }

    /// Chrome's choice after closing an ordinary tab that stood at `index` in `list` (as it is without it).
    private func heir(closing closed: Tab, at index: Int, in list: [Tab], openerCounts: Bool) -> Tab? {
        let free = { (tab: Tab) in !tab.isClosed && !self.isShownElsewhere(tab) }
        if openerCounts, let opener = closed.opener, !opener.isClosed, opener.spaceID == closed.spaceID,
           self.tab(with: opener.id) === opener {
            let siblings = list.indices.filter { list[$0].opener === opener && openedSinceSwitch.contains(list[$0].id) && free(list[$0]) }
            if let at = siblings.first(where: { $0 >= index }) ?? siblings.last { return list[at] }
            if free(opener) { return opener }
        }
        let start = min(index, list.count)
        let shown = { (tab: Tab) in free(tab) && !self.isFoldedAway(tab) }
        return list[start...].first(where: shown) ?? list[..<start].reversed().first(where: shown)
    }

    /// Out of sight in the sidebar: in a shut group, or under a folded tab.
    private func isFoldedAway(_ tab: Tab) -> Bool {
        if let group = tab.groupID, groups[group]?.isOpen == false { return true }
        var parent = tab.parentID
        var steps = 0
        while let id = parent, steps < 64, let up = self.tab(with: id) {
            if up.isCollapsed { return true }
            parent = up.parentID
            steps += 1
        }
        return false
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// The latest closed tab here, by when it closed: windows that came to share tabs keep theirs in turn.
    var lastClosedTab: ClosedTab? {
        guard let latest = closedTabs.map(\.closedAt).max() else { return nil }
        return closedTabs.last { $0.closedAt == latest }
    }

    /// The closed tabs, oldest first, to keep once this window closes (`WindowManager.reopenLastClosed`).
    var closedTabRecords: [ClosedTab] { closedTabs }

    /// A tab closed in a window since closed, brought back here: in its own space if that's still there, on its own,
    /// since its split, group and tree stayed with that window.
    @discardableResult
    func reopenFromClosedWindow(_ record: ClosedTab) -> Tab? {
        var closed = record
        closed.split = nil
        closed.parentID = nil
        closed.childIDs = []
        closed.groupID = nil
        closedTabs.append(closed)
        return reopenClosedTab(closed.id)
    }

    /// Closed tabs with a page, newest first, for History › Recently Closed; reopen with `reopenClosedTab(id)`.
    var recentlyClosedTabs: [(id: UUID, url: URL, title: String)] {
        closedTabs.reversed().compactMap { closed in closed.url.map { (closed.id, $0, closed.customTitle ?? closed.title) } }
    }

    @discardableResult
    /// The latest closed tab (⇧⌘T), or, with an id, that one (⌘Z after closing it).
    func reopenClosedTab(_ id: UUID? = nil, select: Bool = true) -> Tab? {
        let found: Int? = id.map { id in closedTabs.lastIndex { $0.id == id } } ?? (closedTabs.isEmpty ? nil : closedTabs.count - 1)
        guard let index = found else { return nil }
        let closed = closedTabs.remove(at: index)
        let space = Library.shared.space(closed.spaceID) != nil ? closed.spaceID : currentSpaceID
        let tab = Tab(url: closed.url, title: closed.title, spaceID: space, interactionState: closed.interactionState,
                      lastActivated: closed.lastActivated)
        closed.apply(to: tab)
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
        // Back in its group, restoring the group if it was removed.
        tab.groupID = space == closed.spaceID ? closed.groupID.flatMap(regroup) : nil
        // A reopened tab is a new tab: its partner, closed with it and back first, is found by the id it had.
        reopenedAs[closed.id] = tab.id
        if reopenedAs.count > 500 { reopenedAs = [closed.id: tab.id] }
        // Half of a split: back beside its partner, on the same side and at the same size, if that's still free.
        if let pair = closed.split { rejoin(tab, was: closed.id, in: pair, space: space) }
        structureChanged()
        if select { self.select(tab) } else { recentTabIDs.insert(tab.id, at: min(1, recentTabIDs.count)) }
        return tab
    }

    // MARK: Moving

    /// A tab back in the list (reopened, or back from Zigzag Mini) goes back into the split or tile group it left,
    /// `oldID` being the id it had there. Half of a split: back beside its partner, on the same side and at the same
    /// size, if that's still free. A page of a tile group of more: back in its place, if the rest are still together
    /// as it left them.
    private func rejoin(_ tab: Tab, was oldID: UUID, in pair: SplitPair, space: UUID) {
        if pair.isGroup {
            let others = pair.ids.filter { $0 != oldID }
            let now = others.map { reopenedAs[$0] ?? $0 }
            let pages = now.compactMap { self.tab(with: $0) }
            if pages.count == now.count, pages.allSatisfy({ $0.spaceID == space && $0.bookmarkID == nil }),
               let current = split(for: pages[0]), Set(current.ids) == Set(now) {
                var restored = pair
                restored.replace(oldID, with: tab.id)
                for (old, new) in zip(others, now) { restored.replace(old, with: new) }
                splits.removeAll { $0.contains(pages[0].id) }
                splits.append(restored)
            }
            return
        }
        let otherID = pair.left == oldID ? pair.right : pair.left
        if let other = self.tab(with: reopenedAs[otherID] ?? otherID), other.spaceID == space, split(for: other) == nil, canSplit(tab, with: other) {
            var restored = pair
            let onLeft = pair.left == oldID
            restored.left = onLeft ? tab.id : other.id
            restored.right = onLeft ? other.id : tab.id
            splits.append(restored)
        }
    }

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

    /// A tab moves with its nested tabs. `index` counts the list without them; a spot among its own nested tabs means
    /// just after them. To another space it moves alone and its nested tabs move up a level.
    /// How a move treats a tab's group (#209): `fit` keeps it if it lands beside the group, else joins the group it
    /// lands in; `into` puts it in that group (nil: none).
    enum Grouping: Equatable {
        case fit
        case into(UUID?)
    }

    func move(_ tab: Tab, to index: Int, in spaceID: UUID? = nil, nesting: Nesting = .fit, grouping: Grouping = .fit) {
        guard tab.bookmarkID == nil else { return }
        // Moving to another space leaves the group unless one is given.
        let joining: UUID? = if case .into(let group) = grouping { group } else { nil }
        let target = spaceID ?? tab.spaceID
        // A split of two tabs (or a tile group of more) goes to another space as one, still side by side.
        let panes = self.panes(of: tab)
        if target != tab.spaceID, panes.count > 1, panes.count == split(for: tab)?.count, panes.allSatisfy({ $0.bookmarkID == nil }) {
            let halves = panes
            halves.forEach { removeFromList($0) }
            for half in halves {
                half.setSpace(target)
                for (space, id) in selectedBySpace where id == half.id && space != target { selectedBySpace[space] = nil }
            }
            var list = tabsBySpace[target] ?? []
            let at = max(0, min(index, list.count))
            let parent = TabTree.parentForInsertion(at: at, in: treeNodes(in: target))
            halves.forEach { $0.parentID = parent; $0.groupID = joining }
            list.insert(contentsOf: halves, at: at)
            tabsBySpace[target] = list
            structureChanged()
            return
        }
        if target != tab.spaceID {
            // A split with a pinned page can't span two spaces: moving the tab out ends it.
            splits.removeAll { $0.contains(tab.id) }
            removeFromList(tab)
            tab.setSpace(target)
            var list = tabsBySpace[target] ?? []
            let at = max(0, min(index, list.count))
            tab.parentID = TabTree.parentForInsertion(at: at, in: treeNodes(in: target))
            tab.groupID = joining
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
            switch grouping {
            case .into(let group): tab.groupID = group
            case .fit:
                // Stays in the group if still beside its tabs, else leaves it.
                let list = tabs(in: target)
                if let group = tab.groupID, let start = list.firstIndex(where: { $0 === tab }) {
                    let end = TabTree.subtreeEnd(at: start, in: treeNodes(in: target))
                    let beside = (start > 0 && list[start - 1].groupID == group) || (end < list.count && list[end].groupID == group)
                    if !beside { tab.groupID = nil }
                }
            }
        }
        // No other space keeps it selected, whichever one is showing.
        for (space, id) in selectedBySpace where id == tab.id && space != target { selectedBySpace[space] = nil }
        structureChanged()
    }

    /// Into another space: at `index` where it was dropped, else at the top.
    func moveTabToSpace(_ tab: Tab, spaceID: UUID, at index: Int = 0, grouping: Grouping = .fit) {
        // A window that keeps to one profile keeps its tabs in its spaces: elsewhere they'd be out of sight.
        guard keepsTo(spaceID) else { return }
        // Either half of a split moving together counts: the page you were on leaves with it.
        let wasSelected = panes(of: tab).contains { selectedTab === $0 }
        let oldIndex = tabs(in: tab.spaceID).firstIndex { $0 === tab } ?? 0
        move(tab, to: index, in: spaceID, grouping: grouping)
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

    /// Pages side by side: a split of two, or a tile group of up to four (#160, see `TileShape`). The first two are
    /// `left` and `right` (top and bottom, stacked), as a split always had them, so a session saved with a group
    /// opens in an older Zigzag as a split of its first two pages.
    nonisolated struct SplitPair: Codable, Equatable, Sendable {
        var left: UUID
        var right: UUID
        /// Share of the width (or height, when vertical) the first pane gets. In a group of more, the share of the
        /// width left of the line between the columns.
        var ratio: Double = 0.5
        /// Stacked top and bottom instead of side by side.
        var vertical = false
        /// A tile group's third and fourth pages.
        var more: [UUID] = []
        /// Where each page of a group of more than two sits, in `ids` order; nil for two, whose halves `vertical` says.
        var regions: [TileRegion]? = nil
        /// The other line's share: in a group of more, of the height above the line between the rows; with two,
        /// kept for when a third comes.
        var otherRatio: Double = 0.5
        /// A group's own lines (#316): the line between the columns in the top row and in the bottom, then the line
        /// between the rows in the left column and in the right. Nil for two, whose one line each `ratio` and
        /// `vertical` say, and for a group saved before its rows had lines of their own.
        var shares: [Double]? = nil

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
            otherRatio = (try? c.decodeIfPresent(Double.self, forKey: .otherRatio)) ?? 0.5
            // A group whose pages or places don't add up opens as the split of its first two.
            let more = ((try? c.decodeIfPresent([UUID].self, forKey: .more)) ?? nil) ?? []
            let regions = (try? c.decodeIfPresent([TileRegion].self, forKey: .regions)) ?? nil
            if !more.isEmpty, let regions, regions.count == more.count + 2, TileShape.isValid(regions),
               Set([left, right] + more).count == more.count + 2 {
                self.more = more
                self.regions = regions
                shares = ((try? c.decodeIfPresent([Double].self, forKey: .shares)) ?? nil).flatMap { $0.count == 4 ? $0 : nil }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case left, right, ratio, vertical, more, regions, otherRatio, shares
        }
    }

    /// Splits and tile groups, stored as list rows so sharing windows see them too.
    private(set) var splits: [SplitPair] {
        get { store.splits }
        _modify { yield &store.splits }
    }

    func split(for tab: Tab) -> SplitPair? {
        splits.first { $0.contains(tab.id) }
    }

    /// The other page of a split of two. Nil in a tile group of more, whose pages are `partners(of:)`: what goes for
    /// a pair (pinning both, a pinned page beside a tab) doesn't for those.
    func partner(of tab: Tab) -> Tab? {
        guard let pair = split(for: tab), !pair.isGroup else { return nil }
        return self.tab(with: pair.left == tab.id ? pair.right : pair.left)
    }

    /// The other pages on screen with this one: a split's other half, or the rest of a tile group, in order.
    func partners(of tab: Tab) -> [Tab] {
        guard let pair = split(for: tab) else { return [] }
        return pair.ids.filter { $0 != tab.id }.compactMap { self.tab(with: $0) }
    }

    /// This page and the ones beside it, in the group's order; only this one when it's alone.
    func panes(of tab: Tab) -> [Tab] {
        guard let pair = split(for: tab) else { return [tab] }
        let panes = pair.ids.compactMap { self.tab(with: $0) }
        return panes.contains { $0 === tab } ? panes : [tab]
    }

    /// Whether `tab` may come into the group `current` is in (or beside `current` alone) by a drop on the page: a tab
    /// of its own with a page; into a group of three or four, only among ordinary tabs of one space. A pinned page's
    /// pair stays a pair.
    func canTile(_ tab: Tab, beside current: Tab) -> Bool {
        guard tab !== current, split(for: tab) == nil, tab.url != nil else { return false }
        guard let pair = split(for: current) else {
            return canSplit(tab, with: current) && Self.canSplit(splitSide(of: tab), onto: splitSide(of: current))
        }
        let panes = pair.ids.compactMap { self.tab(with: $0) }
        return tab.bookmarkID == nil && panes.count == pair.count && panes.allSatisfy { $0.bookmarkID == nil && $0.spaceID == current.spaceID }
    }

    /// A sidebar row a page is dropped on, or the page dropped: a tab's, or a pinned page's.
    enum RowPage: Equatable {
        case tab(UUID)
        case pinned(UUID)
    }

    /// How `tab` joins `target`'s split when dropped on its sidebar row (`onRight`: right half); nil if not a split,
    /// full, or the page can't tile.
    func joining(_ tab: Tab, onto target: Tab, onRight: Bool) -> TileDrop.Kind? {
        joining(.tab(tab.id), onto: .tab(target.id), onRight: onRight)
    }

    /// How a page joins the split a sidebar row shows when dropped on it (`onRight`: right half), up to four pages: a
    /// tab into a split of tabs; a tab or a pinned page of that space on its own into a pinned split, pinned there.
    /// Nil if the row isn't a split, it's full, or the page can't come in.
    func joining(_ page: RowPage, onto target: RowPage, onRight: Bool) -> TileDrop.Kind? {
        switch (page, target) {
        case let (.tab(id), .tab(targetID)):
            guard let tab = self.tab(with: id), let other = self.tab(with: targetID), let pair = split(for: other), canTile(tab, beside: other) else { return nil }
            return TileShape.joining(pair.shape.regions, onRight: onRight)
        case (_, .pinned(let targetID)):
            guard !isPrivate, let pinned = Library.shared.pinnedSplit(containing: targetID), !Library.shared.isFavorite(targetID),
                  let space = Library.shared.spaceID(ofBookmark: targetID) else { return nil }
            switch page {
            case .tab(let id):
                guard let tab = self.tab(with: id), tab.bookmarkID == nil, tab.url != nil, split(for: tab) == nil, canPin(tab, keepingGroup: false) else { return nil }
            case .pinned(let id):
                guard !pinned.contains(id), Library.shared.spaceID(ofBookmark: id) == space, !Library.shared.isFavorite(id),
                      !splitSide(ofBookmark: id).inSplit else { return nil }
            }
            return TileShape.joining(pinned.shape.regions, onRight: onRight)
        case (.pinned, .tab):
            return nil
        }
    }

    /// A page dropped on a split's sidebar row joins it where `joining` said: a tab tiles in among tabs; into a pinned
    /// split, a tab is pinned there and a pinned page moves there, and the whole split opens side by side.
    func join(_ page: RowPage, onto target: RowPage, _ kind: TileDrop.Kind) {
        switch (page, target) {
        case let (.tab(id), .tab(targetID)):
            guard let tab = self.tab(with: id), let other = self.tab(with: targetID) else { return }
            tile(tab, beside: other, kind)
        case (_, .pinned(let targetID)):
            guard let space = Library.shared.spaceID(ofBookmark: targetID) else { return }
            let mark: Bookmark?
            switch page {
            case .tab(let id): mark = self.tab(with: id).flatMap { pinInPlace($0, in: space) }
            case .pinned(let id): mark = Library.shared.bookmark(id)
            }
            guard let mark else { return }
            Library.shared.joinPinnedSplit(mark, onto: targetID, kind)
            if let page = Library.shared.bookmark(mark.id) { openBookmark(page) }
        case (.pinned, .tab):
            return
        }
    }

    /// `tab` into the group on screen with `current`, where `drop` puts it (`TileDrop`): beside a page alone, the two
    /// make a split. A page it takes the place of goes back to being a tab of its own, where it is in the list.
    func tile(_ tab: Tab, beside current: Tab, _ drop: TileDrop.Kind) {
        guard canTile(tab, beside: current) else { return }
        guard let index = splits.firstIndex(where: { $0.contains(current.id) }) else {
            guard let pair = SplitPair.pair(current.id, tab.id, drop) else { return }
            makeSplit(current, with: tab, otherOnRight: pair.right == tab.id, vertical: pair.vertical)
            return
        }
        guard let grown = splits[index].adding(tab.id, drop) else { return }
        if tab.spaceID != current.spaceID {
            removeFromList(tab)
            tab.setSpace(current.spaceID)
            tabsBySpace[current.spaceID, default: []].insert(tab, at: 0)
        }
        liftToTopLevel(tab)
        splits[index] = grown
        tab.ensureWebView()
        structureChanged()
        select(tab)
    }

    /// Takes one page out of its tile group, which closes up around the gap; out of a split of two, the split ends.
    /// The page that takes its room is returned (nil if none).
    @discardableResult
    func leaveGroup(_ tab: Tab, notify: Bool = true) -> Tab? {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return nil }
        let pair = splits[index]
        // A group of three or four closes up around its place, pinned or not; a split of two ends.
        guard pair.isGroup else {
            unsplit(tab, notify: notify)
            return pair.ids.first { $0 != tab.id }.flatMap { self.tab(with: $0) }
        }
        let taker = closeUp(index, without: tab)
        if notify {
            structureChanged()
            selectionChanged()
        }
        return taker
    }

    /// Split `index` without `tab`, the rest closed up around its place (a split of two ends); the page that grew
    /// over its room is returned.
    private func closeUp(_ index: Int, without tab: Tab) -> Tab? {
        let pair = splits[index]
        guard let rest = pair.removing(tab.id) else {
            splits.remove(at: index)
            return pair.ids.first { $0 != tab.id }.flatMap { self.tab(with: $0) }
        }
        splits[index] = rest
        // The page that grew over its room: the one whose place now covers part of where it was.
        let gone = pair.shape.regions[pair.ids.firstIndex(of: tab.id) ?? 0].cells
        let shape = rest.shape
        let taker = rest.ids.indices.first { shape.regions[$0].cells & gone != 0 } ?? 0
        return self.tab(with: rest.ids[taker])
    }

    /// One pinned page out of its pinned split, as `leaveGroup` takes a tab out of a group of tabs: it stays pinned on
    /// its own, and the rest stay one pinned split, closed up around its place, on screen too; of two, the other is a
    /// pinned page on its own. The page that grew over its room on screen is returned.
    @discardableResult
    func leavePinnedGroup(_ bookmarkID: UUID) -> Tab? {
        guard Library.shared.pinnedSplit(containing: bookmarkID) != nil else { return nil }
        // On screen first, so the group there still matches its pinned one once the library changes.
        var taker: Tab?
        if let tab = bookmarkTabs[bookmarkID], let index = splits.firstIndex(where: { $0.contains(tab.id) }) {
            taker = closeUp(index, without: tab)
        }
        Library.shared.removeFromPinnedSplit(bookmarkID)
        structureChanged()
        selectionChanged()
        return taker
    }

    /// Two to four tabs of one space side by side as a tile group laid out as `shape`, ending any splits they were in
    /// (the debug bridge's way to make one; a drop builds one a page at a time).
    func makeGroup(_ tabs: [Tab], shape: TileShape) {
        guard tabs.count >= 2, tabs.allSatisfy({ $0.bookmarkID == nil && $0.spaceID == tabs[0].spaceID }),
              let pair = SplitPair(ids: tabs.map(\.id), shape: shape) else { return }
        tabs.forEach { unsplit($0, notify: false) }
        tabs.forEach { liftToTopLevel($0) }
        splits.append(pair)
        tabs.forEach { $0.ensureWebView() }
        structureChanged()
        select(tabs[tabs.count - 1])
    }

    /// Whether a tile group's pages may stay side by side: ordinary tabs of one space, or pages of one pinned or
    /// favorite group (some may be unloaded, the rest closed up).
    private func groupFits(_ pages: [Tab]) -> Bool {
        guard let first = pages.first else { return false }
        if pages.allSatisfy({ $0.bookmarkID == nil }) { return pages.allSatisfy { $0.spaceID == first.spaceID } }
        let marks = pages.compactMap(\.bookmarkID)
        guard marks.count == pages.count, let pinned = Library.shared.pinnedSplit(containing: marks[0]) else { return false }
        return Set(marks).count == marks.count && Set(marks).isSubset(of: pinned.ids)
    }

    /// Ordinary tabs split, the two pinned pages of a pinned split, and a pinned page with a tab: the pinned page's
    /// row carries that pair. A favorite belongs to every space, and two pinned pages to rows of their own, so neither
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

    /// Puts `other` beside `tab` (on the right or left, or below or above, stacked), ending any splits either was in.
    func makeSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool = true, vertical: Bool = false) {
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
        var pair = otherOnRight ? SplitPair(left: tab.id, right: other.id) : SplitPair(left: other.id, right: tab.id)
        pair.vertical = vertical
        splits.append(pair)
        Tutorial.complete("split")
        other.ensureWebView()
        structureChanged()
        select(other)
    }

    /// A tab a link opened in a split took its opener's pane; going back from it puts the opener back there.
    func returnPane(of tab: Tab, to opener: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }), split(for: opener) == nil,
              canSplit(tab, with: opener), opener.spaceID == tab.spaceID else { return }
        splits[index].replace(tab.id, with: opener.id)
        opener.ensureWebView()
    }

    /// Ends the split or tile group the tab is in: its pages each a tab of its own again.
    func unsplit(_ tab: Tab, notify: Bool = true) {
        let before = splits.count
        splits.removeAll { $0.contains(tab.id) }
        if notify, splits.count != before {
            structureChanged()
            selectionChanged()
        }
    }

    /// Takes one pane out of its split and shows the other on its own.
    func unsplit(_ tab: Tab, keep other: Tab) {
        unsplit(tab, notify: false)
        structureChanged()
        select(other)
    }

    /// A split of two only: a tile group's pages keep their places.
    func toggleSplitOrientation(for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }), !splits[index].isGroup else { return }
        splits[index].vertical.toggle()
        rememberPinnedLayout(splits[index])
        selectionChanged()
    }

    /// The two pages trade places; each keeps the size it had.
    func swapSplit(for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }), !splits[index].isGroup else { return }
        let pair = splits[index]
        splits[index].left = pair.right
        splits[index].right = pair.left
        splits[index].ratio = 1 - pair.ratio
        rememberPinnedLayout(splits[index])
        structureChanged()
        // The panes on screen trade places too, or clicks and find go to the page that was there.
        selectionChanged()
    }

    /// Where the lines between a tile group's pages are (shares of the width and height); a split of two takes the
    /// one it has.
    func setTileRatios(column: CGFloat, row: CGFloat, for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        splits[index].setRatios(column: min(max(column, 0.2), 0.8), row: min(max(row, 0.2), 0.8))
        rememberPinnedLayout(splits[index])
    }

    /// Where each of a tile group's lines between its pages is, as the page area's shares (#316): each row's line
    /// between the columns and each column's between the rows.
    func setTileShape(_ shape: TileShape, for tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        splits[index].setLines(of: shape)
        rememberPinnedLayout(splits[index])
    }

    /// The group `old` laid out again as `new`, the same pages in other places (a pane dragged by its strip, and ⌘Z
    /// putting it back). False if that group isn't on screen as `old` left it.
    @discardableResult
    func rearrange(_ old: SplitPair, to new: SplitPair) -> Bool {
        guard Set(old.ids) == Set(new.ids), let index = splits.firstIndex(where: { $0.ids == old.ids && $0.shape.regions == old.shape.regions }) else { return false }
        splits[index] = new
        rememberPinnedLayout(new)
        structureChanged()
        selectionChanged()
        return true
    }

    /// A pinned split or group keeps how it was last laid out, so it opens that way again.
    private func rememberPinnedLayout(_ pair: SplitPair) {
        let marks = pair.ids.compactMap { tab(with: $0)?.bookmarkID }
        guard marks.count == pair.count, let layout = PinnedSplit(marks, as: pair) else { return }
        Library.shared.setPinnedSplitLayout(layout)
    }

    /// Puts back a split exactly as it was (undo).
    func restoreSplit(_ pair: SplitPair) {
        let pages = pair.ids.compactMap { tab(with: $0) }
        guard pages.count == pair.count else { return }
        pages.forEach { unsplit($0, notify: false) }
        splits.append(pair)
        structureChanged()
        selectionChanged()
    }

    /// The splits and groups a session saved, those whose pages all came back and may still be side by side.
    func restoreSplits(_ pairs: [SplitPair]) {
        // Leave other sharing windows' splits alone (#162).
        var placed = Set(splits.flatMap(\.ids))
        splits += pairs.filter { pair in
            let pages = pair.ids.compactMap { tab(with: $0) }
            guard pages.count == pair.count, placed.isDisjoint(with: pair.ids) else { return false }
            let fits = pair.isGroup ? groupFits(pages) : canSplit(pages[0], with: pages[1])
            if fits { placed.formUnion(pair.ids) }
            return fits
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
        /// Group per grouped tab, and the groups (#209).
        fileprivate var groupOf: [UUID: UUID] = [:]
        fileprivate var groups: [UUID: TabGroup] = [:]

        /// Names of the groups in use: a rename counts as a change, folding doesn't.
        fileprivate var groupNames: [UUID: String] { Dictionary(Set(groupOf.values).map { ($0, groups[$0]?.name ?? "") }, uniquingKeysWith: { a, _ in a }) }

        /// The same tabs in the same places, whatever else opened since; selection and split sizes don't count.
        fileprivate func matches(_ now: Arrangement) -> Bool {
            let ids = Set(tabs.keys)
            return lists.filter { !$0.value.isEmpty } == now.lists.mapValues { $0.filter(ids.contains) }.filter { !$0.value.isEmpty }
                && pinned == now.pinned.filter { ids.contains($0.value) }
                && pairs == now.pairs.filter { $0.allSatisfy(ids.contains) }
                && parents == now.parents.filter { ids.contains($0.key) }
                && groupOf == now.groupOf.filter { ids.contains($0.key) }
                && groupNames.allSatisfy { now.groups[$0.key]?.name == $0.value }
                && now.tabs.keys.filter(ids.contains).count == ids.count
        }

        /// The same tabs, in the same places.
        func isSame(as other: Arrangement) -> Bool { matches(other) && other.matches(self) }
    }

    var arrangement: Arrangement {
        let tabs = allTabs
        return Arrangement(lists: tabsBySpace.mapValues { $0.map(\.id) }, pinned: bookmarkTabs.mapValues(\.id),
                           pairs: splits.map(\.ids), splits: splits,
                           tabs: Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                           spaces: Dictionary(tabs.map { ($0.id, $0.spaceID) }, uniquingKeysWith: { a, _ in a }), selected: selectedBySpace,
                           parents: Dictionary(tabs.compactMap { tab in tab.parentID.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a }),
                           groupOf: Dictionary(tabs.compactMap { tab in tab.groupID.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a }),
                           groups: groups)
    }

    /// Whether the tabs `done` placed are still where it left them.
    func isUnchanged(since done: Arrangement) -> Bool { done.matches(arrangement) }

    /// Puts the tabs back as `target` had them, undoing `done`: tabs `done` made are closed, ones opened since stay.
    func restore(_ target: Arrangement, undoing done: Arrangement) {
        let now = arrangement
        for (id, tab) in now.tabs where target.tabs[id] == nil && done.tabs[id] != nil {
            tab.close()
            store.unwatch(id)
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
            tab.groupID = tab.bookmarkID == nil ? target.groupOf[id] : nil
        }
        // Restore groups as saved but with current fold state; groups of newer tabs stay.
        var restored = target.groups
        for (id, group) in groups { if restored[id] != nil { restored[id]?.isOpen = group.isOpen } else { restored[id] = group } }
        groups = restored
        for space in Array(tabsBySpace.keys) { repairTree(in: space) }
        splits = target.splits.filter { $0.ids.allSatisfy { alive[$0] != nil } }
            + now.splits.filter { $0.ids.contains { since[$0] != nil } }
        for (space, id) in target.selected where alive[id] != nil { selectedBySpace[space] = id }
        selectedBySpace = selectedBySpace.filter { tab(with: $0.value) != nil }
        structureChanged()
        selectionChanged()
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

    /// What closing this tab closes: with the tabs under it folded away, all of them too, in list order (#155); else
    /// it alone, and they move up a level.
    func closing(_ tab: Tab) -> [Tab] {
        guard tab.bookmarkID == nil else { return [tab] }
        let ids = TabTree.closing(tab.id, folded: tab.isCollapsed, in: treeNodes(in: tab.spaceID))
        let byID = Dictionary(tabs(in: tab.spaceID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.count > 1 ? ids.compactMap { byID[$0] } : [tab]
    }

    /// Folds the tabs under this one away in the sidebar, or shows them again.
    func setNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) {
        guard tab.isCollapsed != collapsed else { return }
        tab.isCollapsed = collapsed
        structureChanged()
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

    // MARK: Groups of tabs

    /// Tabs were added, removed or moved: normalize each group to one run (`TabGroups`), drop empty groups, then
    /// notify.
    func structureChanged() {
        settleGroups()
        changed.send(.structure)
        // Sharing windows (#162) redraw too.
        guard !isBatching, !isRelaying, store.isShared else { return }
        for other in store.managers where other !== self { other.listChanged() }
    }

    private func settleGroups() {
        for tab in bookmarkTabs.values { tab.groupID = nil }
        guard !groups.isEmpty || tabsBySpace.values.contains(where: { $0.contains { $0.groupID != nil } }) else { return }
        var claimed: [UUID: UUID] = [:]
        let pinnedPages = Set(bookmarkTabs.values.map(\.id))
        for (space, list) in tabsBySpace {
            // A group belongs to one space; its tabs elsewhere are ungrouped.
            let known = Set(groups.keys).filter { claimed[$0] == nil || claimed[$0] == space }
            // Pages drawn in another tab's row: split partners (in the first tab's row) and pinned-page partners (no
            // group).
            var riders: [UUID: UUID?] = [:]
            let ids = Set(list.map(\.id))
            for pair in splits where !ids.isDisjoint(with: pair.ids) {
                let lead = pair.ids.first(where: ids.contains)
                let pinned = pair.ids.contains(where: pinnedPages.contains)
                for id in pair.ids where ids.contains(id) && (pinned || id != lead) { riders[id] = pinned ? .some(nil) : lead }
            }
            let settled = TabGroups.settled(treeNodes(in: space), groups: groupIDs(in: space), riders: riders, known: known)
            for tab in list { tab.groupID = settled[tab.id] }
            for group in Set(settled.values) { claimed[group] = space }
        }
        for (id, group) in groups where claimed[id] == nil {
            groups[id] = nil
            emptiedGroups[id] = group
        }
    }

    /// Group per grouped tab in a space.
    func groupIDs(in spaceID: UUID) -> [UUID: UUID] {
        Dictionary(tabs(in: spaceID).compactMap { tab in tab.groupID.map { (tab.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    func group(_ id: UUID) -> TabGroup? { groups[id] }

    /// A group's tabs in list order, including split partners.
    func tabs(inGroup id: UUID) -> [Tab] {
        tabsBySpace.values.lazy.map { $0.filter { $0.groupID == id } }.first { !$0.isEmpty } ?? []
    }

    /// A space's groups, top to bottom.
    func groups(in spaceID: UUID) -> [TabGroup] {
        var seen: Set<UUID> = []
        return tabs(in: spaceID).compactMap { tab in tab.groupID.flatMap { seen.insert($0).inserted ? groups[$0] : nil } }
    }

    /// The group for a reopened tab, restoring it if removed; nil if gone for good.
    private func regroup(_ id: UUID) -> UUID? {
        if groups[id] == nil, let group = emptiedGroups.removeValue(forKey: id) { groups[id] = group }
        return groups[id] != nil ? id : nil
    }

    /// Restores a session's groups before its tabs are adopted.
    func restoreGroups(_ restored: [TabGroup]) {
        for group in restored { groups[group.id] = group }
    }

    /// Creates a group named `name` from these rows (split partners and nested tabs included) at the first one's
    /// position. Tabs leave other groups. Returns its id.
    @discardableResult
    func makeGroup(with picked: [Tab], name: String) -> UUID? {
        guard let space = picked.first(where: { $0.bookmarkID == nil })?.spaceID else { return nil }
        let nodes = treeNodes(in: space)
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var chosen = picked.filter { $0.bookmarkID == nil && $0.spaceID == space && index[$0.id] != nil }
        chosen.sort { index[$0.id]! < index[$1.id]! }
        guard let first = chosen.first else { return nil }
        // Each tab with its nested tabs, once.
        var blockIDs: [UUID] = []
        var taken: Set<UUID> = []
        for tab in chosen where !taken.contains(tab.id) {
            let run = [tab.id] + TabTree.descendants(of: tab.id, in: nodes)
            for id in run where taken.insert(id).inserted { blockIDs.append(id) }
        }
        var block = nodes.filter { taken.contains($0.id) }
        for i in block.indices where !taken.contains(block[i].parent ?? UUID()) { block[i].parent = nil }
        let rest = nodes.filter { !taken.contains($0.id) }
        // At the first tab's position: top level, or right after its parent if nested.
        var root = first.id
        let parents = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        while let up = parents[root] ?? nil { root = up }
        var at: Int
        if root == first.id {
            at = rest.filter { index[$0.id]! < index[first.id]! }.count
        } else {
            at = rest.firstIndex { $0.id == root }.map { TabTree.subtreeEnd(at: $0, in: rest) } ?? 0
        }
        // Never inside another group: place it after.
        let current = groupIDs(in: space)
        while at > 0, at < rest.count, let other = current[rest[at].id], current[rest[at - 1].id] == other { at += 1 }
        let group = TabGroup(name: name)
        groups[group.id] = group
        applyTree(Array(rest[..<at]) + block + Array(rest[at...]), in: space)
        for tab in tabs(in: space) where taken.contains(tab.id) { tab.groupID = group.id }
        // Split partners join via `settleGroups`.
        structureChanged()
        return group.id
    }

    /// Removes the group; its tabs stay in place, ungrouped.
    func ungroup(_ id: UUID) {
        guard groups[id] != nil else { return }
        for tab in tabs(inGroup: id) { tab.groupID = nil }
        groups[id] = nil
        emptiedGroups[id] = nil
        structureChanged()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, groups[id] != nil, groups[id]?.name != name else { return }
        groups[id]?.name = name
        structureChanged()
    }

    /// Folds or unfolds a group in the sidebar.
    func setGroupOpen(_ id: UUID, _ open: Bool) {
        guard groups[id] != nil, groups[id]?.isOpen != open else { return }
        groups[id]?.isOpen = open
        structureChanged()
    }

    /// Moves a tab (with its nested tabs) to the end of a group; nil ungroups it, placing it after the group.
    func setGroup(of tab: Tab, to id: UUID?) {
        guard tab.bookmarkID == nil, tab.groupID != id else { return }
        let space = tab.spaceID
        let anchor = id ?? tab.groupID
        let nodes = treeNodes(in: space)
        guard let anchor, let start = nodes.firstIndex(where: { $0.id == tab.id }) else { return }
        // Excluding its own run, the spot right after the group's last tab.
        let run = Set([tab.id] + TabTree.descendants(of: tab.id, in: nodes))
        let rest = nodes.filter { !run.contains($0.id) }
        let current = groupIDs(in: space)
        let at = (rest.lastIndex { current[$0.id] == anchor }).map { $0 + 1 } ?? min(start, rest.count)
        applyTree(TabTree.moving(tab.id, to: at, parent: nil, in: nodes), in: space)
        tab.groupID = id
        structureChanged()
    }

    /// Moves a group to `index` (counted without its tabs), in its space or another, keeping order and nesting. Never
    /// inside another group or a nest: just after it.
    func moveGroup(_ id: UUID, to index: Int, in spaceID: UUID? = nil) {
        let members = tabs(inGroup: id)
        guard let from = members.first?.spaceID else { return }
        let target = spaceID ?? from
        if target == from {
            applyTree(TabGroups.moving(members.map(\.id), to: index, in: treeNodes(in: from), groups: groupIDs(in: from)), in: from)
            structureChanged()
            return
        }
        let wasSelected = members.contains { selectedTab === $0 }
        let oldIndex = tabs(in: from).firstIndex { $0 === members[0] } ?? 0
        let ids = Set(members.map(\.id))
        // A split partly outside the group can't span spaces: unsplit it.
        splits.removeAll { pair in pair.ids.contains(where: ids.contains) && !pair.ids.allSatisfy(ids.contains) }
        tabsBySpace[from]?.removeAll { ids.contains($0.id) }
        for tab in members {
            tab.setSpace(target)
            for (space, selected) in selectedBySpace where selected == tab.id && space != target { selectedBySpace[space] = nil }
        }
        tabsBySpace[target, default: []].append(contentsOf: members)
        applyTree(TabGroups.moving(members.map(\.id), to: index, in: treeNodes(in: target), groups: groupIDs(in: target)), in: target)
        structureChanged()
        if wasSelected { selectAfterClosing(Tab(url: nil, spaceID: currentSpaceID), index: oldIndex) }
    }

    // MARK: Suspension

    /// Background tabs nobody has looked at in a while give their memory back (TabSleep says when): every minute,
    /// and at once when macOS says memory is short.
    func sleepIdleTabs() {
        // Kept awake: what's on screen (both halves of a split), calls, floating pages and notifying sites. Favorites
        // and keep-awake sites too, unless memory is critical (TabSleep). Other spaces sleep normally; snapshots cover
        // swipes. With shared tabs (#162) the oldest window checks for all, keeping each one's visible pages.
        let windows = store.managers.isEmpty ? [self] : store.managers
        guard windows.first === self else { return }
        var selectedIDs = Set<UUID>()
        for window in windows {
            // `shownTabs` is empty for the AI apps' unseen window, where only use keeps a tab awake.
            selectedIDs.formUnion(window.shownTabs.map(\.id))
        }
        let live = allTabs.filter { !$0.isSuspended }
        let now = Date()
        let memory = MemoryPressure.shared.level
        let candidates = live.map {
            TabSleep.Candidate(id: $0.id, unseen: now.timeIntervalSince($0.lastActivated),
                               mustStay: selectedIDs.contains($0.id) || $0.isPlayingAudio || $0.isInUse || $0.notifiesUser,
                               hasTypedText: $0.pageState?.hasTypedText == true, isFavorite: $0.isFavorite,
                               keptAwake: KeepAwake.isOn(for: $0.url), isLoading: $0.isLoading)
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
        archiveStaleTabs(keeping: selectedIDs.union(windows.flatMap(\.selectedBySpace.values)))
    }

    /// Whether Suspend Page is offered for a tab: an ordinary tab whose page is running (a pinned page or favorite
    /// has Unload Page), and, while you're on it, with another tab to go to.
    func maySuspend(_ tab: Tab) -> Bool {
        guard tab.isLoaded, !tab.isClosed, tab.bookmarkID == nil, tab.url != nil else { return false }
        guard let selected = selectedTab, panes(of: selected).contains(where: { $0 === tab }) else { return true }
        return panes(of: selected).count > 1 || awayTarget(from: selected, leaving: [tab]) != nil
    }

    /// Puts tabs to sleep that you chose (Suspend Page), as Zigzag puts one to sleep: its page let go, where you were
    /// and its history kept, loaded again when you click it. One you're on goes out of sight first, once its page has
    /// said it holds nothing you typed: one page of a split leaves the split, which stays on the rest, as closing it
    /// does; a page alone, or a whole split, goes to where closing it would go, and stays when there's nowhere.
    /// `refused` hears each that stayed awake, and why.
    func suspend(chosen: [Tab], refused: @escaping (Tab, Tab.StaysAwake) -> Void) {
        var sleepers: [Tab] = []
        for tab in chosen where maySuspend(tab) {
            if let why = tab.staysAwake { refused(tab, why) } else { sleepers.append(tab) }
        }
        let shown = selectedTab.map(panes(of:)) ?? []
        let onScreen = sleepers.filter { tab in shown.contains { $0 === tab } }
        for tab in sleepers where !onScreen.contains(where: { $0 === tab }) { putToSleep(tab, refused: refused) }
        guard !onScreen.isEmpty else { return }
        // Asked before you're moved, so a page that stays awake never takes you off it.
        var typed: [Tab] = []
        var waiting = onScreen.count
        for tab in onScreen {
            tab.checkTypedText { [weak self] hasTyped in
                if hasTyped { typed.append(tab) }
                waiting -= 1
                guard waiting == 0, let self else { return }
                for tab in typed { refused(tab, .typedText) }
                self.leaveScreen(onScreen.filter { tab in !typed.contains { $0 === tab } && self.maySuspend(tab) }, refused: refused)
            }
        }
    }

    private func putToSleep(_ tab: Tab, refused: @escaping (Tab, Tab.StaysAwake) -> Void) {
        tab.suspend(because: "chosen from its menu", chosen: true) { [weak tab] why in if let tab { refused(tab, why) } }
    }

    /// Takes the tabs you're on out of sight, then puts them to sleep.
    private func leaveScreen(_ sleepers: [Tab], refused: @escaping (Tab, Tab.StaysAwake) -> Void) {
        guard let selected = selectedTab else { sleepers.forEach { putToSleep($0, refused: refused) }; return }
        let panes = panes(of: selected)
        let leaving = sleepers.filter { tab in panes.contains { $0 === tab } }
        var asleep = sleepers.filter { tab in !leaving.contains { $0 === tab } }
        if !leaving.isEmpty, leaving.count < panes.count {
            // Some of the split stays: those pages leave it, and you stay on the rest.
            var taker: Tab?
            for tab in leaving {
                let next = leaveGroup(tab, notify: false)
                if tab === selected { taker = next }
            }
            structureChanged()
            if leaving.contains(where: { $0 === selected }) {
                let rest = panes.filter { pane in !leaving.contains { $0 === pane } }
                if let next = taker.flatMap({ taker in rest.first { $0 === taker } }) ?? rest.first { select(next) }
            } else {
                selectionChanged()
            }
            asleep += leaving
        } else if !leaving.isEmpty, let next = awayTarget(from: selected, leaving: sleepers) {
            select(next)
            asleep += leaving
        }
        asleep.forEach { putToSleep($0, refused: refused) }
    }

    /// Where to go from the tab you're on when it's put to sleep: its opener, the tab you were on before, else a
    /// neighbor, never to a page of its split or one going to sleep with it.
    private func awayTarget(from tab: Tab, leaving: [Tab]) -> Tab? {
        let away = panes(of: tab) + leaving
        let fits = { (other: Tab) in !other.isClosed && other.spaceID == tab.spaceID && !away.contains { $0 === other } }
        if let opener = tab.opener, fits(opener), self.tab(with: opener.id) === opener, !isShownElsewhere(opener) { return opener }
        let recent = recentTabs
        if let previous = recent.first(where: { fits($0) && !isShownElsewhere($0) }) ?? recent.first(where: fits) { return previous }
        let list = tabs(in: tab.spaceID)
        guard let index = list.firstIndex(where: { $0 === tab }) else { return list.first(where: fits) }
        return list[(index + 1)...].first(where: fits) ?? list[..<index].reversed().first(where: fits)
    }

    /// Whether a tab on its way to sleep (TabSleep.queue) still may: it's open and awake, and no window has come to
    /// show it, alone or beside another in a split, since it was chosen.
    static func mayStillSleep(_ tab: Tab) -> Bool {
        guard !tab.isClosed, !tab.isSuspended else { return false }
        return !WindowManager.shared.everyController.contains { $0.tabManager.shows(tab) }
    }

    /// Whether someone sees the tab here: selected or in its split, never in an unseen window.
    func shows(_ tab: Tab) -> Bool { shownTabs.contains { $0 === tab } }

    /// The tabs this window shows to someone, for a pass over many tabs to work out once.
    var shownTabs: [Tab] {
        guard host?.isOutOfSight != true, let selected = selectedTab else { return [] }
        return panes(of: selected)
    }

    /// The tabs the Archive may take, by space: never a private window's or AI apps'.
    var archivableTabs: [[Tab]] {
        guard !isPrivate else { return [] }
        return tabsBySpace.filter { Profiles.shared.profile(forSpace: $0.key).getsYourData }.map(\.value)
    }

    /// Ordinary tabs unseen for longer than the setting move to the archive. Never pinned pages or favorites,
    /// what's on screen, a split, anything playing or in a call, a site that sends notifications, one with something you
    /// typed still in it, or what `archivableTabs` leaves out.
    private func archiveStaleTabs(keeping onScreen: Set<UUID>) {
        let lists = archivableTabs
        TabArchive.offerIfCrowded(tabCount: lists.map(\.count).max() ?? 0)
        guard let limit = TabArchive.after.interval else { return }
        let now = Date()
        let stale = lists.flatMap { $0 }.filter {
            $0.bookmarkID == nil && !onScreen.contains($0.id) && split(for: $0) == nil && !$0.isPlayingAudio && !$0.isInUse && !$0.notifiesUser
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
            store.unwatch(tab.id)
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
            tab.close()
        }
        structureChanged()
    }
}

extension TabManager.ClosedTab {
    /// A tab as it closed, at `index` in its space's list, with the tabs that were under it.
    init(_ tab: Tab, at index: Int, split pair: TabManager.SplitPair? = nil, childIDs: [UUID] = []) {
        self.init(id: tab.id, url: tab.url, title: tab.displayTitle, spaceID: tab.spaceID, index: index,
                  interactionState: tab.interactionStateForSaving, customTitle: tab.customTitle, customIcon: tab.customIcon, split: pair,
                  lastActivated: tab.lastActivated, parentID: tab.parentID, childIDs: childIDs, isCollapsed: tab.isCollapsed,
                  groupID: tab.groupID)
    }

    /// What it had beyond its page, back on the tab that reopens it.
    func apply(to tab: Tab) {
        tab.customTitle = customTitle
        tab.customIcon = customIcon
        tab.isCollapsed = isCollapsed
    }
}
