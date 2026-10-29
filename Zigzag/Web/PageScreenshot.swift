import AppKit
import WebKit

/// A picture of the whole page, top to bottom, copied for pasting with Save… one click away.
///
/// Pages load as you scroll (images, whole sections), so a picture taken straight away is full of blanks. First the
/// page is scrolled through once, behind a still of what you were looking at so nothing jumps, then it waits for
/// its images and fonts, goes back to the top so sticky headers sit there once, and is drawn in one piece.
@MainActor
enum PageScreenshot {
    private static var isTaking = false

    /// Long enough for nearly any page; endless feeds stop here instead of scrolling forever.
    private static let maxViewports = 40
    /// Big pictures are drawn smaller rather than failing: the longest side and the total pixels have a ceiling.
    private static let maxPixelHeight: CGFloat = 32_000
    private static let maxPixels: CGFloat = 150_000_000

    static func canTake(_ tab: Tab?) -> Bool {
        guard let tab, tab.webView != nil, let scheme = tab.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    static func take(_ tab: Tab, in controller: BrowserWindowController) {
        guard !isTaking, canTake(tab), let webView = tab.webView else { return }
        isTaking = true
        Toast.show("Taking a picture of the whole page…", symbol: "camera.viewfinder", duration: 30, in: controller)
        Task { @MainActor in
            defer { isTaking = false }
            let (data, page) = await capture(webView)
            guard let data else {
                Toast.show("Couldn’t take a picture of this page", symbol: "exclamationmark.triangle", in: controller)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            let name = fileName(for: tab)
            let note = page?.scrollsInside == true ? "Copied what’s on screen: this page scrolls inside itself" : "Screenshot of the whole page copied"
            Toast.show(note, symbol: "camera.viewfinder", action: ("Save…", { [weak controller] in
                guard let controller else { return }
                save(data, name: name, in: controller)
            }), duration: 8, in: controller)
        }
    }

    // MARK: Steps

    /// The picture as PNG data, and what was learned about the page on the way.
    private static func capture(_ webView: WKWebView) async -> (Data?, Page?) {
        let cover = await coverPage(webView)
        let page = await prepare(webView)
        let data = await draw(webView, height: page?.height)
        restore(webView, page: page)
        cover?.removeFromSuperview()
        return (data, page)
    }

    #if DEBUG
    /// For testing: the picture goes to a file, never your clipboard.
    static func debugCapture(_ webView: WKWebView, to url: URL) {
        Task { @MainActor in try? await capture(webView).0?.write(to: url) }
    }
    #endif

    /// A still of the page over it while it scrolls underneath, so the page doesn't race past your eyes.
    private static func coverPage(_ webView: WKWebView) async -> NSView? {
        guard let superview = webView.superview, let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        let still = NSImageView(frame: webView.frame)
        still.image = image
        still.imageScaling = .scaleAxesIndependently
        still.autoresizingMask = [.width, .height]
        superview.addSubview(still, positioned: .above, relativeTo: webView)
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
        guard let pdf = try? await webView.pdf(configuration: configuration), let rep = NSPDFImageRep(data: pdf) else { return nil }
        let size = rep.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let backing = webView.window?.backingScaleFactor ?? 2
        let scale = max(0.5, min(backing, maxPixelHeight / size.height, (maxPixels / (size.width * size.height)).squareRoot()))
        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Pages without a background of their own are white, as on screen.
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Back where you were reading.
    private static func restore(_ webView: WKWebView, page: Page?) {
        guard let page else { return }
        webView.evaluateJavaScript("window.scrollTo(\(page.x), \(page.y))", in: nil, in: .defaultClient, completionHandler: nil)
    }

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
