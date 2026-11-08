import AppKit
import os

/// One-click import from Arc: spaces (with names and colors), pinned tabs and Favorites as bookmarks, and history.
/// Reads Arc's local files only; nothing leaves the Mac.
enum ArcImporter {
    struct Result {
        var spaces = 0
        var bookmarks = 0
        var historyEntries = 0
        /// What stopped part of the import, said plainly; nothing is ever dropped silently.
        var problems: [ImportProblem] = []
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zigzag", category: "import")

    /// What of Arc's couldn't be read.
    private enum Part: String { case history, sidebar = "spaces and pinned tabs" }

    /// Turns a file error into something to show: macOS refusing access gets the fix that opens its setting.
    private static func problem(reading part: Part, _ error: Error, retries: Int = 8) -> ImportProblem {
        let ns = error as NSError
        log.error("Arc import: couldn't read \(part.rawValue, privacy: .public): \(ns.domain, privacy: .public) \(ns.code)")
        let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
            || (ns.underlyingErrors.first as NSError?).map { $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EPERM) || $0.code == Int(EACCES)) } ?? false
        if denied {
            let message = switch part {
            case .history: String(localized: "macOS didn’t let Zigzag read Arc’s history. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on Arc, then try again.",
                                  comment: "Problem in the Import window. Arc is a browser's name; System Settings › Privacy & Security › Files & Folders is macOS's own wording.")
            case .sidebar: String(localized: "macOS didn’t let Zigzag read Arc’s spaces and pinned tabs. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on Arc, then try again.",
                                  comment: "Problem in the Import window. Arc is a browser's name; System Settings › Privacy & Security › Files & Folders is macOS's own wording.")
            }
            return ImportProblem(message: message, fix: .fullDiskAccess)
        }
        let message = switch part {
        case .history: String(localized: "Zigzag couldn’t read Arc’s history. Try again.", comment: "Problem in the Import window. Arc is a browser's name.")
        case .sidebar: String(localized: "Zigzag couldn’t read Arc’s spaces and pinned tabs. Try again.", comment: "Problem in the Import window. Arc is a browser's name.")
        }
        return ImportProblem(message: message, fix: .retry, retries: retries)
    }

    nonisolated static var arcSupport: URL {
        BrowserFolders.applicationSupport.appendingPathComponent("Arc", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: arcSupport.appendingPathComponent("StorableSidebar.json").path)
    }

    /// Everything: the sidebar, then history.
    @discardableResult
    static func importAll() -> (result: Result, firstSpace: UUID?) {
        var (result, first) = importSidebar()
        do {
            let entries = try readHistory()
            HistoryStore.shared.importVisits(entries)
            result.historyEntries = entries.count
        } catch { result.problems.append(historyProblem(error)) }
        return (result, first)
    }

    /// Trying again reads history only (`Choice.history`), never the sidebar a second time.
    static func historyProblem(_ error: Error) -> ImportProblem { problem(reading: .history, error, retries: 4) }

    /// Spaces, pinned tabs and Favorites.
    @discardableResult
    static func importSidebar() -> (result: Result, firstSpace: UUID?) {
        var result = Result()
        let (spaces, favorites): ([SpaceInfo], [Bookmark])
        do {
            (spaces, favorites) = try readSidebar()
        } catch {
            result.problems.append(problem(reading: .sidebar, error))
            (spaces, favorites) = ([], [])
        }
        var newSpaces = spaces
        // Arc's Favorites are global, like ours.
        let addedFavorites = Library.shared.appendFavorites(favorites)
        for favorite in favorites { FaviconStore.shared.prefetch(for: favorite.url) }
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
        result.bookmarks = newSpaces.map(\.bookmarks.count).reduce(0, +) + merged + addedFavorites
        if !newSpaces.isEmpty {
            // A fresh install's one empty space gives way to the imported ones. Spaces you made yourself stay, even empty.
            let before = Library.shared.spaces
            let pristine = before.count == 1 ? before.filter { space in
                space.bookmarks.isEmpty && WindowManager.shared.controllers.allSatisfy { $0.tabManager.tabs(in: space.id).isEmpty }
            } : []
            Library.shared.appendSpaces(newSpaces)
            for space in pristine where Library.shared.spaces.count > 1 { Library.shared.removeSpace(space.id) }
            for bookmark in newSpaces.flatMap(\.bookmarks) { FaviconStore.shared.prefetch(for: bookmark.url) }
        }
        log.notice("Arc import: \(result.spaces) spaces, \(result.bookmarks) bookmarks, \(result.problems.count) problems")
        return (result, newSpaces.first?.id)
    }

    // MARK: Sidebar

    struct FormatError: LocalizedError {
        var errorDescription: String? { "its sidebar file is in a format Zigzag doesn’t know yet" }
    }

    private static func readSidebar() throws -> (spaces: [SpaceInfo], favorites: [Bookmark]) {
        try parseSidebar(Data(contentsOf: arcSupport.appendingPathComponent("StorableSidebar.json")))
    }

    static func parseSidebar(_ data: Data) throws -> (spaces: [SpaceInfo], favorites: [Bookmark]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["spaces"] != nil }) else { throw FormatError() }

        // Arc stores lists as [key, value, key, value…] or as plain arrays; collect the dictionaries.
        let itemList = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var items: [String: [String: Any]] = [:]
        for item in itemList { if let id = item["id"] as? String { items[id] = item } }

        /// A pinned tab's page, if it's a web page.
        func tabPage(_ node: [String: Any]) -> [Bookmark] {
            guard let data = node["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                  let urlString = tab["savedURL"] as? String, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else { return [] }
            let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
            return [Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url))]
        }

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
            let name = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Space \(spaces.count + 1)", comment: "Name of an imported space that had none in Arc: Space 1, Space 2…")
            let containerIDs = space["containerIDs"] as? [Any] ?? []
            var pinnedID: String?
            for (i, value) in containerIDs.enumerated() where (value as? String) == "pinned" && i + 1 < containerIDs.count {
                pinnedID = containerIDs[i + 1] as? String
            }
            var info = SpaceInfo(name: name, color: color(of: space))
            if let pinnedID, let pinned = items[pinnedID] {
                // Arc's pinned folders come over as folders, nested as they were.
                var folders: [BookmarkFolder] = []
                func addFolder(_ id: String, parent: UUID?, depth: Int) {
                    guard depth < 8, let node = items[id] else { return }
                    var folder = BookmarkFolder(name: (node["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                                ?? String(localized: "Folder", comment: "Name of an imported folder that had none."))
                    folder.parentID = parent
                    let at = folders.count
                    folders.append(folder)
                    for child in node["childrenIds"] as? [String] ?? [] {
                        guard let inner = items[child], let data = inner["data"] as? [String: Any] else { continue }
                        if data["tab"] != nil || data["splitView"] != nil {
                            // A page, or a split view's pages, pinned in this folder.
                            let pages = data["tab"] != nil ? tabPage(inner) : bookmarks(under: child)
                            info.bookmarks += pages
                            folders[at].bookmarkIDs += pages.map(\.id)
                        } else {
                            addFolder(child, parent: folder.id, depth: depth + 1)
                        }
                    }
                }
                for child in pinned["childrenIds"] as? [String] ?? [] {
                    guard let node = items[child] else { continue }
                    let isTab = (node["data"] as? [String: Any])?["tab"] != nil
                    let inside = isTab ? [] : bookmarks(under: child)
                    if isTab {
                        if let data = node["data"] as? [String: Any], let tab = data["tab"] as? [String: Any],
                           let urlString = tab["savedURL"] as? String, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" {
                            let title = (node["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host() ?? urlString
                            info.bookmarks.append(Bookmark(url: url, title: TabManager.bookmarkTitle(title, url: url)))
                        }
                    } else if (node["data"] as? [String: Any])?["splitView"] != nil {
                        // A split view isn't a folder: its pages are pinned on their own.
                        info.bookmarks += inside
                    } else if !inside.isEmpty {
                        addFolder(child, parent: nil, depth: 0)
                    }
                }
                // A folder with no pages anywhere inside it doesn't come over.
                folders = folders.filter { !folders.pages(in: $0.id).isEmpty }
                if !folders.isEmpty { info.folders = folders }
            }
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
        let candidates = SpaceColor.allCases.filter { !$0.isNeutral }
        return candidates.min { a, b in
            hueDistance(hue, (a.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0)) < hueDistance(hue, (b.swatch.usingColorSpace(.sRGB)?.hueComponent ?? 0))
        } ?? .sky
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    // MARK: History

    /// Reads Arc's Chromium history, off the main thread: the file can be hundreds of megabytes. Every profile's, as
    /// Arc's spaces can live in any of them ("Default", "Profile 1"…); the newest visit of a page wins.
    nonisolated static func readHistory() throws -> [(URL, String, Int, Date)] {
        let userData = arcSupport.appendingPathComponent("User Data", isDirectory: true)
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: userData.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        var newest: [URL: (URL, String, Int, Date)] = [:]
        for profile in profiles {
            let source = userData.appendingPathComponent(profile).appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            for entry in readHistory(at: source) where newest[entry.0].map({ $0.3 < entry.3 }) ?? true {
                newest[entry.0] = entry
            }
        }
        return newest.values.sorted { $0.3 > $1.3 }
    }

    /// One profile's history, through a private copy with its write-ahead log (Arc keeps the file locked while
    /// running, and the latest visits may be only in the log).
    nonisolated private static func readHistory(at source: URL) -> [(URL, String, Int, Date)] {
        guard let reader = SQLiteReader(source) else { return [] }
        var entries: [(URL, String, Int, Date)] = []
        // Chromium time: microseconds since 1601-01-01.
        let epochOffset: Double = 11_644_473_600
        reader.rows("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 50000") { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url) else { return }
            let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - epochOffset)
            entries.append((url, row.string(1), Int(row.int(2)), date))
        }
        return entries
    }
}
