import WebKit

/// Sites whose cookies Clear Cookies… and quitting leave alone (#334), one list per profile. A site is a registrable
/// domain without "www.", covering http and https and every subdomain. Chosen in Site Controls or Settings › Privacy;
/// a private window never adds one, and keeps nothing to begin with.
enum KeptCookies {
    /// Where the lists are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// A profile's kept sites changed, from Site Controls or Settings.
    static let changed = Signal<Void>()
    /// A profile's Clear cookies when Zigzag quits changed.
    static let clearingChanged = Signal<UUID>()

    // MARK: Sites

    /// The site a host is kept under: its registrable domain, or the host itself (localhost, an address).
    nonisolated static func site(ofHost host: String) -> String? {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        guard !host.isEmpty, !host.hasPrefix(".") else { return nil }
        return PublicSuffix.registrableDomain(host) ?? host
    }

    /// The site of a web page; nil for anything but http and https.
    nonisolated static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: false) else { return nil }
        return site(ofHost: host)
    }

    /// Add Site… input: a host, an address with a port, or a URL.
    nonisolated static func entry(from text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        return site(of: URL(string: typed.contains("://") ? typed : "https://" + typed))
    }

    /// Whether a website data record (WebKit names them by domain or host) belongs to a kept site.
    nonisolated static func covers(_ kept: Set<String>, record name: String) -> Bool {
        let name = name.lowercased()
        if kept.contains(name) { return true }
        if let site = site(ofHost: name), kept.contains(site) { return true }
        return kept.contains { name.hasSuffix("." + $0) }
    }

    // MARK: The list

    static func sites(in profile: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: ProfileKey.keptCookieSites.name(in: profile)) ?? [])
    }

    static func setSites(_ sites: Set<String>, in profile: UUID) {
        if sites.isEmpty { defaults.removeObject(forKey: ProfileKey.keptCookieSites.name(in: profile)) }
        else { defaults.set(Array(sites).sorted(), forKey: ProfileKey.keptCookieSites.name(in: profile)) }
        changed.send()
    }

    static func keeps(_ url: URL?, in profile: UUID) -> Bool {
        guard let site = site(of: url) else { return false }
        return sites(in: profile).contains(site)
    }

    /// Whether Site Controls offers it: on a web page, never in a private window.
    static func isOffered(for url: URL?, isPrivate: Bool) -> Bool { !isPrivate && site(of: url) != nil }

    /// From Site Controls. A private window's choice is never kept.
    static func set(_ on: Bool, for url: URL?, in profile: UUID, isPrivate: Bool) {
        guard !isPrivate, let site = site(of: url) else { return }
        on ? add(site, in: profile) : remove(site, in: profile)
    }

    static func add(_ site: String, in profile: UUID) {
        var kept = sites(in: profile)
        guard kept.insert(site).inserted else { return }
        setSites(kept, in: profile)
    }

    static func remove(_ site: String, in profile: UUID) {
        var kept = sites(in: profile)
        guard kept.remove(site) != nil else { return }
        setSites(kept, in: profile)
    }

    // MARK: Clearing when Zigzag quits

    /// Off until chosen, per profile.
    static func clearsOnQuit(in profile: UUID) -> Bool {
        defaults.bool(forKey: ProfileKey.clearsCookiesOnQuit.name(in: profile))
    }

    static func setClearsOnQuit(_ on: Bool, in profile: UUID) {
        if on { defaults.set(true, forKey: ProfileKey.clearsCookiesOnQuit.name(in: profile)) }
        else { defaults.removeObject(forKey: ProfileKey.clearsCookiesOnQuit.name(in: profile)) }
        clearingChanged.send(profile)
    }

    /// How long quitting waits for the clearing, at most.
    static let quitWait: TimeInterval = 1.5

    /// The profiles to clear as Zigzag quits: those that chose it and were used this run (one not opened has had
    /// nothing new stored since it was last cleared).
    static func profilesClearingOnQuit() -> [Profile] {
        Profiles.shared.opened.filter { clearsOnQuit(in: $0.id) }
    }

    /// Clears the cookies of every site but the kept ones, one job per profile, for `whenDone` within `quitWait`.
    static func clearJobs(_ profiles: [Profile]) -> [@MainActor () async -> Void] {
        profiles.map { profile in
            let store = profile.store, kept = sites(in: profile.id)
            return {
                await WebsiteData.clear(.cookies, keeping: kept, in: store)
                await flushCookies(in: store)
            }
        }
    }

    /// Writes the store's cookies to disk now (WebKit's private flush): otherwise a clearing made as Zigzag quits
    /// is lost with the network process, and the cookies are back at the next launch.
    static func flushCookies(in store: WKWebsiteDataStore) async {
        let cookies = store.httpCookieStore
        let selector = NSSelectorFromString("_flushCookiesToDiskWithCompletionHandler:")
        guard cookies.responds(to: selector), let method = class_getInstanceMethod(type(of: cookies), selector) else { return }
        typealias Flush = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let flush = unsafeBitCast(method_getImplementation(method), to: Flush.self)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in flush(cookies, selector) { done.resume() } }
    }

    /// Runs the jobs one after another, calling `done` once: when they've all finished or `wait` has passed.
    static func whenDone(_ jobs: [@MainActor () async -> Void], within wait: TimeInterval, done: @escaping () -> Void) {
        let once = Once(done)
        Task { @MainActor in
            for job in jobs { await job() }
            once.fire()
        }
        // From the run loop, so the wait ends even while the main queue is held up.
        once.perform(#selector(Once.fire), with: nil, afterDelay: wait, inModes: [.common])
    }

    /// Calls its closure the first time it fires.
    private final class Once: NSObject {
        private var done: (() -> Void)?
        init(_ done: @escaping () -> Void) { self.done = done }
        @objc func fire() {
            let call = done
            done = nil
            call?()
        }
    }

    // MARK: Clearing

    /// Removes `types` for every record but the kept sites' ones; everything when none is kept. Returns the
    /// removed records' names, or nil when everything went.
    @discardableResult
    static func clear(_ types: Set<String>, keeping kept: Set<String>, in store: any WebsiteDataClearing) async -> [String]? {
        guard !kept.isEmpty else {
            await store.removeAllData(ofTypes: types)
            return nil
        }
        let names = await store.recordNames(ofTypes: types).filter { !covers(kept, record: $0) }
        if !names.isEmpty { await store.removeData(ofTypes: types, named: Set(names)) }
        return names
    }

    // MARK: Words

    /// Over the sheet that clears every site's cookies, when some are kept.
    static var clearTitle: String {
        String(localized: "Clear cookies for every site you don’t keep?", comment: "Title of the sheet that clears every site's cookies, when some sites keep theirs (Settings › Privacy › Keep Cookies).")
    }

    static func clearMessage(keeping count: Int) -> String {
        count == 1
            ? String(localized: "You’ll be signed out of every site except the one you keep. Your passwords, pinned tabs and history stay.",
                     comment: "Message of the sheet that clears every site's cookies, when one site keeps its cookies.")
            : String(localized: "You’ll be signed out of every site except the \(count) sites you keep. Your passwords, pinned tabs and history stay.",
                     comment: "Message of the sheet that clears every site's cookies, when some sites keep theirs. The number is how many, always more than one.")
    }
}

/// What clearing reads and removes in: a website data store, or a made-up one in tests.
@MainActor
protocol WebsiteDataClearing: AnyObject {
    func recordNames(ofTypes types: Set<String>) async -> [String]
    func removeData(ofTypes types: Set<String>, named names: Set<String>) async
    func removeAllData(ofTypes types: Set<String>) async
}

extension WKWebsiteDataStore: WebsiteDataClearing {
    func recordNames(ofTypes types: Set<String>) async -> [String] {
        await dataRecords(ofTypes: types).map(\.displayName)
    }

    func removeData(ofTypes types: Set<String>, named names: Set<String>) async {
        let records = await dataRecords(ofTypes: types).filter { names.contains($0.displayName) }
        guard !records.isEmpty else { return }
        await removeData(ofTypes: types, for: records)
    }

    func removeAllData(ofTypes types: Set<String>) async {
        await removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
