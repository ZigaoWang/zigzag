import AppKit
import WebKit

/// The open tabs a window shows (#162): each space's list, the open pages of pinned tabs and favorites, the splits
/// and tile groups, the groups of tabs, and the closed tabs ⇧⌘T brings back. Each window has a store of its own,
/// unless Settings › Tabs has windows share a space's tabs, as in Arc: then every everyday window is a view of one
/// store (`TabManager`), with its own space, its own tab chosen in each space and its own place on screen, and opening,
/// closing, moving, nesting or folding a tab in one shows in all of them. A space belongs to one profile, so windows
/// on different profiles' spaces never see each other's tabs. A private window always has a store of its own.
///
/// A page can be on screen in only one window: the one that last showed it has it (`Tab.shownBy`), and another
/// window on the same tab shows that it's open there, until you show it there again.
final class TabStore {
    var tabsBySpace: [UUID: [Tab]] = [:]
    var bookmarkTabs: [UUID: Tab] = [:]
    var splits: [TabManager.SplitPair] = []
    var closedTabs: [TabManager.ClosedTab] = []
    /// Closed tabs brought back, by the id each had: the new tab's id.
    var reopenedAs: [UUID: UUID] = [:]
    /// How many closed tabs ⇧⌘T and ⌘Z can bring back: fifty more than the biggest lot closed at once. It never
    /// shrinks back, or closing two more after Clear took sixty would leave ⌘Z on the sixty short.
    var closedLimit = 50
    /// The groups of tabs (#209), by id; which tabs are in each, the tabs say (`Tab.groupID`).
    var groups: [UUID: TabGroup] = [:]
    /// Groups that went when their last tab closed or left, so ⌘Z or ⇧⌘T bringing a tab back brings its group too.
    var emptiedGroups: [UUID: TabGroup] = [:]

    /// Private windows' tabs share one throwaway store, gone when the window closes.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    private struct Member { weak var manager: TabManager? }
    private var members: [Member] = []
    /// The windows' views of the store, oldest first.
    var managers: [TabManager] { members.compactMap(\.manager) }
    /// Whether more than one window shows these tabs.
    var isShared: Bool { managers.count > 1 }

    init(isPrivate: Bool = false) {
        privateStore = isPrivate ? .nonPersistent() : nil
    }

    func attach(_ manager: TabManager) {
        members.removeAll { $0.manager == nil || $0.manager === manager }
        members.append(Member(manager: manager))
    }

    func detach(_ manager: TabManager) {
        members.removeAll { $0.manager == nil || $0.manager === manager }
    }

    var allTabs: [Tab] { tabsBySpace.values.flatMap { $0 } + Array(bookmarkTabs.values) }

    /// Settings › Tabs: everyday windows share each space's open tabs, as in Arc (#162). Off unless you turn it on:
    /// each window has tabs of its own.
    static var windowsShareTabs: Bool {
        get { UserDefaults.standard.bool(forKey: "WindowsShareTabs") }
        set {
            guard newValue != windowsShareTabs else { return }
            UserDefaults.standard.set(newValue, forKey: "WindowsShareTabs")
            WindowManager.shared.tabSharingChanged()
        }
    }

    // MARK: Watching tabs

    private var tabTokens: [UUID: SignalToken] = [:]

    /// Watches a tab so navigation inside it gets saved for crash recovery, whichever window it's in. A page's own
    /// title saves at most every half minute: pages that count down or flash "(1) New message" would otherwise save
    /// the whole session every second or two. A name you give a tab saves at once.
    func watch(_ tab: Tab) {
        tab.privateStore = privateStore
        tab.store = self
        var lastTitleSave = Date.distantPast
        tabTokens[tab.id] = tab.changed.observe { [weak self] change in
            switch change {
            case .url, .audio, .renamed:
                self?.contentChanged()
            case .title where Date().timeIntervalSince(lastTitleSave) > 30:
                lastTitleSave = Date()
                self?.contentChanged()
            default:
                break
            }
        }
    }

    func unwatch(_ id: UUID) { tabTokens[id] = nil }

