import Foundation

/// File › Export Your Data…'s bookmarks file: the Netscape bookmarks HTML every browser imports. One folder per space,
/// in the sidebar's order, holding its pinned pages and folders as the sidebar nests them (a split's pages one after
/// another) and, when asked, its open tabs. Favorites, which every space of a profile shares, are a folder of their own.
/// With more than one profile, each profile is a folder around its favorites and spaces.
enum BookmarksExport {
    indirect enum Node: Equatable {
        case page(title: String, url: URL)
        case folder(name: String, children: [Node])
    }

    static func tree(_ backup: ZigzagBackup) -> [Node] {
        let open = Dictionary((backup.openTabs ?? []).map { ($0.spaceID, $0.rows.flatMap { $0 }) }, uniquingKeysWith: { a, _ in a })
        func profile(ofSpace id: UUID) -> UUID { backup.spaceProfiles[id.uuidString] ?? Profile.defaultID }
        func profile(ofFavorite id: UUID) -> UUID { backup.favoriteProfiles[id.uuidString] ?? Profile.defaultID }
        let profiles = backup.profiles.isEmpty ? [ProfileInfo(id: Profile.defaultID)] : backup.profiles
        let known = Set(profiles.map(\.id))
        func contents(of id: UUID) -> [Node] {
            var nodes: [Node] = []
            let favorites = backup.favorites.filter { mark in
                let owner = profile(ofFavorite: mark.id)
                return owner == id || (id == Profile.defaultID && !known.contains(owner))
            }
            if !favorites.isEmpty {
                nodes.append(.folder(name: String(localized: "Favorites", comment: "Folder in an exported bookmarks file holding the favorites."),
                                     children: favorites.map { .page(title: $0.title, url: $0.url) }))
            }
            for space in backup.spaces {
                let owner = profile(ofSpace: space.id)
                guard owner == id || (id == Profile.defaultID && !known.contains(owner)) else { continue }
                var children = pinned(space)
                if let tabs = open[space.id], !tabs.isEmpty {
                    children.append(.folder(name: String(localized: "Open Tabs", comment: "Folder in an exported bookmarks file holding a space's open tabs, not pinned ones."),
                                            children: tabs.map { .page(title: $0.customTitle ?? $0.title, url: $0.url) }))
                }
                nodes.append(.folder(name: space.name, children: children))
            }
            return nodes
        }
        guard profiles.count > 1 else { return contents(of: Profile.defaultID) }
        return profiles.map { .folder(name: $0.displayName, children: contents(of: $0.id)) }
    }

    /// A space's pinned pages and folders as the sidebar shows them: each level in the order its first page comes, an
    /// empty folder at the top of where it sits.
    static func pinned(_ space: SpaceInfo) -> [Node] {
        let tidy = Library.tidied(space.bookmarks, space.folders ?? [], space.pinnedSplits ?? [])
        let pages = tidy.bookmarks, folders = tidy.folders
        let position = Dictionary(pages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var folderOf: [UUID: UUID] = [:]
        for folder in folders { for id in folder.bookmarkIDs { folderOf[id] = folder.id } }
        var firstAt: [UUID: Int] = [:]
        func first(_ id: UUID) -> Int {
            if let known = firstAt[id] { return known }
            firstAt[id] = -1
            let own = folders.first { $0.id == id }?.bookmarkIDs.compactMap { position[$0] } ?? []
            let inner = folders.children(of: id).map { first($0.id) }.filter { $0 >= 0 }
            let at = (own + inner).min() ?? -1
            firstAt[id] = at
            return at
        }
        var emitted: Set<UUID> = []
        func level(_ parent: UUID?) -> [Node] {
            var units: [(at: Int, order: Int, node: () -> Node?)] = []
            for (i, page) in pages.enumerated() where folderOf[page.id] == parent {
                units.append((i, i, { .page(title: page.title, url: page.url) }))
            }
            for (i, folder) in folders.enumerated() where folder.parentID == parent {
                units.append((first(folder.id), pages.count + i, {
                    guard emitted.insert(folder.id).inserted else { return nil }
                    return .folder(name: folder.name, children: level(folder.id))
                }))
            }
            return units.sorted { ($0.at, $0.order) < ($1.at, $1.order) }.compactMap { $0.node() }
        }
        return level(nil)
    }

    static func html(_ nodes: [Node]) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        func write(_ nodes: [Node], depth: Int) {
            let indent = String(repeating: "    ", count: depth)
            for node in nodes {
                switch node {
                case .page(let title, let url):
                    out += "\(indent)<DT><A HREF=\"\(escape(url.absoluteString, quotes: true))\">\(escape(title.isEmpty ? url.absoluteString : title))</A>\n"
                case .folder(let name, let children):
                    out += "\(indent)<DT><H3>\(escape(name))</H3>\n\(indent)<DL><p>\n"
                    write(children, depth: depth + 1)
                    out += "\(indent)</DL><p>\n"
                }
            }
        }
        write(nodes, depth: 1)
        return out + "</DL><p>\n"
    }

    /// Text for HTML: `&`, `<` and `>`, and in an attribute `"` too.
    static func escape(_ text: String, quotes: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where quotes: result += "&quot;"
            case "\n", "\r": result += " "
            default: result.append(character)
            }
        }
        return result
    }
}
