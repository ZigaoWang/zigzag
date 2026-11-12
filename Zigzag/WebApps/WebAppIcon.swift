import AppKit
import WebKit

/// The icon of a site installed as an app: the site's own large icon (its manifest's, its Apple touch icon, or its
/// largest favicon), set in a rounded square with the Mac's icon margins, as Safari does for Add to Dock.
nonisolated enum WebAppIcon {
    /// What the page says about itself, read in Zigzag's own script world.
    struct PageFacts: Equatable {
        var title = ""
        var appTitle: String?
        var applicationName: String?
        var siteName: String?
        var manifest: URL?
        var icons: [Candidate] = []
    }

    /// An icon the page or its manifest names, with the size it says it is (0 when it doesn't say).
    struct Candidate: Equatable {
        var url: URL
        var size: Int
        /// An Apple touch icon or a maskable manifest icon: a full square, made to be rounded off.
        var fillsSquare: Bool
    }

    static let pageScript = """
        (() => {
          const abs = (h) => { try { return new URL(h, document.baseURI).href } catch (e) { return null } };
          const meta = (n) => document.querySelector(`meta[name="${n}"], meta[property="${n}"]`)?.content || null;
          const icons = [...document.querySelectorAll('link[rel]')].filter(l => /(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/i.test(l.rel))
            .map(l => ({ href: abs(l.getAttribute('href') || ''), sizes: l.getAttribute('sizes') || '', rel: l.rel.toLowerCase() }))
            .filter(i => i.href);
          const manifest = document.querySelector('link[rel="manifest"]');
          return JSON.stringify({ title: document.title || '', appTitle: meta('apple-mobile-web-app-title'),
            applicationName: meta('application-name'), siteName: meta('og:site_name'),
            manifest: manifest ? abs(manifest.getAttribute('href') || '') : null, icons });
        })()
        """

    /// Reads `pageScript`'s answer.
    static func facts(fromPage json: String) -> PageFacts {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return PageFacts() }
        func text(_ key: String) -> String? {
            (object[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var facts = PageFacts(title: text("title") ?? "", appTitle: text("appTitle"), applicationName: text("applicationName"),
                              siteName: text("siteName"), manifest: text("manifest").flatMap(URL.init(string:)))
        for icon in object["icons"] as? [[String: Any]] ?? [] {
            guard let href = icon["href"] as? String, let url = URL(string: href), ["http", "https"].contains(url.scheme ?? "") else { continue }
            let rel = icon["rel"] as? String ?? ""
            facts.icons.append(Candidate(url: url, size: largestSize(icon["sizes"] as? String ?? ""), fillsSquare: rel.contains("apple-touch-icon")))
        }
        return facts
    }

    /// A manifest's name and icons. `base` is the manifest's own address, which its icons are relative to.
    static func manifest(_ data: Data, base: URL) -> (name: String?, shortName: String?, icons: [Candidate]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, []) }
        func text(_ key: String) -> String? {
            (object[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var icons: [Candidate] = []
        for icon in object["icons"] as? [[String: Any]] ?? [] {
            guard let src = icon["src"] as? String, let url = URL(string: src, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? "") else { continue }
            // A monochrome icon is a stencil for the system to color: not a picture to show.
            let purposes = (icon["purpose"] as? String ?? "any").lowercased().split(separator: " ")
            guard purposes.contains("any") || purposes.contains("maskable") else { continue }
            icons.append(Candidate(url: url, size: largestSize(icon["sizes"] as? String ?? ""), fillsSquare: purposes.contains("maskable") && !purposes.contains("any")))
        }
        return (text("name"), text("short_name"), icons)
    }

    /// "192x192 512x512" → 512; "any" (a drawing) counts as large.
    static func largestSize(_ sizes: String) -> Int {
        sizes.lowercased().split(separator: " ").map { part -> Int in
            if part == "any" { return 1024 }
            return Int(part.split(separator: "x").first ?? "") ?? 0
        }.max() ?? 0
    }

    /// The name the app starts with: what the site calls itself as an app, else its name, else the page's title, else
    /// the host without www.
    static func name(facts: PageFacts, manifestName: String?, manifestShortName: String?, url: URL) -> String {
        let host = (url.host() ?? "").replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let candidates = [facts.appTitle, manifestShortName, manifestName, facts.applicationName, facts.siteName,
                          siteName(inTitle: facts.title, url: url), facts.title]
        let name = candidates.lazy.compactMap { $0 }.first { !$0.isEmpty } ?? host
        return String(name.prefix(60))
    }

    /// The site's own name in a page title like "Mac (computer) - Wikipedia": the part that is the site's domain name.
    static func siteName(inTitle title: String, url: URL) -> String? {
        guard let site = Tab.site(of: url), let label = site.split(separator: ".").first?.lowercased() else { return nil }
        var pieces = [title]
        for separator in [" - ", " | ", " — ", " – ", " · ", " :: "] { pieces = pieces.flatMap { $0.components(separatedBy: separator) } }
        guard pieces.count > 1 else { return nil }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.first { piece in
            piece.lowercased().filter { $0.isLetter || $0.isNumber } == label.filter { $0.isLetter || $0.isNumber }
        }
    }

    /// The icons to try, best first: the largest a full square (a touch icon or a maskable one) that's big enough,
    /// then the largest of the rest. The site's own /apple-touch-icon.png last, which many sites have without naming.
    static func ranked(_ candidates: [Candidate], origin: URL?) -> [Candidate] {
        var all = candidates
        if let origin, let touch = URL(string: "/apple-touch-icon.png", relativeTo: origin)?.absoluteURL, !all.contains(where: { $0.url == touch }) {
            all.append(Candidate(url: touch, size: 180, fillsSquare: true))
        }
        return all.enumerated().sorted { a, b in
            // A declared size of 0 is unknown: taken for a small favicon.
            let sa = a.element.size, sb = b.element.size
            if (sa >= 120) != (sb >= 120) { return sa >= 120 }
            if sa != sb { return sa > sb }
            if a.element.fillsSquare != b.element.fillsSquare { return a.element.fillsSquare }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Drawing

    /// The icon's canvas, and the rounded square on it, as macOS lays out an app icon: 824 of 1024, 100 in from each
    /// side, corners 185.4.
    static let canvas: CGFloat = 1024
    static let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let plateRadius: CGFloat = 185.4

    /// Whether a picture covers its whole square (its corners aren't see-through), so it can fill the plate as it is.
    static func isOpaqueSquare(_ image: CGImage) -> Bool {
        let side = 16
        guard abs(image.width - image.height) <= max(2, image.width / 20),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let corners = [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)]
        return corners.allSatisfy { data[($0.1 * side + $0.0) * 4 + 3] > 240 }
    }

    /// The icon at 1024 by 1024: `picture` filling the rounded square when it's a full square, else on a white one
    /// with room around it; a small picture, or none, makes a letter on the site's color instead (`monogram`).
    static func render(_ picture: CGImage?, name: String, tint: NSColor? = nil) -> CGImage? {
        let side = Int(canvas)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let path = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)
        // The soft shadow under every Mac app icon.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        context.addPath(path)
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        if let picture, min(picture.width, picture.height) >= 64 {
            if isOpaqueSquare(picture) {
                context.draw(picture, in: aspectFill(picture, in: plate))
            } else {
                // A shape of its own: on white, as large as the Mac's icon grid leaves inside the square.
                let inner = plate.insetBy(dx: plate.width * 0.17, dy: plate.height * 0.17)
                context.draw(picture, in: aspectFit(picture, in: inner))
            }
        } else {
            drawMonogram(name, color: tint ?? picture.flatMap(averageColor) ?? NSColor(srgbRed: 0.42, green: 0.48, blue: 0.58, alpha: 1), in: context)
        }
        context.restoreGState()
        // A hairline around the square, so a white icon still has an edge on a white Dock.
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(2)
        context.strokePath()
        return context.makeImage()
    }

    private static func aspectFill(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The first letter of the name in white on the color, for a site with no picture big enough to show.
    private static func drawMonogram(_ name: String, color: NSColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(plate)
        let letter = name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).localizedUppercase } ?? "?"
        let font = NSFont.systemFont(ofSize: 460, weight: .semibold)
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: plate.midX - bounds.midX, y: plate.midY - bounds.midY)
        CTLineDraw(line, context)
    }

    /// The picture's color, deepened so white reads on it.
    private static func averageColor(_ image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pixel[3] > 20 else { return nil }
        let a = CGFloat(pixel[3]) / 255
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255 / a, green: CGFloat(pixel[1]) / 255 / a, blue: CGFloat(pixel[2]) / 255 / a, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return NSColor(hue: h, saturation: min(1, max(s, 0.35)), brightness: min(b, 0.62), alpha: 1)
    }

    // MARK: The .icns file

    /// Each picture an app icon file holds: its type code and pixel size, 16 to 1024, the 2x ones included.
    static let icnsEntries: [(type: String, pixels: Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("icp6", 64),
        ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]

    /// AppIcon.icns for `image` (the 1024 one `render` makes): a PNG at every size the Mac asks for.
    static func icns(from image: CGImage) -> Data? {
        var body = Data()
        var pngs: [Int: Data] = [:]
        for entry in icnsEntries {
            if pngs[entry.pixels] == nil {
                guard let png = png(scaled(image, to: entry.pixels)) else { return nil }
                pngs[entry.pixels] = png
            }
            guard let png = pngs[entry.pixels] else { return nil }
            body.append(Data(entry.type.utf8))
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return file
    }

    /// The type codes and the pixel sizes in an .icns file, in order, for checking one.
    static func icnsContents(_ data: Data) -> [(type: String, width: Int, height: Int)] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, String(bytes: bytes[0..<4], encoding: .ascii) == "icns" else { return [] }
        var out: [(String, Int, Int)] = []
        var i = 8
        while i + 8 <= bytes.count {
            let type = String(bytes: bytes[i..<i + 4], encoding: .ascii) ?? ""
            let length = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
            guard length >= 8, i + length <= bytes.count else { break }
            let payload = Data(bytes[i + 8..<i + length])
            if let source = CGImageSourceCreateWithData(payload as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                out.append((type, picture.width, picture.height))
            } else {
                out.append((type, 0, 0))
            }
            i += length
        }
        return out
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func scaled(_ image: CGImage, to pixels: Int) -> CGImage {
        guard image.width != pixels || image.height != pixels,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A picture from data a site sent: PNG, JPEG, ICO (its largest), WebP, SVG; nil for anything else. The largest
    /// of the pictures in it.
    static func picture(from data: Data) -> CGImage? {
        guard data.count < 8_000_000 else { return nil }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            let best = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }.max { $0.width < $1.width }
            if let best { return best }
        }
        // An SVG: NSImage draws it, at the size the icon needs.
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512 * image.size.height / image.size.width)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// Finds a page's app name and icon: what the page says, its manifest, then the best icon that loads.
@MainActor
enum WebAppIconFinder {
    struct Found {
        var name: String
        /// The site's own picture, before it's set in the rounded square; nil when none was big enough.
        var picture: CGImage?
    }

    /// Asks the page, then the network; `done` hears what was found, on the main thread, within a few seconds.
    static func find(for tab: Tab, done: @escaping (Found) -> Void) {
        guard let url = tab.url, let webView = tab.webView else {
            done(Found(name: tab.displayTitle, picture: nil))
            return
        }
        webView.evaluateJavaScript(WebAppIcon.pageScript, in: nil, in: .defaultClient) { result in
            let json = (try? result.get()) as? String ?? ""
            var facts = WebAppIcon.facts(fromPage: json)
            if facts.title.isEmpty { facts.title = tab.displayTitle }
            Task {
                let found = await look(facts: facts, url: url)
                done(found)
            }
        }
    }

    private static func look(facts: WebAppIcon.PageFacts, url: URL) async -> Found {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var candidates = facts.icons
        var manifestName: String?, manifestShortName: String?
        if let manifest = facts.manifest, let (data, _) = try? await session.data(from: manifest), data.count < 1_000_000 {
            let read = WebAppIcon.manifest(data, base: manifest)
            manifestName = read.name
            manifestShortName = read.shortName
            candidates = read.icons + candidates
        }
        let name = WebAppIcon.name(facts: facts, manifestName: manifestName, manifestShortName: manifestShortName, url: url)
        let origin = URL(string: "/", relativeTo: url)?.absoluteURL
        for candidate in WebAppIcon.ranked(candidates, origin: origin).prefix(5) {
            guard let (data, response) = try? await session.data(from: candidate.url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let picture = WebAppIcon.picture(from: data), min(picture.width, picture.height) >= 64 else { continue }
            return Found(name: name, picture: picture)
        }
        return Found(name: name, picture: nil)
    }
}
