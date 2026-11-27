import AppKit
import UniformTypeIdentifiers

/// A Zigzag backup (File › Export Your Data…): one JSON file with spaces, pinned tabs, folders, splits, favorites,
/// profiles, site rules, and optionally open tabs, history and settings. Restored from File › Import, merged into
/// what's here without making copies. Never passwords, cookies or sign-ins.
struct ZigzagBackup: Codable {
    static let formatName = "Zigzag Backup"
    static let currentVersion = 1
    static let fileExtension = "zigzagbackup"
    static let contentType = UTType(exportedAs: "wang.zigao.zigzag.backup", conformingTo: .json)

    var format = Self.formatName
    var version = Self.currentVersion
    var created = Date()
    var appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var profiles: [ProfileInfo] = []
    var spaces: [SpaceInfo] = []
    /// Space ID to profile ID, for spaces not on the first profile.
    var spaceProfiles: [String: UUID] = [:]
    var favorites: [Bookmark] = []
    /// Favorite ID to profile ID, for favorites not the first profile's.
    var favoriteProfiles: [String: UUID] = [:]
    var favoriteSplits: [PinnedSplit] = []
    var siteRoutes: [SiteRoutes.Route] = []
    /// Image icons (`image:` names) and space pictures, by the name they're kept under.
    var pageIcons: [String: Data] = [:]
    var backgrounds: [String: Data] = [:]

    var openTabs: [SpaceTabs]? = nil
    var history: [ProfileHistory]? = nil
    var settings: Settings? = nil

    struct Page: Codable, Equatable {
        var url: URL
        var title: String
        var customTitle: String? = nil
    }

    /// One space's open tabs, top to bottom: each row a page, or a split's pages.
    struct SpaceTabs: Codable, Equatable {
        var spaceID: UUID
        var rows: [[Page]]
    }

    struct Visit: Codable, Equatable {
        var url: URL
        var title: String
        var count: Int
        var lastVisit: Date
    }

    struct ProfileHistory: Codable {
        var profile: UUID
        var visits: [Visit]
    }

    struct Settings: Codable, Equatable {
        var searchEngine: SearchEngine?
        var language: String?
        var values: [String: SettingValue] = [:]
    }

    enum ReadError: Error, Equatable { case unreadable, newer }

    // MARK: Reading and writing

    static func isBackup(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> Result<ZigzagBackup, ReadError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Header: Decodable { var format: String; var version: Int }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatName else { return .failure(.unreadable) }
        guard header.version <= currentVersion else { return .failure(.newer) }
        guard let backup = try? decoder.decode(ZigzagBackup.self, from: data) else { return .failure(.unreadable) }
        return .success(backup)
    }

