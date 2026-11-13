import Foundation
import WebKit

/// Sites that asked to be reached only over a secure connection (HTTP Strict Transport Security, RFC 6797). A
/// certificate warning for one of them has no "Visit anyway", as in Chrome and Safari: the site said a connection that
/// can't be trusted must never be used.
///
/// WebKit enforces HSTS itself but doesn't say which hosts it knows, nor does a failed load say whether its host is one.
/// So Zigzag keeps its own list: the whole top-level domains that are HSTS by rule (.app, .dev, .bank and the like,
/// preloaded in every browser), and the hosts that sent the header over a trusted connection, per website data store,
/// until Zigzag quits or the header's max-age runs out. A host remembered only by WebKit from an earlier session, or
/// on the browsers' preload list one by one, isn't known here.
@MainActor enum StrictTransport {
    /// Top-level domains preloaded as HSTS whole, subdomains included, in Chromium's list (which Safari and Firefox
    /// share): every site under them is https only.
    static let preloadedTopLevelDomains: Set<String> = [
        "android", "app", "bank", "boo", "chrome", "dad", "day", "dev", "eat", "esq", "fly", "foo", "gle", "gmail",
        "google", "hangout", "ing", "insurance", "meet", "meme", "mov", "new", "nexus", "page", "phd", "prof", "rsvp",
        "search", "youtube", "zip",
    ]

    /// What a Strict-Transport-Security header says, or nil when it isn't a valid one.
    struct Policy: Equatable {
        var maxAge: TimeInterval
        var includesSubdomains: Bool
    }

    /// Reads a Strict-Transport-Security header: `max-age` is required, once; `includeSubDomains` is optional;
    /// unknown directives are passed over, as RFC 6797 says. A repeated directive makes the header invalid.
    nonisolated static func parse(_ header: String) -> Policy? {
        var maxAge: TimeInterval?
        var subdomains = false
        var seen: Set<String> = []
        for part in header.split(separator: ";", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { return nil }
            var value = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch name {
            case "max-age":
                guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) else { return nil }
                // Very large ages are held to a year past what any site asks, never overflowing a date.
                maxAge = TimeInterval(UInt64(value.prefix(12)) ?? 0)
            case "includesubdomains":
                subdomains = true
            default:
                continue
            }
        }
        guard let maxAge else { return nil }
        return Policy(maxAge: min(maxAge, 2 * 365 * 24 * 60 * 60), includesSubdomains: subdomains)
    }

    private final class Entry {
        let until: Date
        let includesSubdomains: Bool
        init(until: Date, includesSubdomains: Bool) { self.until = until; self.includesSubdomains = includesSubdomains }
    }

    /// Per data store, the hosts that sent the header: a private window's stay in it and go with it.
    private static let known = NSMapTable<WKWebsiteDataStore, NSMutableDictionary>.weakToStrongObjects()

    /// Takes note of a response's Strict-Transport-Security header. Only over https, and never over a connection
    /// let through on the warning page: the RFC has it ignored there, so a site can't be pinned by an impostor.
    static func note(_ response: URLResponse, in store: WKWebsiteDataStore, now: Date = Date()) {
        guard let http = response as? HTTPURLResponse, let url = http.url, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), !host.isEmpty, !isAddress(host),
              let header = http.value(forHTTPHeaderField: "Strict-Transport-Security"), let policy = parse(header),
              !CertificateExceptions.hasException(for: host, in: store, now: now) else { return }
        note(host, policy: policy, in: store, now: now)
    }

    static func note(_ host: String, policy: Policy, in store: WKWebsiteDataStore, now: Date = Date()) {
        let host = host.lowercased()
        let hosts = known.object(forKey: store) ?? NSMutableDictionary()
        // max-age=0 is the site taking it back.
        if policy.maxAge <= 0 {
            hosts.removeObject(forKey: host)
        } else {
            hosts[host] = Entry(until: now.addingTimeInterval(policy.maxAge), includesSubdomains: policy.includesSubdomains)
        }
        known.setObject(hosts, forKey: store)
    }

    /// Whether `host` is to be reached only securely in `store`: its top-level domain is HSTS whole, or it or a
    /// domain over it that covers its subdomains sent the header.
    static func isKnown(_ host: String, in store: WKWebsiteDataStore?, now: Date = Date()) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        let labels = host.split(separator: ".").map(String.init)
        if let last = labels.last, preloadedTopLevelDomains.contains(last) { return true }
        guard let store, let hosts = known.object(forKey: store) else { return false }
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            guard let entry = hosts[candidate] as? Entry, now < entry.until else { continue }
            if start == labels.startIndex || entry.includesSubdomains { return true }
        }
        return false
    }

    /// The hosts noted for `store` go (its site data was cleared).
    static func forget(in store: WKWebsiteDataStore) {
        known.removeObject(forKey: store)
    }

    /// An IP address is never HSTS: the header is ignored for one.
    nonisolated private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
