import AppKit
import os

/// Dia's sidebar from StorableProfileContainers.json: favorites, pinned and open tabs, into each profile's space (#511).
enum DiaImporter {
    struct Result {
        var spaces = 0
        var bookmarks = 0
        var tabs = 0
        var problems: [ImportProblem] = []
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zigzag", category: "import")

    static let fileName = "StorableProfileContainers.json"

    /// What a container of Dia's holds, as its id names it. Kinds not known here stay behind.
    enum Kind {
        case favorites, pinned, open

        init?(_ word: String) {
            switch word.lowercased() {
            case "favorites", "favorite", "favourites": self = .favorites
            case "pinned", "pinnedtabs": self = .pinned
            case "unpinned", "today", "open", "opentabs", "regular": self = .open
            default: return nil
            }
        }
    }

    /// One Dia profile's sidebar, by the `profileID` its containers carry. A row of two or more pages is a split view.
    struct Group: Equatable {
        var profileID: String
        var favorites: [ArcImporter.OpenPage] = []
        var pinned: [ArcImporter.OpenTab] = []
        var open: [ArcImporter.OpenTab] = []

        var isEmpty: Bool { favorites.isEmpty && pinned.isEmpty && open.isEmpty }
    }

    /// A container's kind: {"container": {"pinned": {…}}}, {"container": "pinned"} or the word alone.
    static func kind(_ any: Any?, depth: Int = 0) -> Kind? {
        guard depth < 4 else { return nil }
        if let word = any as? String { return Kind(word) }
        guard let dict = any as? [String: Any] else { return nil }
        if let inner = dict["container"] { return kind(inner, depth: depth + 1) }
        return dict.keys.sorted().lazy.compactMap(Kind.init).first
    }

