import Foundation
import WebKit

/// HSTS hosts (RFC 6797). Their certificate warnings have no "Visit anyway", as in Chrome and Safari. WebKit enforces
/// HSTS but doesn't expose which hosts it knows, so Zigzag keeps its own list: the shared browser preload list
/// (Chromium's, bundled as `hsts_preload.txt`) plus hosts that sent the header over a trusted connection, per data
/// store. A profile's persist until max-age runs out or site data is cleared; a private window's stay in memory.
@MainActor enum StrictTransport {
    /// One name per line, byte-sorted: a name covering its subdomains, or `=name` for itself only. Memory-mapped and
    /// searched in place, so 95,000 names cost almost nothing; a lookup touches a few dozen lines.
    nonisolated private static let preload: Data = {
        guard let url = Bundle.main.url(forResource: "hsts_preload", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return Data() }
        return data
    }()

    nonisolated static var isPreloadLoaded: Bool { !preload.isEmpty }

    /// The host itself, or a parent that covers subdomains.
    nonisolated static func isPreloaded(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !isAddress(host) else { return false }
        if listed("=" + host) { return true }
        let labels = host.split(separator: ".")
        for start in labels.indices where listed(labels[start...].joined(separator: ".")) { return true }
        return false
    }

    /// Binary search over the bytes, snapping each probe to the start of its line.
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

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var until: Date
        var includesSubdomains: Bool
    }

    /// Hosts that sent the header in one store. A profile's file is read on the disk queue so the first response
    /// never waits; notes made meanwhile win over the file.
    private final class Hosts {
        var entries: [String: Entry] = [:]
        /// Nil for a private window's, which is never written.
        let url: URL?
        /// The file's contents once read, until merged.
        let read = ReadBox()
        var isComplete: Bool
        /// Writes are coalesced so many responses make one.
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

    /// Per data store; a private window's go with it.
    private static let known = NSMapTable<WKWebsiteDataStore, Hosts>.weakToStrongObjects()
    /// Lists with a pending write, flushed on quit (or when a test waits).
    private static var unsaved: [ObjectIdentifier: Hosts] = [:]

    static let fileName = "Strict Transport.plist"
    /// Per profile; the soonest to expire are dropped first.
    static let maxHosts = 5000
    /// Serializes reads, writes and removals.
    static let disk = DispatchQueue(label: "app.zigzag.strict-transport", qos: .utility)
    /// Coalescing delay before a write.
    static let saveDelay: TimeInterval = 2

    /// A profile's file (`DarkPages.nativeScope`). Tests get their own.
    static var file: (String) -> URL? = { scope in
        if AppDelegate.isHostingTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagTests-StrictTransport-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent(scope).appendingPathComponent(fileName)
        }
        if scope == "default" { return Paths.support.appendingPathComponent(fileName) }
        guard let id = UUID(uuidString: scope) else { return nil }
        return Profiles.folder(of: id).appendingPathComponent(fileName)
    }

    /// Starts reading the profile's file on first use.
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

    /// Merges the file's list once read; newer notes win.
    private static func takeIn(_ hosts: Hosts) {
        guard !hosts.isComplete, let read = hosts.read.take() else { return }
        hosts.entries = read.merging(hosts.entries) { _, noted in noted }
        hosts.isComplete = true
    }

    /// Waits for the file if it's still being read (for a certificate warning).
    private static func completeHosts(in store: WKWebsiteDataStore) -> Hosts {
        let hosts = hosts(in: store)
        if !hosts.isComplete {
            disk.sync {}
            takeIn(hosts)
        }
        return hosts
    }

    /// Writes a profile's list after `saveDelay`, off the main thread; private windows are never written.
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
        // Never overwrite before the file has been read.
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

    /// Flushes pending writes (on quit).
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
              !CertificateExceptions.hasException(for: host, port: url.port ?? 443, in: store, now: now) else { return }
        note(host, policy: policy, in: store, now: now)
    }

    static func note(_ host: String, policy: Policy, in store: WKWebsiteDataStore, now: Date = Date()) {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return }
        // Removing a host needs the file merged first, or the file would bring it back.
        let hosts = policy.maxAge <= 0 ? completeHosts(in: store) : hosts(in: store)
        let old = hosts.entries[host]
        // max-age=0 is the site taking it back.
        if policy.maxAge <= 0 {
            guard old != nil else { return }
            hosts.entries[host] = nil
        } else {
            let entry = Entry(until: now.addingTimeInterval(policy.maxAge), includesSubdomains: policy.includesSubdomains)
            // Every page of the site sends the same header; skip writing an unchanged entry.
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

    /// On the preload list, or the host or a subdomain-covering parent sent the header.
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

    /// Clears noted hosts after site data is cleared: all, or one site's (its subdomains and parent domains). The
    /// preload list stays.
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

    /// Flushes and waits (tests).
    static func settle() { finishWriting() }

    /// Drops what's been read so the next lookup rereads the files (tests).
    static func reload() {
        finishWriting()
        known.removeAllObjects()
    }

    /// An IP address is never HSTS: the header is ignored for one.
    nonisolated private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
