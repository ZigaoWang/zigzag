import Foundation

/// Dark Reader's site fixes (#134): `darkreader-fixes.config`, its repository's `dynamic-theme-fixes.config` as it is
/// (scripts/update-darkreader.sh), read the way Dark Reader reads it. Each block names the addresses it's for, then what
/// it changes there: parts to invert, CSS of its own, parts whose inline style or pictures aren't looked at. A page gets
/// the one for every address (`*`) with every block matching it after, as one, which is what Dark Reader's `enable`
/// takes.
nonisolated enum DarkReaderFixes {
    struct Fix: Equatable {
        var url: [String] = []
        var invert: [String] = []
        var css = ""
        var ignoreInlineStyle: [String] = []
        var ignoreImageAnalysis: [String] = []
        var ignoreCSSUrl: [String] = []

        /// As Dark Reader's `enable` takes it.
        var json: [String: Any] {
            ["invert": invert, "css": css, "ignoreInlineStyle": ignoreInlineStyle, "ignoreImageAnalysis": ignoreImageAnalysis,
             "ignoreCSSUrl": ignoreCSSUrl]
        }
    }

    // MARK: Reading the file

    /// A line naming what follows: "INVERT", "IGNORE INLINE STYLE" (up to three capitalized words).
    private static func isCommand(_ line: Substring) -> Bool {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        return (1...3).contains(words.count) && words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "A" && $0 <= "Z" } }
    }

    private static func lines(_ text: some StringProtocol) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The blocks, in the file's order. Blocks are split by a line of "=" (two or more); a block with nothing for it
    /// to do is left out.
    static func parse(_ text: String) -> [Fix] {
        var fixes: [Fix] = []
        var block: [Substring] = []
        func finish() {
            defer { block = [] }
            guard let first = block.firstIndex(where: isCommand) else { return }
            var fix = Fix(url: lines(block[..<first].joined(separator: "\n")))
            var at = first
            while at < block.count {
                let command = block[at].trimmingCharacters(in: .whitespaces)
                let next = block[(at + 1)...].firstIndex(where: isCommand) ?? block.count
                let value = block[(at + 1)..<next].joined(separator: "\n")
                switch command {
                case "INVERT": fix.invert = lines(value)
                case "CSS": fix.css = value.trimmingCharacters(in: .whitespacesAndNewlines)
                case "IGNORE INLINE STYLE": fix.ignoreInlineStyle = lines(value)
                case "IGNORE IMAGE ANALYSIS": fix.ignoreImageAnalysis = lines(value)
                case "IGNORE CSS URL": fix.ignoreCSSUrl = lines(value)
                default: break
                }
                at = next
            }
            fixes.append(fix)
        }
        for line in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) { finish() } else { block.append(line) }
        }
        finish()
        return fixes
    }

    // MARK: Addresses

    /// An address as a pattern is matched against: its host's labels last first, its path's parts.
    struct Prepared: Equatable {
        var hostParts: [String]
        var pathParts: [String]
        var port: String
        var scheme: String
    }

    static func prepare(_ url: URL) -> Prepared? {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return nil }
        var path = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if path.last?.isEmpty == true { path.removeLast() }
        return Prepared(hostParts: host.split(separator: ".", omittingEmptySubsequences: false).reversed().map(String.init),
                        pathParts: path, port: url.port.map(String.init) ?? "", scheme: scheme + ":")
    }

    struct Pattern {
        var regex: NSRegularExpression?
        var hostParts: [String] = []
        var pathParts: [String] = []
        var port = "*"
        var scheme = ""
        var exactStart = false
        var exactEnd = false
    }

    /// Dark Reader's patterns: "example.com" (and its www), "*.example.com", "example.com/path", "^" and "$" for an exact
    /// start or end, a scheme or port if given, or a regular expression between slashes.
    static func pattern(_ text: String) -> Pattern? {
        guard !text.isEmpty else { return nil }
        if text.count > 2, text.hasPrefix("/"), text.hasSuffix("/") {
            return Pattern(regex: try? NSRegularExpression(pattern: String(text.dropFirst().dropLast())))
        }
        var p = Pattern()
        var rest = text
        if rest.hasPrefix("^") { p.exactStart = true; rest.removeFirst() }
        if rest.hasSuffix("$") { p.exactEnd = true; rest.removeLast() }
        if let range = rest.range(of: "://"), range.lowerBound > rest.startIndex {
            p.scheme = String(rest[..<range.lowerBound]) + ":"
            rest = String(rest[range.upperBound...])
        }
        let slash = rest.firstIndex(of: "/")
        let host = slash.map { String(rest[..<$0]) } ?? rest
        var hostName = host
        if let colon = host.lastIndex(of: ":"), !host.hasPrefix("[") || host.lastIndex(of: "]").map({ $0 < colon }) == true {
            hostName = String(host[..<colon])
            p.port = String(host[host.index(after: colon)...])
        }
        p.hostParts = hostName.split(separator: ".", omittingEmptySubsequences: false).reversed().map(String.init)
        let path = slash.map { String(rest[rest.index(after: $0)...]) } ?? ""
        p.pathParts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if p.pathParts.last?.isEmpty == true { p.pathParts.removeLast() }
        return p
    }

    static func matches(_ u: Prepared, _ p: Pattern, address: String) -> Bool {
        if let regex = p.regex {
            return regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
        guard p.hostParts.count <= u.hostParts.count, !(p.exactStart && p.hostParts.count != u.hostParts.count),
              !(p.exactEnd && p.pathParts.count != u.pathParts.count), p.port == "*" || p.port == u.port,
              p.scheme.isEmpty || p.scheme == u.scheme else { return false }
        for (i, part) in p.hostParts.enumerated() where part != "*" && part != u.hostParts[i] { return false }
        // "example.com" covers www.example.com, not other subdomains; "*.example.com" covers them.
        if p.hostParts.count >= 2, p.hostParts.last != "*",
           p.hostParts.count < u.hostParts.count - 1 || (p.hostParts.count == u.hostParts.count - 1 && u.hostParts.last != "www") {
            return false
        }
        if p.pathParts.isEmpty { return true }
        guard p.pathParts.count <= u.pathParts.count else { return false }
        for (i, part) in p.pathParts.enumerated() where part != "*" && part != u.pathParts[i] { return false }
        return true
    }

    static func matches(_ url: URL, _ pattern: String) -> Bool {
        guard let u = prepare(url), let p = Self.pattern(pattern) else { return false }
        return matches(u, p, address: url.absoluteString)
    }

    // MARK: A page's fix

    private struct Entry { var fix: Fix; var patterns: [Pattern] }

    /// The file, read once.
    private static let entries: [Entry] = {
        let text = Bundle.main.url(forResource: "darkreader-fixes", withExtension: "config").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return parse(text).map { Entry(fix: $0, patterns: $0.url.compactMap(pattern)) }
    }()

    /// The fixes in `entries` for an address: the one for every address first, then every block matching it.
    static func fixes(for url: URL?, in list: [Fix]) -> [Fix] {
        select(url, list.map { Entry(fix: $0, patterns: $0.url.compactMap(pattern)) })
    }

    private static func select(_ url: URL?, _ list: [Entry]) -> [Fix] {
        let common = list.filter { $0.fix.url.first == "*" }.map(\.fix)
        guard let url, let u = prepare(url) else { return common }
        let address = url.absoluteString
        let site = list.filter { $0.fix.url.first != "*" && $0.patterns.contains { matches(u, $0, address: address) } }.map(\.fix)
        return common + site
    }

    /// Several fixes as one, as Dark Reader puts them together.
    static func combined(_ fixes: [Fix]) -> Fix {
        var out = Fix()
        for fix in fixes {
            out.invert += fix.invert
            if !fix.css.isEmpty { out.css += (out.css.isEmpty ? "" : "\n") + fix.css }
            out.ignoreInlineStyle += fix.ignoreInlineStyle
            out.ignoreImageAnalysis += fix.ignoreImageAnalysis
            out.ignoreCSSUrl += fix.ignoreCSSUrl
        }
        return out
    }

    /// What a page at `url` is given: the fix for every address, with the site's own if it has one. Nil `url` (a frame,
    /// whose address isn't known yet), the one for every address alone.
    static func fix(for url: URL?) -> Fix { combined(select(url, entries)) }
}
