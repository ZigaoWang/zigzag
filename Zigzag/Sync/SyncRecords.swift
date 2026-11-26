import Foundation

/// One synced thing as its iCloud record holds it: its kind, its fields as JSON, and when it last changed.
struct SyncItem: Codable, Equatable {
    var type: String
    /// The fields, as canonical JSON (sorted keys), so equal items have equal bytes.
    var payload: Data
    var modified: Date

    init(_ body: SyncBody, modified: Date) {
        type = body.recordType
        payload = body.encoded()
        self.modified = modified
    }

    init(type: String, payload: Data, modified: Date) {
        self.type = type
        self.payload = payload
        self.modified = modified
    }

    var body: SyncBody { SyncBody.decode(type: type, payload: payload) }

    /// Same fields, whenever each was written.
    func sameContent(as other: SyncItem) -> Bool { type == other.type && payload == other.payload }

    static func == (a: SyncItem, b: SyncItem) -> Bool { a.sameContent(as: b) && a.modified == b.modified }
}

/// What a record is about. A kind this version doesn't know is kept as it came and never changed.
enum SyncBody {
    case space(SyncSpace), profile(SyncProfile), page(SyncPage), folder(SyncFolder), favorite(SyncFavorite)
    case rules(SyncRules), settings(SyncSettings), removals(SyncRemovals)
    case unknown(type: String, payload: Data)

    static let spaceType = "Space", profileType = "Profile", pageType = "Page", folderType = "Folder"
    static let favoriteType = "Favorite", rulesType = "Rules", settingsType = "Settings", removalsType = "Removals"

    var recordType: String {
        switch self {
        case .space: Self.spaceType
        case .profile: Self.profileType
        case .page: Self.pageType
        case .folder: Self.folderType
        case .favorite: Self.favoriteType
        case .rules: Self.rulesType
        case .settings: Self.settingsType
        case .removals: Self.removalsType
        case .unknown(let type, _): type
        }
    }

    /// The JSON keys this version writes for a kind; others in a record are a newer Zigzag's and are kept.
    static func knownKeys(of type: String) -> Set<String> {
        switch type {
        case spaceType: SyncSpace.knownKeys
        case profileType: SyncProfile.knownKeys
        case pageType: SyncPage.knownKeys
        case folderType: SyncFolder.knownKeys
        case favoriteType: SyncFavorite.knownKeys
        case rulesType: SyncRules.knownKeys
        case settingsType: SyncSettings.knownKeys
        case removalsType: SyncRemovals.knownKeys
        default: []
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    func encoded() -> Data {
        let encoder = Self.encoder()
        let data: Data?
        switch self {
        case .space(let v): data = try? encoder.encode(v)
        case .profile(let v): data = try? encoder.encode(v)
        case .page(let v): data = try? encoder.encode(v)
        case .folder(let v): data = try? encoder.encode(v)
        case .favorite(let v): data = try? encoder.encode(v)
        case .rules(let v): data = try? encoder.encode(v)
        case .settings(let v): data = try? encoder.encode(v)
        case .removals(let v): data = try? encoder.encode(v)
        case .unknown(_, let payload): data = payload
        }
        return data ?? Data("{}".utf8)
    }

    /// A record that can't be read as its kind (damaged, or a newer shape) reads as unknown and is left alone.
    static func decode(type: String, payload: Data) -> SyncBody {
        let decoder = Self.decoder()
        switch type {
        case spaceType: if let v = try? decoder.decode(SyncSpace.self, from: payload) { return .space(v) }
        case profileType: if let v = try? decoder.decode(SyncProfile.self, from: payload) { return .profile(v) }
        case pageType: if let v = try? decoder.decode(SyncPage.self, from: payload) { return .page(v) }
        case folderType: if let v = try? decoder.decode(SyncFolder.self, from: payload) { return .folder(v) }
        case favoriteType: if let v = try? decoder.decode(SyncFavorite.self, from: payload) { return .favorite(v) }
        case rulesType: if let v = try? decoder.decode(SyncRules.self, from: payload) { return .rules(v) }
        case settingsType: if let v = try? decoder.decode(SyncSettings.self, from: payload) { return .settings(v) }
        case removalsType: if let v = try? decoder.decode(SyncRemovals.self, from: payload) { return .removals(v) }
        default: break
        }
        return .unknown(type: type, payload: payload)
    }

    /// The JSON to upload: this version's fields over the record as the server last had it, so a newer Zigzag's
    /// fields survive an edit made here.
    static func overlay(_ mine: Data, on server: Data?, type: String) -> Data {
        guard let server, var merged = (try? JSONSerialization.jsonObject(with: server)) as? [String: Any],
              let own = (try? JSONSerialization.jsonObject(with: mine)) as? [String: Any] else { return mine }
        for key in knownKeys(of: type) { merged[key] = nil }
        for (key, value) in own { merged[key] = value }
        return (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])) ?? mine
    }
}

