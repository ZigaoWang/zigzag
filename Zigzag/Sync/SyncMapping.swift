import Foundation

/// What sync reads and writes: the library, the search engine and the preferences it carries.
struct SyncLibrary {
    var contents: Library.Contents
    var searchEngine: SearchEngine
    /// The carried preferences that are set, by key (`SyncPreferences`).
    var settings: [String: SettingValue]
}

/// This Mac's IDs for items the first sync matched with differently named ones in iCloud (a space by name, a page by
/// address). Local IDs stay as they are, so open tabs and website data keep finding their spaces and profiles.
nonisolated struct SyncAliases: Codable, Equatable, Sendable {
    /// Local ID to the ID in iCloud.
    private(set) var toServer: [UUID: UUID] = [:]
    private var toLocal: [UUID: UUID] = [:]

    private enum CodingKeys: String, CodingKey { case toServer }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toServer = try c.decodeIfPresent([UUID: UUID].self, forKey: .toServer) ?? [:]
        toLocal = Dictionary(toServer.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toServer, forKey: .toServer)
    }

    mutating func link(local: UUID, server: UUID) {
        guard local != server else { return }
        toServer[local] = server
        toLocal[server] = local
    }

    func server(_ id: UUID) -> UUID { toServer[id] ?? id }
    func local(_ id: UUID) -> UUID { toLocal[id] ?? id }
    var isEmpty: Bool { toServer.isEmpty }
}

/// The preferences sync carries: choices about how Zigzag behaves, never ones about this Mac (window places and
/// sizes, folders, the update channel, counters, debug switches) or what lets other apps in.
enum SyncPreferences {
    static let keys: Set<String> = [
        // General
        "AskBeforeQuitting", "LaunchChoice", "DownloadsAskWhere", "FormsAutofill", "NewSpacesGetOwnProfile", "OpensExternalLinksInMini",
        "CaptureMode", "CardFinish",
        // Appearance and sidebar
        "borderlessPage", "addressBarPlace", "addressAbovePage", "sidebarOnRight", "sidebarDoubleClickNewTab", "LargeSpaceNames",
        "FavoritesPerRow", "PinnedTabsAsTiles", "ShortFloatingSidebar", "ShowLinkAddressOnHover", "DefaultZoom", "ReduceMotion", "DarkPages",
        "DarkPagesPureBlack", "EdgeSidebar",
        // Tabs and windows
        "ControlTabOrder", "NestsOpenedLinks", "WindowsShareTabs", "ArchiveTabsAfter", "SleepsBusyTabs", "NewTabPlace", "NewTabPlaceOtherwise",
        "PictureInPictureFollowsTabs", "PictureInPictureWhenLeaving", "FullScreenFills", "SwipeBetweenPages", "OffersToPinWanderedPage",
        "InPageMini", "ShortcutOverrides",
        // Search
        "SearchSuggestions", "CustomSearchTemplate", "pdfTwoPages",
        // Privacy
        "BlockAdsAndTrackers", "AdsAllowedSites", "ProtectsIPFromWebRTC", "JavaScriptAllowed", "JavaScriptOffSites",
        "CookieBanners", "CookieBannersHandledSites", "CookieBannersLeftSites",
        // Translation and Reader
        "TranslateInto", "TranslateOffers", "TranslateAlways", "TranslateNever", "TranslateNeverSites",
        "ReaderFace", "ReaderSize", "ReaderTheme", "ReaderWidth",
        // Per site: zaps and compatibility mode (SiteBoosts), zoom, dark pages, user agents, icons. Never what a site may
        // use (camera, microphone, location, notifications, downloads) or scripts allowed where they're off: as in
        // Safari, a grant is made on the Mac it's for.
        "SiteBoosts", "ZoomLevels", "DarkPagesOnSites", "DarkPagesOffSites", "DarkPagesForcedSites",
        "UserAgentSites", "KeepAwakeSites", "FullScreenPageSites", "FullScreenScreenSites", "SiteIcons",
        // Developer
        "DeveloperTools", "DeveloperToolsInBar", "DeveloperPageSizes", "DevelopmentSites",
    ]

    /// Each profile's own choices, named with the profile's ID after a dot (`ProfileKey`). Not filling passwords, which
    /// follows the password app each Mac has, nor clearing cookies on quit, which would sign you out on another Mac.
    static let profileKeys: [ProfileKey] = [.extensionsOffSites]

