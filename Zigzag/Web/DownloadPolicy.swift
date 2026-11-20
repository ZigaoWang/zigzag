import WebKit

/// What a page may download and which responses are shown, shared by tabs and pop-ups so an attachment is never shown
/// (and run) as a page, and neither can start a download stream. Attachments (`Content-Disposition: attachment`) and
/// types WebKit can't show are saved; web pages are always shown, even from a service worker before WebKit knows it
/// can. Frames download only right after a click in them. A file you navigated to (click, typed or pasted address,
/// plus redirects) always saves. An unrequested download (a script's, or the page navigating to a file) is allowed
/// once, then refused for 30 seconds unless you click or type.
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

    /// Records a navigation and decides `download`-attribute links: `.download`, or `.cancel` for an unclicked one
    /// too soon after another. Nil for normal navigations. `clicked`: user-started, or Zigzag's own load.
    func decide(shouldDownload: Bool, clicked: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationActionPolicy? {
        if isMainFrame { mainFrameClicked = clicked } else if clicked { frameClickedAt = now }
        if clicked { actedSinceScriptDownload = true }
        guard shouldDownload else { return nil }
        return clicked || mayDownloadUnasked(now: now) ? .download : .cancel
    }

    /// `.cancel` refuses a download.
    func decide(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationResponsePolicy {
        guard Self.downloads(mimeType: mimeType, contentDisposition: contentDisposition, canShowMIMEType: canShowMIMEType) else { return .allow }
        guard isMainFrame else {
            return frameClickedAt.map { now.timeIntervalSince($0) < Self.frameClickWindow } == true ? .download : .cancel
        }
        // A user-started navigation (redirects included, since their own decisions aren't clicks) saves; a page
        // navigating on its own ("your download starts in 5 seconds") counts as unrequested.
        return mainFrameClicked || mayDownloadUnasked(now: now) ? .download : .cancel
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

    private func mayDownloadUnasked(now: Date) -> Bool {
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
