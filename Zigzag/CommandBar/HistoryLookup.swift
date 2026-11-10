import Foundation

/// The command bar's reads of History, off the main thread, so a letter typed never waits on them however big History
/// grows. What's typed now is asked for; an answer for text since typed over is dropped, or never read at all.
final class HistoryLookup {
    private var store: HistoryStore
    /// Told when pages arrive for what was last asked.
    var onPages: (() -> Void)?
    /// Told when sites for inline completion arrive for what was last asked.
    var onSites: (() -> Void)?
    private var pages: (key: String, entries: [HistoryEntry])?
    private var askedPages: String?
    private var sites: (prefix: String, found: [(entry: HistoryEntry, score: Double)])?
    private var askedSites: String?
    // The bar's own, so its reads only ever stop each other, never a History tab's; pages and sites don't stop each other.
    private let pagesAsker = UUID().hashValue, sitesAsker = UUID().hashValue

    init(store: HistoryStore) { self.store = store }

    /// The bar is used in a profile: its history is the one read from now on. Another's answers are dropped.
    func use(_ store: HistoryStore) {
        guard store !== self.store else { return }
        self.store = store
        reset()
    }

    /// A fresh bar: History may have changed since it was last open.
    func reset() {
        pages = nil
        askedPages = nil
        sites = nil
        askedSites = nil
    }

    /// Pages matching `query`: the answer once it's read. Meanwhile, the last answer's pages that still match, so the
    /// rows already showing stay put rather than blinking out and back with each letter; nil when none do.
    func pages(for query: String, limit: Int) -> [HistoryEntry]? {
        let words = HistoryStore.words(query)
        guard !words.isEmpty else { return [] }
        let key = "\(limit)|" + words.joined(separator: " ")
        // Back to the text already answered (a letter typed, then deleted): an answer still coming for the other is dropped.
        if let pages, pages.key == key { askedPages = nil; return pages.entries }
        if askedPages != key {
            askedPages = key
            Task { [weak self, store, pagesAsker] in
                let entries = await store.search(query, limit: limit, asker: pagesAsker) { $0 }
                guard let self, let entries, self.askedPages == key else { return }
                self.pages = (key, entries)
                self.askedPages = nil
                self.onPages?()
            }
        }
        let meanwhile = pages?.entries.filter { CommandRanker.matches(words, $0.title, $0.url.absoluteString) } ?? []
        return meanwhile.isEmpty ? nil : meanwhile
    }

    /// Sites to complete `prefix` to, or nil until they're read.
    func completionSites(for prefix: String) -> [(entry: HistoryEntry, score: Double)]? {
        if let sites, sites.prefix == prefix { askedSites = nil; return sites.found }
        if askedSites != prefix {
            askedSites = prefix
            Task { [weak self, store, sitesAsker] in
                let found = await store.completionSites(for: prefix, asker: sitesAsker)
                guard let self, let found, self.askedSites == prefix else { return }
                self.sites = (prefix, found)
                self.askedSites = nil
                self.onSites?()
            }
        }
        return nil
    }

    /// Nothing more to complete (a letter deleted, an input method composing): an answer still coming is dropped.
    func stopSites() { askedSites = nil }
}