    private func contentChanged() {
        for manager in managers { manager.changed.send(.content) }
    }

    /// The lists changed: what each window works out for extensions from them starts over.
    func listsChanged() {
        for manager in managers { manager.forgetExtensionLists() }
    }

    // MARK: Pages on screen

    /// Whether another window than `manager`'s has this page on screen now, or in its mini player.
    func isShownElsewhere(_ tab: Tab, than manager: TabManager) -> Bool {
        guard let owner = tab.shownBy, owner !== manager, !owner.isInvalidated, owner.store === self else { return false }
        return owner.isShowing(tab) || tab.isInMiniPlayer
    }

    // MARK: Turning sharing on and off

    /// Windows that had tabs of their own share one list from now on: each space's tabs, window after window, so no
    /// tab is lost. A pinned page or favorite open in more than one window keeps the page on screen (else the first
    /// window's); another copy that went on from its pinned page stays as an ordinary tab, and one still on it closes,
    /// since the pin opens it again. Each window keeps its space and the tab it was on.
    static func share(_ managers: [TabManager]) {
        let windows = managers.filter { !$0.isPrivate && !$0.isInvalidated }
        let stores = windows.map(\.store).reduce(into: [TabStore]()) { list, store in if !list.contains(where: { $0 === store }) { list.append(store) } }
        guard stores.count > 1, let shared = stores.first else { return }
        // Which window shows each page now: the copy to keep of a pinned page open in two.
        var shown: Set<ObjectIdentifier> = []
        for window in windows {
            if let tab = window.selectedTab { window.panes(of: tab).forEach { shown.insert(ObjectIdentifier($0)) } }
        }
        for store in stores.dropFirst() {
            for (space, list) in store.tabsBySpace { shared.tabsBySpace[space, default: []].append(contentsOf: list) }
            for (bookmark, tab) in store.bookmarkTabs {
                guard let kept = shared.bookmarkTabs[bookmark] else { shared.bookmarkTabs[bookmark] = tab; continue }
                // Two windows have this pinned page open: one stays its page.
                let keepNew = shown.contains(ObjectIdentifier(tab)) && !shown.contains(ObjectIdentifier(kept))
                let (stays, other) = keepNew ? (tab, kept) : (kept, tab)
                shared.bookmarkTabs[bookmark] = stays
                shared.splits.removeAll { $0.contains(other.id) }
                store.splits.removeAll { $0.contains(other.id) }
                shared.setAside(other, from: bookmark)
            }
            shared.splits += store.splits
            shared.closedTabs += store.closedTabs
            shared.closedLimit = max(shared.closedLimit, store.closedLimit)
            shared.reopenedAs.merge(store.reopenedAs) { a, _ in a }
            shared.groups.merge(store.groups) { a, _ in a }
            shared.emptiedGroups.merge(store.emptiedGroups) { a, _ in a }
            for tab in store.allTabs { store.unwatch(tab.id) }
        }
        for tab in shared.allTabs { shared.watch(tab) }
        for window in windows {
            for tab in window.allTabsShownNow { tab.shownBy = window }
            window.adopt(store: shared)
        }
        shared.listsChanged()
        windows.forEach { $0.storeChanged() }
    }

    /// A copy of a pinned page's open page that another window had too: an ordinary tab at the top of its space if it
    /// went on from its pinned page, else closed (the pin opens it again).
    private func setAside(_ tab: Tab, from bookmark: UUID) {
        let away: Bool = {
            guard let url = tab.url, let mark = Library.shared.bookmark(bookmark) else { return false }
            let here = TabManager.normalize(url)
            return here != TabManager.normalize(mark.url) && here != tab.pinnedLanding.map(TabManager.normalize)
        }()
        guard away, Library.shared.space(tab.spaceID) != nil else {
            if #available(macOS 15.4, *) { ExtensionCenter.tabClosed(tab) }
            tab.close()
            return
        }
        tab.bookmarkID = nil
        tab.isFavorite = false
        tab.parentID = nil
        tab.groupID = nil
        tabsBySpace[tab.spaceID, default: []].insert(tab, at: 0)
    }

