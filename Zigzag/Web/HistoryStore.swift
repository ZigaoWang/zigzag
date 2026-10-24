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
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        guard sqlite3_open(Paths.history.path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
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

    /// Bulk import inside one transaction.
    func importVisits(_ entries: [(URL, String, Int, Date)]) {
        exec("BEGIN")
        for (url, title, count, date) in entries { recordVisit(url: url, title: title, at: date, count: max(1, count)) }
        exec("COMMIT")
    }

    func clearAll() {
        exec("DELETE FROM visits")
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

    /// The most visited URL whose host starts with the typed text, for inline completion.
    func bestHostCompletion(for prefix: String) -> HistoryEntry? {
        let lower = prefix.lowercased()
        guard !lower.isEmpty, !lower.contains(" "), let statement = prepare("""
        SELECT url, title, SUM(visit_count) AS c, MAX(last_visit) FROM visits
        WHERE host LIKE ?1 ESCAPE '\\' GROUP BY host ORDER BY c DESC LIMIT 1
        """) else { return nil }
        defer { sqlite3_finalize(statement) }
        let escaped = lower.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(statement, 1, "\(escaped)%", -1, transient)
        return collect(statement).first
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
