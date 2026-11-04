import Foundation
import SQLite3

struct HistoryEntry {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

/// Every page visited, kept locally in SQLite. Used by the command bar.
final class HistoryStore {
    static let shared = HistoryStore(path: Paths.history.path)

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The one store is `shared`; tests open their own, ":memory:", so they never see your history.
    init(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        // With WAL this is still safe across a crash, without a full disk sync on every page visited.
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS visits (
            url TEXT PRIMARY KEY,
            host TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 1,
            last_visit REAL NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS visits_last ON visits(last_visit DESC)")
        exec("CREATE INDEX IF NOT EXISTS visits_host ON visits(host)")
        // A year of history is plenty to search; older single visits go, so typing stays quick as it grows.
        exec("DELETE FROM visits WHERE last_visit < strftime('%s','now') - 31536000 AND visit_count <= 1")
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
    }

    func updateTitle(_ title: String, for url: URL) {
        guard Self.shouldRecord(url), let statement = prepare("UPDATE visits SET title = ?1 WHERE url = ?2") else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, title, -1, transient)
        sqlite3_bind_text(statement, 2, url.absoluteString, -1, transient)
        sqlite3_step(statement)
    }

    /// Bulk import inside one transaction, with one statement. A page already here keeps the larger count, not
    /// the sum: importing the same browser again never doubles its visits.
    func importVisits(_ entries: [(URL, String, Int, Date)]) {
        guard let statement = prepare("""
        INSERT INTO visits (url, host, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET visit_count = MAX(visit_count, ?4),
            last_visit = MAX(last_visit, ?5),
            title = CASE WHEN ?3 = '' THEN title ELSE ?3 END
        """) else { return }
        defer { sqlite3_finalize(statement) }
        exec("BEGIN")
        for (url, title, count, date) in entries where Self.shouldRecord(url) {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
            sqlite3_bind_text(statement, 2, Self.normalizedHost(url), -1, transient)
            sqlite3_bind_text(statement, 3, title, -1, transient)
            sqlite3_bind_int(statement, 4, Int32(clamping: max(1, count)))
            sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
            sqlite3_step(statement)
        }
        exec("COMMIT")
    }

    /// Archived tabs go with it: they're pages you visited, and the address bar suggests them.
    func clearAll() {
        exec("DELETE FROM visits")
        PDFViewerView.forgetPlaces()
        TabArchive.shared.clear()
        FaviconStore.shared.forgetVisited()
    }

    /// Everything visited since `date` (Clear Last Hour, Today…).
    func clear(since date: Date) {
        guard let statement = prepare("DELETE FROM visits WHERE last_visit >= ?1") else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_step(statement)
        PDFViewerView.forgetPlaces(since: date)
        TabArchive.shared.clear(since: date)
        FaviconStore.shared.forgetVisited(since: date)
    }

    func delete(_ url: URL) {
        TabArchive.shared.remove(url: url)
        guard let statement = prepare("DELETE FROM visits WHERE url = ?1") else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, url.absoluteString, -1, transient)
        sqlite3_step(statement)
    }

    /// Newest first, for the History window; `before` pages further back.
    func page(before date: Date? = nil, limit: Int = 300) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits WHERE last_visit < ?1 ORDER BY last_visit DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, (date ?? .distantFuture).timeIntervalSince1970)
        return collect(statement)
    }

    static func normalizedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Ranked matches: every word must appear in the URL or title.
    func search(_ query: String, limit: Int = 12) -> [HistoryEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let clause = words.indices.map { "(url LIKE ?\($0 + 1) ESCAPE '\\' OR title LIKE ?\($0 + 1) ESCAPE '\\')" }.joined(separator: " AND ")
        let sql = "SELECT url, title, visit_count, last_visit FROM visits WHERE \(clause) ORDER BY visit_count * 1.0 / (1 + (strftime('%s','now') - last_visit) / 604800.0) DESC LIMIT \(limit * 3)"
        guard let statement = prepare(sql) else { return [] }
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

    func recent(limit: Int = 8) -> [HistoryEntry] {
        guard let statement = prepare("SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC LIMIT \(limit)") else { return [] }
        defer { sqlite3_finalize(statement) }
        return collect(statement)
    }

    private func collect(_ statement: OpaquePointer) -> [HistoryEntry] {
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
