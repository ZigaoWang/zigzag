import AppKit
import WebKit

final class DownloadItem {
    enum State: Equatable { case downloading, finished, failed, cancelled }

    let id = UUID()
    fileprivate(set) var filename: String
    fileprivate(set) var destination: URL?
    fileprivate(set) var state: State = .downloading
    fileprivate(set) var fractionCompleted: Double = 0
    fileprivate(set) var totalBytes: Int64 = 0
    fileprivate(set) var completedBytes: Int64 = 0
    let started = Date()
    fileprivate weak var download: WKDownload?
    fileprivate var progressObservation: NSKeyValueObservation?
    fileprivate var resumeData: Data?
    fileprivate let sourceURL: URL?
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

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    /// What a window lists: a private window its own downloads, a normal window everything else.
    func items(isPrivate: Bool) -> [DownloadItem] { items.filter { $0.isPrivate == isPrivate } }

    /// The last private window closed: its finished downloads leave the list (the files stay in Downloads).
    func forgetPrivate() {
        let before = items.count
        items.removeAll { $0.isPrivate && $0.state != .downloading }
        if items.count != before { changed.send(nil) }
    }
    var overallProgress: Double {
        let active = items.filter { $0.state == .downloading }
        guard !active.isEmpty else { return 1 }
        return active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
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

    func track(_ download: WKDownload, window: NSWindow?) {
        download.delegate = self
        if let window { windows[ObjectIdentifier(download)] = window }
        let isPrivate = download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download", sourceURL: download.originalRequest?.url,
                                isPrivate: isPrivate)
        item.download = download
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak self, weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let item else { return }
                item.fractionCompleted = fraction
                item.completedBytes = completed
                item.totalBytes = total
                self?.changed.send(item)
            }
        }
        items.insert(item, at: 0)
        changed.send(item)
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { [weak self] data in
            MainActor.assumeIsolated {
                item.resumeData = data
                item.state = .cancelled
                self?.changed.send(item)
            }
        }
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: DownloadItem) {
        guard let url = item.destination, item.state == .finished else { return }
        NSWorkspace.shared.open(url)
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

    /// A file the page made itself (blob:, data:) can't be fetched again.
    var canRetry: (DownloadItem) -> Bool {
        { $0.resumeData != nil || ["http", "https"].contains($0.sourceURL?.scheme?.lowercased() ?? "") }
    }

    func remove(_ item: DownloadItem) {
        if item.state == .downloading { cancel(item) }
        items.removeAll { $0 === item }
        changed.send(nil)
    }

    func clearFinished(isPrivate: Bool) {
        items.removeAll { $0.state != .downloading && $0.isPrivate == isPrivate }
        changed.send(nil)
    }

    /// A free name in Downloads, also avoiding names given to downloads still in progress (their files don't
    /// exist yet), so two "report.pdf"s started together don't collide.
    static func uniqueDestination(for filename: String, avoiding taken: Set<String> = []) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
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
        if Self.asksWhereToSave {
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
        panel.directoryURL = lastFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
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
        item.state = .finished
        item.fractionCompleted = 1
        item.progressObservation = nil
        if let destination = item.destination {
            // Bounce the Downloads stack in the Dock, like every Mac browser.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        }
        changed.send(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.resumeData = resumeData
        item.progressObservation = nil
        if item.state != .cancelled { item.state = .failed }
        changed.send(item)
    }
}
