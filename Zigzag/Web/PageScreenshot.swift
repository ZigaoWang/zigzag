import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// A picture of the whole page, top to bottom, copied for pasting with Save… one click away.
///
/// Pages load as you scroll (images, whole sections), so a picture taken straight away is full of blanks. First the
/// page is scrolled through once, behind a still of what you were looking at so nothing jumps, then it waits for
/// its images and fonts, goes back to the top so sticky headers sit there once, and is drawn in one piece.
///
/// Web apps (mail, chats, documents) keep the page still and scroll a box inside it, sometimes in a frame from
/// another site. Then that box is scrolled through instead and pictured a screenful at a time, stitched together.
@MainActor
enum PageScreenshot {
    private static var isTaking = false

    /// Long enough for nearly any page; endless feeds stop here instead of scrolling forever.
    private static let maxViewports = 40
    /// Big pictures are drawn smaller rather than failing: the longest side and the total pixels have a ceiling.
    nonisolated private static let maxPixelHeight: CGFloat = 32_000
    nonisolated private static let maxPixels: CGFloat = 150_000_000

    static func canTake(_ tab: Tab?) -> Bool {
        // A PDF in Zigzag's viewer isn't the page underneath: Save gives you the file itself.
        guard let tab, tab.webView != nil, tab.pdfViewer == nil, let scheme = tab.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    static func take(_ tab: Tab, in controller: BrowserWindowController) {
        guard !isTaking, canTake(tab), let webView = tab.webView else { return }
        isTaking = true
        Toast.show("Taking a picture of the whole page…", symbol: "camera.viewfinder", duration: 30, in: controller)
        Task { @MainActor in
            defer { isTaking = false }
            let (data, onScreenOnly) = await capture(webView)
            guard let data else {
                Toast.show("Couldn’t take a picture of this page", symbol: "exclamationmark.triangle", in: controller)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            let name = fileName(for: tab)
            let note = onScreenOnly ? "Copied what’s on screen: this page scrolls inside itself" : "Screenshot of the whole page copied"
            Toast.show(note, symbol: "camera.viewfinder", action: ("Save", { [weak controller] in
                guard let controller else { return }
                save(data, name: name, in: controller)
            }), duration: 8, in: controller)
        }
    }

    // MARK: Steps

    /// The picture as PNG data, and whether it could only be what's on screen.
    private static func capture(_ webView: WKWebView) async -> (Data?, Bool) {
        let cover = await coverPage(webView)
        // However it ends, the still comes off.
        defer { cover?.removeFromSuperview() }
        if let scroller = await findScroller(webView), let data = await captureScroller(scroller, in: webView) {
            return (data, false)
        }
        let page = await prepare(webView)
        let data = await draw(webView, height: page?.height)
        restore(webView, page: page)
        return (data, page?.scrollsInside == true)
    }

    #if DEBUG
    /// For testing: the picture goes to a file, never your clipboard.
    static func debugCapture(_ webView: WKWebView, to url: URL) {
        Task { @MainActor in try? await capture(webView).0?.write(to: url) }
    }
    #endif

    /// A still of the page over it while it scrolls underneath, so the page doesn't race past your eyes. It sits
    /// inside the web view, so switching tabs meanwhile takes it away with its page, not over the next one.
    private static func coverPage(_ webView: WKWebView) async -> NSView? {
        guard webView.window != nil, let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        let still = NSImageView(frame: webView.bounds)
        still.image = image
        still.imageScaling = .scaleAxesIndependently
        still.autoresizingMask = [.width, .height]
        webView.addSubview(still)
        return still
    }

    private struct Page { var height: CGFloat; var x: CGFloat; var y: CGFloat; var scrollsInside: Bool }

    /// Scrolls through so everything that loads on sight loads, waits for it, then goes to the top.
    private static func prepare(_ webView: WKWebView) async -> Page? {
        let script = """
        const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
        const root = document.scrollingElement || document.documentElement;
        const start = { x: window.scrollX, y: window.scrollY };
        const limit = window.innerHeight * \(maxViewports);
        document.querySelectorAll('img[loading="lazy"], iframe[loading="lazy"]').forEach((el) => { el.loading = 'eager'; });
        const step = Math.max(200, window.innerHeight * 0.85);
        for (let y = 0; y < Math.min(root.scrollHeight, limit); y += step) {
          window.scrollTo(0, y);
          await sleep(80);
        }
        window.scrollTo(0, Math.min(root.scrollHeight, limit));
        await sleep(250);
        const pending = Array.from(document.images).filter((img) => !img.complete);
        await Promise.race([Promise.all(pending.map((img) => img.decode().catch(() => {}))), sleep(3000)]);
        if (document.fonts) { await Promise.race([document.fonts.ready, sleep(1000)]); }
        window.scrollTo(0, 0);
        await sleep(150);
        return { height: Math.min(root.scrollHeight, limit), x: start.x, y: start.y,
                 inside: root.scrollHeight <= window.innerHeight + 2 };
        """
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat { CGFloat((result[key] as? NSNumber)?.doubleValue ?? 0) }
        return Page(height: number("height"), x: number("x"), y: number("y"), scrollsInside: (result["inside"] as? Bool) ?? false)
    }

    /// The page as one tall PDF page, drawn into a picture.
    private static func draw(_ webView: WKWebView, height: CGFloat?) async -> Data? {
        let configuration = WKPDFConfiguration()
        // Past the ceiling an endless feed is cut off where the scroll-through stopped.
        if let height, height > 0 {
            let zoom = webView.pageZoom
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height * zoom)
        }
        guard let pdf = try? await webView.pdf(configuration: configuration) else { return nil }
        let backing = webView.window?.backingScaleFactor ?? 2
        // Drawing and encoding a picture this big takes a while: off the main thread, so the window stays live.
        return await Task.detached(priority: .userInitiated) { render(pdf, backing: backing) }.value
    }

    /// The one-page PDF drawn into a PNG, at the screen's sharpness within the ceilings.
    nonisolated private static func render(_ pdf: Data, backing: CGFloat) -> Data? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let size = box.size
        guard size.width > 0, size.height > 0 else { return nil }
        // At least half size for a sharp enough picture, but the ceilings come last: they're what keeps it drawable.
        let scale = min(max(0.5, backing), maxPixelHeight / size.height, (maxPixels / (size.width * size.height)).squareRoot())
        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Pages without a background of their own are white, as on screen.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return png(image, scale: scale)
    }

