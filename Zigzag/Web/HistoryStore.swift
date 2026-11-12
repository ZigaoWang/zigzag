import Foundation
import SQLite3

nonisolated struct HistoryEntry: Sendable {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

/// What taking pages out of History took with them, kept so ⌘Z can put it all back (`HistoryStore.restore`).
struct HistoryRemoval {
    let visits: [HistoryEntry]
    let archive: [ArchivedTab]
    let pdfPlaces: [String: Any]
    /// The sites' icons, set aside rather than deleted; gone for good when Zigzag next starts.
    let icons: URL?
    /// The profile whose history it was taken from.
    var profile = Profile.defaultID
    var isEmpty: Bool { visits.isEmpty && archive.isEmpty }
}

/// Every page visited in one profile, kept locally in SQLite. Used by the command bar. Each profile has its own
/// (`Profile.history`): what you visit in one is never suggested in another.
///
/// Its connection lives on a queue of its own (`HistoryDatabase`): a visit or a title is written there without the
/// main thread waiting, which it did for every page visited, up to the two seconds SQLite waits for a lock another
/// Zigzag or an update backup holds (#89). Reads wait there for the writes before them, so what was just recorded is
/// always found.
final class HistoryStore {
    /// The profile it's the history of.
    let profile: UUID
    /// Its file's place under Zigzag's data folder, which is also its place in each update backup.
    private var backupPath: String { profile == Profile.defaultID ? "History.sqlite" : "Profiles/\(profile.uuidString)/History.sqlite" }
    /// Whether an archived tab is this profile's: it was in one of its spaces.
    private var isOurs: (ArchivedTab) -> Bool {
        let profile = profile
        return { Library.shared.profileID(ofSpace: $0.spaceID) == profile }
    }

    private let database: HistoryDatabase
    /// Where the History page's searches run; nil for a store in memory, which no second connection can see.
    private let reader: HistoryReader?

    /// Every store opened since Zigzag started, to finish their writes as it quits.
    private static let opened = NSHashTable<HistoryStore>.weakObjects()

    /// Profiles open theirs; tests open their own, ":memory:", so they never see your history.
    init(path: String, profile: UUID = Profile.defaultID) {
        self.profile = profile
        reader = path == ":memory:" ? nil : HistoryReader(path: path)
        database = HistoryDatabase(path: path)
        Self.opened.add(self)
    }

    /// Waits for what's still being written, in every store: for quitting, so nothing recorded or cleared is cut short.
    static func finishWriting() {
        for store in opened.allObjects { store.database.finishWriting() }
    }

    nonisolated static func shouldRecord(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host() != nil
    }

    func recordVisit(url: URL, title: String?, at date: Date = Date(), count: Int = 1) {
        guard Self.shouldRecord(url) else { return }
        let address = url.absoluteString, host = Self.normalizedHost(url), title = title ?? "", count = Int32(count)
        let when = date.timeIntervalSince1970
        database.write { db in
            HistoryDatabase.run(db, """
            INSERT INTO visits (url, host, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + ?4,
                last_visit = MAX(last_visit, ?5),
                title = CASE WHEN ?3 = '' THEN title ELSE ?3 END
            """) { statement in
                HistoryDatabase.bind(statement, 1, address)
                HistoryDatabase.bind(statement, 2, host)
                HistoryDatabase.bind(statement, 3, title)
                sqlite3_bind_int(statement, 4, count)
                sqlite3_bind_double(statement, 5, when)
            }
            // Once it's in: whoever hears of it can look it up.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onVisit?(url) }
            }
        }
    }

    /// Told of each page recorded, for extensions listening to `history.onVisited` (ExtensionBridge).
    var onVisit: ((URL) -> Void)?
    /// Told of pages taken out (nil: all of them), for `history.onVisitRemoved`.
    var onRemove: (([URL]?) -> Void)?

    func updateTitle(_ title: String, for url: URL) {
        guard Self.shouldRecord(url) else { return }
        let address = url.absoluteString
        database.write { db in
            HistoryDatabase.run(db, "UPDATE visits SET title = ?1 WHERE url = ?2") { statement in
                HistoryDatabase.bind(statement, 1, title)
                HistoryDatabase.bind(statement, 2, address)
            }
        }
    }

    /// Bulk import inside one transaction, with one statement. A page already here keeps the larger count, not
    /// the sum: importing the same browser again never doubles its visits. Returns how many pages are new here,
    /// so importing the same browser again says it brought nothing new rather than every page once more.
    @discardableResult
    func importVisits(_ entries: [(URL, String, Int, Date)]) -> Int {
        let rows = entries.filter { Self.shouldRecord($0.0) }
            .map { (url: $0.0.absoluteString, host: Self.normalizedHost($0.0), title: $0.1, count: Int32(clamping: max(1, $0.2)), when: $0.3.timeIntervalSince1970) }
        return database.sync { db in HistoryDatabase.importRows(rows, into: db) }
    }

    /// Takes everything visited out of History, or everything since `date`. Archived tabs go with it (they're pages
    /// you visited, and the address bar suggests them), and so do where you were in PDFs and the icons saved for those
    /// sites. All of it comes back as `HistoryRemoval`, so ⌘Z can put it back.
    func remove(since date: Date? = nil) -> HistoryRemoval {
        let since = date?.timeIntervalSince1970
        let visits = database.sync { db -> [HistoryEntry] in
            let visits = HistoryDatabase.select(db, since.map { _ in "last_visit >= ?1" }) { statement in
                if let since { sqlite3_bind_double(statement, 1, since) }
            }
            if let since {
                HistoryDatabase.run(db, "DELETE FROM visits WHERE last_visit >= ?1") { sqlite3_bind_double($0, 1, since) }
            } else {
                HistoryDatabase.exec(db, "DELETE FROM visits")
            }
            return visits
        }
        // The log the deleted rows passed through goes too, and the copies kept from before each update: cleared
        // means cleared there as well. Both after the rows are gone, on the history's own queue; quitting waits for them.
        let backups = backupFiles
        database.write { db in
            HistoryDatabase.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            HistoryDatabase.scrub(backups, since.map { "DELETE FROM visits WHERE last_visit >= \($0)" } ?? "DELETE FROM visits")
        }
        // What went wrong lately names its sites too. That, where you were in PDFs and the sites' icons aren't
        // kept by profile, so with several profiles they go for all: cleared never leaves a trace behind.
        Diagnostics.forget(since: date)
        // Dark pages' sites seen dark are a list of sites visited in the profile, so they go too.
        DarkSeen.forget(scope: DarkSeen.scope(ofProfile: profile), since: date)
        onRemove?(date == nil ? nil : visits.map(\.url))
        return HistoryRemoval(visits: visits, archive: TabArchive.shared.take(since: date, where: isOurs),
                              pdfPlaces: PDFViewerView.takePlaces(since: date), icons: FaviconStore.shared.setAsideVisited(since: date), profile: profile)
    }

    /// The history files in every update backup.
    private var backupFiles: [URL] { UpdateBackup.all().map { $0.appendingPathComponent(backupPath) } }

    /// Takes these pages out of History, and their archived tabs with them.
    func remove(_ urls: [URL]) -> HistoryRemoval {
        let addresses = urls.map(\.absoluteString)
        let visits = database.sync { db -> [HistoryEntry] in
            var visits: [HistoryEntry] = []
            for address in addresses {
                visits += HistoryDatabase.select(db, "url = ?1") { HistoryDatabase.bind($0, 1, address) }
                HistoryDatabase.run(db, "DELETE FROM visits WHERE url = ?1") { HistoryDatabase.bind($0, 1, address) }
            }
            return visits
        }
        let quoted = addresses.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        if !urls.isEmpty {
            let backups = backupFiles
            database.write { _ in HistoryDatabase.scrub(backups, "DELETE FROM visits WHERE url IN (\(quoted))") }
        }
        if !visits.isEmpty { onRemove?(visits.map(\.url)) }
        return HistoryRemoval(visits: visits, archive: TabArchive.shared.take(urls, where: isOurs), pdfPlaces: [:], icons: nil, profile: profile)
    }

    /// Puts back what a removal took, as it was.
    func restore(_ removal: HistoryRemoval) {
        importVisits(removal.visits.map { ($0.url, $0.title, $0.visitCount, $0.lastVisit) })
        TabArchive.shared.putBack(removal.archive)
        PDFViewerView.putBackPlaces(removal.pdfPlaces)
        if let icons = removal.icons { FaviconStore.shared.putBack(icons) }
    }

    /// Newest first, for the History window; `before` pages further back.
    func page(before date: Date? = nil, limit: Int = 300) -> [HistoryEntry] {
        let before = (date ?? .distantFuture).timeIntervalSince1970
        return database.sync { db in
            HistoryDatabase.query(db, "SELECT url, title, visit_count, last_visit FROM visits WHERE last_visit < ?1 ORDER BY last_visit DESC LIMIT \(limit)") {
                sqlite3_bind_double($0, 1, before)
            }
        }
    }

    nonisolated static func normalizedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.withoutWWW
    }

    nonisolated static func words(_ query: String) -> [String] {
        query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Ranked matches: every word must appear in the URL or title.
    func search(_ query: String, limit: Int = 12) -> [HistoryEntry] {
        let words = Self.words(query)
        return database.sync { Self.runSearch(words, limit: limit, in: $0) }
    }

    /// The same search, off the main thread, for the History page and the command bar: typing there never waits on
    /// reading every visit, however big History grows. `then` shapes the answer there too. Nil when a newer search
    /// from the same `asker` took over: it's stopped where it was, as its answer would only be dropped.
    func search<T: Sendable>(_ query: String, limit: Int, asker: Int, then: @escaping @Sendable ([HistoryEntry]) -> T) async -> T? {
        guard let reader else { return then(search(query, limit: limit)) }
        // What was recorded just before is in by then.
        await database.written()
        return await reader.search(Self.words(query), limit: limit, asker: asker, then: then)
    }

    nonisolated fileprivate static func runSearch(_ words: [String], limit: Int, in db: OpaquePointer?) -> [HistoryEntry] {
        guard !words.isEmpty else { return [] }
        let clause = words.indices.map { "(url LIKE ?\($0 + 1) ESCAPE '\\' OR title LIKE ?\($0 + 1) ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = "SELECT url, title, visit_count, last_visit FROM visits WHERE \(clause) ORDER BY visit_count * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT \(limit * 3)"
        return HistoryDatabase.query(db, sql) { statement in
            for (i, word) in words.enumerated() { HistoryDatabase.bind(statement, Int32(i + 1), "%\(HistoryDatabase.escapeLike(word))%") }
        }
    }

    /// Sites whose host starts with the typed text, for inline completion: the most used first, each with the page
    /// you visit most there and a score that weighs visits by how recent they are, as `search` does. With
    /// `afterSubdomain`, hosts where it starts a later label instead ("wiki" in en.wikipedia.org); that can't use the
    /// index, so it's only asked when no host starts with it.
    func completionSites(for prefix: String, afterSubdomain: Bool = false, limit: Int = 8) -> [(entry: HistoryEntry, score: Double)] {
        database.sync { Self.runCompletionSites(prefix, afterSubdomain: afterSubdomain, limit: limit, in: $0) }
    }

    /// The command bar's inline completion, off the main thread: hosts starting with the text, or failing that hosts
    /// where it starts a later label. Nil when a newer lookup from the same `asker` took over.
    func completionSites(for prefix: String, asker: Int) async -> [(entry: HistoryEntry, score: Double)]? {
        let lookup: @Sendable (OpaquePointer?) -> [(entry: HistoryEntry, score: Double)] = { db in
            let found = Self.runCompletionSites(prefix, afterSubdomain: false, limit: 8, in: db)
            return found.isEmpty ? Self.runCompletionSites(prefix, afterSubdomain: true, limit: 8, in: db) : found
        }
        guard let reader else { return database.sync { lookup($0) } }
        await database.written()
        return await reader.read(asker: asker, lookup) { $0 }
    }

    nonisolated fileprivate static func runCompletionSites(_ prefix: String, afterSubdomain: Bool, limit: Int,
                                                           in db: OpaquePointer?) -> [(entry: HistoryEntry, score: Double)] {
        let transient = HistoryDatabase.transient
        let lower = prefix.lowercased()
        let match = afterSubdomain ? "host LIKE ?3 ESCAPE '\\'" : "host >= ?1 AND host < ?2"
        var statement: OpaquePointer?
        guard !lower.isEmpty, !lower.contains(" "), sqlite3_prepare_v2(db, """
        SELECT url, title, visit_count, last_visit, score FROM (
            SELECT url, title, visit_count, last_visit,
                SUM(visit_count) OVER site * 1.0 / (1 + (strftime('%s','now') - MAX(last_visit) OVER site) / 604800.0) AS score,
                ROW_NUMBER() OVER (PARTITION BY origin ORDER BY visit_count DESC, last_visit DESC) AS rank
            FROM (
                -- One site per host and port, with or without "www.": localhost:3000 and localhost:8080 are two.
                SELECT url, title, visit_count, last_visit,
                    CASE WHEN authority LIKE 'www.%' THEN substr(authority, 5) ELSE authority END AS origin
                FROM (
                    SELECT url, title, visit_count, last_visit, lower(substr(rest, 1, instr(rest || '/', '/') - 1)) AS authority
                    FROM (SELECT *, substr(url, instr(url, '://') + 3) AS rest FROM visits WHERE \(match))
                )
            )
            WINDOW site AS (PARTITION BY origin)
        ) WHERE rank = 1 ORDER BY score DESC LIMIT \(limit)
        """, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        // Hosts are stored lowercase, so a plain range finds the prefix through the index instead of a full scan.
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, lower + "\u{10FFFF}", -1, transient)
        sqlite3_bind_text(statement, 3, "%.\(HistoryDatabase.escapeLike(lower))%", -1, transient)
        var results: [(HistoryEntry, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cURL = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: cURL)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            results.append((HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int(statement, 2)),
                                         lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))),
                            sqlite3_column_double(statement, 4)))
        }
        return results
    }

    /// Pages for an extension's `history.search`: the text in the address or title (every word, or anything when
    /// empty), last visited in the range, newest first, each with its row's number as a stable ID.
    func items(matching text: String, from start: Date?, to end: Date?, limit: Int) -> [(id: Int64, entry: HistoryEntry)] {
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var clauses = ["last_visit >= ?1", "last_visit <= ?2"]
        clauses += words.indices.map { "(url LIKE ?\($0 + 3) ESCAPE '\\' OR title LIKE ?\($0 + 3) ESCAPE '\\')" }
        let sql = "SELECT rowid, url, title, visit_count, last_visit FROM visits WHERE \(clauses.joined(separator: " AND ")) ORDER BY last_visit DESC LIMIT \(max(1, min(limit, 10_000)))"
        let from = (start ?? .distantPast).timeIntervalSince1970, to = (end ?? .distantFuture).timeIntervalSince1970
        return database.sync { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, from)
            sqlite3_bind_double(statement, 2, to)
            for (i, word) in words.enumerated() { HistoryDatabase.bind(statement, Int32(i + 3), "%\(HistoryDatabase.escapeLike(word))%") }
            var results: [(Int64, HistoryEntry)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cURL = sqlite3_column_text(statement, 1), let url = URL(string: String(cString: cURL)) else { continue }
                let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                results.append((sqlite3_column_int64(statement, 0), HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int(statement, 3)),
                                                                                   lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))))
            }
            return results
        }
    }

    /// One page by its address, with its ID, for `history.getVisits` and `onVisited`.
    func item(for url: URL) -> (id: Int64, entry: HistoryEntry)? {
        let address = url.absoluteString
        return database.sync { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rowid, url, title, visit_count, last_visit FROM visits WHERE url = ?1", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            HistoryDatabase.bind(statement, 1, address)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            return (sqlite3_column_int64(statement, 0), HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int(statement, 3)),
                                                                    lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
        }
    }

    /// The pages visited most, weighed by how recent, for `topSites.get`.
    func mostVisited(limit: Int) -> [HistoryEntry] {
        database.sync { HistoryDatabase.query($0, "SELECT url, title, visit_count, last_visit FROM visits ORDER BY visit_count * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT \(limit)") { _ in } }
    }

    /// Takes out what was last visited between two times, for `history.deleteRange`.
    func remove(from start: Date, to end: Date) -> HistoryRemoval {
        let from = start.timeIntervalSince1970, to = end.timeIntervalSince1970
        let visits = database.sync { db in
            HistoryDatabase.select(db, "last_visit >= ?1 AND last_visit <= ?2") { sqlite3_bind_double($0, 1, from); sqlite3_bind_double($0, 2, to) }
        }
        return visits.isEmpty ? HistoryRemoval(visits: [], archive: [], pdfPlaces: [:], icons: nil) : remove(visits.map(\.url))
    }

    func recent(limit: Int = 8) -> [HistoryEntry] {
        database.sync { HistoryDatabase.query($0, "SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC LIMIT \(limit)") { _ in } }
    }
}

