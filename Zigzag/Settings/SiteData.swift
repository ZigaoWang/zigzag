import WebKit

// MARK: - What sites keep, as Settings lists it (#207)

/// What kinds of things a site keeps, in the three words Settings says them in.
nonisolated struct SiteDataKinds: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let cookies = SiteDataKinds(rawValue: 1)
    /// Local storage, databases, service workers: what keeps a site's own state.
    static let saved = SiteDataKinds(rawValue: 2)
    static let cache = SiteDataKinds(rawValue: 4)

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                                          WKWebsiteDataTypeOfflineWebApplicationCache]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(types: Set<String>) {
        var kinds: SiteDataKinds = []
        if types.contains(WKWebsiteDataTypeCookies) { kinds.insert(.cookies) }
        if !types.isDisjoint(with: Self.cacheTypes) { kinds.insert(.cache) }
        if !types.subtracting(Self.cacheTypes).subtracting([WKWebsiteDataTypeCookies]).isEmpty { kinds.insert(.saved) }
        self = kinds
    }
}

/// One record as WebKit lists it, without WebKit's object: its name, what it keeps, and its size when known.
nonisolated struct SiteDataRecord: Sendable, Hashable {
    let name: String
    let kinds: SiteDataKinds
    var size: Int64?

    init(name: String, kinds: SiteDataKinds, size: Int64? = nil) {
        self.name = name
        self.kinds = kinds
        self.size = size
    }
}

/// A site in the list: every record of one registrable domain (news.bbc.co.uk and bbc.co.uk are bbc.co.uk),
/// what they keep between them, and their size added up.
nonisolated struct SiteDataEntry: Sendable, Hashable {
    let site: String
    let kinds: SiteDataKinds
    /// Nil until WebKit has said, or when it can't.
    let size: Int64?
    /// The records' own names, to remove them by.
    let names: [String]
}

nonisolated enum SiteDataSort: Int, Sendable, CaseIterable { case name, size }