    /// The picture as a PNG, marked with its sharpness (pixels per point).
    nonisolated private static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        // Marked with its sharpness, so it opens at the page's size rather than twice it.
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Back where you were reading.
    private static func restore(_ webView: WKWebView, page: Page?) {
        guard let page else { return }
        webView.evaluateJavaScript("window.scrollTo(\(page.x), \(page.y))", in: nil, in: .defaultClient, completionHandler: nil)
    }

    // MARK: Pages that scroll inside

    /// The box that scrolls: the frame it's in (nil for the page itself), the part of it on screen in that frame's
    /// coordinates, and the same part in the web view's.
    private struct Scroller { var frame: WKFrameInfo?; var window: CGRect; var view: CGRect }

    /// What one frame says about itself: its size, whether it scrolls, the biggest box in it that scrolls, and the
    /// frames inside it with where they sit.
    private struct Survey: Decodable {
        struct Inner: Decodable { var origin: String; var rect: [CGFloat] }
        var origin: String
        var width: CGFloat
        var height: CGFloat
        var scrolls: Bool
        var best: [CGFloat]?
        var frames: [Inner]
    }

    private struct Prepared: Decodable { var start: CGFloat; var height: CGFloat; var client: CGFloat }
    private struct Step: Decodable { var top: CGFloat; var height: CGFloat; var client: CGFloat; var pinTop: CGFloat; var pinBottom: CGFloat }

