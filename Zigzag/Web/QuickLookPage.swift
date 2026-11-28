import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

/// Office and Apple documents in a tab (#566), read-only, in macOS's own Quick Look view: zigzag://quicklook?url=<the
/// file>. The address bar shows the file's own address. A local file opens as it is; one from the web is fetched
/// again with the tab's cookies, as the PDF viewer does, into a private temporary folder, marked as downloaded, and
/// shown from there. A file sent as an attachment downloads as before.
///
/// The page under the viewer is a blank of Zigzag's own that runs nothing, so Back, Forward, history and reopening
/// work as for any page. Quick Look reads the file out of process, in macOS's sandboxed previewers, exactly as
/// Finder's preview does: Zigzag only hands it the file.
@MainActor
enum QuickLookPage {
    nonisolated static let host = "quicklook"
    /// Past this, a file from the web downloads as it would without the viewer.
    nonisolated static let maxBytes = 200 << 20

    /// The documents shown here, by name: Word, Excel, PowerPoint, Pages, Numbers, Keynote and rich text.
    nonisolated static let extensions: Set<String> = ["doc", "docx", "dotx", "xls", "xlsx", "xltx", "ppt", "pptx", "potx", "ppsx",
                                                      "pages", "numbers", "key", "rtf", "rtfd"]
    /// The same, as the web sends them, with the name each is saved under when its address has none.
    nonisolated static let mimeTypes: [String: String] = [
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.apple.pages": "pages", "application/x-iwork-pages-sffpages": "pages",
        "application/vnd.apple.numbers": "numbers", "application/x-iwork-numbers-sffnumbers": "numbers",
        "application/vnd.apple.keynote": "key", "application/x-iwork-keynote-sffkey": "key",
        "application/rtf": "rtf", "text/rtf": "rtf",
    ]
    /// Types a server sends any file as: the name at the address says what it is.
    nonisolated static let genericMimeTypes: Set<String> = ["", "application/octet-stream", "binary/octet-stream", "application/x-download",
                                                            "application/download", "application/zip", "application/x-zip-compressed"]

