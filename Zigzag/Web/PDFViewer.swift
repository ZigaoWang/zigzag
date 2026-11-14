import AppKit
import WebKit
import os

/// PDFs in Zigzag's own viewer, from the web or your Mac: the pages, with our controls in a pill at the bottom: the
/// pages or contents down the side, where you are (click it to jump), zoom, two pages side by side, dark pages, and
/// saving. It reopens a PDF where you left off.
///
/// The PDF is never read here: Zigzag runs outside WebKit's sandbox, so the sandboxed PDF helper opens it
/// (`SafePDF`), and the pages are drawn from what it sends back (`ZigzagPDFView`). Zigzag only holds the bytes, to
/// send them there and to save them as they came. If the helper can't read a PDF, or fails on it, WebKit's own
/// viewer shows it instead.
///
/// WebKit still loads the PDF underneath, so Back, Forward, history, printing and reopening after a restart work as
/// for any page. The viewer fetches the same file with the page's cookies (PDFs behind a sign-in) and covers
/// WebKit's own, a quiet blank while it loads.
@MainActor
final class PDFViewerView: NSView {
    let url: URL
    private(set) var data: Data?
    private(set) var document: SafePDF?
    /// The title the PDF gives itself, once it's loaded and if it has one.
    var documentTitle: String?
    private let isPrivate: Bool
    /// The profile of the tab it's in: a copy downloaded from it is that profile's.
    private let profile: UUID
    let pdfView = ZigzagPDFView()
    private let spinner = NSProgressIndicator()

    private let sidebar = NSView()
    private let sidebarEdge = ColorView(color: Tokens.Color.separator)
    private let thumbnails = PDFThumbnailsView()
    private let sidebarSwitch = SlidingSwitch([.text(String(localized: "Pages", comment: "Switch in the PDF viewer's sidebar: shows the pages as thumbnails.")), .text(String(localized: "Contents", comment: "Switch in the PDF viewer's sidebar: shows the document's table of contents."))])
    private let contents = PDFContentsView()

    private let bar = FloatingPanelView()
    private let sidebarButton = IconButton(symbol: "sidebar.left", toolTip: String(localized: "Pages and Contents", comment: "Toolbar button tooltip in the PDF viewer."))
    private let pageButton = PageNumberButton()
    private let zoomOutButton = IconButton(symbol: "minus.magnifyingglass", toolTip: String(localized: "Zoom Out", comment: "Toolbar button tooltip in the PDF viewer."))
    private let zoomInButton = IconButton(symbol: "plus.magnifyingglass", toolTip: String(localized: "Zoom In", comment: "Toolbar button tooltip in the PDF viewer."))
    private let twoPagesButton = IconButton(symbol: "book", toolTip: String(localized: "Two Pages", comment: "Toolbar button tooltip in the PDF viewer. Shows two pages side by side."))
    private let darkButton = IconButton(symbol: "moon", toolTip: String(localized: "Dark Pages", comment: "Toolbar button tooltip in the PDF viewer. Shows the pages dark."))
    private let saveButton = IconButton(symbol: "arrow.down.circle", toolTip: String(localized: "Download PDF", comment: "Toolbar button tooltip in the PDF viewer."))
    private var showsSidebar = false
    private var saveWork: DispatchWorkItem?

    /// Links in the PDF open like links on a page: web links here, other apps' links through `onExternalLink`.
    var onOpenLink: ((URL) -> Void)?
    var onExternalLink: ((URL) -> Void)?
    /// The helper failed on this PDF after it showed: WebKit's viewer takes over.
    var onFail: (() -> Void)?
    /// Swipes to go back or forward, handed to the page underneath with which way the pages can still scroll.
    var onSwipe: ((NSEvent, (left: Bool, right: Bool)) -> Bool)? {
        get { pdfView.onSwipe }
        set { pdfView.onSwipe = newValue }
    }

    private static let sidebarWidth: CGFloat = 196
    private static let barHeight = Tokens.Space.x10
    private static let backdrop = Tokens.Color.pdfBackdrop