    /// When the page itself doesn't scroll, the box that does: the biggest one on screen, looked for in the page and
    /// in every frame on it, other sites' included. Nil when the page scrolls, or when nothing big enough does.
    private static func findScroller(_ webView: WKWebView) async -> Scroller? {
        guard let main = await survey(nil, in: webView), !main.scrolls else { return nil }
        var others: [(frame: WKFrameInfo, survey: Survey)] = []
        for frame in PageFrames.shared.frames(in: webView) {
            if let survey = await survey(frame, in: webView) { others.append((frame, survey)) }
        }
        let viewport = CGRect(x: 0, y: 0, width: main.width, height: main.height)
        var best: (frame: WKFrameInfo?, offset: CGPoint, page: CGRect)?
        func consider(_ frame: WKFrameInfo?, _ survey: Survey, offset: CGPoint, clip: CGRect) {
            guard let box = rect(survey.best) else { return }
            let page = box.offsetBy(dx: offset.x, dy: offset.y).intersection(clip)
            guard !page.isNull, page.width * page.height > (best.map { $0.page.width * $0.page.height } ?? 0) else { return }
            best = (frame, offset, page)
        }
        consider(nil, main, offset: .zero, clip: viewport)
        // Frames don't say where they sit: each is matched to a frame element of its size (and site, when that can
        // be told), from the page down, so frames inside frames are placed too.
        var placed: [(survey: Survey, offset: CGPoint, clip: CGRect)] = [(main, .zero, viewport)]
        var next = 0
        while next < placed.count {
            let parent = placed[next]
            next += 1
            for inner in parent.survey.frames {
                guard let box = rect(inner.rect) else { continue }
                let fits = { (survey: Survey) in abs(survey.width - box.width) <= 2 && abs(survey.height - box.height) <= 2 }
                guard let index = others.firstIndex(where: { fits($0.survey) && $0.survey.origin == inner.origin }) ?? others.firstIndex(where: { fits($0.survey) })
                else { continue }
                let child = others.remove(at: index)
                let frame = box.offsetBy(dx: parent.offset.x, dy: parent.offset.y)
                let clip = frame.intersection(parent.clip)
                guard !clip.isNull else { continue }
                consider(child.frame, child.survey, offset: frame.origin, clip: clip)
                placed.append((child.survey, frame.origin, clip))
            }
        }
        // A small box (a menu, a side list) isn't what you'd want a picture of.
        guard let best, best.page.width * best.page.height >= viewport.width * viewport.height * 0.15 else { return nil }
        let zoom = webView.pageZoom
        let view = CGRect(x: best.page.minX * zoom, y: best.page.minY * zoom, width: best.page.width * zoom, height: best.page.height * zoom)
        return Scroller(frame: best.frame, window: best.page.offsetBy(dx: -best.offset.x, dy: -best.offset.y), view: view)
    }

    private static func survey(_ frame: WKFrameInfo?, in webView: WKWebView) async -> Survey? {
        guard let json = await run(surveyScript, in: frame, of: webView) else { return nil }
        return try? JSONDecoder().decode(Survey.self, from: Data(json.utf8))
    }

