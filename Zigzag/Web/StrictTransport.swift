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
    /// The preload list, one name a line, sorted byte by byte: a name whose subdomains are covered too, or `=name` for
    /// one covered alone. It's searched where it lies in the app, mapped rather than read, so the 95,000 names cost
    /// next to no memory and nothing at launch; a look-up reads a few dozen lines.
    nonisolated private static let preload: Data = {
        guard let url = Bundle.main.url(forResource: "hsts_preload", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Data() }
        return data
    }()

    /// Whether the preload list is there.
    nonisolated static var isPreloadLoaded: Bool { !preload.isEmpty }

    /// Whether `host` is on the preload list: itself, or under a name that covers its subdomains.
    nonisolated static func isPreloaded(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        if listed("=" + host) { return true }
        let labels = host.split(separator: ".")
        for start in labels.indices where listed(labels[start...].joined(separator: ".")) { return true }
        return false
    }

    /// Whether `line` is one of the preload list's lines: a binary search over its bytes, each step moving to the
    /// start of the line it lands in.
    nonisolated static func listed(_ line: String, in list: Data = preload) -> Bool {
        let key = Array(line.utf8)
        guard !key.isEmpty else { return false }
        return list.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var low = 0, high = bytes.count
            while low < high {
                var start = (low + high) / 2
                while start > low && bytes[start - 1] != 0x0A { start -= 1 }
                var end = start
                while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                var order = 0, index = 0
                while order == 0 {
                    let atEnd = start + index >= end, keyDone = index >= key.count
                    if atEnd || keyDone { order = atEnd && keyDone ? 0 : (atEnd ? -1 : 1); break }
                    let a = bytes[start + index], b = key[index]
                    order = a == b ? 0 : (a < b ? -1 : 1)
                    index += 1
                }
                if order == 0 { return true }
                if order < 0 { low = end + 1 } else { high = start }
            }
            return false
        }
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
    nonisolated struct Entry: Codable, Equatable, Sendable {
        var until: Date
        var includesSubdomains: Bool
    }

    /// One store's hosts that sent the header. A profile's file is read on the disk queue, so a page's first response
    /// never waits for it: notes made meanwhile are kept and win over what the file said.
    private final class Hosts {
        var entries: [String: Entry] = [:]
        /// Where the list is kept; nil for a private window's, never written.
        let url: URL?
        /// The file's list, once read, until it's taken in.
        let read = ReadBox()
        var isComplete: Bool
        /// A write is on its way, after a moment, so a page's many responses make one.
        var saveScheduled = false
        init(url: URL?) {
            self.url = url
            isComplete = url == nil
        }
    }

    nonisolated private final class ReadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Entry]?
        func set(_ entries: [String: Entry]) { lock.withLock { value = entries } }
        func take() -> [String: Entry]? { lock.withLock { defer { value = nil }; return value } }
    }

    /// Per data store: a private window's stay in it and go with it.
    private static let known = NSMapTable<WKWebsiteDataStore, Hosts>.weakToStrongObjects()
    /// Lists with a write on its way, to finish at once when Zigzag quits (or a test waits).
    private static var unsaved: [ObjectIdentifier: Hosts] = [:]

    static let fileName = "Strict Transport.plist"
    /// Hosts kept for each profile: the ones that run out first go first.
    static let maxHosts = 5000
    /// Where the lists are read, written and removed, in order.
    static let disk = DispatchQueue(label: "app.zigzag.strict-transport", qos: .utility)
    /// How long a change waits for others before it's written.
    static let saveDelay: TimeInterval = 2

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

    /// The hosts known in `store`: its profile's file starts being read the first time.
    private static func hosts(in store: WKWebsiteDataStore) -> Hosts {
        if let hosts = known.object(forKey: store) {
            takeIn(hosts)
            return hosts
        }
        let hosts = Hosts(url: DarkPages.nativeScope(of: store).flatMap(file))
        known.setObject(hosts, forKey: store)
        if let url = hosts.url {
            let box = hosts.read
            disk.async {
                let data = try? Data(contentsOf: url)
                let read = data.flatMap { try? PropertyListDecoder().decode([String: Entry].self, from: $0) } ?? [:]
                let now = Date()
                box.set(read.filter { now < $0.value.until })
            }
        }
        return hosts
    }

    /// The file's list, if it's been read: what was noted since stays over it.
    private static func takeIn(_ hosts: Hosts) {
        guard !hosts.isComplete, let read = hosts.read.take() else { return }
        hosts.entries = read.merging(hosts.entries) { _, noted in noted }
        hosts.isComplete = true
    }

    /// Everything known in `store`, the file waited for if it's still being read (a certificate warning's answer).
    private static func completeHosts(in store: WKWebsiteDataStore) -> Hosts {
        let hosts = hosts(in: store)
        if !hosts.isComplete {
            disk.sync {}
            takeIn(hosts)
        }
        return hosts
    }

    /// Writes a profile's list a moment from now, off the main thread, with whatever else changed meanwhile; a
    /// private window's is never written.
    private static func save(_ hosts: Hosts) {
        guard hosts.url != nil else { return }
        unsaved[ObjectIdentifier(hosts)] = hosts
        guard !hosts.saveScheduled else { return }
        hosts.saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { MainActor.assumeIsolated { write(hosts) } }
    }

    private static func write(_ hosts: Hosts) {
        hosts.saveScheduled = false
        guard unsaved.removeValue(forKey: ObjectIdentifier(hosts)) != nil, let url = hosts.url else { return }
        // Never written over before the file's own list is in.
        if !hosts.isComplete {
            disk.sync {}
            takeIn(hosts)
        }
        let entries = hosts.entries
        disk.async {
            guard !entries.isEmpty else { try? FileManager.default.removeItem(at: url); return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(entries) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes what's waiting now (Zigzag quitting).
    static func finishWriting() {
        for hosts in Array(unsaved.values) { write(hosts) }
        disk.sync {}
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
        // Taking it back needs the file's list in, or the file would bring it back.
        let hosts = policy.maxAge <= 0 ? completeHosts(in: store) : hosts(in: store)
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
        save(hosts)
    }

    /// Whether `host` is to be reached only securely in `store`: it's on the preload list, or it or a domain over it
    /// that covers its subdomains sent the header.
    static func isKnown(_ host: String, in store: WKWebsiteDataStore?, now: Date = Date()) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        if isPreloaded(host) { return true }
        guard let store else { return false }
        let entries = completeHosts(in: store).entries
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
        let hosts = completeHosts(in: store)
        if let site = site?.lowercased() {
            let before = hosts.entries.count
            hosts.entries = hosts.entries.filter { key, _ in !(key == site || key.hasSuffix("." + site) || site.hasSuffix("." + key)) }
            guard hosts.entries.count != before else { return }
        } else {
            hosts.entries = [:]
        }
        save(hosts)
    }

    /// Writes what's waiting and waits for it (tests).
    static func settle() { finishWriting() }

    /// Forgets what's been read, so the next look reads the files again (tests).
    static func reload() {
        finishWriting()
        known.removeAllObjects()
    }

    /// An IP address is never HSTS: the header is ignored for one.
    nonisolated private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
