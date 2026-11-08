import AppKit
import ImageIO

/// Site icons, cached in memory and on disk by host.
final class FaviconStore {
    static let shared = FaviconStore()

    private var memory: [String: NSImage] = [:]

    /// Icons in memory, at most a few hundred: a long session's worth of sites would otherwise all stay. Past that
    /// the cache starts over, and icons come back from disk as they're shown.
    private func keep(_ image: NSImage, for key: String) {
        if memory.count >= 400, memory[key] == nil { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }
    /// Sites with no icon file yet, so asking again (every sidebar refresh) doesn't read the disk each time.
    private var missing: Set<String> = []
    private var inFlight: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(WebKitSetup.applicationNameForUserAgent)"]
        return URLSession(configuration: config)
    }()

    /// Fires with the host whose icon changed.
    let updated = Signal<String>()

    /// The site an icon is kept for: what `updated` sends when one arrives, so a view can tell whether it's its own.
    nonisolated func iconKey(for url: URL?) -> String? { url.flatMap(key(for:)) }

    nonisolated private func key(for url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // Google runs separate apps under one host, each with its own icon: Maps mustn't become Search's icon.
        if site == "google.com", let app = url.pathComponents.dropFirst().first?.lowercased(), Self.googleApps.contains(app) {
            return site + "/" + app
        }
        return site
    }

    nonisolated private static let googleApps: Set<String> = ["maps", "travel", "flights", "finance", "shopping", "books", "earth"]

    private init() {
        // Before Google's apps had their own icons, one of them could have taken over google.com's.
        if !UserDefaults.standard.bool(forKey: "faviconGoogleApps") {
            try? FileManager.default.removeItem(at: file(for: "google.com"))
            UserDefaults.standard.set(true, forKey: "faviconGoogleApps")
        }
        // Icons used to be stretched to 64 pixels, small ones blurred; they're fetched again at their own size.
        if !UserDefaults.standard.bool(forKey: "faviconNativeSize2") {
            try? FileManager.default.removeItem(at: Paths.favicons)
            try? FileManager.default.createDirectory(at: Paths.favicons, withIntermediateDirectories: true)
            UserDefaults.standard.set(true, forKey: "faviconNativeSize2")
        }
    }

