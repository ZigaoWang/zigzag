import Foundation

/// Filling in the rest of an address you've been to as you type it, the way Safari does: "wiki" shows
/// "wiki|pedia.org" with "pedia.org" selected, so Return goes there and typing on replaces it.
enum InlineCompletion {
    /// A site you could mean: where completing it goes, and how much you use it.
    struct Site {
        let url: URL
        var score: Double
    }

    /// What the field shows once completed, and where Return goes.
    struct Match: Equatable {
        let text: String
        let url: URL
    }

    /// Only what could be the start of an address completes: letters, digits, dots, dashes and a port's colon.
    /// A space, a slash or anything else is a search or a path, and is left as typed.
    static func looksLikeHost(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Whether a change took text away rather than adding it: a delete key (or Undo) did it, or a cut took the
    /// completion and left exactly what you'd typed. The text alone can't tell: "h" typed over a whole selected
    /// "https://…" looks like deleting all but its first letter. Taking away never completes, or the completion you
    /// just deleted would come straight back.
    static func isDeletion(_ text: String, shown: String, typed: String, deleting: Bool) -> Bool {
        deleting || (text == typed && shown != typed)
    }

    /// Whether the field may complete what's in it now: typing forward at the very end, nothing being composed in
    /// an input method, and the text the start of an address.
    static func allowed(_ text: String, shown: String, typed: String, deleting: Bool, caretAtEnd: Bool, hasMarkedText: Bool) -> Bool {
        caretAtEnd && !hasMarkedText && looksLikeHost(text) && !isDeletion(text, shown: shown, typed: typed, deleting: deleting)
    }

    /// The address as it completes: host, its port, and the path when there is one, with no "www." and no trailing slash.
    static func address(_ url: URL) -> String {
        var text = HistoryStore.normalizedHost(url)
        if let port = url.port { text += ":\(port)" }
        let path = url.path(percentEncoded: true)
        if path.count > 1 { text += path.hasSuffix("/") ? String(path.dropLast()) : path }
        return text
    }

    /// Where completing a page goes: the page itself when you go to it more than anywhere else on its site, otherwise
    /// the site's front. A page with a query or a fragment (a search, a place in a document) only gives its site.
    static func target(_ url: URL, wholePage: Bool) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        if wholePage, url.query == nil, url.fragment == nil, url.path.count > 1 { parts.percentEncodedPath = url.path(percentEncoded: true) }
        return parts.url
    }

    /// A host with its leading subdomains dropped, one at a time, down to the site itself: en.wikipedia.org gives
    /// wikipedia.org, a.b.example.co.uk gives b.example.co.uk and example.co.uk. Never past the site to a public
    /// suffix ("co.uk"), and nothing for an address or a name that has no site, like localhost.
    static func shortenedHosts(_ host: String) -> [String] {
        guard let site = PublicSuffix.registrableDomain(host), site != host, host.hasSuffix("." + site) else { return [] }
        var labels = host.split(separator: ".").map(String.init)
        var hosts: [String] = []
        while labels.count > site.split(separator: ".").count {
            labels.removeFirst()
            hosts.append(labels.joined(separator: "."))
        }
        return hosts
    }

    /// The best site whose host starts with what you typed, with or without "www.", or failing that whose host does
    /// without its subdomains: "wiki" finds en.wikipedia.org as wikipedia.org. The most used wins; on a tie the
    /// shorter address, so "git" means github.com before gist.github.com.
    static func best(for typed: String, among sites: [Site]) -> Match? {
        let lower = typed.lowercased()
        let www = lower.hasPrefix("www.")
        let bare = www ? String(lower.dropFirst(4)) : lower
        guard !bare.isEmpty, looksLikeHost(lower) else { return nil }
        // A whole host that matches always beats one only matched once shortened.
        var best: (site: Site, address: String, whole: Bool)?
        // A host you've been to, typed out in full, is where you mean to go: it isn't stretched to a page there or
        // to a longer host (192.168.1.1 to 192.168.1.10).
        var exact: Site?
        func consider(_ site: Site, _ address: String, whole: Bool) {
            if let current = best {
                if current.whole && !whole { return }
                if current.whole == whole {
                    if site.score < current.site.score { return }
                    if site.score == current.site.score, (address.count, address) >= (current.address.count, current.address) { return }
                }
            }
            best = (site, address, whole)
        }
        for site in sites {
            let address = address(site.url)
            // The host (and port) alone has to start with what you typed; a path never does.
            let host = String(address.prefix { $0 != "/" })
            if host == bare, exact.map({ site.score > $0.score }) ?? true { exact = site }
            if host.hasPrefix(bare) {
                consider(site, address, whole: true)
            } else if let short = shortenedHosts(HistoryStore.normalizedHost(site.url)).last(where: { $0.hasPrefix(bare) }) {
                // Shown and opened as the shorter host itself, on the scheme and port it was visited with; the site
                // sends you on from there as it likes.
                var parts = URLComponents()
                parts.scheme = site.url.scheme?.lowercased() ?? "https"
                parts.host = (www ? "www." : "") + short
                parts.port = site.url.port
                guard let url = parts.url else { continue }
                consider(Site(url: url, score: site.score), short + (site.url.port.map { ":\($0)" } ?? ""), whole: false)
            }
        }
        if let exact, let front = target(exact.url, wholePage: false) {
            return Match(text: (www ? "www." : "") + bare, url: front)
        }
        guard let best else { return nil }
        return Match(text: (www ? "www." : "") + best.address, url: best.site.url)
    }

    /// A completion still showing after one more letter: kept while what you've typed is still its beginning.
    static func kept(_ match: Match, typed: String) -> Match? {
        match.text.lowercased().hasPrefix(typed.lowercased()) ? match : nil
    }

    /// What completes after one more letter: what you've typed when it's a whole host you've been to, otherwise the
    /// completion already showing while it still agrees, otherwise what was looked up.
    static func next(previous: Match?, found: Match?, typed: String) -> Match? {
        if let found, found.text.count == typed.count { return found }
        return previous.flatMap { kept($0, typed: typed) } ?? found
    }

    /// Sites gathered from several places, one per host and port: scores add up, and a page from history wins
    /// over a site's front from a tab or a bookmark.
    static func merge(_ sites: [Site]) -> [Site] {
        var merged: [String: Site] = [:]
        var order: [String] = []
        for site in sites {
            let key = String(address(site.url).prefix { $0 != "/" })
            if let existing = merged[key] {
                let url = address(existing.url).count >= address(site.url).count ? existing.url : site.url
                merged[key] = Site(url: url, score: existing.score + site.score)
            } else {
                merged[key] = site
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
