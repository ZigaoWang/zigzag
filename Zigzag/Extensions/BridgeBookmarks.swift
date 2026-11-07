import Foundation

/// `chrome.bookmarks`, over Zigzag's own pinned pages, folders and Favorites.
///
/// Chrome's tree, drawn from Zigzag's: under the root, "Favorites" (id "1", the bookmarks bar's place) holds your
/// favorites, and "Spaces" (id "2") holds a folder for each space with its pinned pages and folders inside. IDs say
/// what they stand for ("b:" a page, "f:" a folder, "s:" a space), so they stay the same across launches.
///
/// Changes go through Library, as the sidebar's do, so they show at once and can be undone the usual way.
/// Removing a whole space is left to you; an extension can't.
@available(macOS 15.4, *)
@MainActor
final class BridgeBookmarks: BridgeNamespace {
    static let name = "bookmarks"
    static let permission = "bookmarks"
    private var library: Library { .shared }
    /// The tree as last told to listening extensions, to work out what changed (Library says only that something did).
    private var lastSeen: [String: Placed]?
    private var watching: SignalToken?

    private static let root = "0", favorites = "1", spaces = "2"

    /// A node's place and content, for comparing one moment with the next.
    private struct Placed: Equatable {
        let parentId: String
        let index: Int
        let title: String
        let url: String?
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "getTree": return [node(Self.root, depth: .max)]
        case "getSubTree":
            guard let id = args.string(0), exists(id) else { throw BridgeError("Can't find bookmark") }
            return [node(id, depth: .max)]
        case "get":
            let ids = (args.first as? [String]) ?? args.string(0).map { [$0] } ?? []
            guard ids.allSatisfy(exists) else { throw BridgeError("Can't find bookmark") }
            return ids.map { node($0, depth: 0) }
        case "getChildren":
            guard let id = args.string(0), exists(id) else { throw BridgeError("Can't find bookmark") }
            return children(of: id).map { node($0, depth: 0) }
        case "getRecent":
            // Zigzag doesn't date its pins; the newest are the last added in each list, favorites first.
            let count = max(1, Int(args.number(0) ?? 10))
            return allPages().suffix(count).reversed().map { node($0, depth: 0) }
        case "search":
            return search(args.first).map { node($0, depth: 0) }
        case "create":
            return node(try create(args.object(0)), depth: 0)
        case "update":
            guard let id = args.string(0) else { throw BridgeError("Can't find bookmark") }
            try update(id, args.object(1))
            return node(id, depth: 0)
        case "move":
            guard let id = args.string(0) else { throw BridgeError("Can't find bookmark") }
            try move(id, args.object(1))
            return node(id, depth: 0)
        case "remove", "removeTree":
            guard let id = args.string(0) else { throw BridgeError("Can't find bookmark") }
            try remove(id)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    // MARK: Reading

    private func exists(_ id: String) -> Bool {
        if [Self.root, Self.favorites, Self.spaces].contains(id) { return true }
        guard let (kind, uuid) = parse(id) else { return false }
        switch kind {
        case "b": return library.bookmark(uuid) != nil
        case "f": return library.folder(uuid) != nil
        case "s": return library.space(uuid) != nil
        default: return false
        }
    }

