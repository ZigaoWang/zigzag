import AppKit
import WebKit

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
    let sourceURL: URL?
    /// Bytes a second, smoothed over the last few seconds, for "time left".
    fileprivate(set) var speed: Double = 0
    fileprivate var lastSample: (at: Date, bytes: Int64)?

    /// Why it stopped, in a few plain words, when it failed ("the connection dropped").
    fileprivate(set) var failure: String?

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

    init(filename: String, sourceURL: URL?, isPrivate: Bool) {
        self.filename = filename
        self.sourceURL = sourceURL
        self.isPrivate = isPrivate
    }
}

/// Files downloaded from pages. Saved straight to ~/Downloads, no questions asked.
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
    }

    override init() {
        super.init()
        let saved = JSONStore.load([Saved].self, from: Paths.downloads) ?? []
        items = saved.filter { FileManager.default.fileExists(atPath: $0.destination.path) }.map { entry in
            let item = DownloadItem(filename: entry.filename, sourceURL: entry.sourceURL, isPrivate: false)
            item.destination = entry.destination
            item.totalBytes = entry.totalBytes
            item.started = entry.started
            if entry.paused == true {
                item.state = .paused
                item.resumeData = entry.resumeData
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
        let kept = items.filter { !$0.isPrivate && [.finished, .paused].contains($0.state) }.prefix(50).compactMap { item in
            item.destination.map {
                Saved(filename: item.filename, destination: $0, sourceURL: item.sourceURL, started: item.started, totalBytes: item.totalBytes,
                      completedBytes: item.completedBytes, paused: item.state == .paused ? true : nil, resumeData: item.state == .paused ? item.resumeData : nil)
            }
        }
        JSONStore.save(Array(kept), to: Paths.downloads)
    }

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    /// What a window lists: a private window its own downloads, a normal window everything else.
    func items(isPrivate: Bool) -> [DownloadItem] { items.filter { $0.isPrivate == isPrivate } }

    /// The last private window closed: its finished downloads leave the list (the files stay in Downloads).
    func forgetPrivate() {
        let before = items.count
        items.filter { $0.isPrivate && $0.state == .paused }.forEach(discardPartial)
        items.removeAll { $0.isPrivate && $0.state != .downloading }
        if items.count != before { changed.send(nil) }
    }
    var overallProgress: Double {
        let active = items.filter { $0.state == .downloading }
        guard !active.isEmpty else { return 1 }
        return active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
    }

    /// Where downloads go: Downloads unless you picked another folder in Settings (and it's still there).
    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "DownloadFolder"), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            UserDefaults.standard.set(newValue.standardizedFileURL == downloads.standardizedFileURL ? nil : newValue.path, forKey: "DownloadFolder")
        }
    }

    /// Ask with a save sheet each time instead of saving straight to Downloads.
    static var asksWhereToSave: Bool {
        get { UserDefaults.standard.bool(forKey: "DownloadsAskWhere") }
        set { UserDefaults.standard.set(newValue, forKey: "DownloadsAskWhere") }
    }

    /// A download got its file and is under way: the window it came from shows it leaving for Downloads.
    let started = Signal<(DownloadItem, NSWindow?)>()
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    /// The folder the last save sheet was pointed at, to start there next time.
    private var lastFolder: URL?

    /// Where a download was already told to go (Save Page As picked the place), so it isn't asked again.
    private var chosenDestinations: [ObjectIdentifier: URL] = [:]

    func track(_ download: WKDownload, window: NSWindow?, saveTo destination: URL? = nil) {
        if let destination { chosenDestinations[ObjectIdentifier(download)] = destination }
        download.delegate = self
        if let window { windows[ObjectIdentifier(download)] = window }
        let isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download", sourceURL: download.originalRequest?.url,
                                isPrivate: isPrivate)
        item.dataStore = download.webView?.configuration.websiteDataStore
        attach(download, to: item)
        items.insert(item, at: 0)
        changed.send(item)
    }

    /// Follows a download's progress on its row: the first attempt, or the same row after a resume.
    private func attach(_ download: WKDownload, to item: DownloadItem) {
        item.download = download
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak self, weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
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

    /// A paused download given up on: the part already downloaded goes too.
    private func discardPartial(_ item: DownloadItem) {
        item.resumeData = nil
        if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
    }

    func cancel(_ item: DownloadItem) {
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

    /// Goes on with a paused download in the same row: from where it stopped, or from the start when the server
    /// doesn't allow picking up partway.
    func resume(_ item: DownloadItem) {
        guard item.state == .paused, let webView = webView(for: item) else { return }
        item.state = .downloading
        changed.send(item)
        let attach: (WKDownload) -> Void = { [weak self] download in
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
    private func webView(for item: DownloadItem) -> WKWebView? {
        if let open = WindowManager.shared.controllers.first(where: { $0.tabManager.isPrivate == item.isPrivate })?.selectedWebView,
           item.dataStore == nil || open.configuration.websiteDataStore === item.dataStore {
            return open
        }
        let configuration = WKWebViewConfiguration()
        if let store = item.dataStore { configuration.websiteDataStore = store } else if item.isPrivate { return nil }
        let hidden = WKWebView(frame: .zero, configuration: configuration)
        helpers[item.id] = hidden
        return hidden
    }

    private var helpers: [UUID: WKWebView] = [:]

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fetches a finished file again after it was deleted or moved, in the same place in the list.
    func downloadAgain(_ item: DownloadItem, in webView: WKWebView) {
        guard let url = item.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated {
                self?.items.removeAll { $0 === item }
                self?.track(download, window: webView.window)
            }
        }
    }

    /// Starts a failed or cancelled download again: from where it stopped when the server allows, else from the
    /// start. The new attempt takes the old row's place.
    func retry(_ item: DownloadItem, in webView: WKWebView) {
        let finish: (WKDownload) -> Void = { [weak self] download in
            MainActor.assumeIsolated {
                self?.items.removeAll { $0 === item }
                self?.track(download, window: webView.window)
            }
        }
        if let data = item.resumeData {
            webView.resumeDownload(fromResumeData: data, completionHandler: finish)
        } else if let url = item.sourceURL, canRetry(item) {
            webView.startDownload(using: URLRequest(url: url), completionHandler: finish)
        }
    }

    /// What went wrong, the way you'd say it.
    static func reason(for error: Error) -> String? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet: return "You’re offline"
            case NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost: return "The connection dropped"
            case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotOpenFile:
                return "Couldn’t save it in that folder"
            case NSURLErrorBadServerResponse, NSURLErrorResourceUnavailable, NSURLErrorFileDoesNotExist: return "The site couldn’t send it"
            case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile: return "The site refused it"
            default: break
            }
        }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) {
            return "Not enough space on your Mac"
        }
        return nil
    }

    /// A file the page made itself (blob:, data:) can't be fetched again.
    var canRetry: (DownloadItem) -> Bool {
        { $0.resumeData != nil || ["http", "https"].contains($0.sourceURL?.scheme?.lowercased() ?? "") }
    }

    func remove(_ item: DownloadItem) {
        if item.state == .downloading { cancel(item) }
        if item.state == .paused { discardPartial(item) }
        items.removeAll { $0 === item }
        changed.send(nil)
    }

    func clearFinished(isPrivate: Bool) {
        // Paused downloads stay, like ones still running: Clear never throws away a half-finished file.
        items.removeAll { ![.downloading, .paused].contains($0.state) && $0.isPrivate == isPrivate }
        changed.send(nil)
    }

    /// A free name in Downloads, also avoiding names given to downloads still in progress (their files don't
    /// exist yet), so two "report.pdf"s started together don't collide.
    static func uniqueDestination(for filename: String, avoiding taken: Set<String> = []) -> URL {
        let folder = Self.folder
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
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
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let inProgress = Set(items.filter { $0.state == .downloading }.compactMap { $0.destination?.path })
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        var destination = Self.uniqueDestination(for: name, avoiding: inProgress)
        let window = windows.removeValue(forKey: ObjectIdentifier(download))
        if let url = download.originalRequest?.url, let earlier = restarts.removeValue(forKey: url) {
            // A paused download started over: it replaces its own partial file.
            try? FileManager.default.removeItem(at: earlier)
            return earlier
        }
        if let chosen = chosenDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: chosen)
            destination = chosen
        } else if Self.asksWhereToSave {
            guard let chosen = await askWhere(name: destination.lastPathComponent, in: window) else {
                // Cancelled in the sheet: no download, and nothing left in the list.
                items.removeAll { $0.download === download }
                changed.send(nil)
                return nil
            }
            destination = chosen
            // The sheet already asked about replacing a file of the same name.
            try? FileManager.default.removeItem(at: chosen)
        }
        if let item = item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
            changed.send(item)
            started.send((item, window))
        }
        return destination
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

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        helpers[item.id] = nil
        item.state = .finished
        item.fractionCompleted = 1
        item.progressObservation = nil
        // The file's real size: a download that had to start over after a pause counts its first bytes twice.
        if let path = item.destination?.path, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
            item.totalBytes = size
            item.completedBytes = size
        }
        if let destination = item.destination {
            // Bounce the Downloads stack in the Dock, like every Mac browser.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        }
        changed.send(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        // Pausing cancels the transfer underneath; the row stays paused, with what's needed to go on.
        if item.state == .paused { return }
        helpers[item.id] = nil
        item.resumeData = resumeData
        item.progressObservation = nil
        if item.state != .cancelled {
            item.state = .failed
            item.failure = Self.reason(for: error)
        }
        changed.send(item)
    }
}
