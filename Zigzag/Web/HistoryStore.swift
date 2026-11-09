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
    var isEmpty: Bool { visits.isEmpty && archive.isEmpty }
}

/// Every page visited, kept locally in SQLite. Used by the command bar.
final class HistoryStore {
    static let shared = HistoryStore(path: Paths.history.path)

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Where the History page's searches run; nil for a store in memory, which no second connection can see.
    private let reader: HistoryReader?

    /// The one store is `shared`; tests open their own, ":memory:", so they never see your history.
    init(path: String) {
        reader = path == ":memory:" ? nil : HistoryReader(path: path)
        guard open(path) else {
            // A damaged file (a disk error, a half-copied restore) would leave history off for good, silently: it's
            // set aside, named for when, and history starts afresh.
            sqlite3_close(db)
            db = nil
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.moveItem(atPath: path + suffix, toPath: "\(path).damaged-\(stamp)\(suffix)")
            }
            Diagnostics.note("History was damaged and started afresh")
            if !open(path) { sqlite3_close(db); db = nil }
            return
        }
    }

    /// Runs a removal on the history in every update backup too, erasing it there as here.
    private static func scrubBackups(_ sql: String) {
        for backup in ProfileBackup.all() {
            let file = backup.appendingPathComponent("History.sqlite")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var copy: OpaquePointer?
            guard sqlite3_open_v2(file.path, &copy, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(copy); continue }
            sqlite3_exec(copy, "PRAGMA secure_delete=ON", nil, nil, nil)
            sqlite3_exec(copy, sql, nil, nil, nil)
            sqlite3_exec(copy, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(copy)
        }
    }

    /// Opens the file and makes sure it holds History's table; false when it isn't a database SQLite can use.
    private func open(_ path: String) -> Bool {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        // Another Zigzag writing (an update relaunching) waits its turn instead of losing the visit.
        sqlite3_busy_timeout(db, 2000)
        exec("PRAGMA journal_mode=WAL")
        // With WAL this is still safe across a crash, without a full disk sync on every page visited.
        exec("PRAGMA synchronous=NORMAL")
        // What's cleared is overwritten, not just unlinked, so a cleared page can't be read back out of the file.
        exec("PRAGMA secure_delete=ON")
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
        exec("CREATE INDEX IF NOT EXISTS visits_last ON visits(last_visit DESC)")
        exec("CREATE INDEX IF NOT EXISTS visits_host ON visits(host)")
        // A year of history is plenty to search; older single visits go, so typing stays quick as it grows.
        exec("DELETE FROM visits WHERE last_visit < strftime('%s','now') - 31536000 AND visit_count <= 1")
        return true
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    nonisolated static func shouldRecord(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host() != nil
    }

    func recordVisit(url: URL, title: String?, at date: Date = Date(), count: Int = 1) {
        guard Self.shouldRecord(url), let statement = prepare("""
        INSERT INTO visits (url, host, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + ?4,
            last_visit = MAX(last_visit, ?5),
            title = CASE WHEN ?3 = '' THEN title ELSE ?3 END
        """) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
        sqlite3_bind_text(statement, 2, Self.normalizedHost(url), -1, transient)
        sqlite3_bind_text(statement, 3, title ?? "", -1, transient)
        sqlite3_bind_int(statement, 4, Int32(count))
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        sqlite3_step(statement)
        onVisit?(url)
    }

    /// Told of each page recorded, for extensions listening to `history.onVisited` (ExtensionBridge).
    var onVisit: ((URL) -> Void)?
    /// Told of pages taken out (nil: all of them), for `history.onVisitRemoved`.
    var onRemove: (([URL]?) -> Void)?

    func updateTitle(_ title: String, for url: URL) {
        guard Self.shouldRecord(url), let statement = prepare("UPDATE visits SET title = ?1 WHERE url = ?2") else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, transient)
        sqlite3_bind_text(statement, 2, url.absoluteString, -1, transient)
        sqlite3_step(statement)
    }

    /// Bulk import inside one transaction, with one statement. A page already here keeps the larger count, not
    /// the sum: importing the same browser again never doubles its visits. Returns how many pages are new here,
    /// so importing the same browser again says it brought nothing new rather than every page once more.
    @discardableResult
    func importVisits(_ entries: [(URL, String, Int, Date)]) -> Int {
        guard let statement = prepare("""
        INSERT INTO visits (url, host, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visit_count, ?4),
            last_visit = MAX(last_visit, ?5),
            title = CASE WHEN ?3 = '' THEN title ELSE ?3 END
        """) else { return 0 }
        defer { sqlite3_finalize(statement) }
        exec("BEGIN")
        let before = pageCount()
        for (url, title, count, date) in entries where Self.shouldRecord(url) {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
            sqlite3_bind_text(statement, 2, Self.normalizedHost(url), -1, transient)
            sqlite3_bind_text(statement, 3, title, -1, transient)
            sqlite3_bind_int(statement, 4, Int32(clamping: max(1, count)))
            sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
            sqlite3_step(statement)
        }
        let added = pageCount() - before
        exec("COMMIT")
        return max(0, added)
    }

    private func pageCount() -> Int {
        guard let statement = prepare("SELECT count(*) FROM visits") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Takes everything visited out of History, or everything since `date`. Archived tabs go with it (they're pages
    /// you visited, and the address bar suggests them), and so do where you were in PDFs and the icons saved for those
    /// sites. All of it comes back as `HistoryRemoval`, so ⌘Z can put it back.
    func remove(since date: Date? = nil) -> HistoryRemoval {
        let visits = select(date.map { _ in "last_visit >= ?1" }) { statement in
            if let date { sqlite3_bind_double(statement, 1, date.timeIntervalSince1970) }
        }
        if let date, let statement = prepare("DELETE FROM visits WHERE last_visit >= ?1") {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_step(statement)
        } else if date == nil {
            exec("DELETE FROM visits")
        }
        // The log the deleted rows passed through goes too.
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        // What went wrong lately names its sites too.
        Diagnostics.forget(since: date)
        // And the copies kept from before each update: cleared means cleared there as well.
        Self.scrubBackups(date.map { "DELETE FROM visits WHERE last_visit >= \($0.timeIntervalSince1970)" } ?? "DELETE FROM visits")
        onRemove?(date == nil ? nil : visits.map(\.url))
        return HistoryRemoval(visits: visits, archive: TabArchive.shared.take(since: date),
                              pdfPlaces: PDFViewerView.takePlaces(since: date), icons: FaviconStore.shared.setAsideVisited(since: date))
    }

    /// Takes these pages out of History, and their archived tabs with them.
    func remove(_ urls: [URL]) -> HistoryRemoval {
        var visits: [HistoryEntry] = []
        for url in urls {
            visits += select("url = ?1") { sqlite3_bind_text($0, 1, url.absoluteString, -1, self.transient) }
            guard let statement = prepare("DELETE FROM visits WHERE url = ?1") else { continue }
            sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        let quoted = urls.map { "'" + $0.absoluteString.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        if !urls.isEmpty { Self.scrubBackups("DELETE FROM visits WHERE url IN (\(quoted))") }
        if !visits.isEmpty { onRemove?(visits.map(\.url)) }
        return HistoryRemoval(visits: visits, archive: TabArchive.shared.take(urls), pdfPlaces: [:], icons: nil)
    }

    /// Puts back what a removal took, as it was.
    func restore(_ removal: HistoryRemoval) {
        importVisits(removal.visits.map { ($0.url, $0.title, $0.visitCount, $0.lastVisit) })
        TabArchive.shared.putBack(removal.archive)
        PDFViewerView.putBackPlaces(removal.pdfPlaces)
        if let icons = removal.icons { FaviconStore.shared.putBack(icons) }
    }

    private func select(_ condition: String?, bind: (OpaquePointer) -> Void) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits" + (condition.map { " WHERE " + $0 } ?? "")) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        return Self.collect(statement)
    }


    /// Newest first, for the History window; `before` pages further back.
    func page(before date: Date? = nil, limit: Int = 300) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits WHERE last_visit < ?1 ORDER BY last_visit DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, (date ?? .distantFuture).timeIntervalSince1970)
        return Self.collect(statement)
    }

    nonisolated static func normalizedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    nonisolated static func words(_ query: String) -> [String] {
        query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Ranked matches: every word must appear in the URL or title.
    func search(_ query: String, limit: Int = 12) -> [HistoryEntry] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        // Asked again for the same text with nothing recorded since (the command bar does, when suggestions
        // arrive): the last answer, rather than reading every visit once more.
        let key = "\(limit)|\(words.joined(separator: " "))|\(sqlite3_total_changes(db))"
        if let last = lastSearch, last.key == key { return last.results }
        let results = Self.runSearch(words, limit: limit, in: db)
        lastSearch = (key, results)
        return results
    }

    private var lastSearch: (key: String, results: [HistoryEntry])?

    /// The same search, off the main thread, for the History page: typing there never waits on reading every visit,
    /// however big History grows. `then` shapes the answer there too. Nil when a newer search from the same `asker`
    /// took over: it's stopped where it was, as its answer would only be dropped.
    func search<T: Sendable>(_ query: String, limit: Int, asker: Int, then: @escaping @Sendable ([HistoryEntry]) -> T) async -> T? {
        guard let reader else { return then(search(query, limit: limit)) }
        return await reader.search(Self.words(query), limit: limit, asker: asker, then: then)
    }

    nonisolated fileprivate static func runSearch(_ words: [String], limit: Int, in db: OpaquePointer?) -> [HistoryEntry] {
        guard !words.isEmpty else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let clause = words.indices.map { "(url LIKE ?\($0 + 1) ESCAPE '\\' OR title LIKE ?\($0 + 1) ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = "SELECT url, title, visit_count, last_visit FROM visits WHERE \(clause) ORDER BY visit_count * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT \(limit * 3)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for (i, word) in words.enumerated() {
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(statement, Int32(i + 1), "%\(escaped)%", -1, transient)
        }
        return collect(statement)
    }

    /// Sites whose host starts with the typed text, for inline completion: the most used first, each with the page
    /// you visit most there and a score that weighs visits by how recent they are, as `search` does. With
    /// `afterSubdomain`, hosts where it starts a later label instead ("wiki" in en.wikipedia.org); that can't use the
    /// index, so it's only asked when no host starts with it.
    func completionSites(for prefix: String, afterSubdomain: Bool = false, limit: Int = 8) -> [(entry: HistoryEntry, score: Double)] {
        let lower = prefix.lowercased()
        let match = afterSubdomain ? "host LIKE ?3 ESCAPE '\\'" : "host >= ?1 AND host < ?2"
        guard !lower.isEmpty, !lower.contains(" "), let statement = prepare("""
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
        """) else { return [] }
        defer { sqlite3_finalize(statement) }
        // Hosts are stored lowercase, so a plain range finds the prefix through the index instead of a full scan.
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, lower + "\u{10FFFF}", -1, transient)
        let escaped = lower.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(statement, 3, "%.\(escaped)%", -1, transient)
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
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, (start ?? .distantPast).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, (end ?? .distantFuture).timeIntervalSince1970)
        for (i, word) in words.enumerated() {
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(statement, Int32(i + 3), "%\(escaped)%", -1, transient)
        }
        var results: [(Int64, HistoryEntry)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cURL = sqlite3_column_text(statement, 1), let url = URL(string: String(cString: cURL)) else { continue }
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            results.append((sqlite3_column_int64(statement, 0), HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int(statement, 3)),
                                                                               lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))))
        }
        return results
    }

    /// One page by its address, with its ID, for `history.getVisits` and `onVisited`.
    func item(for url: URL) -> (id: Int64, entry: HistoryEntry)? {
        guard let statement = prepare("SELECT rowid, url, title, visit_count, last_visit FROM visits WHERE url = ?1") else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        return (sqlite3_column_int64(statement, 0), HistoryEntry(url: url, title: title, visitCount: Int(sqlite3_column_int(statement, 3)),
                                                                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
    }

    /// The pages visited most, weighed by how recent, for `topSites.get`.
    func mostVisited(limit: Int) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits ORDER BY visit_count * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(statement) }
        return Self.collect(statement)
    }

    /// Takes out what was last visited between two times, for `history.deleteRange`.
    func remove(from start: Date, to end: Date) -> HistoryRemoval {
        let bind: (OpaquePointer) -> Void = { sqlite3_bind_double($0, 1, start.timeIntervalSince1970); sqlite3_bind_double($0, 2, end.timeIntervalSince1970) }
        let visits = select("last_visit >= ?1 AND last_visit <= ?2", bind: bind)
        return visits.isEmpty ? HistoryRemoval(visits: [], archive: [], pdfPlaces: [:], icons: nil) : remove(visits.map(\.url))
    }

    func recent(limit: Int = 8) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(statement) }
        return Self.collect(statement)
    }

    nonisolated private static func collect(_ statement: OpaquePointer) -> [HistoryEntry] {
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

/// History's searches for the History page, on a connection of their own and a queue of their own. The file is in WAL
/// mode, so reading here never waits on a visit being written on the main thread, nor holds one up.
nonisolated final class HistoryReader: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "app.zigzag.history.search", qos: .userInitiated)
    // Only touched on `queue`.
    private var db: OpaquePointer?
    // Under `lock`: the newest search each asker (a History tab) has made, and which one is running now.
    private let lock = NSLock()
    private var newest: [Int: Int] = [:]
    private var running: (asker: Int, ticket: Int)?
    private var tickets = 0

    init(path: String) { self.path = path }

    deinit { sqlite3_close(db) }

    func search<T: Sendable>(_ words: [String], limit: Int, asker: Int, then: @escaping @Sendable ([HistoryEntry]) -> T) async -> T? {
        let ticket: Int = lock.withLock {
            tickets += 1
            newest[asker] = tickets
            // The same tab's last search, still reading: stopped, since the page drops what it would find.
            if let running, running.asker == asker { sqlite3_interrupt(db) }
            return tickets
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.run(words, limit: limit, asker: asker, ticket: ticket, then: then))
            }
        }
    }

    private func run<T>(_ words: [String], limit: Int, asker: Int, ticket: Int, then: ([HistoryEntry]) -> T) -> T? {
        // Typed over before it started: never run at all.
        guard isNewest(asker, ticket) else { return nil }
        if db == nil {
            var opened: OpaquePointer?
            guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(opened); return then([]) }
            sqlite3_busy_timeout(opened, 2000)
            lock.withLock { db = opened }
        }
        lock.withLock { running = (asker, ticket) }
        let found = HistoryStore.runSearch(words, limit: limit, in: db)
        lock.withLock { running = nil }
        guard isNewest(asker, ticket) else { return nil }
        let shaped = then(found)
        return isNewest(asker, ticket) ? shaped : nil
    }

    private func isNewest(_ asker: Int, _ ticket: Int) -> Bool { lock.withLock { newest[asker] == ticket } }
}
