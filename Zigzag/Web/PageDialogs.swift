import AppKit
import WebKit
import UniformTypeIdentifiers

/// Dialogs pages are allowed to ask for. Always sheets over the page that asked, never free-floating.
enum PageDialogs {
    private static func originText(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return origin.host.isEmpty ? "This page" : origin.host
    }

    /// Dialogs shown per page (web view and the address it's on), and pages whose dialogs were blocked.
    private static var shown: [ObjectIdentifier: (url: URL?, count: Int)] = [:]
    private static var blocked: [ObjectIdentifier: URL?] = [:]

    /// Asks in Zigzag's own sheet. A page whose dialogs were blocked gets its quiet default at once, until it
    /// loads something new.
    private static func ask(_ frame: WKFrameInfo, window: NSWindow?, message: String, fields: [PageDialogSheet.Field] = [],
                            showsCancel: Bool) async -> PageDialogSheet.Result {
        guard let window else { return .cancelled }
        let page = frame.webView.map(ObjectIdentifier.init)
        let url = frame.webView?.url
        if let page, let blockedURL = blocked[page] {
            if blockedURL == url { return .cancelled }
            blocked[page] = nil
        }
        var count = 1
        if let page {
            count = shown[page].map { $0.url == url ? $0.count + 1 : 1 } ?? 1
            shown[page] = (url, count)
        }
        let result = await PageDialogSheet.ask(in: window, title: "\(originText(frame)) says", message: message, fields: fields,
                                               showsCancel: showsCancel, offersBlock: count >= 2, page: frame.webView)
        if case .blocked = result, let page { blocked[page] = url }
        return result
    }

    static func alert(message: String, frame: WKFrameInfo, window: NSWindow?) async {
        _ = await ask(frame, window: window, message: message, showsCancel: false)
    }

    static func confirm(message: String, frame: WKFrameInfo, window: NSWindow?) async -> Bool {
        if case .confirmed = await ask(frame, window: window, message: message, showsCancel: true) { return true }
        return false
    }

    static func prompt(message: String, defaultText: String?, frame: WKFrameInfo, window: NSWindow?) async -> String? {
        let result = await ask(frame, window: window, message: message, fields: [.init(placeholder: "", value: defaultText ?? "")], showsCancel: true)
        if case .confirmed(let values) = result { return values.first ?? "" }
        return nil
    }

    static func openPanel(parameters: WKOpenPanelParameters, window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        // A page that asks for a folder gets a folder; one that asks for files gets files.
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        // What the page accepts ("image/*", ".pdf"), as Safari offers it: other files are greyed out. WebKit keeps the
        // list on its parameters without a public name; when it isn't there, or names nothing we know, any file goes.
        if !parameters.allowsDirectories {
            func strings(_ key: String) -> [String] {
                parameters.responds(to: NSSelectorFromString(key)) ? (parameters.value(forKey: key) as? [String]) ?? [] : []
            }
            let types = strings("_acceptedMIMETypes").compactMap { mime -> UTType? in
                mime.hasSuffix("/*") ? UTType(mime == "image/*" ? "public.image" : mime == "video/*" ? "public.movie" : mime == "audio/*" ? "public.audio" : "")
                    : UTType(mimeType: mime)
            } + strings("_acceptedFileExtensions").compactMap { UTType(filenameExtension: $0.hasPrefix(".") ? String($0.dropFirst()) : $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }
}

/// HTTP authentication (basic/digest) and client certificate prompts.
/// Sites whose certificate you chose to trust anyway, from the warning page. Only until Zigzag quits, as Safari does.
/// Kept per website data store, so a private window's choices stay in that window and go when it does.
@MainActor enum CertificateExceptions {
    private static let hosts = NSMapTable<WKWebsiteDataStore, NSMutableSet>.weakToStrongObjects()
    static func allow(_ host: String, in store: WKWebsiteDataStore) {
        let set = hosts.object(forKey: store) ?? NSMutableSet()
        set.add(host.lowercased())
        hosts.setObject(set, forKey: store)
    }
    static func allows(_ host: String, in store: WKWebsiteDataStore) -> Bool {
        hosts.object(forKey: store)?.contains(host.lowercased()) ?? false
    }

    /// The link the warning page's "Visit anyway" goes to; the tab catches it before it loads.
    static let scheme = "zigzag-proceed"
    /// Carries the nonce on that link, so a page can't make one up.
    private static let nonceItem = "zigzag-nonce"
    /// Made fresh each launch and written only into Zigzag's own warning page.
    static let nonce = UUID().uuidString

    /// The "Visit anyway" link for a page whose certificate failed.
    static func proceedLink(for url: URL, nonce: String) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        parts.scheme = scheme
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: nonceItem, value: nonce)]
        return parts.url
    }