    /// The windows sharing one list each have tabs of their own again: a tab goes with the window that has it on
    /// screen, else the one it was last in (`Tab.host`), else the first. A split or tile group goes whole, with its
    /// first page; a nested tab whose parent went elsewhere comes to the top level. The closed tabs stay with the
    /// first window. Every tab stays open, in one window.
    static func unshare(_ managers: [TabManager]) {
        let windows = managers.filter { !$0.isPrivate && !$0.isInvalidated }
        var seen: [TabStore] = []
        for window in windows where !seen.contains(where: { $0 === window.store }) { seen.append(window.store) }
        for store in seen {
            let views = store.managers.filter { view in windows.contains { $0 === view } }
            guard views.count > 1, let first = views.first else { continue }
            func owner(of tab: Tab) -> TabManager {
                if let shown = tab.shownBy, views.contains(where: { $0 === shown }), shown.isShowing(tab) { return shown }
                if let showing = views.first(where: { $0.isShowing(tab) }) { return showing }
                if let host = tab.host, let view = views.first(where: { $0.host === host }) { return view }
                if let chooser = views.first(where: { $0.hasChosen(tab) }) { return chooser }
                return first
            }
            var owners: [ObjectIdentifier: TabManager] = [:]
            for tab in store.allTabs { owners[ObjectIdentifier(tab)] = owner(of: tab) }
            // A split goes whole, with its first page.
            let byID = Dictionary(store.allTabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for pair in store.splits {
                let pages = pair.ids.compactMap { byID[$0] }
                guard let lead = pages.first, let goes = owners[ObjectIdentifier(lead)] else { continue }
                // The one with a page of it on screen takes it.
                let to = pages.lazy.compactMap { page in views.first { $0.isShowing(page) } }.first ?? goes
                pages.forEach { owners[ObjectIdentifier($0)] = to }
            }
            var stores: [ObjectIdentifier: TabStore] = [ObjectIdentifier(first): store]
            for view in views.dropFirst() { stores[ObjectIdentifier(view)] = TabStore() }
            let fresh = views.dropFirst().compactMap { stores[ObjectIdentifier($0)] }
            for target in fresh {
                target.groups = store.groups
                target.closedLimit = store.closedLimit
            }
            // Each list keeps its order, split among the windows.
            for (space, list) in store.tabsBySpace {
                var lists: [ObjectIdentifier: [Tab]] = [:]
                for tab in list { lists[ObjectIdentifier(owners[ObjectIdentifier(tab)] ?? first), default: []].append(tab) }
                for view in views { stores[ObjectIdentifier(view)]?.tabsBySpace[space] = lists[ObjectIdentifier(view)] ?? [] }
            }
            var marks: [ObjectIdentifier: [UUID: Tab]] = [:]
            for (bookmark, tab) in store.bookmarkTabs { marks[ObjectIdentifier(owners[ObjectIdentifier(tab)] ?? first), default: [:]][bookmark] = tab }
            for view in views { stores[ObjectIdentifier(view)]?.bookmarkTabs = marks[ObjectIdentifier(view)] ?? [:] }
            var pairs: [ObjectIdentifier: [TabManager.SplitPair]] = [:]
            for pair in store.splits {
                guard let lead = pair.ids.first.flatMap({ byID[$0] }) else { continue }
                pairs[ObjectIdentifier(owners[ObjectIdentifier(lead)] ?? first), default: []].append(pair)
            }
            for view in views { stores[ObjectIdentifier(view)]?.splits = pairs[ObjectIdentifier(view)] ?? [] }
            for view in views.dropFirst() {
                guard let target = stores[ObjectIdentifier(view)] else { continue }
                for tab in target.allTabs {
                    store.unwatch(tab.id)
                    target.watch(tab)
                    tab.host = view.host
                }
                view.adopt(store: target)
            }
            for tab in store.allTabs where tab.host !== first.host { tab.host = first.host }
            for view in views {
                stores[ObjectIdentifier(view)]?.allTabs.forEach { $0.shownBy = nil }
                view.storeChanged()
            }
        }
    }
}