    private func file(for key: String) -> URL {
        Paths.favicons.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func cachedIcon(for url: URL) -> NSImage? {
        // An extension's own pages wear the extension's icon.
        if #available(macOS 15.4, *), url.scheme == "webkit-extension",
           let context = ExtensionHost.shared.contexts.first(where: { $0.baseURL.host() == url.host() }) {
            return context.webExtension.icon(for: NSSize(width: 32, height: 32))
        }
        // Zigzag's own pages wear a symbol.
        if SettingsPage.isSettings(url) { return Tokens.Symbol.image("gearshape", size: Tokens.Symbol.row) }
        if url.scheme == HistoryPage.scheme { return Tokens.Symbol.image("clock.arrow.circlepath", size: Tokens.Symbol.row) }
        guard let key = key(for: url) else { return nil }
        if let image = memory[key] { return image }
        guard !missing.contains(key) else { return nil }
        if let image = NSImage(contentsOf: file(for: key)) {
            keep(image, for: key)
            return image
        }
        missing.insert(key)
        return nil
    }

    /// Picks the best declared icon (falling back to /favicon.ico), downloads, caches, and returns it.
    func resolve(pageURL: URL, links: [[String: String]], completion: @escaping (NSImage?) -> Void) {
        guard let key = key(for: pageURL) else { completion(nil); return }
        let (icons, touch) = Self.rank(links: links, pageURL: pageURL)
        let hasIcon = memory[key] != nil || FileManager.default.fileExists(atPath: file(for: key).path)
        fetchFirst(icons, touch: touch, key: key, save: Self.speaksForSite(pageURL, hasIcon: hasIcon), completion: completion)
    }

    /// Whether a page's icon becomes its whole site's. A page deep in a site can wear its own (each claude.ai artifact
    /// has one), and that mustn't replace the icon of the site's favorites and tabs; a front page's icon can.
    static func speaksForSite(_ pageURL: URL, hasIcon: Bool) -> Bool {
        !hasIcon || pageURL.pathComponents.filter { $0 != "/" }.count <= 1
    }

    /// Sites whose icon couldn't be found: when to look again, and how long the wait was. A site that's down, blocks
    /// requests or has no icon is asked again after a minute, then twice as long each time up to a day, never at
    /// every sidebar refresh.
    private var failures: [String: (next: Date, wait: TimeInterval)] = [:]

    /// The wait before asking a site again after it gave no icon, from the wait before it.
    nonisolated static func retryWait(after previous: TimeInterval?) -> TimeInterval {
        min(max((previous ?? 30) * 2, 60), 24 * 3600)
    }

    /// Loads an icon for a URL we have never visited (bookmarks, imports, history): the site's usual addresses
    /// first, then the icons its page lists, then the ones its front page lists. One fetch per site at a time.
    func prefetch(for url: URL) {
        guard let key = key(for: url), memory[key] == nil, !inFlight.contains(key),
              !FileManager.default.fileExists(atPath: file(for: key).path) else { return }
        if let failure = failures[key], failure.next > Date() { return }
        inFlight.insert(key)
        let done: (Bool) -> Void = { [weak self] found in
            guard let self else { return }
            self.inFlight.remove(key)
            if found {
                self.failures[key] = nil
            } else {
                let wait = Self.retryWait(after: self.failures[key]?.wait)
                self.failures[key] = (Date().addingTimeInterval(wait), wait)
            }
        }
        // A Google app's icon isn't at the host's root, only on its own page.
        guard !key.contains("/") else { fetchListed(on: [url], key: key, done: done); return }
        // The page itself, then the site's front page, when the address is deeper: an app's address often only
        // leads to its sign-in, but its front page lists the icons.
        var pages = [url]
        if let home = URL(string: "/", relativeTo: url)?.absoluteURL, home.path() != url.path() { pages.append(home) }
        let (icons, touch) = Self.rank(links: [], pageURL: url)
        fetchFirst(icons, touch: touch, key: key) { [weak self] image in
            guard image == nil else { done(true); return }
            // Nothing at the usual addresses (Brave Search keeps its icons on a CDN): the icons the pages list.
            self?.fetchListed(on: pages, key: key, done: done)
        }
    }

    /// The first of `pages` that lists icons, and the best of them that loads.
    private func fetchListed(on pages: [URL], key: String, done: @escaping (Bool) -> Void) {
        guard let page = pages.first else { done(false); return }
        let rest = Array(pages.dropFirst())
        declaredIcons(of: page) { [weak self] links in
            guard let self else { return }
            guard !links.isEmpty else { self.fetchListed(on: rest, key: key, done: done); return }
            let (icons, touch) = Self.rank(links: links, pageURL: page)
            self.fetchFirst(icons, touch: touch, key: key) { [weak self] image in
                if image == nil { self?.fetchListed(on: rest, key: key, done: done) } else { done(true) }
            }
        }
    }

    /// The icon links a page's head declares, read from its HTML without loading it in a web view. Asked as the
    /// browser (some sites turn other clients away). A page that sends you to a sign-in lists the sign-in's icons
    /// (Google Calendar's would be Google's account page's), not its own: none then.
    private func declaredIcons(of url: URL, completion: @escaping @MainActor ([[String: String]]) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, _ in
            let landed = response?.url ?? url
            let html = Self.isSignIn(landed, from: url) ? "" : data.flatMap { String(data: $0.prefix(200_000), encoding: .utf8) } ?? ""
            // Made absolute, as a page's own script reports them.
            let links = Self.iconLinks(in: html).map { link -> [String: String] in
                var link = link
                link["href"] = link["href"].flatMap { URL(string: $0, relativeTo: landed)?.absoluteString }
                return link
            }
            Task { @MainActor in completion(links) }
        }.resume()
    }

