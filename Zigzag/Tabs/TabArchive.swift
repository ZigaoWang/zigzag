import Foundation

/// Tabs not looked at for a while move from the sidebar to the archive, still found by the command bar and
/// zigzag://archive. Pinned, favorites, visible, playing, in a call and private tabs are never archived. Keeps a month,
/// newest first, saved to disk.
nonisolated struct ArchivedTab: Codable, Equatable, Identifiable {
    var id = UUID()
    let url: URL
    let title: String
    let spaceID: UUID
    let archivedAt: Date
}

final class TabArchive {
    static let shared = TabArchive()

    /// How long a tab can sit unseen before it's archived. Nil: never.
    enum After: String, CaseIterable {
        case twelveHours, day, week, never

        var interval: TimeInterval? {
            switch self {
            case .twelveHours: 12 * 3600
            case .day: 24 * 3600
            case .week: 7 * 24 * 3600
            case .never: nil
            }
        }

        var title: String {
            switch self {
            case .twelveHours: String(localized: "After 12 Hours", comment: "A choice in Settings for when tabs you haven't used are archived.")
            case .day: String(localized: "After a Day", comment: "A choice in Settings for when tabs you haven't used are archived.")
            case .week: String(localized: "After a Week", comment: "A choice in Settings for when tabs you haven't used are archived.")
            case .never: String(localized: "Never", comment: "A choice in Settings for when tabs you haven't used are archived. Tabs are never archived.")
            }
        }
    }

    static var after: After {
        // Off until you ask for it: tabs disappearing on their own is something you choose.
        get { After(rawValue: UserDefaults.standard.string(forKey: "ArchiveTabsAfter") ?? "") ?? .never }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ArchiveTabsAfter") }
    }

    /// Once, when a space's list has grown long: a quiet offer to turn archiving on. Never asked again.
    static func offerIfCrowded(tabCount: Int) {
        let d = UserDefaults.standard
        guard after == .never, d.string(forKey: "ArchiveTabsAfter") == nil, !d.bool(forKey: "ArchiveOffered"), tabCount >= 20,
              let controller = WindowManager.shared.keyController, !controller.tabManager.isPrivate else { return }
        d.set(true, forKey: "ArchiveOffered")
        Toast.show(String(localized: "Tidy tabs you haven’t used in a day?", comment: "Toast offered once when a space has many tabs: archive the ones unused for a day."), symbol: "archivebox",
                   action: (String(localized: "Turn On", comment: "Button in the toast that offers to archive unused tabs."), { after = .day }),
                   duration: 10, in: controller)
    }

    private(set) var entries: [ArchivedTab]
    private static let keep: TimeInterval = 30 * 24 * 3600
    private static let limit = 500

    /// Nil keeps it in memory only (tests).
    private let file: URL?

    init(file: URL? = Paths.file("Archive.json"), entries: [ArchivedTab]? = nil) {
        self.file = file
        self.entries = entries ?? file.flatMap { JSONStore.load([ArchivedTab].self, from: $0) } ?? []
        prune()
    }

    func entry(_ id: UUID) -> ArchivedTab? { entries.first { $0.id == id } }

    func add(_ entry: ArchivedTab) { add(contentsOf: [entry]) }

    /// Several at once (a morning's worth of tabs going quiet), written once.
    func add(contentsOf new: [ArchivedTab]) {
        guard !new.isEmpty else { return }
        for entry in new {
            entries.removeAll { $0.url == entry.url }
            entries.insert(entry, at: 0)
        }
        prune()
        save()
    }

    /// Taken out when it's opened again, so it never shows twice.
    func remove(url: URL) {
        let before = entries.count
        entries.removeAll { TabManager.normalize($0.url) == TabManager.normalize(url) }
        if entries.count != before { save() }
    }

    /// Clearing history clears archived tabs too (the address bar suggests them): all of them, or those archived
    /// since `date`. Handed back so ⌘Z can put them back. `belongs`: which ones the history being cleared covers
    /// (one profile's).
    func take(since date: Date?, where belongs: (ArchivedTab) -> Bool = { _ in true }) -> [ArchivedTab] {
        let goes = { (entry: ArchivedTab) in belongs(entry) && (date.map { entry.archivedAt >= $0 } ?? true) }
        let taken = entries.filter(goes)
        guard !taken.isEmpty else { return [] }
        entries.removeAll(where: goes)
        save()
        return taken
    }