    nonisolated static func isDocumentName(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    nonisolated static func documentType(_ type: UTType) -> Bool {
        type.preferredFilenameExtension.map { extensions.contains($0.lowercased()) } ?? false
    }

    // MARK: Addresses

    /// Where the viewer shows a file. `name`: what a file from the web is called, when its address doesn't say.
    nonisolated static func address(for source: URL, name: String? = nil) -> URL {
        FilePages.address(host: host, for: source, extra: name.map { [("name", $0)] } ?? [])
    }

    nonisolated static func source(of page: URL?) -> URL? {
        FilePages.source(of: page, host: host, schemes: ["file", "http", "https"])
    }

    /// The file's name: a local file's own, else the one the server gave, else the address's, always ending in the
    /// document's extension, so Quick Look knows what it is.
    nonisolated static func name(of page: URL?) -> String {
        guard let source = source(of: page) else { return "" }
        let given = FilePages.value("name", in: page, host: host).map(DownloadManager.safeFilename)
        let own = source.lastPathComponent.removingPercentEncoding ?? source.lastPathComponent
        if source.isFileURL { return own }
        return [given, own].compactMap { $0 }.first { isDocumentName($0) } ?? given ?? (own.isEmpty || own == "/" ? "Document" : own)
    }

    /// A local file that opens here when a tab goes to it.
    nonisolated static func showsFile(_ url: URL) -> Bool {
        url.isFileURL && isDocumentName(url.path)
    }

    /// Whether a web page's response is a document for the viewer: a whole reply to a GET, not an attachment, not
    /// past `maxBytes`, sent as one of the types or as any file at a document's address. The name it's saved under,
    /// or nil.
    nonisolated static func shows(_ response: URLResponse, isGet: Bool) -> String? {
        guard isGet, let url = response.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if let http = response as? HTTPURLResponse {
            guard http.statusCode == 200 else { return nil }
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if disposition.hasPrefix("attachment") { return nil }
        }
        if response.expectedContentLength > Int64(maxBytes) { return nil }
        let mime = (response.mimeType ?? "").lowercased()
        let suggested = HistoryStore.suggestedName(of: response).map(DownloadManager.safeFilename)
        let named = [suggested, url.lastPathComponent].compactMap { $0 }.first(where: isDocumentName)
        if let ext = mimeTypes[mime] {
            let base = (suggested ?? url.lastPathComponent).isEmpty ? "Document" : (suggested ?? url.lastPathComponent)
            return named ?? (base == "/" ? "Document" : base) + "." + ext
        }
        return genericMimeTypes.contains(mime) ? named : nil
    }

    // MARK: Serving

    /// The page under the viewer: the file's name as its title, the viewer's color, nothing else.
    static func serve(_ task: any WKURLSchemeTask, in webView: WKWebView) {
        guard let url = task.request.url, source(of: url) != nil else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let page = "<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta http-equiv=\"Content-Security-Policy\" content=\"\(FolderPage.policy)\">\n"
            + "<title>\(MarkdownHTML.escape(name(of: url)))</title>\n<style>\n\(PageStyle.variables(theme: HistoryPage.theme(for: webView)))"
            + "html { background: var(--bg); }</style>\n</head>\n<body></body>\n</html>\n"
        let data = Data(page.utf8)
        let headers = ["Content-Type": "text/html; charset=utf-8", "Content-Length": String(data.count), "Content-Security-Policy": FolderPage.policy,
                       "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: Copies of web files

    /// Where copies of web files wait while they're shown: Zigzag's own temporary folder, readable only by you.
    nonisolated static var copies: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Quick Look", isDirectory: true)
    }

    /// The bytes written into a folder of their own under `copies`. Copies left behind (Zigzag quit while showing
    /// one) go after a day.
    nonisolated static func writeCopy(_ data: Data, named name: String) -> URL? {
        let manager = FileManager.default
        let root = copies
        if let old = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < Date().addingTimeInterval(-86_400) {
                try? manager.removeItem(at: folder)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let file = folder.appendingPathComponent(DownloadManager.safeFilename(name))
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            try? manager.removeItem(at: folder)
            return nil
        }
    }
}

/// The document in Quick Look's own view, under a slim header: its name, Open in its app, and Show in Finder for a
/// file on your Mac or Download for one from the web.
@MainActor
final class QuickLookViewerView: NSView {
    let source: URL
    let name: String
    private let isPrivate: Bool
    private let profile: UUID
    /// The file Quick Look shows: the local file itself, or the copy of a web file.
    private(set) var file: URL?
    /// A web file's bytes, to download as they came.
    private(set) var data: Data?
    private(set) var preview: QLPreviewView?
    private var loading: Task<Void, Never>?

    private let header = HeaderView()
    private let edge = ColorView(color: Tokens.Color.separator)
    private let icon = NSImageView()
    private let title: Label
    private let openButton = PillButton(title: "", style: .quiet)
    private let placeButton: PillButton
    private let spinner = Spinner()
    private let message = Label(String(localized: "This document couldn’t be shown.", comment: "Shown in a tab in place of an Office or Apple document Quick Look couldn't open, under the bar with its name."),
                                font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    private var app: URL?

    /// Download for a web file with no bytes in hand (its fetch failed): the tab downloads it from its page.
    var onDownloadFromPage: (() -> Void)?

    static let headerHeight = Tokens.Page.controlHeight + Tokens.Space.x2 * 2

    init(source: URL, name: String, isPrivate: Bool, profile: UUID = Profile.defaultID) {
        self.source = source
        self.name = name
        self.isPrivate = isPrivate
        self.profile = profile
        title = Label(name, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        placeButton = source.isFileURL
            ? PillButton(title: String(localized: "Show in Finder", comment: "Button at the top of an Office or Apple document shown in a tab, for a file on the Mac."), style: .quiet)
            : PillButton(title: String(localized: "Download", comment: "Button at the top of an Office or Apple document from the web shown in a tab: saves it to Downloads."), symbol: "arrow.down.circle", style: .quiet)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = cgColor(Tokens.Color.surface)

        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = name
        icon.imageScaling = .scaleProportionallyDown
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        icon.image = source.isFileURL ? NSWorkspace.shared.icon(forFile: source.path) : NSWorkspace.shared.icon(for: type)
        app = NSWorkspace.shared.urlForApplication(toOpen: type)
        if source.isFileURL, let own = NSWorkspace.shared.urlForApplication(toOpen: source) { app = own }
        if let app {
            let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            openButton.title = String(localized: "Open in \(appName)", comment: "Button at the top of an Office or Apple document shown in a tab. The placeholder is the app that opens it, like “Pages” or “Microsoft Word”.")
        }
        openButton.isHidden = app == nil
        openButton.onClick = { [weak self] _ in self?.openInApp() }
        placeButton.onClick = { [weak self] _ in
            guard let self else { return }
            if self.source.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([self.source]) } else { self.download() }
        }
        [icon, title, openButton, placeButton, edge].forEach { header.addSubview($0) }
        addSubview(header)
        message.alignment = .center
        message.isHidden = true
        addSubview(message)
        addSubview(spinner)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.preview == nil, self.message.isHidden else { return }
            self.spinner.startAnimation(nil)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = cgColor(Tokens.Color.surface)
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        edge.frame = NSRect(x: 0, y: h - Tokens.Metric.hairline, width: bounds.width, height: Tokens.Metric.hairline)
        let pad = Tokens.Space.x4, control = Tokens.Page.controlHeight, y = (h - control) / 2
        // The last button's words end as far in from the edge as the name starts.
        var right = bounds.width - pad + placeButton.textInset
        for button in [placeButton, openButton] where !button.isHidden {
            let width = button.fittingWidth
            button.frame = NSRect(x: right - width, y: y, width: width, height: control)
            right = button.frame.minX - Tokens.Space.x1
        }
        let side = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (h - side) / 2, width: side, height: side)
        let x = icon.frame.maxX + Tokens.Space.x2 - Label.inset
        title.frame = NSRect(x: x, y: title.centeredY(in: h), width: max(0, right - Tokens.Space.x2 - x), height: title.lineHeight)
        let below = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        preview?.frame = below
        message.frame = NSRect(x: pad, y: below.midY - message.lineHeight / 2, width: max(0, bounds.width - pad * 2), height: message.lineHeight)
        let s: CGFloat = 24
        spinner.frame = NSRect(x: (bounds.width - s) / 2, y: below.midY - s / 2, width: s, height: s)
    }

    // MARK: Loading

    /// Fetches a web file with the page's cookies, or checks a local one is there, then shows it.
    func load(from webView: WKWebView) {
        loading?.cancel()
        let source = source, name = name, isPrivate = isPrivate
        let userAgent = webView.customUserAgent
        loading = Task { [weak self, weak webView] in
            var shown: URL?
            if source.isFileURL {
                shown = await Task.detached { FileManager.default.isReadableFile(atPath: source.path) ? source : nil }.value
            } else if let webView, let bytes = await PDFViewerView.fetch(source, from: webView, userAgent: userAgent, limit: QuickLookPage.maxBytes) {
                self?.data = bytes
                shown = await Task.detached { QuickLookPage.writeCopy(bytes, named: name) }.value
                // Marked as from the web, as a download is, before anything reads it.
                if let shown { DownloadManager.markDownloaded(shown, from: source, page: source, isPrivate: isPrivate) }
            }
            guard let self, !Task.isCancelled else {
                if let shown, !source.isFileURL { try? FileManager.default.removeItem(at: shown.deletingLastPathComponent()) }
                return
            }
            self.show(shown)
        }
    }

    private func show(_ file: URL?) {
        spinner.stopAnimation(nil)
        self.file = file
        guard let file, let preview = QLPreviewView(frame: .zero, style: .normal) else {
            message.isHidden = false
            return
        }
        // The tab can move to another window, and closes it itself (`close`).
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
        preview.previewItem = file as NSURL
        self.preview = preview
        addSubview(preview, positioned: .below, relativeTo: header)
        needsLayout = true
        if let window, window.firstResponder === self || window.firstResponder === window { window.makeFirstResponder(preview) }
    }

    /// Typing goes to the document, as it went to the page.
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let preview { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(preview) } }
        return true
    }

