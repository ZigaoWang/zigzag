import AppKit
import WebKit
import os

/// A File handoff waiting for Zigzag to save the file before it runs the rule.
struct PendingFileHandoff {
    var rule: DownloadRule
    var request: DownloadHandoff.Request
    /// A download follows a Hand Off at once; an older answer is left for the next one.
    var at = Date()
}

final class DownloadItem {
    enum State: Equatable { case downloading, paused, finished, failed, cancelled }

    let id = UUID()
    fileprivate(set) var filename: String
    fileprivate(set) var destination: URL?
    fileprivate(set) var state: State = .downloading
    fileprivate(set) var fractionCompleted: Double = 0
    fileprivate(set) var totalBytes: Int64 = 0
    fileprivate(set) var completedBytes: Int64 = 0
    var started = Date()
    fileprivate weak var download: WKDownload?
    fileprivate var progressObservation: NSKeyValueObservation?
    fileprivate var resumeData: Data?
    /// The file this download replaces once it's done; until then it goes to a hidden file beside it, so a failed
    /// or canceled download never costs you the one you had.
    fileprivate var replaces: URL?
    /// Set by a rule's Open: hand the finished file to its default app. Not saved with the item.
    fileprivate var opensWhenFinished = false
    /// A File handoff waiting for this download; nil for a URL handoff. Not saved with the item.
    fileprivate(set) var fileHandoff: PendingFileHandoff?
    let sourceURL: URL?
    /// Bytes a second, smoothed over the last few seconds, for "time left".
    fileprivate(set) var speed: Double = 0
    fileprivate var lastSample: (at: Date, bytes: Int64)?

    /// Why it stopped, in a few plain words, when it failed ("the connection dropped").
    fileprivate(set) var failure: String?
    /// Why its folder can't be saved into, kept from when the destination was decided: WebKit's own error names
    /// neither the folder nor what's wrong with it, so this is said instead when the error says nothing better.
    fileprivate(set) var placeProblem: String?

    /// Finished, but the file isn't where it was saved any more (deleted, or moved in Finder).
    var fileIsMissing: Bool {
        state == .finished && !(destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    /// Seconds until done at the current speed, once there's enough to tell.
    var secondsLeft: Double? {
        guard state == .downloading, speed > 1, totalBytes > completedBytes else { return nil }
        return Double(totalBytes - completedBytes) / speed
    }
    /// The data store it came from, so a paused download resumes with the same cookies (a private one's own).
    fileprivate weak var dataStore: WKWebsiteDataStore?
    /// From a private window: listed only in private windows, and forgotten when the last one closes.
    let isPrivate: Bool
    /// The profile it was downloaded in: only that profile's extensions see it (BridgeDownloads).
    let profile: UUID
    /// From the AI Apps profile (Headless): kept out of your list and the Dock.
    let isForAIApps: Bool

    init(filename: String, sourceURL: URL?, isPrivate: Bool, profile: UUID = Profile.defaultID) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.isPrivate = isPrivate
        self.profile = profile
        isForAIApps = Library.shared.directory.profile(profile)?.isHeadless == true
    }
}

/// Files downloaded from pages, saved to the Downloads folder setting unless a rule or a question says otherwise.
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []
    let changed = Signal<DownloadItem?>()

    /// Finished downloads are remembered between launches (never private ones), the newest 50, while the file is there.
    /// Paused ones too, with what WebKit needs to go on from where they stopped.
    private struct Saved: Codable {
        var filename: String
        var destination: URL
        var sourceURL: URL?
        var started: Date
        var totalBytes: Int64
        var completedBytes: Int64?
        var paused: Bool?
        var resumeData: Data?
        /// A paused download that replaces a file goes on into a hidden one beside it; this is the file it takes the
        /// place of once done. Missing in lists saved before it was kept.
        var replaces: URL?
        /// The profile it was downloaded in, when that isn't the first: a paused one goes on with that profile's
        /// sign-ins, and only that profile's extensions see it. Missing in lists saved before there were profiles.
        var profile: UUID?
    }

    override init() {
        super.init()
        let saved = JSONStore.load([Saved].self, from: Paths.downloads) ?? []
        items = saved.filter { FileManager.default.fileExists(atPath: $0.destination.path) }.map { entry in
            // One whose profile is gone is the first's, as its spaces are.
            let profile = entry.profile.flatMap { Library.shared.directory.profile($0) != nil ? $0 : nil } ?? Profile.defaultID
            let item = DownloadItem(filename: entry.filename, sourceURL: entry.sourceURL, isPrivate: false, profile: profile)
            item.destination = entry.destination
            item.totalBytes = entry.totalBytes
            item.started = entry.started
            if entry.paused == true {
                item.state = .paused
                item.resumeData = entry.resumeData
                item.replaces = entry.replaces
                // One paused before there were profiles, or in the first, goes on in the first: never in whichever
                // profile's page happens to be in front.
                item.dataStore = Profiles.shared.profile(profile).store
                item.completedBytes = entry.completedBytes ?? 0
                item.fractionCompleted = entry.totalBytes > 0 ? Double(item.completedBytes) / Double(entry.totalBytes) : 0
            } else {
                item.state = .finished
                item.fractionCompleted = 1
                item.completedBytes = entry.totalBytes
            }
            return item
        }
        // Written when a download finishes or the list is cleared, not on every progress tick.
        token = changed.observe { [weak self] item in
            if item == nil || item?.state != .downloading { self?.save() }
        }
    }

