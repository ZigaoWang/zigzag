import AppKit
import PDFKit
import WebKit
import os

/// PDFs in Zigzag's own viewer: Apple's PDFKit (Preview's engine) for the pages, with our controls in a pill at the
/// bottom: the pages or contents down the side, where you are (click it to jump), zoom, two pages side by side,
/// dark pages, and saving. It reopens a PDF where you left off.
///
/// WebKit still loads the PDF underneath, so Back, Forward, history and reopening after a restart work as for any
/// page. The viewer fetches the same file with the page's cookies (PDFs behind a sign-in) and covers WebKit's own,
/// a quiet blank while it loads; if that fails, WebKit's viewer simply shows.
@MainActor
final class PDFViewerView: NSView, PDFViewDelegate {
    let url: URL
    private(set) var data: Data?
    /// The title the PDF gives itself, once it's loaded and if it has one.
    var documentTitle: String?
    private let isPrivate: Bool
    /// The profile of the tab it's in: a copy downloaded from it is that profile's.
    private let profile: UUID
    let pdfView = ZigzagPDFView()
    private let spinner = NSProgressIndicator()

    private let sidebar = NSView()
    private let sidebarEdge = ColorView(color: Tokens.Color.separator)
    private let thumbnails = PDFThumbnailView()
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

    /// Shown at once, blank while the PDF loads; `show(_:data:)` puts the pages in.
    init(url: URL, isPrivate: Bool, profile: UUID = Profile.defaultID) {
        self.url = url
        self.isPrivate = isPrivate
        self.profile = profile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = cgColor(Self.backdrop)

        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.delegate = self
        pdfView.backgroundColor = Self.backdrop
        pdfView.alphaValue = 0
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
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: Self.sidebarWidth - 64, height: (Self.sidebarWidth - 64) * 1.3)
        thumbnails.backgroundColor = Self.backdrop
        contents.isHidden = true
        contents.onPick = { [weak self] destination in self?.glide(to: destination) }
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
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(followDarkPages), name: Self.darkPagesChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pages are here: on the page you left off at, faded in over the blank.
    func show(_ document: PDFDocument, data: Data) {
        self.data = data
        spinner.stopAnimation(nil)
        // Sized first, so the pages are scaled for the window they're in and open at their top.
        layoutSubtreeIfNeeded()
        applyTwoPages()
        // Dark from its first draw, if that's how you read PDFs.
        (document as? DarkableDocument)?.isDark = Self.darkPages
        pdfView.document = document
        contents.outline = document.outlineRoot
        // The Pages and Contents switch only when there are contents to show.
        sidebarSwitch.isHidden = !contents.hasEntries
        pdfView.layoutDocumentView()
        let saved = Self.place(for: url).flatMap { $0 < document.pageCount ? $0 : nil } ?? 0
        if let page = document.page(at: saved) { pdfView.go(to: page) }
        applyDarkPages()
        pageChanged()
        bar.isHidden = false
        needsLayout = true
        Tokens.Motion.animate(Tokens.Motion.gentle, evenFromKeyboard: true, moves: true) {
            self.pdfView.animator().alphaValue = 1
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
        Tokens.Space.x2 * 2 + Tokens.Metric.iconButton * 6 + pageButton.fittingWidth(pages: pdfView.document?.pageCount ?? 0) + Tokens.Space.x1 * 2
    }

    private func layoutBar() {
        let b = Tokens.Metric.iconButton, h = bar.bounds.height, y = (h - b) / 2
        var x = Tokens.Space.x2
        func place(_ view: NSView, _ width: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: b); x += width }
        place(sidebarButton, b)
        x += Tokens.Space.x1
        place(pageButton, pageButton.fittingWidth(pages: pdfView.document?.pageCount ?? 0))
        x += Tokens.Space.x1
        [zoomOutButton, zoomInButton, twoPagesButton, darkButton, saveButton].forEach { place($0, b) }
    }

    @objc private func pageChanged() {
        // The page at the top of the view: PDFKit's own idea of it lags behind a smooth scroll.
        let top = NSPoint(x: pdfView.bounds.midX, y: pdfView.isFlipped ? 40 : pdfView.bounds.maxY - 40)
        guard let document = pdfView.document, let page = pdfView.page(for: top, nearest: true) ?? pdfView.currentPage else { return }
        let index = document.index(for: page)
        pageButton.set(page: index + 1, of: document.pageCount)
        contents.markCurrent(page)
        rememberPlace(index)
    }

