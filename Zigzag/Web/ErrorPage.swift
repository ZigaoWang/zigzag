import Network
import WebKit

/// Zigzag's own page in place of one that didn't load: a quiet drawing for the kind of problem, what happened in
/// plain words, the site's name whole on its own line, then what you can do about it. The error itself waits under
/// Details for whoever needs it. Try Again (Return) loads the real address again.
enum ErrorPage {
    /// A page whose process stopped twice in a row.
    static let crashDomain = "ZigzagPageStopped"

    /// The kinds of problem, each with its own drawing, words and actions.
    enum Kind: CaseIterable {
        case offline, notFound, refused, timedOut, secureFailed, certificate, clientCertificate, redirects, broken
        case badAddress, port, blocked, filtered, missingFile, unreadableFile, unavailable, extensionGone, stopped, other
    }

    /// What the page's buttons do; the first is the primary, and Return presses it.
    enum Action: Equatable { case tryAgain, reload, goBack }

    /// A certificate failure, whose page offers "Visit this site anyway".
    static func offersProceed(_ error: NSError) -> Bool {
        [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
         NSURLErrorServerCertificateHasUnknownRoot].contains(error.code) && error.domain == NSURLErrorDomain
    }

    /// Web views whose next commit is an error page, so it isn't recorded as a visit (see `Tab.didCommit`).
    static let pending = NSHashTable<WKWebView>.weakObjects()

    /// True, once, when the page that just committed in `webView` is an error page.
    static func consume(_ webView: WKWebView) -> Bool {
        guard pending.contains(webView) else {
            // Something else came: the offline page it showed is gone.
            OfflineRetry.forget(webView)
            return false
        }
        pending.remove(webView)
        return true
    }