    /// The page a "Visit anyway" link opens, or nil unless it carries this launch's nonce and is for the host the
    /// tab warned about.
    static func destination(of link: URL, warnedHost: String?, nonce: String) -> URL? {
        guard link.scheme == scheme, var parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty, host == warnedHost?.lowercased(),
              var items = parts.queryItems, items.last?.name == nonceItem, items.last?.value == nonce else { return nil }
        items.removeLast()
        parts.queryItems = items.isEmpty ? nil : items
        parts.scheme = "https"
        return parts.url
    }
}

enum AuthenticationPrompt {
    /// `store`: the asking web view's data store, whose certificate exceptions apply. `page`: the web view asking,
    /// whose tab the sign-in sheet stays with; without one it covers the window.
    static func respond(to challenge: URLAuthenticationChallenge, window: NSWindow?, store: WKWebsiteDataStore,
                        page: WKWebView? = nil) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        // A certificate you chose to trust on the warning page: accepted for this session.
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
           await CertificateExceptions.allows(challenge.protectionSpace.host, in: store) {
            return (.useCredential, URLCredential(trust: trust))
        }
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM else {
            return (.performDefaultHandling, nil)
        }
        if challenge.previousFailureCount == 0, let saved = URLCredentialStorage.shared.defaultCredential(for: challenge.protectionSpace) {
            return (.useCredential, saved)
        }
        guard let window else { return (.cancelAuthenticationChallenge, nil) }
        // Several loads asking for the same sign-in at once (a page and its images): one question, one answer for all.
        let space = challenge.protectionSpace
        let key = "\(ObjectIdentifier(store).hashValue)|\(space.host):\(space.port)|\(space.realm ?? "")"
        if challenge.previousFailureCount == 0, let asking = signingIn[key] { return await asking.value }
        let task = Task { @MainActor in await ask(challenge, window: window, page: page) }
        signingIn[key] = task
        let answer = await task.value
        if signingIn[key] == task { signingIn[key] = nil }
        return answer
    }

    @MainActor private static var signingIn: [String: Task<(URLSession.AuthChallengeDisposition, URLCredential?), Never>] = [:]

    @MainActor
    private static func ask(_ challenge: URLAuthenticationChallenge, window: NSWindow,
                            page: WKWebView?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let message = challenge.previousFailureCount > 0 ? "That name or password didn’t work. Try again." : "This site needs a name and password."
        let result = await PageDialogSheet.ask(in: window, title: "Sign in to \(challenge.protectionSpace.host)", message: message,
                                               fields: [.init(placeholder: "Username"), .init(placeholder: "Password", secure: true)],
                                               confirmTitle: "Sign In", showsCancel: true, offersBlock: false, page: page)
        guard case .confirmed(let values) = result, values.count == 2 else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: values[0], password: values[1], persistence: .forSession))
    }
}

/// A calm page shown in place of a load error. Reload tries the real URL again.
enum ErrorPage {
    /// A page whose process stopped twice in a row.
    static let crashDomain = "ZigzagPageStopped"

