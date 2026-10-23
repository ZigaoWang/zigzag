import AppKit
import SQLite3

/// One-click import from Arc: spaces (with names and colors), pinned tabs and Favorites as bookmarks, and history.
/// Reads Arc's local files only; nothing leaves the Mac.
enum ArcImporter {
    struct Result {
        var spaces = 0
        var bookmarks = 0
        var historyEntries = 0
    }

    static var arcSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: arcSupport.appendingPathComponent("StorableSidebar.json").path)
    }

    /// Menu command: import, then say what came over.
    static func runInteractive() {
        guard isAvailable else {
            let alert = NSAlert()
            alert.messageText = "Arc isn’t on this Mac"
            alert.informativeText = "Zigzag looks for Arc’s data in your Library folder and couldn’t find it."
            alert.runModal()
            return
        }
        let result = importAll()
        Library.shared.importedFromArc = true
        if let first = result.firstSpace, let controller = WindowManager.shared.keyController {
            controller.tabManager.switchToSpace(first)
        }
        let alert = NSAlert()
        alert.messageText = "Imported from Arc"
        var parts: [String] = []
        if result.result.spaces > 0 { parts.append("\(result.result.spaces) space\(result.result.spaces == 1 ? "" : "s")") }
        if result.result.bookmarks > 0 { parts.append("\(result.result.bookmarks) bookmark\(result.result.bookmarks == 1 ? "" : "s")") }
        if result.result.historyEntries > 0 { parts.append("\(result.result.historyEntries) history entries") }
        alert.informativeText = parts.isEmpty ? "There was nothing to bring over." : "Brought over " + parts.joined(separator: ", ") + ". Your pinned tabs are now bookmarks at the top of each space."
        if let window = WindowManager.shared.keyController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @discardableResult
    static func importAll() -> (result: Result, firstSpace: UUID?) {
        var result = Result()
        let (spaces, favorites) = readSidebar()
        var newSpaces = spaces
        if !favorites.isEmpty {
            if newSpaces.isEmpty { newSpaces = [SpaceInfo(name: "Personal", color: .sky)] }
            // Arc's Favorites were global; they become bookmarks at the top of the first space.
            newSpaces[0].bookmarks = favorites + newSpaces[0].bookmarks
        }
        result.spaces = newSpaces.count
        result.bookmarks = newSpaces.map(\.bookmarks.count).reduce(0, +)

        // Importing again merges: spaces with the same name gain only the bookmarks they don't have yet.
        var merged = 0
        newSpaces = newSpaces.filter { incoming in
            guard let existing = Library.shared.spaces.first(where: { $0.name == incoming.name }) else { return true }
            let known = Set(existing.bookmarks.map { TabManager.normalize($0.url) })
            for bookmark in incoming.bookmarks where !known.contains(TabManager.normalize(bookmark.url)) {
                Library.shared.addBookmark(url: bookmark.url, title: bookmark.title, to: existing.id)
                merged += 1
            }
            return false
        }
        result.spaces = newSpaces.count
        result.bookmarks = newSpaces.map(\.bookmarks.count).reduce(0, +) + merged
        if !newSpaces.isEmpty {
            // A fresh install's empty default space gives way to the imported ones.
            let pristine = Library.shared.spaces.filter { space in
                space.bookmarks.isEmpty && WindowManager.shared.controllers.allSatisfy { $0.tabManager.tabs(in: space.id).isEmpty }
            }
            Library.shared.appendSpaces(newSpaces)
            for space in pristine where Library.shared.spaces.count > 1 { Library.shared.removeSpace(space.id) }
            for bookmark in newSpaces.flatMap(\.bookmarks) { FaviconStore.shared.prefetch(for: bookmark.url) }
        }
        result.historyEntries = importHistory()
        return (result, newSpaces.first?.id)
    }

    // MARK: Sidebar

    private static func readSidebar() -> (spaces: [SpaceInfo], favorites: [Bookmark]) {
        let file = arcSupport.appendingPathComponent("StorableSidebar.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["spaces"] != nil }) else { return ([], []) }

        // Arc stores lists as [key, value, key, value…] or as plain arrays; collect the dictionaries.
        let itemList = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var items: [String: [String: Any]] = [:]
        for item in itemList { if let id = item["id"] as? String { items[id] = item } }

        func bookmarks(under id: String, depth: Int = 0) -> [Bookmark] {
            guard depth < 8, let item = items[id] else { return [] }
            var result: [Bookmark] = []
            for child in item["childrenIds"] as? [String] ?? [] {
                guard let node = items[child], let data = node["data"] as? [String: Any] else { continue }
                if let tab = data["tab"] as? [String: Any], let urlString = tab["savedURL"] as? String, let url = URL(string: urlString),
                   url.scheme == "http" || url.scheme == "https" {
                    let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
                    result.append(Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url)))
                } else {
                    // Folders flatten into the list, keeping their order.
                    result += bookmarks(under: child, depth: depth + 1)
                }
            }
            return result
        }

        var spaces: [SpaceInfo] = []
        for case let space as [String: Any] in main["spaces"] as? [Any] ?? [] {
            let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space \(spaces.count + 1)"
            let containerIDs = space["containerIDs"] as? [Any] ?? []
            var pinnedID: String?
            for (i, value) in containerIDs.enumerated() where (value as? String) == "pinned" && i + 1 < containerIDs.count {
                pinnedID = containerIDs[i + 1] as? String
            }
            var info = SpaceInfo(name: name, color: color(of: space))
            if let pinnedID { info.bookmarks = bookmarks(under: pinnedID) }
            spaces.append(info)
        }

        var favorites: [Bookmark] = []
        if let top = main["topAppsContainerIDs"] as? [Any] {
            for case let id as String in top { favorites += bookmarks(under: id) }
        }
        return (spaces, favorites)
    }

    /// Maps an Arc space's theme to the nearest of our tints.
    private static func color(of space: [String: Any]) -> SpaceColor {
        guard let info = space["customInfo"] as? [String: Any], let theme = info["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any],
              let mid = palette["midTone"] as? [String: Any],
              let r = mid["red"] as? Double, let g = mid["green"] as? Double, let b = mid["blue"] as? Double else { return .sky }
        let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        if color.saturationComponent < 0.15 { return .graphite }
        let hue = color.hueComponent
        let candidates = SpaceColor.allCases.filter { $0 != .graphite }
        return candidates.min { a, b in
            hueDistance(hue, (a.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0)) < hueDistance(hue, (b.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0))
        } ?? .sky
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    // MARK: History

    /// Reads Arc's Chromium history. The file is copied first because Arc keeps it locked while running.
    private static func importHistory() -> Int {
        let source = arcSupport.appendingPathComponent("User Data/Default/History")
        guard FileManager.default.fileExists(atPath: source.path) else { return 0 }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-arc-history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 50000"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        var entries: [(URL, String, Int, Date)] = []
        // Chromium time: microseconds since 1601-01-01.
        let epochOffset: Double = 11_644_473_600
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cURL = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: cURL)),
                  HistoryStore.shouldRecord(url) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let micros = Double(sqlite3_column_int64(statement, 3))
            let date = Date(timeIntervalSince1970: micros / 1_000_000 - epochOffset)
            entries.append((url, title, count, date))
        }
        HistoryStore.shared.importVisits(entries)
        return entries.count
    }
}
