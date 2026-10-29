import AppKit
import PDFKit
import WebKit

/// PDFs in Zigzag's own viewer: Apple's PDFKit (Preview's engine) for the pages, with our controls in a pill at the
/// bottom: the pages down the side, where you are, zoom, and saving.
///
/// WebKit still loads the PDF underneath, so Back, Forward, history and reopening after a restart work as for any
/// page. The viewer fetches the same file with the page's cookies (PDFs behind a sign-in) and covers WebKit's own;
/// if that fails, WebKit's viewer simply stays.
@MainActor
final class PDFViewerView: NSView, PDFViewDelegate {
    let url: URL
    private(set) var data: Data?
    let pdfView = ZigzagPDFView()
    private let thumbnails = PDFThumbnailView()
    private let thumbnailsEdge = ColorView(color: Tokens.Color.separator)
    private let bar = FloatingPanelView()
    private let sidebarButton = IconButton(symbol: "sidebar.left", size: Tokens.Space.x7Height, toolTip: "Pages")
    private let pageLabel = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let zoomOutButton = IconButton(symbol: "minus.magnifyingglass", size: Tokens.Space.x7Height, toolTip: "Zoom Out")
    private let zoomInButton = IconButton(symbol: "plus.magnifyingglass", size: Tokens.Space.x7Height, toolTip: "Zoom In")
    private let saveButton = IconButton(symbol: "arrow.down.circle", size: Tokens.Space.x7Height, toolTip: "Save PDF")
    private var showsThumbnails = false
    /// Links in the PDF open like links on a page.
    var onOpenLink: ((URL) -> Void)?
    /// Swipes to go back or forward, handed to the page underneath.
    var onSwipe: ((NSEvent) -> Bool)? {
        get { pdfView.onSwipe }
        set { pdfView.onSwipe = newValue }
    }

    private static let thumbnailsWidth: CGFloat = 132

    init(url: URL, document: PDFDocument, data: Data) {
        self.url = url
        self.data = data
        super.init(frame: .zero)
        wantsLayer = true
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.delegate = self
        pdfView.backgroundColor = Self.backdrop
        addSubview(pdfView)

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: Self.thumbnailsWidth - 40, height: (Self.thumbnailsWidth - 40) * 1.3)
        thumbnails.backgroundColor = Self.backdrop
        thumbnails.isHidden = true
        thumbnailsEdge.isHidden = true
        addSubview(thumbnails)
        addSubview(thumbnailsEdge)

        bar.radius = Tokens.Space.x5
        [sidebarButton, pageLabel, zoomOutButton, zoomInButton, saveButton].forEach { bar.addSubview($0) }
        pageLabel.alignment = .center
        addSubview(bar)
        bar.onLayout = { [weak self] in self?.layoutBar() }
        sidebarButton.onClick = { [weak self] _ in self?.toggleThumbnails() }
        zoomOutButton.onClick = { [weak self] _ in self?.zoomOut() }
        zoomInButton.onClick = { [weak self] _ in self?.zoomIn() }
        saveButton.onClick = { [weak self] _ in self?.save() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        pageChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Behind the pages: a shade off the card, so each page stands out as paper.
    private static let backdrop = Tokens.Color.dynamic(light: Tokens.Color.hex(0xEDEDF0), dark: Tokens.Color.hex(0x161618))

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = showsThumbnails ? Self.thumbnailsWidth : 0
        thumbnails.frame = NSRect(x: 0, y: 0, width: Self.thumbnailsWidth, height: bounds.height)
        thumbnailsEdge.frame = NSRect(x: Self.thumbnailsWidth - Tokens.Metric.hairline, y: 0, width: Tokens.Metric.hairline, height: bounds.height)
        pdfView.frame = NSRect(x: side, y: 0, width: bounds.width - side, height: bounds.height)
        let width = barWidth
        let h = Tokens.Space.x10
        bar.frame = NSRect(x: round(side + (bounds.width - side - width) / 2), y: bounds.height - h - Tokens.Space.x4, width: width, height: h)
    }

    private var barWidth: CGFloat {
        let b = Tokens.Space.x7Height
        return Tokens.Space.x2 * 2 + b * 4 + pageLabelWidth + Tokens.Space.x2 * 2
    }