// MARK: Record names

/// Records are named by kind and the item's ID: "page.<UUID>". The rules and the settings are one record each.
enum SyncName {
    static let rules = "rules"
    static let settings = "settings"
    static let removals = "removals"

    static func space(_ id: UUID) -> String { "space.\(id.uuidString)" }
    static func profile(_ id: UUID) -> String { "profile.\(id.uuidString)" }
    static func page(_ id: UUID) -> String { "page.\(id.uuidString)" }
    static func folder(_ id: UUID) -> String { "folder.\(id.uuidString)" }
    static func favorite(_ id: UUID) -> String { "favorite.\(id.uuidString)" }

    /// Parents before children, so another Mac reading part of a send has a page's space before the page.
    nonisolated static func rank(_ name: String) -> Int {
        let kind = name.prefix { $0 != "." }
        return ["profile": 0, "space": 1, "folder": 2, "page": 3, "favorite": 4][String(kind)] ?? 5
    }

    nonisolated static func ordered(_ names: [String]) -> [String] { names.sorted { (rank($0), $0) < (rank($1), $1) } }

    /// The ID in a record's name, if it has one.
    static func id(_ name: String) -> UUID? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        return UUID(uuidString: String(name[name.index(after: dot)...]))
    }
}

// MARK: Kinds

/// A space: its look as `SpaceInfo` writes it (without its pages, folders or what only this Mac has), the profile
/// it's on, its place among spaces and its pinned splits.
struct SyncSpace: Codable {
    var look: SpaceInfo
    var profile: UUID
    var position: String
    var splits: [PinnedSplit]

    private enum Keys: String, CodingKey { case profile, position, splits }

    static let knownKeys: Set<String> = [
        "id", "name", "color", "bookmarks", "folders", "pinnedSplits", "hue", "intensity", "appearance", "grain", "hue2", "intensity2",
        "angle", "glass", "brightness", "brightness2", "dayDepth", "nightDepth", "tint", "tint2", "translucency", "clearGlass", "clearTint",
        "texture", "icon", "importedFrom", "defaultColor", "routedSites", "backgroundImage", "paletteColor", "paletteDefaultColor",
        "profile", "position", "splits",
    ]

    init(look: SpaceInfo, profile: UUID, position: String, splits: [PinnedSplit]) {
        var look = look
        look.bookmarks = []
        look.folders = nil
        look.pinnedSplits = nil
        look.routedSites = nil
        look.backgroundImage = nil
        look.importedFrom = nil
        self.look = look
        self.profile = profile
        self.position = position
        self.splits = splits
    }

