import WebKit

/// Cookies with no expiry date, which WebKit drops when Zigzag quits, kept across a relaunch that brings the last
/// session back, as Chrome does (YouTube's theater mode, sign-ins that use them). One file per profile, in its
/// folder, owner-only; never for a private window, whose store is no profile's.
@MainActor
enum SessionCookies {
    /// One cookie as it's written down. Its value never shows in a description or a log.
    nonisolated struct Saved: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?

        init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false, httpOnly: Bool = false, sameSite: String? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.secure = secure
            self.httpOnly = httpOnly
            self.sameSite = sameSite
        }

        init(_ cookie: HTTPCookie) {
            self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure,
                      httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
        }

        /// What WebKit takes back: still a session cookie, for the same host or domain as before.
        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path.isEmpty ? "/" : path, .name: name, .value: value, .discard: "TRUE"]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }

        var bytes: Int { name.utf8.count + value.utf8.count + domain.utf8.count + path.utf8.count }

        var description: String { "SessionCookie(\(name) for \(domain))" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }
    }

    nonisolated struct File: Codable, Sendable {
        var version = 1
        var cookies: [Saved]
    }

    /// At most this many are kept per profile, and this many bytes of them.
    nonisolated static let maxCount = 1000
    nonisolated static let maxBytes = 512 * 1024

    nonisolated static func file(in folder: URL) -> URL { folder.appendingPathComponent("SessionCookies.json") }

    // MARK: Choosing and writing

    /// The session cookies among `cookies`, in a fixed order, within the caps. `kept`: only those sites' (a profile
    /// that clears cookies when Zigzag quits keeps no others).
    nonisolated static func toSave(_ cookies: [HTTPCookie], keeping kept: Set<String>? = nil) -> [Saved] {
        var saved = cookies.filter(\.isSessionOnly).map(Saved.init)
        if let kept { saved = saved.filter { KeptCookies.covers(kept, record: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) } }
        saved.sort { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        var total = 0
        var capped: [Saved] = []
        for cookie in saved where capped.count < maxCount {
            // A single oversized one is skipped, not the rest.
            guard total + cookie.bytes <= maxBytes else { continue }
            total += cookie.bytes
            capped.append(cookie)
        }
        return capped
    }

    nonisolated static func encode(_ cookies: [Saved]) -> Data? { JSONStore.encode(File(cookies: cookies)) }

    /// Writes the file owner-only (0600) from the first byte, through a file beside it; none at all when there's
    /// nothing to keep.
    @discardableResult
    nonisolated static func write(_ data: Data?, to url: URL) -> Bool {
        guard let data else { remove(url); return true }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary.path, url.path) == 0 else {
            try? manager.removeItem(at: temporary)
            return false
        }
        return true
    }

    nonisolated static func read(_ url: URL) -> [Saved] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [] }
        return Array(file.cookies.prefix(maxCount))
    }

    nonisolated static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Takes a site's saved cookies out of the file ("youtube.com", covering its subdomains); every site's when `site`
    /// is nil, but the `kept` sites'.
    nonisolated static func forget(site: String?, keeping kept: Set<String> = [], in url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let saved = read(url)
        let left = saved.filter { cookie in
            let host = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let site { return !KeptCookies.covers([site.lowercased()], record: host) }
            return !kept.isEmpty && KeptCookies.covers(kept, record: host)
        }
        guard left != saved else { return }
        write(left.isEmpty ? nil : encode(left), to: url)
    }

    // MARK: Putting them back

    /// Sets the saved cookies into `jar`, then removes the file (the next save writes it again). How many were set.
    @discardableResult
    static func restore(from url: URL, into jar: any SessionCookieJar) async -> Int {
        let saved = read(url)
        remove(url)
        let cookies = saved.compactMap(\.cookie)
        if !cookies.isEmpty { await jar.setSessionCookies(cookies) }
        return cookies.count
    }

    /// Restores still under way, by the store they're for.
    private static var restoring: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// How long a page waits for them at most.
    static let restoreWait: Duration = .seconds(2)

    /// At launch, before any page of the store loads: puts a saved file back when the last session comes back;
    /// otherwise (On launch is Open a new window) removes it. Whether a restore began.
    @discardableResult
    static func prepare(_ url: URL, resumes: Bool, for store: AnyObject, jar: () -> any SessionCookieJar) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard resumes else { remove(url); return false }
        let key = ObjectIdentifier(store)
        let jar = jar()
        restoring[key] = Task { @MainActor in
            await restore(from: url, into: jar)
            restoring[key] = nil
        }
        return true
    }

    static func isRestoring(_ store: AnyObject) -> Bool { restoring[ObjectIdentifier(store)] != nil }

    /// Waits for the store's restore, if one is under way, so a page's first request carries the cookies.
    static func ready(_ store: AnyObject) async {
        guard let task = restoring[ObjectIdentifier(store)] else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Countdown(1) { done.resume() }
            Task { @MainActor in
                await task.value
                once.tick()
            }
            Task { @MainActor in
                try? await Task.sleep(for: restoreWait)
                once.tick()
            }
        }
    }

    // MARK: Saving while Zigzag runs

    /// On once launch has decided what comes back: nothing is saved before, so a file waiting to be restored isn't
    /// written over. Never on while tests run.
    private(set) static var isOn = false
    private static var watchers: [UUID: Watcher] = [:]
    private static var waiting: Set<UUID> = []
    private static var generation: [UUID: Int] = [:]
    private static var written: [UUID: Data] = [:]
    private static var timer: Timer?
    /// Zigzag is quitting: only the quit's own saves run, so none of them is passed over for one that won't finish.
    private static var quitting = false
    /// A change is saved this long after it, collecting the ones that follow.
    static let saveDelay: TimeInterval = 5
    /// And every profile in use this often, whatever was heard.
    static let saveInterval: TimeInterval = 300

    /// From launch: each profile's saved file is put back or removed, then saving starts.
    static func start(resumes: Bool) {
        for profile in Profiles.shared.all {
            let url = file(in: profile.folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if resumes {
                let store = profile.store
                prepare(url, resumes: true, for: store) { store.httpCookieStore }
                Task { @MainActor in
                    await ready(store)
                    await save(profile)
                }
            } else {
                remove(url)
            }
        }
        isOn = true
        Profiles.shared.opened.forEach(watch)
        timer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { _ in
            MainActor.assumeIsolated { Profiles.shared.opened.forEach { profile in Task { await save(profile) } } }
        }
    }

    /// A profile's store was made: its cookie changes are saved from now on.
    static func watch(_ profile: Profile) {
        guard isOn, watchers[profile.id] == nil, let store = profile.storeIfMade, store.isPersistent else { return }
        let watcher = Watcher(profile: profile.id)
        store.httpCookieStore.add(watcher)
        watchers[profile.id] = watcher
    }

    fileprivate static func changed(_ id: UUID) {
        guard isOn, waiting.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) {
            waiting.remove(id)
            guard let profile = Profiles.shared.listed(id) else { return }
            Task { await save(profile) }
        }
    }

    /// Writes the profile's session cookies now, from its store; none if it has none.
    static func save(_ profile: Profile, forQuit: Bool = false) async {
        guard isOn, !quitting || forQuit, let store = profile.storeIfMade, store.isPersistent, !isRestoring(store) else { return }
        let id = profile.id
        let turn = generation[id, default: 0] + 1
        generation[id] = turn
        let cookies = await store.httpCookieStore.allCookies()
        // A later save is under way, or the profile was removed meanwhile.
        guard generation[id] == turn, Profiles.shared.listed(id) != nil else { return }
        let kept = KeptCookies.clearsOnQuit(in: id) ? KeptCookies.sites(in: id) : nil
        let chosen = toSave(cookies, keeping: kept)
        let data = chosen.isEmpty ? nil : encode(chosen)
        let url = file(in: profile.folder)
        if let data, data == written[id], FileManager.default.fileExists(atPath: url.path) { return }
        if write(data, to: url) { written[id] = data }
    }

    /// The saves to run as Zigzag quits, after its cookie clearing: one per profile in use.
    static func quitJobs() -> [@MainActor () async -> Void] {
        guard isOn else { return [] }
        timer?.invalidate()
        quitting = true
        return Profiles.shared.opened.map { profile in { await save(profile, forQuit: true) } }
    }

    // MARK: Clearing

    /// The profile a store is, never a private window's: that one keeps nothing.
    static func profile(of store: WKWebsiteDataStore) -> Profile? {
        guard store.isPersistent else { return nil }
        return Profiles.shared.profile(ofStore: store)
    }

    /// A site's cookies, or every site's but the kept ones, were cleared in a store: they leave its saved file too.
    static func cleared(site: String?, keeping kept: Set<String> = [], in store: WKWebsiteDataStore) {
        guard let profile = profile(of: store) else { return }
        forget(site: site, keeping: kept, in: file(in: profile.folder))
        written[profile.id] = nil
        Task { await save(profile) }
    }

    /// Hears a profile's cookie changes. The store doesn't retain it.
    private final class Watcher: NSObject, WKHTTPCookieStoreObserver {
        let profile: UUID
        init(profile: UUID) { self.profile = profile }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            MainActor.assumeIsolated { SessionCookies.changed(profile) }
        }
    }
}