    private var pageLabelWidth: CGFloat {
        let count = pdfView.document?.pageCount ?? 0
        let widest = Label("\(count) of \(count)", font: Tokens.Font.small(.medium), color: .clear)
        return ceil(widest.textWidth) + Tokens.Space.x3
    }

    private func layoutBar() {
        let b = Tokens.Space.x7Height, h = bar.bounds.height, y = (h - b) / 2
        var x = Tokens.Space.x2
        sidebarButton.frame = NSRect(x: x, y: y, width: b, height: b)
        x += b + Tokens.Space.x1
        let lw = pageLabelWidth
        pageLabel.frame = NSRect(x: x, y: (h - pageLabel.lineHeight) / 2, width: lw, height: pageLabel.lineHeight)
        x += lw + Tokens.Space.x1
        zoomOutButton.frame = NSRect(x: x, y: y, width: b, height: b)
        x += b
        zoomInButton.frame = NSRect(x: x, y: y, width: b, height: b)
        x += b
        saveButton.frame = NSRect(x: x, y: y, width: b, height: b)
    }

    @objc private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        let index = document.index(for: page) + 1
        pageLabel.stringValue = "\(index) of \(document.pageCount)"
    }

    // MARK: Actions

    private func toggleThumbnails() {
        showsThumbnails.toggle()
        thumbnails.isHidden = !showsThumbnails
        thumbnailsEdge.isHidden = !showsThumbnails
        sidebarButton.showsFillAtRest = showsThumbnails
        needsLayout = true
    }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    /// Back to fitting the window, as when it opened.
    func actualSize() { pdfView.autoScales = true }

    func save() {
        guard let data, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.lastPathComponent.lowercased().hasSuffix(".pdf") ? url.lastPathComponent : "Document.pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let target = panel.url else { return }
            try? data.write(to: target)
        }
    }

    func print() {
        guard let window, let operation = pdfView.document?.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Find

    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var matchedQuery = ""

    /// Finds `query`, moving to the next (or previous) match. Returns where you are and how many there are.
    func find(_ query: String, backwards: Bool, fromStart: Bool) -> (place: Int, count: Int) {
        guard let document = pdfView.document, !query.isEmpty else { clearFind(); return (0, 0) }
        if query != matchedQuery || fromStart {
            matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            matchedQuery = query
            matchIndex = backwards ? matches.count - 1 : 0
        } else if !matches.isEmpty {
            matchIndex = (matchIndex + (backwards ? -1 : 1) + matches.count) % matches.count
        }
        guard matches.indices.contains(matchIndex) else { pdfView.highlightedSelections = nil; return (0, 0) }
        let current = matches[matchIndex]
        pdfView.highlightedSelections = matches
        pdfView.setCurrentSelection(current, animate: true)
        pdfView.go(to: current)
        return (matchIndex + 1, matches.count)
    }

    func clearFind() {
        matches = []
        matchedQuery = ""
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    // MARK: PDFViewDelegate

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        MainActor.assumeIsolated { onOpenLink?(url) }
    }

    // MARK: Loading

    /// Fetches the PDF the way the page did: its cookies and the browser's user agent, so a PDF behind a sign-in
    /// comes too. Nil when it can't (WebKit's own viewer stays then).
    static func load(_ url: URL, from webView: WKWebView, userAgent: String?) async -> (PDFDocument, Data)? {
        let data: Data?
        if url.isFileURL {
            data = try? await Task.detached { try Data(contentsOf: url) }.value
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let configuration = URLSessionConfiguration.ephemeral
            let storage = HTTPCookieStorage()
            cookies.forEach { storage.setCookie($0) }
            configuration.httpCookieStorage = storage
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            guard let (body, response) = try? await session.data(for: request),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            data = body
        } else {
            data = nil
        }
        guard let data, let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        return (document, data)
    }
}

/// PDFKit's view with Zigzag's swipe to go back and forward.
final class ZigzagPDFView: PDFView {
    var onSwipe: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onSwipe?(event) == true { return }
        super.scrollWheel(with: event)
    }
}