    /// Pages taken out of History take their archived tabs with them.
    func take(_ urls: [URL], where belongs: (ArchivedTab) -> Bool = { _ in true }) -> [ArchivedTab] {
        let gone = Set(urls.map(TabManager.normalize))
        let goes = { (entry: ArchivedTab) in belongs(entry) && gone.contains(TabManager.normalize(entry.url)) }
        let taken = entries.filter(goes)
        guard !taken.isEmpty else { return [] }
        entries.removeAll(where: goes)
        save()
        return taken
    }

    /// Back as they were, in their places by when they were archived.
    func putBack(_ taken: [ArchivedTab]) {
        guard !taken.isEmpty else { return }
        let urls = Set(taken.map(\.url))
        entries = (entries.filter { !urls.contains($0.url) } + taken).sorted { $0.archivedAt > $1.archivedAt }
        prune()
        save()
    }

    func search(_ words: [String], limit: Int, where belongs: (ArchivedTab) -> Bool = { _ in true }) -> [ArchivedTab] {
        var found: [ArchivedTab] = []
        for entry in entries where found.count < limit && belongs(entry) {
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            if words.allSatisfy({ haystack.contains($0) }) { found.append(entry) }
        }
        return found
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        entries.removeAll { $0.archivedAt < cutoff }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// Written in order, off the main thread: tabs are archived as others go to sleep, and up to 500 entries took
    /// their time to encode and write there.
    private static let writer = DispatchQueue(label: "app.zigzag.archive", qos: .utility)

    private func save() {
        if self === Self.shared { ArchivePage.refreshOpenPages() }
        guard let file else { return }
        let entries = entries
        Self.writer.async { JSONStore.save(entries, to: file) }
    }

    /// Waits for what's being written, so quitting never cuts it short.
    static func flush() { writer.sync {} }
}

/// Archive page days, newest first: Today, Yesterday, then by date.
nonisolated enum ArchiveDays {
    struct Day: Equatable {
        /// The day's first moment.
        let start: Date
        let entries: [ArchivedTab]
    }

    /// Groups entries by day, each day newest first.
    static func group(_ entries: [ArchivedTab], calendar: Calendar = .current) -> [Day] {
        var byDay: [Date: [ArchivedTab]] = [:]
        for entry in entries { byDay[calendar.startOfDay(for: entry.archivedAt), default: []].append(entry) }
        return byDay.keys.sorted(by: >).map { start in
            Day(start: start, entries: (byDay[start] ?? []).sorted { $0.archivedAt > $1.archivedAt })
        }
    }

    /// “Today”, “Yesterday”, then weekday and date (“Saturday, November 14”), with the year if not this year.
    static func title(of day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = Words.dates) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return String(localized: "Today", comment: "Heading of the tabs archived today, on the Archive page.") }
        if days == 1 { return String(localized: "Yesterday", comment: "Heading of the tabs archived yesterday, on the Archive page.") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "yEEEEMMMMd")
        return formatter.string(from: day)
    }

    /// True when every word is in the title, address or space name.
    static func matches(_ entry: ArchivedTab, words: [String], space: String?) -> Bool {
        let haystack = [entry.title, entry.url.absoluteString, space ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

extension TabManager {
    /// Restores an archived tab in front, in its original space (or the current one if that's gone or private), and
    /// removes it from the archive. Selects it if already open there.
    @discardableResult
    func restore(_ entry: ArchivedTab, from archive: TabArchive = .shared) -> Tab {
        archive.remove(url: entry.url)
        let space = !isPrivate && Library.shared.space(entry.spaceID) != nil ? entry.spaceID : currentSpaceID
        switchToSpace(space)
        let key = Self.normalize(entry.url)
        if let open = tabs(in: space).first(where: { $0.url.map(Self.normalize) == key }) {
            select(open)
            return open
        }
        return newTab(url: entry.url, spaceID: space, select: true, title: entry.title.isEmpty ? nil : entry.title, by: .you)
    }
}
