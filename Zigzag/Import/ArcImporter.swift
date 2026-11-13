import AppKit
import os

/// One-click import from Arc: spaces (with names and colors), pinned tabs and Favorites as bookmarks, each space's
/// open tabs, and history.
/// Reads Arc's local files only; nothing leaves the Mac.
enum ArcImporter {
    struct Result {
        var spaces = 0
        var bookmarks = 0
        /// Open tabs that came over, not loaded until they're clicked.
        var tabs = 0
        var historyEntries = 0
        /// What stopped part of the import, said plainly; nothing is ever dropped silently.
        var problems: [ImportProblem] = []
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zigzag", category: "import")

    /// What of Arc's couldn't be read.
    private enum Part: String { case history, sidebar = "spaces and pinned tabs" }

    /// Turns a file error into something to show: macOS refusing access gets the fix that opens its setting.
    /// `retries`: the import choices trying again runs; for the sidebar, bookmarks (its Favorites), spaces and open
    /// tabs (2, 8 and 64).
    private static func problem(reading part: Part, _ error: Error, retries: Int = 2 | 8 | 64) -> ImportProblem {
        let ns = error as NSError
        log.error("Arc import: couldn't read \(part.rawValue, privacy: .public): \(ns.domain, privacy: .public) \(ns.code)")
        let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
            || (ns.underlyingErrors.first as NSError?).map { $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EPERM) || $0.code == Int(EACCES)) } ?? false
        if denied {
            let message = switch part {
            case .history: String(localized: "macOS didn’t let Zigzag read Arc’s history. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on Arc, then try again.",
                                  comment: "Problem in the Import window. Arc is a browser's name; System Settings › Privacy & Security › Files & Folders is macOS's own wording.")
            case .sidebar: String(localized: "macOS didn’t let Zigzag read Arc’s spaces and pinned tabs. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on Arc, then try again.",
                                  comment: "Problem in the Import window. Arc is a browser's name; System Settings › Privacy & Security › Files & Folders is macOS's own wording.")
            }
            return ImportProblem(message: message, fix: .fullDiskAccess)
        }
        let message = switch part {
        case .history: String(localized: "Zigzag couldn’t read Arc’s history. Try again.", comment: "Problem in the Import window. Arc is a browser's name.")
        case .sidebar: String(localized: "Zigzag couldn’t read Arc’s spaces and pinned tabs. Try again.", comment: "Problem in the Import window. Arc is a browser's name.")
        }
        return ImportProblem(message: message, fix: .retry, retries: retries)
    }

    nonisolated static var arcSupport: URL {
        BrowserFolders.applicationSupport.appendingPathComponent("Arc", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: arcSupport.appendingPathComponent("StorableSidebar.json").path)
    }

    /// Everything: the sidebar, then history.
    @discardableResult
    static func importAll() -> (result: Result, firstSpace: UUID?) {
        var (result, first) = importSidebar()
        do {
            let entries = try readHistory()
            Profiles.shared.default.history.importVisits(entries)
            result.historyEntries = entries.count
        } catch { result.problems.append(historyProblem(error)) }
        return (result, first)
    }

    /// Trying again reads history only (`Choice.history`), never the sidebar a second time.
    static func historyProblem(_ error: Error) -> ImportProblem { problem(reading: .history, error, retries: 4) }

    /// The parts of Arc's sidebar an import brings, each on its own.
    struct Parts: OptionSet, Hashable {
        let rawValue: Int
        /// Its spaces, with their pinned tabs.
        static let spaces = Parts(rawValue: 1)
        /// Its Favorites, the pages at the top of the sidebar, as favorites here.
        static let favorites = Parts(rawValue: 2)
        /// Each space's open tabs.
        static let openTabs = Parts(rawValue: 4)
        static let all: Parts = [.spaces, .favorites, .openTabs]

        /// What the Import window's choices bring from the sidebar: Spaces and Pinned Tabs, Bookmarks (Arc's
        /// Favorites are its bookmarks) and Open Tabs, each only when chosen.
        init(_ choice: ImportCoordinator.Choice) {
            var parts: Parts = []
            if choice.contains(.tabs) { parts.insert(.spaces) }
            if choice.contains(.bookmarks) { parts.insert(.favorites) }
            if choice.contains(.openTabs) { parts.insert(.openTabs) }
            self = parts
        }

        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// What importing `parts` of a sidebar does, worked out before anything changes. `openTabs`: each of Arc's
    /// spaces' open tabs and the space here they go in. With spaces brought over, that's the space made for it, or
    /// the one already here with its name (importing again merges); without, the one here with its name, or nil for
    /// the space you're in, so open tabs never bring a space you didn't ask for.
    struct Plan {
        var favorites: [Bookmark] = []
        var spaces: [SpaceInfo] = []
        var openTabs: [(space: UUID?, tabs: [OpenTab])] = []
    }

    static func plan(_ sidebar: Sidebar, parts: Parts, existing: [SpaceInfo]) -> Plan {
        var plan = Plan()
        if parts.contains(.favorites) { plan.favorites = sidebar.favorites }
        if parts.contains(.spaces) { plan.spaces = sidebar.spaces }
        if parts.contains(.openTabs) {
            plan.openTabs = sidebar.spaces.compactMap { space in
                guard let tabs = sidebar.openTabs[space.id], !tabs.isEmpty else { return nil }
                let here = existing.first { $0.name == space.name }?.id
                return (here ?? (parts.contains(.spaces) ? space.id : nil), tabs)
            }
        }
        return plan
    }

    /// The `parts` of Arc's sidebar chosen: spaces and their pinned tabs, Favorites, each space's open tabs. `into`:
    /// the profile the new spaces are put on and the favorites go to. A space already here that gains pages stays on
    /// its own. Arc's profiles aren't recreated.
    @discardableResult
    static func importSidebar(into profile: UUID = Profile.defaultID, parts: Parts = .all) -> (result: Result, firstSpace: UUID?) {
        var result = Result()
        let sidebar: Sidebar
        do {
            sidebar = try readSidebar()
        } catch {
            result.problems.append(problem(reading: .sidebar, error))
            sidebar = Sidebar()
        }
        let plan = plan(sidebar, parts: parts, existing: Library.shared.spaces)
        var newSpaces = plan.spaces
        let addedFavorites = plan.favorites.isEmpty ? 0 : Library.shared.appendFavorites(plan.favorites, in: profile)
        for favorite in plan.favorites { FaviconStore.shared.prefetch(for: favorite.url) }

        // Importing again merges: spaces with the same name gain only the bookmarks they don't have yet, in their Arc
        // folders, and pages already there but in no folder move into theirs (an earlier merge left them loose).
        var merged = 0
        newSpaces = newSpaces.filter { incoming in
            guard let existing = Library.shared.spaces.first(where: { $0.name == incoming.name }) else { return true }
            let folders = incoming.folders ?? []
            func path(of id: UUID) -> [String] {
                var names: [String] = []
                var folder = folders.first { $0.bookmarkIDs.contains(id) }
                while let current = folder, names.count < 8 {
                    names.insert(current.name, at: 0)
                    folder = current.parentID.flatMap { parent in folders.first { $0.id == parent } }
                }
                return names
            }
            var known: [String: Bookmark] = [:]
            for bookmark in existing.bookmarks { known[TabManager.normalize(bookmark.url)] = known[TabManager.normalize(bookmark.url)] ?? bookmark }
            let filedAlready = Set((existing.folders ?? []).flatMap(\.bookmarkIDs))
            var new: [(url: URL, title: String)] = [], newPaths: [[String]] = []
            var loose: [UUID] = [], loosePaths: [[String]] = []
            for bookmark in incoming.bookmarks {
                if let mine = known[TabManager.normalize(bookmark.url)] {
                    if !filedAlready.contains(mine.id), !loose.contains(mine.id), case let p = path(of: bookmark.id), !p.isEmpty {
                        loose.append(mine.id); loosePaths.append(p)
                    }
                } else {
                    new.append((bookmark.url, bookmark.title)); newPaths.append(path(of: bookmark.id))
                    known[TabManager.normalize(bookmark.url)] = bookmark
                }
            }
            Library.shared.fileBookmarks(loose, paths: loosePaths, in: existing.id)
            merged += Library.shared.appendBookmarks(new, to: existing.id, folders: newPaths).count
            return false
        }
        result.spaces = newSpaces.count
        result.bookmarks = newSpaces.map(\.bookmarks.count).reduce(0, +) + merged + addedFavorites
        if !newSpaces.isEmpty {
            // A fresh install's one empty space gives way to the imported ones. Spaces you made yourself stay, even empty.
            let before = Library.shared.spaces
            let pristine = before.count == 1 ? before.filter { space in
                space.bookmarks.isEmpty && WindowManager.shared.controllers.allSatisfy { $0.tabManager.tabs(in: space.id).isEmpty }
            } : []
            Library.shared.appendSpaces(newSpaces)
            for space in newSpaces { Library.shared.setProfile(profile, forSpace: space.id) }
            for space in pristine where Library.shared.spaces.count > 1 { Library.shared.removeSpace(space.id) }
            for bookmark in newSpaces.flatMap(\.bookmarks) { FaviconStore.shared.prefetch(for: bookmark.url) }
        }
        result.tabs = openInWindow(plan.openTabs)
        log.notice("Arc import: \(result.spaces) spaces, \(result.bookmarks) bookmarks, \(result.tabs) open tabs, \(result.problems.count) problems")
        return (result, newSpaces.first?.id)
    }

    // MARK: Sidebar

    struct FormatError: LocalizedError {
        var errorDescription: String? { "its sidebar file is in a format Zigzag doesn’t know yet" }
    }

    /// A page open in one of Arc's spaces. `customTitle`: the name it was given there, if it was renamed.
    struct OpenPage: Equatable {
        var url: URL
        var title: String
        var customTitle: String? = nil
    }

    /// One row of a space's open tabs, top to bottom: a page, or a split view's two to four pages.
    struct OpenTab: Equatable {
        var pages: [OpenPage]
    }

    /// What Arc's sidebar holds. `openTabs`: each space's open tabs (those under Today, not pinned), by the
    /// `SpaceInfo` id in `spaces`.
    struct Sidebar {
        var spaces: [SpaceInfo] = []
        var favorites: [Bookmark] = []
        var openTabs: [UUID: [OpenTab]] = [:]
    }

    private static func readSidebar() throws -> Sidebar {
        try readSidebar(Data(contentsOf: arcSupport.appendingPathComponent("StorableSidebar.json")))
    }

    static func parseSidebar(_ data: Data) throws -> (spaces: [SpaceInfo], favorites: [Bookmark]) {
        let sidebar = try readSidebar(data)
        return (sidebar.spaces, sidebar.favorites)
    }

    static func readSidebar(_ data: Data) throws -> Sidebar {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FormatError() }
        // Arc keeps more than one copy of the sidebar: one or more classic containers, and, for sync, sidebarSyncState
        // (or firebaseSyncState in older versions). Which one is current varies: with sync on, the synced copy holds
        // everything and a classic one may be stale; with sync off, the synced copy is a small leftover (one person's
        // held only Arc Basics while their pins sat in the fourth classic container). Read them all, and where they
        // disagree, the fullest copy wins.
        struct Copy { var items: [Any] = []; var spaces: [Any] = []; var order: [String] = []; var top: [Any] = []; var synced = false }
        var copies: [Copy] = []
        for container in (root["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]] ?? [] where container["items"] != nil || container["spaces"] != nil {
            copies.append(Copy(items: container["items"] as? [Any] ?? [], spaces: container["spaces"] as? [Any] ?? [],
                               top: container["topAppsContainerIDs"] as? [Any] ?? []))
        }
        for synced in [(root["firebaseSyncState"] as? [String: Any])?["syncData"] as? [String: Any], root["sidebarSyncState"] as? [String: Any]] {
            guard let synced else { continue }
            let container = (synced["container"] as? [String: Any]).flatMap { ($0["value"] as? [String: Any]) ?? $0 }
            let order = (container?["orderedSpaceIDs"] ?? synced["orderedSpaceIDs"]) as? [Any] ?? []
            copies.append(Copy(items: synced["items"] as? [Any] ?? [], spaces: synced["spaceModels"] as? [Any] ?? [],
                               order: order.compactMap { $0 as? String }, top: container?["topAppsContainerIDs"] as? [Any] ?? [], synced: true))
        }
        guard !copies.isEmpty else { throw FormatError() }
        // Smallest first, so the fullest copy is read last and wins.
        copies.sort { $0.items.count < $1.items.count }

        // Arc stores lists as [key, value, key, value…] or as plain arrays, and newer versions (and Arc Sync) wrap each
        // value as {"value": …}; collect the dictionaries either way.
        func unwrapped(_ any: Any) -> [String: Any]? {
            guard let dict = any as? [String: Any] else { return nil }
            if dict["id"] == nil, let inner = dict["value"] as? [String: Any] { return inner }
            return dict
        }
        var items: [String: [String: Any]] = [:]
        /// Item ids in the order the files list them, for items that name their container but aren't in its list.
        var itemOrder: [String] = []
        var spaceByID: [String: [String: Any]] = [:]
        var classicOrder: [String] = []
        for copy in copies {
            for item in copy.items.compactMap(unwrapped) {
                guard let id = item["id"] as? String else { continue }
                if items[id] == nil { itemOrder.append(id) }
                items[id] = item
            }
            for space in copy.spaces.compactMap(unwrapped) where space["containerIDs"] != nil || space["title"] != nil {
                guard let id = space["id"] as? String else { continue }
                if !copy.synced, !classicOrder.contains(id) { classicOrder.append(id) }
                spaceByID[id] = space
            }
        }
        // The spaces in the order Arc shows them: the synced order when the synced copy is the current one, which also
        // leaves out spaces Arc no longer shows; otherwise the classic order.
        let fullest = copies[copies.count - 1]
        let shownOrder = fullest.synced ? fullest.order.filter { spaceByID[$0] != nil } : []
        let spaceList = (shownOrder.isEmpty ? (classicOrder.isEmpty ? Array(spaceByID.keys).sorted() : classicOrder) : shownOrder)
            .compactMap { spaceByID[$0] }
        /// A container's kind as Arc writes it: the word ("pinned"), or, in newer files, an object keyed by it
        /// ({"pinned": {…}}).
        func kind(_ any: Any) -> String? {
            if let word = any as? String { return word }
            return (any as? [String: Any]).flatMap { $0.count == 1 ? $0.keys.first : nil }
        }

        /// A pinned tab's page, if it's a web page.
        func tabPage(_ node: [String: Any]) -> [Bookmark] {
            guard let data = node["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                  let urlString = tab["savedURL"] as? String, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else { return [] }
            let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
            return [Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url))]
        }

        func bookmarks(under id: String, depth: Int = 0) -> [Bookmark] {
            guard depth < 8, let item = items[id] else { return [] }
            var result: [Bookmark] = []
            for child in item["childrenIds"] as? [String] ?? [] {
                guard let node = items[child], let data = node["data"] as? [String: Any] else { continue }
                if let tab = data["tab"] as? [String: Any], let urlString = tab["savedURL"] as? String, let url = URL(string: urlString),
                   url.scheme == "http" || url.scheme == "https" {
                    let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
                    result.append(Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url)))
                } else {
                    // Folders flatten into the list, keeping their order.
                    result += bookmarks(under: child, depth: depth + 1)
                }
            }
            return result
        }

        /// The open tabs under a space's unpinned container, in Arc's order: the container's own list, then any item
        /// that names it as its parent but isn't listed. A split view is one row of its pages; anything else that
        /// holds pages gives each its own row. Archived tabs live in another file and never come over.
        func openTabs(in containerID: String) -> [OpenTab] {
            var children = items[containerID]?["childrenIds"] as? [String] ?? []
            var listed = Set(children)
            for id in itemOrder where !listed.contains(id) && items[id]?["parentID"] as? String == containerID {
                children.append(id)
                listed.insert(id)
            }
            func page(_ node: [String: Any]) -> OpenPage? {
                guard let data = node["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                      let urlString = tab["savedURL"] as? String, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else { return nil }
                let saved = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let named = (node["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return OpenPage(url: url, title: saved ?? named ?? url.host() ?? urlString, customTitle: named == saved ? nil : named)
            }
            func pages(under id: String, depth: Int) -> [OpenPage] {
                guard depth < 8, let node = items[id] else { return [] }
                if let one = page(node) { return [one] }
                return (node["childrenIds"] as? [String] ?? []).flatMap { pages(under: $0, depth: depth + 1) }
            }
            var rows: [OpenTab] = []
            for child in children {
                guard let node = items[child], let data = node["data"] as? [String: Any] else { continue }
                if let one = page(node) {
                    rows.append(OpenTab(pages: [one]))
                } else if data["splitView"] != nil {
                    let inside = pages(under: child, depth: 0)
                    // Side by side as in Arc, up to the four a group holds; any more get a row each.
                    if inside.count > 1 { rows.append(OpenTab(pages: Array(inside.prefix(TileShape.maxPanes)))) }
                    rows += inside.dropFirst(inside.count > 1 ? TileShape.maxPanes : 0).map { OpenTab(pages: [$0]) }
                } else {
                    rows += pages(under: child, depth: 0).map { OpenTab(pages: [$0]) }
                }
            }
            return rows
        }

        var spaces: [SpaceInfo] = []
        var open: [UUID: [OpenTab]] = [:]
        for space in spaceList {
            let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Space \(spaces.count + 1)", comment: "Name of an imported space that had none in Arc: Space 1, Space 2…")
            let containerIDs = space["containerIDs"] as? [Any] ?? []
            var pinnedID: String?, unpinnedID: String?
            for (i, value) in containerIDs.enumerated() where i + 1 < containerIDs.count {
                switch kind(value) {
                case "pinned": pinnedID = containerIDs[i + 1] as? String
                case "unpinned": unpinnedID = containerIDs[i + 1] as? String
                default: break
                }
            }
            var info = SpaceInfo(name: name, color: color(of: space))
            if let unpinnedID, case let rows = openTabs(in: unpinnedID), !rows.isEmpty { open[info.id] = rows }
            if let pinnedID, let pinned = items[pinnedID] {
                // Arc's pinned folders come over as folders, nested as they were.
                var folders: [BookmarkFolder] = []
                func addFolder(_ id: String, parent: UUID?, depth: Int) {
                    guard depth < 8, let node = items[id] else { return }
                    var folder = BookmarkFolder(name: (node["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                                ?? String(localized: "Folder", comment: "Name of an imported folder that had none."))
                    folder.parentID = parent
                    let at = folders.count
                    folders.append(folder)
                    for child in node["childrenIds"] as? [String] ?? [] {
                        guard let inner = items[child], let data = inner["data"] as? [String: Any] else { continue }
                        if data["tab"] != nil || data["splitView"] != nil {
                            // A page, or a split view's pages, pinned in this folder.
                            let pages = data["tab"] != nil ? tabPage(inner) : bookmarks(under: child)
                            info.bookmarks += pages
                            folders[at].bookmarkIDs += pages.map(\.id)
                        } else {
                            addFolder(child, parent: folder.id, depth: depth + 1)
                        }
                    }
                }
                for child in pinned["childrenIds"] as? [String] ?? [] {
                    guard let node = items[child] else { continue }
                    let isTab = (node["data"] as? [String: Any])?["tab"] != nil
                    let inside = isTab ? [] : bookmarks(under: child)
                    if isTab {
                        if let data = node["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                           let urlString = tab["savedURL"] as? String, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" {
                            let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
                            info.bookmarks.append(Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url)))
                        }
                    } else if (node["data"] as? [String: Any])?["splitView"] != nil {
                        // A split view isn't a folder: its pages are pinned on their own.
                        info.bookmarks += inside
                    } else if !inside.isEmpty {
                        addFolder(child, parent: nil, depth: 0)
                    }
                }
                // A folder with no pages anywhere inside it doesn't come over.
                folders = folders.filter { !folders.pages(in: $0.id).isEmpty }
                if !folders.isEmpty { info.folders = folders }
            }
            spaces.append(info)
        }

        var favorites: [Bookmark] = []
        var topIDs: [String] = []
        for copy in copies.reversed() {
            // IDs, between the markers that say whose they are; only IDs name an item.
            for case let id as String in copy.top where items[id] != nil && !topIDs.contains(id) { topIDs.append(id) }
        }
        for id in topIDs { favorites += bookmarks(under: id) }
        return Sidebar(spaces: spaces, favorites: favorites, openTabs: open)
    }

    // MARK: Open tabs

    /// Puts each space's open tabs in the front browser window, after the tabs it has, in Arc's order, split views
    /// side by side. None loads: each waits, as after a relaunch, until it's clicked, so hundreds don't load at once
    /// (its hover card says it isn't loaded yet; not that Zigzag reopened, as `isRestored` would).
    /// A page already open in that space isn't opened twice, so importing again adds only what's new. Returns how
    /// many came over.
    /// A space of nil is the window's own, the one you're in.
    static func openInWindow(_ bySpace: [(space: UUID?, tabs: [OpenTab])]) -> Int {
        guard bySpace.contains(where: { !$0.tabs.isEmpty }) else { return 0 }
        let windows = WindowManager.shared
        let key = windows.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 }
        guard let manager = (key ?? windows.controllers.last { !$0.tabManager.isPrivate } ?? windows.restoreIfNoWindows())?.tabManager else { return 0 }
        return open(bySpace.map { ($0.space ?? manager.currentSpaceID, $0.tabs) }, in: manager)
    }

    /// `openInWindow`'s work, in one window's tabs.
    static func open(_ bySpace: [(space: UUID, tabs: [OpenTab])], in manager: TabManager) -> Int {
        var count = 0
        for (spaceID, rows) in bySpace where Library.shared.space(spaceID) != nil && !rows.isEmpty {
            var known = Set(manager.tabs(in: spaceID).compactMap { $0.url.map(TabManager.normalize) })
            var tabs: [Tab] = [], groups: [[Tab]] = []
            for row in rows {
                let pages = row.pages.filter { !known.contains(TabManager.normalize($0.url)) }
                let made = pages.map { page in
                    let tab = Tab(url: page.url, title: page.title, spaceID: spaceID)
                    tab.customTitle = page.customTitle
                    return tab
                }
                known.formUnion(pages.map { TabManager.normalize($0.url) })
                tabs += made
                if made.count > 1 { groups.append(made) }
            }
            guard !tabs.isEmpty else { continue }
            manager.adopt(tabs, in: spaceID)
            for group in groups { if let pair = splitPair(group.map(\.id)) { manager.restoreSplit(pair) } }
            for tab in tabs { if let url = tab.url { FaviconStore.shared.prefetch(for: url) } }
            count += tabs.count
        }
        if count > 0 {
            manager.changed.send(.structure)
            WindowManager.shared.scheduleSave()
        }
        return count
    }

    /// Two to four pages side by side, as Arc's split view had them: two halves, a half and two quarters, or four.
    static func splitPair(_ ids: [UUID]) -> TabManager.SplitPair? {
        let regions: [TileRegion] = switch ids.count {
        case 2: [.left, .right]
        case 3: [.left, .topRight, .bottomRight]
        default: [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
        return TabManager.SplitPair(ids: Array(ids.prefix(TileShape.maxPanes)), shape: TileShape(regions: regions))
    }

    /// Maps an Arc space's theme to the nearest of our tints.
    private static func color(of space: [String: Any]) -> SpaceColor {
        guard let info = space["customInfo"] as? [String: Any], let theme = info["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any],
              let mid = palette["midTone"] as? [String: Any],
              let r = mid["red"] as? Double, let g = mid["green"] as? Double, let b = mid["blue"] as? Double else { return .sky }
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        if color.saturationComponent < 0.15 { return .graphite }
        let hue = color.hueComponent
        let candidates = SpaceColor.allCases.filter { !$0.isNeutral }
        return candidates.min { a, b in
            hueDistance(hue, (a.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0)) < hueDistance(hue, (b.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0))
        } ?? .sky
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    // MARK: History

    /// Reads Arc's Chromium history, off the main thread: the file can be hundreds of megabytes. Every profile's, as
    /// Arc's spaces can live in any of them ("Default", "Profile 1"…); the newest visit of a page wins.
    nonisolated static func readHistory() throws -> [(URL, String, Int, Date)] {
        let userData = arcSupport.appendingPathComponent("User Data", isDirectory: true)
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: userData.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        var newest: [URL: (URL, String, Int, Date)] = [:]
        for profile in profiles {
            let source = userData.appendingPathComponent(profile).appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            for entry in readHistory(at: source) where newest[entry.0].map({ $0.3 < entry.3 }) ?? true {
                newest[entry.0] = entry
            }
        }
        return newest.values.sorted { $0.3 > $1.3 }
    }

    /// One profile's history, through a private copy with its write-ahead log (Arc keeps the file locked while
    /// running, and the latest visits may be only in the log).
    nonisolated private static func readHistory(at source: URL) -> [(URL, String, Int, Date)] {
        guard let reader = SQLiteReader(source) else { return [] }
        var entries: [(URL, String, Int, Date)] = []
        // Chromium time: microseconds since 1601-01-01.
        let epochOffset: Double = 11_644_473_600
        reader.rows("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 50000") { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url) else { return }
            let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - epochOffset)
            entries.append((url, row.string(1), Int(row.int(2)), date))
        }
        return entries
    }
}