    private static var twoPages: Bool {
        get { UserDefaults.standard.bool(forKey: "pdfTwoPages") }
        set { UserDefaults.standard.set(newValue, forKey: "pdfTwoPages") }
    }
    private static var darkPages: Bool {
        get { UserDefaults.standard.bool(forKey: "pdfDarkPages") }
        set { UserDefaults.standard.set(newValue, forKey: "pdfDarkPages") }
    }

    /// Shown at once, blank while the PDF loads; `show(_:info:)` puts the pages in.
    init(url: URL, isPrivate: Bool, profile: UUID = Profile.defaultID) {
        self.url = url
        self.isPrivate = isPrivate
        self.profile = profile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = cgColor(Self.backdrop)

        pdfView.backdrop = Self.backdrop
        pdfView.bottomInset = Self.barHeight + Tokens.Space.x4
        pdfView.alphaValue = 0
        pdfView.onPageChanged = { [weak self] in self?.pageChanged() }
        pdfView.onOpenURL = { [weak self] url in self?.openLink(url) }
        pdfView.onThumbnail = { [weak self] page in self?.thumbnails.thumbnailArrived(page) }
        addSubview(pdfView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        // Most PDFs are here before a spinner would mean anything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pdfView.document == nil else { return }
            self.spinner.startAnimation(nil)
        }

        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = cgColor(Self.backdrop)
        thumbnails.onPick = { [weak self] page in self?.jump(toPage: page + 1) }
        contents.isHidden = true
        contents.onPick = { [weak self] item in
            guard let self, let page = item.page else { return }
            self.pdfView.go(toPage: page, y: item.y, animated: true)
        }
        sidebarSwitch.onChange = { [weak self] index in
            self?.thumbnails.isHidden = index != 0
            self?.contents.isHidden = index != 1
        }
        [thumbnails, contents, sidebarSwitch].forEach { sidebar.addSubview($0) }
        sidebar.isHidden = true
        sidebarEdge.isHidden = true
        addSubview(sidebar)
        addSubview(sidebarEdge)

        // A capsule, as the Reader's bar is, rising those few points from the page's bottom as the PDF opens.
        bar.radius = Self.barHeight / 2
        bar.attachedEdge = .maxY
        [sidebarButton, pageButton, zoomOutButton, zoomInButton, twoPagesButton, darkButton, saveButton].forEach { bar.addSubview($0) }
        bar.isHidden = true
        addSubview(bar)
        bar.onLayout = { [weak self] in self?.layoutBar() }
        sidebarButton.onClick = { [weak self] _ in self?.toggleSidebar() }
        zoomOutButton.onClick = { [weak self] _ in self?.zoomOut() }
        zoomInButton.onClick = { [weak self] _ in self?.zoomIn() }
        twoPagesButton.onClick = { [weak self] _ in self?.toggleTwoPages() }
        darkButton.onClick = { [weak self] _ in self?.toggleDarkPages() }
        saveButton.onClick = { [weak self] _ in self?.save() }
        // A PDF already on your Mac has nothing to download; the button saves a copy elsewhere.
        if url.isFileURL {
            saveButton.toolTip = String(localized: "Save a Copy…", comment: "Toolbar button tooltip in the PDF viewer. For a PDF already on the Mac.")
            saveButton.symbol = "square.and.arrow.down"
        }
        pageButton.onJump = { [weak self] number in self?.jump(toPage: number) }
        pageButton.onDone = { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.pdfView) }
        NotificationCenter.default.addObserver(self, selector: #selector(followDarkPages), name: Self.darkPagesChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pages are here: on the page you left off at, faded in over the blank once they're drawn.
    func show(_ document: SafePDF, info: SafePDF.Info) {
        self.document = document
        data = document.data
        document.onFail = { [weak self] in self?.onFail?() }
        spinner.stopAnimation(nil)
        // Sized first, so the pages are scaled for the window they're in and open at their top.
        layoutSubtreeIfNeeded()
        pdfView.twoUp = Self.twoPages
        twoPagesButton.showsFillAtRest = Self.twoPages
        // Dark from its first draw, if that's how you read PDFs.
        applyDarkPages()
        let saved = Self.place(for: url).flatMap { $0 < info.pageSizes.count ? $0 : nil } ?? 0
        pdfView.show(document, info: info, startPage: saved)
        thumbnails.pages = pdfView
        contents.outline = info.outline
        // The Pages and Contents switch only when there are contents to show.
        sidebarSwitch.isHidden = !contents.hasEntries
        pageChanged()
        bar.isHidden = false
        needsLayout = true
        pdfView.whenShown { [weak self] in
            guard let self else { return }
            Tokens.Motion.animate(Tokens.Motion.Curve(duration: Tokens.Motion.large), evenFromKeyboard: true) {
                self.pdfView.animator().alphaValue = 1
            }
        }
        bar.present(arrival: .pop)
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layers keep the color they were given: light or dark, they take it again.
        layer?.backgroundColor = cgColor(Self.around(dark: Self.darkPages))
        sidebar.layer?.backgroundColor = cgColor(Self.backdrop)
    }

    override func layout() {
        super.layout()
        layoutPanes()
        let s = NSSize(width: 16, height: 16)
        spinner.frame = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    private func layoutPanes() {
        let side = showsSidebar ? Self.sidebarWidth : 0
        // The sidebar slides in from the left edge; it waits just off it while closed.
        sidebar.frame = NSRect(x: side - Self.sidebarWidth, y: 0, width: Self.sidebarWidth, height: bounds.height)
        sidebarEdge.frame = NSRect(x: side - Tokens.Metric.hairline, y: 0, width: Tokens.Metric.hairline, height: bounds.height)
        pdfView.frame = NSRect(x: side, y: 0, width: bounds.width - side, height: bounds.height)
        let switchHeight: CGFloat = sidebarSwitch.isHidden ? 0 : Tokens.Page.controlHeight
        let top = sidebarSwitch.isHidden ? 0 : Tokens.Space.x3 + switchHeight + Tokens.Space.x2
        sidebarSwitch.frame = NSRect(x: Tokens.Space.x3, y: sidebar.bounds.height - Tokens.Space.x3 - switchHeight,
                                     width: Self.sidebarWidth - Tokens.Space.x6, height: switchHeight)
        let below = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: sidebar.bounds.height - top)
        thumbnails.frame = below
        contents.frame = below
        let width = barWidth
        let h = Self.barHeight
        bar.frame = NSRect(x: round(side + (bounds.width - side - width) / 2), y: bounds.height - h - Tokens.Space.x4, width: width, height: h)
    }

    private var barWidth: CGFloat {
        Tokens.Space.x2 * 2 + Tokens.Metric.iconButton * 6 + pageButton.fittingWidth(pages: pdfView.pageCount) + Tokens.Space.x1 * 2
    }

    private func layoutBar() {
        let b = Tokens.Metric.iconButton, h = bar.bounds.height, y = (h - b) / 2
        var x = Tokens.Space.x2
        func place(_ view: NSView, _ width: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: b); x += width }
        place(sidebarButton, b)
        x += Tokens.Space.x1
        place(pageButton, pageButton.fittingWidth(pages: pdfView.pageCount))
        x += Tokens.Space.x1
        [zoomOutButton, zoomInButton, twoPagesButton, darkButton, saveButton].forEach { place($0, b) }
    }

