import Foundation
import WebKit

/// The dark palettes dark pages made for light sites (#134), one per site and kind of background (dark gray or Pure
/// black): a style sheet of the site's own colors turned dark, made by the page script the first time the site was
/// seen, so later visits are drawn with it from the first frame instead of through the invert filter.
///
/// Kept for each profile, in its folder, and never for a private window. It's a list of sites you've been to, so it
/// goes with them: clearing a site's cache or cookies takes its palette, clearing all of either or all of History
/// takes them all, and clearing History since a time takes the ones made since. Each file is named after its site, so
/// clearing one site never has to read the others. The sites seen dark on their own (`DarkSeen`) are kept beside them
/// and go with them.
@MainActor
enum DarkPalettes {
    struct Entry: Codable, Equatable {
        /// "https://example.com", as the page's own `location.origin`.
        var origin: String
        var black: Bool
        /// What the site's style was made of when it was read (`fingerprint` in dark-palette.js), the last few: a site
        /// whose pages load different sheets has several, and its palette has what each page needed.
        var fingerprints: [String]
        /// The style sheet, rule by rule.
        var rules: [String]
        /// The palette left too much of the page light, or there was nothing to make one from: the filter instead,
        /// until the site's style changes.
        var invert: Bool
        /// It's been drawn once since it last changed, and that looked right (or didn't, and `invert` says so).
        var verified: Bool
        /// Counts up each time it changes, so a web view given an older one gets the new one.
        var revision: Int
        /// A dark site's fill (#134): its light surfaces alone made dark, and the ink on them light, rather than a
        /// light site's whole palette. Nil in files written before there were any.
        var fill: Bool?

        var isFill: Bool { fill == true }

        var css: String { rules.joined(separator: "\n") }
    }

    static let maxFingerprints = 6
    /// Past this, a site's palette is the latest page's alone rather than every page's together.
    static let maxBytes = 768 * 1024
    static let maxRules = 40_000
    /// Sites kept for each profile: the ones least recently made go first.
    static let maxSites = 400

    // MARK: Merging

    /// The palette after a page of the site was read: the rules it needed join the ones other pages needed (the newest
    /// last, so they win), unless that grows too big or the old one wasn't any good.
    static func merged(_ old: Entry?, origin: String, black: Bool, fingerprint: String, rules: [String], invert: Bool, fill: Bool = false) -> Entry {
        var prints = (old?.fingerprints ?? []).filter { $0 != fingerprint } + [fingerprint]
        if prints.count > maxFingerprints { prints.removeFirst(prints.count - maxFingerprints) }
        let fresh = Array(rules.prefix(maxRules))
        // Too big to put in every page of the site as it starts: the filter instead.
        let invert = invert || fresh.reduce(0, { $0 + $1.utf8.count + 1 }) > maxBytes
        var kept = fresh
        if let old, !old.invert, !invert {
            let new = Set(fresh)
            let together = old.rules.filter { !new.contains($0) } + fresh
            if together.count <= maxRules, together.reduce(0, { $0 + $1.utf8.count + 1 }) <= maxBytes { kept = together }
        }
        if invert { kept = [] }
        // A fill is used as soon as it's made: there's nothing to check it against, the page being dark already.
        return Entry(origin: origin, black: black, fingerprints: prints, rules: kept, invert: invert, verified: fill,
                     revision: (old?.revision ?? 0) + 1, fill: fill ? true : nil)
    }

    /// The palette after it was drawn: kept if it covered the page, the filter instead if it didn't. Only for the
    /// style it was made from.
    static func verified(_ old: Entry, fingerprint: String, ok: Bool) -> Entry {
        guard old.fingerprints.contains(fingerprint), !old.verified || !ok else { return old }
        var entry = old
        entry.verified = true
        if !ok { entry.invert = true; entry.rules = [] }
        entry.revision += 1
        return entry
    }

    // MARK: Where they're kept