    /// A certificate failure, whose page offers "Visit this site anyway".
    static func offersProceed(_ error: NSError) -> Bool {
        [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
         NSURLErrorServerCertificateHasUnknownRoot].contains(error.code) && error.domain == NSURLErrorDomain
    }

    /// Web views whose next commit is an error page, so it isn't recorded as a visit (see `Tab.didCommit`).
    static let pending = NSHashTable<WKWebView>.weakObjects()

    /// True, once, when the page that just committed in `webView` is an error page.
    static func consume(_ webView: WKWebView) -> Bool {
        guard pending.contains(webView) else { return false }
        pending.remove(webView)
        return true
    }

    /// `canProceed` is false where a certificate can't be let through (a popup): the page explains, with no way past.
    static func show(error: NSError, url: URL?, in webView: WKWebView, canProceed: Bool = true) {
        guard let url else { return }
        pending.add(webView)
        let (title, message) = describe(error, url: url)
        // For a certificate you know is fine (your router, a dev server), a quiet way through, with the reason first.
        var proceed = ""
        if canProceed, offersProceed(error) {
            if let link = CertificateExceptions.proceedLink(for: url, nonce: CertificateExceptions.nonce) {
                proceed = """
                <details><summary>Show details</summary><p class="why">\(escape(certificateReason(error.code)))</p>
                <a class="anyway" href="\(escape(link.absoluteString))">Visit this site anyway</a></details>
                """
            }
        }
        // Zigzag's own page, in the shared design: the surface, type and button History and Settings use, under the
        // wordmark drawn faint, as History's empty page has it.
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(escape(url.host() ?? title))</title>
        <style>
        \(PageStyle.css(theme: Brand.Theme.for(webView)))
        html, body { height: 100%; }
        body { display: flex; align-items: center; justify-content: center; }
        main { max-width: var(--empty-width); padding: var(--space-8); text-align: center; }
        main > svg { width: var(--empty-mark); height: auto; color: var(--text); opacity: var(--empty-mark-opacity); display: block; margin: 0 auto var(--empty-gap); }
        h1 { font-size: var(--heading); font-weight: 600; margin: 0 0 var(--space-2); }
        p { margin: 0 0 var(--empty-action-gap); line-height: var(--space-5); color: var(--muted); }
        details { margin-top: var(--space-5); } summary { cursor: default; color: var(--muted); list-style: none; }
        summary::-webkit-details-marker { display: none; } summary:hover { color: var(--text); }
        .why { margin: var(--space-3) 0; text-align: left; } .anyway { color: var(--muted); }
        </style></head><body><main>
        \(WordmarkView.svg(class: "mark", label: nil))
        <h1>\(escape(title))</h1><p>\(escape(message))</p>
        \(url.scheme == "webkit-extension" ? "" : #"<button class="button prominent" onclick="location.reload()">Try Again</button>"#)
        \(proceed)
        \(error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost ? "<script>addEventListener('online', () => location.reload())</script>" : "")
        </main></body></html>
        """
        // WebKit won't show anything at an address of an extension it doesn't have, so that page has none.
        if url.scheme == "webkit-extension" {
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        }
    }

    /// The title and message for an error, in plain words. Never the system's own text, which reads like a log.
    static func describe(_ error: NSError, url: URL) -> (String, String) {
        let host = url.host() ?? url.absoluteString
        // An extension's own page, from an extension that's been removed or turned off.
        if url.scheme == "webkit-extension" {
            return ("This extension isn’t here", "The page belongs to an extension that has been removed or turned off. Turn it back on in Settings › Extensions, or close this tab.")
        }
        if error.domain == crashDomain {
            return ("This page keeps stopping", "It may need more memory than your Mac can spare right now. Close some tabs, then try again.")
        }
        // WebKit's own errors.
        if error.domain == "WebKitErrorDomain" {
            switch error.code {
            // A port browsers keep closed, because other services (like email) use it.
            case 103: return ("Zigzag won’t open this port", "\(host) is on a port kept for other things, like email, so browsers don’t open it.")
            case 101: return ("Zigzag can’t open this address", "Check the address for typos.")
            default: return generic
            }
        }
        guard error.domain == NSURLErrorDomain else { return generic }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return ("You’re offline", "Check your internet connection, then try again.")
        // Most often the internet is down, or the address has a typo; the site itself rarely vanishes.
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ("Can’t find \(host)", "Your Mac may not be connected to the internet, or the address may have a typo. Check both, then try again.")
        case NSURLErrorTimedOut:
            return ("\(host) took too long", "The site didn’t respond in time. Try again in a moment.")
        // The secure connection itself failed (reset, blocked by a network): nothing says the site is an impostor.
        case NSURLErrorSecureConnectionFailed:
            return ("Can’t connect securely to \(host)", "The secure connection was cut off, often by the network you’re on. Try again, or try another network.")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
            return ("This connection isn’t private", "\(host) can’t prove it is who it says it is, so Zigzag didn’t open it.")
        case NSURLErrorClientCertificateRequired, NSURLErrorClientCertificateRejected:
            return ("\(host) wants a certificate", "The site only opens for Macs with a certificate it trusts, often one from work or school.")
        case NSURLErrorCannotConnectToHost:
            return ("Can’t connect to \(host)", "The site may be down right now. Try again in a moment.")
        case NSURLErrorHTTPTooManyRedirects:
            return ("\(host) keeps sending you around", "It redirected the page in a loop. Clearing this site’s cookies often fixes it.")
        case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData,
             NSURLErrorCannotParseResponse:
            return ("\(host) sent a broken page", "Something went wrong on the site’s side. Try again in a moment.")
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return ("Zigzag can’t open this address", "Check the address for typos.")
        case NSURLErrorFileDoesNotExist:
            return ("This file isn’t there", "It may have been moved, renamed or deleted.")
        case NSURLErrorNoPermissionsToReadFile:
            return ("Zigzag can’t read this file", "Your Mac doesn’t let Zigzag open it.")
        case NSURLErrorResourceUnavailable:
            return ("This page isn’t available", "Try again in a moment.")
        default:
            return generic
        }
    }

    /// For anything not described above.
    private static let generic = ("Can’t open this page", "Something went wrong while loading it. Try again in a moment.")

    private static func certificateReason(_ code: Int) -> String {
        switch code {
        case NSURLErrorServerCertificateHasBadDate: "The site’s certificate has expired, or your Mac’s date and time are wrong."
        case NSURLErrorServerCertificateNotYetValid: "The site’s certificate isn’t valid yet. Check your Mac’s date and time."
        case NSURLErrorServerCertificateHasUnknownRoot: "The site’s certificate wasn’t issued by anyone your Mac trusts. Sites on your own network, like a router, often look like this."
        default: "The site’s certificate is for a different address, or can’t be trusted. Someone could be pretending to be this site."
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Recognizes search engine results pages so results can fold their search into back history.
enum SearchFolding {
    private static let engines: [(host: String, path: String, param: String)] = [
        ("google.", "/search", "q"),
        ("bing.com", "/search", "q"),
        ("duckduckgo.com", "/", "q"),
        ("kagi.com", "/search", "q"),
        ("ecosia.org", "/search", "q"),
        ("search.yahoo.com", "/search", "p"),
        ("search.brave.com", "/search", "q"),
        ("perplexity.ai", "/search", "q"),
    ]

    static func isSearchResultsPage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return engines.contains { engine in
            host.contains(engine.host) && url.path().hasPrefix(engine.path) && items.contains { $0.name == engine.param && !($0.value ?? "").isEmpty }
        }
    }

    /// Search engines route result clicks through redirects; a result is anything off the engine's host.
    static func isResultNavigation(from tabURL: URL?, to url: URL) -> Bool {
        guard let tabURL, isSearchResultsPage(tabURL) else { return false }
        return HistoryStore.normalizedHost(tabURL) != HistoryStore.normalizedHost(url)
    }
}