    private var shownPage = -1

    private func pageChanged() {
        guard pdfView.pageCount > 0 else { return }
        let index = pdfView.currentPage
        guard index != shownPage else { return }
        shownPage = index
        pageButton.set(page: index + 1, of: pdfView.pageCount)
        contents.markCurrent(index)
        thumbnails.markCurrent(index)
        rememberPlace(index)
    }

    /// What's on screen, for the tab's picture in the switcher and all-tabs view.
    func snapshot() -> NSImage? {
        guard pdfView.document != nil else { return nil }
        return pdfView.snapshot()
    }

    // MARK: Moving around

    private func jump(toPage number: Int) {
        guard pdfView.pageCount > 0 else { return }
        pdfView.go(toPage: min(max(number, 1), pdfView.pageCount) - 1, y: nil, animated: true)
        window?.makeFirstResponder(pdfView)
    }

    /// Never a file on your Mac: a local PDF's relative links would otherwise reach the files beside it.
    private func openLink(_ url: URL) {
        switch Reader.route(for: url) {
        case .browse: onOpenLink?(url)
        case .externalApp: onExternalLink?(url)
        case .ignore: break
        }
    }

    private func toggleSidebar() {
        showsSidebar.toggle()
        sidebarButton.showsFillAtRest = showsSidebar
        if showsSidebar { sidebar.isHidden = false; sidebarEdge.isHidden = false }
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true, {
            let side = self.showsSidebar ? Self.sidebarWidth : 0
            self.sidebar.animator().frame.origin.x = side - Self.sidebarWidth
            self.sidebarEdge.animator().frame.origin.x = side - Tokens.Metric.hairline
            self.pdfView.animator().frame = NSRect(x: side, y: 0, width: self.bounds.width - side, height: self.bounds.height)
            var frame = self.bar.frame
            frame.origin.x = round(side + (self.bounds.width - side - frame.width) / 2)
            self.bar.animator().frame = frame
        }, completion: { [weak self] in
            guard let self, !self.showsSidebar else { return }
            self.sidebar.isHidden = true
            self.sidebarEdge.isHidden = true
        })
    }

    private func toggleTwoPages() {
        Self.twoPages.toggle()
        pdfView.twoUp = Self.twoPages
        twoPagesButton.showsFillAtRest = Self.twoPages
    }

    /// Dark pages are one setting: every open PDF, in any window, follows it.
    private static let darkPagesChanged = Notification.Name("ZigzagPDFDarkPagesChanged")

    private func toggleDarkPages() {
        Self.darkPages.toggle()
        NotificationCenter.default.post(name: Self.darkPagesChanged, object: nil)
    }

    @objc private func followDarkPages() {
        // A soft crossfade from the pages as they were, rather than a flash, where you can see it: the old look stays
        // until the new one is drawn.
        guard window != nil, pdfView.document != nil, let image = pdfView.snapshot() else {
            applyDarkPages()
            return
        }
        let still = NSImageView(frame: pdfView.frame)
        still.image = image
        still.imageScaling = .scaleAxesIndependently
        addSubview(still, positioned: .above, relativeTo: pdfView)
        applyDarkPages()
        pdfView.whenShown {
            Tokens.Motion.animate(Tokens.Motion.change, evenFromKeyboard: true, { still.animator().alphaValue = 0 }, completion: { still.removeFromSuperview() })
        }
    }

    private static func around(dark: Bool) -> NSColor { dark ? Tokens.Color.pdfBackdropDarkPages : backdrop }

    /// Dark pages: each page drawn dark by the helper (soft dark paper, light ink, its colors kept), and no page
    /// shadows, which would glow.
    private func applyDarkPages() {
        let dark = Self.darkPages
        darkButton.showsFillAtRest = dark
        darkButton.symbol = dark ? "moon.fill" : "moon"
        pdfView.isDark = dark
        pdfView.pageShadows = !dark
        let around = Self.around(dark: dark)
        pdfView.backdrop = around
        layer?.backgroundColor = cgColor(around)
        thumbnails.reload()
    }

    // MARK: Remembering your place

    private static let placesKey = "pdfPlaces"

    /// The PDF's address without what follows `?` or `#`: a web PDF's query often carries a sign-in token, which
    /// has no business sitting in your settings.
    private static func key(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        if !url.isFileURL { parts?.query = nil }
        return parts?.string ?? url.absoluteString
    }

    /// Clearing history forgets where you were in PDFs too: all of them, or those read since `date`. Handed back
    /// so ⌘Z can put them back.
    static func takePlaces(since date: Date? = nil) -> [String: Any] {
        let all = UserDefaults.standard.dictionary(forKey: placesKey) ?? [:]
        let kept = date.map { places(all, readBefore: $0) } ?? [:]
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: placesKey) } else { UserDefaults.standard.set(kept, forKey: placesKey) }
        return all.filter { kept[$0.key] == nil }
    }

    static func putBackPlaces(_ taken: [String: Any]) {
        guard !taken.isEmpty else { return }
        let all = UserDefaults.standard.dictionary(forKey: placesKey) ?? [:]
        UserDefaults.standard.set(taken.merging(all) { _, now in now }, forKey: placesKey)
    }

    /// The saved places (page, then when) last read before `date`. One without a time is older than any, so it stays.
    static func places(_ all: [String: Any], readBefore date: Date) -> [String: Any] {
        all.filter { (($0.value as? [Any])?.last as? Double ?? 0) < date.timeIntervalSince1970 }
    }

    private static func place(for url: URL) -> Int? {
        (UserDefaults.standard.dictionary(forKey: placesKey)?[key(for: url)] as? [Any])?.first as? Int
    }

    /// The page you're on, kept a moment after you stop (not while scrolling past), for the last 200 PDFs.
    private func rememberPlace(_ index: Int) {
        guard !isPrivate, pdfView.document != nil else { return }
        saveWork?.cancel()
        let key = Self.key(for: url)
        let work = DispatchWorkItem {
            var all = UserDefaults.standard.dictionary(forKey: Self.placesKey) ?? [:]
            all[key] = [index, Date().timeIntervalSince1970]
            if all.count > 200 {
                let oldest = all.min { (($0.value as? [Any])?.last as? Double ?? 0) < (($1.value as? [Any])?.last as? Double ?? 0) }
                if let oldest { all[oldest.key] = nil }
            }
            UserDefaults.standard.set(all, forKey: Self.placesKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Actions

    func zoomIn() { pdfView.zoomIn() }
    func zoomOut() { pdfView.zoomOut() }
    /// The pages at their printed size, as in Preview (it still opens fitting the window).
    func actualSize() { pdfView.actualSize() }

    /// Downloaded like any file: into Downloads (or where you choose, with that setting), with the usual flight into
    /// the Downloads button, which opens to show it. The tab stays on the web copy you were reading; opening the file
    /// from Downloads opens it on the same page. A PDF that's already a file on your Mac has nothing to download: Save
    /// As asks where a copy goes. Either way, the bytes as they came, untouched.
    func save() {
        guard let data, let window else { return }
        let name = url.lastPathComponent.lowercased().hasSuffix(".pdf") ? url.lastPathComponent : "Document.pdf"
        let controller = WindowManager.shared.controller(for: window)
        if url.isFileURL {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = name
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let target = panel.url else { return }
                MainActor.assumeIsolated {
                    do { try data.write(to: target) } catch {
                        if let controller { Toast.show(SaveFailure.message(String(localized: "Couldn’t save the PDF", comment: "Toast when saving a copy of a PDF fails; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle", duration: 4, in: controller) }
                    }
                }
            }
            return
        }
        let page = pdfView.currentPage
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let item = try await DownloadManager.shared.save(data, named: name, from: self.url, isPrivate: self.isPrivate, profile: self.profile, window: window),
                      let file = item.destination else { return }
                // The saved copy, opened later, opens on the same page.
                if !self.isPrivate { Self.setPlace(page, for: file) }
            } catch {
                if let controller { Toast.show(SaveFailure.message(String(localized: "Couldn’t download the PDF", comment: "Toast when downloading a PDF fails; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle", duration: 4, in: controller) }
            }
        }
    }

    private static func setPlace(_ index: Int, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: placesKey) ?? [:]
        all[key(for: url)] = [index, Date().timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: placesKey)
    }

    // MARK: Find

    private var matches: [(page: Int, range: NSRange)] = []
    private var matchIndex = 0
    private var matchedQuery = ""
    private var finding = 0

    /// Finds `query`, moving to the next (or previous) match. Returns where you are and how many there are; nil when
    /// a newer search came while this one waited for the PDF's text.
    func find(_ query: String, backwards: Bool, fromStart: Bool) async -> (place: Int, count: Int)? {
        finding += 1
        let search = finding
        guard pdfView.document != nil, !query.isEmpty else { clearFind(); return (0, 0) }
        if query != matchedQuery || fromStart {
            let found = await pdfView.matches(of: query)
            guard search == finding else { return nil }
            matches = found
            matchedQuery = query
            matchIndex = backwards ? found.count - 1 : 0
        } else if !matches.isEmpty {
            matchIndex = (matchIndex + (backwards ? -1 : 1) + matches.count) % matches.count
        }
        guard matches.indices.contains(matchIndex) else { pdfView.showMatches([], current: nil); return (0, 0) }
        pdfView.showMatches(matches, current: matchIndex)
        return (matchIndex + 1, matches.count)
    }

    func clearFind() {
        finding += 1
        matches = []
        matchedQuery = ""
        pdfView.clearFind()
    }

    #if DEBUG
    /// DebugBridge's `pdf` command: the bar's buttons, a page, or a search, from a test copy.
    func debug(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "in": zoomIn()
        case "out": zoomOut()
        case "actual": actualSize()
        case "dark": toggleDarkPages()
        case "twoup": toggleTwoPages()
        case "sidebar": toggleSidebar()
        case "page": jump(toPage: Int(parts.last ?? "") ?? 1)
        case "find": Task { _ = await find(parts.count > 1 ? parts[1] : "", backwards: false, fromStart: true) }
        default: break
        }
    }
    #endif

    // MARK: Loading

    /// Fetches the PDF the way the page did: its cookies and the browser's user agent, so a PDF behind a sign-in
    /// comes too; a file on your Mac is read as it is. Nil when it can't (WebKit's own viewer shows then). Only the
    /// bytes: the helper is what reads them (`open`).
    static func load(_ url: URL, from webView: WKWebView, userAgent: String?) async -> Data? {
        if url.isFileURL {
            return try? await Task.detached { try Data(contentsOf: url) }.value
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        // WebKit's own copy first, once it has all of it: no second download, and nothing a fetch of our own could
        // get differently (a link that works once).
        if let data = await mainResourceData(of: webView, at: url) { return data }
        // Only the cookies a link from another site would carry too: a "Strict" one, held back from the page's own
        // load when another site sent you there, isn't sent behind its back now.
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.sameSitePolicy != .sameSiteStrict }
        let configuration = URLSessionConfiguration.ephemeral
        let storage = HTTPCookieStorage()
        cookies.forEach { storage.setCookie($0) }
        configuration.httpCookieStorage = storage
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (body, response) = try? await session.data(for: request),
              ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400, body.count <= SafePDF.maxInputBytes else { return nil }
        return body
    }

    /// The bytes WebKit loaded for the page, once it's done loading them (WebKit's own unpublished call, as Safari
    /// has it). Nil if it can't say, or they aren't a PDF's: the viewer fetches the file itself then.
    private static func mainResourceData(of webView: WKWebView, at url: URL) async -> Data? {
        let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
        guard webView.responds(to: selector) else { return nil }
        while webView.isLoading, webView.url == url, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard webView.url == url, !Task.isCancelled else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
        let data: Data? = await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            call(webView, selector) { data, _ in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: data as Data?)
            }
        }
        guard let data, data.count <= SafePDF.maxInputBytes, data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { return nil }
        return data
    }

    /// The PDF opened in the helper. Nil when the helper can't read it (not a PDF, behind a password, or it failed):
    /// WebKit's viewer, which asks for a password, shows it instead.
    static func open(_ data: Data) async -> (SafePDF, SafePDF.Info)? {
        let document = SafePDF(data: data)
        guard let info = await document.open() else { return nil }
        return (document, info)
    }
}