    private static func rect(_ numbers: [CGFloat]?) -> CGRect? {
        guard let numbers, numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Scrolls the box through once so what loads on sight loads, then pictures it a screenful at a time from the
    /// top, each piece placed where the box says it scrolled to. What stays put while the rest scrolls (a header,
    /// a message box) is left out of the pieces in between, so it shows once at the top and once at the bottom.
    private static func captureScroller(_ scroller: Scroller, in webView: WKWebView) async -> Data? {
        guard let json = await run(prepareScrollerScript, arguments: ["viewports": maxViewports], in: scroller.frame, of: webView, timeout: 30),
              let prepared = try? JSONDecoder().decode(Prepared.self, from: Data(json.utf8)) else { return nil }
        defer { webView.callAsyncJavaScript(restoreScrollerScript, arguments: ["y": prepared.start], in: scroller.frame, in: .defaultClient, completionHandler: nil) }
        let view = scroller.view, window = scroller.window
        // Lengths are in the frame's own (CSS) pixels; the picture has `perPixel` of its pixels to each.
        let shown = window.height
        let length = max(shown, prepared.height - prepared.client + shown)
        let zoom = webView.pageZoom
        let backing = webView.window?.backingScaleFactor ?? 2
        let scale = min(max(0.5, backing), maxPixelHeight / (length * zoom), (maxPixels / (view.width * length * zoom)).squareRoot())
        let perPixel = zoom * scale
        let pixelsWide = Int((view.width * scale).rounded()), pixelsHigh = Int((length * perPixel).rounded())
        guard pixelsWide > 0, pixelsHigh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.interpolationQuality = .high
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view
        // No sharper than the picture will be, so a long one doesn't hold forty full-size screenfuls on the way.
        if scale < backing { configuration.snapshotWidth = NSNumber(value: Double(view.width * scale / backing)) }

        var target: CGFloat = 0, covered: CGFloat = 0, end: CGFloat = 0, pieces = 0, lastTop: CGFloat = -1
        for _ in 0..<(maxViewports * 2) {
            let area = [window.minX, window.minY, window.width, window.height]
            guard let json = await run(stepScript, arguments: ["y": target, "area": area], in: scroller.frame, of: webView),
                  let step = try? JSONDecoder().decode(Step.self, from: Data(json.utf8)) else { break }
            // A header that only sticks once scrolled covers where the last piece ended: back up a little and go again.
            if pieces > 0, step.top + step.pinTop > covered + 1, covered - step.pinTop > lastTop + 1 {
                target = covered - step.pinTop
                continue
            }
            guard let image = try? await webView.takeSnapshot(configuration: configuration),
                  let piece = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { break }
            let last = step.top + step.client >= min(step.height, prepared.height) - 1 || step.top <= lastTop
            let from = pieces == 0 ? 0 : step.pinTop
            let to = last ? shown : shown - step.pinBottom
            // The piece's pixels to each of the frame's, measured rather than assumed.
            let ratio = CGFloat(piece.height) / shown
            let crop = CGRect(x: 0, y: (from * ratio).rounded(), width: CGFloat(piece.width), height: ((to - from) * ratio).rounded())
            if to > from, let band = piece.cropping(to: crop) {
                let top = ((step.top + from) * perPixel).rounded(), bottom = ((step.top + to) * perPixel).rounded()
                context.draw(band, in: CGRect(x: 0, y: CGFloat(pixelsHigh) - bottom, width: CGFloat(pixelsWide), height: bottom - top))
            }
            pieces += 1
            covered = step.top + to
            end = max(end, step.top + shown)
            if last { break }
            lastTop = step.top
            target = step.top + max(50, (shown - step.pinTop - step.pinBottom) * 0.85)
        }
        let height = min(pixelsHigh, Int((end * perPixel).rounded()))
        guard pieces > 0, height > 0, let whole = context.makeImage(),
              let image = whole.cropping(to: CGRect(x: 0, y: 0, width: pixelsWide, height: height)) else { return nil }
        return await Task.detached(priority: .userInitiated) { png(image, scale: scale) }.value
    }

    /// A script's answer from one frame, as JSON. A frame that's gone may never answer, so it isn't waited on for long.
    private static func run(_ script: String, arguments: [String: Any] = [:], in frame: WKFrameInfo?, of webView: WKWebView,
                            timeout: Double = 5) async -> String? {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            webView.callAsyncJavaScript(script, arguments: arguments, in: frame, in: .defaultClient) { result in
                answer.give(try? result.get() as? String)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                answer.give(nil)
            }
        }
    }

