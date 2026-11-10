import Foundation

/// Orion, Kagi's WebKit browser. Its data is under ~/Library/Application Support/Orion, the default profile in
/// `Defaults` (as Kagi's help pages list it): bookmarks in `favourites.plist`, the reading list in
/// `reading_list.plist`, history in an SQLite file named `history`, and the extensions added from the Chrome
/// Web Store in `Extensions/extensions.plist`.
///
/// Passwords stay behind: Orion keeps them in its own Keychain, which no other app can read. Orion exports them
/// (File › Export › Passwords), and that file comes over like any other.
nonisolated enum OrionImporter {
    static let name = "Orion"
    static let bundleID = "com.kagi.kagimacOS"
    /// Under ~/Library/Application Support.
    static let root = "Orion"
    /// The default profile's folder.
    static let defaultProfile = "Defaults"
    /// Orion's own folders next to its profiles, which hold no profile.
    private static let notProfiles: Set<String> = ["profiles", "Shared", "WebApps", "snapshots", "NativeMessagingHosts", "PKCS11 Modules"]

    struct Browser: Sendable, Hashable {
        /// One profile's folder ("Defaults"), when importing a single profile; nil means all of them.
        var profile: String? = nil
        /// That profile's name as Orion shows it ("Work").
        var profileName: String? = nil

        func only(_ folder: String, named display: String) -> Browser { Browser(profile: folder, profileName: display) }
    }

    static var rootURL: URL { BrowserFolders.applicationSupport.appendingPathComponent(root, isDirectory: true) }

    /// Whether a folder holds a profile: its bookmarks or its history.
    private static func isProfile(_ folder: URL) -> Bool {
        ["favourites.plist", "history"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Each profile's folder and its name, the default one first. Other profiles sit next to `Defaults` in folders
    /// of their own; their names, where Orion lists them in `profiles`, are looked up there.
    static func profileNames(in root: URL = rootURL) -> [(folder: String, name: String)] {
        let fm = FileManager.default
        var folders: [String] = []
        if isProfile(root.appendingPathComponent(defaultProfile, isDirectory: true)) { folders.append(defaultProfile) }
        let others = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != defaultProfile && !notProfiles.contains($0) && !$0.contains("..") }
            .filter { isProfile(root.appendingPathComponent($0, isDirectory: true)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        folders += others
        let listed = listedNames(in: root.appendingPathComponent("profiles"))
        var unnamed = 0
        return folders.map { folder -> (folder: String, name: String) in
            if folder == defaultProfile {
                return (folder, String(localized: "import.orion-default-profile", defaultValue: "Default", comment: "Name of Orion's default profile, in the Import window: Orion (Default)."))
            }
            if let name = listed[folder.lowercased()] { return (folder, name) }
            // A folder named by an ID: a number reads better than that.
            if UUID(uuidString: folder) != nil {
                unnamed += 1
                return (folder, String(localized: "Profile \(unnamed + 1)", comment: "Name of an Orion profile whose name couldn't be found, in the Import window: Orion (Profile 2)."))
            }
            return (folder, folder)
        }
    }

    /// Profile names from Orion's `profiles` list (a plist, or a folder of them): any entry that names a folder
    /// alongside a name, by the folder's name in lowercase.
    static func listedNames(in profiles: URL) -> [String: String] {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: profiles.path, isDirectory: &isFolder) else { return [:] }
        let files = isFolder.boolValue
            ? ((try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "plist" }
            : [profiles]
        var names: [String: String] = [:]
        func walk(_ value: Any, depth: Int) {
            guard depth < 6 else { return }
            if let entry = value as? [String: Any] {
                let name = ["name", "title", "profileName", "displayName"].lazy.compactMap { entry[$0] as? String }
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let name {
                    for case let id as String in entry.values where id != name { names[id.lowercased()] = name }
                }
                entry.values.forEach { walk($0, depth: depth + 1) }
            } else if let list = value as? [Any] {
                list.forEach { walk($0, depth: depth + 1) }
            }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            walk(plist, depth: 0)
        }
        return names
    }

    /// The profile folders to read.
    static func profiles(of browser: Browser, in root: URL = rootURL) -> [URL] {
        var folders = profileNames(in: root).map(\.folder)
        if let only = browser.profile { folders = folders.filter { $0 == only } }
        return folders.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    static func isInstalled(_ browser: Browser = Browser(), in root: URL = rootURL) -> Bool { !profiles(of: browser, in: root).isEmpty }

    /// Its files are there but macOS won't open them to Zigzag.
    static func isPrivate(_ browser: Browser) -> Bool {
        let fm = FileManager.default
        return profiles(of: browser).contains { profile in
            ["favourites.plist", "history", "reading_list.plist"].map { profile.appendingPathComponent($0).path }
                .contains { fm.fileExists(atPath: $0) && !fm.isReadableFile(atPath: $0) }
        }
    }

    static func read(_ browser: Browser, _ choice: ChromiumImporter.Choice) -> ImportBatch {
        var batch = ImportBatch()
        if choice.contains(.passwords) {
            batch.problems.append(ImportProblem(message: String(localized: "Orion keeps its passwords in its own Keychain, which only Orion can open. Export them there (File › Export › Passwords), then choose the file here.",
                                                                comment: "Note in the Import window. File › Export › Passwords is Orion's own menu wording."),
                                                fix: .exportFromApplePasswords))
        }
        guard choice.contains(.bookmarks) || choice.contains(.history) else { return batch }
        if isPrivate(browser) {
            batch.problems.append(ImportProblem(message: String(localized: "macOS keeps \(name)’s data private until you allow it. In System Settings › Privacy & Security › Files & Folders, find Zigzag and turn on \(name), then try again.",
                                                                comment: "Problem in the Import window. The placeholder is a browser's name, like Chrome; System Settings › Privacy & Security › Files & Folders is macOS's own wording."),
                                                fix: .fullDiskAccess))
            return batch
        }
        for profile in profiles(of: browser) {
            if choice.contains(.bookmarks) {
                batch.bookmarks += bookmarks(at: profile.appendingPathComponent("favourites.plist"))
                batch.bookmarks += readingList(at: profile.appendingPathComponent("reading_list.plist"))
            }
            if choice.contains(.history) { batch.history += history(at: profile.appendingPathComponent("history")) }
        }
        return batch
    }

    /// How much it holds: bookmarks (with the reading list) and pages of history.
    static func counts(_ browser: Browser) -> (bookmarks: Int, history: Int) {
        var bookmarks = 0, history = 0
        for profile in profiles(of: browser) {
            bookmarks += self.bookmarks(at: profile.appendingPathComponent("favourites.plist")).count
                + readingList(at: profile.appendingPathComponent("reading_list.plist")).count
            let file = profile.appendingPathComponent("history")
            if FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) {
                db.rows("SELECT count(*) FROM history_items") { history += Int($0.int(0)) }
            }
        }
        return (bookmarks, history)
    }

    // MARK: Files

    /// `favourites.plist`: every item by its ID, each with `type` (folder or bookmark), `parentId`, `index`,
    /// `title` and, for a bookmark, `url`. Orion's own top folders (Favorites, Bookmarks Bar, Bookmarks) aren't
    /// yours, so what's in them comes over at the top level, and folders inside them as folders.
    static func bookmarks(at file: URL) -> [ImportBatch.Bookmark] {
        guard let data = try? Data(contentsOf: file),
              let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        struct Item { let id: String; let parent: String?; let index: Int; let type: String; let title: String; let url: String?; let builtIn: Bool }
        let all: [Item] = items.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            let id = (entry["id"] as? String) ?? key
            let parent = (entry["parentId"] as? String) ?? (entry["parentId"] as? Int).map(String.init)
            return Item(id: id, parent: parent == id ? nil : parent, index: (entry["index"] as? Int) ?? 0,
                        type: (entry["type"] as? String) ?? "", title: (entry["title"] as? String) ?? "",
                        url: entry["url"] as? String, builtIn: entry["unmodifiable"] != nil)
        }
        let ids = Set(all.map(\.id))
        var children: [String: [Item]] = [:]
        var tops: [Item] = []
        for item in all {
            if let parent = item.parent, ids.contains(parent) { children[parent, default: []].append(item) } else { tops.append(item) }
        }
        func ordered(_ list: [Item]) -> [Item] { list.sorted { ($0.index, $0.id) < ($1.index, $1.id) } }
        var result: [ImportBatch.Bookmark] = []
        var seen = Set<String>()
        func walk(_ item: Item, in path: [String], depth: Int) {
            guard seen.insert(item.id).inserted, depth < 64 else { return }
            if item.type == "folder" {
                // The root (depth 0) and Orion's own folders under it don't become folders here.
                let own = depth >= 2 || (depth == 1 && !item.builtIn)
                let name = item.title.isEmpty ? String(localized: "Folder", comment: "Name of an imported folder that had none.") : item.title
                for child in ordered(children[item.id] ?? []) { walk(child, in: own ? path + [name] : path, depth: depth + 1) }
            } else if let string = item.url, let url = URL(string: string), url.scheme == "http" || url.scheme == "https" {
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ImportBatch.Bookmark(url: url, title: title.isEmpty ? (url.host() ?? string) : title, folders: path))
            }
        }
        for top in ordered(tops) {
            // The root folder has no parent; a bookmark whose folder is gone comes over at the top level.
            walk(top, in: [], depth: top.type == "folder" && top.parent == nil && top.title.isEmpty ? 0 : 1)
        }
        return result
    }

    /// `reading_list.plist`: a list of pages, each with `title` and `url` (a dictionary whose `relative` is the
    /// address). They come over in a folder of their own, so they stay apart from the bookmarks.
    static func readingList(at file: URL) -> [ImportBatch.Bookmark] {
        guard let data = try? Data(contentsOf: file),
              let items = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        let folder = String(localized: "Reading List", comment: "Folder that pages from another browser's reading list are imported into.")
        return items.compactMap { entry in
            let string = ((entry["url"] as? [String: Any])?["relative"] as? String) ?? (entry["url"] as? String)
            guard let string, let url = URL(string: string), url.scheme == "http" || url.scheme == "https" else { return nil }
            let title = ((entry["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ImportBatch.Bookmark(url: url, title: title.isEmpty ? (url.host() ?? string) : title, folders: [folder])
        }
    }

    /// `history`: WebKit-style `history_items`, each page once with its visit count and last visit, written by
    /// SQLite as "YYYY-MM-DD HH:MM:SS" in UTC.
    static func history(at file: URL) -> [(URL, String, Int, Date)] {
        guard FileManager.default.fileExists(atPath: file.path), let db = SQLiteReader(file) else { return [] }
        var result: [(URL, String, Int, Date)] = []
        db.rows("""
        SELECT URL, COALESCE(TITLE, ''), COALESCE(VISIT_COUNT, 1),
               CASE WHEN typeof(LAST_VISIT_TIME) = 'text' THEN strftime('%s', LAST_VISIT_TIME) ELSE LAST_VISIT_TIME END
        FROM history_items ORDER BY LAST_VISIT_TIME DESC LIMIT 50000
        """) { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url) else { return }
            result.append((url, row.string(1), max(1, Int(row.int(2))), date(row.string(3))))
        }
        return result
    }

    /// A visit time as stored: seconds since 1970 (from the text), or a number in milliseconds, in seconds, or
    /// in seconds since 2001 as Apple's frameworks write it.
    static func date(_ value: String) -> Date {
        guard let number = Double(value), number > 0 else { return Date() }
        if number > 1e11 { return Date(timeIntervalSince1970: number / 1000) }
        if number > 1e9 { return Date(timeIntervalSince1970: number) }
        return Date(timeIntervalSinceReferenceDate: number)
    }

    // MARK: Extensions

    /// The Chrome Web Store extensions on in Orion: `Extensions/extensions.plist` lists each with its
    /// `store_type`, `store_id` and whether it's `active`; its files, with the manifest, are in a folder of its own
    /// next to that list. Ones from Firefox's store, and ones turned off, stay behind.
    static func extensions(of browser: Browser, source: String) -> [ChromiumExtensions.Found] {
        var seen = Set<String>()
        return profiles(of: browser).flatMap { extensions(inProfile: $0) }
            .filter { seen.insert($0.id).inserted }
            .map { ChromiumExtensions.Found(id: $0.id, name: $0.name, source: source) }
    }

    static func extensions(inProfile profile: URL) -> [ChromiumExtensions.Found] {
        let folder = profile.appendingPathComponent("Extensions", isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("extensions.plist")),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entries = list["extensions"] as? [String: Any] else { return [] }
        return entries.compactMap { key, value -> ChromiumExtensions.Found? in
            guard let entry = value as? [String: Any], entry["store_type"] as? String == "chrome",
                  entry["active"] as? Bool ?? true else { return nil }
            let id = (entry["store_id"] as? String) ?? key
            guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
            var manifest: [String: Any] = [:]
            var files: URL?
            for name in [key, id] where !name.contains("/") && !name.contains("..") {
                let candidate = folder.appendingPathComponent(name, isDirectory: true)
                if let data = try? Data(contentsOf: candidate.appendingPathComponent("manifest.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    manifest = json
                    files = candidate
                    break
                }
            }
            // Themes and apps aren't extensions here.
            guard manifest["theme"] == nil, manifest["app"] == nil else { return nil }
            return ChromiumExtensions.Found(id: id, name: ChromiumExtensions.name(manifest, in: files) ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