/// The PDF's own table of contents, indented by level. Click a heading to go there; the one you're reading is marked.
private final class PDFContentsView: NSView {
    private let scroll = NSScrollView()
    private let stack = FlippedView()
    private var rows: [(row: ContentsRow, page: Int?)] = []
    var onPick: ((SafePDF.OutlineItem) -> Void)?
    var hasEntries: Bool { !rows.isEmpty }

    var outline: [SafePDF.OutlineItem] = [] {
        didSet { rebuild() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func rebuild() {
        rows.forEach { $0.row.removeFromSuperview() }
        rows = []
        for item in outline {
            let row = ContentsRow(title: item.title, level: item.level)
            row.onClick = { [weak self] _ in self?.onPick?(item) }
            stack.addSubview(row)
            rows.append((row, item.page))
        }
        needsLayout = true
    }

    /// The section you're reading: the first heading on this page, or the last one before it.
    func markCurrent(_ index: Int) {
        let placed = rows.compactMap { row, page in page.map { (row, $0) } }
        let current = placed.first { $0.1 == index }?.0 ?? placed.last { $0.1 < index }?.0
        rows.forEach { $0.row.isSelected = $0.row === current }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        // The sidebar's rhythm: rows 8pt in from the edges, a hairline apart.
        let pad = Tokens.Metric.sidebarPadding
        var y = Tokens.Space.x1
        for (row, _) in rows {
            row.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: Tokens.Metric.rowHeight)
            y += Tokens.Metric.rowHeight + Tokens.Metric.rowGap
        }
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y + Tokens.Space.x2, bounds.height))
    }
}