    private var token: SignalToken?

    private func save() {
        let kept = items.filter { !$0.isPrivate && !$0.isForAIApps && [.finished, .paused].contains($0.state) }.prefix(50).compactMap { item in
            item.destination.map {
                Saved(filename: item.filename, destination: $0, sourceURL: item.sourceURL, started: item.started, totalBytes: item.totalBytes,
                      completedBytes: item.completedBytes, paused: item.state == .paused ? true : nil, resumeData: item.state == .paused ? item.resumeData : nil,
                      replaces: item.state == .paused ? item.replaces : nil,
                      profile: item.profile == Profile.defaultID ? nil : item.profile)
            }
        }
        JSONStore.save(Array(kept), to: Paths.downloads)
    }

    var activeCount: Int { items.filter { $0.state == .downloading }.count }
    /// The downloads the Dock shows: all but AI apps'.
    private var yourActive: [DownloadItem] { items.filter { $0.state == .downloading && !$0.isForAIApps } }
    var yourActiveCount: Int { yourActive.count }

    /// What a window lists: a private window its own downloads, a normal window everything else but AI apps'.
    func items(isPrivate: Bool) -> [DownloadItem] { items.filter { $0.isPrivate == isPrivate && !$0.isForAIApps } }

    /// The last private window closed: its finished downloads leave the list (the files stay in Downloads).
    func forgetPrivate() {
        let before = items.count
        items.filter { $0.isPrivate && $0.state == .paused }.forEach(discardPartial)
        items.removeAll { $0.isPrivate && $0.state != .downloading }
        if items.count != before { changed.send(nil) }
    }
    var overallProgress: Double {
        let active = yourActive
        guard !active.isEmpty else { return 1 }
        return active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
    }

    /// Where downloads go: Downloads unless you picked another folder in Settings. The pick is kept even when that
    /// folder is gone, so the download says so rather than quietly landing in Downloads (#588).
    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "DownloadFolder") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            UserDefaults.standard.set(newValue.standardizedFileURL == downloads.standardizedFileURL ? nil : newValue.path, forKey: "DownloadFolder")
        }
    }

    /// Why a download can't be saved into this folder, in plain words naming it, or nil when it can: the folder may
    /// be gone (an unmounted disk, say), may not be a folder, or may not be writable.
    static func folderProblem(_ folder: URL = DownloadManager.folder) -> String? {
        let name = folder.lastPathComponent
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) else {
            return String(localized: "“\(name)” isn’t there. If it’s on another disk, that disk may not be mounted", comment: "Why a download can't be saved: its folder is missing, named in quotes, like “Downloads” isn’t there. If it’s on another disk, that disk may not be mounted.")
        }
        guard isFolder.boolValue else {
            return String(localized: "“\(name)” isn’t a folder", comment: "Why a download can't be saved: something that isn't a folder is at its folder's place, named in quotes, like “Movies” isn’t a folder.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return String(localized: "“\(name)” can’t be written to", comment: "Why a download can't be saved: its folder is read-only, named in quotes, like “Movies” can’t be written to.")
        }
        return nil
    }

    /// Ask with a save sheet each time instead of saving straight to Downloads.
    static var asksWhereToSave: Bool {
        get { UserDefaults.standard.bool(forKey: "DownloadsAskWhere") }
        set { UserDefaults.standard.set(newValue, forKey: "DownloadsAskWhere") }
    }

    /// A download got its file and is under way: the window it came from shows it leaving for Downloads.
    let started = Signal<(DownloadItem, NSWindow?)>()
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// The origin at download start; the tab may have navigated by the time the destination is decided, and it
    /// decides whether cookies may go along.
    private var origins: [ObjectIdentifier: String] = [:]
    /// The folder the last save sheet was pointed at, to start there next time.
    private var lastFolder: URL?

    /// Where a download was already told to go (Save Page As picked the place), so it isn't asked again.
    private var chosenDestinations: [ObjectIdentifier: URL] = [:]
    /// Downloads from a page a rule opened; that rule mustn't take the file too.
    private var ruleOpenedDownloads: Set<ObjectIdentifier> = []
    /// Downloads whose handoff question was put off; don't ask the same rule again.
    private var ruleDeclinedDownloads: Set<ObjectIdentifier> = []
    /// File handoffs a tab or pop-up answered before WebKit made its download, by the page's web view.
    private var pendingFileHandoffs: [ObjectIdentifier: [PendingFileHandoff]] = [:]

    /// A tab or pop-up answered Hand Off for a File rule: let the download run, and this rule takes the saved file.
    func expectFileHandoff(_ rule: DownloadRule, request: DownloadHandoff.Request, from webView: WKWebView?) {
        guard let webView else { return }
        let key = ObjectIdentifier(webView)
        let cutoff = Date().addingTimeInterval(-60)
        var waiting = (pendingFileHandoffs[key] ?? []).filter { $0.at > cutoff }
        waiting.append(PendingFileHandoff(rule: rule, request: request))
        pendingFileHandoffs[key] = waiting
    }

    /// The site refused the download a File handoff was waiting for: it won't come.
    func dropFileHandoff(for url: URL, from webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        let waiting = (pendingFileHandoffs[key] ?? []).filter { $0.request.url != url }
        pendingFileHandoffs[key] = waiting.isEmpty ? nil : waiting
    }

    #if DEBUG
    func debugPendingFileHandoffs(from webView: WKWebView) -> [URL] { (pendingFileHandoffs[ObjectIdentifier(webView)] ?? []).map(\.request.url) }
    func debugSetFileHandoff(_ handoff: PendingFileHandoff?, on item: DownloadItem) { item.fileHandoff = handoff }
    #endif

    /// The File handoff waiting for this download, matched by its address, before or after redirects. Never another
    /// download's, so a handoff whose download never started can't take a later file.
    private func takeFileHandoff(for download: WKDownload, response: URLResponse) -> PendingFileHandoff? {
        guard let webView = download.webView else { return nil }
        let key = ObjectIdentifier(webView)
        let cutoff = Date().addingTimeInterval(-60)
        var waiting = (pendingFileHandoffs[key] ?? []).filter { $0.at > cutoff }
        let addresses = [download.originalRequest?.url, response.url].compactMap { $0 }
        guard let index = waiting.firstIndex(where: { addresses.contains($0.request.url) }) else {
            pendingFileHandoffs[key] = waiting.isEmpty ? nil : waiting
            return nil
        }
        let pending = waiting.remove(at: index)
        pendingFileHandoffs[key] = waiting.isEmpty ? nil : waiting
        return pending
    }

    /// A Firefox package coming in from a page (the store's Add to Firefox): it is installed, not kept. The file is
    /// temporary, and the window and profile are the ones the page was in, for the install sheet.
    private struct PendingExtensionInstall {
        let file: URL
        weak var window: NSWindow?
        let profile: UUID
        /// The sha256 AMO's API publishes for the file; the bytes must match it.
        let hash: String
        /// AMO's ID for the add-on, for a package that names none itself.
        let storeID: String?
    }
    private var pendingExtensionInstalls: [ObjectIdentifier: PendingExtensionInstall] = [:]
    /// Downloads a click on AMO's button started, with the file AMO's API named for them at the click.
    private var addonsFiles: [ObjectIdentifier: ExtensionStore.PublishedAddonsFile] = [:]

    private static func isPrivate(_ download: WKDownload) -> Bool {
        !(download.webView?.configuration.websiteDataStore.isPersistent ?? false)
    }

