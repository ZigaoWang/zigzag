import AppKit
import UniformTypeIdentifiers
import WebKit

/// Capture (⇧⌘2, Site Controls › Capture, the command bar), as Arc has it: a mode over the page that takes a picture
/// of an area you drag, an element you point at, the whole page or what's on screen. The picture is copied at once
/// and shown in a small card (`CapturePreview`) with Save, Share and a thumbnail to drag out. Nothing is kept
/// anywhere else, in a private window too: only where you save or paste it.
@MainActor
final class PageCapture {
    enum Mode: String, CaseIterable {
        case area, element, fullPage, visible
        /// The key that picks it while capturing.
        var key: String {
            switch self {
            case .area: "a"
            case .element: "e"
            case .fullPage: "f"
            case .visible: "v"
            }
        }
    }

    private weak var controller: BrowserWindowController?
    private weak var webView: WKWebView?
    private weak var tab: Tab?
    private var overlay: CaptureOverlay?
    private var toolbar: CaptureToolbar?
    private var monitors: [Any] = []
    private var urlObservation: NSKeyValueObservation?
    private(set) var mode: Mode = .area
    private var isTaking = false
    private(set) var preview: CapturePreview?
    /// One question to the page at a time: the point asked about meanwhile waits here, the newest only.
    private var hoverInFlight = false
    private var hoverPending: NSPoint?
    #if DEBUG
    /// The last file Save wrote, for testing.
    private(set) var debugSaved: URL?
    /// What the page last answered about the pointer.
    private var debugLastHover = ""
    #endif

    var isActive: Bool { overlay != nil }

    init(controller: BrowserWindowController) { self.controller = controller }

    /// Area or Element, whichever you used last; Element to begin with, as in Arc, where a drag still draws an area.
    static var lastMode: Mode {
        get { UserDefaults.standard.string(forKey: "CaptureMode") == Mode.area.rawValue ? .area : .element }
        set { UserDefaults.standard.set(newValue == .area ? newValue.rawValue : nil, forKey: "CaptureMode") }
    }

