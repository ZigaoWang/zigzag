import Foundation

/// What a feed says, read by `LiveFeedParser`: its name and its entries, newest first.
nonisolated struct LiveFeed: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// What stays the same for this entry from one fetch to the next: its guid or id, else its link.
        var key: String
        var url: URL
        var title: String
        var date: Date?
    }

    var title: String?
    var entries: [Entry]
}

/// Reads RSS 2.0, Atom 1.0 and RSS 1.0 (RDF) with XMLParser.
nonisolated enum LiveFeedParser {
    /// The most entries read from one feed; the rest are left unread.
    static let maxEntries = 500

    /// Nil when it isn't a feed. Links are resolved against `base` (the feed's own address) and xml:base.
    static func parse(_ data: Data, base: URL) -> LiveFeed? {
        if let feed = read(data, base: base) { return feed }
        // Feeds written by hand often use HTML entities XML doesn't know, or a bare &.
        guard let repaired = FeedText.repairedXML(data) else { return nil }
        return read(repaired, base: base)
    }

    private static func read(_ data: Data, base: URL) -> LiveFeed? {
        let reader = Reader(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let finished = parser.parse()
        guard reader.kind != nil, finished || reader.stoppedAtLimit else { return nil }
        return LiveFeed(title: reader.feedTitle.flatMap(FeedText.title), entries: ordered(reader.entries))
    }

    /// One entry per key, the first kept; newest first when every entry is dated, else in the feed's own order.
    static func ordered(_ entries: [LiveFeed.Entry]) -> [LiveFeed.Entry] {
        var seen: Set<String> = []
        let unique = entries.filter { seen.insert($0.key).inserted }
        guard unique.allSatisfy({ $0.date != nil }) else { return unique }
        return unique.enumerated().sorted { a, b in
            a.element.date! != b.element.date! ? a.element.date! > b.element.date! : a.offset < b.offset
        }.map(\.element)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        enum Kind { case rss, atom, rdf }
        var kind: Kind?
        var feedTitle: String?
        var entries: [LiveFeed.Entry] = []
        var stoppedAtLimit = false

        private struct Draft {
            var title: String?
            var titleIsHTML = false
            var link: String?
            var alternate: String?
            var guid: String?
            var guidIsLink = true
            var about: String?
            var published: String?
            var updated: String?
            var base: URL
        }

        private var path: [String] = []
        private var bases: [URL]
        private var draft: Draft?
        private var entryDepth = 0
        private var text = ""
        private var capturing: String?
        private var titleIsHTML = false

        init(base: URL) { bases = [base] }

        private static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes: [String: String] = [:]) {
            let name = Self.local(elementName)
            let parentBase = bases.last!
            bases.append(attributes["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase)
            if path.isEmpty {
                switch name {
                case "rss": kind = .rss
                case "feed": kind = .atom
                case "RDF": kind = .rdf
                default: parser.abortParsing()
                }
            }
            path.append(name)
            if draft == nil, name == "item" || name == "entry" {
                draft = Draft(base: bases.last!)
                draft?.about = attributes["rdf:about"]
                entryDepth = path.count
                return
            }
            if capturing != nil { return }
            if draft != nil, path.count == entryDepth + 1 {
                switch name {
                case "link" where kind == .atom:
                    let rel = attributes["rel"] ?? "alternate"
                    let href = attributes["href"].flatMap { URL(string: $0, relativeTo: bases.last!)?.absoluteString }
                    if rel == "alternate", draft?.alternate == nil { draft?.alternate = href }
                    if draft?.link == nil, rel != "self", rel != "enclosure", rel != "replies" { draft?.link = href }
                case "guid":
                    draft?.guidIsLink = attributes["isPermaLink"]?.lowercased() != "false"
                    capture(name, html: false)
                case "title":
                    capture(name, html: attributes["type"] == "html" || attributes["type"] == "xhtml" || kind == .rss)
                case "link", "id", "pubDate", "date", "published", "updated", "issued", "modified":
                    capture(name, html: false)
                default: break
                }
            } else if draft == nil, name == "title", feedTitle == nil {
                // The feed's own name: under channel (RSS, RDF) or feed (Atom).
                let parent = path.count >= 2 ? path[path.count - 2] : ""
                if parent == "channel" || (parent == "feed" && path.count == 2) { capture(name, html: true) }
            }
        }

        private func capture(_ name: String, html: Bool) {
            capturing = name
            titleIsHTML = html
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing != nil { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if capturing != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = Self.local(elementName)
            defer {
                path.removeLast()
                bases.removeLast()
            }
            if let field = capturing, field == name, path.count == (draft == nil ? path.count : entryDepth + 1) {
                capturing = nil
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if draft == nil {
                    feedTitle = value
                } else {
                    switch name {
                    case "title":
                        draft?.title = value
                        draft?.titleIsHTML = titleIsHTML
                    case "link": if draft?.link == nil, !value.isEmpty { draft?.link = value }
                    case "guid", "id": draft?.guid = value
                    case "pubDate", "published", "issued": draft?.published = value
                    case "date", "updated", "modified": draft?.updated = value
                    default: break
                    }
                }
                return
            }
            guard draft != nil, path.count == entryDepth, name == "item" || name == "entry" else { return }
            if let entry = finish(draft!) { entries.append(entry) }
            draft = nil
            if entries.count >= LiveFeedParser.maxEntries {
                stoppedAtLimit = true
                parser.abortParsing()
            }
        }

        private func finish(_ draft: Draft) -> LiveFeed.Entry? {
            // RSS without a link: a guid that is the page's address stands in.
            let guidLink = kind == .rss && draft.guidIsLink ? draft.guid : nil
            guard let raw = draft.alternate ?? draft.link ?? guidLink ?? draft.about,
                  let url = FeedText.pageURL(raw, base: draft.base) else { return nil }
            let date = (draft.published ?? draft.updated).flatMap(FeedDates.parse) ?? draft.updated.flatMap(FeedDates.parse)
            let title = draft.title.flatMap { draft.titleIsHTML ? FeedText.title($0) : FeedText.plainTitle($0) } ?? FeedText.fallbackTitle(for: url)
            let key = draft.guid.flatMap { $0.isEmpty ? nil : $0 } ?? draft.about ?? url.absoluteString
            return LiveFeed.Entry(key: key, url: url, title: title, date: date)
        }
    }
}

/// Feed text into plain titles and addresses.
nonisolated enum FeedText {
    /// The longest a title is kept.
    static let maxTitle = 300

    /// A web address for a link, resolved against `base`; nil for anything but http and https.
    static func pageURL(_ raw: String, base: URL) -> URL? {
        let trimmed = decodeEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // An address with spaces or other unescaped characters in it, escaped.
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#", "%"])) ?? trimmed
        guard !trimmed.isEmpty, let url = (URL(string: trimmed, relativeTo: base) ?? URL(string: escaped, relativeTo: base))?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// A title as one line of plain text: tags dropped, entities decoded, spaces collapsed. Nil when nothing is left.
    static func title(_ raw: String) -> String? {
        var text = raw
        if text.contains("<") { text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression) }
        text = collapsed(decodeEntities(text))
        if text.count > maxTitle { text = String(text.prefix(maxTitle)) + "…" }
        return text.isEmpty ? nil : text
    }

    /// A title that is plain text already (Atom's type="text"): only spaces collapsed.
    static func plainTitle(_ raw: String) -> String? {
        var text = collapsed(raw)
        if text.count > maxTitle { text = String(text.prefix(maxTitle)) + "…" }
        return text.isEmpty ? nil : text
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    /// The host and path, for an entry with no title.
    static func fallbackTitle(for url: URL) -> String {
        let host = url.host() ?? ""
        let path = url.path() == "/" ? "" : url.path()
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }

    /// The named entities feeds use most, past the five XML has.
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—",
        "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "copy": "©",
        "reg": "®", "trade": "™", "middot": "·", "bull": "•", "deg": "°", "times": "×", "eacute": "é", "egrave": "è",
        "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß", "ccedil": "ç", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "prime": "′", "Prime": "″", "thinsp": "\u{2009}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}",
    ]

    /// `&amp;`, `&#8217;`, `&#x2019;` and the names in `named`; anything else is left as it is.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";"), let decoded = entity(String(after[..<semi])) {
                result += decoded
                rest = after[after.index(after: semi)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name]
    }

    /// The feed with HTML's entities written as XML can read them, a bare & escaped, and its encoding said as UTF-8.
    /// Nil when it can't be read as text or nothing needed changing.
    static func repairedXML(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+;|#[xX][0-9a-fA-F]+;|[A-Za-z][A-Za-z0-9]{1,10};)?")
        let xml: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
        var out = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[last..<range.lowerBound]
            last = range.upperBound
            guard let nameRange = Range(match.range(at: 1), in: text) else { out += "&amp;"; continue }
            let name = String(text[nameRange].dropLast())
            if name.hasPrefix("#") || xml.contains(name) {
                out += text[range]
            } else if let value = named[name] {
                out += value.unicodeScalars.map { "&#\($0.value);" }.joined()
            } else {
                out += "&amp;" + text[nameRange]
            }
        }
        out += text[last...]
        out = out.replacingOccurrences(of: #"(<\?xml[^>]*encoding=)["'][^"']*["']"#, with: "$1\"UTF-8\"", options: .regularExpression)
        let repaired = Data(out.utf8)
        return repaired == data ? nil : repaired
    }
}

/// The dates feeds write: RFC 822 in RSS, ISO 8601 in Atom and Dublin Core.
nonisolated enum FeedDates {
    private static let rfc822: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz",
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss",
        "EEE, d MMM yyyy",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    private nonisolated(unsafe) static let iso: [ISO8601DateFormatter] = ([
        [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate],
    ] as [ISO8601DateFormatter.Options]).map { options in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    private static let isoWithoutZone: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let lock = NSLock()

    static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // "UT" and a few US zones DateFormatter doesn't read on its own.
        for (zone, offset) in [(" UT", " +0000"), (" Z", " +0000"), (" EDT", " -0400"), (" EST", " -0500"), (" CDT", " -0500"),
                               (" CST", " -0600"), (" MDT", " -0600"), (" MST", " -0700"), (" PDT", " -0700"), (" PST", " -0800")] where text.hasSuffix(zone) {
            text = String(text.dropLast(zone.count)) + offset
        }
        return lock.withLock {
            if text.first?.isNumber == true, text.contains("-") {
                for formatter in iso.dropLast() { if let date = formatter.date(from: text) { return date } }
                if text.count >= 19, let date = isoWithoutZone.date(from: String(text.prefix(19))) { return date }
                if let date = iso.last?.date(from: text) { return date }
            }
            for formatter in rfc822 { if let date = formatter.date(from: text) { return date } }
            return nil
        }
    }
}

/// Finding a site's feed from its page: the `<link rel="alternate">` tags in its HTML.
nonisolated enum FeedDiscovery {
    static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/feed+xml"]

    /// The feeds a page links to, in its order, comment feeds last.
    static func feeds(inHTML html: String, base: URL) -> [URL] {
        let head = String(html.prefix(1_000_000))
        var base = base
        if let tag = tags("base", in: head).first, let href = tag["href"], let url = URL(string: FeedText.decodeEntities(href), relativeTo: base)?.absoluteURL { base = url }
        var feeds: [(url: URL, comments: Bool)] = []
        for tag in tags("link", in: head) {
            let rel = Set((tag["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let type = (tag["type"] ?? "").lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard rel.contains("alternate"), feedTypes.contains(type), let href = tag["href"],
                  let url = FeedText.pageURL(href, base: base), !feeds.contains(where: { $0.url == url }) else { continue }
            let title = (tag["title"] ?? "").lowercased()
            feeds.append((url, title.contains("comment") || url.path().lowercased().contains("/comments/")))
        }
        return feeds.filter { !$0.comments }.map(\.url) + feeds.filter(\.comments).map(\.url)
    }

    /// Whether the start of a response reads like a feed rather than a page.
    static func looksLikeFeed(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return start.contains("<rss") || start.contains("<feed") || start.contains("<rdf:rdf")
    }

    static func looksLikeHTML(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return start.contains("<html") || start.contains("<!doctype html") || start.contains("<head")
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<([a-zA-Z]+)\\b([^>]*)>")
    private static let attributePattern = try! NSRegularExpression(pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

    /// Each `<name …>` tag's attributes, names lowercased.
    private static func tags(_ name: String, in html: String) -> [[String: String]] {
        let range = NSRange(html.startIndex..., in: html)
        return tagPattern.matches(in: html, range: range).compactMap { match in
            guard let tagName = Range(match.range(at: 1), in: html), html[tagName].lowercased() == name,
                  let body = Range(match.range(at: 2), in: html) else { return nil }
            let text = String(html[body])
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let key = Range(attribute.range(at: 1), in: text) else { continue }
                let value = (2...4).lazy.compactMap { Range(attribute.range(at: $0), in: text) }.first.map { String(text[$0]) } ?? ""
                attributes[text[key].lowercased()] = value
            }
            return attributes
        }
    }
}

/// The GitHub lists a live folder can follow, for a GitHub username, through GitHub's public search: open items in
/// public repositories, newest activity first. No sign-in, so nothing private shows.
nonisolated enum GitHubList: String, Codable, CaseIterable, Sendable {
    case pullRequests, issues, reviewRequests, repositoryIssues, repositoryPullRequests

    func query(for user: String) -> String {
        switch self {
        case .pullRequests: "is:pr is:open archived:false author:\(user)"
        case .issues: "is:issue is:open archived:false assignee:\(user)"
        case .reviewRequests: "is:pr is:open archived:false review-requested:\(user)"
        case .repositoryIssues: "is:issue is:open archived:false user:\(user)"
        case .repositoryPullRequests: "is:pr is:open archived:false user:\(user)"
        }
    }

    func url(for user: String, count: Int) -> URL {
        var parts = URLComponents(string: "https://api.github.com/search/issues")!
        parts.queryItems = [URLQueryItem(name: "q", value: query(for: user)), URLQueryItem(name: "sort", value: "updated"),
                            URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "per_page", value: String(min(max(count, 1), 100)))]
        return parts.url!
    }

    /// GitHub usernames: letters, digits and single hyphens, up to 39 characters.
    static func isUsername(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$", options: .regularExpression) != nil
    }

    private struct Results: Decodable {
        struct Item: Decodable {
            var html_url: URL
            var title: String
            var updated_at: String?
        }
        var items: [Item]
    }

    /// The search's answer as feed entries; nil when it isn't one.
    static func entries(_ data: Data) -> [LiveFeed.Entry]? {
        guard let results = try? JSONDecoder().decode(Results.self, from: data) else { return nil }
        return LiveFeedParser.ordered(results.items.compactMap { item in
            guard let url = FeedText.pageURL(item.html_url.absoluteString, base: item.html_url) else { return nil }
            return LiveFeed.Entry(key: url.absoluteString, url: url, title: FeedText.title(item.title) ?? FeedText.fallbackTitle(for: url),
                                  date: item.updated_at.flatMap(FeedDates.parse))
        })
    }
}