    /// Answers once: with the script's result or, if that's slow, with nothing.
    private final class Answer {
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func give(_ value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Looks for the biggest box on screen that scrolls, from points spread over the frame, and lists the frames in
    /// this one. The box is kept for the scripts after, in Zigzag's own script world where the page can't see it.
    private static let surveyScript = """
    const root = document.scrollingElement || document.documentElement;
    const clipped = (x, y, w, h) => {
      const x0 = Math.max(0, x), y0 = Math.max(0, y), x1 = Math.min(innerWidth, x + w), y1 = Math.min(innerHeight, y + h);
      return x1 > x0 && y1 > y0 ? [x0, y0, x1 - x0, y1 - y0] : null;
    };
    let best = null, bestBox = null;
    const consider = (el, box) => {
      if (box && (!bestBox || box[2] * box[3] > bestBox[2] * bestBox[3])) { best = el; bestBox = box; }
    };
    // Taller than the window isn't enough: a page that hides its overflow doesn't scroll.
    const hidden = (v) => v === 'hidden' || v === 'clip';
    const html = getComputedStyle(document.documentElement).overflowY;
    const body = document.body ? getComputedStyle(document.body).overflowY : 'visible';
    const scrolls = (room) => root.scrollHeight > innerHeight + room && !hidden(html) && !(html === 'visible' && hidden(body));
    if (window !== window.top && scrolls(40)) consider(root, clipped(0, 0, document.documentElement.clientWidth, innerHeight));
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
    const seen = new Set();
    for (let i = 1; i < 8; i++) {
      for (let j = 1; j < 8; j++) {
        for (let el = deepest(innerWidth * i / 8, innerHeight * j / 8); el && el !== root && el !== document.documentElement && !seen.has(el); el = up(el)) {
          seen.add(el);
          if (el.scrollHeight <= el.clientHeight + 40 || el.clientHeight < 100 || el.clientWidth < 100) continue;
          const overflow = getComputedStyle(el).overflowY;
          if (overflow !== 'auto' && overflow !== 'scroll' && overflow !== 'overlay') continue;
          const r = el.getBoundingClientRect();
          consider(el, clipped(r.left + el.clientLeft, r.top + el.clientTop, el.clientWidth, el.clientHeight));
        }
      }
    }
    const inner = [];
    for (const f of document.querySelectorAll('iframe, frame')) {
      const r = f.getBoundingClientRect(), style = getComputedStyle(f);
      const left = parseFloat(style.paddingLeft) || 0, above = parseFloat(style.paddingTop) || 0;
      const w = f.clientWidth - left - (parseFloat(style.paddingRight) || 0), h = f.clientHeight - above - (parseFloat(style.paddingBottom) || 0);
      if (w <= 0 || h <= 0 || !clipped(r.left, r.top, r.width, r.height)) continue;
      let origin = 'null';
      try { origin = new URL(f.src || 'about:blank', location.href).origin; } catch (e) {}
      inner.push({ origin, rect: [r.left + f.clientLeft + left, r.top + f.clientTop + above, w, h] });
    }
    window.__zigzagShot = best;
    return JSON.stringify({ origin: location.origin, width: innerWidth, height: innerHeight,
                            scrolls: scrolls(2), best: bestBox, frames: inner });
    """

    /// The page's scroll-through, for the box: everything that loads on sight loads, then back to its top.
    private static let prepareScrollerScript = """
    const el = window.__zigzagShot;
    if (!el || !el.isConnected) return null;
    const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
    const go = (y) => el.scrollTo({ top: y, behavior: 'instant' });
    const start = el.scrollTop;
    const limit = el.clientHeight * viewports;
    document.querySelectorAll('img[loading="lazy"], iframe[loading="lazy"]').forEach((e) => { e.loading = 'eager'; });
    const step = Math.max(200, el.clientHeight * 0.85);
    for (let y = 0; y < Math.min(el.scrollHeight, limit); y += step) {
      go(y);
      await sleep(80);
    }
    go(Math.min(el.scrollHeight, limit));
    await sleep(250);
    const pending = Array.from(document.images).filter((img) => !img.complete);
    await Promise.race([Promise.all(pending.map((img) => img.decode().catch(() => {}))), sleep(3000)]);
    if (document.fonts) { await Promise.race([document.fonts.ready, sleep(1000)]); }
    go(0);
    await sleep(150);
    return JSON.stringify({ start, height: Math.min(el.scrollHeight, limit), client: el.clientHeight });
    """

    /// Scrolls the box to `y` and waits for it to be drawn, then says where it really went and how much at its top
    /// and bottom stays put (sticky or fixed) as it scrolls.
    private static let stepScript = """
    const el = window.__zigzagShot;
    if (!el || !el.isConnected) return null;
    el.scrollTo({ top: y, behavior: 'instant' });
    await Promise.race([new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))), new Promise((done) => setTimeout(done, 200))]);
    await new Promise((done) => setTimeout(done, 50));
    const [x0, y0, w, h] = area;
    const pinned = (node) => {
      for (let n = node; n && n !== el && el.contains(n); n = n.parentElement) {
        const position = getComputedStyle(n).position;
        if (position === 'sticky' || position === 'fixed') return n;
      }
      return null;
    };
    let above = 0, below = 0;
    for (let i = 0; i < 5; i++) {
      const x = x0 + w * (i + 0.5) / 5;
      const a = pinned(document.elementFromPoint(x, y0 + 1));
      if (a) { const r = a.getBoundingClientRect(); if (r.top <= y0 + 2) above = Math.max(above, r.bottom - y0); }
      const b = pinned(document.elementFromPoint(x, y0 + h - 2));
      if (b) { const r = b.getBoundingClientRect(); if (r.bottom >= y0 + h - 2) below = Math.max(below, y0 + h - r.top); }
    }
    return JSON.stringify({ top: el.scrollTop, height: el.scrollHeight, client: el.clientHeight,
                            pinTop: above < h * 0.35 ? above : 0, pinBottom: below < h * 0.35 ? below : 0 });
    """

    private static let restoreScrollerScript = """
    const el = window.__zigzagShot;
    window.__zigzagShot = null;
    if (el && el.isConnected) el.scrollTo({ top: y, behavior: 'instant' });
    """

    private static func fileName(for tab: Tab) -> String {
        let title = tab.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let date = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        return "\(title.isEmpty ? "Page" : title) \(date).png"
    }

    private static func save(_ data: Data, name: String, in controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try data.write(to: url)
                    Toast.show("Screenshot saved", symbol: "checkmark.circle", in: controller)
                } catch {
                    Toast.show("Couldn’t save the screenshot", symbol: "exclamationmark.triangle", in: controller)
                }
            }
        }
    }
}