    static func read(_ url: URL) -> Result<ZigzagBackup, ReadError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return decode(data)
    }

    // MARK: Making one

    /// What's here now. Private windows keep nothing in the library and their tabs are skipped. `pagesOnly` leaves out
    /// settings and pictures, for the bookmarks file.
    static func make(library: Library = .shared, managers: [TabManager], openTabs: Bool, history: Bool, pagesOnly: Bool = false, defaults: UserDefaults = .standard,
                     iconFolder: URL = PageImageIcon.folder, backgroundFolder: URL = SpaceBackground.folder) -> ZigzagBackup {
        var backup = ZigzagBackup()
        let contents = library.contents
        backup.profiles = contents.directory.all
        backup.spaces = contents.spaces
        for space in contents.spaces where contents.directory.profileID(ofSpace: space.id) != Profile.defaultID {
            backup.spaceProfiles[space.id.uuidString] = contents.directory.profileID(ofSpace: space.id)
        }
        backup.favorites = contents.favorites
        for favorite in contents.favorites where contents.directory.profileID(ofFavorite: favorite.id) != Profile.defaultID {
            backup.favoriteProfiles[favorite.id.uuidString] = contents.directory.profileID(ofFavorite: favorite.id)
        }
        backup.favoriteSplits = contents.favoriteSplits
        backup.siteRoutes = contents.siteRoutes
        if openTabs { backup.openTabs = Self.openTabs(of: managers, spaces: contents.spaces.map(\.id)) }
        guard !pagesOnly else { return backup }

        var icons = contents.favorites.compactMap(\.icon) + contents.spaces.flatMap { $0.bookmarks.compactMap(\.icon) + [$0.icon].compactMap { $0 } }
        backup.settings = settings(from: defaults, profiles: Set(contents.directory.all.map(\.id)))
        backup.settings?.searchEngine = library.searchEngine
        backup.settings?.language = AppLanguage.chosen
        if case .dictionary(let sites)? = backup.settings?.values["SiteIcons"] {
            icons += sites.values.compactMap { if case .string(let icon) = $0 { icon } else { nil } }
        }
        for icon in icons {
            guard let name = PageImageIcon.name(of: icon), backup.pageIcons[name] == nil,
                  let data = try? Data(contentsOf: iconFolder.appendingPathComponent(name)) else { continue }
            backup.pageIcons[name] = data
        }
        for name in contents.spaces.compactMap(\.backgroundImage) where backup.backgrounds[name] == nil {
            guard !name.contains("/"), let data = try? Data(contentsOf: backgroundFolder.appendingPathComponent(name)) else { continue }
            backup.backgrounds[name] = data
        }
        if history {
            backup.history = contents.directory.all.map { profile in
                let visits = Profiles.shared.profile(profile.id).history.page(limit: 5_000_000)
                return ProfileHistory(profile: profile.id, visits: visits.map { Visit(url: $0.url, title: $0.title, count: $0.visitCount, lastVisit: $0.lastVisit) })
            }.filter { !$0.visits.isEmpty }
        }
        return backup
    }

    /// Every everyday window's open tabs (not pinned pages or favorites), each space's in order, split pages in one row.
    /// Windows sharing tabs are read once; private windows never.
    static func openTabs(of managers: [TabManager], spaces: [UUID]) -> [SpaceTabs] {
        var seen: Set<ObjectIdentifier> = []
        let windows = managers.filter { !$0.isPrivate && seen.insert(ObjectIdentifier($0.store)).inserted }
        var result: [SpaceTabs] = []
        for spaceID in spaces {
            var rows: [[Page]] = []
            var placed: Set<UUID> = []
            for manager in windows {
                let tabs = manager.tabs(in: spaceID)
                let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for tab in tabs where !placed.contains(tab.id) && !tab.isPrivate {
                    let group = manager.splits.first { $0.contains(tab.id) }.map { $0.ids.compactMap { byID[$0] } } ?? [tab]
                    placed.formUnion(group.map(\.id))
                    let pages = group.compactMap { tab -> Page? in
                        guard let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                        return Page(url: url, title: tab.title, customTitle: tab.customTitle)
                    }
                    if !pages.isEmpty { rows.append(pages) }
                }
            }
            if !rows.isEmpty { result.append(SpaceTabs(spaceID: spaceID, rows: rows)) }
        }
        return result
    }

    // MARK: Settings

    /// Preferences a backup carries: choices made in Settings and per site. Never passwords, sign-ins, keys or
    /// anything that lets other apps in (AI apps, AppleScript, trusted certificates), and never counters or one-time
    /// notes. Per-profile ones (`ProfileKey`) carry the profile's ID after a dot.
    static let settingKeys: Set<String> = [
        // General
        "AskBeforeQuitting", "LaunchChoice", "DownloadsAskWhere", "BetaUpdates", "SUAutomaticallyUpdate", "FormsAutofill",
        "NewSpacesGetOwnProfile", "OpensExternalLinksInMini", "CaptureMode", "CardFinish",
        // Look
        "borderlessPage", "addressBarPlace", "addressAbovePage", "sidebarOnRight", "sidebarDoubleClickNewTab", "SidebarSize", "SidebarSizePercent",
        "LargeSpaceNames", "FavoritesPerRow", "PinnedTabsAsTiles", "ShortFloatingSidebar", "ShowLinkAddressOnHover", "DefaultZoom", "ReduceMotion",
        "DarkPages", "DarkPagesPureBlack", "EdgeSidebar",
        // Tabs and windows
        "ControlTabOrder", "NestsOpenedLinks", "WindowsShareTabs", "ArchiveTabsAfter", "SleepsBusyTabs", "NewTabPlace", "NewTabPlaceOtherwise",
        "PictureInPictureFollowsTabs", "PictureInPictureWhenLeaving", "FullScreenFills", "SwipeBetweenPages", "OffersToPinWanderedPage",
        "CommandBarPosition", "InPageMini", "ShortcutOverrides", "SearchSuggestions", "CustomSearchTemplate", "pdfTwoPages",
        // Privacy
        "BlockAdsAndTrackers", "AdsAllowedSites", "ProtectsIPFromWebRTC", "JavaScriptAllowed", "JavaScriptOnSites", "JavaScriptOffSites",
        "CookieBanners", "CookieBannersHandledSites", "CookieBannersLeftSites", "SiteAsksBeforeDownloads",
        // Translation and Reader
        "TranslateInto", "TranslateOffers", "TranslateAlways", "TranslateNever", "TranslateNeverSites",
        "ReaderFace", "ReaderSize", "ReaderTheme", "ReaderWidth",
        // Per site
        "SiteBoosts", "ZoomLevels", "DarkPagesOnSites", "DarkPagesOffSites", "DarkPagesForcedSites", "SitePermissions", "SitePermissionActions",
        "UserAgentSites", "KeepAwakeSites", "FullScreenPageSites", "FullScreenScreenSites", "SiteIcons",
        // Developer
        "DeveloperTools", "DeveloperToolsInBar", "DeveloperPageSizes", "DevelopmentSites",
    ]

    /// Per-profile choices a backup carries.
    static let profileSettingKeys: Set<ProfileKey> = [.extensionsOffSites, .offersToSavePasswords, .fillsPasswords, .keptCookieSites, .clearsCookiesOnQuit]

    /// Whether `key` is a setting a backup carries, and whose: nil for Zigzag's own, a profile's ID for a profile's.
    static func settingOwner(_ key: String) -> (carried: Bool, profile: UUID?) {
        if settingKeys.contains(key) { return (true, nil) }
        for profileKey in profileSettingKeys {
            if key == profileKey.rawValue { return (true, nil) }
            let prefix = profileKey.rawValue + "."
            if key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))) { return (true, id) }
        }
        return (false, nil)
    }

    /// The carried settings set in `defaults`, of these profiles.
    static func settings(from defaults: UserDefaults, profiles: Set<UUID>) -> Settings {
        var values: [String: SettingValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            let owner = settingOwner(key)
            guard owner.carried, owner.profile.map(profiles.contains) ?? true, let setting = SettingValue(value) else { continue }
            values[key] = setting
        }
        return Settings(values: values)
    }

    /// Writes the carried settings into `defaults`; ones for a profile that isn't here are left out. Returns how many.
    @discardableResult
    static func apply(_ settings: Settings, to defaults: UserDefaults, profiles: Set<UUID>, icons: [String: String] = [:]) -> Int {
        var count = 0
        for (key, value) in settings.values {
            let owner = settingOwner(key)
            guard owner.carried, owner.profile.map(profiles.contains) ?? true else { continue }
            var value = value
            if key == "SiteIcons", case .dictionary(let sites) = value { value = .dictionary(remapped(sites, icons: icons)) }
            defaults.set(value.object, forKey: key)
            count += 1
        }
        return count
    }

    /// Site icons with their image icons renamed as restored; ones that didn't come back are left out.
    private static func remapped(_ sites: [String: SettingValue], icons: [String: String]) -> [String: SettingValue] {
        sites.compactMapValues { value in
            guard case .string(let icon) = value, PageImageIcon.isImage(icon) else { return value }
            return icons[icon].map(SettingValue.string)
        }
    }

    /// Whether the backup's settings differ from these.
    func settingsDiffer(from defaults: UserDefaults, searchEngine: SearchEngine) -> Bool {
        guard let settings, !settings.values.isEmpty || settings.searchEngine != nil else { return false }
        if let engine = settings.searchEngine, engine != searchEngine { return true }
        return settings.values.contains { key, value in defaults.object(forKey: key).flatMap(SettingValue.init) != value }
    }
}