    /// A page's site as the page script names it: scheme, host and a port that isn't the usual one.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let shown = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { return "\(scheme)://\(shown):\(port)" }
        return "\(scheme)://\(shown)"
    }

    /// The site of an origin, without "www.", to match a site being cleared.
    static func site(ofOrigin origin: String) -> String? { URL(string: origin).flatMap(DarkPages.site(of:)) }

    /// The file a site's palette is kept in: its origin, spelled to be a file name, and which background it's for.
    static func fileName(origin: String, black: Bool, fill: Bool = false) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return (fill ? "fill-" : "") + (black ? "black " : "dark ") + (origin.addingPercentEncoding(withAllowedCharacters: allowed) ?? "site") + ".json"
    }

    /// The origin a file is for, from its name.
    static func origin(ofFile name: String) -> String? {
        guard name.hasSuffix(".json"), let space = name.firstIndex(of: " ") else { return nil }
        return String(name[name.index(after: space)..<name.index(name.endIndex, offsetBy: -5)]).removingPercentEncoding
    }

    /// The profile scope (`DarkPages.nativeScope`) of a profile.
    nonisolated static func scope(ofProfile id: UUID) -> String { id == Profile.defaultID ? "default" : id.uuidString }

    /// A profile's folder for them. Tests never use a real profile's: they get one of their own.
    static var folder: (String) -> URL? = { scope in
        let name = "Dark Pages"
        if AppDelegate.isHostingTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagTests-DarkPalettes-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent(scope).appendingPathComponent(name)
        }
        if scope == "default" { return Paths.support.appendingPathComponent(name, isDirectory: true) }
        guard let id = UUID(uuidString: scope) else { return nil }
        return Profiles.folder(of: id).appendingPathComponent(name, isDirectory: true)
    }

    /// Each profile's files by name (read once), and the entries read from them so far (nil: read, and not usable).
    private static var names: [String: Set<String>] = [:]
    private static var entries: [String: [String: Entry?]] = [:]
    /// Where their files are written and removed, in order; the sites seen dark (`DarkSeen`) share it.
    static let disk = DispatchQueue(label: "app.zigzag.dark-palettes", qos: .utility)

    private static func listing(_ scope: String) -> Set<String> {
        if let known = names[scope] { return known }
        let found = folder(scope).flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }.map { Set($0.filter { $0.hasSuffix(".json") }) } ?? []
        names[scope] = found
        return found
    }

    /// A site's palette in a profile, if one was made; nil for a private window (`scope` nil).
    static func entry(origin: String?, black: Bool, scope: String?, fill: Bool = false) -> Entry? {
        guard let scope, let origin else { return nil }
        let name = fileName(origin: origin, black: black, fill: fill)
        if let known = entries[scope]?[name] { return known }
        guard listing(scope).contains(name), let url = folder(scope)?.appendingPathComponent(name) else { return nil }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        let usable = read?.origin == origin && read?.black == black && read?.isFill == fill ? read : nil
        entries[scope, default: [:]][name] = .some(usable)
        return usable
    }

    /// Keeps a site's palette in a profile, written to disk off the main thread.
    static func store(_ entry: Entry, scope: String) {
        let name = fileName(origin: entry.origin, black: entry.black, fill: entry.isFill)
        entries[scope, default: [:]][name] = .some(entry)
        var listed = listing(scope)
        listed.insert(name)
        names[scope] = listed
        guard let dir = folder(scope), let data = try? JSONEncoder().encode(entry) else { return }
        let limit = maxSites
        disk.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            prune(dir, keeping: limit)
        }
    }

    /// The oldest made go once there are more than `keeping`.
    nonisolated private static func prune(_ dir: URL, keeping: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        // Palettes alone: the sites seen dark (`DarkSeen`) keep their own count.
        guard let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys))?.filter({ $0.pathExtension == "json" }),
              files.count > keeping else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keeping) { try? FileManager.default.removeItem(at: file) }
        let left = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []))
        DispatchQueue.main.async { MainActor.assumeIsolated { forgetGone(dir, left: left) } }
    }

    private static func forgetGone(_ dir: URL, left: Set<String>) {
        for (scope, listed) in names where folder(scope) == dir {
            names[scope] = listed.intersection(left)
            entries[scope] = entries[scope]?.filter { left.contains($0.key) }
        }
    }

    // MARK: Forgetting

    /// Takes a profile's palettes away: one site's (covering its subdomains), the ones made since a time, or all.
    /// Pages open there keep theirs until they next load.
    static func forget(scope: String, site: String? = nil, since: Date? = nil) {
        // The sites seen dark go the same way, kept beside them.
        DarkSeen.forget(scope: scope, site: site, since: since)
        DarkPages.palettesForgotten()
        guard let dir = folder(scope) else { return }
        let listed = listing(scope)
        let matching: Set<String>
        if let site {
            matching = listed.filter { name in
                guard let origin = origin(ofFile: name), let theirs = self.site(ofOrigin: origin) else { return false }
                return theirs == site || theirs.hasSuffix("." + site) || site.hasSuffix("." + theirs)
            }
        } else if let since {
            matching = listed.filter { name in
                let date = (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (date ?? .distantFuture) >= since
            }
        } else {
            matching = listed
        }
        guard !matching.isEmpty || (site == nil && since == nil) else { return }
        names[scope] = site == nil && since == nil ? [] : listed.subtracting(matching)
        if site == nil && since == nil { entries[scope] = [:] } else { entries[scope] = entries[scope]?.filter { !matching.contains($0.key) } }
        let all = site == nil && since == nil
        disk.async {
            if all { try? FileManager.default.removeItem(at: dir); return }
            for name in matching { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }

    /// The same for a website data store: a private window's has none.
    static func forget(in store: WKWebsiteDataStore, site: String? = nil) {
        guard let scope = DarkPages.nativeScope(of: store) else { return }
        forget(scope: scope, site: site)
    }

    /// Waits for the files to be written or removed (tests).
    static func settle() { disk.sync {} }

    /// Forgets what's been read, so the next look reads the folder again (tests).
    static func reload() { names = [:]; entries = [:]; DarkSeen.reload() }

    // MARK: Fetching sheets

    /// Whether a sheet the page can't read itself may be fetched for it: only from the web, never local or private
    /// addresses the page didn't reach the same way.
    static func fetchable(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
        // A literal address on this Mac's networks.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1])) { return false }
        }
        if host.contains(":") { return false }
        return true
    }

    nonisolated static let maxSheetBytes = 3 * 1024 * 1024

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// A style sheet's text, or nil: not CSS, too big, or not there.
    nonisolated static func fetchSheet(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("text/css,*/*;q=0.1", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count <= maxSheetBytes else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard type.isEmpty || type.contains("css") || type.contains("text/plain") else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
