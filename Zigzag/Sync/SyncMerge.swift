import Foundation

/// The first sync on a Mac that already has a library: a merge, never a replace. Items match by ID first, then a
/// space by name in the same profile, a folder by name and a pinned page by address in the same place, a favorite by
/// address in the same profile, a profile by name. What matched takes iCloud's version; what's only here is added
/// next to where it sits here. Nothing here is ever dropped.
enum SyncMerge {
    struct Result {
        var aliases: SyncAliases
        /// iCloud's records with this Mac's own added.
        var items: [String: SyncItem]
        /// How many of this Mac's items iCloud didn't have.
        var added: Int
    }

    private struct Node {
        var name: String
        var id: UUID
        var body: SyncBody
        var position: String
    }

    static func merge(local library: SyncLibrary, server: [String: SyncItem], now: Date = Date()) -> Result {
        let local = SyncMapping.export(library, previous: [:], aliases: SyncAliases(), now: now).items
        var aliases = SyncAliases()
        var items = server
        var added = 0
        let serverNodes = nodes(server)
        let localNodes = nodes(local)
        let serverNames = Set(server.keys)
        var matched: Set<String> = []
        var serverTaken: Set<String> = []

        func link(_ node: Node, to serverName: String) {
            matched.insert(node.name)
            serverTaken.insert(serverName)
            if let serverID = SyncName.id(serverName) { aliases.link(local: node.id, server: serverID) }
        }
        func byID(_ node: Node) -> Bool {
            guard serverNames.contains(node.name), !serverTaken.contains(node.name) else { return false }
            link(node, to: node.name)
            return true
        }
        func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        // Profiles: by ID, then by name.
        for node in localNodes.filter({ if case .profile = $0.body { true } else { false } }) {
            guard !byID(node), case .profile(let mine) = node.body else { continue }
            let name = normalized(mine.name ?? "")
            if !name.isEmpty, let other = serverNodes.first(where: { n in
                guard !serverTaken.contains(n.name), case .profile(let theirs) = n.body else { return false }
                return normalized(theirs.name ?? "") == name
            }) { link(node, to: other.name) }
        }
        // Spaces: by ID, then by name on the same profile.
        for node in localNodes.filter({ if case .space = $0.body { true } else { false } }) {
            guard !byID(node), case .space(let mine) = node.body else { continue }
            let name = normalized(mine.look.name), profile = aliases.server(mine.profile)
            if let other = serverNodes.first(where: { n in
                guard !serverTaken.contains(n.name), case .space(let theirs) = n.body else { return false }
                return theirs.profile == profile && normalized(theirs.look.name) == name
            }) { link(node, to: other.name) }
        }
        // Folders, outer ones first: by ID, then by name in the same place.
        var folders = localNodes.filter { if case .folder = $0.body { true } else { false } }
        let folderParent = Dictionary(folders.map { n -> (UUID, UUID?) in
            if case .folder(let f) = n.body { (n.id, f.parent) } else { (n.id, nil) }
        }, uniquingKeysWith: { a, _ in a })
        func depth(_ id: UUID) -> Int {
            var d = 0, seen: Set<UUID> = [id], current = id
            while let p = folderParent[current] ?? nil, seen.insert(p).inserted { d += 1; current = p }
            return d
        }
        folders.sort { depth($0.id) < depth($1.id) }
        for node in folders {
            guard !byID(node), case .folder(let mine) = node.body else { continue }
            let name = normalized(mine.name), space = aliases.server(mine.space), parent = mine.parent.map(aliases.server)
            if let other = serverNodes.first(where: { n in
                guard !serverTaken.contains(n.name), case .folder(let theirs) = n.body else { return false }
                return theirs.space == space && theirs.parent == parent && normalized(theirs.name) == name && (theirs.live == nil) == (mine.live == nil)
            }) { link(node, to: other.name) }
        }
        // Pinned pages: by ID, then by address in the same space and folder. Looked up by place, for big libraries.
        var serverPages: [String: [String]] = [:], serverFavorites: [String: [String]] = [:]
        for n in serverNodes {
            if case .page(let p) = n.body { serverPages["\(p.space) \(p.parent?.uuidString ?? "") \(TabManager.normalize(p.url))", default: []].append(n.name) }
            if case .favorite(let f) = n.body { serverFavorites["\(f.profile) \(TabManager.normalize(f.url))", default: []].append(n.name) }
        }
        for node in localNodes.filter({ if case .page = $0.body { true } else { false } }) {
            guard !byID(node), case .page(let mine) = node.body else { continue }
            let key = "\(aliases.server(mine.space)) \(mine.parent.map(aliases.server)?.uuidString ?? "") \(TabManager.normalize(mine.url))"
            if let other = serverPages[key]?.first(where: { !serverTaken.contains($0) }) { link(node, to: other) }
        }
        // Favorites: by ID, then by address in the same profile.
        for node in localNodes.filter({ if case .favorite = $0.body { true } else { false } }) {
            guard !byID(node), case .favorite(let mine) = node.body else { continue }
            let key = "\(aliases.server(mine.profile)) \(TabManager.normalize(mine.url))"
            if let other = serverFavorites[key]?.first(where: { !serverTaken.contains($0) }) { link(node, to: other) }
        }

        // What's only here joins iCloud's lists next to the item it follows here.
        func group(_ body: SyncBody, server isServer: Bool) -> String? {
            let map: (UUID) -> UUID = isServer ? { $0 } : aliases.server
            switch body {
            case .profile: return "profiles"
            case .space: return "spaces"
            case .favorite(let f): return "favorites \(map(f.profile))"
            case .page(let p): return "tree \(map(p.space)) \(p.parent.map(map)?.uuidString ?? "")"
            case .folder(let f): return "tree \(map(f.space)) \(f.parent.map(map)?.uuidString ?? "")"
            default: return nil
            }
        }
        var serverGroups: [String: [Node]] = [:]
        for node in serverNodes { if let g = group(node.body, server: true) { serverGroups[g, default: []].append(node) } }
        var localGroups: [String: [Node]] = [:]
        for node in localNodes { if let g = group(node.body, server: false) { localGroups[g, default: []].append(node) } }
        for (g, mine) in localGroups {
            let theirs = SyncOrder.sorted(serverGroups[g] ?? [], key: \.position, id: \.id)
            guard mine.contains(where: { !matched.contains($0.name) }) else { continue }
            var order = theirs.map(\.name)
            var cursor = 0
            for node in SyncOrder.sorted(mine, key: \.position, id: \.id) {
                if matched.contains(node.name) {
                    let serverName = name(of: node, aliases)
                    if let at = order.firstIndex(of: serverName) { cursor = max(cursor, at + 1) }
                    continue
                }
                order.insert(node.name, at: min(cursor, order.count))
                cursor += 1
            }
            // One ID per name, so `keys` can keep iCloud's places.
            var idOf: [String: UUID] = [:]
            for name in order { idOf[name] = SyncName.id(name) ?? UUID() }
            var existing: [UUID: String] = [:]
            for node in theirs { if let id = idOf[node.name] { existing[id] = node.position } }
            let keys = SyncOrder.keys(for: order.compactMap { idOf[$0] }, existing: existing)
            for node in mine where !matched.contains(node.name) {
                guard let id = idOf[node.name], let key = keys[id] else { continue }
                items[node.name] = SyncItem(rewritten(node.body, position: key, aliases: aliases), modified: now)
                added += 1
            }
            // iCloud's own may have new places too, where an item went between two of them.
            for node in theirs {
                guard let id = idOf[node.name], let key = keys[id], key != node.position, let item = server[node.name] else { continue }
                items[node.name] = SyncItem(rewritten(node.body, position: key, aliases: SyncAliases()), modified: item.modified)
            }
        }

        // Site rules: iCloud's, then this Mac's for sites iCloud has no rule for.
        if case .rules(let mine)? = local[SyncName.rules]?.body {
            let theirs: [SiteRoutes.Route] = if case .rules(let r)? = server[SyncName.rules]?.body { r.routes.rules } else { [] }
            var routes = theirs
            for var route in mine.routes.rules where !theirs.contains(where: { $0.id == route.id || ($0.site == route.site && $0.match == route.match) }) {
                route.spaceID = aliases.server(route.spaceID)
                routes.append(route)
            }
            if routes.count != theirs.count || server[SyncName.rules] == nil {
                items[SyncName.rules] = SyncItem(.rules(SyncRules(routes: routes)), modified: now)
            }
        }
        // Preferences: iCloud's where it has one, this Mac's for the rest.
        if case .settings(let mine)? = local[SyncName.settings]?.body {
            let theirs: [String: SyncSettings.Entry] = if case .settings(let s)? = server[SyncName.settings]?.body { s.values } else { [:] }
            var values = theirs
            for (key, entry) in mine.values where entry.value != nil {
                let named = SyncPreferences.renamed(key, aliases.server)
                if values[named] == nil { values[named] = entry }
            }
            if values != theirs || server[SyncName.settings] == nil {
                items[SyncName.settings] = SyncItem(.settings(SyncSettings(values: values)), modified: now)
            }
        }
        return Result(aliases: aliases, items: items, added: added)
    }