    /// `proceedNonce`: the nonce for this warning's "Visit anyway" link. Without one (a popup, where a certificate
    /// can't be let through) the page explains, with no way past.
    static func show(error: NSError, url: URL?, in webView: WKWebView, proceedNonce: String? = nil) {
        guard let url else { return }
        pending.add(webView)
        let kind = Self.kind(of: error, url: url)
        // For a certificate you know is fine (your router, a dev server), a quiet way through, with the reason first.
        let proceed = proceedNonce.flatMap { offersProceed(error) ? CertificateExceptions.proceedLink(for: url, nonce: $0) : nil }
        // Over a page that was showing, Back goes to it; on the same address (Try Again, a page that stopped), to
        // whatever was before it.
        let canGoBack = webView.url == nil ? false : webView.url == url ? webView.canGoBack : true
        let page = html(error: error, url: url, canGoBack: canGoBack, proceedLink: proceed,
                        style: PageStyle.css(theme: Brand.Theme.for(webView)), nonce: UUID().uuidString)
        if kind == .offline { OfflineRetry.wait(webView, for: url) } else { OfflineRetry.forget(webView) }
        // WebKit won't show anything at an address of an extension it doesn't have, so that page has none.
        if url.scheme == "webkit-extension" {
            webView.loadHTMLString(page, baseURL: nil)
        } else {
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: page)
        }
    }

    // MARK: - What it says

    static func kind(of error: NSError, url: URL) -> Kind {
        // An extension's own page, from an extension that's been removed or turned off.
        if url.scheme == "webkit-extension" { return .extensionGone }
        if error.domain == crashDomain { return .stopped }
        // WebKit's own errors.
        if error.domain == "WebKitErrorDomain" {
            switch error.code {
            // A port browsers keep closed, because other services (like email) use it.
            case 103: return .port
            case 101: return .badAddress
            case 104: return .blocked
            case 105: return .filtered
            default: return .other
            }
        }
        guard error.domain == NSURLErrorDomain else { return .other }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .notFound
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorSecureConnectionFailed: return .secureFailed
        case _ where offersProceed(error): return .certificate
        case NSURLErrorClientCertificateRequired, NSURLErrorClientCertificateRejected: return .clientCertificate
        case NSURLErrorCannotConnectToHost: return .refused
        case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return .redirects
        case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData,
             NSURLErrorCannotParseResponse:
            return .broken
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return .badAddress
        case NSURLErrorFileDoesNotExist: return .missingFile
        case NSURLErrorNoPermissionsToReadFile: return .unreadableFile
        case NSURLErrorResourceUnavailable: return .unavailable
        default: return .other
        }
    }

    /// The buttons, primary first. Back is there only when there's somewhere to go back to; it leads on a certificate
    /// warning, where going back is the safe choice. Where trying again can't help (a closed port, a gone
    /// extension), there's no Try Again.
    static func actions(for kind: Kind, canGoBack: Bool) -> [Action] {
        let back: [Action] = canGoBack ? [.goBack] : []
        switch kind {
        case .stopped: return [.reload] + back
        case .certificate: return back + [.tryAgain]
        case .port, .badAddress, .filtered, .extensionGone: return back
        default: return [.tryAgain] + back
        }
    }

    /// The title and message for an error, in plain words. Never the system's own text, which reads like a log, and
    /// never the site's name, which the page shows whole on a line of its own.
    static func describe(_ error: NSError, url: URL) -> (String, String) {
        switch Self.kind(of: error, url: url) {
        case .offline:
            return (String(localized: "You’re offline", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Check your Wi-Fi or network connection. Zigzag tries again by itself once you’re back online.", comment: "Message on the page Zigzag shows when a page can't load because the Mac is offline."))
        // Most often the internet is down, or the address has a typo; the site itself rarely vanishes.
        case .notFound:
            return (String(localized: "Can’t find this site", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The address may have a typo, or your Mac may not be connected to the internet. Check both, then try again.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .refused where isOnThisMac(url):
            return (String(localized: "Nothing’s answering at this address", comment: "Title of the page Zigzag shows when a server on this Mac (localhost) refuses the connection."),
                    String(localized: "If it’s a server on your Mac, check that it’s running, then try again.", comment: "Message on the page Zigzag shows when a server on this Mac (localhost) refuses the connection."))
        case .refused:
            return (String(localized: "Can’t connect to this site", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The site may be down right now. Try again in a moment.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .timedOut:
            return (String(localized: "This site took too long to answer", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "It may be busy or down right now. Try again in a moment.", comment: "Message on the page Zigzag shows when a page can't load."))
        // The secure connection itself failed (reset, blocked by a network): nothing says the site is an impostor.
        case .secureFailed:
            return (String(localized: "Can’t connect securely", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The secure connection was cut off, often by the network you’re on. Try again, or try another network.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .certificate:
            return (String(localized: "This connection isn’t private", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "This site can’t prove it is who it says it is, so Zigzag didn’t open it. Someone could be pretending to be it to see what you send.", comment: "Message on the page Zigzag shows for a site whose certificate can't be trusted."))
        case .clientCertificate:
            return (String(localized: "This site wants a certificate", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The site only opens for Macs with a certificate it trusts, often one from work or school.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .redirects:
            return (String(localized: "This page keeps redirecting", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "It sends Zigzag around in a loop. Clearing this site’s cookies often fixes it.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .broken:
            return (String(localized: "This site sent a broken page", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Something went wrong on the site’s side. Try again in a moment.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .badAddress:
            return (String(localized: "Zigzag can’t open this address", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Check the address for typos.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .port:
            return (String(localized: "Zigzag won’t open this port", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The address uses a port kept for other things, like email, so browsers don’t open it.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .blocked:
            return (String(localized: "A blocker stopped this page", comment: "Title of the page Zigzag shows when a content blocker kept a page from loading."),
                    String(localized: "A content blocker doesn’t let this page load. If you trust the site, allow it in the blocker, then try again.", comment: "Message on the page Zigzag shows when a content blocker kept a page from loading."))
        case .filtered:
            return (String(localized: "This site is blocked on this Mac", comment: "Title of the page Zigzag shows when Screen Time or a content filter blocks a site."),
                    String(localized: "Screen Time or a content filter on this Mac doesn’t allow it.", comment: "Message on the page Zigzag shows when Screen Time or a content filter blocks a site."))
        case .missingFile:
            return (String(localized: "This file isn’t there", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "It may have been moved, renamed or deleted.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .unreadableFile:
            return (String(localized: "Zigzag can’t read this file", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Your Mac doesn’t let Zigzag open it.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .unavailable:
            return (String(localized: "This page isn’t available", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Try again in a moment.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .extensionGone:
            return (String(localized: "This extension isn’t here", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "The page belongs to an extension that has been removed or turned off. Turn it back on in Settings › Extensions, or close this tab.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .stopped:
            return (String(localized: "This page keeps stopping", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "It may need more memory than your Mac can spare right now. Close some tabs, then try again.", comment: "Message on the page Zigzag shows when a page can't load."))
        case .other:
            return (String(localized: "Can’t open this page", comment: "Title of the page Zigzag shows when a page can't load."),
                    String(localized: "Something went wrong while loading it. Try again in a moment.", comment: "Message on the page Zigzag shows when a page can't load."))
        }
    }

    /// An address on this Mac (a dev server), where "the site may be down" would be the wrong guess.
    static func isOnThisMac(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    /// The site as the page names it: the host with its port, a file's name, or nothing for an extension's page.
    /// Never broken across lines; one too long for the column loses its middle, keeping the end that says whose it is.
    static func siteName(for url: URL, limit: Int = 56) -> String? {
        var name: String
        if url.isFileURL {
            name = url.lastPathComponent
        } else if url.scheme == "webkit-extension" {
            return nil
        } else if let host = url.host(), !host.isEmpty {
            name = host.contains(":") ? "[\(host)]" : host
            if let port = url.port { name += ":\(port)" }
        } else {
            name = url.absoluteString
        }
        guard name.count > limit else { return name.isEmpty ? nil : name }
        let tail = limit * 3 / 5, head = limit - tail - 1
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }

    private static func title(of action: Action) -> String {
        switch action {
        case .tryAgain: String(localized: "Try Again", comment: "Button on the page Zigzag shows when a page can't load.")
        case .reload: String(localized: "Reload Page", comment: "Button on the page Zigzag shows when a page keeps stopping.")
        case .goBack: String(localized: "Go Back", comment: "Button on the page Zigzag shows when a page can't load: back to the page before.")
        }
    }

    private static func certificateReason(_ code: Int) -> String {
        switch code {
        case NSURLErrorServerCertificateHasBadDate: String(localized: "The site’s certificate has expired, or your Mac’s date and time are wrong.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case NSURLErrorServerCertificateNotYetValid: String(localized: "The site’s certificate isn’t valid yet. Check your Mac’s date and time.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case NSURLErrorServerCertificateHasUnknownRoot: String(localized: "The site’s certificate wasn’t issued by anyone your Mac trusts. Sites on your own network, like a router, often look like this.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        default: String(localized: "The site’s certificate is for a different address, or can’t be trusted. Someone could be pretending to be this site.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        }
    }

    /// The error as the system reports it, for whoever needs it: its own words, its domain and code, the address.
    static func technical(_ error: NSError, url: URL) -> String {
        var lines: [String] = []
        if error.domain != crashDomain, !error.localizedDescription.isEmpty { lines.append(error.localizedDescription) }
        lines.append("\(error.domain) \(error.code)")
        lines.append(url.absoluteString)
        return lines.joined(separator: "\n")
    }

    // MARK: - The page

    /// The whole page, everything on it escaped, its one script allowed by `nonce` and nothing loaded from anywhere.
    static func html(error: NSError, url: URL, canGoBack: Bool, proceedLink: URL?, style: String, nonce: String) -> String {
        let kind = Self.kind(of: error, url: url)
        let (title, message) = describe(error, url: url)
        let site = siteName(for: url)
        let actions = Self.actions(for: kind, canGoBack: canGoBack)
        let buttons = actions.enumerated().map { i, action in
            #"<button class="button\#(i == 0 ? " prominent" : "")" data-action="\#(name(of: action))">\#(escape(self.title(of: action)))</button>"#
        }.joined()
        let reason = kind == .certificate ? #"<p class="why">\#(escape(certificateReason(error.code)))</p>"# : ""
        let anyway = proceedLink.map {
            #"<a class="anyway" href="\#(escape($0.absoluteString))">\#(escape(String(localized: "Visit this site anyway", comment: "Link on the page Zigzag shows for a site whose certificate can't be trusted, under Show details.")))</a>"#
        } ?? ""
        let details = String(localized: "Details", comment: "Disclosure on the page Zigzag shows when a page can't load: the error as the system reports it.")
        let copy = String(localized: "Copy", comment: "Button under Details on the page Zigzag shows when a page can't load: copies the error.")
        let copied = String(localized: "Copied", comment: "The Copy button under Details on an error page, once it has copied the error.")
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return """
        <!doctype html><html lang="\(escape(language))"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-\(escape(nonce))'; img-src data:; base-uri 'none'; form-action 'none'">
        <title>\(escape(site ?? title))</title>
        <style>
        \(style)
        \(css)
        </style></head><body>
        <div class="stage"><main>
        \(symbol(for: kind))
        <h1>\(escape(title))</h1>
        \(site.map { #"<p class="site" title="\#(escape(url.host() ?? $0))">\#(escape($0))</p>"# } ?? "")
        <p class="message">\(escape(message))</p>
        \(buttons.isEmpty ? "" : #"<div class="actions">\#(buttons)</div>"#)
        <details><summary>\(chevron)\(escape(details))</summary><div class="more">\(reason)
        <div class="technical" id="technical">\(escape(technical(error, url: url)))</div>
        <div class="more-actions"><button class="button quiet" id="copy" data-done="\(escape(copied))">\(escape(copy))</button>\(anyway)</div>
        </div></details>
        </main></div>
        <footer>\(WordmarkView.svg(class: "mark", label: nil))</footer>
        <script nonce="\(escape(nonce))">\(script)</script>
        </body></html>
        """
    }

    private static func name(of action: Action) -> String {
        switch action {
        case .tryAgain: "try-again"
        case .reload: "reload"
        case .goBack: "go-back"
        }
    }

    /// The page's own rules, after `PageStyle`'s: one column a little above the middle, left-aligned, the wordmark
    /// signing it at the foot.
    private static let css = """
    html, body { min-height: 100%; }
    body { display: flex; flex-direction: column; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }
    .stage { flex: 1; display: flex; align-items: center; justify-content: center; padding: var(--space-8) var(--gutter) 0; }
    main { width: 100%; max-width: 480px; margin-bottom: 10vh; }
    .symbol { display: block; width: 36px; height: 36px; color: var(--icon); margin: 0 0 var(--space-5) -2px; }
    .symbol.warning { color: var(--destructive); }
    h1 { font-size: 26px; font-weight: 300; letter-spacing: -0.023em; line-height: 1.2; margin: 0; text-wrap: balance; }
    .site { margin: var(--space-2) 0 0; font-size: var(--row-text); font-weight: 500; color: var(--text);
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .message { margin: var(--space-3) 0 0; font-size: var(--row-text); line-height: 21px; color: var(--muted); text-wrap: pretty; }
    .actions { display: flex; flex-wrap: wrap; gap: var(--space-2); margin-top: var(--space-6); }
    details { margin-top: var(--space-6); }
    summary { display: inline-flex; align-items: center; gap: 6px; color: var(--muted); list-style: none; border-radius: var(--radius-small); }
    summary::-webkit-details-marker { display: none; }
    summary:hover { color: var(--text); }
    summary svg { width: 10px; height: 10px; flex: none; }
    details[open] summary svg { transform: rotate(90deg); }
    .more { margin-top: var(--space-3); }
    .why { margin: 0 0 var(--space-3); line-height: 20px; color: var(--muted); }
    .technical { padding: var(--space-3) var(--space-4); border-radius: var(--radius-field); background: var(--group); box-shadow: inset 0 0 0 1px var(--group-edge);
                 font-size: var(--label); line-height: 18px; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere;
                 -webkit-user-select: text; cursor: text; }
    .more-actions { display: flex; align-items: center; gap: var(--space-3); margin-top: var(--space-2); margin-left: calc(-1 * var(--space-3)); }
    .anyway { color: var(--muted); text-decoration: underline; text-decoration-color: var(--line); text-underline-offset: 3px; cursor: pointer; }
    .anyway:hover { color: var(--text); text-decoration-color: currentColor; }
    footer { display: flex; justify-content: center; padding: var(--space-6) 0 var(--space-8); color: var(--faint); }
    footer svg { width: 64px; height: auto; display: block; }
    @media (max-height: 420px) { footer { display: none; } }
    """

    /// Return presses the primary button, unless something else has the keyboard (Details, another button).
    private static let script = """
    const go = { 'try-again': () => location.reload(), 'reload': () => location.reload(), 'go-back': () => history.back() };
    document.querySelectorAll('[data-action]').forEach(b => b.addEventListener('click', () => go[b.dataset.action]()));
    addEventListener('keydown', e => {
      if (e.key !== 'Enter' || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
      const at = document.activeElement;
      if (at && at !== document.body) return;
      const primary = document.querySelector('[data-action]');
      if (primary) { e.preventDefault(); primary.click(); }
    });
    const copy = document.getElementById('copy');
    copy.addEventListener('click', () => {
      const range = document.createRange(), selection = getSelection();
      range.selectNodeContents(document.getElementById('technical'));
      selection.removeAllRanges(); selection.addRange(range);
      document.execCommand('copy');
      selection.removeAllRanges();
      copy.textContent = copy.dataset.done;
    });
    """

    private static let chevron = #"<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3.5 2l3 3-3 3"/></svg>"#

    /// One line drawing per kind, in Zigzag's line style (`LineGlyph`): one thin stroke, round caps and joins, on a
    /// 32 square with a 3 margin.
    static func symbol(for kind: Kind) -> String {
        let dot = { (x: Double, y: Double) in #"<circle cx="\#(x)" cy="\#(y)" r="1.1" fill="currentColor" stroke="none"/>"# }
        let page = #"<path d="M9 4.5h9.5L24 10v17.5H9z"/><path d="M18.5 4.5V10H24"/>"#
        let question = { (x: Double, y: Double) in
            #"<path d="M\#(x - 2.4) \#(y - 2.6)a2.4 2.4 0 1 1 3.4 2.2c-.6.3-1 .8-1 1.5v.5"/>"# + dot(x, y + 3.6)
        }
        let lock = #"<rect x="8" y="14" width="16" height="12" rx="2.5"/><path d="M11.5 14v-3.5a4.5 4.5 0 0 1 9 0V14"/>"#
        let barred = #"<circle cx="16" cy="16" r="11.5"/><path d="M7.9 7.9l16.2 16.2"/>"#
        let notice = #"<circle cx="16" cy="16" r="11.5"/><path d="M16 10v7"/>"# + dot(16, 21.5)
        let drawing: String
        switch kind {
        case .offline:
            drawing = #"<path d="M4.5 13.2a16.5 16.5 0 0 1 23 0"/><path d="M8.6 17.3a10.6 10.6 0 0 1 14.8 0"/><path d="M12.7 21.4a4.8 4.8 0 0 1 6.6 0"/>"#
                + dot(16, 25) + #"<path d="M6 5l20 21"/>"#
        case .notFound: drawing = #"<circle cx="14" cy="14" r="9"/><path d="M20.5 20.5l7 7"/>"# + question(14, 13)
        case .refused:
            drawing = #"<rect x="5" y="5.5" width="22" height="9" rx="2.5"/><rect x="5" y="17.5" width="22" height="9" rx="2.5"/>"#
                + dot(9.5, 10) + dot(9.5, 22)
        case .timedOut: drawing = #"<circle cx="16" cy="16" r="11.5"/><path d="M16 9.5V16l4.5 3"/>"#
        case .secureFailed: drawing = lock + #"<path d="M5 5l22 22"/>"#
        case .certificate: drawing = #"<path d="M16 3.5l10 3.8v7.4c0 6.3-4.1 10.8-10 13-5.9-2.2-10-6.7-10-13V7.3z"/><path d="M16 10v7"/>"# + dot(16, 21.3)
        case .clientCertificate:
            drawing = #"<rect x="4" y="7.5" width="24" height="17" rx="2.5"/><circle cx="11" cy="14" r="2.6"/><path d="M7.2 20.5c.7-1.7 2.1-2.5 3.8-2.5s3.1.8 3.8 2.5M18.5 13h5.5M18.5 17.5h4"/>"#
        case .redirects:
            drawing = #"<path d="M25.5 13.5a10 10 0 0 0-18.3-3"/><path d="M6.5 4.8v5.7h5.7"/><path d="M6.5 18.5a10 10 0 0 0 18.3 3"/><path d="M25.5 27.2v-5.7h-5.7"/>"#
        case .broken: drawing = page + #"<path d="M9 19.5l3-2.5 3 2.5 3-2.5 3 2.5 3-2.5"/>"#
        case .missingFile: drawing = page + question(16.5, 16.5)
        case .unreadableFile: drawing = lock
        case .port, .blocked, .filtered: drawing = barred
        case .extensionGone: drawing = #"<path d="M6.5 11.5h5.2a3 3 0 1 1 6 0h5.2v5.2a3 3 0 1 1 0 6v5.3H6.5z"/>"#
        case .stopped:
            drawing = #"<rect x="4" y="6" width="24" height="20" rx="3"/><path d="M4 11h24"/><path d="M17.5 13.5l-3.5 4.5h4l-3.5 5"/>"#
        case .badAddress, .unavailable, .other: drawing = notice
        }
        return #"<svg class="symbol\#(kind == .certificate ? " warning" : "")" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">\#(drawing)</svg>"#
    }

    /// Safe anywhere in the page: in text and in a quoted attribute.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// A page that didn't load because the Mac was offline loads again by itself once the network is back, as Chrome's
/// does: one watch on the network while any such page is showing, and none otherwise.
@MainActor
enum OfflineRetry {
    /// Each web view showing the offline page, and the address it's for.
    private static let waiting = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()
    private static var monitor: NWPathMonitor?
    private static var gate = Gate()

    /// Tells coming back online from having been online all along: the watch's first word only says how things
    /// are, so a page that failed while the Mac looked connected isn't reloaded in a loop.
    struct Gate {
        private var wasOffline = false

        /// True when this is the network coming back.
        mutating func note(online: Bool) -> Bool {
            if !online { wasOffline = true; return false }
            defer { wasOffline = false }
            return wasOffline
        }
    }

    static func wait(_ webView: WKWebView, for url: URL) {
        waiting.setObject(url as NSURL, forKey: webView)
        guard monitor == nil else { return }
        gate = Gate()
        let watch = NWPathMonitor()
        watch.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in noted(online: online) }
        }
        watch.start(queue: .main)
        monitor = watch
    }

    static func forget(_ webView: WKWebView) {
        guard waiting.object(forKey: webView) != nil else { return }
        waiting.removeObject(forKey: webView)
        stopIfIdle()
    }

    private static func noted(online: Bool) {
        guard gate.note(online: online) else { return }
        let pages = (waiting.keyEnumerator().allObjects as? [WKWebView]) ?? []
        for webView in pages {
            let url = waiting.object(forKey: webView) as URL?
            waiting.removeObject(forKey: webView)
            // Still on that offline page: anywhere else, it's been left.
            guard let url, webView.url == url, !webView.isLoading else { continue }
            webView.reload()
        }
        stopIfIdle()
    }

    private static func stopIfIdle() {
        guard waiting.count == 0 else { return }
        monitor?.cancel()
        monitor = nil
    }
}
