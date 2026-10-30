import AppKit
import ImageIO
import UniformTypeIdentifiers
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
            let (data, page) = await capture(webView)
            guard let data else {
                Toast.show("Couldn’t take a picture of this page", symbol: "exclamationmark.triangle", in: controller)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            let name = fileName(for: tab)
            let note = page?.scrollsInside == true ? "Copied what’s on screen: this page scrolls inside itself" : "Screenshot of the whole page copied"
            Toast.show(note, symbol: "camera.viewfinder", action: ("Save", { [weak controller] in
                guard let controller else { return }
                save(data, name: name, in: controller)
            }), duration: 8, in: controller)
        }
    }

    // MARK: Steps

    /// The picture as PNG data, and what was learned about the page on the way.
    private static func capture(_ webView: WKWebView) async -> (Data?, Page?) {
        let cover = await coverPage(webView)
        // However it ends, the still comes off.
        defer { cover?.removeFromSuperview() }
        let page = await prepare(webView)
        let data = await draw(webView, height: page?.height)
        restore(webView, page: page)
        return (data, page)
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
