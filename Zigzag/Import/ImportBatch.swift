import AppKit
import SQLite3

/// What one source brings over. Every importer fills this in; `ImportCoordinator` puts it into Zigzag.
nonisolated struct ImportBatch: Sendable {
    struct Login: Sendable {
        let url: URL
        let username: String
        let password: SecretString
        let created: Date?
        /// When its password last changed, where the source keeps that: newer wins when the same login is here.
        var changed: Date? = nil
        var notes = ""
        var otpAuth = ""
    }

    struct Bookmark: Sendable {
        let url: URL
        let title: String
        /// The folders it was in, outermost first ("Work", "Docs"); empty at the top level.
        var folders: [String] = []
    }

    var logins: [Login] = []
    var bookmarks: [Bookmark] = []
    var history: [(URL, String, Int, Date)] = []
    /// The sites you're signed in to there; held only until they're set into Zigzag's website data.
    var cookies: [SignInImporter.Cookie] = []
    /// There, but wouldn't open: said gently once they're in, with any WebKit wouldn't take.
    var unreadableCookies = 0
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
    /// What fixing it runs again (an `ImportCoordinator.Choice`'s raw value): only the part that failed, so
    /// trying again never brings history or tabs over a second time. Zero means everything.
    var retries: Int = 0
}

/// Where other browsers keep their data: ~/Library/Application Support.
nonisolated enum BrowserFolders {
    static var applicationSupport: URL {
        #if DEBUG
        if let fake { return fake }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    #if DEBUG
    /// A debug copy checked by script reads made-up profiles from this folder instead (ZIGZAG_FAKE_BROWSERS, a path),
    /// so no run ever opens a real browser's data, its Keychain item, or Safari's.
    static let fake: URL? = {
        guard let path = ProcessInfo.processInfo.environment["ZIGZAG_FAKE_BROWSERS"], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
    #endif
}

/// The folders an import reads through: a browser's database copied out of its way, Safari's export unzipped. They
/// can hold passwords, so they're yours alone, and any a crash left behind go at the next launch.
nonisolated enum ImportScratch {
    static let prefixes = ["zigzag-import-", "zigzag-safari-"]

    /// A new, empty folder only you can open.
    static func makeFolder(_ prefix: String, in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = parent.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Removes folders left from imports that never finished. Not one made in the last few minutes: another Zigzag
    /// (the dev copy, say) may be reading through it right now.
    static func removeLeftovers(in parent: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where prefixes.contains(where: name.hasPrefix) {
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            let made = (try? fm.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(made) > 10 * 60 { try? fm.removeItem(at: folder) }
        }
    }
}

/// Reads a browser's SQLite database through a private copy: browsers keep theirs open and locked.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?
    private let copy: URL

    init?(_ source: URL) {
        let fm = FileManager.default
        guard let folder = try? ImportScratch.makeFolder("zigzag-import-") else { return nil }
        copy = folder.appendingPathComponent(source.lastPathComponent)
        do {
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