    /// A preference bigger than this (a site's long styles, say) stays on this Mac: all of them share one record, and
    /// iCloud takes a record up to 1 MB.
    static let largestValue = 200_000

    static func isTooBig(_ value: SettingValue?) -> Bool { size(value) > largestValue }

    /// All of them together take up to this much of their record; beyond it, the biggest stay on this Mac.
    static let largestTotal = 700_000

    /// What a value takes in the record.
    static func size(_ value: SettingValue?) -> Int {
        guard let value else { return 0 }
        return (try? JSONEncoder().encode(value))?.count ?? 0
    }


    /// What a preference takes in the record, its key and date included.
    static func cost(_ key: String, _ value: SettingValue?) -> Int { size(value) + key.utf8.count + 40 }

    /// The search engine, kept in the library, travels as one more preference.
    static let searchEngineKey = "searchEngine"

    /// Whether sync carries `key`, and for which profile (nil: Zigzag's own, or the first profile's).
    static func owner(_ key: String) -> (carried: Bool, profile: UUID?) {
        if keys.contains(key) { return (true, nil) }
        for profileKey in profileKeys {
            if key == profileKey.rawValue { return (true, nil) }
            let prefix = profileKey.rawValue + "."
            if key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))) { return (true, id) }
        }
        return (false, nil)
    }

    /// `key` with its profile's ID swapped for `map`'s.
    static func renamed(_ key: String, _ map: (UUID) -> UUID) -> String {
        guard case let (true, profile?) = owner(key), let dot = key.lastIndex(of: ".") else { return key }
        return "\(key[..<dot]).\(map(profile).uuidString)"
    }

    /// The carried preferences set in `defaults`, for these profiles.
    static func read(from defaults: UserDefaults, profiles: Set<UUID>) -> [String: SettingValue] {
        var values: [String: SettingValue] = [:]
        for (key, object) in defaults.dictionaryRepresentation() {
            let owner = owner(key)
            guard owner.carried, owner.profile.map(profiles.contains) ?? true, let value = SettingValue(object) else { continue }
            values[key] = key == "SiteIcons" ? withoutImages(value) : value
        }
        return values
    }

    /// Writes what changed into `defaults`: nil sets a preference back to its default.
    static func write(_ changes: [String: SettingValue?], to defaults: UserDefaults) {
        for (key, value) in changes where owner(key).carried {
            if let value { defaults.set(value.object, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    /// Picture icons are files on this Mac: only symbols and emoji travel.
    static func withoutImages(_ value: SettingValue) -> SettingValue {
        guard case .dictionary(let sites) = value else { return value }
        return .dictionary(sites.filter { _, icon in if case .string(let name) = icon { !name.hasPrefix(PageImageIcon.prefix) } else { true } })
    }
}

/// Turns the library into records and records back into the library.
enum SyncMapping {
    /// What isn't synced: the AI Apps profile, which runs on this Mac only, and its spaces and favorites.
    static func isLocalOnly(profile: UUID, in directory: ProfileDirectory) -> Bool { directory.profile(profile)?.isHeadless == true }

    /// A picture icon is a file on this Mac: it isn't sent, and one here stays when the record has none.
    static func sentIcon(_ icon: String?) -> String? { icon.flatMap { $0.hasPrefix(PageImageIcon.prefix) ? nil : $0 } }
    static func keptIcon(_ synced: String?, local: String?) -> String? { synced ?? local.flatMap { $0.hasPrefix(PageImageIcon.prefix) ? $0 : nil } }

    struct Export {
        var items: [String: SyncItem]
        /// Folders with no pages in them here now.
        var emptyFolders: Set<UUID>
        /// A folder that just got its first pages keeps the place it had: the library should be laid out again.
        var needsLayout = false
        /// Preferences too big for iCloud, by this Mac's keys, that stay on this Mac.
        var staysHere: Set<String> = []
    }

    // MARK: Waiting for a parent

    /// Records that wait for their space, folder or profile before they're shown, since one fetch can bring a page
    /// before its space. One changed here whose parent is gone is shown where it can be, and sent from there; one whose
    /// parent this version can't read always waits, so nothing here rewrites it. `kept`: kept profiles' record names.
    static func waiting(_ items: [String: SyncItem], unsent: Set<String>, kept: Set<String> = []) -> Set<String> {
        var memo: [String: Bool] = [:]
        func parents(_ body: SyncBody) -> [String] {
            switch body {
            case .page(let p): [SyncName.space(p.space)] + (p.parent.map { [SyncName.folder($0)] } ?? [])
            case .folder(let f): [SyncName.space(f.space)] + (f.parent.map { [SyncName.folder($0)] } ?? [])
            case .space(let s): s.profile == Profile.defaultID ? [] : [SyncName.profile(s.profile)]
            case .favorite(let f): f.profile == Profile.defaultID ? [] : [SyncName.profile(f.profile)]
            default: []
            }
        }
        func waits(_ name: String) -> Bool {
            if let known = memo[name] { return known }
            guard let item = items[name] else { return false }
            // A loop reads as placed; apply untangles it.
            memo[name] = false
            var result = false
            let space: UUID? = switch item.body {
            case .page(let p): p.space
            case .folder(let f): f.space
            default: nil
            }
            for parent in parents(item.body) where !kept.contains(parent) {
                guard let record = items[parent] else {
                    if !unsent.contains(name) { result = true }
                    continue
                }
                if case .unknown = record.body { result = true; continue }
                // Its folder there, but in another space: one of the two moved, and the other hasn't arrived yet.
                if case .folder(let folder) = record.body, let space, folder.space != space, !unsent.contains(name) { result = true; continue }
                if waits(parent), !unsent.contains(name) { result = true }
            }
            memo[name] = result
            return result
        }
        return Set(items.keys.filter(waits))
    }

    // MARK: Library to records

    /// `kept`: profiles removed on another Mac and kept here. They and their favorites and settings aren't sent; their
    /// spaces are, on the profile iCloud has them on.
    static func export(_ library: SyncLibrary, previous: [String: SyncItem], aliases: SyncAliases, emptyBefore: Set<UUID> = [],
                       kept: Set<UUID> = [], unsent: Set<String> = [], now: Date = Date(),
                       settingsChanged: [String: Date] = [:], settingsNow: Date? = nil,
                       settingsInICloud: [String: SyncSettings.Entry]? = nil) -> Export {
        // A preference's change counts from when it was made, never from the library file's date.
        func changed(_ key: String) -> Date { settingsChanged[SyncPreferences.renamed(key, aliases.local)] ?? settingsNow ?? now }
        let contents = library.contents
        let directory = contents.directory
        var items: [String: SyncItem] = [:]
        var positions: [String: String] = [:]
        for (name, item) in previous {
            switch item.body {
            case .space(let v): positions[name] = v.position
            case .profile(let v): positions[name] = v.position
            case .page(let v): positions[name] = v.position
            case .folder(let v): positions[name] = v.position
            case .favorite(let v): positions[name] = v.position
            case .unknown, .removals: items[name] = item
            default: break
            }
        }
        func put(_ name: String, _ body: SyncBody) { items[name] = SyncItem(body, modified: previous[name]?.modified ?? now) }
        func existing(_ ids: [UUID], _ name: (UUID) -> String) -> [UUID: String] {
            var result: [UUID: String] = [:]
            for id in ids { if let p = positions[name(aliases.server(id))] { result[id] = p } }
            return result
        }
        var export = Export(items: [:], emptyFolders: [])
        let held = waiting(previous, unsent: unsent, kept: Set(kept.map { SyncName.profile(aliases.server($0)) }))
        /// Splits iCloud has whose pages (or favorites) haven't arrived here yet, or wait: kept as they are.
        func pendingSplits(_ earlier: [PinnedSplit]?, here: Set<UUID>, name: (UUID) -> String) -> [PinnedSplit] {
            (earlier ?? []).filter { split in
                split.ids.contains { id in
                    guard !here.contains(id) else { return false }
                    let record = name(id)
                    return previous[record] == nil || held.contains(record)
                }
            }
        }

        // Profiles
        let profiles = directory.all.filter { !$0.isHeadless && !kept.contains($0.id) }
        let profileKeys = SyncOrder.keys(for: profiles.map(\.id), existing: existing(profiles.map(\.id), SyncName.profile))
        let favoriteSplits = contents.favoriteSplits
        for profile in profiles {
            var splits = favoriteSplits.filter { directory.profileID(ofFavorite: $0.left) == profile.id }.compactMap { mapped($0, aliases.server) }
            let earlierSplits: [PinnedSplit]? = if case .profile(let v)? = previous[SyncName.profile(aliases.server(profile.id))]?.body { v.favoriteSplits } else { nil }
            splits += pendingSplits(earlierSplits, here: Set(contents.favorites.map { aliases.server($0.id) }), name: SyncName.favorite)
            put(SyncName.profile(aliases.server(profile.id)),
                .profile(SyncProfile(name: profile.name, color: profile.color, position: profileKeys[profile.id] ?? "", favoriteSplits: splits)))
        }

        // Favorites, each profile's in its order
        for profile in profiles {
            let favorites = contents.favorites.filter { directory.profileID(ofFavorite: $0.id) == profile.id }
            let keys = SyncOrder.keys(for: favorites.map(\.id), existing: existing(favorites.map(\.id), SyncName.favorite))
            for favorite in favorites {
                put(SyncName.favorite(aliases.server(favorite.id)),
                    .favorite(SyncFavorite(url: favorite.url, title: favorite.title, icon: sentIcon(favorite.icon), profile: aliases.server(profile.id),
                                           position: keys[favorite.id] ?? "")))
            }
        }

        // Spaces, with their pinned pages and folders
        let spaces = contents.spaces.filter { !isLocalOnly(profile: directory.profileID(ofSpace: $0.id), in: directory) }
        let spaceKeys = SyncOrder.keys(for: spaces.map(\.id), existing: existing(spaces.map(\.id), SyncName.space))
        for space in spaces {
            let serverSpace = aliases.server(space.id)
            let folders = space.folders ?? []
            let livePages = Set(folders.filter { $0.live != nil }.flatMap(\.bookmarkIDs))
            let ids = space.bookmarks.map(\.id)
            let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            var folderOf: [UUID: UUID] = [:]
            for folder in folders { for id in folder.bookmarkIDs where folderOf[id] == nil { folderOf[id] = folder.id } }
            var firstAt: [UUID: Int] = [:]
            func first(_ id: UUID) -> Int {
                if let known = firstAt[id] { return known }
                firstAt[id] = -1
                let own = folders.first { $0.id == id }?.bookmarkIDs.compactMap { index[$0] } ?? []
                let inner = folders.children(of: id).map { first($0.id) }.filter { $0 >= 0 }
                let at = (own + inner).min() ?? -1
                firstAt[id] = at
                return at
            }
            let known = Set(folders.map(\.id))
            for parent in [nil] + folders.map(\.id) as [UUID?] {
                var units: [(at: Int, order: Int, id: UUID, folder: Bool)] = []
                for (i, id) in ids.enumerated() where folderOf[id] == parent && !livePages.contains(id) { units.append((i, i, id, false)) }
                for (i, folder) in folders.enumerated() where (folder.parentID.flatMap { known.contains($0) ? $0 : nil }) == parent {
                    units.append((first(folder.id), ids.count + i, folder.id, true))
                }
                guard !units.isEmpty else { continue }
                units.sort { ($0.at, $0.order) < ($1.at, $1.order) }
                let order = units.map(\.id)
                var keyed = existing(units.filter { !$0.folder }.map(\.id), SyncName.page)
                keyed.merge(existing(units.filter(\.folder).map(\.id), SyncName.folder)) { a, _ in a }
                var fixed: Set<UUID> = []
                for unit in units where unit.folder && keyed[unit.id] != nil {
                    if unit.at < 0 { fixed.insert(unit.id) } else if emptyBefore.contains(unit.id) { fixed.insert(unit.id); export.needsLayout = true }
                }
                let keys = SyncOrder.keys(for: order, existing: keyed, fixed: fixed)
                let serverParent = parent.map(aliases.server)
                for unit in units {
                    let key = keys[unit.id] ?? ""
                    if unit.folder, let folder = folders.first(where: { $0.id == unit.id }) {
                        if unit.at < 0 { export.emptyFolders.insert(folder.id) }
                        let live = folder.live.map { SyncFolder.Live(source: $0.source, limit: $0.limit, namedByFeed: $0.namedByFeed) }
                        put(SyncName.folder(aliases.server(folder.id)),
                            .folder(SyncFolder(name: folder.name, icon: sentIcon(folder.icon), isOpen: folder.isOpen, space: serverSpace, parent: serverParent,
                                               position: key, live: live)))
                    } else if let page = space.bookmarks.first(where: { $0.id == unit.id }) {
                        put(SyncName.page(aliases.server(page.id)),
                            .page(SyncPage(url: page.url, title: page.title, icon: sentIcon(page.icon), space: serverSpace, parent: serverParent, position: key)))
                    }
                }
            }
            var splits = (space.pinnedSplits ?? []).filter { !$0.ids.contains(where: livePages.contains) }.compactMap { mapped($0, aliases.server) }
            let earlierSplits: [PinnedSplit]? = if case .space(let v)? = previous[SyncName.space(serverSpace)]?.body { v.splits } else { nil }
            splits += pendingSplits(earlierSplits, here: Set(space.bookmarks.map { aliases.server($0.id) }), name: SyncName.page)
            var look = space
            look.id = serverSpace
            look.icon = sentIcon(space.icon)
            var profile = aliases.server(directory.profileID(ofSpace: space.id))
            if kept.contains(directory.profileID(ofSpace: space.id)) {
                profile = if case .space(let v)? = previous[SyncName.space(serverSpace)]?.body { v.profile } else { Profile.defaultID }
            }
            put(SyncName.space(serverSpace),
                .space(SyncSpace(look: look, profile: profile, position: spaceKeys[space.id] ?? "", splits: splits)))
        }

        // Site rules for the synced spaces
        let synced = Set(spaces.map(\.id))
        var routes = contents.siteRoutes.filter { synced.contains($0.spaceID) }
        for i in routes.indices { routes[i].spaceID = aliases.server(routes[i].spaceID) }
        // Waiting records, and the rules for spaces not here yet, stay as they are.
        if case .rules(let earlier)? = previous[SyncName.rules]?.body {
            let here = Set(spaces.map { aliases.server($0.id) })
            for (i, route) in earlier.routes.rules.enumerated() where !here.contains(route.spaceID) && !routes.contains(where: { $0.id == route.id }) {
                let space = SyncName.space(route.spaceID)
                let readable = previous[space].map { if case .unknown = $0.body { false } else { true } } ?? false
                guard !readable || held.contains(space) else { continue }
                routes.insert(route, at: min(i, routes.count))
            }
        }
        put(SyncName.rules, .rules(SyncRules(routes: routes)))

        // Preferences, each with the date it was last seen to change
        let earlier: [String: SyncSettings.Entry] = if case .settings(let s)? = previous[SyncName.settings]?.body { s.values } else { [:] }
        var values: [String: SyncSettings.Entry] = [:]
        var current: [String: SettingValue] = [:]
        for (key, value) in library.settings {
            let owner = SyncPreferences.owner(key)
            guard owner.carried, !(owner.profile.map { isLocalOnly(profile: $0, in: directory) || kept.contains($0) } ?? false) else { continue }
            current[SyncPreferences.renamed(key, aliases.server)] = value
        }
        if library.searchEngine != .fromExtension { current[SyncPreferences.searchEngineKey] = .string(library.searchEngine.rawValue) }
        // Too big for iCloud: one bigger than a value may be, and, when together they're bigger than `largestTotal`,
        // first what iCloud doesn't have yet (this Mac's own additions), then what's grown here since, the biggest first,
        // until the rest fit. One that stays here keeps iCloud's entry as it is, or the record leaves it out, and this
        // Mac keeps its own; never sent as unset, so no other Mac loses its value. Only this Mac's own values choose
        // what stays here: what another Mac changed is taken as usual (`apply`'s `keepHere`).
        let inICloud = settingsInICloud ?? earlier
        func cost(_ key: String, _ value: SettingValue?) -> Int { value == nil ? 0 : SyncPreferences.cost(key, value) }
        var tooBig = Set(current.filter { SyncPreferences.isTooBig($0.value) }.keys)
        for (key, value) in current {
            if tooBig.contains(key) { values[key] = inICloud[key]; continue }
            values[key] = earlier[key].flatMap { $0.value == value ? $0 : nil } ?? .init(value: value, modified: changed(key))
        }
        var total = values.reduce(0) { $0 + cost($1.key, $1.value.value) }
        func bySize(_ keys: [String]) -> [String] { keys.sorted { (cost($0, current[$0]), $0) > (cost($1, current[$1]), $1) } }
        let added = bySize(current.keys.filter { !tooBig.contains($0) && inICloud[$0] == nil && $0 != SyncPreferences.searchEngineKey })
        for key in added where total > SyncPreferences.largestTotal {
            total -= cost(key, current[key])
            values[key] = nil
            tooBig.insert(key)
        }
        let grown = bySize(current.keys.filter { key in
            guard !tooBig.contains(key), key != SyncPreferences.searchEngineKey, let theirs = inICloud[key] else { return false }
            return theirs.value != current[key] && cost(key, current[key]) > cost(key, theirs.value)
        })
        for key in grown where total > SyncPreferences.largestTotal {
            total += cost(key, inICloud[key]?.value) - cost(key, current[key])
            values[key] = inICloud[key]
            tooBig.insert(key)
        }
        export.staysHere = Set(tooBig.map { SyncPreferences.renamed($0, aliases.local) })
        // A preference set back to its default is sent as unset; the search engine chosen from an extension stays as it was.
        for (key, entry) in earlier where values[key] == nil && !tooBig.contains(key) {
            if key == SyncPreferences.searchEngineKey, library.searchEngine == .fromExtension { values[key] = entry; continue }
            // One this version doesn't know, or a profile's not here (yet), or a kept profile's: as iCloud has it.
            let owner = SyncPreferences.owner(SyncPreferences.renamed(key, aliases.local))
            if key != SyncPreferences.searchEngineKey, !owner.carried { values[key] = entry; continue }
            if let profile = owner.profile, kept.contains(profile) || directory.profile(profile) == nil { values[key] = entry; continue }
            values[key] = entry.value == nil ? entry : .init(value: nil, modified: changed(key))
        }
        let settingsModified = values.values.map(\.modified).max() ?? previous[SyncName.settings]?.modified ?? now
        items[SyncName.settings] = SyncItem(.settings(SyncSettings(values: values)), modified: settingsModified)

        for name in held where items[name] == nil { items[name] = previous[name] }
        export.items = items
        return export
    }

    private static func mapped(_ split: PinnedSplit, _ map: (UUID) -> UUID) -> PinnedSplit? {
        split.layout.withPages(split.ids.map(map)).map(PinnedSplit.init(layout:))
    }

    // MARK: Records to library

    struct Applied {
        var library: SyncLibrary
    }

    /// `kept`: profiles removed on another Mac and kept here, with their spaces, favorites and settings as they are.
    /// `keepHere`: preferences this Mac keeps as they are here, too big for iCloud (`Export.staysHere`).
    static func apply(_ items: [String: SyncItem], onto library: SyncLibrary, aliases: SyncAliases, kept: Set<UUID> = [],
                      unsent: Set<String> = [], keepHere: Set<String> = []) -> Applied {
        let held = waiting(items, unsent: unsent, kept: Set(kept.map { SyncName.profile(aliases.server($0)) }))
        let items = items.filter { !held.contains($0.key) }
        var spaces: [(UUID, SyncSpace)] = [], profiles: [(UUID, SyncProfile)] = [], pages: [(UUID, SyncPage)] = []
        var folders: [(UUID, SyncFolder)] = [], favorites: [(UUID, SyncFavorite)] = []
        var rules: SyncRules?, settings: SyncSettings?
        for (name, item) in items {
            let id = SyncName.id(name).map(aliases.local)
            switch item.body {
            case .space(let v): if let id { spaces.append((id, v)) }
            case .profile(let v): if let id { profiles.append((id, v)) }
            case .page(let v): if let id { pages.append((id, v)) }
            case .folder(let v): if let id { folders.append((id, v)) }
            case .favorite(let v): if let id { favorites.append((id, v)) }
            case .rules(let v): rules = v
            case .settings(let v): settings = v
            case .unknown, .removals: break
            }
        }
        let old = library.contents
        var result = Applied(library: library)
        var directory = old.directory

        // Profiles: the first one's name and color, the others in their order.
        let headless = directory.headless
        profiles = SyncOrder.sorted(profiles, key: { $0.1.position }, id: { aliases.server($0.0) })
        let deleting = Set(directory.deleting.map(\.id))
        var listed: Set<UUID> = [Profile.defaultID]
        for (id, profile) in profiles where id != headless?.id && !deleting.contains(id) {
            if directory.profile(id) == nil { directory.add(name: profile.name ?? "", color: profile.color, id: id) }
            directory.update(id, name: profile.name, color: profile.color)
            listed.insert(id)
        }
        // A profile iCloud doesn't have stays, after the others.
        directory.arrange(profiles.map(\.0).filter(listed.contains))
        func profileHere(_ id: UUID) -> UUID {
            let local = aliases.local(id)
            return directory.profile(local) != nil && local != headless?.id ? local : Profile.defaultID
        }

        // Spaces in their order, then the ones only this Mac has (the AI Apps profile's) after them.
        spaces = SyncOrder.sorted(spaces, key: { $0.1.position }, id: { aliases.server($0.0) })
        let byID = Dictionary(old.spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localOnly = old.spaces.filter { isLocalOnly(profile: old.directory.profileID(ofSpace: $0.id), in: old.directory) }
        var newSpaces: [SpaceInfo] = []
        for (id, record) in spaces where !localOnly.contains(where: { $0.id == id }) {
            var space = record.look
            space.id = id
            if let here = byID[id] {
                space.backgroundImage = here.backgroundImage
                space.importedFrom = here.importedFrom
                space.icon = keptIcon(record.look.icon, local: here.icon)
            }
            space.bookmarks = []
            space.folders = nil
            space.pinnedSplits = nil
            space.routedSites = nil
            newSpaces.append(space)
            // A space on a kept profile stays on it, unless iCloud puts it on another profile of its own.
            let current = old.directory.profileID(ofSpace: id), target = profileHere(record.profile)
            directory.assign(space: id, to: kept.contains(current) && (target == Profile.defaultID || kept.contains(target)) ? current : target)
        }
        let syncedSpaceIDs = Set(newSpaces.map(\.id))
        // Where what lost its space goes: the first space.
        let fallbackSpace = newSpaces.first?.id

        // Pages and folders into their spaces.
        let oldPages = Dictionary(old.spaces.flatMap(\.bookmarks).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldFolders = Dictionary(old.spaces.flatMap { $0.folders ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func spaceHere(_ id: UUID) -> UUID? {
            let local = aliases.local(id)
            return syncedSpaceIDs.contains(local) ? local : fallbackSpace
        }
        var folderSpace: [UUID: UUID] = [:]
        for (id, folder) in folders { if let s = spaceHere(folder.space) { folderSpace[id] = s } }
        var children: [UUID: [UUID?: [(key: String, id: UUID, folder: Bool)]]] = [:]
        var folderRecords: [UUID: SyncFolder] = [:]
        for (id, folder) in folders {
            guard let s = folderSpace[id] else { continue }
            folderRecords[id] = folder
            var parent = folder.parent.map(aliases.local)
            if let p = parent, folderSpace[p] != s || p == id { parent = nil }
            children[s, default: [:]][parent, default: []].append((folder.position, id, true))
        }
        // A folder inside its own subfolders goes to the top of its space.
        func loops(_ id: UUID, in s: UUID) -> Bool {
            var seen: Set<UUID> = [id], current = id
            while let p = parentOf(current, in: s) { if !seen.insert(p).inserted { return true }; current = p }
            return false
        }
        func parentOf(_ id: UUID, in s: UUID) -> UUID? {
            children[s]?.first { $0.value.contains { $0.id == id } }?.key ?? nil
        }
        for s in children.keys {
            for (parent, list) in children[s] ?? [:] where parent != nil {
                for unit in list where unit.folder && loops(unit.id, in: s) {
                    children[s]?[parent]?.removeAll { $0.id == unit.id }
                    children[s]?[nil, default: []].append(unit)
                }
            }
        }
        var pageRecords: [UUID: SyncPage] = [:]
        for (id, page) in pages {
            guard let s = spaceHere(page.space) else { continue }
            pageRecords[id] = page
            var parent = page.parent.map(aliases.local)
            if let p = parent, folderSpace[p] != s || folderRecords[p]?.live != nil { parent = nil }
            children[s, default: [:]][parent, default: []].append((page.position, id, false))
        }

        for i in newSpaces.indices {
            let s = newSpaces[i].id
            let tree = children[s] ?? [:]
            var list: [Bookmark] = []
            var made: [BookmarkFolder] = []
            func emit(_ parent: UUID?) {
                for unit in SyncOrder.sorted(tree[parent] ?? [], key: { $0.key }, id: { aliases.server($0.id) }) {
                    if unit.folder, let record = folderRecords[unit.id] {
                        let here = oldFolders[unit.id]
                        var folder = BookmarkFolder(id: unit.id, name: record.name)
                        folder.icon = keptIcon(record.icon, local: here?.icon)
                        folder.isOpen = record.isOpen
                        folder.parentID = parent
                        folder.groupID = here?.groupID
                        folder.tucked = !record.isOpen && here?.isOpen == false ? here?.tucked : nil
                        if let live = record.live {
                            let kept = here?.live.flatMap { $0.source == live.source ? $0.items : nil } ?? []
                            folder.live = LiveFolder(source: live.source, limit: live.limit, namedByFeed: live.namedByFeed, items: kept)
                            // Its fetched pages stay as they were here.
                            let own = here?.bookmarkIDs.compactMap { oldPages[$0] }.filter { id in kept.contains { $0.bookmarkID == id.id } } ?? []
                            list.append(contentsOf: own)
                            folder.bookmarkIDs = own.map(\.id)
                            made.append(folder)
                        } else {
                            made.append(folder)
                            emit(unit.id)
                        }
                    } else if let record = pageRecords[unit.id] {
                        list.append(Bookmark(id: unit.id, url: record.url, title: record.title, icon: keptIcon(record.icon, local: oldPages[unit.id]?.icon)))
                        if let parent, let f = made.firstIndex(where: { $0.id == parent }) { made[f].bookmarkIDs.append(unit.id) }
                    }
                }
            }
            emit(nil)
            let splits = spaces.first { $0.0 == s }?.1.splits.compactMap { mapped($0, aliases.local) } ?? []
            let tidy = Library.tidied(list, made, splits)
            newSpaces[i].bookmarks = tidy.bookmarks
            newSpaces[i].folders = tidy.folders.isEmpty ? nil : tidy.folders
            newSpaces[i].pinnedSplits = tidy.splits.isEmpty ? nil : tidy.splits
        }
        var contents = old
        // No space in iCloud at all: nothing here is taken away.
        contents.spaces = newSpaces.isEmpty ? old.spaces : newSpaces + localOnly

        // Favorites, each profile's in its order; the AI Apps profile's stay.
        favorites = SyncOrder.sorted(favorites, key: { $0.1.position }, id: { aliases.server($0.0) })
        let oldFavorites = Dictionary(old.favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newFavorites: [Bookmark] = []
        for (id, record) in favorites {
            newFavorites.append(Bookmark(id: id, url: record.url, title: record.title, icon: keptIcon(record.icon, local: oldFavorites[id]?.icon)))
            directory.assign(favorite: id, to: profileHere(record.profile))
        }
        let keptFavorites = old.favorites.filter { favorite in
            let profile = old.directory.profileID(ofFavorite: favorite.id)
            return profile == headless?.id || kept.contains(profile)
        }
        contents.favorites = newFavorites + keptFavorites
        let keptIDs = Set(keptFavorites.map(\.id))
        contents.favoriteSplits = profiles.flatMap { $0.1.favoriteSplits.compactMap { mapped($0, aliases.local) } }
            + old.favoriteSplits.filter { $0.ids.allSatisfy(keptIDs.contains) }

        // Site rules for the synced spaces; the AI Apps spaces' stay.
        if let rules {
            let here = Set(contents.spaces.map(\.id))
            var routes = rules.routes.rules
            for i in routes.indices { routes[i].spaceID = aliases.local(routes[i].spaceID) }
            let localOnlyIDs = Set(localOnly.map(\.id))
            contents.siteRoutes = routes.filter { here.contains($0.spaceID) } + old.siteRoutes.filter { localOnlyIDs.contains($0.spaceID) }
        }
        contents.directory = directory
        result.library.contents = contents

        // Preferences; one this Mac keeps here, too big for iCloud, stays as it is. Only this Mac's own choice of
        // what stays: what arrives is never made to stay.
        if let settings {
            for (key, entry) in settings.values {
                if key == SyncPreferences.searchEngineKey {
                    if case .string(let raw)? = entry.value, let engine = SearchEngine(rawValue: raw), engine != .fromExtension,
                       library.searchEngine != .fromExtension {
                        result.library.searchEngine = engine
                    }
                    continue
                }
                let local = SyncPreferences.renamed(key, aliases.local)
                let owner = SyncPreferences.owner(local)
                guard owner.carried, !(owner.profile.map(kept.contains) ?? false), !keepHere.contains(local), !SyncPreferences.isTooBig(library.settings[local]) else { continue }
                if local == "SiteIcons" {
                    // Picture icons set here stay.
                    let images: [String: SettingValue] = if case .dictionary(let d)? = library.settings[local] {
                        d.filter { if case .string(let name) = $0.value { name.hasPrefix(PageImageIcon.prefix) } else { false } }
                    } else { [:] }
                    if case .dictionary(let d)? = entry.value { result.library.settings[local] = .dictionary(d.merging(images) { a, _ in a }) }
                    else { result.library.settings[local] = images.isEmpty ? nil : .dictionary(images) }
                    continue
                }
                result.library.settings[local] = entry.value
            }
        }
        return result
    }
}
