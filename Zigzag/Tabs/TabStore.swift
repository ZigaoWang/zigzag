import AppKit
import WebKit

/// The open tabs that windows share (#162), as in Arc: each space's list, the open pages of pinned tabs and
/// favorites, the splits and tile groups, and the closed tabs ⇧⌘T brings back. Every everyday window is a view of
/// one store (`TabManager`), with its own space, its own tab chosen in each space and its own place on screen; opening,
/// closing, moving, nesting or folding a tab in one shows in all of them. A private window has a store of its own,
/// so its tabs stay in it.
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

    /// Private windows' tabs share one throwaway store, gone when the window closes.
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }

    private struct Member { weak var manager: TabManager? }
    private var members: [Member] = []
    /// The windows' views of the store, oldest first.
    var managers: [TabManager] { members.compactMap(\.manager) }

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

    // MARK: Watching tabs

    private var tabTokens: [UUID: SignalToken] = [:]

    /// Watches a tab so navigation inside it gets saved for crash recovery, whichever window it's in. A page's own
    /// title saves at most every half minute: pages that count down or flash "(1) New message" would otherwise save
    /// the whole session every second or two. A name you give a tab saves at once.
    func watch(_ tab: Tab) {
        tab.privateStore = privateStore
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

    // MARK: Pages on screen

    /// Whether another window than `manager`'s has this page on screen now, or in its mini player.
    func isShownElsewhere(_ tab: Tab, than manager: TabManager) -> Bool {
        guard let owner = tab.shownBy, owner !== manager, !owner.isInvalidated else { return false }
        return owner.isShowing(tab) || tab.isInMiniPlayer
    }
}
