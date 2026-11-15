import WebKit

/// What a page may save to your Mac, and which responses are shown rather than saved: one policy, for a tab's page and
/// a pop-up window's alike, so a file a site serves as an attachment is never shown (and run) as a page in a pop-up,
/// and a page can't start a stream of downloads from either.
///
/// - A response sent as an attachment (`Content-Disposition: attachment`), or one WebKit can't show, is saved; a web
///   page is always shown, even one a service worker hands over before WebKit knows it can show it.
/// - A frame saves a file only just after a click in it: files in frames aren't saved behind your back.
/// - A file the page itself goes to after you sent it there (a link you clicked, an address you typed or pasted, the
///   redirects on the way) always saves.
/// - A download nobody asked for (a script's, or the page going to a file on its own) is let through once, then not
///   again for half a minute unless you've clicked or typed in the meantime.
@MainActor
final class DownloadPolicy {
    /// How long after a download nobody clicked for another one is refused.
    static let scriptDownloadGap: TimeInterval = 30
    /// How long after a click in a frame it may hand over a file (a download page's hidden frame).
    static let frameClickWindow: TimeInterval = 10

    private var lastScriptDownload: Date?
    /// You clicked or typed for something since the last download nobody asked for: the next one isn't held back.
    private var actedSinceScriptDownload = false
    private var frameClickedAt: Date?
    /// Whether the main frame's navigation now on its way was started by you (a click, a key, the address bar).
    private var mainFrameClicked = false
    /// Whether the last main-frame navigation was one you started, for a response that turns out to be a file.
    var mainFrameWasClicked: Bool { mainFrameClicked }

    /// Takes note of a navigation and decides it if it's a download WebKit was asked for (a link with `download`):
    /// `.download`, or `.cancel` for another one nobody clicked for too soon. nil: it isn't one, decided as usual.
    /// `clicked`: you started it, with a click or a key, or it's Zigzag's own load.
    func decide(shouldDownload: Bool, clicked: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationActionPolicy? {
        if isMainFrame { mainFrameClicked = clicked } else if clicked { frameClickedAt = now }
        if clicked { actedSinceScriptDownload = true }
        guard shouldDownload else { return nil }
        return clicked || mayDownloadUnasked(now: now) ? .download : .cancel
    }

    /// Whether a response is shown, saved, or neither (`.cancel`: a download refused).
    func decide(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationResponsePolicy {
        guard Self.downloads(mimeType: mimeType, contentDisposition: contentDisposition, canShowMIMEType: canShowMIMEType) else { return .allow }
        guard isMainFrame else {
            return frameClickedAt.map { now.timeIntervalSince($0) < Self.frameClickWindow } == true ? .download : .cancel
        }
        // Where you sent the page, a redirect on the way included (its own decision isn't a click), saves; one the
        // page went to on its own (a "your download starts in 5 seconds" page) counts as a download nobody asked for.
        return mainFrameClicked || mayDownloadUnasked(now: now) ? .download : .cancel
    }

    /// Whether a response is a file to save rather than a page to show.
    nonisolated static func downloads(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool) -> Bool {
        let mime = (mimeType ?? "").lowercased()
        let disposition = (contentDisposition ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // A web page is shown, always. WebKit can briefly say it can't show HTML (a response handed over by a
        // service worker, as YouTube's first load does), and a page saved as "youtube.com.html" is never right.
        let isWebPage = mime.isEmpty || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime)
        // Sent as an attachment: saved, a web page too, with a name or without, as in Chrome and Safari. Sites serve
        // their users' uploads that way so the upload never runs as one of the site's own pages.
        let isAttachment = disposition.hasPrefix("attachment")
        return isAttachment || !(isWebPage || canShowMIMEType)
    }

    private func mayDownloadUnasked(now: Date) -> Bool {
        if !actedSinceScriptDownload, let last = lastScriptDownload, now.timeIntervalSince(last) < Self.scriptDownloadGap { return false }
        lastScriptDownload = now
        actedSinceScriptDownload = false
        return true
    }

    /// What a refused download says, in a toast where the page is.
    static var refusedText: String {
        String(localized: "Blocked a download the page started on its own",
               comment: "Toast when a page starts a second download within half a minute without a click.")
    }

    /// What a download the site may not make says: the permission's own words, so a click that saves nothing says why.
    static var blockedText: String {
        String(localized: "Blocked a download from this site",
               comment: "Toast when a site is not allowed to save files and sends one anyway.")
    }
}
