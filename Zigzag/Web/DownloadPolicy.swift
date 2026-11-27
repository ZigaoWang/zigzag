import WebKit

/// What a page may download and which responses are shown, shared by tabs and pop-ups so an attachment is never shown
/// (and run) as a page, and neither can start a download stream. Attachments (`Content-Disposition: attachment`) and
/// types WebKit can't show are saved; web pages are always shown, even from a service worker before WebKit knows it
/// can. A file you navigated to (click, typed or pasted address, plus redirects) always saves, and so does a frame's
/// right after a click in it. An unrequested download (a script's, the page navigating to a file, a hidden frame
/// handing over an export) is allowed once, then refused for 30 seconds unless you click or type in the page. A
/// frame's file then goes through the site's download permission as the page's does, its own site's Block included.
@MainActor
final class DownloadPolicy {
    static let scriptDownloadGap: TimeInterval = 30
    /// A click in a frame allows its download for this long (a download page's hidden frame).
    static let frameClickWindow: TimeInterval = 10

    private var lastScriptDownload: Date?
    /// You clicked or typed since the last unrequested download, so the next isn't held back.
    private var actedSinceScriptDownload = false
    private var frameClickedAt: Date?
    /// The pending main-frame navigation was user-started (click, key, address bar).
    private var mainFrameClicked = false
    /// For a response that turns out to be a file.
    var mainFrameWasClicked: Bool { mainFrameClicked }
    /// The site each frame navigated from lately, by the address it went to.
    private var frameSites: [(url: URL, site: String)] = []

    /// A frame went to `url` from a page of `site`: a file it gets there answers to that site's download permission
    /// as well as the page's.
    func noteFrame(navigatingTo url: URL?, from site: String?) {
        guard let url, let site else { return }
        frameSites.removeAll { $0.url == url }
        frameSites.append((url, site))
        if frameSites.count > 16 { frameSites.removeFirst(frameSites.count - 16) }
    }

    /// The sites a frame's file at `url` answers to besides the page's: the frame's own, and the file's.
    func frameSites(for url: URL) -> [String] {
        var sites = frameSites.filter { $0.url == url }.map(\.site)
        if let own = SiteOrigin.of(url), !sites.contains(own) { sites.append(own) }
        return sites
    }

    /// Records a navigation and decides `download`-attribute links: `.download`, or `.cancel` for an unclicked one
    /// too soon after another. Nil for normal navigations. `clicked`: user-started, or Zigzag's own load.
    /// `lastInput`: your last click or key in the page, which WebKit stops counting once the page has waited on its
    /// server.
    func decide(shouldDownload: Bool, clicked: Bool, isMainFrame: Bool, now: Date = Date(), lastInput: Date? = nil) -> WKNavigationActionPolicy? {
        if isMainFrame { mainFrameClicked = clicked } else if clicked { frameClickedAt = now }
        if clicked { actedSinceScriptDownload = true }
        guard shouldDownload else { return nil }
        return clicked || mayDownloadUnasked(now: now, lastInput: lastInput) ? .download : .cancel
    }

    /// `.cancel` refuses a download.
    func decide(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool, isMainFrame: Bool, now: Date = Date(),
                lastInput: Date? = nil) -> WKNavigationResponsePolicy {
        guard Self.downloads(mimeType: mimeType, contentDisposition: contentDisposition, canShowMIMEType: canShowMIMEType) else { return .allow }
        // A frame's file counts as the page's own unrequested download, as in Chrome and Safari: a hidden frame is how
        // web apps hand over an export long after the click (#535).
        guard isMainFrame else {
            if frameClickedAt.map({ now.timeIntervalSince($0) < Self.frameClickWindow }) == true { return .download }
            return mayDownloadUnasked(now: now, lastInput: lastInput) ? .download : .cancel
        }
        // A user-started navigation (redirects included, since their own decisions aren't clicks) saves; a page
        // navigating on its own ("your download starts in 5 seconds") counts as unrequested.
        return mainFrameClicked || mayDownloadUnasked(now: now, lastInput: lastInput) ? .download : .cancel
    }

    /// Your last click or key in this page, as a date for `decide`.
    static func lastInput(in webView: WKWebView, now: Date = Date()) -> Date? {
        PopupNotice.sinceInput(in: webView).map { now.addingTimeInterval(-$0) }
    }

    /// Whether a download is a Firefox extension package, which is installed rather than kept as a file. AMO's
    /// Add to Firefox hands over `application/x-xpinstall`; a package served as a plain file still names itself
    /// `.xpi`. Only the type decides; the contents are checked by the store's own verification.
    nonisolated static func isExtensionPackage(mimeType: String?, filename: String) -> Bool {
        let mime = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mime == "application/x-xpinstall" { return true }
        return filename.lowercased().hasSuffix(".xpi")
    }

    nonisolated static func downloads(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool) -> Bool {
        let mime = (mimeType ?? "").lowercased()
        let disposition = (contentDisposition ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // Web pages always show. WebKit can briefly report it can't show HTML (a service worker's response, e.g.
        // YouTube's first load), and saving "youtube.com.html" is never right.
        let isWebPage = mime.isEmpty || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime)
        // Attachments always save, web pages included, as in Chrome and Safari. Sites serve user uploads this way so
        // they never run as the site's pages.
        let isAttachment = disposition.hasPrefix("attachment")
        return isAttachment || !(isWebPage || canShowMIMEType)
    }

    private func mayDownloadUnasked(now: Date, lastInput: Date?) -> Bool {
        if let lastInput, let last = lastScriptDownload, lastInput > last { actedSinceScriptDownload = true }
        if !actedSinceScriptDownload, let last = lastScriptDownload, now.timeIntervalSince(last) < Self.scriptDownloadGap { return false }
        lastScriptDownload = now
        actedSinceScriptDownload = false
        return true
    }

    /// Toast text for a refused download.
    static var refusedText: String {
        String(localized: "Blocked a download the page started on its own",
               comment: "Toast when a page starts a second download within half a minute without a click.")
    }

    /// Toast text for a refused download a frame in the page started.
    static var refusedFrameText: String {
        String(localized: "Blocked a download a frame in this page started on its own",
               comment: "Toast when a frame inside a web page (often a hidden one) starts a second download within half a minute without a click.")
    }

    /// What Report a Problem notes for a refused download.
    static func refusedNote(isMainFrame: Bool) -> String {
        isMainFrame ? "A page started another download without a click" : "A frame in the page started another download without a click"
    }

    /// Uses the permission's wording so the click explains itself.
    static var blockedText: String {
        String(localized: "Blocked a download from this site",
               comment: "Toast when a site is not allowed to save files and sends one anyway.")
    }

    /// Only plain GETs can be re-requested for Allow Once; a POST would need the form resent, so its notice offers
    /// nothing. Nil request (a closed pop-up): nothing to offer.
    nonisolated static func canBeAskedAgain(_ request: URLRequest?) -> Bool {
        guard let request else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        return method == "GET" && request.httpBody == nil
    }
}
