import Foundation
import WebKit

/// A page as one MHTML file (RFC 2557), as Chrome's "Webpage, Single File" saves it: `multipart/related`, the
/// document first, then what it loaded and its frames, each with the address it came from, so the page's own
/// links find their parts when the file is opened. WebKit archives a page only as a web archive (a property list
/// of the same parts), so that is what's read here.
nonisolated enum PageArchive {
    struct Part: Equatable {
        let url: String
        let type: String
        let charset: String?
        let data: Data
    }

    /// A web archive's parts in the page's order: the document, what it loaded, then each frame's own the same way.
    /// Of what a page loaded, only pictures, stylesheets and fonts go in (`keeps`), as in Chrome's MHTML, which is a
    /// picture of the page and never runs it. A frame `includes` says no to is left out with everything in it, and
    /// so is a frame with no address of its own (about:blank, about:srcdoc): its origin isn't in the archive, and a
    /// reader couldn't tell two of them apart. Parts with no address or bytes stay out, so do `data:` parts (they're
    /// in the markup already), and so does a second part at an address already taken. Nil when the data isn't a web
    /// archive.
    static func parts(ofWebArchive archive: Data, includes: (String) -> Bool = { _ in true }) -> [Part]? {
        guard let plist = plist(archive), let main = part(plist["WebMainResource"]) else { return nil }
        var parts = [main]
        add(plist, into: &parts, includes: includes)
        var seen = Set<String>()
        return parts.filter { seen.insert($0.url).inserted }
    }

    /// The addresses of every frame in a web archive, frames inside frames too, for deciding which `parts` keeps.
    static func frameURLs(ofWebArchive archive: Data) -> Set<String> {
        var urls = Set<String>()
        func walk(_ archive: [String: Any]) {
            for frame in archive["WebSubframeArchives"] as? [Any] ?? [] {
                guard let frame = frame as? [String: Any] else { continue }
                if let url = (frame["WebMainResource"] as? [String: Any])?["WebResourceURL"] as? String { urls.insert(url) }
                walk(frame)
            }
        }
        if let plist = plist(archive) { walk(plist) }
        return urls
    }

    private static func plist(_ archive: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any]
    }

    private static func add(_ archive: [String: Any], into parts: inout [Part], includes: (String) -> Bool) {
        for resource in archive["WebSubresources"] as? [Any] ?? [] {
            if let made = part(resource), keeps(made) { parts.append(made) }
        }
        for frame in archive["WebSubframeArchives"] as? [Any] ?? [] {
            guard let frame = frame as? [String: Any], let document = part(frame["WebMainResource"]),
                  !document.url.lowercased().hasPrefix("about:"), includes(document.url) else { continue }
            parts.append(document)
            add(frame, into: &parts, includes: includes)
        }
    }

    /// A subresource for the file: only what a page shows, a picture, a stylesheet or a font, as in Chrome's MHTML,
    /// whatever site it came from. The archive keeps what a server finally answered under the address the page
    /// asked for, so neither the address nor the site says what the bytes are: a tag pointing at a private address
    /// (a router's page, an intranet's JSON), directly or through a redirect or a service worker, would otherwise
    /// bring back what the page itself could never read.
    /// From the web only: never a picture from one of Zigzag's own addresses (an icon, a tab's picture).
    static func keeps(_ part: Part) -> Bool {
        let scheme = part.url.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() }
        return isShown(part.type) && !isScript(part.type) && (scheme == "http" || scheme == "https")
    }

    /// A script's media type: the WHATWG list (`text/javascript`, `application/ecmascript` and the old spellings).
    static func isScript(_ type: String) -> Bool {
        ["text/javascript", "application/javascript", "application/x-javascript", "text/ecmascript", "application/ecmascript",
         "text/jscript", "text/livescript", "application/x-ecmascript", "text/x-javascript", "text/x-ecmascript",
         "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4",
         "text/javascript1.5"].contains(type)
    }

    /// What a page shows from another site: pictures, stylesheets and fonts.
    static func isShown(_ type: String) -> Bool {
        type.hasPrefix("image/") || type.hasPrefix("font/") || type == "text/css"
            || ["application/font-woff", "application/font-woff2", "application/x-font-woff", "application/font-sfnt",
                "application/x-font-ttf", "application/x-font-truetype", "application/x-font-otf", "application/x-font-opentype",
                "application/vnd.ms-fontobject"].contains(type)
    }

    private static func part(_ value: Any?) -> Part? {
        guard let resource = value as? [String: Any], let url = resource["WebResourceURL"] as? String, !url.isEmpty,
              !url.lowercased().hasPrefix("data:"), let data = resource["WebResourceData"] as? Data else { return nil }
        let type = (resource["WebResourceMIMEType"] as? String).flatMap(mediaType) ?? "application/octet-stream"
        return Part(url: url, type: type, charset: (resource["WebResourceTextEncodingName"] as? String).flatMap(token), data: data)
    }

    /// The MHTML for these parts, the first being the page. Every part goes as base64, which every reader takes and
    /// which never holds the boundary (it has characters base64 doesn't). What came from the page (its title, its
    /// parts' addresses and types) can't start a header of its own: line breaks and other control characters go.
    static func mhtml(_ parts: [Part], title: String, date: Date = Date(), boundary: String = "----MultipartBoundary--" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> Data {
        let page = parts.first
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var text = "From: <Saved by Zigzag>\r\n"
        if let page { text += "Snapshot-Content-Location: \(headerSafe(page.url))\r\n" }
        text += "Subject: \(encodedWord(title))\r\n"
        text += "Date: \(format.string(from: date))\r\n"
        text += "MIME-Version: 1.0\r\n"
        text += "Content-Type: multipart/related;\r\n\ttype=\"\(page?.type ?? "text/html")\";\r\n\tboundary=\"\(boundary)\"\r\n\r\n"
        var out = Data(text.utf8)
        for part in parts {
            var head = "--\(boundary)\r\n"
            head += "Content-Type: \(part.type)\(part.charset.map { "; charset=\($0)" } ?? "")\r\n"
            head += "Content-Transfer-Encoding: base64\r\n"
            head += "Content-Location: \(headerSafe(part.url))\r\n\r\n"
            out.append(Data(head.utf8))
            out.append(part.data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            out.append(Data("\r\n\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    /// A media type as a header takes it (`text/html`), or nil.
    static func mediaType(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let type = token(String(parts[0])), let subtype = token(String(parts[1])) else { return nil }
        return (type + "/" + subtype).lowercased()
    }

    /// A header token (RFC 2045: a charset's name, a type's halves), or nil.
    static func token(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~").union(CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        guard !value.isEmpty, value.count <= 128, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    /// A value on one header line: no line breaks or other control characters.
    static func headerSafe(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
    }

    /// A header's words in ASCII, as RFC 2047 has them when they aren't.
    static func encodedWord(_ text: String) -> String {
        let plain = headerSafe(text)
        if plain.unicodeScalars.allSatisfy({ $0.isASCII }) { return plain }
        return "=?utf-8?B?\(Data(plain.utf8).base64EncodedString())?="
    }
}

/// `chrome.pageCapture.saveAsMHTML`: a tab, as Chrome saves it, for an extension allowed on its site. WebKit names
/// tabs to extensions by IDs only an extension's own `tabs` API knows, so bridge.js says what `tabs.get` and
/// `windows.get` tell it of the tab, and it's found here among the tabs the extension sees. A frame from a site the
/// extension can't reach is left out of the file.
@available(macOS 15.4, *)
@MainActor
final class BridgePageCapture: BridgeNamespace {
    static let name = "pageCapture"
    static let permission = "pageCapture"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    /// What the extension's `tabs.get` and `windows.get` said of the tab.
    struct Hint: Equatable {
        let url: String?
        let index: Int
        let active: Bool
        /// Its window's tabs' addresses, in order; nil for one the extension isn't told.
        let windowURLs: [String?]?

        init?(_ value: [String: Any]) {
            guard let index = (value["index"] as? NSNumber)?.intValue, index >= 0 else { return nil }
            // WebKit tells an extension "" for the address of a tab on a site it can't access.
            let known = { (value: Any?) -> String? in (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
            url = known(value["url"])
            self.index = index
            active = value["active"] as? Bool ?? false
            windowURLs = (value["urls"] as? [Any])?.map(known)
        }

        init(url: String?, index: Int, active: Bool, windowURLs: [String?]?) {
            self.url = url
            self.index = index
            self.active = active
            self.windowURLs = windowURLs
        }
    }

    /// One of the tabs an extension sees, as the hint is matched against it.
    struct Seen {
        let url: String?
        let active: Bool
    }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "saveAsMHTML":
            guard let hint = Hint(args.object(0)) else { throw BridgeError("Cannot find the tab for this request.") }
            return try await save(hint, for: extensionID)
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// The largest page saved, as WebKit archives it: past this, the archive, the file and its copy for the
    /// extension would hold more than a gigabyte between them.
    nonisolated static let largestArchive = 256 * 1024 * 1024

    /// The window and place the hint names, among the windows the extension sees (each a list of its tabs): the one
    /// window whose tabs read as the hint's window does, with the tab at that place showing the same page. A tab
    /// reads as its address only where the extension may save it, and as nothing elsewhere, so a hint can't test a
    /// guess at the address of a tab it can't read: the tab asked for must match, and any other matches whatever
    /// the hint says where either side has no address. Nil when none or more than one window fits.
    nonisolated static func place(of hint: Hint, in windows: [[Seen]]) -> (window: Int, index: Int)? {
        guard let url = hint.url else { return nil }
        let fits = windows.indices.filter { w in
            let tabs = windows[w]
            guard tabs.indices.contains(hint.index), tabs[hint.index].url == url, tabs[hint.index].active == hint.active else { return false }
            guard let urls = hint.windowURLs else { return true }
            return urls.count == tabs.count && zip(urls, tabs).allSatisfy { said, tab in said == nil || tab.url == nil || said == tab.url }
        }
        guard fits.count == 1, let window = fits.first else { return nil }
        return (window, hint.index)
    }

    /// The tab's page as MHTML, in base64 for the trip back to bridge.js. The archive is read and written away from
    /// the main thread; which frames go in is decided on it, with what the extension may reach once the page is read.
    private func save(_ hint: Hint, for extensionID: String) async throws -> String {
        let denied = BridgeError("Extension manifest must request permission to access this host.")
        let missing = BridgeError("Cannot find the tab for this request.")
        guard let context = host.context(for: extensionID), let controller = context.webExtensionController else { throw missing }
        // Without the tab's address the extension can't reach its site, so there's nothing it may save.
        guard hint.url != nil else { throw denied }
        // Private windows only for an extension allowed in them (WebKit's list leaves them out already; this says so here).
        let open = host.webExtensionController(controller, openWindowsFor: context)
        let windows = open.map { window -> [any WKWebExtensionTab] in
            (window.isPrivate?(for: context) ?? false) && !context.hasAccessToPrivateData ? [] : window.tabs?(for: context) ?? []
        }
        // Active as tabs.get says it: the window's active tab, which isn't every selected one.
        let seen = zip(open, windows).map { window, tabs in
            let active = window.activeTab?(for: context)
            return tabs.map { tab in
                Seen(url: tab.url?(for: context).flatMap { mayReach($0, in: tab, context: context) ? $0.absoluteString : nil },
                     active: active.map { $0 === tab } ?? tab.isSelected?(for: context) ?? false)
            }
        }
        guard let place = Self.place(of: hint, in: seen) else { throw missing }
        let tab = windows[place.window][place.index]
        guard (tab as? Tab)?.isPrivate != true || context.hasAccessToPrivateData,
              let webView = tab.webView?(for: context), let url = webView.url else { throw missing }
        guard mayReach(url, in: tab, context: context) else { throw denied }
        let archive: Data = try await withCheckedThrowingContinuation { done in
            webView.createWebArchiveData { done.resume(with: $0) }
        }
        guard archive.count <= Self.largestArchive else { throw BridgeError("Cannot save this page: it's too large.") }
        let frames = await Task.detached { PageArchive.frameURLs(ofWebArchive: archive) }.value
        // As in Chrome: a page that changed while it was read isn't saved as the one asked for; and the extension
        // still needs the site now, since it could have lost it meanwhile.
        guard webView.url == url else { throw BridgeError("Tab navigated before capture could complete.") }
        guard mayReach(url, in: tab, context: context) else { throw denied }
        let allowed = frames.filter { frame in URL(string: frame).map { mayReach($0, in: tab, context: context) } ?? false }
        let title = webView.title ?? ""
        let page = Self.withoutFragment(url.absoluteString)
        let made = await Task.detached { () -> (page: String?, file: String?) in
            guard let parts = PageArchive.parts(ofWebArchive: archive, includes: allowed.contains) else { return (nil, nil) }
            return (parts.first?.url, PageArchive.mhtml(parts, title: title).base64EncodedString())
        }.value
        guard let file = made.file else { throw BridgeError("Cannot save this page.") }
        // The archive is of the page that was checked, not one that came in between.
        guard made.page.map(Self.withoutFragment) == page else { throw BridgeError("Tab navigated before capture could complete.") }
        return file
    }

    nonisolated static func withoutFragment(_ url: String) -> String {
        url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
    }

    /// The extension may save the page at this address in this tab (`reaches`), as WebKit decides its access.
    private func mayReach(_ url: URL, in tab: any WKWebExtensionTab, context: WKWebExtensionContext) -> Bool {
        Self.reaches(url, hasAccess: context.hasAccess(to: url, in: tab), offSites: ExtensionStore.extensionsOffSites(in: host.profile))
    }

    /// A web page on a site the extension has (what it asked for and you allowed, or the tab through activeTab:
    /// WebKit's `hasAccess`), where extensions aren't switched off. Site access On All Sites means every site it
    /// was approved for, not every site, so it opens nothing more here.
    static func reaches(_ url: URL, hasAccess: Bool, offSites: Set<String>) -> Bool {
        guard hasAccess, isCapturable(url) else { return false }
        return BridgeTabCapture.siteAllows(url, offSites: offSites, hasAccess: true, allSites: false)
    }

    /// A page an extension may save: http and https. Not a file: Chrome asks for that separately (Allow access to
    /// file URLs), and Zigzag has no such switch. Never one of Zigzag's own pages.
    nonisolated static func isCapturable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