@discardableResult
    func track(_ download: WKDownload, window: NSWindow?, saveTo destination: URL? = nil,
               openedByRule: Bool = false, rulesAlreadyDeclined: Bool = false,
               addonsFile: ExtensionStore.PublishedAddonsFile? = nil) -> DownloadItem {
        let identifier = ObjectIdentifier(download)
        if let addonsFile { addonsFiles[identifier] = addonsFile } else { addonsFiles.removeValue(forKey: identifier) }
        if openedByRule { ruleOpenedDownloads.insert(identifier) } else { ruleOpenedDownloads.remove(identifier) }
        if rulesAlreadyDeclined { ruleDeclinedDownloads.insert(identifier) } else { ruleDeclinedDownloads.remove(identifier) }
        if let destination { chosenDestinations[ObjectIdentifier(download)] = destination }
        download.delegate = self
        if let window { windows[ObjectIdentifier(download)] = window }
        let referrer = download.originalRequest?.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) }
        origins[ObjectIdentifier(download)] = SiteOrigin.of(referrer) ?? SiteOrigin.of(download.webView?.url)
        let isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download", sourceURL: download.originalRequest?.url,
                                isPrivate: isPrivate, profile: Profiles.shared.profile(ofPage: download.webView).id)
        item.dataStore = download.webView?.configuration.websiteDataStore
        attach(download, to: item)
        items.insert(item, at: 0)
        changed.send(item)
        return item
    }

    /// Follows a download's progress on its row: the first attempt, or the same row after a resume.
    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download
        // A fast download reports hundreds of times a second; the row, the Dock and every window hear of it four
        // times a second, which is as often as anyone can read it.
        let lastSent = OSAllocatedUnfairLock(initialState: Date.distantPast)
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak self, weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            let due = lastSent.withLock { last -> Bool in
                let now = Date()
                guard fraction >= 1 || now.timeIntervalSince(last) >= 0.25 else { return false }
                last = now
                return true
            }
            guard due else { return }
            DispatchQueue.main.async {
                guard let item else { return }
                let now = Date()
                if let last = item.lastSample {
                    let elapsed = now.timeIntervalSince(last.at)
                    if elapsed >= 0.5 {
                        let instant = Double(max(0, completed - last.bytes)) / elapsed
                        item.speed = item.speed == 0 ? instant : item.speed * 0.75 + instant * 0.25
                        item.lastSample = (now, completed)
                    }
                } else {
                    item.lastSample = (now, completed)
                }
                item.fractionCompleted = fraction
                item.completedBytes = completed
                item.totalBytes = total
                self?.changed.send(item)
            }
        }
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    /// A File handoff that won't run: it is forgotten, and the failure is said once.
    private func failFileHandoff(_ item: DownloadItem) {
        guard let handoff = item.fileHandoff else { return }
        item.fileHandoff = nil
        DownloadHandoff.report(.failed(String(localized: "The download didn’t finish.", comment: "Why a File handoff didn't run: the download failed or was cancelled.")),
                               rule: handoff.rule, request: handoff.request)
    }

    /// A paused download given up on: the part already downloaded goes too.
    private func discardPartial(_ item: DownloadItem) {
        item.resumeData = nil
        if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
    }

    func cancel(_ item: DownloadItem) {
        // You stopped it: the handoff goes quietly.
        item.fileHandoff = nil
        if item.state == .paused {
            discardPartial(item)
            item.state = .cancelled
            changed.send(item)
            return
        }
        item.download?.cancel { [weak self] data in
            MainActor.assumeIsolated {
                item.resumeData = data
                item.state = .cancelled
                self?.changed.send(item)
            }
        }
    }

    /// Whether a download can stop for now and go on later: one fetched from a web address. A file the page made
    /// itself (blob:, data:) can only be canceled.
    func canPause(_ item: DownloadItem) -> Bool {
        item.state == .downloading && ["http", "https"].contains(item.sourceURL?.scheme?.lowercased() ?? "")
    }

    /// Stops a download where it is, keeping what's arrived so far when the server lets it go on from there.
    func pause(_ item: DownloadItem) {
        guard canPause(item), let download = item.download else { return }
        item.state = .paused
        item.progressObservation = nil
        item.speed = 0
        item.lastSample = nil
        changed.send(item)
        download.cancel { [weak self] data in
            MainActor.assumeIsolated {
                item.resumeData = data
                self?.changed.send(item)
            }
        }
    }

    /// Quitting: every download still coming in pauses where it is, and is written down with what's needed to go on
    /// after the next launch. `done` runs once they've all stopped, or after two seconds at most.
    func pauseAllForQuit(then done: @escaping () -> Void) {
        final class Countdown { var left = 0; var finished = false }
        let countdown = Countdown()
        let finish = { [weak self] in
            guard !countdown.finished else { return }
            countdown.finished = true
            self?.save()
            done()
        }
        for item in items where !item.isPrivate && canPause(item) {
            guard let download = item.download else { continue }
            countdown.left += 1
            item.state = .paused
            item.progressObservation = nil
            download.cancel { data in
                MainActor.assumeIsolated {
                    item.resumeData = data
                    countdown.left -= 1
                    if countdown.left == 0 { finish() }
                }
            }
        }
        if countdown.left == 0 { finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
    }

    /// Goes on with a paused download in the same row: from where it stopped, or from the start when the server
    /// doesn't allow picking up partway.
    func resume(_ item: DownloadItem) {
        guard item.state == .paused, let webView = webView(for: item) else { return }
        item.state = .downloading
        changed.send(item)
        let attach: @MainActor (WKDownload) -> Void = { [weak self] download in
            MainActor.assumeIsolated {
                download.delegate = self
                self?.attach(download, to: item)
                self?.changed.send(item)
            }
        }
        if let data = item.resumeData {
            item.resumeData = nil
            webView.resumeDownload(fromResumeData: data, completionHandler: attach)
        } else if let url = item.sourceURL {
            // Starting over: the new copy goes to the same file.
            if let destination = item.destination { restarts[url] = destination }
            item.completedBytes = 0
            item.fractionCompleted = 0
            webView.startDownload(using: URLRequest(url: url), completionHandler: attach)
        }
    }

    /// Downloads started over after a pause, by address, and the file each one already had.
    private var restarts: [URL: URL] = [:]

    /// A web view to resume in: one from a window of the same kind, else a hidden one on the download's own data
    /// store, kept until the download ends.
    /// A page to fetch it with on its own data store: an open tab of the same kind, else a hidden one, so a private
    /// download never uses another session's cookies.
    func webView(for item: DownloadItem) -> WKWebView? {
        guard let store = Self.store(for: item.dataStore, isPrivate: item.isPrivate, profile: item.profile) else { return nil }
        if let open = WindowManager.shared.controllers.first(where: { $0.tabManager.isPrivate == item.isPrivate })?.selectedWebView,
           open.configuration.websiteDataStore === store {
            return open
        }
        if let helper = helpers[item.id] { return helper }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let hidden = WKWebView(frame: .zero, configuration: configuration)
        helpers[item.id] = hidden
        return hidden
    }

    private var helpers: [UUID: WKWebView] = [:]

    /// The store a download is fetched again in: the one it was made in while that's still here, else its profile's
    /// (a download listed from before Zigzag started), never the store of whichever page is in front, which may be
    /// another profile's sign-ins. None for a private window's that's gone, or a profile that's been removed.
    static func store(for made: WKWebsiteDataStore?, isPrivate: Bool, profile: UUID) -> WKWebsiteDataStore? {
        if let made { return made }
        guard !isPrivate else { return nil }
        return Profiles.shared.listed(profile)?.store
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fetches a finished file again after it was deleted or moved, in the same place in the list.
    /// False when it can't be fetched again (not from the web, or a private window that's gone).
    @discardableResult
    func downloadAgain(_ item: DownloadItem) -> Bool {
        guard let url = item.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let webView = webView(for: item) else { return false }
        webView.startDownload(using: URLRequest(url: url), completionHandler: replace(item, from: webView))
        return true
    }

    /// Starts a failed or cancelled download again: from where it stopped when the server allows, in the same row
    /// and into the same file (WebKit doesn't ask where to save a resumed download), else from the start, the new
    /// attempt taking the old row's place.
    @discardableResult
    func retry(_ item: DownloadItem) -> Bool {
        guard canRetry(item), let webView = webView(for: item) else { return false }
        if let data = item.resumeData {
            item.resumeData = nil
            item.failure = nil
            // The same file, so the folder may be back now (or still be gone): ask again rather than keep the old answer.
            item.placeProblem = item.destination.flatMap { Self.folderProblem($0.deletingLastPathComponent()) }
            item.state = .downloading
            changed.send(item)
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                MainActor.assumeIsolated {
                    download.delegate = self
                    self?.attach(download, to: item)
                    self?.changed.send(item)
                }
            }
        } else if let url = item.sourceURL {
            webView.startDownload(using: URLRequest(url: url), completionHandler: replace(item, from: webView))
        }
        return true
    }

    /// The new attempt takes the old row's place, keeping the hidden page it runs on (if any) until it's done.
    private func replace(_ item: DownloadItem, from webView: WKWebView) -> @MainActor (WKDownload) -> Void {
        { [weak self] download in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.items.removeAll { $0 === item }
                let new = self.track(download, window: webView.window)
                if let helper = self.helpers.removeValue(forKey: item.id) { self.helpers[new.id] = helper }
            }
        }
    }

    /// What went wrong, the way you'd say it.
    static func reason(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet: return String(localized: "You’re offline", comment: "Why a download failed, under its name in the downloads panel.")
            case NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost: return String(localized: "The connection dropped", comment: "Why a download failed, under its name in the downloads panel.")
            case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotOpenFile:
                return String(localized: "Couldn’t save it in that folder", comment: "Why a download failed, under its name in the downloads panel.")
            case NSURLErrorBadServerResponse, NSURLErrorResourceUnavailable, NSURLErrorFileDoesNotExist: return String(localized: "The site couldn’t send it", comment: "Why a download failed, under its name in the downloads panel.")
            case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile: return String(localized: "The site refused it", comment: "Why a download failed, under its name in the downloads panel.")
            default: break
            }
        }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) {
            return String(localized: "Not enough space on your Mac", comment: "Why a download failed, under its name in the downloads panel.")
        }
        return nil
    }

    /// What a failed download's row says under its name: the folder's own problem first, since WebKit's error for a
    /// folder that isn't there names neither the folder nor why (#588), then what the error itself says.
    static func failure(_ error: Error, placeProblem: String?) -> String? {
        placeProblem ?? reason(for: error)
    }

    /// A file the page made itself (blob:, data:) can't be fetched again.
    var canRetry: (DownloadItem) -> Bool {
        { $0.resumeData != nil || ["http", "https"].contains($0.sourceURL?.scheme?.lowercased() ?? "") }
    }

    func remove(_ item: DownloadItem) {
        item.fileHandoff = nil
        if item.state == .downloading { cancel(item) }
        if [.paused, .cancelled, .failed].contains(item.state) { discardPartial(item) }
        items.removeAll { $0 === item }
        changed.send(nil)
    }

    func clearFinished(isPrivate: Bool) {
        // Paused downloads stay, like ones still running: Clear never throws away a half-finished file. One that was
        // canceled or failed is given up for good, and the part it left behind goes with it.
        let cleared = items.filter { ![.downloading, .paused].contains($0.state) && $0.isPrivate == isPrivate }
        for item in cleared where [.cancelled, .failed].contains(item.state) { discardPartial(item) }
        items.removeAll { item in cleared.contains { $0 === item } }
        changed.send(nil)
    }

    /// Makes a site's filename safe: no "/" or ":", no control characters, and no invisible characters that reorder
    /// or hide text (a right-to-left override makes "invoice\u{202E}fdp.exe" read as "invoiceexe.pdf"; zero-width
    /// spaces hide between letters). Never a leading dot, never empty.
    nonisolated static func safeFilename(_ filename: String) -> String {
        let name = DownloadTokens.safeName(filename)
        return name.isEmpty ? "Download" : name
    }

    /// AI apps' downloads folder, in their profile's data; nil for yours.
    static func aiAppsFolder(for item: DownloadItem?) -> URL? {
        guard let item, item.isForAIApps else { return nil }
        let folder = Profiles.folder(of: item.profile).appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A free name in Downloads, also avoiding names given to downloads still in progress (their files don't
    /// exist yet), so two "report.pdf"s started together don't collide.
    static func uniqueDestination(for filename: String, avoiding taken: Set<String> = []) -> URL {
        uniqueDestination(for: filename, in: Self.folder, avoiding: taken)
    }

    /// Same, in the rule's folder.
    static func uniqueDestination(for filename: String, in folder: URL, avoiding taken: Set<String> = []) -> URL {
        let safe = safeFilename(filename)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    /// A destination rule's save location: its folder, de-duplicated, or the normal location for an Open rule (saved,
    /// then opened). Nil when no folder is named or it's gone, so the setting decides as if no rule matched.
    /// `canOpen` is false in a private window for a rule not allowed there: still saved, never opened.
    static func place(for destination: DownloadDestination, folder: String, filename: String,
                      avoiding taken: Set<String> = [], canOpen: Bool = true) -> (destination: URL, openWhenFinished: Bool)? {
        switch destination {
        case .folder:
            let path = (folder as NSString).expandingTildeInPath
            guard !path.isEmpty else { return nil }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return (uniqueDestination(for: filename, in: URL(fileURLWithPath: path, isDirectory: true), avoiding: taken), false)
        case .open:
            // Final check: apps, scripts, installers and archives are saved, never opened.
            let mayOpen = canOpen && !DownloadOpening.isRefused((filename as NSString).pathExtension)
            return (uniqueDestination(for: filename, avoiding: taken), mayOpen)
        }
    }

    /// The first destination rule for this file. Tokens in its folder are filled from this download before `place`
    /// decides.
    private static func rulePlace(url: URL, filename: String, response: URLResponse, download: WKDownload,
                                  avoiding taken: Set<String>) -> (destination: URL, openWhenFinished: Bool)? {
        let owner = (download.webView as? BrowserWebView)?.owner
        guard let (rule, wanted) = DownloadRulesStore.shared.destination(for: url, filename: filename,
                                                                          in: download.webView.map { Profiles.shared.profile(ofPage: $0) }) else { return nil }
        let values = HandoffValues(link: url,
                                   referrer: download.originalRequest?.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) },
                                   filename: filename, mime: response.mimeType ?? "",
                                   space: owner.flatMap { Library.shared.space($0.spaceID)?.name } ?? "")
        return place(for: wanted, folder: DownloadTokens.expand(rule.action.folderPath, with: values), filename: filename,
                     avoiding: taken, canOpen: !isPrivate(download) || rule.runsInPrivateWindows)
    }

    /// Opens in the default app, as a Finder double-click would. Without one, the file stays in the downloads list.
    private func openWhenFinished(_ item: DownloadItem) {
        item.opensWhenFinished = false
        guard let url = item.destination, !DownloadOpening.isRefused(url.pathExtension) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let inProgress = Set(items.filter { $0.state == .downloading }.compactMap { $0.destination?.path })
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        let identifier = ObjectIdentifier(download)
        var destination = Self.uniqueDestination(for: name, avoiding: inProgress)
        let window = windows.removeValue(forKey: identifier)
        let startedAt = origins.removeValue(forKey: identifier)
        if let url = download.originalRequest?.url, let earlier = restarts.removeValue(forKey: url) {
            // A paused download started over: it replaces its own partial file.
            try? FileManager.default.removeItem(at: earlier)
            return earlier
        }
        // Add to Firefox: the tab checked the click, its listing and the API's file when the response came (#429), so
        // the file goes to a temporary file and the install sheet, not the download list. Save Page As and the
        // bridge keep their chosen file.
        if let published = addonsFiles.removeValue(forKey: identifier), chosenDestinations[identifier] == nil,
           ExtensionStore.isAddonsFile(download.originalRequest?.url),
           DownloadPolicy.isExtensionPackage(mimeType: response.mimeType, filename: name),
           // The file fetched, after redirects, must be the one the API names.
           ExtensionStore.isPublishedAddonsFile(response.url ?? download.originalRequest?.url, published: published.url) {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("Zigzag-\(UUID().uuidString)-\(Self.safeFilename(name))")
            pendingExtensionInstalls[identifier] = PendingExtensionInstall(file: file, window: window,
                                                                          profile: item(for: download)?.profile ?? Profile.defaultID,
                                                                          hash: published.hash, storeID: published.guid)
            items.removeAll { $0.download === download }
            changed.send(nil)
            return file
        }
        // A tab or pop-up already answered Hand Off for a File rule. Its download runs, then the saved file is handed
        // off; don't ask again.
        // Save Page As and an extension's chosen file are never a rule's.
        var fileHandoff = chosenDestinations[identifier] == nil ? takeFileHandoff(for: download, response: response) : nil
        // Download rules for downloads the navigation never saw: context-menu Download Linked File, or a page's
        // startDownload. Save Page As already chose its file. A URL handoff cancels WebKit's copy and removes its row;
        // a File handoff lets it finish. A rule-opened page's download and a just-put-off one aren't offered again, or
        // a rule that matches its own file would loop.
        defer {
            ruleOpenedDownloads.remove(identifier)
            ruleDeclinedDownloads.remove(identifier)
        }
        let ruleMayAsk = !ruleOpenedDownloads.contains(identifier) && !ruleDeclinedDownloads.contains(identifier)
        let owner = (download.webView as? BrowserWebView)?.owner
        if fileHandoff == nil, ruleMayAsk, let owner, chosenDestinations[ObjectIdentifier(download)] == nil,
           let url = download.originalRequest?.url,
           let rule = DownloadHandoff.firstMatch(url, appliesToLinks: false, filename: name,
                                                 isPrivate: !(download.webView?.configuration.websiteDataStore.isPersistent ?? false), in: owner.profile) {
            var handoff = DownloadHandoff.Request(url: url, referrer: download.originalRequest?.value(forHTTPHeaderField: "Referer").flatMap { URL(string: $0) },
                                                  pageOrigin: startedAt ?? SiteOrigin.of(owner.url ?? download.webView?.url),
                                                  filename: DownloadTokens.filename(for: url, suggested: name),
                                                  space: Library.shared.space(owner.spaceID)?.name ?? "",
                                                  dataStore: download.webView?.configuration.websiteDataStore,
                                                  isPrivate: Self.isPrivate(download),
                                                  window: window, tab: owner)
            let decision = await DownloadHandoff.decide(rule, request: handoff, tab: owner, forDownload: true)
            handoff.place = decision.place
            switch decision.gate {
            case .handOff:
                if DownloadHandoff.defersToSavedFile(rule, forDownload: true) {
                    fileHandoff = PendingFileHandoff(rule: rule, request: handoff)
                } else {
                    let outcome = await DownloadHandoff.perform(rule, request: handoff)
                    if outcome == .handedOff {
                        items.removeAll { $0.download === download }
                        changed.send(nil)
                        Task { _ = await download.cancel() }
                        return nil
                    }
                    if case .failed = outcome { DownloadHandoff.report(outcome, rule: rule, request: handoff) }
                    // Matched but not taken: saved as usual.
                }
            case .browser:
                break
            case .cancel:
                // Don't Allow: nothing saved, row removed.
                items.removeAll { $0.download === download }
                changed.send(nil)
                Task { _ = await download.cancel() }
                return nil
            }
        }
        var replacing: URL?
        var opensWhenFinished = false
        if let folder = Self.aiAppsFolder(for: item(for: download)) {
            // AI apps' files stay in their profile's own folder, and no one is asked where.
            let chosen = chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
            destination = Self.uniqueDestination(for: chosen?.lastPathComponent ?? name, in: folder, avoiding: inProgress)
        } else if let chosen = chosenDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            destination = chosen
            // A name chosen ahead (an extension's download with "overwrite") only ever replaces a plain file there,
            // never a folder or a link: anything else there keeps its place and the download takes a new name.
            if FileManager.default.fileExists(atPath: chosen.path) {
                if Self.isPlainFile(chosen) { replacing = chosen } else {
                    destination = Self.uniqueDestination(for: chosen.lastPathComponent, avoiding: inProgress)
                }
            }
        } else if fileHandoff == nil, let url = download.originalRequest?.url,
                  let place = Self.rulePlace(url: url, filename: name, response: response, download: download, avoiding: inProgress) {
            // A file-type rule decides the location: its folder, or the normal one for an Open rule. Destinations
            // never stop the download.
            destination = place.destination
            opensWhenFinished = place.openWhenFinished
        } else if fileHandoff == nil, Self.asksWhereToSave {
            guard let chosen = await askWhere(name: destination.lastPathComponent, in: window) else {
                // Cancelled in the sheet: no download, and nothing left in the list.
                items.removeAll { $0.download === download }
                changed.send(nil)
                return nil
            }
            destination = chosen
            // The sheet already asked about replacing a file of the same name; it's replaced when this one is done.
            if FileManager.default.fileExists(atPath: chosen.path) { replacing = chosen }
        }
        let shownName = destination.lastPathComponent
        if let replacing {
            destination = replacing.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(replacing.lastPathComponent).download")
        }
        if let item = item(for: download) {
            item.filename = shownName
            item.replaces = replacing
            item.destination = destination
            // The folder the file is going into, said if WebKit can't make it there: WebKit's own error names neither
            // the folder nor what's wrong with it (#588).
            item.placeProblem = Self.folderProblem(destination.deletingLastPathComponent())
            item.opensWhenFinished = opensWhenFinished
            item.fileHandoff = fileHandoff
            changed.send(item)
            started.send((item, window))
        }
        return destination
    }

    /// A file Zigzag already has in hand (the PDF viewer's), saved as any download is: into Downloads, or where you
    /// choose with that setting on; marked as downloaded; listed; and flown into the Downloads button. Nil when you
    /// cancel the save sheet.
    @discardableResult
    func save(_ data: Data, named name: String, from source: URL?, isPrivate: Bool, profile: UUID = Profile.defaultID, window: NSWindow?) async throws -> DownloadItem? {
        var destination = Self.uniqueDestination(for: name)
        if Self.asksWhereToSave {
            guard let chosen = await askWhere(name: destination.lastPathComponent, in: window) else { return nil }
            destination = chosen
        }
        try data.write(to: destination, options: .atomic)
        Self.markDownloaded(destination, from: source, page: source, isPrivate: isPrivate)
        let item = DownloadItem(filename: destination.lastPathComponent, sourceURL: source, isPrivate: isPrivate, profile: profile)
        item.destination = destination
        item.state = .finished
        item.fractionCompleted = 1
        item.totalBytes = Int64(data.count)
        item.completedBytes = item.totalBytes
        items.insert(item, at: 0)
        started.send((item, window))
        changed.send(item)
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        return item
    }

    /// The standard save sheet, on the window the download came from.
    private func askWhere(name: String, in window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = lastFolder ?? Self.folder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        lastFolder = url.deletingLastPathComponent()
        return url
    }

    /// A regular file, not a folder, a package or a link (looked at without following it).
    static func isPlainFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && values.isPackage != true
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let pending = pendingExtensionInstalls.removeValue(forKey: ObjectIdentifier(download)) {
            offerExtensionInstall(pending)
            return
        }
        guard let item = item(for: download) else { return }
        helpers[item.id] = nil
        // Done: now it takes the place of the file it replaces.
        if let target = item.replaces, let temporary = item.destination {
            // Rechecked, since the folder may have changed during the download. A replaced file goes to the Trash;
            // anything else in the way gets a unique name beside it instead of keeping the hidden temp name.
            let fileManager = FileManager.default
            if Self.isPlainFile(target), (try? fileManager.trashItem(at: target, resultingItemURL: nil)) != nil,
               (try? fileManager.moveItem(at: temporary, to: target)) != nil {
                item.destination = target
            } else {
                let beside = Self.uniqueDestination(for: target.lastPathComponent)
                if (try? fileManager.moveItem(at: temporary, to: beside)) != nil { item.destination = beside }
            }
            item.replaces = nil
        }
        item.state = .finished
        item.fractionCompleted = 1
        item.progressObservation = nil
        // The file's real size: a download that had to start over after a pause counts its first bytes twice.
        if let path = item.destination?.path, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
            item.totalBytes = size
            item.completedBytes = size
        }
        if let destination = item.destination {
            Self.markDownloaded(destination, from: item.sourceURL, page: download.originalRequest?.mainDocumentURL, isPrivate: item.isPrivate)
            // Bounce the Downloads stack in the Dock, like every Mac browser.
            if !item.isForAIApps { DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path) }
        }
        changed.send(item)
        if item.opensWhenFinished { openWhenFinished(item) }
        if let handoff = item.fileHandoff {
            item.fileHandoff = nil
            guard let file = item.destination else {
                DownloadHandoff.report(.failed(String(localized: "The download didn’t finish.", comment: "Why a File handoff didn't run: the download failed or was cancelled.")),
                                       rule: handoff.rule, request: handoff.request)
                return
            }
            Task { @MainActor in
                let outcome = await DownloadHandoff.perform(handoff.rule, request: handoff.request, file: file)
                if case .failed = outcome { DownloadHandoff.report(outcome, rule: handoff.rule, request: handoff.request) }
            }
        }
}

    /// A package arrived: verify and unpack it, offer it with the store's own sheet in the profile it came from,
    /// and delete the download's own copy either way. The store keeps its staged copy until it's installed or
    /// declined.
    private func offerExtensionInstall(_ pending: PendingExtensionInstall) {
        let file = pending.file
        let profile = Profiles.shared.profile(pending.profile)
        let window = pending.window ?? WindowManager.shared.keyController?.window
        guard #available(macOS 15.4, *), let host = window?.contentView else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        Task { @MainActor in
            // Read once: the bytes checked against AMO's sha256 are the bytes unpacked.
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            guard let data, ExtensionStore.matchesPublishedHash(data, sha256: pending.hash) else {
                Self.noticeCouldNotAdd(String(localized: "This extension’s package doesn’t match the one the Firefox Add-ons store publishes, so it wasn’t installed.",
                                              comment: "Shown when an .xpi downloaded from addons.mozilla.org doesn't match the sha256 the store publishes for it."), in: host)
                return
            }
            let prepared = await ExtensionStore.prepareInstallXPI(data: data, storeID: pending.storeID)
            switch prepared {
            case .failure(let error):
                Self.noticeCouldNotAdd(error.message, in: host)
            case .success(let install):
                ExtensionSheet.offer(install, in: profile, over: host, onInstalled: { result in
                    if case .failure(let error) = result { Self.noticeCouldNotAdd(error.message, in: host) }
                })
            }
        }
    }

    static func noticeCouldNotAdd(_ message: String, in host: NSView) {
        ConfirmSheet.notice(in: host,
                            title: String(localized: "Couldn’t add this extension",
                                          comment: "Title of the notice when a picked extension file can't be added."),
                            message: message)
    }

    /// Marks a finished file as downloaded from the web by Zigzag, as Safari does. WebKit marks it as from the
    /// internet but names no app, so opening it asked about a file "created by the app (null)". A private window's
    /// download names no addresses.
    static func markDownloaded(_ file: URL, from source: URL?, page: URL?, isPrivate: Bool) {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Zigzag",
            kLSQuarantineAgentBundleIdentifierKey as String: Bundle.main.bundleIdentifier ?? "app.zigzag",
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if !isPrivate {
            if let source { properties[kLSQuarantineDataURLKey as String] = source }
            if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        }
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
        // Where it came from, as Safari and Chrome note it: Finder's Get Info shows it under Where From. macOS keeps
        // no addresses in the quarantine note above, so this is where they're kept.
        if !isPrivate {
            let froms = [source, page].compactMap { $0?.absoluteString }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !froms.isEmpty, let plist = try? PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0) {
                _ = plist.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0) }
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // A package that never arrived leaves no temporary file behind.
        if let pending = pendingExtensionInstalls.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: pending.file)
        }
        // A failed or cancelled download never reaches the destination decision; clear its state here.
        origins.removeValue(forKey: ObjectIdentifier(download))
        windows.removeValue(forKey: ObjectIdentifier(download))
        chosenDestinations.removeValue(forKey: ObjectIdentifier(download))
        addonsFiles.removeValue(forKey: ObjectIdentifier(download))
        guard let item = item(for: download) else { return }
        // Pausing cancels the transfer underneath; the row stays paused, with what's needed to go on.
        if item.state == .paused { return }
        // A File handoff never runs for a failed or cancelled download.
        failFileHandoff(item)
        helpers[item.id] = nil
        item.resumeData = resumeData
        item.progressObservation = nil
        // Gave up (not paused): the hidden file goes, and the file it would have replaced stays as it was.
        if item.replaces != nil, resumeData == nil, let temporary = item.destination {
            try? FileManager.default.removeItem(at: temporary)
        }
        if item.state != .cancelled {
            item.state = .failed
            // The folder's own problem first: WebKit's error for a folder that isn't there says neither its name nor
            // why, while this says both (#588).
            item.failure = Self.failure(error, placeProblem: item.placeProblem)
            Diagnostics.note("Download failed", site: item.sourceURL?.host(), Diagnostics.describe(error as NSError), isPrivate: item.isPrivate)
        }
        changed.send(item)
    }
}
