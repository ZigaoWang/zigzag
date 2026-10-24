import AppKit

/// Site icons, cached in memory and on disk by host.
final class FaviconStore {
    static let shared = FaviconStore()

    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(WebKitSetup.applicationNameForUserAgent)"]
        return URLSession(configuration: config)
    }()

    /// Fires with the host whose icon changed.
    let updated = Signal<String>()

    private func key(for url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
        guard let key = key(for: url) else { return nil }
        if let image = memory[key] { return image }
        if let image = NSImage(contentsOf: file(for: key)) {
            memory[key] = image
            return image
        }
        return nil
    }

    /// Picks the best declared icon (falling back to /favicon.ico), downloads, caches, and returns it.
    func resolve(pageURL: URL, links: [[String: String]], completion: @escaping (NSImage?) -> Void) {
        guard let key = key(for: pageURL) else { completion(nil); return }
        let candidates = rank(links: links, pageURL: pageURL)
        fetchFirst(candidates, key: key, completion: completion)
    }

    /// Loads an icon for a URL we have never visited (bookmarks, imports, history).
    func prefetch(for url: URL) {
        guard let key = key(for: url), memory[key] == nil, !inFlight.contains(key),
              !FileManager.default.fileExists(atPath: file(for: key).path) else { return }
        inFlight.insert(key)
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host()
        components.path = "/favicon.ico"
        var candidates: [URL] = []
        if let ico = components.url { candidates.append(ico) }
        components.path = "/apple-touch-icon.png"
        if let touch = components.url { candidates.append(touch) }
        fetchFirst(candidates, key: key) { [weak self] _ in self?.inFlight.remove(key) }
    }

    private func rank(links: [[String: String]], pageURL: URL) -> [URL] {
        func size(_ link: [String: String]) -> Int {
            let sizes = link["sizes"] ?? ""
            if sizes == "any" { return 512 }
            return sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 16
        }
        // Prefer the smallest icon that is at least 32px (crisp at 16pt @2x), then larger, then smaller.
        let scored = links.compactMap { link -> (URL, Int)? in
            guard let href = link["href"], let url = URL(string: href) else { return nil }
            let s = size(link)
            let isSVG = (link["type"] ?? "").contains("svg") || url.pathExtension.lowercased() == "svg"
            let isTouch = (link["rel"] ?? "").contains("apple-touch")
            var score = s >= 32 ? 1000 - s : s
            if isSVG { score = 1100 }
            if isTouch { score -= 50 }
            return (url, score)
        }
        var result = scored.sorted { $0.1 > $1.1 }.map(\.0)
        var components = URLComponents()
        components.scheme = pageURL.scheme
        components.host = pageURL.host()
        components.port = pageURL.port
        components.path = "/favicon.ico"
        if let fallback = components.url, !result.contains(fallback) { result.append(fallback) }
        return result
    }

    private func fetchFirst(_ candidates: [URL], key: String, completion: @escaping (NSImage?) -> Void) {
        guard let next = candidates.first else { completion(nil); return }
        let rest = Array(candidates.dropFirst())
        if next.scheme == "data", let data = try? Data(contentsOf: next), let image = NSImage(data: data), image.isValid {
            store(image, key: key)
            completion(image)
            return
        }
        Task {
            let result = try? await session.data(from: next)
            let ok = ((result?.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400
            if ok, let data = result?.0, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                store(image, key: key)
                completion(memory[key])
            } else {
                fetchFirst(rest, key: key, completion: completion)
            }
        }
    }

    /// Keeps an icon we already have (onboarding's site logos), so the sidebar never starts with a globe.
    func remember(_ image: NSImage, for url: URL) {
        guard let key = key(for: url), memory[key] == nil else { return }
        store(image, key: key)
    }

    private func store(_ image: NSImage, key: String) {
        let normalized = Self.normalize(image)
        memory[key] = normalized
        if let tiff = normalized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: file(for: key), options: .atomic)
        }
        updated.send(key)
    }

    /// Renders to a 64px bitmap so every icon draws the same, whatever the source format.
    private static func normalize(_ image: NSImage) -> NSImage {
        let side: CGFloat = 64
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.size = NSSize(width: Tokens.Metric.favicon, height: Tokens.Metric.favicon)
        return out
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
        memory[id] = image
        return image
    }

    static func save(_ image: NSImage, for id: UUID) {
        memory[id] = image
        guard let tiff = image.tiffRepresentation else { return }
        let url = file(id)
        DispatchQueue.global(qos: .utility).async { writeJPEG(tiff, to: url) }
    }

    nonisolated private static func writeJPEG(_ tiff: Data, to url: URL) {
        guard let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? jpg.write(to: url, options: .atomic)
    }

    static func remove(_ id: UUID) {
        memory[id] = nil
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