/// A preference value as JSON: what `UserDefaults` holds. Data and dates are tagged, the rest is plain JSON.
nonisolated indirect enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String), data(Data), date(Date)
    case array([SettingValue]), dictionary([String: SettingValue])

    init?(_ object: Any) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
            else { self = .int(number.intValue) }
        case let string as String: self = .string(string)
        case let data as Data: self = .data(data)
        case let date as Date: self = .date(date)
        case let array as [Any]:
            let values = array.compactMap(SettingValue.init)
            guard values.count == array.count else { return nil }
            self = .array(values)
        case let dictionary as [String: Any]:
            let values = dictionary.compactMapValues(SettingValue.init)
            guard values.count == dictionary.count else { return nil }
            self = .dictionary(values)
        default: return nil
        }
    }

    var object: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .data(let value): value
        case .date(let value): value
        case .array(let values): values.map(\.object)
        case .dictionary(let values): values.mapValues(\.object)
        }
    }

    private enum Tag: String, CodingKey { case data = "$data", date = "$date" }

    init(from decoder: Decoder) throws {
        if let tagged = try? decoder.container(keyedBy: Tag.self), tagged.allKeys.count == 1 {
            if let data = try? tagged.decode(Data.self, forKey: .data) { self = .data(data); return }
            if let date = try? tagged.decode(Date.self, forKey: .date) { self = .date(date); return }
        }
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Int.self) { self = .int(value) }
        else if let value = try? single.decode(Double.self) { self = .double(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([SettingValue].self) { self = .array(value) }
        else { self = .dictionary(try single.decode([String: SettingValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .data(let value):
            var c = encoder.container(keyedBy: Tag.self)
            try c.encode(value, forKey: .data)
        case .date(let value):
            var c = encoder.container(keyedBy: Tag.self)
            try c.encode(value, forKey: .date)
        default:
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try c.encode(value)
            case .int(let value): try c.encode(value)
            case .double(let value): try c.encode(value)
            case .string(let value): try c.encode(value)
            case .array(let values): try c.encode(values)
            case .dictionary(let values): try c.encode(values)
            case .data, .date: break
            }
        }
    }
}