/// The list's logic, apart from WebKit and the screen: grouping, sorting, finding.
nonisolated enum SiteDataListing {
    /// The site a record is listed under: its registrable domain, or its own name where there's none (localhost,
    /// an address, a name the Public Suffix List doesn't know).
    static func site(of name: String) -> String {
        let name = name.lowercased()
        return PublicSuffix.registrableDomain(name) ?? name
    }

    /// The records by site, sorted by name.
    static func group(_ records: [SiteDataRecord]) -> [SiteDataEntry] {
        var bySite: [String: (kinds: SiteDataKinds, size: Int64?, names: [String])] = [:]
        for record in records where !record.name.isEmpty {
            let site = site(of: record.name)
            var entry = bySite[site] ?? ([], nil, [])
            entry.kinds.formUnion(record.kinds)
            if let size = record.size { entry.size = (entry.size ?? 0) + size }
            entry.names.append(record.name)
            bySite[site] = entry
        }
        return sort(bySite.map { SiteDataEntry(site: $0.key, kinds: $0.value.kinds, size: $0.value.size, names: $0.value.names) }, by: .name)
    }

    /// By name, as Finder sorts (a2 before a10); or largest first, sites with no size known last, by name.
    static func sort(_ entries: [SiteDataEntry], by order: SiteDataSort) -> [SiteDataEntry] {
        entries.sorted { a, b in
            if order == .size, a.size != b.size { return (a.size ?? -1) > (b.size ?? -1) }
            return a.site.localizedStandardCompare(b.site) == .orderedAscending
        }
    }

    /// The words of a search, as typed.
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// The entries whose site has every word, in the order given.
    static func filter(_ entries: [SiteDataEntry], words: [String]) -> [SiteDataEntry] {
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in words.allSatisfy { matches($0, in: entry.site) } }
    }

    static func matches(_ word: String, in site: String) -> Bool {
        site.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Where each word is in a site's name, to mark it.
    static func matchRanges(of words: [String], in site: String) -> [NSRange] {
        let text = site as NSString
        return words.map { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.filter { $0.location != NSNotFound }
    }

    /// Sizes read later, put into the entries they belong to (by each record's name).
    static func applying(sizes: [String: Int64], to entries: [SiteDataEntry]) -> [SiteDataEntry] {
        entries.map { entry in
            let known = entry.names.compactMap { sizes[$0] }
            return SiteDataEntry(site: entry.site, kinds: entry.kinds, size: known.isEmpty ? entry.size : known.reduce(0, +), names: entry.names)
        }
    }
}

// MARK: - Where it comes from

/// What the list reads from and removes in: a profile's website data store, or a made-up one in tests.
@MainActor
protocol SiteDataSource: AnyObject {
    func records() async -> [SiteDataRecord]
    /// Each record's size, by name; empty when it can't be told.
    func sizes() async -> [String: Int64]
    /// Everything the records of these names keep.
    func remove(_ names: [String]) async
    /// Everything every site keeps.
    func removeAll() async
}

/// A profile's website data, read from WebKit. Records are fetched with every type, so a site's row says all
/// it keeps; WebKit does the reading in its own process, never on this thread.
final class WebKitSiteData: SiteDataSource {
    let store: WKWebsiteDataStore
    /// The last records read, by name, for removing them.
    private var byName: [String: WKWebsiteDataRecord] = [:]

    init(store: WKWebsiteDataStore) { self.store = store }

    func records() async -> [SiteDataRecord] {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        byName = Dictionary(records.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        return records.map { SiteDataRecord(name: $0.displayName, kinds: SiteDataKinds(types: $0.dataTypes)) }
    }

    /// WebKit's sizes come only from its private fetch with sizes computed (what Safari's Manage Website Data
    /// uses). Where that isn't there, the list has no sizes and sorts by name.
    private static let fetchWithOptions = NSSelectorFromString("_fetchDataRecordsOfTypes:withOptions:completionHandler:")
    /// _WKWebsiteDataStoreFetchOptionComputeSizes.
    private static let computeSizes: UInt = 1 << 0

    func sizes() async -> [String: Int64] {
        guard store.responds(to: Self.fetchWithOptions), WKWebsiteDataRecord.instancesRespond(to: NSSelectorFromString("_dataSize")),
              let method = class_getInstanceMethod(type(of: store), Self.fetchWithOptions) else { return [:] }
        typealias Fetch = @convention(c) (AnyObject, Selector, NSSet, UInt, @escaping @convention(block) (NSArray) -> Void) -> Void
        let fetch = unsafeBitCast(method_getImplementation(method), to: Fetch.self)
        let types = WKWebsiteDataStore.allWebsiteDataTypes() as NSSet
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { done in
            fetch(store, Self.fetchWithOptions, types, Self.computeSizes) { array in done.resume(returning: array.compactMap { $0 as? WKWebsiteDataRecord }) }
        }
        var sizes: [String: Int64] = [:]
        for record in records {
            guard let size = record.value(forKey: "_dataSize") as? NSObject, size.responds(to: NSSelectorFromString("totalSize")),
                  let total = size.value(forKey: "totalSize") as? NSNumber else { continue }
            sizes[record.displayName, default: 0] += total.int64Value
        }
        return sizes
    }

    func remove(_ names: [String]) async {
        let records = names.compactMap { byName[$0] }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        names.forEach { byName[$0] = nil }
        // Dark pages' sites seen dark go with the site's data, as when cookies are cleared.
        for name in Set(names.map(SiteDataListing.site(of:))) { DarkSeen.forget(in: store, site: name) }
    }

    func removeAll() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        byName = [:]
        DarkSeen.forget(in: store)
    }
}

// MARK: - The list's state

/// One profile's list while Settings is open: read once when it's first shown and kept, read again in the
/// background when the pane is shown again, so it never empties while you look. Grouping and sorting happen off
/// the main thread.
@MainActor
final class SiteDataModel {
    enum State: Equatable { case idle, loading, loaded }

    let source: SiteDataSource
    private(set) var state = State.idle
    /// Every site, in the order chosen.
    private(set) var entries: [SiteDataEntry] = []
    /// The sites shown: those matching the search, in order.
    private(set) var shown: [SiteDataEntry] = []
    /// The list's own search, and "Find a setting"'s words while that's in use.
    var query = "" { didSet { if query != oldValue { refilter() } } }
    var outsideWords: [String] = [] { didSet { if outsideWords != oldValue { refilter() } } }
    var order = SiteDataSort.name {
        didSet {
            guard order != oldValue else { return }
            entries = SiteDataListing.sort(entries, by: order)
            refilter()
        }
    }
    /// Whether sizes have come in.
    private(set) var hasSizes = false
    /// Called when what's shown changes.
    var changed: (() -> Void)?
    private var reading: Task<Void, Never>?

    init(source: SiteDataSource) { self.source = source }

    var words: [String] { SiteDataListing.words(query) + outsideWords }
    var isFiltering: Bool { !words.isEmpty }

    /// Reads the list again; what's there stays until the new one is in, sizes included until new ones come.
    /// Several asks while reading are one read.
    func refresh() {
        guard reading == nil else { return }
        if state == .idle { state = .loading }
        // Removed sites stay off the list until a read that starts after their removal is done.
        if removing == 0 { removed = [] }
        reading = Task { [weak self] in
            guard let self else { return }
            let records = await self.source.records()
            let order = self.order
            let known = Dictionary(self.entries.compactMap { entry in entry.size.map { (entry.site, $0) } }, uniquingKeysWith: { a, _ in a })
            let entries = await Task.detached(priority: .userInitiated) {
                SiteDataListing.sort(SiteDataListing.group(records).map { entry in
                    SiteDataEntry(site: entry.site, kinds: entry.kinds, size: entry.size ?? known[entry.site], names: entry.names)
                }, by: order)
            }.value
            self.take(entries)
            let sizes = await self.source.sizes()
            if !sizes.isEmpty {
                let current = self.entries, order = self.order
                self.hasSizes = true
                self.take(await Task.detached(priority: .utility) { SiteDataListing.sort(SiteDataListing.applying(sizes: sizes, to: current), by: order) }.value)
            }
            self.reading = nil
        }
    }

    /// Waits for a read in progress (tests).
    func settle() async { await reading?.value }

    private var removed: Set<String> = []
    private var removing = 0

    private func take(_ new: [SiteDataEntry]) {
        let new = removed.isEmpty ? new : new.filter { !removed.contains($0.site) }
        let wasLoaded = state == .loaded
        state = .loaded
        guard new != entries || !wasLoaded else { return }
        entries = new
        refilter()
    }

    private func refilter() {
        shown = SiteDataListing.filter(entries, words: words)
        changed?()
    }

    /// Removes these sites' data, and takes them off the list at once.
    func remove(_ sites: [SiteDataEntry]) async {
        let gone = Set(sites.map(\.site))
        removed.formUnion(gone)
        entries.removeAll { gone.contains($0.site) }
        refilter()
        removing += 1
        await source.remove(sites.flatMap(\.names))
        removing -= 1
    }

    /// Removes every site's data, or only those shown while searching.
    func removeAllShown() async {
        if isFiltering {
            await remove(shown)
        } else {
            removed.formUnion(entries.map(\.site))
            entries = []
            refilter()
            removing += 1
            await source.removeAll()
            removing -= 1
        }
    }
}