    init(from decoder: Decoder) throws {
        look = try SpaceInfo(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        profile = try c.decodeIfPresent(UUID.self, forKey: .profile) ?? Profile.defaultID
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        splits = (try? c.decodeIfPresent([PinnedSplit].self, forKey: .splits)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        try look.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(profile, forKey: .profile)
        try c.encode(position, forKey: .position)
        try c.encode(splits, forKey: .splits)
    }
}

/// A profile: its name, color and place. Not its website data. Its favorites' splits ride along.
struct SyncProfile: Codable {
    var name: String?
    var color: SpaceColor?
    var position: String
    var favoriteSplits: [PinnedSplit] = []

    private enum CodingKeys: String, CodingKey { case name, color, position, favoriteSplits }
    static let knownKeys: Set<String> = ["name", "color", "position", "favoriteSplits"]

    init(name: String?, color: SpaceColor?, position: String, favoriteSplits: [PinnedSplit] = []) {
        self.name = name
        self.color = color
        self.position = position
        self.favoriteSplits = favoriteSplits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        color = ((try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil).flatMap(SpaceColor.named)
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        favoriteSplits = (try? c.decodeIfPresent([PinnedSplit].self, forKey: .favoriteSplits)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(color?.rawValue, forKey: .color)
        try c.encode(position, forKey: .position)
        try c.encode(favoriteSplits, forKey: .favoriteSplits)
    }
}

/// A pinned page: where it goes, what it's called, its own icon, and where it sits.
struct SyncPage: Codable {
    var url: URL
    var title: String
    var icon: String?
    var space: UUID
    /// The folder it's in; nil at the top of the space.
    var parent: UUID?
    var position: String

    private enum CodingKeys: String, CodingKey { case url, title, icon, space, parent, position }
    static let knownKeys: Set<String> = ["url", "title", "icon", "space", "parent", "position"]

    init(url: URL, title: String, icon: String?, space: UUID, parent: UUID?, position: String) {
        self.url = url
        self.title = title
        self.icon = icon
        self.space = space
        self.parent = parent
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        space = try c.decode(UUID.self, forKey: .space)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
    }
}

/// A folder of pinned pages, or a live folder's source and settings (never its fetched pages).
struct SyncFolder: Codable {
    var name: String
    var icon: String?
    var isOpen: Bool
    var space: UUID
    var parent: UUID?
    var position: String
    var live: Live?

    struct Live: Codable, Equatable {
        var source: LiveSource
        var limit: Int
        var namedByFeed: Bool

        private enum CodingKeys: String, CodingKey { case source, limit, namedByFeed }

        init(source: LiveSource, limit: Int, namedByFeed: Bool) {
            self.source = source
            self.limit = limit
            self.namedByFeed = namedByFeed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(LiveSource.self, forKey: .source)
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? LiveFolder.defaultLimit
            namedByFeed = try c.decodeIfPresent(Bool.self, forKey: .namedByFeed) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey { case name, icon, isOpen, space, parent, position, live }
    static let knownKeys: Set<String> = ["name", "icon", "isOpen", "space", "parent", "position", "live"]

    init(name: String, icon: String?, isOpen: Bool, space: UUID, parent: UUID?, position: String, live: Live?) {
        self.name = name
        self.icon = icon
        self.isOpen = isOpen
        self.space = space
        self.parent = parent
        self.position = position
        self.live = live
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        space = try c.decode(UUID.self, forKey: .space)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        live = try? c.decodeIfPresent(Live.self, forKey: .live)
    }
}

/// A favorite: its page, the profile it's in, and its place among that profile's favorites.
struct SyncFavorite: Codable {
    var url: URL
    var title: String
    var icon: String?
    var profile: UUID
    var position: String

    private enum CodingKeys: String, CodingKey { case url, title, icon, profile, position }
    static let knownKeys: Set<String> = ["url", "title", "icon", "profile", "position"]

    init(url: URL, title: String, icon: String?, profile: UUID, position: String) {
        self.url = url
        self.title = title
        self.icon = icon
        self.profile = profile
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        profile = try c.decodeIfPresent(UUID.self, forKey: .profile) ?? Profile.defaultID
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
    }
}

/// Which sites open in which space, in their order. A rule this version can't read is kept as it came.
struct SyncRules: Codable {
    var routes: SiteRoutes.StoredRules

    private enum CodingKeys: String, CodingKey { case routes }
    static let knownKeys: Set<String> = ["routes"]

    init(routes: [SiteRoutes.Route]) { self.routes = SiteRoutes.StoredRules(routes) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routes = (try? c.decodeIfPresent(SiteRoutes.StoredRules.self, forKey: .routes)) ?? SiteRoutes.StoredRules()
    }
}

/// Zigzag's own preferences, each with when it was last changed, so two Macs changing different ones both keep theirs.
struct SyncSettings: Codable {
    var values: [String: Entry]

    struct Entry: Codable, Equatable {
        /// Nil: set back to its default.
        var value: SettingValue?
        var modified: Date
    }

    private enum CodingKeys: String, CodingKey { case values }
    static let knownKeys: Set<String> = ["values"]

    init(values: [String: Entry]) { self.values = values }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One value that can't be read leaves the rest.
        let raw = (try? c.decodeIfPresent([String: Lenient].self, forKey: .values)) ?? [:]
        values = raw.compactMapValues(\.entry)
    }

    private struct Lenient: Decodable {
        var entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// Each key's newer value.
    static func merged(_ a: [String: Entry], _ b: [String: Entry]) -> [String: Entry] {
        a.merging(b) { x, y in y.modified > x.modified ? y : x }
    }
}

/// What was removed lately, by record name, and when: an edit made before a removal, sent late (a Mac restored
/// from a backup), doesn't bring it back.
struct SyncRemovals: Codable {
    var names: [String: Date]

    private enum CodingKeys: String, CodingKey { case names }
    static let knownKeys: Set<String> = ["names"]
    /// How long a removal is remembered.
    static let kept: TimeInterval = 30 * 24 * 3600

    init(names: [String: Date]) { self.names = names }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = (try? c.decodeIfPresent([String: Date].self, forKey: .names)) ?? [:]
    }
}

// MARK: Order

/// Places among siblings as text that sorts between any two others ("fractional indexing"), so a move or an
/// insertion changes only the items that moved, and two Macs inserting at once both keep theirs.
enum SyncOrder {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let index: [Character: Int] = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })
    /// Longer than this, a list's places are given out afresh.
    static let longest = 24

    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.last != "0" && key.allSatisfy { index[$0] != nil }
    }

    /// A place after `a` and before `b` (nil: the start, the end).
    static func between(_ a: String?, _ b: String?) -> String {
        let a = a.flatMap { isValid($0) ? $0 : nil } ?? ""
        let b = b.flatMap { isValid($0) && $0 > a ? $0 : nil }
        return midpoint(Array(a), b.map(Array.init))
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 { return String(b[..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n))) }
        }
        let digitA = a.first.flatMap { index[$0] } ?? 0
        let digitB = b.flatMap { $0.first.flatMap { index[$0] } } ?? digits.count
        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB + 1) / 2])
        }
        if let b, b.count > 1 { return String(b[0]) }
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }

    /// `count` places between `low` and `high`, spread so they stay short.
    static func spread(_ count: Int, after low: String?, before high: String?) -> [String] {
        guard count > 0 else { return [] }
        var result = [String](repeating: "", count: count)
        func fill(_ range: Range<Int>, _ lo: String?, _ hi: String?) {
            guard !range.isEmpty else { return }
            let mid = range.lowerBound + range.count / 2
            let key = between(lo, hi)
            result[mid] = key
            fill(range.lowerBound..<mid, lo, key)
            fill((mid + 1)..<range.upperBound, key, hi)
        }
        fill(0..<count, low, high)
        return result
    }

    /// Places for `order`: items whose place in `existing` still reads in order keep it; the rest get new ones
    /// between their neighbors. `fixed` items keep theirs wherever they fall.
    static func keys(for order: [UUID], existing: [UUID: String], fixed: Set<UUID> = []) -> [UUID: String] {
        var result: [UUID: String] = [:]
        var free: [UUID] = []
        for id in order {
            if fixed.contains(id), let key = existing[id], isValid(key) { result[id] = key } else { free.append(id) }
        }
        // The longest run of free items whose old places are already in order keeps them.
        let known = free.enumerated().compactMap { i, id in existing[id].flatMap { isValid($0) ? (i, $0) : nil } }
        var tails: [Int] = [], previous = [Int](repeating: -1, count: known.count)
        for (k, item) in known.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let m = (lo + hi) / 2; if known[tails[m]].1 < item.1 { lo = m + 1 } else { hi = m } }
            if lo > 0 { previous[k] = tails[lo - 1] }
            if lo == tails.count { tails.append(k) } else { tails[lo] = k }
        }
        var kept: [Int: String] = [:]
        var k = tails.last ?? -1
        while k >= 0 { kept[known[k].0] = known[k].1; k = previous[k] }
        var i = 0
        var low: String? = nil
        while i < free.count {
            if let key = kept[i] { result[free[i]] = key; low = key; i += 1; continue }
            var j = i
            while j < free.count, kept[j] == nil { j += 1 }
            let high = j < free.count ? kept[j] : nil
            for (offset, key) in spread(j - i, after: low, before: high).enumerated() { result[free[i + offset]] = key }
            i = j
        }
        // Places grown too long are given out afresh only around them, widening until they fit, so a busy spot doesn't
        // renumber (and send again) the whole list.
        while let bad = free.indices.first(where: { (result[free[$0]] ?? "").count > longest }) {
            var lo = bad, hi = bad + 1
            // The whole crowded run first, then outward from it.
            while hi < free.count, (result[free[hi]] ?? "").count > longest / 2 { hi += 1 }
            while lo > 0, (result[free[lo - 1]] ?? "").count > longest / 2 { lo -= 1 }
            while true {
                let keys = spread(hi - lo, after: lo > 0 ? result[free[lo - 1]] : nil, before: hi < free.count ? result[free[hi]] : nil)
                if keys.allSatisfy({ $0.count <= longest / 2 }) || (lo == 0 && hi == free.count) {
                    for (offset, key) in keys.enumerated() { result[free[lo + offset]] = key }
                    break
                }
                lo = max(0, lo - 1)
                hi = min(free.count, hi + 1)
            }
        }
        return result
    }

    /// Items in their places' order; the same place sorts by ID, so every Mac reads one order.
    static func sorted<T>(_ items: [T], key: (T) -> String, id: (T) -> UUID) -> [T] {
        items.sorted { a, b in
            let ka = key(a), kb = key(b)
            return ka != kb ? ka < kb : id(a).uuidString < id(b).uuidString
        }
    }
}