    /// A tab's page when it's on the web: {"variant": {"webContent": {"_0": {"title", "url"}}}}.
    static func page(_ any: Any) -> ArcImporter.OpenPage? {
        guard let content = any as? [String: Any], let variant = content["variant"] as? [String: Any],
              let web = variant["webContent"] as? [String: Any] else { return nil }
        let info = (web["_0"] as? [String: Any]) ?? web
        guard let string = info["url"] as? String, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let title = (info["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ArcImporter.OpenPage(url: url, title: title ?? url.host() ?? string)
    }

    /// Each profile's sidebar, in the order Dia lists them. Anything it can't make sense of is skipped, never guessed.
    static func parse(_ data: Data) throws -> [Group] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = root["containers"] as? [Any] else { throw ArcImporter.FormatError() }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for case let container as [String: Any] in containers {
            guard let kind = kind(container["id"]) else { continue }
            let id = (container["profileID"] as? String) ?? ""
            if groups[id] == nil { order.append(id) }
            var group = groups[id] ?? Group(profileID: id)
            for case let tab as [String: Any] in container["tabs"] as? [Any] ?? [] {
                let pages = (tab["contents"] as? [Any] ?? []).compactMap(page)
                guard !pages.isEmpty else { continue }
                // Side by side as in Dia, up to the four a split holds; any more get a row each.
                let rows = pages.count > 1
                    ? [ArcImporter.OpenTab(pages: Array(pages.prefix(TileShape.maxPanes)))] + pages.dropFirst(TileShape.maxPanes).map { ArcImporter.OpenTab(pages: [$0]) }
                    : [ArcImporter.OpenTab(pages: pages)]
                switch kind {
                case .favorites: group.favorites += pages
                case .pinned: group.pinned += rows
                case .open: group.open += rows
                }
            }
            groups[id] = group
        }
        return order.compactMap { groups[$0] }.filter { !$0.isEmpty }
    }

    /// The Dia profile folder ("Profile 1") of each profile ID: the folder named after it, else the one whose Local
    /// State entry holds it; with one of each left over, those two; with one folder, that one. Others map to none.
    static func folders(for ids: [String], browser: ChromiumImporter.Browser, in userData: URL) -> [String: String] {
        var all = browser
        all.profile = nil
        let folders = ChromiumImporter.profiles(of: all, in: userData).map(\.lastPathComponent)
        var cache: [String: Any] = [:]
        if let data = try? Data(contentsOf: userData.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cache = ((json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]) ?? [:]
        }
        func plain(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        func holds(_ any: Any?, _ key: String, depth: Int = 0) -> Bool {
            guard depth < 4 else { return false }
            if let s = any as? String { return plain(s) == key }
            if let dict = any as? [String: Any] { return dict.values.contains { holds($0, key, depth: depth + 1) } }
            if let list = any as? [Any] { return list.contains { holds($0, key, depth: depth + 1) } }
            return false
        }
        var result: [String: String] = [:]
        if folders.count == 1 {
            for id in ids { result[id] = folders[0] }
            return result
        }
        for id in ids {
            let key = plain(id)
            guard !key.isEmpty else { continue }
            if let folder = folders.first(where: { plain($0) == key })
                ?? (key.count >= 4 ? folders.first(where: { holds(cache[$0], key) }) : nil)
                ?? (key.count >= 8 ? folders.first(where: { plain($0).contains(key) }) : nil) {
                result[id] = folder
            }
        }
        let leftIDs = ids.filter { result[$0] == nil }
        let leftFolders = folders.filter { !result.values.contains($0) }
        if leftIDs.count == 1, leftFolders.count == 1 { result[leftIDs[0]] = leftFolders[0] }
        return result
    }

    /// Each group with the profile its pages are marked with, as `ChromiumImporter` marks that profile's bookmarks.
    /// Importing one profile (`browser.profile`) takes only its own; groups found in no folder come with the first.
    static func placed(_ groups: [Group], browser: ChromiumImporter.Browser, in userData: URL) -> [(group: Group, from: ImportBatch.BrowserProfile?)] {
        let folders = folders(for: groups.map(\.profileID), browser: browser, in: userData)
        let labels = ChromiumImporter.profileLabels(of: browser, in: userData)
        let first = ChromiumImporter.profileNames(of: browser, in: userData).first?.folder
        var unknown = 0
        return groups.compactMap { group in
            if let folder = folders[group.profileID] {
                if let only = browser.profile, only != folder { return nil }
                return (group, ChromiumImporter.importProfile(of: browser, folder: folder, labels: labels))
            }
            if let only = browser.profile, only != first { return nil }
            // Alone, it's the browser's one space; else a space of its own.
            if labels.isEmpty, groups.count == 1 { return (group, nil) }
            unknown += 1
            let name = String(localized: "import.dia-profile", defaultValue: "Profile \(labels.count + unknown)",
                              comment: "Name of the space for a Dia profile whose name couldn't be found: Profile 2.")
            return (group, ImportBatch.BrowserProfile(key: "\(browser.root)#\(group.profileID)", browser: browser.name, name: name))
        }
    }

    /// Imports the chosen `parts` into `profile`; importing again adds only what's new. `userData`: a test's folder.
    @discardableResult
    static func importSidebar(_ browser: ChromiumImporter.Browser, into profile: UUID = Profile.defaultID,
                              parts: ArcImporter.Parts, userData: URL? = nil) -> Result {
        var result = Result()
        let userData = userData ?? ChromiumImporter.rootURL(of: browser)
        let file = userData.deletingLastPathComponent().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return result }
        let groups: [Group]
        do {
            groups = try parse(Data(contentsOf: file))
        } catch {
            result.problems.append(problem(error))
            return result
        }
        let library = Library.shared
        let placed = placed(groups, browser: browser, in: userData)
        if parts.contains(.favorites) {
            let favorites = placed.flatMap(\.group.favorites).map { Bookmark(url: $0.url, title: TabManager.bookmarkTitle($0.title, url: $0.url)) }
            result.bookmarks += library.appendFavorites(favorites, in: profile)
            for favorite in favorites.prefix(40) { FaviconStore.shared.prefetch(for: favorite.url) }
        }
        var open: [(space: UUID?, tabs: [ArcImporter.OpenTab])] = []
        for (group, from) in placed {
            let place = ImportCoordinator.placement(for: from, source: browser.name, in: library.spaces, on: profile,
                                                    profileOf: library.profileID(ofSpace:))
            var spaceID = place.space?.id
            let pins = parts.contains(.spaces) ? group.pinned : []
            let tabs = parts.contains(.openTabs) ? group.open : []
            // Open tabs alone never bring a space you didn't ask for: they go in the one you're in.
            if spaceID == nil, parts.contains(.spaces), !pins.isEmpty || !tabs.isEmpty {
                let space = library.addSpace(name: place.name, profile: profile)
                if let from { library.setImportedFrom(from.key, forSpace: space.id) }
                spaceID = space.id
                result.spaces += 1
            }
            if let spaceID, !pins.isEmpty {
                var incoming = SpaceInfo(name: place.name, color: .sky)
                var splits: [PinnedSplit] = []
                for row in pins {
                    let pages = row.pages.map { Bookmark(url: $0.url, title: TabManager.bookmarkTitle($0.title, url: $0.url)) }
                    incoming.bookmarks += pages
                    if pages.count > 1, let pair = ArcImporter.splitPair(pages.map(\.id)) { splits.append(PinnedSplit(layout: pair)) }
                }
                if !splits.isEmpty { incoming.pinnedSplits = splits }
                result.bookmarks += ArcImporter.merge(incoming, into: spaceID)
                for bookmark in incoming.bookmarks.prefix(40) { FaviconStore.shared.prefetch(for: bookmark.url) }
            }
            if !tabs.isEmpty { open.append((spaceID, tabs)) }
        }
        result.tabs = ArcImporter.openInWindow(open)
        log.notice("Dia import: \(result.spaces) spaces, \(result.bookmarks) bookmarks, \(result.tabs) open tabs, \(result.problems.count) problems")
        return result
    }

    /// A read error as a problem; trying again runs bookmarks, spaces and open tabs (2, 8 and 64).
    static func problem(_ error: Error) -> ImportProblem {
        let ns = error as NSError
        log.error("Dia import: couldn't read its tabs: \(ns.domain, privacy: .public) \(ns.code)")
        if ArcImporter.isDenied(error) {
            return ImportProblem(message: String(localized: "macOS didn’t let Zigzag read Dia’s pinned tabs. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on Dia, then try again.",
                                                 comment: "Problem in the Import window. Dia is a browser's name; System Settings › Privacy & Security › Files & Folders is macOS's own wording."),
                                 fix: .fullDiskAccess)
        }
        return ImportProblem(message: String(localized: "Zigzag couldn’t read Dia’s pinned tabs. Try again.", comment: "Problem in the Import window. Dia is a browser's name."),
                             fix: .retry, retries: 2 | 8 | 64)
    }
}