    /// What's on screen, for the tab's picture in the switcher and all-tabs view.
    func snapshot() -> NSImage? {
        guard pdfView.document != nil, let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) else { return nil }
        pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
        let image = NSImage(size: pdfView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Moving around

    /// Scrolls to a page or a heading in one smooth move, rather than a cut.
    private func glide(to destination: PDFDestination) {
        guard let page = destination.page else { return }
        guard !Tokens.Motion.reduceMotion, let documentView = pdfView.documentView, let clip = documentView.enclosingScrollView?.contentView else {
            pdfView.go(to: destination)
            return
        }
        // Where the heading sits on its page, or the page's top, in the scrolling view's own terms.
        let box = page.bounds(for: pdfView.displayBox)
        var point = destination.point
        if point.y == kPDFDestinationUnspecifiedValue || point.y > box.maxY { point.y = box.maxY }
        if point.x == kPDFDestinationUnspecifiedValue { point.x = box.minX }
        let inView = pdfView.convert(point, from: page)
        let inDocument = documentView.convert(inView, from: pdfView)
        let margin: CGFloat = 12
        var origin = clip.bounds.origin
        origin.y = documentView.isFlipped ? inDocument.y - margin : inDocument.y - clip.bounds.height + margin
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        origin.y = min(max(origin.y, 0), maxY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.snappy.duration
            context.timingFunction = Tokens.Motion.easeInOut
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self, weak clip] in
            MainActor.assumeIsolated {
                guard let self, let clip else { return }
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
                // Landed: the page count follows what's now at the top.
                self.pageChanged()
            }
        }
    }

