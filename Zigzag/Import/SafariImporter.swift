import AppKit

/// Safari keeps bookmarks and history behind macOS's Full Disk Access, and its passwords in the Passwords
/// app, which no other app can read. So bookmarks and history come straight over once access is granted, and
/// passwords come from an export the person makes: the Passwords app's CSV, or Safari's "Export Browsing Data"
/// zip (bookmarks, history and passwords in one file).
nonisolated enum SafariImporter {
    static let bundleID = "com.apple.Safari"
    private static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true) }

    /// Whether Zigzag can read Safari's own files right now.
    static var hasAccess: Bool { FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("Bookmarks.plist").path) }

    static func read(_ choice: ChromiumImporter.Choice) -> ImportBatch {
        var batch = ImportBatch()
        if choice.contains(.passwords) {
            batch.problems.append(ImportProblem(message: "Safari's passwords are kept by the Passwords app. Export them there (File › Export All Passwords), then choose the file here.", fix: .exportFromApplePasswords))
        }
        guard choice.contains(.bookmarks) || choice.contains(.history) else { return batch }
        guard hasAccess else {
            batch.problems.append(ImportProblem(message: "To bring over Safari’s bookmarks and history, export them from Safari (File › Export Browsing Data to File) and choose that file here. Nothing else needs your permission.", fix: .exportFromApplePasswords))
            return batch
        }
        if choice.contains(.bookmarks) { batch.bookmarks = bookmarks() }
        if choice.contains(.history) { batch.history = history() }
        return batch
    }

    private static func bookmarks() -> [ImportBatch.Bookmark] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Bookmarks.plist")),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var result: [ImportBatch.Bookmark] = []
        func walk(_ node: [String: Any]) {
            // Reading List is a separate idea; it stays in Safari.
            if node["Title"] as? String == "com.apple.ReadingList" { return }
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let string = node["URLString"] as? String,
               let url = URL(string: string), url.scheme == "http" || url.scheme == "https" {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                result.append(ImportBatch.Bookmark(url: url, title: title ?? url.host() ?? string))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return result
    }

    private static func history() -> [(URL, String, Int, Date)] {
        guard let db = SQLiteReader(folder.appendingPathComponent("History.db")) else { return [] }
        var result: [(URL, String, Int, Date)] = []
        // Safari time: seconds since 2001-01-01.
        db.rows("""
        SELECT i.url, COALESCE(v.title, ''), i.visit_count, MAX(v.visit_time) FROM history_items i
        JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT 50000
        """) { row in
            guard let url = URL(string: row.string(0)), HistoryStore.shouldRecord(url) else { return }
            let seconds = Double(row.int(3))
            result.append((url, row.string(1), Int(row.int(2)), Date(timeIntervalSinceReferenceDate: seconds)))
        }
        return result
    }

    // MARK: Safari's export

    /// Safari's "Export Browsing Data" zip: its passwords CSV, bookmarks HTML and history JSON, whichever are in it.
    static func readExport(_ zip: URL) -> ImportBatch {
        var batch = ImportBatch()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        let unreadable = ImportProblem(message: "\(zip.lastPathComponent) isn’t a Safari export Zigzag can open. In Safari, choose File › Export Browsing Data, then choose the zip it makes.", fix: .none)
        guard (try? unzip.run()) != nil else { batch.problems.append(unreadable); return batch }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { batch.problems.append(unreadable); return batch }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files {
            switch file.pathExtension.lowercased() {
            case "csv":
                if case .success(let (_, csv)) = CSVImporter.read(file) { batch.logins += csv.logins; batch.problems += csv.problems }
            case "html":
                batch.bookmarks += netscapeBookmarks(file)
            case "json":
                batch.history += historyJSON(file)
            default:
                break
            }
        }
        if batch.logins.isEmpty, batch.bookmarks.isEmpty, batch.history.isEmpty, batch.problems.isEmpty { batch.problems.append(unreadable) }
        return batch
    }

    /// The bookmarks HTML every browser exports: `<A HREF="…">Title</A>`.
    static func netscapeBookmarks(_ file: URL) -> [ImportBatch.Bookmark] {
        guard let html = try? String(contentsOf: file, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"<A[^>]*HREF="([^"]+)"[^>]*>([^<]*)</A>"#, options: [.caseInsensitive]) else { return [] }
        return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let urlRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: decodeEntities(String(html[urlRange]))), url.scheme == "http" || url.scheme == "https" else { return nil }
            let title = decodeEntities(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            return ImportBatch.Bookmark(url: url, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title)
        }
    }

    /// "Tom &amp; Jerry&#39;s" → "Tom & Jerry's": the named entities exports use, and numbered ones.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var result = "", rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { decoded = named[String(name).lowercased()] }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }

    /// History JSON: entries with a URL, a title and a time, wherever they sit in the file.
    private static func historyJSON(_ file: URL) -> [(URL, String, Int, Date)] {
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var result: [(URL, String, Int, Date)] = []
        func walk(_ value: Any) {
            if let entry = value as? [String: Any], let string = entry["url"] as? String, let url = URL(string: string), HistoryStore.shouldRecord(url) {
                let micros = (entry["time_usec"] as? Double) ?? (entry["time"] as? Double).map { $0 * 1_000_000 } ?? 0
                let date = micros > 0 ? Date(timeIntervalSince1970: micros / 1_000_000) : Date()
                result.append((url, entry["title"] as? String ?? "", (entry["visit_count"] as? Int) ?? 1, date))
            } else if let array = value as? [Any] {
                array.forEach(walk)
            } else if let object = value as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(json)
        return result
    }
}