    /// The record name an item has in iCloud.
    private static func name(of node: Node, _ aliases: SyncAliases) -> String {
        let id = aliases.server(node.id)
        return switch node.body {
        case .space: SyncName.space(id)
        case .profile: SyncName.profile(id)
        case .page: SyncName.page(id)
        case .folder: SyncName.folder(id)
        case .favorite: SyncName.favorite(id)
        default: node.name
        }
    }

    private static func nodes(_ items: [String: SyncItem]) -> [Node] {
        items.compactMap { name, item in
            guard let id = SyncName.id(name) else { return nil }
            let body = item.body
            let position: String
            switch body {
            case .space(let v): position = v.position
            case .profile(let v): position = v.position
            case .page(let v): position = v.position
            case .folder(let v): position = v.position
            case .favorite(let v): position = v.position
            default: return nil
            }
            return Node(name: name, id: id, body: body, position: position)
        }.sorted { $0.name < $1.name }
    }

    /// The item as iCloud will have it: its place, and its space, folder and profile by their iCloud IDs.
    private static func rewritten(_ body: SyncBody, position: String, aliases: SyncAliases) -> SyncBody {
        let map = aliases.server
        switch body {
        case .space(var v):
            v.position = position
            v.profile = map(v.profile)
            v.splits = v.splits.compactMap { split in split.layout.withPages(split.ids.map(map)).map(PinnedSplit.init(layout:)) }
            return .space(v)
        case .profile(var v):
            v.position = position
            v.favoriteSplits = v.favoriteSplits.compactMap { split in split.layout.withPages(split.ids.map(map)).map(PinnedSplit.init(layout:)) }
            return .profile(v)
        case .page(var v):
            v.position = position
            v.space = map(v.space)
            v.parent = v.parent.map(map)
            return .page(v)
        case .folder(var v):
            v.position = position
            v.space = map(v.space)
            v.parent = v.parent.map(map)
            return .folder(v)
        case .favorite(var v):
            v.position = position
            v.profile = map(v.profile)
            return .favorite(v)
        default:
            return body
        }
    }
}