/// Every frame on a page says hello as it starts, so a picture can later reach into the one that scrolls, even
/// when it's from another site. That's all: nothing more happens until a picture is taken.
final class PageFrames: NSObject, WKScriptMessageHandler {
    static let shared = PageFrames()
    static let messageName = "zigzagFrame"

    static let script = WKUserScript(source: """
    (() => {
      const hello = (again) => { try { window.webkit.messageHandlers.\(messageName).postMessage(again); } catch (e) {} };
      hello(false);
      window.addEventListener('pageshow', (e) => { if (e.persisted) hello(true); });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    /// The frames each web view has seen since its page last loaded, newest last. Ones that have gone since simply
    /// don't answer when asked.
    private struct Seen { weak var webView: WKWebView?; var frames: [WKFrameInfo] }
    private var seen: [ObjectIdentifier: Seen] = [:]

    func frames(in webView: WKWebView) -> [WKFrameInfo] {
        guard let entry = seen[ObjectIdentifier(webView)], entry.webView === webView else { return [] }
        return entry.frames
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = message.webView else { return }
        let key = ObjectIdentifier(webView)
        if message.frameInfo.isMainFrame {
            // A new page starts with no frames; one back from the cache keeps the ones it had.
            guard (message.body as? Bool) != true else { return }
            seen = seen.filter { $0.value.webView != nil }
            seen[key] = Seen(webView: webView, frames: [])
            return
        }
        var entry = seen[key].flatMap { $0.webView === webView ? $0 : nil } ?? Seen(webView: webView, frames: [])
        entry.frames.append(message.frameInfo)
        // Pages full of ads make and remake frames: the newest are kept.
        if entry.frames.count > 64 { entry.frames.removeFirst(entry.frames.count - 64) }
        seen[key] = entry
    }
}
