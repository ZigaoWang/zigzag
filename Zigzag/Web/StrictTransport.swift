import Foundation
import WebKit

/// Sites that asked to be reached only over a secure connection (HTTP Strict Transport Security, RFC 6797). A
/// certificate warning for one of them has no "Visit anyway", as in Chrome and Safari: the site said a connection that
/// can't be trusted must never be used.
///
/// WebKit enforces HSTS itself but doesn't say which hosts it knows, nor does a failed load say whether its host is one.
/// So Zigzag keeps its own list: the browsers' preload list (Chromium's, which Safari and Firefox share, bundled as
/// `hsts_preload.txt`), and the hosts that sent the header over a trusted connection, per website data store. A
/// profile's are kept on disk across launches until the header's max-age runs out or its site data is cleared; a
/// private window's stay in memory and go with it.
@MainActor enum StrictTransport {
    /// The preload list: names whose subdomains are covered too, and names covered alone (written `=name`).
    private struct Preload: Sendable {
        var withSubdomains: Set<String> = []
        var alone: Set<String> = []
    }

    nonisolated private static let preload: Preload = {
        var list = Preload()
        guard let url = Bundle.main.url(forResource: "hsts_preload", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return list }
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty || name.hasPrefix("//") { continue }
            if name.hasPrefix("=") { list.alone.insert(String(name.dropFirst())) } else { list.withSubdomains.insert(name) }
        }
        return list
    }()

    /// Whether the preload list is there.
    nonisolated static var isPreloadLoaded: Bool { !preload.withSubdomains.isEmpty }

    /// Whether `host` is on the preload list: itself, or under a name that covers its subdomains.
    nonisolated static func isPreloaded(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        if preload.alone.contains(host) { return true }
        let labels = host.split(separator: ".")
        for start in labels.indices where preload.withSubdomains.contains(labels[start...].joined(separator: ".")) { return true }
        return false
    }

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

    /// One host that sent the header, and until when it holds.
    struct Entry: Codable, Equatable {
        var until: Date
        var includesSubdomains: Bool
    }

    /// One store's hosts that sent the header.
    private final class Hosts {
        var entries: [String: Entry]
        init(_ entries: [String: Entry]) { self.entries = entries }
    }

    /// Per data store: a private window's stay in it and go with it.
    private static let known = NSMapTable<WKWebsiteDataStore, Hosts>.weakToStrongObjects()

    static let fileName = "Strict Transport.plist"
    /// Hosts kept for each profile: the ones that run out first go first.
    static let maxHosts = 5000
    /// Where the lists are written and removed, in order.
    static let disk = DispatchQueue(label: "app.zigzag.strict-transport", qos: .utility)

    /// A profile's file (`DarkPages.nativeScope`). Tests never use a real profile's: they get one of their own.
    static var file: (String) -> URL? = { scope in
        if AppDelegate.isHostingTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagTests-StrictTransport-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent(scope).appendingPathComponent(fileName)
        }
        if scope == "default" { return Paths.support.appendingPathComponent(fileName) }
        guard let id = UUID(uuidString: scope) else { return nil }
        return Profiles.folder(of: id).appendingPathComponent(fileName)
    }

    /// The hosts known in `store`: read from its profile's file the first time.
    private static func hosts(in store: WKWebsiteDataStore, now: Date = Date()) -> Hosts {
        if let hosts = known.object(forKey: store) { return hosts }
        var read: [String: Entry] = [:]
        if let scope = DarkPages.nativeScope(of: store), let url = file(scope), let data = try? Data(contentsOf: url) {
            read = ((try? PropertyListDecoder().decode([String: Entry].self, from: data)) ?? [:]).filter { now < $0.value.until }
        }
        let hosts = Hosts(read)
        known.setObject(hosts, forKey: store)
        return hosts
    }

    /// Writes a profile's list off the main thread; a private window's is never written.
    private static func save(_ hosts: Hosts, of store: WKWebsiteDataStore) {
        guard let scope = DarkPages.nativeScope(of: store), let url = file(scope) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = hosts.entries.isEmpty ? nil : try? encoder.encode(hosts.entries)
        disk.async {
            guard let data else { try? FileManager.default.removeItem(at: url); return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

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
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return }
        let hosts = hosts(in: store, now: now)
        let old = hosts.entries[host]
        // max-age=0 is the site taking it back.
        if policy.maxAge <= 0 {
            guard old != nil else { return }
            hosts.entries[host] = nil
        } else {
            let entry = Entry(until: now.addingTimeInterval(policy.maxAge), includesSubdomains: policy.includesSubdomains)
            // The same answer again a little later (every page of the site sends it) isn't written each time.
            if let old, old.includesSubdomains == entry.includesSubdomains, abs(old.until.timeIntervalSince(entry.until)) < 24 * 60 * 60 { return }
            hosts.entries[host] = entry
            if hosts.entries.count > maxHosts {
                for gone in hosts.entries.sorted(by: { $0.value.until < $1.value.until }).prefix(hosts.entries.count - maxHosts) {
                    hosts.entries[gone.key] = nil
                }
            }
        }
        save(hosts, of: store)
    }

    /// Whether `host` is to be reached only securely in `store`: it's on the preload list, or it or a domain over it
    /// that covers its subdomains sent the header.
    static func isKnown(_ host: String, in store: WKWebsiteDataStore?, now: Date = Date()) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        if isPreloaded(host) { return true }
        guard let store else { return false }
        let entries = hosts(in: store, now: now).entries
        let labels = host.split(separator: ".").map(String.init)
        for start in labels.indices {
            guard let entry = entries[labels[start...].joined(separator: ".")], now < entry.until else { continue }
            if start == labels.startIndex || entry.includesSubdomains { return true }
        }
        return false
    }

    /// The hosts noted for `store` go (its site data was cleared): all of them, or one site's (covering its
    /// subdomains and the domains it's under). The preload list stays.
    static func forget(in store: WKWebsiteDataStore, site: String? = nil) {
        let hosts = hosts(in: store)
        if let site = site?.lowercased() {
            let before = hosts.entries.count
            hosts.entries = hosts.entries.filter { key, _ in !(key == site || key.hasSuffix("." + site) || site.hasSuffix("." + key)) }
            guard hosts.entries.count != before else { return }
        } else {
            hosts.entries = [:]
        }
        save(hosts, of: store)
    }

    /// Waits for the lists to be written (tests).
    static func settle() { disk.sync {} }

    /// Forgets what's been read, so the next look reads the files again (tests).
    static func reload() { known.removeAllObjects() }

    /// An IP address is never HSTS: the header is ignored for one.
    nonisolated private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
