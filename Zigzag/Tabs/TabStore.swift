import AppKit
import WebKit

/// A window's open tabs (#162): each space's list, open pinned and favorite pages, splits, tile groups, tab groups and
/// closed tabs for ⇧⌘T. Each window has its own store unless Settings › Tabs shares them (as in Arc): then every
/// everyday window is a `TabManager` view of one store, with its own space, selection and on-screen pages, and tab
/// changes show in all. Spaces belong to one profile, so other profiles' windows never share. Private windows always
/// have their own.
///
/// A page shows in one window at a time: the last to show it (`Tab.shownBy`); others show a placeholder.
final class TabStore {
    var tabsBySpace: [UUID: [Tab]] = [:]
    var bookmarkTabs: [UUID: Tab] = [:]
    var splits: [TabManager.SplitPair] = []
    var closedTabs: [TabManager.ClosedTab] = [] {
        didSet { if !isPrivate { WindowManager.recentlyClosedChanged.send() } }
    }
    /// Reopened closed tabs: old id to new id.
    var reopenedAs: [UUID: UUID] = [:]
    /// How many closed tabs ⇧⌘T and ⌘Z can reopen: 50 more than the largest batch closed. Never shrinks, so ⌘Z after a
    /// big Clear still works.
    var closedLimit = 50
    /// Tab groups (#209) by id; membership is on `Tab.groupID`.
    var groups: [UUID: TabGroup] = [:]
    /// Groups removed with their last tab, so reopening the tab restores its group.
    var emptiedGroups: [UUID: TabGroup] = [:]

    /// Shared throwaway data store for private tabs.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    private struct Member { weak var manager: TabManager? }
    private var members: [Member] = []
    /// Window views of the store, oldest first.
    var managers: [TabManager] { members.compactMap(\.manager) }
    /// More than one window shows these tabs.
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

    /// Settings › Tabs: everyday windows share each space's tabs, as in Arc (#162). Off by default.
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

    /// Saves navigation for crash recovery, in any window. Page titles save at most every 30 seconds, so countdowns or
    /// "(1) New message" titles don't save the session constantly. Custom tab names save at once.
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

    /// Lists changed: reset each window's cached extension lists.
    func listsChanged() {
        for manager in managers { manager.forgetExtensionLists() }
    }

    // MARK: Pages on screen

    /// Whether a window other than `manager`'s shows this page or has it in its mini player.
    func isShownElsewhere(_ tab: Tab, than manager: TabManager) -> Bool {
        guard let owner = tab.shownBy, owner !== manager, !owner.isInvalidated, owner.store === self else { return false }
        return owner.isShowing(tab) || tab.isInMiniPlayer
    }

    // MARK: Turning sharing on and off

    /// Merges windows' tabs into one shared list, each space's tabs window by window, so none is lost. A pinned page or
    /// favorite open in several windows keeps the visible copy (else the first window's); other copies that navigated
    /// away become ordinary tabs, the rest close. Each window keeps its space and selection.
    static func share(_ managers: [TabManager]) {
        let windows = managers.filter { !$0.isPrivate && !$0.isInvalidated }
        let stores = windows.map(\.store).reduce(into: [TabStore]()) { list, store in if !list.contains(where: { $0 === store }) { list.append(store) } }
        guard stores.count > 1, let shared = stores.first else { return }
        // Which pages are on screen, to pick the copy of a pinned page to keep.
        var shown: Set<ObjectIdentifier> = []
        for window in windows {
            if let tab = window.selectedTab { window.panes(of: tab).forEach { shown.insert(ObjectIdentifier($0)) } }
        }
        for store in stores.dropFirst() {
            for (space, list) in store.tabsBySpace { shared.tabsBySpace[space, default: []].append(contentsOf: list) }
            for (bookmark, tab) in store.bookmarkTabs {
                guard let kept = shared.bookmarkTabs[bookmark] else { shared.bookmarkTabs[bookmark] = tab; continue }
                // Pinned page open in two windows: keep one.
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

    /// A duplicate pinned page from another window: an ordinary tab at the top of its space if it navigated away, else
    /// closed (the pin reopens it).
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

    /// Splits a shared list back into per-window tabs: each tab goes to the window showing it, else its last
    /// (`Tab.host`), else the first. Splits and tile groups go whole with their first page; nested tabs whose parent
    /// went elsewhere move to the top level. Closed tabs stay with the first window. No tab closes.
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
            // Splits go whole, with their first page.
            let byID = Dictionary(store.allTabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for pair in store.splits {
                let pages = pair.ids.compactMap { byID[$0] }
                guard let lead = pages.first, let goes = owners[ObjectIdentifier(lead)] else { continue }
                // The window showing one of its pages takes it.
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
            // Each list keeps its order, split among windows.
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