    private func parse(_ id: String) -> (String, UUID)? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[1]) else { return nil }
        return (parts[0], uuid)
    }

    /// A node's children, in the order the sidebar shows them.
    private func children(of id: String) -> [String] {
        switch id {
        case Self.root: return [Self.favorites, Self.spaces]
        case Self.favorites: return library.favorites.map { "b:\($0.id)" }
        case Self.spaces: return library.spaces.map { "s:\($0.id)" }
        default: break
        }
        guard let (kind, uuid) = parse(id) else { return [] }
        if kind == "s" { return listed(in: uuid, folder: nil) }
        if kind == "f", let folder = library.folder(uuid), let space = library.spaces.first(where: { $0.folders?.contains { $0.id == uuid } == true }) {
            return listed(in: space.id, folder: folder.id)
        }
        return []
    }

    /// What sits directly in a space (folder nil) or a folder: pages, and subfolders where their first page falls.
    private func listed(in spaceID: UUID, folder: UUID?) -> [String] {
        let folders = library.folders(in: spaceID)
        let direct = folders.children(of: folder)
        var result: [String] = [], placed = Set<UUID>()
        for page in library.bookmarks(in: spaceID) {
            let holder = library.folderID(containing: page.id)
            if holder == folder { result.append("b:\(page.id)"); continue }
            // A page deeper down: the subfolder of this level that holds it goes here, once.
            if let sub = direct.first(where: { $0.id == holder || folders.descendants(of: $0.id).contains(holder ?? UUID()) }),
               placed.insert(sub.id).inserted {
                result.append("f:\(sub.id)")
            }
        }
        // Empty folders, which no page places.
        for sub in direct where !placed.contains(sub.id) { result.append("f:\(sub.id)") }
        return result
    }

    private func parent(of id: String) -> String? {
        if id == Self.root { return nil }
        if id == Self.favorites || id == Self.spaces { return Self.root }
        guard let (kind, uuid) = parse(id) else { return nil }
        switch kind {
        case "s": return Self.spaces
        case "f":
            guard let folder = library.folder(uuid) else { return nil }
            if let up = folder.parentID { return "f:\(up)" }
            return library.spaces.first { $0.folders?.contains { $0.id == uuid } == true }.map { "s:\($0.id)" }
        case "b":
            if library.isFavorite(uuid) { return Self.favorites }
            if let folder = library.folderID(containing: uuid) { return "f:\(folder)" }
            return library.spaceID(ofBookmark: uuid).map { "s:\($0)" }
        default: return nil
        }
    }

    private func title(of id: String) -> String {
        switch id {
        case Self.root: return ""
        case Self.favorites: return "Favorites"
        case Self.spaces: return "Spaces"
        default: break
        }
        guard let (kind, uuid) = parse(id) else { return "" }
        switch kind {
        case "b": return library.bookmark(uuid)?.title ?? ""
        case "f": return library.folder(uuid)?.name ?? ""
        case "s": return library.space(uuid)?.name ?? ""
        default: return ""
        }
    }

    private func node(_ id: String, depth: Int) -> [String: Any] {
        var node: [String: Any] = ["id": id, "title": title(of: id), "syncing": false]
        if let parent = parent(of: id) {
            node["parentId"] = parent
            node["index"] = children(of: parent).firstIndex(of: id) ?? 0
        }
        if let (kind, uuid) = parse(id), kind == "b", let page = library.bookmark(uuid) {
            node["url"] = page.url.absoluteString
        } else {
            if id == Self.favorites { node["folderType"] = "bookmarks-bar" }
            if id == Self.spaces { node["folderType"] = "other" }
            if depth > 0 { node["children"] = children(of: id).map { self.node($0, depth: depth - 1) } }
        }
        return node
    }

    private func allPages() -> [String] {
        library.favorites.map { "b:\($0.id)" } + library.spaces.flatMap { $0.bookmarks.map { "b:\($0.id)" } }
    }

    /// `search("text")` matches title or address, every word; `search({ query, url, title })` as Chrome does.
    private func search(_ query: Any?) -> [String] {
        let pages = allPages().compactMap { id -> (String, Bookmark)? in parse(id).flatMap { library.bookmark($0.1) }.map { (id, $0) } }
        if let text = query as? String {
            let words = text.lowercased().split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            return pages.filter { _, page in words.allSatisfy { page.title.lowercased().contains($0) || page.url.absoluteString.lowercased().contains($0) } }.map(\.0)
        }
        let options = query as? [String: Any] ?? [:]
        return pages.filter { _, page in
            if let url = options.string("url"), page.url.absoluteString != url { return false }
            if let title = options.string("title"), page.title != title { return false }
            if let text = options.string("query"), !text.isEmpty {
                let words = text.lowercased().split(separator: " ").map(String.init)
                return words.allSatisfy { page.title.lowercased().contains($0) || page.url.absoluteString.lowercased().contains($0) }
            }
            return true
        }.map(\.0)
    }

    // MARK: Changing

    /// Where a new page or folder can go: in Favorites (pages only), a space, or a folder.
    private func create(_ details: [String: Any]) throws -> String {
        let parentID = details.string("parentId") ?? Self.spaces
        let title = details.string("title") ?? ""
        let index = details.number("index").map(Int.init)
        if let text = details.string("url") {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
                throw BridgeError("Bookmarks hold web addresses")
            }
            let name = title.isEmpty ? (url.host() ?? text) : title
            switch parentID {
            case Self.favorites:
                return "b:\(library.addFavorite(url: url, title: name, at: index).id)"
            case Self.root, Self.spaces:
                guard let first = library.spaces.first, let page = library.addBookmark(url: url, title: name, to: first.id, at: index) else { throw BridgeError("Couldn't add the bookmark") }
                return "b:\(page.id)"
            default:
                guard let (kind, uuid) = parse(parentID) else { throw BridgeError("Can't find parent bookmark node") }
                if kind == "s", let page = library.addBookmark(url: url, title: name, to: uuid, at: index) { return "b:\(page.id)" }
                if kind == "f", let space = spaceID(ofFolder: uuid), let page = library.addBookmark(url: url, title: name, to: space) {
                    library.setFolder(of: page.id, to: uuid)
                    return "b:\(page.id)"
                }
                throw BridgeError("Can't find parent bookmark node")
            }
        }
        // A folder.
        let name = title.isEmpty ? "New Folder" : title
        switch parentID {
        case Self.spaces, Self.root: return "s:\(library.addSpace(name: name).id)"
        case Self.favorites: throw BridgeError("Favorites hold pages, not folders")
        default:
            guard let (kind, uuid) = parse(parentID) else { throw BridgeError("Can't find parent bookmark node") }
            if kind == "s", let folder = library.addFolder(named: name, with: [], in: uuid, parent: .some(nil)) { return "f:\(folder.id)" }
            if kind == "f", let space = spaceID(ofFolder: uuid), let folder = library.addFolder(named: name, with: [], in: space, parent: .some(uuid)) { return "f:\(folder.id)" }
            throw BridgeError("Can't find parent bookmark node")
        }
    }

    private func update(_ id: String, _ changes: [String: Any]) throws {
        guard let (kind, uuid) = parse(id), exists(id) else { throw BridgeError("Can't modify the root bookmark folders") }
        let title = changes.string("title")
        switch kind {
        case "b":
            var url: URL?
            if let text = changes.string("url") {
                guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { throw BridgeError("Bookmarks hold web addresses") }
                url = parsed
            }
            library.updateBookmark(uuid, title: title, url: url)
        case "f": if let title { library.renameFolder(uuid, to: title) }
        case "s": if let title { library.renameSpace(uuid, to: title) }
        default: throw BridgeError("Can't find bookmark")
        }
    }

    private func move(_ id: String, _ destination: [String: Any]) throws {
        guard let (kind, uuid) = parse(id), exists(id) else { throw BridgeError("Can't modify the root bookmark folders") }
        let target = destination.string("parentId") ?? parent(of: id) ?? Self.spaces
        let index = destination.number("index").map(Int.init)
        switch (kind, target) {
        case ("b", Self.favorites):
            if library.isFavorite(uuid) { library.moveFavorite(uuid, to: index ?? library.favorites.count) } else { library.makeFavorite(uuid, at: index) }
        case ("b", _):
            guard let (parentKind, parentID) = parse(target) else { throw BridgeError("Can't find parent bookmark node") }
            if parentKind == "s" {
                if library.isFavorite(uuid) { library.pinFavorite(uuid, in: parentID, at: index ?? library.bookmarks(in: parentID).count) }
                else { library.moveBookmark(uuid, to: index ?? library.bookmarks(in: parentID).count, in: parentID, folder: .some(nil)) }
            } else if parentKind == "f", let space = spaceID(ofFolder: parentID) {
                if library.isFavorite(uuid) { library.pinFavorite(uuid, in: space, at: library.bookmarks(in: space).count) }
                library.moveBookmark(uuid, to: index ?? library.bookmarks(in: space).count, in: space, folder: .some(parentID))
            } else {
                throw BridgeError("Can't find parent bookmark node")
            }
        case ("f", _):
            guard let (parentKind, parentID) = parse(target) else { throw BridgeError("Folders go in a space or a folder") }
            if parentKind == "s" { library.moveFolder(uuid, to: index ?? library.bookmarks(in: parentID).count, in: parentID, parent: .some(nil)) }
            else if parentKind == "f", let space = spaceID(ofFolder: parentID), !library.subfolderIDs(of: uuid).contains(parentID), parentID != uuid {
                library.moveFolder(uuid, to: index ?? library.bookmarks(in: space).count, in: space, parent: .some(parentID))
            } else {
                throw BridgeError("Can't move a folder there")
            }
        case ("s", _):
            library.moveSpace(uuid, to: max(0, min(index ?? library.spaces.count, library.spaces.count - 1)))
        default:
            throw BridgeError("Can't find bookmark")
        }
    }

    private func remove(_ id: String) throws {
        guard let (kind, uuid) = parse(id), exists(id) else { throw BridgeError("Can't remove the root bookmark folders") }
        switch kind {
        case "b": library.removeBookmark(uuid)
        // The folder goes; its pages stay pinned where they were, as when you remove one in the sidebar.
        case "f": library.removeFolder(uuid)
        case "s": throw BridgeError("Spaces can only be removed in Zigzag")
        default: throw BridgeError("Can't find bookmark")
        }
    }

    private func spaceID(ofFolder id: UUID) -> UUID? {
        library.spaces.first { $0.folders?.contains { $0.id == id } == true }?.id
    }

    // MARK: Events

    func startEvents() {
        guard watching == nil else { return }
        lastSeen = snapshot()
        watching = library.changed.observe { [weak self] _ in self?.announceChanges() }
    }

    private func snapshot() -> [String: Placed] {
        var all: [String: Placed] = [:]
        var queue = [Self.root]
        while let id = queue.popLast() {
            let kids = children(of: id)
            for (index, kid) in kids.enumerated() {
                let url = parse(kid).flatMap { $0.0 == "b" ? library.bookmark($0.1)?.url.absoluteString : nil }
                all[kid] = Placed(parentId: id, index: index, title: title(of: kid), url: url)
                queue.append(kid)
            }
        }
        return all
    }

    /// Library changed: work out what, and tell listening extensions as Chrome would.
    private func announceChanges() {
        guard let before = lastSeen else { return }
        let after = snapshot()
        lastSeen = after
        let bridge = ExtensionBridge.shared
        guard ["bookmarks.onCreated", "bookmarks.onRemoved", "bookmarks.onChanged", "bookmarks.onMoved"].contains(where: { bridge.isListened($0) }) else { return }
        for id in after.keys where before[id] == nil {
            bridge.emit("bookmarks.onCreated", [id, node(id, depth: 0)])
        }
        for (id, was) in before where after[id] == nil {
            var gone: [String: Any] = ["id": id, "title": was.title, "parentId": was.parentId, "index": was.index]
            if let url = was.url { gone["url"] = url }
            bridge.emit("bookmarks.onRemoved", [id, ["parentId": was.parentId, "index": was.index, "node": gone] as [String: Any]])
        }
        // A node moved when its parent changed, or its place among the siblings that were there both times did:
        // one page added or removed doesn't count as moving everything after it.
        func order(_ tree: [String: Placed], _ parent: String, keeping: Set<String>) -> [String] {
            tree.filter { $0.value.parentId == parent && keeping.contains($0.key) }.sorted { $0.value.index < $1.value.index }.map(\.key)
        }
        let common = Set(before.keys).intersection(after.keys)
        for id in common {
            guard let was = before[id], let now = after[id] else { continue }
            if was.title != now.title || was.url != now.url {
                var change: [String: Any] = ["title": now.title]
                if let url = now.url { change["url"] = url }
                bridge.emit("bookmarks.onChanged", [id, change])
            }
            let moved = was.parentId != now.parentId
                || order(before, was.parentId, keeping: common).firstIndex(of: id) != order(after, now.parentId, keeping: common).firstIndex(of: id)
            if moved {
                bridge.emit("bookmarks.onMoved", [id, ["parentId": now.parentId, "index": now.index, "oldParentId": was.parentId, "oldIndex": was.index] as [String: Any]])
            }
        }
    }
}
