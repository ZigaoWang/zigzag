import AppKit

/// The page a space starts on: `zigzag://blank`, its ground and picture with the wordmark on it.
///
/// It is a document, not a view drawn over the card, so it is shown the one way every other page is. The card keeps
/// the native backdrop under it (`EmptyPageBackdrop`): the page has to load before it can draw, and a swipe paints
/// the empty card partway between two spaces' looks, which one served ground can't.
@MainActor
enum ViewportPage {
    /// The blank page's one address. The window asks for it through `blankURL`, the scheme handler reads it through
    /// `blankRequest(in:)`.
    static let blank = URL(string: "\(HistoryPage.scheme)://\(blankHost)")!
    static let blankHost = "blank"
    /// The space's picture, served as bytes: the name it is stored under is a file in Zigzag's own folder, which the
    /// page can't read for itself.
    static let pictureHost = "blank-picture"

    static func isBlank(_ url: URL?) -> Bool { HistoryPage.isInternal(url) && url?.host() == blankHost }

    /// The address for `space`'s blank page. The space, whether the window is private, and the picture travel in the
    /// request, so a window that isn't key never draws the key window's space. The picture is in the address so a
    /// space whose picture changed is a different address, never a cached document with the old photo.
    /// `ground` is the card's color as the window draws it (`ground(_:)`), which may be a look still being edited; with
    /// it the address is the whole page, and a picture shows only if the address names one.
    static func blankURL(for space: UUID, isPrivate: Bool, picture: String? = nil, ground: String? = nil) -> URL {
        var components = URLComponents(url: blank, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "space", value: space.uuidString)]
        if isPrivate { components.queryItems?.append(URLQueryItem(name: "private", value: "1")) }
        if let picture, !isPrivate, SpaceBackground.isKept(picture) {
            components.queryItems?.append(URLQueryItem(name: "picture", value: picture))
        }
        if let ground {
            components.queryItems?.append(URLQueryItem(name: "ground", value: ground))
        }
        return components.url!
    }

    /// A ground for the address: light and dark, eight hex digits each.
    static func ground(_ color: NSColor) -> String { color.hex(dark: false) + "," + color.hex(dark: true) }

    /// What a blank address asks for, as it was written: the space's id (nil if the address names none), whether the
    /// window is private, the picture's stored name if the address carries one Zigzag kept, and the ground's light and
    /// dark colors if it gives them. Only a blank address is answered; any other host reads as no request at all.
    static func blankRequest(in url: URL) -> (space: UUID?, isPrivate: Bool, picture: String?, ground: (light: String, dark: String)?)? {
        guard url.host() == blankHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let space = items.first { $0.name == "space" }?.value.flatMap(UUID.init(uuidString:))
        let isPrivate = items.first { $0.name == "private" }?.value == "1"
        let picture = items.first { $0.name == "picture" }?.value.flatMap { SpaceBackground.isKept($0) ? $0 : nil }
        let colors = items.first { $0.name == "ground" }?.value?.split(separator: ",").map(String.init) ?? []
        let isHex = { (s: String) in s.count == 8 && s.allSatisfy(\.isHexDigit) }
        let ground = colors.count == 2 && colors.allSatisfy(isHex) ? (light: "#" + colors[0], dark: "#" + colors[1]) : nil
        return (space, isPrivate, picture, ground)
    }

    /// The document an address asks for. `space` resolves the id the address names; it is a parameter so a test can
    /// answer without a window or the Library, and so the served page can only ever draw the space it was asked for.
    /// A private window never draws a picture: the address can name one, and it is ignored.
    static func html(for url: URL, space: (UUID) -> SpaceInfo? = { Library.shared.space($0) }) -> String {
        let request = blankRequest(in: url)
        let isPrivate = request?.isPrivate == true
        if let ground = request?.ground {
            return blankHTML(ground: ground, picture: isPrivate ? nil : request?.picture)
        }
        return blankHTML(for: request?.space.flatMap(space), isPrivate: isPrivate,
                         picture: isPrivate ? nil : request?.picture)
    }

    /// The picture an address asks for, if it is one Zigzag stored: never a path of the page's choosing.
    static func pictureName(in url: URL) -> String? {
        guard url.host() == pictureHost,
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value,
              SpaceBackground.isKept(name) else { return nil }
        return name
    }

    /// The page itself: the space's ground, its picture, and the wordmark on both. `picture` is the stored name the
    /// address carried, if any; without one the space's own picture is used. A private window never draws a picture.
    /// Colors come for both appearances at once, so the page follows the window between light and dark.
    static func blankHTML(for space: SpaceInfo?, isPrivate: Bool, picture named: String? = nil) -> String {
        let ground = EmptyPage.ground(for: space, isPrivate: isPrivate)
        return blankHTML(ground: (ground.css(dark: false), ground.css(dark: true)),
                         picture: isPrivate ? nil : (named ?? EmptyPage.picture(for: space, isPrivate: isPrivate)))
    }

    /// The page for a ground given as CSS colors, light and dark, and the stored picture on it, if any.
    static func blankHTML(ground: (light: String, dark: String), picture: String?) -> String {
        // Images decoded before they paint, so the page never shows less than the native card under it.
        let name = picture?.addingPercentEncoding(withAllowedCharacters: Self.nameCharacters) ?? ""
        let photo = picture == nil ? "" : "<img class=\"photo\" alt=\"\" decoding=\"sync\" src=\"\(HistoryPage.scheme)://\(pictureHost)?name=\(name)\">"
        let style = """
        :root{--ground:\(ground.light)}
        @media (prefers-color-scheme: dark){:root{--ground:\(ground.dark)}}
        body{background:var(--ground)}
        .photo{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
        \(markPlacement)
        """
        return document(style: style, body: photo + mark(onPicture: picture != nil))
    }

    /// Letters, digits and the marks a stored picture's name is made of (`SpaceBackground.freshName`), so the name in
    /// the address is the file's own and the route can check it against the folder.
    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    /// Where `BrowserRootView.markFrame` puts the native mark, rounded the same way, so the two land on the same pixels.
    private static var markPlacement: String {
        let size = EmptySpaceMark.size
        func n(_ v: CGFloat) -> String { String(format: "%.3f", v) }
        return ".mark img{position:absolute;width:\(n(size.width))px;height:\(n(size.height))px;"
            + "left:round(50% - \(n(size.width / 2))px, 1px);top:round(50% - \(n(size.height / 2))px, 1px)}"
            + ".mark .dark{display:none}@media (prefers-color-scheme: dark){.mark .light{display:none}.mark .dark{display:block}}"
    }

    // MARK: The wordmark

    /// The wordmark's own route: `EmptySpaceMark`'s drawing as a picture, so the page and the native mark under it are
    /// the same pixels.
    static let markHost = "blank-mark"

    /// The mark in both appearances and at both screen scales; CSS shows the one for the appearance.
    private static func mark(onPicture: Bool) -> String {
        func url(dark: Bool, scale: Int) -> String {
            "\(HistoryPage.scheme)://\(markHost)?on=\(onPicture ? "picture" : "ground")&dark=\(dark ? 1 : 0)&scale=\(scale)"
        }
        func image(dark: Bool) -> String {
            "<img class=\"\(dark ? "dark" : "light")\" alt=\"\" decoding=\"sync\" srcset=\"\(url(dark: dark, scale: 1)) 1x, \(url(dark: dark, scale: 2)) 2x\">"
        }
        return "<div class=\"mark\">\(image(dark: false))\(image(dark: true))</div>"
    }

    /// What a mark address asks for: on a picture or a ground, dark or light, and at 1x or 2x.
    static func markRequest(in url: URL) -> (onPicture: Bool, dark: Bool, scale: Int)? {
        guard url.host() == markHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let scale = value("scale").flatMap(Int.init), [1, 2].contains(scale) else { return nil }
        return (value("on") == "picture", value("dark") == "1", scale)
    }

    private static var marks: [String: Data] = [:]

    /// `EmptySpaceMark` drawn as a PNG, as it draws in the window.
    static func markPNG(onPicture: Bool, dark: Bool, scale: Int) -> Data? {
        let key = "\(onPicture) \(dark) \(scale) \(Tokens.Contrast.isIncreased)"
        if let kept = marks[key] { return kept }
        let view = EmptySpaceMark(frame: NSRect(origin: .zero, size: EmptySpaceMark.size))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.onPicture = onPicture
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((view.bounds.width * CGFloat(scale)).rounded(.up)),
                                         pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB)
        else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        marks[key] = png
        return png
    }

    /// A document with Zigzag's ground and no chrome of its own: no header, no selection, no scrollbars, and nothing
    /// to press.
    private static func document(style: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="\(Bundle.main.preferredLocalizations.first ?? "en")">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(HistoryPage.scheme):; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light dark}
        html,body{margin:0;height:100%;overflow:hidden}
        body{-webkit-user-select:none;cursor:default}
        \(style)
        </style></head>
        <body>\(body)</body></html>
        """
    }
}

extension NSColor {
    /// A color as CSS reads it, resolved for one appearance. A dynamic color (`EmptyPage.ground`,
    /// `Tokens.Color.markOnPicture`) has to be pinned to one before it can be written, which is why a page that follows
    /// the window is written once per appearance.
    func css(dark: Bool) -> String {
        var resolved = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        guard let srgb = resolved.usingColorSpace(.sRGB) else { return "#000" }
        let (r, g, b) = (Int((srgb.redComponent * 255).rounded()), Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        guard srgb.alphaComponent < 1 else { return String(format: "#%02X%02X%02X", r, g, b) }
        return String(format: "rgba(%d,%d,%d,%.3g)", r, g, b, srgb.alphaComponent)
    }

    /// The color for one appearance as eight hex digits, red to alpha, for an address.
    func hex(dark: Bool) -> String {
        var resolved = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        guard let srgb = resolved.usingColorSpace(.sRGB) else { return "000000FF" }
        let parts = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        return parts.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }
}
