import AppKit
import SQLite3

/// What one source brings over. Every importer fills this in; `ImportCoordinator` puts it into Zigzag.
nonisolated struct ImportBatch: Sendable {
    struct Login: Sendable {
        let url: URL
        let username: String
        let password: SecretString
        let created: Date?
        var notes = ""
        var otpAuth = ""
    }

    struct Bookmark: Sendable {
        let url: URL
        let title: String
    }

    var logins: [Login] = []
    var bookmarks: [Bookmark] = []
    var history: [(URL, String, Int, Date)] = []
    /// Something that couldn't come over, and how to fix it.
    var problems: [ImportProblem] = []
}

/// A plain explanation and a one-click fix for what couldn't be imported.
nonisolated struct ImportProblem: Sendable, Hashable {
    enum Fix: Sendable, Hashable {
        /// Run the import again (after allowing access in the macOS prompt).
        case retry
        /// Ask for a primary password and try again.
        case primaryPassword
        /// Open System Settings › Privacy & Security › Files & Folders, where macOS lists the browsers Zigzag asked for.
        case fullDiskAccess
        /// Show how to export passwords from Safari or the Passwords app, then choose the file.
        case exportFromApplePasswords
        case none
    }

    let message: String
    let fix: Fix
}

/// Reads a browser's SQLite database through a private copy: browsers keep theirs open and locked.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?
    private let copy: URL

    init?(_ source: URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("zigzag-import-\(UUID().uuidString)", isDirectory: true)
        copy = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: source, to: copy)
            // The write-ahead log holds recent changes; without it the copy can miss the newest rows.
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            try? fm.removeItem(at: folder)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
        // The copy may hold encrypted passwords; it goes as soon as we're done.
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }

    /// Runs a query and hands each row to the closure.
    func rows(_ sql: String, _ row: (Row) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(Row(statement: statement)) }
    }

    struct Row {
        let statement: OpaquePointer?
        func string(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        func data(_ i: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, i) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
        }
    }
}