    /// Where pictures are copied. Test copies and unit tests use one of their own, never your clipboard.
    static let pasteboard: NSPasteboard = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if !(env["ZIGZAG_DATA_DIR"] ?? "").isEmpty || env["XCTestConfigurationFilePath"] != nil {
            return NSPasteboard(name: NSPasteboard.Name("wang.zigao.zigzag.capture.test"))
        }
        #endif
        return .general
    }()

    /// Whether the page in front can be captured: a web page on screen, not Reader or a PDF.
    var canBegin: Bool {
        guard let controller, let tab = controller.selectedTab, PageScreenshot.canTake(tab),
              let webView = controller.selectedWebView, webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0
        else { return false }
        return !controller.isShowingReader
    }

    /// ⇧⌘2: in, or out again.
    func toggle() { isActive ? cancel() : begin() }

    func begin(_ start: Mode? = nil) {
        guard !isActive, !isTaking, canBegin, let controller, let tab = controller.selectedTab, let webView = controller.selectedWebView else { return }
        dismissPreview()
        Toast.hide(in: controller)
        self.tab = tab
        self.webView = webView
        let overlay = CaptureOverlay()
        let toolbar = CaptureToolbar()
        self.overlay = overlay
        self.toolbar = toolbar
        overlay.onHover = { [weak self] point in self?.hover(at: point) }
        overlay.onPick = { [weak self] point in self?.pick(at: point) }
        overlay.onConfirm = { [weak self] in self?.confirm() }
        overlay.onSelectionChange = { [weak self] in self?.selectionChanged() }
        overlay.onDrawStart = { [weak self] in
            // A drag in Element mode draws an area instead.
            guard let self, self.mode == .element else { return }
            self.setMode(.area, remember: false)
        }
        overlay.onScroll = { [weak self] event in
            guard let self, let webView = self.webView else { return }
            webView.scrollWheel(with: event)
            if self.mode == .element, let point = self.overlay?.pointer { self.hover(at: point) }
        }
        toolbar.onChoose = { [weak self] mode in self?.choose(mode) }
        toolbar.onCapture = { [weak self] in self?.confirm() }
        toolbar.onCancel = { [weak self] in self?.cancel() }
        controller.root.overlay.addSubview(overlay)
        controller.root.overlay.addSubview(toolbar)
        place()
        setMode(start.flatMap { $0 == .area || $0 == .element ? $0 : nil } ?? Self.lastMode, remember: false)
        overlay.present()
        toolbar.attachedEdge = .maxY
        toolbar.present()
        installMonitors()
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        Announcement.post(String(localized: "Capture: drag over the page to pick an area, or press E to pick an element", comment: "VoiceOver announcement when Capture mode starts (⇧⌘2). E is the key for Element."))
        if let start, start == .fullPage || start == .visible { take(start) }
    }

    /// Leaves capture mode without a picture: Esc, Cancel, another tab, the page going elsewhere.
    func cancel() {
        guard isActive else { return }
        end()
    }

    /// Takes the mode down: the dim fades and the toolbar drops away; the page gets the pointer back.
    private func end() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        urlObservation = nil
        if let webView { setPageCursor(nil, in: webView) }
        overlay?.dismiss()
        toolbar?.dismiss()
        overlay = nil
        toolbar = nil
        hoverPending = nil
    }

    /// A toolbar button or its key: Area and Element are modes, Full Page and Visible take the picture.
    func choose(_ mode: Mode) {
        switch mode {
        case .area, .element: setMode(mode, remember: true)
        case .fullPage, .visible: take(mode)
        }
    }

    private func setMode(_ mode: Mode, remember: Bool) {
        self.mode = mode
        if remember { Self.lastMode = mode }
        overlay?.mode = mode
        toolbar?.mode = mode
        if mode == .element { overlay?.selection = nil }
        overlay?.setHighlight(nil, animated: false)
        if let webView { setPageCursor(mode == .area ? "crosshair" : "default", in: webView) }
        if mode == .element, let point = overlay?.pointer { hover(at: point) }
        selectionChanged()
    }

    private func selectionChanged() {
        toolbar?.showsCapture = mode == .area && overlay?.selection != nil
        placeToolbar()
    }

    /// Return, the toolbar's Capture or a double-click: the area you drew, or the element under the pointer.
    func confirm() {
        guard let overlay else { return }
        switch mode {
        case .area: if overlay.selection != nil { take(.area) }
        case .element: if overlay.highlight != nil { take(.element) }
        case .fullPage, .visible: take(mode)
        }
    }

    // MARK: Placing

    /// The web view's frame over the window, where the dim and the toolbar go.
    private var pageFrame: NSRect? {
        guard let controller, let webView, webView.window === controller.window else { return nil }
        return webView.convert(webView.bounds, to: controller.root.overlay)
    }

    /// Follows the page as the window's layout changes: a resize, the sidebar, full screen.
    func reposition() {
        if isActive {
            guard let webView, webView.window != nil, controller?.selectedWebView === webView else { cancel(); return }
            place()
        }
        placePreview()
    }

    private func place() {
        guard let frame = pageFrame, let overlay else { return }
        Tokens.Motion.withoutAnimation {
            overlay.frame = frame
            // The page card's own rounded corners, so the dim never squares them off.
            var view: NSView? = webView
            while let current = view, current !== controller?.root, (current.layer?.cornerRadius ?? 0) == 0 { view = current.superview }
            if view === controller?.root { view = nil }
            overlay.layer?.cornerRadius = view?.layer?.cornerRadius ?? 0
            overlay.layer?.maskedCorners = view?.layer?.maskedCorners ?? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            overlay.layer?.cornerCurve = .continuous
        }
        overlay.needsLayout = true
        placeToolbar()
    }

    /// Centered over the page, near its bottom edge, where macOS keeps its own.
    private func placeToolbar() {
        guard let frame = pageFrame, let toolbar else { return }
        toolbar.compact = toolbar.fittingWidth(compact: false) > frame.width - Tokens.Space.x8
        let width = toolbar.fittingWidth(compact: toolbar.compact), height = Tokens.Metric.captureToolbarHeight
        toolbar.frame = NSRect(x: round(frame.midX - width / 2), y: frame.maxY - Tokens.Space.x4 - height, width: width, height: height)
        toolbar.needsLayout = true
    }

    // MARK: Keys and clicks

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, event.window === self.controller?.window else { return event }
            // A field taking the typing (the command bar, Find) ends Capture: the keys are the field's.
            if let text = event.window?.firstResponder as? NSTextView, text.isEditable { self.cancel(); return event }
            return self.handle(event) ? nil : event
        }
        // A click anywhere else in the window (the sidebar, the address) leaves capture mode and goes on.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isActive, event.window === self.controller?.window, let controller = self.controller else { return event }
            let point = controller.root.overlay.convert(event.locationInWindow, from: nil)
            let inside = [self.overlay, self.toolbar].contains { $0?.frame.contains(point) == true }
            if !inside { self.cancel() }
            return event
        }
        monitors = [keys, clicks].compactMap { $0 }
    }

    /// Esc leaves, Return takes, A, E, F and V pick the mode, the arrows nudge the area (⇧ by 10). True for a key it
    /// used; any other key goes on, ⌘ keys to the menus as ever.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags.contains(.command) || flags.contains(.control) { return false }
        switch event.keyCode {
        case 53: cancel(); return true
        case 36, 76: confirm(); return true
        case 123, 124, 125, 126:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta: NSPoint = switch event.keyCode {
            case 123: NSPoint(x: -step, y: 0)
            case 124: NSPoint(x: step, y: 0)
            case 125: NSPoint(x: 0, y: step)
            default: NSPoint(x: 0, y: -step)
            }
            if mode == .area, let overlay, let selection = overlay.selection {
                overlay.selection = CaptureGeometry.moved(selection, by: delta, in: overlay.bounds)
            }
            return true
        default: break
        }
        if let mode = Self.mode(typed: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode) { choose(mode); return true }
        return false
    }

    /// The mode a letter picks. A layout without Latin letters goes by where the letter sits on a US keyboard, as the
    /// Quit key does (#441); AZERTY and Dvorak go by the letter typed.
    static func mode(typed: String, keyCode: UInt16) -> Mode? {
        let typed = typed.lowercased()
        if let mode = Mode.allCases.first(where: { $0.key == typed }) { return mode }
        guard !typed.isEmpty, !typed.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return Mode.allCases.first { AppDelegate.ansiKeyCode($0.key) == keyCode }
    }

    // MARK: Pointing at elements

    /// Asks the page what's under the pointer, and lights it.
    func hover(at point: NSPoint) {
        guard mode == .element, let webView else { return }
        if hoverInFlight { hoverPending = point; return }
        hoverInFlight = true
        let zoom = webView.pageZoom
        webView.callAsyncJavaScript(Self.hoverScript, arguments: ["x": Double(point.x / zoom), "y": Double(point.y / zoom)], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverInFlight = false
                #if DEBUG
                self.debugLastHover = String(describing: result)
                #endif
                if self.isActive, self.mode == .element {
                    let numbers = (try? result.get()) as? [NSNumber]
                    let rect = numbers.flatMap { $0.count == 4 ? NSRect(x: $0[0].doubleValue, y: $0[1].doubleValue, width: $0[2].doubleValue, height: $0[3].doubleValue) : nil }
                    self.overlay?.setHighlight(rect.map { CaptureGeometry.viewRect(css: $0, zoom: zoom) }, animated: true)
                }
                if let next = self.hoverPending {
                    self.hoverPending = nil
                    self.hover(at: next)
                }
            }
        }
    }

    /// A click in Element mode: the element there, the one just lit.
    private func pick(at point: NSPoint) {
        guard mode == .element, overlay?.highlight != nil else { return }
        take(.element)
    }

    // MARK: Taking the picture

    /// Leaves the mode and takes the picture; then it's copied and shown.
    func take(_ kind: Mode) {
        guard !isTaking, let webView, let tab, let controller else { return }
        let area = overlay?.selection
        if kind == .area && area == nil { return }
        isTaking = true
        end()
        let title = tab.displayTitle
        Task { @MainActor [weak self, weak controller] in
            var data: Data?
            var onScreenOnly = false
            switch kind {
            case .area: data = await Self.snapshot(webView, rect: area ?? webView.bounds)
            case .visible: data = await Self.snapshot(webView, rect: webView.bounds)
            case .element: data = await Self.element(in: webView)
            case .fullPage:
                if let controller {
                    Toast.working(String(localized: "Taking a screenshot of the whole page…", comment: "Toast while Zigzag takes a screenshot of the whole page."), in: controller)
                }
                (data, onScreenOnly) = await PageScreenshot.capture(webView)
                if let controller { Toast.hide(in: controller) }
            }
            guard let self else { return }
            self.isTaking = false
            guard let controller else { return }
            guard let data else {
                Toast.show(String(localized: "Couldn’t take a screenshot of this page", comment: "Toast when a screenshot of the whole page fails."), symbol: "exclamationmark.triangle", in: controller)
                return
            }
            self.deliver(data, name: CaptureGeometry.fileName(title: title, date: Date()),
                         note: onScreenOnly ? String(localized: "Only what’s on screen: this page scrolls inside itself", comment: "On the card after Capture's Full Page, when only the visible part could be taken.") : nil)
        }
    }

    /// Copied at once, then the card with what you can do next.
    private func deliver(_ data: Data, name: String, note: String?) {
        Self.copy(data)
        guard let controller, let image = NSImage(data: data) else { return }
        let card = CapturePreview(image: image, data: data, name: name, note: note)
        card.onSave = { [weak self] in self?.save(data, name: name) }
        card.onCopy = { Self.copy(data) }
        card.onClose = { [weak self, weak card] in if self?.preview === card { self?.preview = nil } }
        preview = card
        controller.root.overlay.addSubview(card)
        placePreview()
        card.show(in: controller)
        Announcement.post(String(localized: "Screenshot copied", comment: "Toast after taking a screenshot of the whole page."))
    }

    static func copy(_ data: Data) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    func dismissPreview() {
        preview?.close()
        preview = nil
    }

    /// In the page's bottom right corner, as macOS shows its own.
    private func placePreview() {
        guard let preview, let controller else { return }
        let frame = pageFrame ?? controller.root.cardFrame
        let size = preview.fittingSize
        preview.frame = NSRect(x: frame.maxX - Tokens.Space.x3 - size.width, y: frame.maxY - Tokens.Space.x3 - size.height, width: size.width, height: size.height)
        preview.needsLayout = true
    }

    /// Into the download folder, named after the page and the time, or where you choose when downloads ask.
    private func save(_ data: Data, name: String) {
        guard let controller else { return }
        func write(to url: URL) {
            do {
                try data.write(to: url)
                #if DEBUG
                debugSaved = url
                #endif
                dismissPreview()
                Toast.show(String(localized: "Screenshot saved", comment: "Toast after saving a screenshot of the whole page."), symbol: "checkmark.circle",
                           action: (String(localized: "Show in Finder", comment: "Tooltip of a download's button in the downloads panel: shows the file in Finder."), {
                               NSWorkspace.shared.activateFileViewerSelecting([url])
                           }), duration: 5, in: controller)
            } catch {
                Toast.show(SaveFailure.message(String(localized: "Couldn’t save the screenshot", comment: "Toast when saving a screenshot fails; a reason may follow as its own sentence."), error), symbol: "exclamationmark.triangle", duration: 4, in: controller)
            }
        }
        guard DownloadManager.asksWhereToSave, let window = controller.window else {
            write(to: DownloadManager.uniqueDestination(for: name, in: DownloadManager.folder))
            return
        }
        preview?.holds = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        panel.directoryURL = DownloadManager.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.preview?.holds = false
                guard response == .OK, let url = panel.url else { return }
                write(to: url)
            }
        }
    }

    // MARK: Pictures

    /// What's on screen in `rect` (the web view's points), at the screen's sharpness.
    static func snapshot(_ webView: WKWebView, rect: NSRect) async -> Data? {
        let rect = CaptureGeometry.pixelAligned(rect.intersection(webView.bounds), scale: webView.window?.backingScaleFactor ?? 2)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        guard let image = try? await webView.takeSnapshot(configuration: configuration), let picture = sharpest(image) else { return nil }
        let scale = CGFloat(picture.width) / rect.width
        return await Task.detached(priority: .userInitiated) { PageScreenshot.png(picture, scale: scale) }.value
    }

    /// The image's largest bitmap, not the one the main screen would pick.
    private static func sharpest(_ image: NSImage) -> CGImage? {
        var proposed = NSRect(origin: .zero, size: image.size)
        let best = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        return (best as? NSBitmapImageRep)?.cgImage ?? best?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            ?? image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    /// What the page says about the element last lit.
    private struct Measure: Decodable {
        var rect: [CGFloat]
        var scroll: [CGFloat]
        var view: [CGFloat]
        var inner: Bool
        var pinned: Bool
        var css: NSRect { NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
    }

    private static func measure(_ webView: WKWebView, script: String) async -> Measure? {
        guard let json = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String else { return nil }
        return try? JSONDecoder().decode(Measure.self, from: Data(json.utf8))
    }

    /// The element whole: as it is when it's all on screen; scrolled into view when it fits, behind a still of the
    /// page so nothing jumps, and back; drawn in one piece from the page when it's bigger than the screen.
    private static func element(in webView: WKWebView) async -> Data? {
        guard let found = await measure(webView, script: measureScript) else { return nil }
        let zoom = webView.pageZoom
        let viewport = NSSize(width: found.view[0], height: found.view[1])
        switch CaptureGeometry.route(css: found.css, viewport: viewport, inner: found.inner, pinned: found.pinned) {
        case .onScreen, .visiblePart:
            return await snapshot(webView, rect: CaptureGeometry.viewRect(css: found.css, zoom: zoom))
        case .scrollIntoView:
            let cover = await PageScreenshot.coverPage(webView)
            let moved = await measure(webView, script: bringIntoViewScript)
            var data: Data?
            if let moved { data = await snapshot(webView, rect: CaptureGeometry.viewRect(css: moved.css, zoom: zoom)) }
            _ = try? await webView.callAsyncJavaScript(restoreScript, contentWorld: .defaultClient)
            cover?.removeFromSuperview()
            return data
        case .whole:
            let configuration = WKPDFConfiguration()
            let page = found.css.offsetBy(dx: found.scroll[0], dy: found.scroll[1])
            configuration.rect = CaptureGeometry.viewRect(css: page, zoom: zoom)
            guard let pdf = try? await webView.pdf(configuration: configuration) else { return nil }
            let backing = webView.window?.backingScaleFactor ?? 2
            return await Task.detached(priority: .userInitiated) { PageScreenshot.render(pdf, backing: backing) }.value
        }
    }

    /// The pointer while capturing, set on the page too: WebKit sets its own as the pointer moves over it.
    private func setPageCursor(_ cursor: String?, in webView: WKWebView) {
        webView.callAsyncJavaScript(Self.cursorScript, arguments: ["cursor": cursor ?? ""], in: nil, in: .defaultClient, completionHandler: nil)
    }

    // MARK: Scripts

    /// The element under (x, y) worth a picture: through shadow roots, up from inline words and anything too small
    /// to mean much, out to the outermost box of the same size, and nothing for the page's own background. Kept in
    /// Zigzag's script world for the click.
    private static let hoverScript = """
    const deepest = (x, y) => {
      let el = document.elementFromPoint(x, y);
      while (el && el.shadowRoot) {
        const inner = el.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      return el;
    };
    const up = (el) => el.parentElement || (el.parentNode instanceof ShadowRoot ? el.parentNode.host : null);
    const root = document.documentElement, body = document.body;
    const whole = new Set(['img', 'video', 'canvas', 'svg', 'picture', 'iframe', 'embed', 'object', 'input', 'textarea', 'select', 'button']);
    const same = (a, b) => Math.abs(a.left - b.left) <= 2 && Math.abs(a.top - b.top) <= 2 && Math.abs(a.right - b.right) <= 2 && Math.abs(a.bottom - b.bottom) <= 2;
    let el = deepest(x, y);
    while (el && el instanceof SVGElement && el.tagName.toLowerCase() !== 'svg') el = up(el);
    let pick = null;
    for (let n = el; n && n !== root && n !== body; n = up(n)) {
      const r = n.getBoundingClientRect(), tag = n.tagName.toLowerCase();
      if (r.width < 1 || r.height < 1) continue;
      if (whole.has(tag)) { if (r.width >= 12 && r.height >= 12) { pick = n; break; } continue; }
      const display = getComputedStyle(n).display;
      if (display === 'inline' || display === 'contents') continue;
      if (r.width < 24 || r.height < 16 || r.width * r.height < 900) continue;
      pick = n;
      break;
    }
    if (pick) {
      for (let p = up(pick); p && p !== root && p !== body && same(pick.getBoundingClientRect(), p.getBoundingClientRect()); p = up(p)) pick = p;
      const r = pick.getBoundingClientRect(), w = root.clientWidth || innerWidth, h = root.clientHeight || innerHeight;
      if (r.width >= w * 0.98 && r.height >= h * 0.98) pick = null;
    }
    window.__zigzagCapture = pick ? new WeakRef(pick) : null;
    if (!pick) return null;
    const r = pick.getBoundingClientRect();
    return [r.left, r.top, r.width, r.height];
    """

    /// The lit element's box, the page's scroll and viewport, whether a box inside the page scrolls around it, and
    /// whether it or what holds it stays put as the page scrolls.
    private static let measureBody = """
    const el = window.__zigzagCapture && window.__zigzagCapture.deref();
    if (!el || !el.isConnected) return null;
    const root = document.documentElement, body = document.body;
    let inner = false, pinned = false;
    for (let n = el; n && n !== root; n = n.parentElement) {
      const s = getComputedStyle(n);
      if (s.position === 'fixed' || s.position === 'sticky') pinned = true;
      if (n === el || n === body) continue;
      const scrollsY = /(auto|scroll|overlay)/.test(s.overflowY) && n.scrollHeight > n.clientHeight + 1;
      const scrollsX = /(auto|scroll|overlay)/.test(s.overflowX) && n.scrollWidth > n.clientWidth + 1;
      if (scrollsY || scrollsX) inner = true;
    }
    const r = el.getBoundingClientRect();
    return JSON.stringify({ rect: [r.left, r.top, r.width, r.height], scroll: [scrollX, scrollY],
                            view: [root.clientWidth || innerWidth, root.clientHeight || innerHeight], inner, pinned });
    """

    private static let measureScript = measureBody

    /// Scrolls the lit element to the middle of the screen, noting where the page and every box around it were.
    private static let bringIntoViewScript = """
    const target = window.__zigzagCapture && window.__zigzagCapture.deref();
    if (!target || !target.isConnected) return null;
    const saved = [[null, scrollX, scrollY]];
    for (let n = target.parentElement; n; n = n.parentElement) saved.push([n, n.scrollLeft, n.scrollTop]);
    window.__zigzagCaptureScroll = saved;
    target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    await Promise.race([new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))), new Promise((done) => setTimeout(done, 200))]);
    await new Promise((done) => setTimeout(done, 50));
    """ + measureBody

    /// Back where you were.
    private static let restoreScript = """
    const saved = window.__zigzagCaptureScroll || [];
    window.__zigzagCaptureScroll = null;
    for (const [n, x, y] of saved.reverse()) {
      if (n) n.scrollTo({ left: x, top: y, behavior: 'instant' }); else window.scrollTo({ left: x, top: y, behavior: 'instant' });
    }
    """

    /// One style on the page for the pointer while capturing; an empty `cursor` takes it away.
    private static let cursorScript = """
    let style = document.getElementById('__zigzag-capture');
    if (!cursor) { if (style) style.remove(); return; }
    if (!style) { style = document.createElement('style'); style.id = '__zigzag-capture'; (document.head || document.documentElement).appendChild(style); }
    style.textContent = `html, html * { cursor: ${cursor} !important; }`;
    """

    #if DEBUG
    /// `capture state <path>`: what the mode shows, as JSON.
    var debugState: [String: Any] {
        func numbers(_ r: NSRect?) -> [Double] { r.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? [] }
        return ["active": isActive, "mode": mode.rawValue, "selection": numbers(overlay?.selection), "highlight": numbers(overlay?.highlight),
                "toolbar": numbers(toolbar?.frame), "page": numbers(pageFrame), "preview": numbers(preview?.frame),
                "compact": toolbar?.compact ?? false, "saved": debugSaved?.path ?? "", "taking": isTaking,
                "hoverInFlight": hoverInFlight, "lastHover": debugLastHover]
    }

    /// `capture drag x y w h`: an area drawn as a drag would, in the page's points.
    func debugDrag(_ rect: NSRect) {
        guard let overlay else { return }
        if mode == .element { setMode(.area, remember: false) }
        overlay.selection = CaptureGeometry.rect(from: rect.origin, to: NSPoint(x: rect.maxX, y: rect.maxY), in: overlay.bounds)
    }

    /// `capture hover x y`: the pointer at that point of the page, as a move would put it.
    func debugHover(_ point: NSPoint) {
        overlay?.pointer = point
        hover(at: point)
    }

    var debugPreview: CapturePreview? { preview }
    #endif
}

/// The arithmetic of Capture, apart from any view so it can be checked on its own.
enum CaptureGeometry {
    /// An area from where a drag began to where it is, within `bounds`.
    static func rect(from start: NSPoint, to end: NSPoint, in bounds: NSRect) -> NSRect {
        let a = clamp(start, to: bounds), b = clamp(end, to: bounds)
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func clamp(_ point: NSPoint, to bounds: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// The area moved by `delta`, its size kept, stopping at the edges.
    static func moved(_ rect: NSRect, by delta: NSPoint, in bounds: NSRect) -> NSRect {
        var moved = rect.offsetBy(dx: delta.x, dy: delta.y)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    /// The grips, clockwise from the top left (top-left origin): corners and the middles of the sides.
    static func handles(of r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.midY),
         NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    /// The area with grip `handle` dragged to `point`: its edges follow, the opposite ones stay, and dragged past
    /// them it turns over rather than vanishing.
    static func resized(_ r: NSRect, handle: Int, to point: NSPoint, in bounds: NSRect) -> NSRect {
        let p = clamp(point, to: bounds)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [0, 6, 7].contains(handle) { minX = p.x }
        if [2, 3, 4].contains(handle) { maxX = p.x }
        if [0, 1, 2].contains(handle) { minY = p.y }
        if [4, 5, 6].contains(handle) { maxY = p.y }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// "640 × 360": the area's size in points, as macOS shows it while you drag.
    static func sizeText(_ size: NSSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// The page's CSS pixels in the web view's points.
    static func viewRect(css: NSRect, zoom: CGFloat) -> NSRect {
        NSRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
    }

    /// Each edge on the screen's pixels, so a picture never takes half a pixel's blur at its sides.
    static func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
        guard !rect.isNull, scale > 0 else { return .zero }
        let minX = (rect.minX * scale).rounded() / scale, minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale, maxY = (rect.maxY * scale).rounded() / scale
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// How an element's picture is taken.
    enum Route: Equatable {
        /// All of it is on screen.
        case onScreen
        /// It fits on screen: scrolled there for the picture, then back.
        case scrollIntoView
        /// Bigger than the screen, in a page that scrolls itself: drawn in one piece from the page.
        case whole
        /// Bigger than the screen inside a box that scrolls, or pinned in place: what of it shows.
        case visiblePart
    }

    static func route(css: NSRect, viewport: NSSize, inner: Bool, pinned: Bool) -> Route {
        let screen = NSRect(origin: .zero, size: viewport).insetBy(dx: -1, dy: -1)
        if screen.contains(css) { return .onScreen }
        if pinned { return .visiblePart }
        if css.width <= viewport.width, css.height <= viewport.height { return .scrollIntoView }
        return inner ? .visiblePart : .whole
    }

    /// "Page title 2026-11-21 at 14.03.22.png": the page's name and when, as macOS names its screenshots.
    static func fileName(title: String, date: Date) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = String(localized: "Capture", comment: "Action in the site panel, under its icon: takes a screenshot of the whole page.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)
        return String(localized: "\(name) \(day) at \(time).png", comment: "A captured picture's file name: the page's title, the day (2026-11-21) and the time (14.03.22).")
    }

    /// The card's picture: the capture's shape at `width`, a tall one cut to `maxHeight` from its top.
    static func thumbnailSize(for image: NSSize, width: CGFloat, maxHeight: CGFloat) -> NSSize {
        guard image.width > 0, image.height > 0 else { return NSSize(width: width, height: maxHeight) }
        let height = width * image.height / image.width
        return NSSize(width: width, height: min(max(height, Tokens.Space.x8), maxHeight))
    }
}

/// The dim over the page while capturing, with what's picked clear in it: an area you drag (with grips once drawn
/// and its size beside it), or the element under the pointer.
final class CaptureOverlay: NSView {
    var mode: PageCapture.Mode = .area {
        didSet { window?.invalidateCursorRects(for: self); refresh() }
    }
    /// The area drawn, in this view's (the web view's) points.
    var selection: NSRect? {
        didSet {
            guard selection != oldValue else { return }
            refresh()
            window?.invalidateCursorRects(for: self)
            onSelectionChange?()
        }
    }
    /// The element under the pointer, as the page laid it out.
    private(set) var highlight: NSRect?
    /// Where the pointer is over the page, for asking again after a scroll.
    var pointer: NSPoint?

    var onHover: ((NSPoint) -> Void)?
    var onPick: ((NSPoint) -> Void)?
    var onConfirm: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDrawStart: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    private let scrim = CAShapeLayer()
    private let edge = CAShapeLayer()
    private var grips: [CAShapeLayer] = []
    private let sizeTag = CaptureSizeTag()
    private var tracking: NSTrackingArea?

    private enum Drag {
        case drawing(start: NSPoint)
        case moving(start: NSPoint, original: NSRect)
        case resizing(handle: Int, original: NSRect)
    }
    private var drag: Drag?
    private var pressedAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        scrim.fillRule = .evenOdd
        edge.fillColor = nil
        layer?.addSublayer(scrim)
        layer?.addSublayer(edge)
        for _ in 0..<8 {
            let grip = CAShapeLayer()
            grip.lineWidth = Tokens.Metric.hairline
            grip.shadowOpacity = 1
            grip.shadowRadius = 1.5
            grip.shadowOffset = CGSize(width: 0, height: -0.5)
            layer?.addSublayer(grip)
            grips.append(grip)
        }
        addSubview(sizeTag)
        sizeTag.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Capture", comment: "Action in the site panel, under its icon: takes a screenshot of the whole page."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// The dim fades in where it is.
    func present() {
        alphaValue = 0
        Tokens.Motion.fadeBackdrop(self, entering: true)
    }

    func dismiss() {
        // Clicks reach the page at once while it fades.
        onHover = nil; onPick = nil; onConfirm = nil; onScroll = nil; onDrawStart = nil; onSelectionChange = nil
        isHiddenForClicks = true
        Tokens.Motion.fadeBackdrop(self, entering: false) { [weak self] in self?.removeFromSuperview() }
    }
    private var isHiddenForClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { isHiddenForClicks ? nil : super.hitTest(point) }

    /// Lights the element under the pointer; between two elements the clear part glides, as a menu's highlight does.
    func setHighlight(_ rect: NSRect?, animated: Bool) {
        let rect = rect.map { $0.intersection(bounds) }.flatMap { $0.isNull || $0.width < 1 || $0.height < 1 ? nil : $0 }
        guard rect != highlight else { return }
        let glides = animated && highlight != nil && rect != nil && !Tokens.Motion.reduceMotion
        highlight = rect
        refresh(gliding: glides)
    }

    private var hole: NSRect? { mode == .area ? selection : highlight }

    private func refresh(gliding: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = Brand.Theme.for(self).accent
            Tokens.Motion.withoutAnimation {
                scrim.frame = bounds
                edge.frame = bounds
                scrim.fillColor = Tokens.Color.captureScrim.cgColor
                let path = CGMutablePath()
                path.addRect(bounds)
                let radius: CGFloat = mode == .element ? Tokens.Radius.small : 0
                var edgePath: CGPath?
                if let hole {
                    let shape = CGPath(roundedRect: hole, cornerWidth: min(radius, hole.width / 2), cornerHeight: min(radius, hole.height / 2), transform: nil)
                    path.addPath(shape)
                    edgePath = shape
                }
                let oldScrim = scrim.presentation()?.path ?? scrim.path, oldEdge = edge.presentation()?.path ?? edge.path
                scrim.path = path
                edge.path = edgePath
                edge.strokeColor = (mode == .element ? accent : Tokens.Color.captureEdge).cgColor
                edge.lineWidth = mode == .element ? Tokens.Metric.dropEdge : Tokens.Metric.hairline
                if gliding, let oldScrim, let oldEdge {
                    for (layer, from) in [(scrim, oldScrim), (edge, oldEdge)] {
                        let glide = CABasicAnimation(keyPath: "path")
                        glide.fromValue = from
                        glide.duration = Tokens.Motion.highlightGlide * Tokens.Motion.debugSlowdown
                        glide.timingFunction = Tokens.Motion.easeOut
                        layer.add(glide, forKey: "glide")
                    }
                } else {
                    scrim.removeAnimation(forKey: "glide")
                    edge.removeAnimation(forKey: "glide")
                }
                let points = mode == .area ? selection.map(CaptureGeometry.handles(of:)) ?? [] : []
                let side = Tokens.Metric.captureHandle
                for (i, grip) in grips.enumerated() {
                    grip.isHidden = i >= points.count
                    guard i < points.count else { continue }
                    grip.frame = NSRect(x: points[i].x - side / 2, y: points[i].y - side / 2, width: side, height: side)
                    grip.path = CGPath(ellipseIn: grip.bounds, transform: nil)
                    grip.fillColor = NSColor.white.cgColor
                    grip.strokeColor = Tokens.Color.panelEdge.cgColor
                    grip.shadowColor = Tokens.Color.panelShadow.cgColor
                }
            }
        }
        placeSizeTag()
    }

    /// The size under the area, or over it when there's no room, or inside it at the page's foot.
    private func placeSizeTag() {
        guard let hole else { sizeTag.isHidden = true; return }
        sizeTag.isHidden = false
        sizeTag.text = CaptureGeometry.sizeText(hole.size)
        let size = sizeTag.fittingSize
        let gap = Tokens.Space.x2
        var y = hole.maxY + gap
        if y + size.height > bounds.maxY - gap { y = hole.minY - gap - size.height }
        if y < bounds.minY + gap { y = hole.maxY - gap - size.height }
        let x = min(max(round(hole.midX - size.width / 2), bounds.minX + gap), bounds.maxX - gap - size.width)
        sizeTag.frame = NSRect(x: x, y: round(y), width: size.width, height: size.height)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard mode == .area else { addCursorRect(bounds, cursor: .arrow); return }
        addCursorRect(bounds, cursor: .crosshair)
        guard let selection else { return }
        for (rect, cursor) in Self.cursorRects(for: selection) { addCursorRect(rect, cursor: cursor) }
    }

    /// The move area and the grips of `selection`; a click without a drag leaves a selection too small for a move
    /// area, and AppKit throws on an empty or null cursor rect.
    static func cursorRects(for selection: NSRect) -> [(NSRect, NSCursor)] {
        guard selection.minX.isFinite, selection.minY.isFinite, selection.width.isFinite, selection.height.isFinite else { return [] }
        var rects: [(NSRect, NSCursor)] = []
        let inner = selection.insetBy(dx: Tokens.Metric.captureHandle, dy: Tokens.Metric.captureHandle)
        if !inner.isNull, !inner.isEmpty { rects.append((inner, .openHand)) }
        let side = Tokens.Metric.captureHandle * 2
        for (i, point) in CaptureGeometry.handles(of: selection).enumerated() {
            rects.append((NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), resizeCursor(i)))
        }
        return rects
    }

    /// The Mac's own resize pointers, by grip.
    private static func resizeCursor(_ handle: Int) -> NSCursor {
        let position: NSCursor.FrameResizePosition = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left][handle]
        return NSCursor.frameResize(position: position, directions: .all)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor(at: point).set()
    }

    private func cursor(at point: NSPoint) -> NSCursor {
        guard mode == .area else { return .arrow }
        if let selection {
            if let handle = handle(at: point) { return Self.resizeCursor(handle) }
            if selection.contains(point) { return .openHand }
        }
        return .crosshair
    }

    private func handle(at point: NSPoint) -> Int? {
        guard let selection else { return nil }
        let reach = Tokens.Metric.captureHandle
        return CaptureGeometry.handles(of: selection).enumerated().first { hypot($0.element.x - point.x, $0.element.y - point.y) <= reach }?.offset
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        cursor(at: point).set()
        if mode == .element { onHover?(point) }
    }

    override func mouseExited(with event: NSEvent) {
        if mode == .element { setHighlight(nil, animated: false) }
    }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedAt = point
        if event.clickCount == 2, mode == .area, selection?.contains(point) == true { onConfirm?(); return }
        guard mode == .area else { drag = nil; return }
        if let selection, let handle = handle(at: point) {
            drag = .resizing(handle: handle, original: selection)
        } else if let selection, selection.contains(point) {
            drag = .moving(start: point, original: selection)
            NSCursor.closedHand.set()
        } else {
            drag = .drawing(start: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if mode == .element, let start = pressedAt, hypot(point.x - start.x, point.y - start.y) > 4 {
            // Dragged in Element mode: an area after all, from where the press began.
            onDrawStart?()
            drag = .drawing(start: start)
        }
        switch drag {
        case .drawing(let start): selection = CaptureGeometry.rect(from: start, to: point, in: bounds)
        case .moving(let start, let original):
            selection = CaptureGeometry.moved(original, by: NSPoint(x: point.x - start.x, y: point.y - start.y), in: bounds)
        case .resizing(let handle, let original): selection = CaptureGeometry.resized(original, handle: handle, to: point, in: bounds)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { drag = nil; pressedAt = nil }
        switch drag {
        case .drawing:
            // Too small to mean an area: a click, which clears what was drawn.
            if let selection, selection.width < Tokens.Metric.captureMinSide || selection.height < Tokens.Metric.captureMinSide { self.selection = nil }
        case nil:
            if mode == .element { onPick?(point) }
        default: break
        }
        cursor(at: point).set()
    }

    override func rightMouseDown(with event: NSEvent) {}
}

/// The area's size, on a small capsule beside it.
final class CaptureSizeTag: FloatingPanelView {
    private let label = Label("", font: Tokens.Font.figures(Tokens.TypeSize.small, weight: .medium), color: Tokens.Color.textPrimary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        onLayout = { [weak self] in
            guard let self else { return }
            self.radius = self.bounds.height / 2
            self.label.frame = NSRect(x: Tokens.Space.x2 - Label.inset, y: self.label.centeredY(in: self.bounds.height),
                                      width: self.label.inkWidth + Label.inset * 2, height: self.label.lineHeight)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue; needsLayout = true } }
    }

    override var fittingSize: NSSize { NSSize(width: ceil(label.inkWidth) + Tokens.Space.x2 * 2, height: Tokens.Space.x5 + 2) }
}

/// Capture's toolbar: Area and Element (the two ways to pick), Full Page and Visible (taken at once), Capture once an
/// area is drawn, and Cancel. A capsule in the floating panel's look, near the page's foot.
final class CaptureToolbar: FloatingPanelView {
    var onChoose: ((PageCapture.Mode) -> Void)?
    var onCapture: (() -> Void)?
    var onCancel: (() -> Void)?

    private let buttons: [PageCapture.Mode: CaptureButton]
    private let lines = [ColorView(color: Tokens.Color.separator), ColorView(color: Tokens.Color.separator)]
    private let captureButton = PillButton(title: String(localized: "Capture", comment: "Capture's toolbar: takes the picture of the area drawn."), style: .prominent)
    private let cancelButton = IconButton(symbol: "xmark", size: Tokens.Metric.controlHeight, symbolSize: Tokens.Pane.glyph,
                                          toolTip: String(localized: "Cancel (Esc)", comment: "Tooltip of the close button in Capture's toolbar."))
    private static let order: [PageCapture.Mode] = [.area, .element, .fullPage, .visible]

    var mode: PageCapture.Mode = .area {
        didSet { for (kind, button) in buttons { button.isSelected = kind == mode } }
    }
    var showsCapture = false { didSet { if showsCapture != oldValue { captureButton.isHidden = !showsCapture; needsLayout = true } } }
    /// Icons alone, where the page is too narrow for the names.
    var compact = false { didSet { if compact != oldValue { buttons.values.forEach { $0.showsTitle = !compact }; needsLayout = true } } }

    override init(frame: NSRect) {
        var buttons: [PageCapture.Mode: CaptureButton] = [:]
        for mode in Self.order {
            buttons[mode] = CaptureButton(symbol: Self.symbol(mode), title: Self.title(mode), toolTip: Self.toolTip(mode), isChoice: mode == .area || mode == .element)
        }
        self.buttons = buttons
        super.init(frame: frame)
        for mode in Self.order {
            guard let button = buttons[mode] else { continue }
            button.onClick = { [weak self] _ in self?.onChoose?(mode) }
            addSubview(button)
        }
        lines.forEach { addSubview($0) }
        captureButton.isHidden = true
        captureButton.toolTip = String(localized: "Capture (Return)", comment: "Tooltip of the Capture button in Capture's toolbar.")
        captureButton.onClick = { [weak self] _ in self?.onCapture?() }
        cancelButton.onClick = { [weak self] _ in self?.onCancel?() }
        cancelButton.setAccessibilityLabel(String(localized: "Cancel", comment: "Button in a sheet."))
        addSubview(captureButton)
        addSubview(cancelButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Capture", comment: "Action in the site panel, under its icon: takes a screenshot of the whole page."))
        onLayout = { [weak self] in self?.layoutButtons() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A panel you open in Zigzag takes the place of an extension's popup.
    override var replacesExtensionPopup: Bool { true }

    static func symbol(_ mode: PageCapture.Mode) -> String {
        switch mode {
        case .area: "rectangle.dashed"
        case .element: "cursorarrow.and.square.on.square.dashed"
        case .fullPage: "rectangle.expand.vertical"
        case .visible: "rectangle.inset.filled"
        }
    }

    static func title(_ mode: PageCapture.Mode) -> String {
        switch mode {
        case .area: String(localized: "Area", comment: "Capture's toolbar: drag over the page to pick an area.")
        case .element: String(localized: "Element", comment: "Capture's toolbar: point at a part of the page (an element) and click to take it.")
        case .fullPage: String(localized: "Full Page", comment: "Capture's toolbar: takes the whole page, top to bottom.")
        case .visible: String(localized: "Visible", comment: "Capture's toolbar: takes what's on screen.")
        }
    }

    static func toolTip(_ mode: PageCapture.Mode) -> String {
        switch mode {
        case .area: String(localized: "Drag to Pick an Area (A)", comment: "Tooltip of Area in Capture's toolbar; A is its key.")
        case .element: String(localized: "Click a Part of the Page (E)", comment: "Tooltip of Element in Capture's toolbar; E is its key.")
        case .fullPage: String(localized: "Capture the Whole Page (F)", comment: "Tooltip of Full Page in Capture's toolbar; F is its key.")
        case .visible: String(localized: "Capture What’s on Screen (V)", comment: "Tooltip of Visible in Capture's toolbar; V is its key.")
        }
    }

    private static let inset = Tokens.Space.x1 + 2
    private static let gap: CGFloat = 2
    private static let lineRoom = Tokens.Space.x2 + 1

    func fittingWidth(compact: Bool) -> CGFloat {
        let modes = Self.order.compactMap { buttons[$0]?.fittingWidth(titled: !compact) }.reduce(0, +) + Self.gap * CGFloat(Self.order.count - 2)
        let capture = showsCapture ? captureButton.fittingWidth + Self.gap : 0
        return ceil(Self.inset * 2 + modes + Self.lineRoom * 2 + capture + Tokens.Metric.controlHeight)
    }

    private func layoutButtons() {
        radius = bounds.height / 2
        let h = Tokens.Metric.controlHeight, y = (bounds.height - h) / 2
        var x = Self.inset
        for (i, mode) in Self.order.enumerated() {
            guard let button = buttons[mode] else { continue }
            if i == 2 {
                lines[0].frame = NSRect(x: x + (Self.lineRoom - Self.gap - 1) / 2, y: (bounds.height - Tokens.Space.x4) / 2, width: 1, height: Tokens.Space.x4)
                x += Self.lineRoom - Self.gap
            }
            let width = button.fittingWidth(titled: !compact)
            button.frame = NSRect(x: x, y: y, width: width, height: h)
            x += width + Self.gap
        }
        x -= Self.gap
        lines[1].frame = NSRect(x: x + (Self.lineRoom - 1) / 2, y: (bounds.height - Tokens.Space.x4) / 2, width: 1, height: Tokens.Space.x4)
        x += Self.lineRoom
        if showsCapture {
            captureButton.frame = NSRect(x: x, y: y, width: captureButton.fittingWidth, height: h)
            x = captureButton.frame.maxX + Self.gap
        }
        cancelButton.frame = NSRect(x: bounds.width - Self.inset - h, y: y, width: h, height: h)
    }
}

/// One of the toolbar's buttons: a thin glyph and its name on a capsule; the mode you're in is the soft card.
final class CaptureButton: InteractiveView {
    private let iconView = NSImageView()
    private let label: Label
    private let symbol: String
    /// Area and Element are choices that stay chosen; Full Page and Visible act at once.
    private let isChoice: Bool
    var showsTitle = true { didSet { label.isHidden = !showsTitle; needsLayout = true } }

    init(symbol: String, title: String, toolTip: String, isChoice: Bool) {
        self.symbol = symbol
        self.isChoice = isChoice
        label = Label(title, font: Tokens.Font.control(), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerCurve = .continuous
        iconView.image = Tokens.Symbol.image(symbol, size: Tokens.Symbol.compactGlyph)
        iconView.imageScaling = .scaleNone
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(label)
        self.toolTip = toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(isChoice ? .radioButton : .button)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let pad = Tokens.Space.x2 + 2
    private static let iconGap = Tokens.Space.x1 + 2

    func fittingWidth(titled: Bool) -> CGFloat {
        guard titled else { return Tokens.Metric.controlHeight }
        return ceil(Self.pad * 2 + Tokens.Symbol.compactGlyph + Self.iconGap + label.inkWidth)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let image = iconView.image?.size ?? NSSize(width: Tokens.Symbol.compactGlyph, height: Tokens.Symbol.compactGlyph)
        let ink = Tokens.Symbol.inkOffset(symbol, size: Tokens.Symbol.compactGlyph)
        let slot = Tokens.Symbol.compactGlyph
        let slotX = showsTitle ? Self.pad : (bounds.width - slot) / 2
        let scale = window?.backingScaleFactor ?? 2
        let x = slotX + slot / 2 - image.width / 2 - ink.width, y = bounds.midY - image.height / 2 + ink.height
        iconView.frame = NSRect(x: round(x * scale) / scale, y: round(y * scale) / scale, width: image.width, height: image.height)
        let textX = Self.pad + slot + Self.iconGap
        label.frame = NSRect(x: textX - Label.inset, y: label.centeredY(in: bounds.height), width: label.inkWidth + Label.inset * 2, height: label.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        applyRowStyle(animated: animated)
        if isChoice { setAccessibilityValue(isSelected) }
        iconView.contentTintColor = isSelected || isHovered ? Tokens.Color.textPrimary : Tokens.Color.icon
    }
}
