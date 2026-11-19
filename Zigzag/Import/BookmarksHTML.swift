import Foundation

/// The Netscape bookmarks HTML that Firefox, Safari, Chrome and Edge export: `<H3>` folders over `<DL>` lists,
/// `<A HREF>` pages. A tolerant scanner, since the files are rarely well formed.
nonisolated enum BookmarksHTML {
    /// A bookmarks file, or a problem if it has none.
    static func read(_ file: URL) -> ImportBatch {
        var batch = ImportBatch()
        if let data = try? Data(contentsOf: file) { batch.bookmarks = bookmarks(in: text(of: data)) }
        if batch.bookmarks.isEmpty {
            batch.problems.append(ImportProblem(message: String(localized: "\(file.lastPathComponent) has no bookmarks Zigzag can read. Export your bookmarks as an HTML file from your browser, then choose it.",
                                                                comment: "Problem in the Import window. The placeholder is the chosen file's name."),
                                                fix: .none))
        }
        return batch
    }

    /// UTF-8, else Latin-1 for old exports.
    static func text(of data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Each web page with its folder path. Browser root folders are flattened; Reading List, feeds and non-web
    /// links are skipped.
    static func bookmarks(in html: String) -> [ImportBatch.Bookmark] {
        struct Frame { let name: String?; let skipped: Bool }
        enum Pending { case none, folder(String?), skipped }
        var stack: [Frame] = []
        var pending = Pending.none
        var result: [ImportBatch.Bookmark] = []
        let chars = Array(html.utf16)
        var i = 0

        /// The text from `start` up to the next tag, decoded and trimmed.
        func textRun(from start: Int) -> String {
            var end = start
            while end < chars.count, chars[end] != 0x3C { end += 1 }
            let raw = String(decoding: chars[start..<end], as: UTF16.self)
            return decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while i < chars.count {
            guard chars[i] == 0x3C else { i += 1; continue }  // "<"
            // The tag runs to the first ">" outside quotes.
            var j = i + 1, quote: UInt16 = 0
            while j < chars.count {
                let c = chars[j]
                if quote != 0 { if c == quote { quote = 0 } } else if c == 0x22 || c == 0x27 { quote = c } else if c == 0x3E { break }
                j += 1
            }
            guard j < chars.count else { break }
            let tag = String(decoding: chars[(i + 1)..<j], as: UTF16.self)
            i = j + 1
            let closing = tag.hasPrefix("/")
            let body = closing ? tag.dropFirst() : tag[...]
            let name = body.prefix { $0.isLetter || $0.isNumber }.uppercased()
            let skipping = stack.last?.skipped ?? false

            switch (name, closing) {
            case ("DL", false):
                switch pending {
                case .folder(let folder): stack.append(Frame(name: folder, skipped: skipping))
                case .skipped: stack.append(Frame(name: nil, skipped: true))
                case .none: stack.append(Frame(name: nil, skipped: skipping))
                }
                pending = .none
            case ("DL", true):
                if !stack.isEmpty { stack.removeLast() }
                pending = .none
            case ("H3", false):
                let attributes = attributes(of: body.dropFirst(name.count))
                let title = textRun(from: i)
                let top = stack.filter { $0.name != nil }.isEmpty && stack.count <= 1
                if isReadingList(title, attributes, top: top) {
                    pending = .skipped
                } else if isBrowserRoot(title, attributes, top: top) {
                    pending = .folder(nil)
                } else {
                    pending = .folder(title.isEmpty ? String(localized: "Folder", comment: "Name of an imported folder that had none.") : title)
                }
            case ("A", false):
                pending = .none
                guard !skipping else { continue }
                let attributes = attributes(of: body.dropFirst(name.count))
                // Old Firefox live bookmarks (feeds).
                guard attributes["FEEDURL"] == nil, let href = attributes["HREF"],
                      let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                let title = textRun(from: i)
                result.append(ImportBatch.Bookmark(url: url, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                                   folders: stack.compactMap(\.name)))
            default:
                break
            }
        }
        return result
    }

    /// Toolbar and Other Bookmarks by attribute; Safari's roots by name.
    private static func isBrowserRoot(_ title: String, _ attributes: [String: String], top: Bool) -> Bool {
        if attributes["PERSONAL_TOOLBAR_FOLDER"] != nil || attributes["UNFILED_BOOKMARKS_FOLDER"] != nil { return true }
        if let id = attributes["ID"], ["BookmarksBar", "BookmarksMenu"].contains(id) { return true }
        guard top else { return false }
        let roots: Set<String> = ["favorites", "favourites", "bookmarks bar", "bookmarks menu", "bookmarks toolbar",
                                  "other bookmarks", "个人收藏", "书签栏", "书签菜单", "书签工具栏", "其他书签"]
        return roots.contains(title.lowercased())
    }

    /// Safari's Reading List, skipped as in the Safari importer.
    private static func isReadingList(_ title: String, _ attributes: [String: String], top: Bool) -> Bool {
        if attributes["ID"] == "com.apple.ReadingList" { return true }
        return top && ["reading list", "阅读列表"].contains(title.lowercased())
    }

    /// Attributes by upper-case name, values decoded.
    static func attributes(of text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = text
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            let key = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != ">" }
            guard !key.isEmpty else { break }
            rest = rest.dropFirst(key.count).drop(while: \.isWhitespace)
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let inner = rest.dropFirst()
                    let end = inner.firstIndex(of: quote) ?? inner.endIndex
                    value = String(inner[..<end])
                    rest = end < inner.endIndex ? inner[inner.index(after: end)...] : inner[end...]
                } else {
                    let bare = rest.prefix { !$0.isWhitespace }
                    value = String(bare)
                    rest = rest.dropFirst(bare.count)
                }
            }
            result[key.uppercased()] = decodeEntities(value)
        }
        return result
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
}
