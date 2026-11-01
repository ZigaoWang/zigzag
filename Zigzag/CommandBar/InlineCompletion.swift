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

    /// Whether a change took text away rather than adding it: backspace, forward delete or cut leave a beginning of
    /// what was there and no more than you'd typed. Taking away never completes, or the completion you just
    /// deleted would come straight back.
    static func isDeletion(_ text: String, shown: String, typed: String) -> Bool {
        text.utf16.count <= typed.utf16.count && shown.hasPrefix(text)
    }

    /// Whether the field may complete what's in it now: typing forward at the very end, nothing being composed in
    /// an input method, and the text the start of an address.
    static func allowed(_ text: String, shown: String, typed: String, caretAtEnd: Bool, hasMarkedText: Bool) -> Bool {
        caretAtEnd && !hasMarkedText && looksLikeHost(text) && !isDeletion(text, shown: shown, typed: typed)
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

    /// The best site whose host starts with what you typed, with or without "www.". The most used wins; on a tie the
    /// shorter address, so "git" means github.com before gist.github.com.
    static func best(for typed: String, among sites: [Site]) -> Match? {
        let lower = typed.lowercased()
        let www = lower.hasPrefix("www.")
        let bare = www ? String(lower.dropFirst(4)) : lower
        guard !bare.isEmpty, looksLikeHost(lower) else { return nil }
        var best: (site: Site, address: String)?
        for site in sites {
            let address = address(site.url)
            // The host (and port) alone has to start with what you typed; a path never does.
            let host = String(address.prefix { $0 != "/" })
            guard host.hasPrefix(bare) else { continue }
            if let current = best {
                if site.score < current.site.score { continue }
                if site.score == current.site.score, (address.count, address) >= (current.address.count, current.address) { continue }
            }
            best = (site, address)
        }
        guard let best else { return nil }
        return Match(text: (www ? "www." : "") + best.address, url: best.site.url)
    }

    /// A completion still showing after one more letter: kept while what you've typed is still its beginning.
    static func kept(_ match: Match, typed: String) -> Match? {
        match.text.lowercased().hasPrefix(typed.lowercased()) ? match : nil
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