/// "3 of 42" in the bar. Click it and type a page number to go there.
private final class PageNumberButton: InteractiveView, NSTextFieldDelegate {
    private let label = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let field = PlainTextField(font: Tokens.Font.small(.medium), placeholder: String(localized: "Page", comment: "Placeholder of the page number field in the PDF viewer's toolbar."))
    private var page = 0, count = 0
    var onJump: ((Int) -> Void)?
    /// Return or Esc in the field: typing goes back to the pages, not to a hidden field.
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.control
        label.alignment = .center
        field.alignment = .center
        field.isHidden = true
        field.delegate = self
        [label, field].forEach { addSubview($0) }
        toolTip = String(localized: "Go to Page", comment: "Tooltip of the page number in the PDF viewer's toolbar.")
        setAccessibilityRole(.button)
        onClick = { [weak self] _ in self?.beginTyping() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(page: Int, of count: Int) {
        self.page = page
        self.count = count
        label.stringValue = String(localized: "\(page) of \(count)", comment: "The page you're on in the PDF viewer's toolbar, like “3 of 12”.")
        setAccessibilityLabel(String(localized: "Page \(page) of \(count)", comment: "VoiceOver label of the page number in the PDF viewer's toolbar."))
    }

    func fittingWidth(pages: Int) -> CGFloat {
        let widest = Label(String(localized: "\(pages) of \(pages)", comment: "The page you're on in the PDF viewer's toolbar, like “3 of 12”."), font: Tokens.Font.small(.medium), color: .clear)
        return ceil(widest.textWidth) + Tokens.Space.x4
    }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: Tokens.Space.x1, y: (bounds.height - fh) / 2, width: bounds.width - Tokens.Space.x2, height: fh)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = !field.isHidden ? Tokens.Color.fieldFill : isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }

    private func beginTyping() {
        field.stringValue = ""
        field.placeholderString = "\(page)"
        field.isHidden = false
        label.isHidden = true
        stateDidChange(animated: false)
        window?.makeFirstResponder(field)
    }

    private func endTyping() {
        field.isHidden = true
        label.isHidden = false
        stateDidChange(animated: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces))
            endTyping()
            onDone?()
            if let number { onJump?(number) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endTyping()
            onDone?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { endTyping() }
}


private final class ContentsRow: InteractiveView {
    private let label: Label
    private let level: Int

    init(title: String, level: Int) {
        self.level = level
        label = Label(title, font: level == 0 ? Tokens.Font.body(.medium) : Tokens.Font.body(), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        toolTip = title
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let x = CardRow.inset - Label.inset + CGFloat(min(level, 4)) * Tokens.Space.x3
        let h = label.lineHeight
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - CardRow.inset), height: h)
    }

    override func stateDidChange(animated: Bool) {
        applyRowStyle(animated: animated)
        label.textColor = level == 0 || isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
    }
}