/// History's own connection, and the one queue it's used on, in order: writes are sent there and the main thread goes
/// on; reads wait there for the writes before them. Opening the file (and taking out a year's old visits) happens
/// there too, so a profile's history opening for the first time never holds anything up.
nonisolated final class HistoryDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.zigzag.history", qos: .utility)
    // Only touched on `queue`.
    private var db: OpaquePointer?

    init(path: String) {
        queue.async { self.open(path) }
    }

    deinit { sqlite3_close(db) }

    /// Done on the queue, in order, without waiting for it.
    func write(_ work: @escaping @Sendable (OpaquePointer?) -> Void) {
        queue.async { work(self.db) }
    }

    /// Done on the queue, after what's already there, waiting for the answer.
    func sync<T>(_ work: (OpaquePointer?) -> T) -> T {
        queue.sync { work(db) }
    }

    /// Once everything sent before has been done.
    func written() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// Waits for everything sent so far.
    func finishWriting() { queue.sync {} }

    /// Opens the file; a damaged one (a disk error, a half-copied restore) would leave history off for good,
    /// silently: it's set aside, named for when, and history starts afresh.
    private func open(_ path: String) {
        guard !openFile(path) else { return }
        sqlite3_close(db)
        db = nil
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.moveItem(atPath: path + suffix, toPath: "\(path).damaged-\(stamp)\(suffix)")
        }
        Diagnostics.note("History was damaged and started afresh")
        if !openFile(path) { sqlite3_close(db); db = nil }
    }

    /// Opens the file and makes sure it holds History's table; false when it isn't a database SQLite can use.
    private func openFile(_ path: String) -> Bool {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        // Another Zigzag writing (an update relaunching) waits its turn instead of losing the visit.
        sqlite3_busy_timeout(db, 2000)
        Self.exec(db, "PRAGMA journal_mode=WAL")
        // With WAL this is still safe across a crash, without a full disk sync on every page visited.
        Self.exec(db, "PRAGMA synchronous=NORMAL")
        // What's cleared is overwritten, not just unlinked, so a cleared page can't be read back out of the file.
        Self.exec(db, "PRAGMA secure_delete=ON")
        let created = sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS visits (
            url TEXT PRIMARY KEY,
            host TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 1,
            last_visit REAL NOT NULL
        )
        """, nil, nil, nil)
        guard created == SQLITE_OK, sqlite3_exec(db, "SELECT 1 FROM visits LIMIT 1", nil, nil, nil) == SQLITE_OK else { return false }
        Self.exec(db, "CREATE INDEX IF NOT EXISTS visits_last ON visits(last_visit DESC)")
        Self.exec(db, "CREATE INDEX IF NOT EXISTS visits_host ON visits(host)")
        // A year of history is plenty to search; older single visits go, so typing stays quick as it grows.
        Self.exec(db, "DELETE FROM visits WHERE last_visit < strftime('%s','now') - 31536000 AND visit_count <= 1")
        return true
    }

    // MARK: Statements, on the queue

    static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    static func escapeLike(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Runs a statement that returns no rows.
    static func run(_ db: OpaquePointer?, _ sql: String, bind: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        sqlite3_step(statement)
    }

    /// The visits a statement returns, as url, title, visit_count, last_visit.
    static func query(_ db: OpaquePointer?, _ sql: String, bind: (OpaquePointer) -> Void) -> [HistoryEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        return collect(statement)
    }

    static func select(_ db: OpaquePointer?, _ condition: String?, bind: (OpaquePointer) -> Void) -> [HistoryEntry] {
        query(db, "SELECT url, title, visit_count, last_visit FROM visits" + (condition.map { " WHERE " + $0 } ?? ""), bind: bind)
    }

    static func importRows(_ rows: [(url: String, host: String, title: String, count: Int32, when: Double)], into db: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO visits (url, host, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visit_count, ?4),
            last_visit = MAX(last_visit, ?5),
            title = CASE WHEN ?3 = '' THEN title ELSE ?3 END
        """, -1, &statement, nil) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        exec(db, "BEGIN")
        let before = pageCount(db)
        for row in rows {
            sqlite3_reset(statement)
            bind(statement, 1, row.url)
            bind(statement, 2, row.host)
            bind(statement, 3, row.title)
            sqlite3_bind_int(statement, 4, row.count)
            sqlite3_bind_double(statement, 5, row.when)
            sqlite3_step(statement)
        }
        let added = pageCount(db) - before
        exec(db, "COMMIT")
        return max(0, added)
    }

    private static func pageCount(_ db: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM visits", -1, &statement, nil) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Runs a removal on the history in every update backup too, erasing it there as here.
    static func scrub(_ files: [URL], _ sql: String) {
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var copy: OpaquePointer?
            guard sqlite3_open_v2(file.path, &copy, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(copy); continue }
            sqlite3_exec(copy, "PRAGMA secure_delete=ON", nil, nil, nil)
            sqlite3_exec(copy, sql, nil, nil, nil)
            sqlite3_exec(copy, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(copy)
        }
    }

    static func collect(_ statement: OpaquePointer) -> [HistoryEntry] {
        var results: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cURL = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: cURL)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            results.append(HistoryEntry(url: url, title: title,
                                        visitCount: Int(sqlite3_column_int(statement, 2)),
                                        lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return results
    }
}

/// History's searches for the History page and the command bar, on a connection of their own and a queue of their own. The file is in WAL
/// mode, so reading here never waits on a visit being written (HistoryDatabase), nor holds one up.
nonisolated final class HistoryReader: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "app.zigzag.history.search", qos: .userInitiated)
    // Only touched on `queue`.
    private var db: OpaquePointer?
    // Under `lock`: the newest search each asker (a History tab, a command bar) has made, and which one is running now.
    private let lock = NSLock()
    private var newest: [Int: Int] = [:]
    private var running: (asker: Int, ticket: Int)?
    private var tickets = 0

    init(path: String) { self.path = path }

    deinit { sqlite3_close(db) }

    func search<T: Sendable>(_ words: [String], limit: Int, asker: Int, then: @escaping @Sendable ([HistoryEntry]) -> T) async -> T? {
        await read(asker: asker, { HistoryStore.runSearch(words, limit: limit, in: $0) }, then: then)
    }

    /// Any read, the same way: `lookup` on this connection (nil when the file can't be opened), then `then` on its answer.
    func read<R, T: Sendable>(asker: Int, _ lookup: @escaping @Sendable (OpaquePointer?) -> R, then: @escaping @Sendable (R) -> T) async -> T? {
        let ticket: Int = lock.withLock {
            tickets += 1
            newest[asker] = tickets
            // The same asker's last read, still going: stopped, since its answer would be dropped.
            if let running, running.asker == asker { sqlite3_interrupt(db) }
            return tickets
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.run(lookup, asker: asker, ticket: ticket, then: then))
            }
        }
    }

    private func run<R, T>(_ lookup: (OpaquePointer?) -> R, asker: Int, ticket: Int, then: (R) -> T) -> T? {
        // Typed over before it started: never run at all.
        guard isNewest(asker, ticket) else { return nil }
        if db == nil {
            var opened: OpaquePointer?
            if sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                sqlite3_busy_timeout(opened, 2000)
                lock.withLock { db = opened }
            } else {
                sqlite3_close(opened)
            }
        }
        lock.withLock { running = (asker, ticket) }
        let found = lookup(db)
        lock.withLock { running = nil }
        guard isNewest(asker, ticket) else { return nil }
        let shaped = then(found)
        return isNewest(asker, ticket) ? shaped : nil
    }

    private func isNewest(_ asker: Int, _ ticket: Int) -> Bool { lock.withLock { newest[asker] == ticket } }
}

extension String {
    /// A host without its leading "www.", as Zigzag shows and compares sites.
    nonisolated var withoutWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
