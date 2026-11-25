import Foundation
import SQLite3

/// The History page's search: every word typed, in any order, somewhere in a page's title or address, ignoring case,
/// accents and full-width letters, so "cafe" finds "Café" and "ＡＢＣ" finds "ABC". Addresses are read decoded, so
/// Chinese in a link is found as typed. Matches come newest first, as History lists them.
nonisolated enum HistorySearch {
    /// The most pages one search shows.
    static let limit = 1000

    /// One page, with the text a search looks in, folded once.
    struct Row: Sendable {
        let entry: HistoryEntry
        let text: [UInt8]
    }

    /// Lowercase, without accents, full-width letters as plain ones.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// The words typed, folded, split at any space (an ideographic one too).
    static func words(_ query: String) -> [[UInt8]] {
        fold(query).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    /// The address as a search reads it: without its scheme or "www.", decoded.
    static func address(_ url: URL) -> String {
        var text = url.absoluteString
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.removingPercentEncoding ?? text
    }

    static func row(_ entry: HistoryEntry) -> Row {
        Row(entry: entry, text: Array((fold(entry.title) + "\n" + fold(address(entry.url))).utf8))
    }

    static func matches(_ words: [[UInt8]], _ text: [UInt8]) -> Bool {
        words.allSatisfy { word in
            text.withUnsafeBytes { hay in
                word.withUnsafeBytes { needle in memmem(hay.baseAddress, hay.count, needle.baseAddress, needle.count) != nil }
            }
        }
    }

    /// The rows that hold every word, newest first, at most `limit`. Rows come newest first.
    static func find(_ words: [[UInt8]], in rows: [Row], limit: Int = limit) -> [HistoryEntry] {
        guard !words.isEmpty else { return [] }
        var found: [HistoryEntry] = []
        for row in rows where matches(words, row.text) {
            found.append(row.entry)
            if found.count == limit { break }
        }
        return found
    }

    /// Every page in History, newest first, ready to search.
    static func rows(in db: OpaquePointer?) -> [Row] {
        HistoryDatabase.query(db, "SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC") { _ in }.map(row)
    }

    /// A number that changes whenever another connection changes the file.
    static func version(of db: OpaquePointer?) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : -1
    }
}