    private func jump(toPage number: Int) {
        guard let document = pdfView.document, let page = document.page(at: min(max(number, 1), document.pageCount) - 1) else { return }
        glide(to: PDFDestination(page: page, at: NSPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)))
        window?.makeFirstResponder(pdfView)
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
        applyTwoPages()
    }

    private func applyTwoPages() {
        let page = pdfView.currentPage
        pdfView.displayMode = Self.twoPages ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = Self.twoPages
        pdfView.autoScales = true
        twoPagesButton.showsFillAtRest = Self.twoPages
        if let page { pdfView.go(to: page) }
    }

    /// Dark pages are one setting: every open PDF, in any window, follows it.
    private static let darkPagesChanged = Notification.Name("ZigzagPDFDarkPagesChanged")

    private func toggleDarkPages() {
        Self.darkPages.toggle()
        NotificationCenter.default.post(name: Self.darkPagesChanged, object: nil)
    }

    @objc private func followDarkPages() {
        // A soft crossfade from the pages as they were, rather than a flash, where you can see it.
        guard window != nil, pdfView.document != nil, let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) else {
            applyDarkPages()
            return
        }
        pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
        let image = NSImage(size: pdfView.bounds.size)
        image.addRepresentation(rep)
        let still = NSImageView(frame: pdfView.frame)
        still.image = image
        still.imageScaling = .scaleAxesIndependently
        addSubview(still, positioned: .above, relativeTo: pdfView)
        applyDarkPages()
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, { still.animator().alphaValue = 0 }, completion: { still.removeFromSuperview() })
    }

    private static func around(dark: Bool) -> NSColor { dark ? Tokens.Color.pdfBackdropDarkPages : backdrop }

    /// Dark pages: each page drawn dark by `DarkablePage` (soft dark paper, light ink, its colors kept), and no
    /// page shadows, which would glow.
    private func applyDarkPages() {
        let dark = Self.darkPages
        darkButton.showsFillAtRest = dark
        darkButton.symbol = dark ? "moon.fill" : "moon"
        // Set on this document alone: its pages read it while PDFKit draws them, off the main thread too.
        let darkable = pdfView.document as? DarkableDocument
        let changed = darkable.map { $0.isDark != dark } ?? false
        darkable?.isDark = dark
        pdfView.pageShadowsEnabled = !dark
        let around = Self.around(dark: dark)
        pdfView.backgroundColor = around
        layer?.backgroundColor = cgColor(around)
        // PDFKit keeps pages it has drawn: the document goes back in, on the same spot at the same zoom, so
        // every page and thumbnail draws again in its new colors.
        guard changed, let document = pdfView.document, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        let autoScales = pdfView.autoScales, scale = pdfView.scaleFactor, origin = clip.bounds.origin
        pdfView.document = nil
        pdfView.document = document
        pdfView.scaleFactor = scale
        pdfView.autoScales = autoScales
        pdfView.layoutDocumentView()
        if let newClip = pdfView.documentView?.enclosingScrollView?.contentView {
            newClip.scroll(to: origin)
            newClip.enclosingScrollView?.reflectScrolledClipView(newClip)
        }
        pageChanged()
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

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    /// The pages at their printed size, as in Preview (it still opens fitting the window).
    func actualSize() {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    /// Downloaded like any file: into Downloads (or where you choose, with that setting), with the usual flight into
    /// the Downloads button, which opens to show it. The tab stays on the web copy you were reading; opening the file
    /// from Downloads opens it on the same page. A PDF that's already a file on your Mac has nothing to download: Save
    /// As asks where a copy goes.
    func save() {
        guard let data, let window else { return }
        let name = url.lastPathComponent.lowercased().hasSuffix(".pdf") ? url.lastPathComponent : "Document.pdf"
        let controller = WindowManager.shared.controllers.first { $0.window === window }
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
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
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

    /// Printed from the file itself: paper is never dark.
    func print() {
        guard let window, let data, let operation = PDFDocument(data: data)?.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
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
        // Never a file on your Mac: a local PDF's relative links would otherwise reach the files beside it.
        MainActor.assumeIsolated {
            switch Reader.route(for: url) {
            case .browse: onOpenLink?(url)
            case .externalApp: onExternalLink?(url)
            case .ignore: break
            }
        }
    }

    // MARK: Loading

    /// Fetches the PDF the way the page did: its cookies and the browser's user agent, so a PDF behind a sign-in
    /// comes too. Nil when it can't (WebKit's own viewer shows then).
    static func load(_ url: URL, from webView: WKWebView, userAgent: String?) async -> (PDFDocument, Data)? {
        let data: Data?
        if url.isFileURL {
            data = try? await Task.detached { try Data(contentsOf: url) }.value
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            data = body
        } else {
            data = nil
        }
        // Its pages come as `DarkablePage`, so dark pages can draw them. One behind a password is left to WebKit,
        // which asks for it.
        guard let data, let document = DarkableDocument(data: data), !document.isLocked, document.pageCount > 0 else { return nil }
        return (document, data)
    }
}

/// PDFKit's view with Zigzag's swipe to go back and forward.
final class ZigzagPDFView: PDFView {
    var onSwipe: ((NSEvent, (left: Bool, right: Bool)) -> Bool)?

    /// PDFKit's own scroll view inside takes the trackpad's scrolls, so they never reach this view: the window hands
    /// each scroll over the pages here first (`BrowserWindow.sendEvent`), so the swipe sees every gesture begin and
    /// end. Zoomed in, a sideways swipe pans until the pages reach their edge, and only then goes back or forward.
    func takesSwipe(_ event: NSEvent) -> Bool {
        onSwipe?(event, sidewaysRoom) == true
    }

    /// Whether the pages can scroll further left or right.
    private var sidewaysRoom: (left: Bool, right: Bool) {
        guard let documentView, let clip = documentView.enclosingScrollView?.contentView else { return (false, false) }
        let shown = clip.bounds, all = documentView.frame
        return (shown.minX > all.minX + 0.5, shown.maxX < all.maxX - 0.5)
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

/// The PDF's own table of contents, indented by level. Click a heading to go there; the one you're reading is marked.
private final class PDFContentsView: NSView {
    private let scroll = NSScrollView()
    private let stack = FlippedView()
    private var rows: [(row: ContentsRow, page: PDFPage?)] = []
    var onPick: ((PDFDestination) -> Void)?
    var hasEntries: Bool { !rows.isEmpty }

    var outline: PDFOutline? {
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
        func add(_ item: PDFOutline, level: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                let destination = child.destination
                let row = ContentsRow(title: child.label ?? "", level: level)
                row.onClick = { [weak self] _ in if let destination { self?.onPick?(destination) } }
                stack.addSubview(row)
                rows.append((row, destination?.page))
                add(child, level: level + 1)
            }
        }
        if let outline { add(outline, level: 0) }
        needsLayout = true
    }

    /// The section you're reading: the first heading on this page, or the last one before it.
    func markCurrent(_ page: PDFPage) {
        guard let document = page.document else { return }
        let index = document.index(for: page)
        let placed = rows.compactMap { row, rowPage in rowPage.map { (row, document.index(for: $0)) } }
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

/// A PDF page that can draw itself dark for reading at night, in vectors, so text stays as sharp as ever:
/// the page as usual, its brightness flipped against a soft grey (white paper to #1C1C1E, black ink to #E3E3E3),
/// then the page again in color blending, which puts back each color's own hue and strength on the new brightness.
/// A diagram's blue box stays blue, only darker; nothing turns into its opposite.
/// A document whose pages are `DarkablePage`, and whether they draw dark. Locked, since PDFKit draws pages on
/// its own threads while the setting changes on the main one.
nonisolated final class DarkableDocument: PDFDocument {
    private let dark = OSAllocatedUnfairLock(initialState: false)
    var isDark: Bool {
        get { dark.withLock { $0 } }
        set { dark.withLock { $0 = newValue } }
    }

    override var pageClass: AnyClass { DarkablePage.self }
}

nonisolated final class DarkablePage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard (document as? DarkableDocument)?.isDark == true else { super.draw(with: box, to: context); return }
        let area = context.boundingBoxOfClipPath
        context.saveGState()
        // Paper first, so a page with no background of its own darkens too.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(area)
        super.draw(with: box, to: context)
        context.setBlendMode(.difference)
        context.setFillColor(CGColor(gray: 0.89, alpha: 1))
        context.fill(area)
        context.setBlendMode(.color)
        super.draw(with: box, to: context)
        context.restoreGState()
    }
}
