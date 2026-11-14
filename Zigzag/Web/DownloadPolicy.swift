import WebKit

/// What a page may save to your Mac, and which responses are shown rather than saved: one policy, for a tab's page and
/// a pop-up window's alike, so a file a site serves as an attachment is never shown (and run) as a page in a pop-up,
/// and a page can't start a stream of downloads from either.
///
/// - A response sent as an attachment (`Content-Disposition: attachment`), or one WebKit can't show, is saved; a web
///   page is always shown, even one a service worker hands over before WebKit knows it can show it.
/// - A frame saves a file only just after a click in it: files in frames aren't saved behind your back.
/// - A download nobody clicked for (a script's, or a response that can't be shown) is let through once, then not
///   again for half a minute.
@MainActor
final class DownloadPolicy {
    /// How long after a download nobody clicked for another one is refused.
    static let scriptDownloadGap: TimeInterval = 30
    /// How long after a click in a frame it may hand over a file (a download page's hidden frame).
    static let frameClickWindow: TimeInterval = 10

    private var lastScriptDownload: Date?
    private var frameClickedAt: Date?
    /// Whether the main frame's navigation now on its way was started by you (a click, a key, the address bar).
    private var mainFrameClicked = false

    /// Takes note of a navigation and decides it if it's a download WebKit was asked for (a link with `download`):
    /// `.download`, or `.cancel` for another one nobody clicked for too soon. nil: it isn't one, decided as usual.
    /// `clicked`: you started it, with a click or a key, or it's Zigzag's own load.
    func decide(shouldDownload: Bool, clicked: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationActionPolicy? {
        if isMainFrame { mainFrameClicked = clicked } else if clicked { frameClickedAt = now }
        guard shouldDownload else { return nil }
        return mayDownload(clicked: clicked, now: now) ? .download : .cancel
    }

    /// Whether a response is shown, saved, or neither.
    func decide(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool, isMainFrame: Bool, now: Date = Date()) -> WKNavigationResponsePolicy {
        guard Self.downloads(mimeType: mimeType, contentDisposition: contentDisposition, canShowMIMEType: canShowMIMEType) else { return .allow }
        let frameClicked = frameClickedAt.map { now.timeIntervalSince($0) < Self.frameClickWindow } == true
        guard isMainFrame || frameClicked else { return .cancel }
        return mayDownload(clicked: isMainFrame ? mainFrameClicked : frameClicked, now: now) ? .download : .cancel
    }

    /// Whether a response is a file to save rather than a page to show.
    nonisolated static func downloads(mimeType: String?, contentDisposition: String?, canShowMIMEType: Bool) -> Bool {
        let mime = (mimeType ?? "").lowercased()
        let disposition = (contentDisposition ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // A web page is shown, always. WebKit can briefly say it can't show HTML (a response handed over by a
        // service worker, as YouTube's first load does), and a page saved as "youtube.com.html" is never right.
        let isWebPage = mime.isEmpty || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime)
        // Sent as an attachment: saved, a web page too when it names its file (a site's uploads served as text/html).
        let isAttachment = disposition.hasPrefix("attachment") && (!isWebPage || disposition.contains("filename"))
        return isAttachment || !(isWebPage || canShowMIMEType)
    }

    private func mayDownload(clicked: Bool, now: Date) -> Bool {
        if clicked { return true }
        if let last = lastScriptDownload, now.timeIntervalSince(last) < Self.scriptDownloadGap { return false }
        lastScriptDownload = now
        return true
    }
}