    /// Ends Quick Look's look at the file, and drops a web file's copy unless an app was handed it.
    func close() {
        loading?.cancel()
        loading = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        if !source.isFileURL, let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
    }

    /// What's on screen, for the tab's picture: the header, over Quick Look's own drawing where it gives one.
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Actions

    /// A local file opens in its app as from Finder. A web file is downloaded first, so what you change in the app
    /// is kept in Downloads, not in a copy that goes away.
    private func openInApp() {
        guard let app else { return }
        if source.isFileURL {
            NSWorkspace.shared.open([source], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let saved = await self.save() else { return }
            _ = try? await NSWorkspace.shared.open([saved], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Downloaded like any file: the bytes as they came, into Downloads with the usual flight to the Downloads button.
    func download() {
        guard data != nil else { onDownloadFromPage?(); return }
        Task { @MainActor [weak self] in _ = await self?.save() }
    }

    private func save() async -> URL? {
        guard let data, let window else { return nil }
        let controller = WindowManager.shared.controller(for: window)
        do {
            return try await DownloadManager.shared.save(data, named: name, from: source, isPrivate: isPrivate, profile: profile, window: window)?.destination
        } catch {
            if let controller { Toast.show(SaveFailure.message(String(localized: "Couldn’t download the document", comment: "Toast when downloading an Office or Apple document shown in a tab fails; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle", duration: 4, in: controller) }
            return nil
        }
    }

    #if DEBUG
    var debugTitles: [String] { [title.stringValue] + [openButton, placeButton].filter { !$0.isHidden }.map(\.title) }
    #endif

    /// The bar on the page's surface.
    private final class HeaderView: NSView {
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = cgColor(Tokens.Color.surface) }
    }
}
