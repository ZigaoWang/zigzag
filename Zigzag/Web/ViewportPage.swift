import AppKit

/// The page a space starts on: `zigzag://blank`, its ground and picture with the wordmark on it.
///
/// It is a document, not a view drawn over the card, so it is shown the one way every other page is. The card keeps
/// the native backdrop under it (`EmptyPageBackdrop`): the page has to load before it can draw, and a swipe paints
/// the empty card partway between two spaces' looks, which one served ground can't.
@MainActor
enum ViewportPage {
    /// The blank page's one address, in the place that owns the route. Everything that asks for the page builds on it:
    /// the browser window through `blankURL(for:isPrivate:picture:)`, the edge preview's Mini through the same, and the
    /// scheme handler through `blankRequest(in:)`. Nothing else spells `zigzag://blank`.
    static let blank = URL(string: "\(HistoryPage.scheme)://\(blankHost)")!
    static let blankHost = "blank"
    /// The space's picture, served as bytes: the name it is stored under is a file in Zigzag's own folder, which the
    /// page can't read for itself.
    static let pictureHost = "blank-picture"

    static func isBlank(_ url: URL?) -> Bool { HistoryPage.isInternal(url) && url?.host() == blankHost }

    /// The address for `space`'s blank page. The space, whether the window is private, and the picture travel in the
    /// request: the page is also served into a child window (the edge preview's Mini) and into a window that isn't key,
    /// where looking at the key window would name a space that isn't the one being shown. The picture is in the address
    /// so a space whose picture changed is a different address, never a cached document with the old photo.
    static func blankURL(for space: UUID, isPrivate: Bool, picture: String? = nil) -> URL {
        var components = URLComponents(url: blank, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "space", value: space.uuidString)]
        if isPrivate { components.queryItems?.append(URLQueryItem(name: "private", value: "1")) }
        if let picture, !isPrivate, SpaceBackground.isKept(picture) {
            components.queryItems?.append(URLQueryItem(name: "picture", value: picture))
        }
        return components.url!
    }

    /// What a blank address asks for, as it was written: the space's id (nil if the address names none), whether the
    /// window is private, and the picture's stored name if the address carries one Zigzag kept. Only a blank address is
    /// answered; any other host reads as no request at all.
    static func blankRequest(in url: URL) -> (space: UUID?, isPrivate: Bool, picture: String?)? {
        guard url.host() == blankHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let space = items.first { $0.name == "space" }?.value.flatMap(UUID.init(uuidString:))
        let isPrivate = items.first { $0.name == "private" }?.value == "1"
        let picture = items.first { $0.name == "picture" }?.value.flatMap { SpaceBackground.isKept($0) ? $0 : nil }
        return (space, isPrivate, picture)
    }

    /// The document an address asks for. `space` resolves the id the address names; it is a parameter so a test can
    /// answer without a window or the Library, and so the served page can only ever draw the space it was asked for.
    /// A private window never draws a picture: the address can name one, and it is ignored.
    static func html(for url: URL, space: (UUID) -> SpaceInfo? = { Library.shared.space($0) }) -> String {
        let request = blankRequest(in: url)
        let isPrivate = request?.isPrivate == true
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
    /// Colours come for both appearances at once, as `PageStyle` gives them, so the page follows the window between
    /// light and dark without being served again.
    static func blankHTML(for space: SpaceInfo?, isPrivate: Bool, picture named: String? = nil) -> String {
        let picture = isPrivate ? nil : (named ?? EmptyPage.picture(for: space, isPrivate: isPrivate))
        // On a picture the engraving isn't legible, so the letters are drawn white with a soft shadow, as the native
        // mark does (`Tokens.Color.markOnPicture`). On a ground they are cut into it, as `EmptySpaceMark` cuts them:
        // their floor a shade under the ground, a line of light along their lower rim, a soft shadow just inside it.
        let floor = picture == nil ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.025) : Tokens.Color.markOnPicture
        let floorDark = picture == nil ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07) : Tokens.Color.markOnPicture
        let shadow = picture == nil ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.13) : Tokens.Color.markOnPictureShadow
        let shadowDark = picture == nil ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6) : Tokens.Color.markOnPictureShadow
        let mark = WordmarkView.svg(class: "mark", label: nil)
            .replacingOccurrences(of: "currentColor", with: "var(--mark)")
        // The rim's own colour has no token: it is light drawn under the letters, not text on the ground.
        let rim = "rgba(255,255,255,0.75)", rimDark = "rgba(255,255,255,0.2)"
        let rule = """
        :root{--ground:\(EmptyPage.ground(for: space, isPrivate: isPrivate).css(dark: false));
              --mark:\(floor.css(dark: false));--shadow:\(shadow.css(dark: false));--rim:\(rim)}
        @media (prefers-color-scheme: dark){:root{--ground:\(EmptyPage.ground(for: space, isPrivate: isPrivate).css(dark: true));
              --mark:\(floorDark.css(dark: true));--shadow:\(shadowDark.css(dark: true));--rim:\(rimDark)}}
        body{background:var(--ground);display:grid;place-items:center}
        .mark{width:\(markWidth)px;height:auto;color:var(--mark);
              filter:drop-shadow(0 1px 0 var(--rim)) drop-shadow(0 1.4px 1.4px var(--shadow))}
        """
        // The stored name is in the address, so a new picture for the same space is never read from a cache.
        let name = picture?.addingPercentEncoding(withAllowedCharacters: Self.nameCharacters) ?? ""
        let photo = picture.map { _ in "body{background-image:url('\(HistoryPage.scheme)://\(pictureHost)?name=\(name)');background-size:cover;background-position:center}" } ?? ""
        return document(style: rule + photo, body: mark)
    }

    /// Letters, digits and the marks a stored picture's name is made of (`SpaceBackground.freshName`), so the name in
    /// the address is the file's own and the route can check it against the folder.
    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

    /// The wordmark's width: the native drawing's (`EmptySpaceMark.size`) less its margin, so the page and the
    /// backdrop under it read as the same mark.
    static let markWidth: CGFloat = 28 * WordmarkView.aspect

    /// A document with Zigzag's ground and no chrome of its own: no header, no selection, no scrollbars, and nothing
    /// to press.
    private static func document(style: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="\(Bundle.main.preferredLocalizations.first ?? "en")">
        <head>
        <meta charset="utf-8">
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
    /// A colour as CSS reads it, resolved for one appearance. A dynamic colour (`EmptyPage.ground`,
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
}