    /// Whether asking for `asked` landed on a sign-in somewhere else rather than on the site (a site that moved,
    /// notion.so to notion.com, still counts as itself).
    nonisolated static func isSignIn(_ landed: URL, from asked: URL) -> Bool {
        guard landed.host()?.lowercased() != asked.host()?.lowercased() else { return false }
        let text = ((landed.host() ?? "") + landed.path()).lowercased()
        return ["login", "signin", "sign-in", "sign_in", "accounts.", "auth", "sso"].contains { text.contains($0) }
    }

    /// `<link rel="…icon…" href="…" sizes="…">` tags, as the page's own icon script reports them.
    nonisolated static func iconLinks(in html: String) -> [[String: String]] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              // Quoted or not: minified pages often leave the quotes off.
              let attribute = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))") else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return tag.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range, in: html) else { return nil }
            let text = String(html[r])
            var fields: [String: String] = [:]
            for a in attribute.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let k = Range(a.range(at: 1), in: text),
                      let v = (2...4).lazy.compactMap({ Range(a.range(at: $0), in: text) }).first else { continue }
                fields[text[k].lowercased()] = String(text[v])
            }
            guard let rel = fields["rel"]?.lowercased(), rel.contains("icon"), fields["href"] != nil else { return nil }
            return fields
        }
    }

    /// Where to look for a page's icon, best first: the site's own icons, and apart from them its home-screen ones,
    /// made for a phone's screen on a solid square of their own, only for a site with no icon of its own.
    /// /favicon.ico stands in when the page declares no icon, /apple-touch-icon.png when it declares no home-screen
    /// one.
    nonisolated static func rank(links: [[String: String]], pageURL: URL) -> (icons: [URL], touch: [URL]) {
        func size(_ link: [String: String]) -> Int? {
            let sizes = link["sizes"] ?? ""
            if sizes == "any" { return 512 }
            return sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max()
        }
        // An SVG first, then the smallest of 64px or more, then of 32px or more, then the rest, largest first.
        var icons: [(URL, Int)] = [], touch: [(URL, Int)] = []
        for link in links {
            guard let href = link["href"], let url = URL(string: href) else { continue }
            let isSVG = (link["type"] ?? "").contains("svg") || url.pathExtension.lowercased() == "svg"
            if (link["rel"] ?? "").contains("apple-touch") {
                // A home-screen icon that doesn't say is the usual 180px.
                touch.append((url, size(link) ?? 180))
            } else {
                let s = size(link) ?? 16
                icons.append((url, isSVG ? 2100 : s >= 64 ? 2000 - s : s >= 32 ? 1000 - s : s))
            }
        }
        var components = URLComponents()
        components.scheme = pageURL.scheme ?? "https"
        components.host = pageURL.host()
        components.port = pageURL.port
        if icons.isEmpty {
            components.path = "/favicon.ico"
            if let fallback = components.url { icons.append((fallback, 0)) }
        }
        if touch.isEmpty {
            components.path = "/apple-touch-icon.png"
            if let fallback = components.url { touch.append((fallback, 0)) }
        }
        return (icons.sorted { $0.1 > $1.1 }.map(\.0), touch.sorted { $0.1 > $1.1 }.map(\.0))
    }

    /// Without `save`, the icon is only handed back, for the one page that declared it.
    /// A 16px icon (too small to stay sharp anywhere bigger than a tab) is kept only until a larger one of the site's
    /// own turns up further down the list. The home-screen icons in `touch` are tried only when the site has none
    /// of its own at all: a small icon of its own still wins over a home-screen tile.
    private func fetchFirst(_ candidates: [URL], touch: [URL] = [], key: String, save: Bool = true, small: NSImage? = nil, completion: @escaping (NSImage?) -> Void) {
        func finish(_ image: NSImage) {
            if save { store(image, key: key); completion(memory[key]) } else { completion(Self.normalize(image)) }
        }
        func found(_ image: NSImage, rest: [URL]) {
            // An icon that draws nothing (an SVG styled by the page, which AppKit can't follow) is passed over.
            if Self.isBlank(image) {
                fetchFirst(rest, touch: touch, key: key, save: save, small: small, completion: completion)
                return
            }
            let pixels = image.representations.map(\.pixelsWide).max() ?? 0
            if pixels > 0, pixels < 32, !rest.isEmpty {
                fetchFirst(rest, touch: touch, key: key, save: save, small: small ?? image, completion: completion)
            } else if pixels > 0, pixels < 32, let small, (small.representations.map(\.pixelsWide).max() ?? 0) >= pixels {
                finish(small)
            } else {
                finish(image)
            }
        }
        guard let next = candidates.first else {
            if let small {
                finish(small)
            } else if !touch.isEmpty {
                fetchFirst(touch, key: key, save: save, completion: completion)
            } else {
                completion(nil)
            }
            return
        }
        let rest = Array(candidates.dropFirst())
        if next.scheme == "data", let data = try? Data(contentsOf: next), let image = NSImage(data: data), image.isValid {
            found(image, rest: rest)
            return
        }
        Task {
            let result = try? await session.data(from: next)
            let ok = ((result?.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400
            if ok, let data = result?.0, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                found(image, rest: rest)
            } else {
                fetchFirst(rest, touch: touch, key: key, save: save, small: small, completion: completion)
            }
        }
    }

    /// Keeps an icon we already have (onboarding's site logos), so the sidebar never starts with a globe.
    /// Clearing history: the icons saved for sites you visited go too (all of them, or those saved since `date`), so
    /// the icon folder never stands in for the history you cleared. Icons of your pinned pages and favorites stay.
    /// They're set aside rather than deleted, so ⌘Z can put them back, and are gone for good the next time Zigzag
    /// starts (`Paths.setAsideIcons`).
    func setAsideVisited(since date: Date? = nil) -> URL? {
        let kept = Set((Library.shared.favorites + Library.shared.allBookmarks.map(\.0)).compactMap { key(for: $0.url) }.map { file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.favicons, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let aside = Paths.setAsideIcons.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for file in files where !kept.contains(file.lastPathComponent) {
            if let date, let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < date { continue }
            try? FileManager.default.moveItem(at: file, to: aside.appendingPathComponent(file.lastPathComponent))
        }
        // Read again from disk as needed: what's left is what you kept.
        memory.removeAll()
        missing.removeAll()
        return aside
    }

    /// Icons set aside by clearing history, back where they were (any saved again since stay as they are now).
    func putBack(_ aside: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: aside, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.moveItem(at: file, to: Paths.favicons.appendingPathComponent(file.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: aside)
        missing.removeAll()
    }

    func remember(_ image: NSImage, for url: URL) {
        guard let key = key(for: url), memory[key] == nil else { return }
        store(image, key: key)
    }

    private func store(_ image: NSImage, key: String) {
        let normalized = Self.normalize(image)
        keep(normalized, for: key)
        missing.remove(key)
        failures[key] = nil
        if let tiff = normalized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: file(for: key), options: .atomic)
        }
        updated.send(key)
    }

    /// Renders to a square bitmap so every icon draws the same, whatever the source format. It keeps the source's
    /// own pixels, up to 128: a small icon is never stretched here, so a view can tell how large it stays sharp.
    private static func normalize(_ image: NSImage) -> NSImage {
        let native = image.representations.map(\.pixelsWide).max() ?? 0
        // Drawings (SVG, PDF) have no pixels of their own and render sharp at any size.
        let side = native <= 0 ? 128 : min(max(native, 16), 128)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: Tokens.Metric.favicon, height: Tokens.Metric.favicon))
        out.addRepresentation(rep)
        return out
    }

    private static func isBlank(_ image: NSImage) -> Bool {
        guard let rep = normalize(image).representations.first as? NSBitmapImageRep, let data = rep.bitmapData else { return false }
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * 4 + 3] > 8 { return false }
        }
        return true
    }

    /// The size, in points, an icon fills pixel for pixel on a Retina display; drawn any larger, it's scaled up.
    static func sharpSide(of image: NSImage) -> CGFloat {
        CGFloat(image.representations.map(\.pixelsWide).max() ?? 0) / 2
    }

    /// A color that represents the icon, used for tinting when a site has no theme color.
    func dominantColor(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // Bucket saturated pixels by hue; a logo has a color only if one hue clearly dominates.
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        for i in 0..<(side * side) {
            let a = Double(pixels[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i * 4]) / 255 / a, pg = Double(pixels[i * 4 + 1]) / 255 / a, pb = Double(pixels[i * 4 + 2]) / 255 / a
            let c = NSColor(srgbRed: pr, green: pg, blue: pb, alpha: 1)
            guard c.saturationComponent > 0.3, c.brightnessComponent > 0.25 else { continue }
            let bin = min(bins - 1, Int(c.hueComponent * Double(bins)))
            let w = c.saturationComponent
            weight[bin] += w
            sums[bin].0 += pr * w; sums[bin].1 += pg * w; sums[bin].2 += pb * w
        }
        let total = weight.reduce(0, +)
        guard total > 4, let best = weight.indices.max(by: { weight[$0] < weight[$1] }) else { return nil }
        // Neighboring bins belong to the same hue.
        let neighbors = [(best + bins - 1) % bins, best, (best + 1) % bins]
        let share = neighbors.map { weight[$0] }.reduce(0, +) / total
        guard share > 0.7 else { return nil }
        let w = weight[best]
        let color = NSColor(srgbRed: sums[best].0 / w, green: sums[best].1 / w, blue: sums[best].2 / w, alpha: 1)
        return color.saturationComponent > 0.35 ? color : nil
    }
}