/// The sessionStorage sleeping tabs keep (#502), and open tabs' as Zigzag quits, kept across a relaunch that brings the
/// last session back, as Chrome does: a site that keeps you signed in there still has you signed in. One file per
/// profile, beside its session cookies, owner-only; never a private tab's.
@MainActor
enum SavedSessionStorage {
    /// One tab's, as it's written down. Its items never show in a description or a log.
    nonisolated struct Saved: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var tab: UUID
        /// The page it was read from: only that page gets it back.
        var url: URL
        var origin: String
        var items: [[String]]

        var session: PageState.Session { PageState.Session(origin: origin, items: items) }
        var size: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } }

        var description: String { "SavedSessionStorage(\(items.count) items)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }
    }

    nonisolated struct File: Codable, Sendable {
        var version = 1
        var tabs: [Saved]
    }

    /// One tab carries what a page script should (`PageState.sleepReader`); a profile this many tabs, and this much.
    nonisolated static let maxTabSize = 250_000
    nonisolated static let maxTabs = 200
    nonisolated static let maxSize = 4_000_000

    nonisolated static func file(in folder: URL) -> URL { folder.appendingPathComponent("SessionStorage.json") }

    // MARK: Choosing and writing

    /// What a tab holds to write down: its sleeping page's sessionStorage, or `read` from its open page. Never a
    /// private tab's.
    static func entry(for tab: Tab, read: [UUID: Saved] = [:]) -> Saved? {
        guard !tab.isPrivate, !tab.isClosed else { return nil }
        if let saved = read[tab.id] { return saved }
        guard let state = tab.pageState, let session = state.session else { return nil }
        return Saved(tab: tab.id, url: state.url, origin: session.origin, items: session.items)
    }

    /// Within the caps: a tab that would take the rest past them is skipped, not the rest. `kept`: only those sites'
    /// (a profile that clears cookies when Zigzag quits keeps no others).
    nonisolated static func toSave(_ saved: [Saved], keeping kept: Set<String>? = nil) -> [Saved] {
        var total = 0
        var capped: [Saved] = []
        for entry in saved where capped.count < maxTabs {
            guard !entry.items.isEmpty, let host = URL(string: entry.origin)?.host()?.lowercased(), !host.isEmpty else { continue }
            if let kept, !KeptCookies.covers(kept, record: host) { continue }
            let size = entry.size
            guard size <= maxTabSize, total + size <= maxSize else { continue }
            total += size
            capped.append(entry)
        }
        return capped
    }

    nonisolated static func encode(_ saved: [Saved]) -> Data? { saved.isEmpty ? nil : JSONStore.encode(File(tabs: saved)) }

    /// Owner-only from the first byte, as session cookies are; no file at all when there's nothing to keep.
    @discardableResult
    nonisolated static func write(_ saved: [Saved], to url: URL) -> Bool { SessionCookies.write(encode(saved), to: url) }

    nonisolated static func read(_ url: URL) -> [Saved] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [] }
        return toSave(file.tabs)
    }

    // MARK: Putting it back

    /// Read at launch for the session's tabs, by tab, with the profile each was saved in.
    private static var waiting: [UUID: (profile: UUID, saved: Saved)] = [:]

    /// A profile's file at launch: read for the tabs the last session brings back, or (On launch is Open a new
    /// window) left unread; removed either way, and the next save writes it again.
    static func prepare(_ url: URL, resumes: Bool, profile: UUID) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if resumes { for saved in read(url) { waiting[saved.tab] = (profile, saved) } }
        SessionCookies.remove(url)
    }

    /// A tab made from the last session: its page's sessionStorage goes back on it, before its first load.
    static func restore(into tab: Tab) {
        guard let entry = waiting.removeValue(forKey: tab.id), !tab.isPrivate, tab.profile.id == entry.profile else { return }
        tab.takeSavedSession(entry.saved.session, from: entry.saved.url)
    }

    /// Whether a tab's is still waiting to be put back.
    static func isWaiting(for id: UUID) -> Bool { waiting[id] != nil }

    // MARK: Saving while Zigzag runs

    /// On once the last session's tabs are made: nothing is written before. Never on while tests run.
    private(set) static var isOn = false
    /// Zigzag is quitting and the quit's save is written: nothing after it (tabs closing as windows go) writes over it.
    private static var quitting = false
    private static var scheduled = false
    private static var written: [UUID: Data] = [:]

    /// From launch, before the session's tabs are made.
    static func start(resumes: Bool) {
        for profile in Profiles.shared.all { prepare(file(in: profile.folder), resumes: resumes, profile: profile.id) }
    }

    /// The session's tabs are made: what none of them took is dropped, and the files are written for what they hold.
    static func started() {
        dropWaiting()
        isOn = true
        saveNow()
    }

    static func dropWaiting() { waiting = [:] }

    /// A tab's kept sessionStorage changed: the files are written again, once, on the next turn of the run loop.
    static func changed() {
        guard isOn, !quitting, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            saveNow()
        }
    }

    /// Writes every profile's file now from what its tabs hold, with `read` for the open ones.
    static func saveNow(read: [UUID: Saved] = [:]) {
        guard isOn, !quitting else { return }
        let tabs = WindowManager.shared.openTabs
        for profile in Profiles.shared.all where !profile.isHeadless {
            let kept = KeptCookies.clearsOnQuit(in: profile.id) ? KeptCookies.sites(in: profile.id) : nil
            let saved = toSave(tabs.filter { $0.profile === profile }.compactMap { entry(for: $0, read: read) }, keeping: kept)
            let data = encode(saved)
            let url = file(in: profile.folder)
            if data == written[profile.id], (data != nil) == FileManager.default.fileExists(atPath: url.path) { continue }
            if SessionCookies.write(data, to: url) { written[profile.id] = data }
        }
    }

    /// As Zigzag quits: open tabs' pages are asked for their sessionStorage side by side, and what answers within
    /// `wait` is written with what sleeping tabs hold. Nothing is written after.
    static func saveForQuit(within wait: TimeInterval, done: @escaping () -> Void) {
        guard isOn, !quitting else { done(); return }
        let open = WindowManager.shared.openTabs.filter { !$0.isPrivate && $0.isLoaded }
        capture(open, within: wait) { read in
            saveNow(read: read)
            quitting = true
            done()
        }
    }

    /// Each tab's page's sessionStorage, read as a tab going to sleep reads it, for those that answer within `wait`.
    static func capture(_ tabs: [Tab], within wait: TimeInterval, done: @escaping ([UUID: Saved]) -> Void) {
        let reading = Reading(count: tabs.count, done: done)
        guard !tabs.isEmpty else { reading.finish(); return }
        for tab in tabs {
            tab.readPageState(includingSession: true) { state in
                if let state, let session = state.session {
                    reading.read[tab.id] = Saved(tab: tab.id, url: state.url, origin: session.origin, items: session.items)
                }
                reading.tick()
            }
        }
        // From the run loop, so the wait ends even while the main queue is held up.
        reading.perform(#selector(Reading.finish), with: nil, afterDelay: wait, inModes: [.common])
    }

    /// The answers `capture` waits for, handed on once: all in, or the wait over.
    private final class Reading: NSObject {
        var read: [UUID: Saved] = [:]
        private var left: Int
        private var done: (([UUID: Saved]) -> Void)?
        init(count: Int, done: @escaping ([UUID: Saved]) -> Void) {
            left = count
            self.done = done
        }
        func tick() {
            left -= 1
            if left <= 0 { finish() }
        }
        @objc func finish() {
            guard let call = done else { return }
            done = nil
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            call(read)
        }
    }
}

/// Where restored cookies are set: a store's cookies, or a made-up one in tests.
@MainActor
protocol SessionCookieJar: AnyObject {
    /// Returns once every one is set.
    func setSessionCookies(_ cookies: [HTTPCookie]) async
}

extension WKHTTPCookieStore: SessionCookieJar {
    func setSessionCookies(_ cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty else { return }
        if #available(macOS 26.0, *) { return await setCookies(cookies) }
        // All sent at once, rather than a round trip each.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let left = Countdown(cookies.count) { done.resume() }
            for cookie in cookies { setCookie(cookie) { left.tick() } }
        }
    }
}

/// Calls its closure once, when it has ticked `count` times.
private final class Countdown {
    private var left: Int
    private var done: (() -> Void)?
    init(_ count: Int, done: @escaping () -> Void) {
        left = count
        self.done = done
    }
    func tick() {
        left -= 1
        guard left <= 0, let call = done else { return }
        done = nil
        call()
    }
}