/// Last-known page images, used for previews, the switcher, desk view and suspended tabs.
enum SnapshotStore {
    private static var memory: [UUID: NSImage] = [:]

    nonisolated static func file(_ id: UUID) -> URL { Paths.snapshots.appendingPathComponent(id.uuidString + ".jpg") }

    static func load(_ id: UUID) -> NSImage? {
        if let image = memory[id] { return image }
        guard let image = NSImage(contentsOf: file(id)) else { return nil }
        // Whether it's blank, from the file's small thumbnail: the picture itself stays undecoded until it's shown.
        if let source = CGImageSourceCreateWithURL(file(id) as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) {
            TabThumbnailView.remember(image, blank: TabThumbnailView.isBlank(thumbnail))
        }
        // Read back from disk, it counts toward the limit like a fresh one, so the cache never grows without end.
        remember(image, for: id)
        return image
    }

    private static func remember(_ image: NSImage, for id: UUID) {
        memory[id] = image
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > memoryLimit { memory[recent.removeFirst()] = nil }
    }

    /// Snapshots kept in memory, most recent last; older ones are read back from disk when needed.
    private static var recent: [UUID] = []
    private static let memoryLimit = 40

    static func save(_ image: NSImage, for id: UUID) {
        remember(image, for: id)
        // The bitmap is taken here, cheaply; turning it into a JPEG happens off the main thread.
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let url = file(id)
        DispatchQueue.global(qos: .utility).async { writeJPEG(bitmap, to: url) }
    }

    nonisolated private static func writeJPEG(_ bitmap: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    static func remove(_ id: UUID) {
        memory[id] = nil
        recent.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Drops snapshot files for tabs that no longer exist.
    static func prune(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
