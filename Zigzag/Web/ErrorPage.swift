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
    /// Why a certificate warning has no "Visit anyway", said where the link would be.
    enum NoWayPast: Equatable {
        /// The site asked to be reached only over a secure connection (HSTS).
        case strictTransport
        /// The warning came without the certificate it's about, so there's none to trust.
        case noCertificate

        var text: String {
            switch self {
            case .strictTransport:
                String(localized: "This site asks to be visited only over a secure connection, so it can’t be opened with this certificate.", comment: "Under Details on the page Zigzag shows for a site whose certificate can't be trusted, in place of Visit this site anyway, for a site that uses HSTS.")
            case .noCertificate:
                String(localized: "Zigzag couldn’t read the site’s certificate, so it can’t be trusted anyway.", comment: "Under Details on the page Zigzag shows for a site whose certificate can't be trusted, in place of Visit this site anyway, when the certificate couldn't be read.")
            }
        }
    }

    /// `noWayPast`: why a certificate warning has no "Visit anyway", said in its place.
    static func show(error: NSError, url: URL?, in webView: WKWebView, proceedNonce: String? = nil, noWayPast: NoWayPast? = nil) {
        guard let url else { return }
        let error = ClientCertificates.explain(error, url: url, store: webView.configuration.websiteDataStore)
        pending.add(webView)
        let kind = Self.kind(of: error, url: url)
        // For a certificate you know is fine (your router, a dev server), a quiet way through, with the reason first.
        let proceed = proceedNonce.flatMap { offersProceed(error) ? CertificateExceptions.proceedLink(for: url, nonce: $0) : nil }
        // Over a page that was showing, Back goes to it; on the same address (Try Again, a page that stopped), to
        // whatever was before it.
        let canGoBack = webView.url == nil ? false : webView.url == url ? webView.canGoBack : true
        let proxy = blamesProxy(kind, url: url) ? ProxyCheck.localProxy(for: url) : nil
        let nonce = UUID().uuidString
        let page = html(error: error, url: url, canGoBack: canGoBack, proceedLink: proceed, noWayPast: proceed == nil ? noWayPast : nil, proxy: proxy,
                        style: PageStyle.css(theme: Brand.Theme.for(webView)), nonce: nonce)
        if kind == .offline { OfflineRetry.wait(webView, for: url) } else { OfflineRetry.forget(webView) }
        // WebKit won't show anything at an address of an extension it doesn't have, so that page has none.
        if url.scheme == "webkit-extension" {
            webView.loadHTMLString(page, baseURL: nil)
        } else {
            webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: page)
        }
        if kind == .certificate { checkIssuer(of: error, url: url, page: nonce, in: webView) }
    }

    /// Checks the issuer off the main thread after the page shows (the system can be slow), and refills the reason
    /// only if it changes what Details says.
    private static func checkIssuer(of error: NSError, url: URL, page nonce: String, in webView: WKWebView) {
        guard let chain = certificateChain(of: error), let facts = certificateFacts(of: chain, checkingIssuer: false) else { return }
        var untrusted = facts
        untrusted.issuerTrusted = false
        let host = url.host(), code = error.code
        let reason = certificateProblem(code: code, facts: untrusted, host: host)
        guard reason != certificateProblem(code: code, facts: facts, host: host) else { return }
        Task { [weak webView] in
            let trusted = await Task.detached { issuerTrusted(chain, validFrom: facts.validFrom, validUntil: facts.validUntil) }.value
            guard trusted == false, let webView else { return }
            fillReason(certificateReason(reason), page: nonce, in: webView)
        }
    }

    /// Fills the reason once the page with `nonce` is showing; retries a few times, then gives up.
    private static func fillReason(_ text: String, page nonce: String, in webView: WKWebView, tries: Int = 30) {
        let source = "const r = document.getElementById('why'); if (!r || r.dataset.page !== page) return false; r.textContent = text; return true;"
        webView.callAsyncJavaScript(source, arguments: ["page": nonce, "text": text], in: nil, in: .page) { [weak webView] result in
            guard (try? result.get()) as? Bool != true, tries > 1, let webView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak webView] in
                guard let webView else { return }
                fillReason(text, page: nonce, in: webView, tries: tries - 1)
            }
        }
    }

    /// A response that's only a server error with nothing in it, as a proxy on this Mac sends for an address it
    /// can't reach: shown as a broken page rather than a blank one. A real error page from a site has a body, and
    /// is shown as the site sent it.
    static func emptyServerFailure(_ response: URLResponse) -> NSError? {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 500, http.expectedContentLength == 0 else { return nil }
        var info: [String: Any] = [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"]
        if let url = http.url { info[NSURLErrorFailingURLErrorKey] = url }
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: info)
    }

    // MARK: - What it says

    /// The kinds a proxy on this Mac would cause, for a site out on the web: the proxy answers for every address,
    /// so one it can't reach fails as a cut-off, an unanswered or a broken connection.
    static func blamesProxy(_ kind: Kind, url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !isOnThisMac(url) else { return false }
        return [.secureFailed, .refused, .timedOut, .broken].contains(kind)
    }

    /// Errors an https address gets from an http-only server, so http is tried next (`Tab.fallbackURL`): TLS failed
    /// or the port refused. Not certificate warnings (they have their own way past), and not timeouts, which take a
    /// minute and can be caused by anyone on the path; offline or not found won't work over http either.
    static func fallsBackToHTTP(_ kind: Kind) -> Bool {
        [.secureFailed, .refused].contains(kind)
    }

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
    /// never the site's name, which the page shows whole on a line of its own. `proxy`: the proxy on this Mac pages
    /// go through (host:port), which is then the likelier cause than the network or the site.
    static func describe(_ error: NSError, url: URL, proxy: String? = nil) -> (String, String) {
        let kind = Self.kind(of: error, url: url)
        if let proxy, blamesProxy(kind, url: url) {
            return (String(localized: "Can’t open this site", comment: "Title of the page Zigzag shows when a page can't load through a proxy on this Mac (like Clash)."),
                    String(localized: "Your Mac sends pages through a proxy (\(proxy)). The address may have a typo, or the proxy couldn’t reach the site. Check the address, or try again with the proxy off.", comment: "Message on the page Zigzag shows when a page can't load through a proxy on this Mac (like Clash). The placeholder is the proxy's address, like 127.0.0.1:7890."))
        }
        switch kind {
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
        // An address that starts with 127 is this Mac; a name that does (127.0.0.1.example.com) is looked up like any.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let loopback = parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || loopback
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

    /// Why WebKit rejected a certificate, for Details. WebKit uses one error code for most cases, so the certificate
    /// is inspected here (`certificateFacts`).
    enum CertificateProblem: Equatable {
        case expired(Date?)
        case notYetValid(Date?)
        /// The first name it was issued to.
        case wrongHost(String?)
        case selfSigned
        case untrustedIssuer
        case unknown
    }

    /// What the trust WebKit evaluated tells about the certificate.
    struct CertificateFacts: Equatable {
        var validFrom: Date?
        var validUntil: Date?
        /// DNS names, or the common name when there are none.
        var names: [String]
        /// IP addresses (a router's, issued to 192.168.1.1).
        var addresses: [String] = []
        var selfSigned: Bool
        /// Whether macOS trusts the issuing chain, ignoring dates and host; nil when unknown.
        var issuerTrusted: Bool?
    }

    /// From the certificate's facts, or WebKit's code alone when there are none. Host mismatch first (that's what
    /// impersonation looks like), then dates (expired cert or wrong clock), then the issuer.
    nonisolated static func certificateProblem(code: Int, facts: CertificateFacts?, host: String?, now: Date = Date()) -> CertificateProblem {
        if let facts {
            // Self-signed is reported first: anyone can make one for any name, so its name says nothing (a router's,
            // issued to router.local and reached by IP).
            if let host, !host.isEmpty, !facts.selfSigned, !certificate(facts, covers: host) {
                return .wrongHost(facts.names.first ?? facts.addresses.first)
            }
            if let until = facts.validUntil, until < now { return .expired(until) }
            if let from = facts.validFrom, from > now { return .notYetValid(from) }
            if facts.selfSigned { return .selfSigned }
            if facts.issuerTrusted == false { return .untrustedIssuer }
        }
        switch code {
        case NSURLErrorServerCertificateHasBadDate: return .expired(nil)
        case NSURLErrorServerCertificateNotYetValid: return .notYetValid(nil)
        case NSURLErrorServerCertificateHasUnknownRoot: return .untrustedIssuer
        default: return .unknown
        }
    }

    /// IP hosts match its IP addresses (or an IP common name), names match its names. A certificate naming nothing
    /// counts as covering.
    nonisolated static func certificate(_ facts: CertificateFacts, covers host: String) -> Bool {
        guard !facts.names.isEmpty || !facts.addresses.isEmpty else { return true }
        if let address = ipBytes(host) { return (facts.addresses + facts.names).contains { ipBytes($0) == address } }
        return !facts.names.isEmpty && certificateNames(facts.names, cover: host)
    }

    /// 4 or 16 bytes if the text is an IP address (IPv6 in brackets too).
    nonisolated static func ipBytes(_ text: String) -> [UInt8]? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Exact match, or a wildcard (`*.example.com`) covering exactly one label. Case-insensitive, trailing dot
    /// ignored.
    nonisolated static func certificateNames(_ names: [String], cover host: String) -> Bool {
        func clean(_ name: String) -> String {
            var name = name.lowercased().trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "[]")))
            if name.hasSuffix(".") { name.removeLast() }
            return name
        }
        let host = clean(host)
        return names.map(clean).contains { name in
            if name == host { return true }
            guard name.hasPrefix("*."), let dot = host.firstIndex(of: "."), dot != host.startIndex else { return false }
            let rest = String(host[host.index(after: dot)...])
            return rest == String(name.dropFirst(2)) && rest.contains(".")
        }
    }

    /// From the error's trust or chain. `checkingIssuer: false` skips the slow issuer check.
    static func certificateFacts(of error: NSError, checkingIssuer: Bool = true) -> CertificateFacts? {
        certificateChain(of: error).flatMap { certificateFacts(of: $0, checkingIssuer: checkingIssuer) }
    }

    /// Site's own certificate first.
    static func certificateChain(of error: NSError) -> [SecCertificate]? {
        let key = NSURLErrorFailingURLPeerTrustErrorKey
        let value = error.userInfo[key] ?? (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.userInfo[key]
        if let value, CFGetTypeID(value as CFTypeRef) == SecTrustGetTypeID(),
           let chain = SecTrustCopyCertificateChain(value as! SecTrust) as? [SecCertificate] {
            return chain
        }
        return error.userInfo["NSErrorPeerCertificateChainKey"] as? [SecCertificate]
    }

    /// Dates, names and issuer from the chain (site's first). Rechecks the issuer (`issuerTrusted`) unless
    /// `checkingIssuer` is false.
    nonisolated static func certificateFacts(of chain: [SecCertificate], checkingIssuer: Bool = true) -> CertificateFacts? {
        guard let leaf = chain.first else { return nil }
        let summary = CertificateDetails.summary(leaf)
        var names = CertificateDetails.dnsNames(of: leaf)
        if names.isEmpty, !summary.name.isEmpty, !summary.name.contains(" ") { names = [summary.name] }
        let trusted = checkingIssuer ? issuerTrusted(chain, validFrom: summary.validFrom, validUntil: summary.validUntil) : nil
        return CertificateFacts(validFrom: summary.validFrom, validUntil: summary.validUntil, names: names,
                                addresses: CertificateDetails.ipAddresses(of: leaf),
                                selfSigned: summary.isSelfSigned && chain.count == 1, issuerTrusted: trusted)
    }

    /// Local check only (nothing fetched), at a date the certificate was valid, so an expired one from a trusted
    /// authority still reads as trusted. Can block, so never on the main thread.
    nonisolated static func issuerTrusted(_ chain: [SecCertificate], validFrom: Date?, validUntil: Date?) -> Bool? {
        var check: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &check) == errSecSuccess, let check else { return nil }
        SecTrustSetNetworkFetchAllowed(check, false)
        if let from = validFrom, let until = validUntil, from < until {
            SecTrustSetVerifyDate(check, from.addingTimeInterval(until.timeIntervalSince(from) / 2) as CFDate)
        }
        return SecTrustEvaluateWithError(check, nil)
    }

    private static let certificateDates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    static func certificateReason(_ problem: CertificateProblem) -> String {
        switch problem {
        case .expired(let date?):
            String(localized: "The site’s certificate expired on \(certificateDates.string(from: date)). The site may not have renewed it, or your Mac’s date and time are wrong.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it. The placeholder is the day it expired, like November 14, 2026.")
        case .expired(nil):
            String(localized: "The site’s certificate has expired, or your Mac’s date and time are wrong.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case .notYetValid(let date?):
            String(localized: "The site’s certificate isn’t valid until \(certificateDates.string(from: date)). Check your Mac’s date and time.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it. The placeholder is the first day it's valid, like November 14, 2026.")
        case .notYetValid(nil):
            String(localized: "The site’s certificate isn’t valid yet. Check your Mac’s date and time.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case .wrongHost(let name?):
            String(localized: "The site’s certificate is for a different address, \(name). Someone could be pretending to be this site.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it. The placeholder is the address the certificate is for, like *.example.com.")
        case .wrongHost(nil):
            String(localized: "The site’s certificate is for a different address. Someone could be pretending to be this site.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case .selfSigned:
            String(localized: "The site signed its certificate itself, so nobody your Mac trusts vouches for it. Sites on your own network, like a router, often look like this.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it: it's self-signed.")
        case .untrustedIssuer:
            String(localized: "The site’s certificate wasn’t issued by anyone your Mac trusts. Sites on your own network, like a router, often look like this.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it.")
        case .unknown:
            String(localized: "The site’s certificate can’t be trusted. Someone could be pretending to be this site.", comment: "Why a site's certificate can't be trusted, under Show details on the page Zigzag shows for it, when it isn't known why.")
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
    static func html(error: NSError, url: URL, canGoBack: Bool, proceedLink: URL?, noWayPast: NoWayPast? = nil, proxy: String? = nil,
                     style: String, nonce: String) -> String {
        let kind = Self.kind(of: error, url: url)
        let (title, message) = describe(error, url: url, proxy: proxy)
        let site = siteName(for: url)
        let actions = Self.actions(for: kind, canGoBack: canGoBack)
        let buttons = actions.enumerated().map { i, action in
            #"<button class="button\#(i == 0 ? " prominent" : "")" data-action="\#(name(of: action))">\#(escape(self.title(of: action)))</button>"#
        }.joined()
        let noWay = kind == .certificate && proceedLink == nil ? noWayPast.map { #"<p class="why">\#(escape($0.text))</p>"# } ?? "" : ""
        // The issuer is checked later (`checkIssuer`) so the page doesn't wait.
        let problem = kind == .certificate ? certificateProblem(code: error.code, facts: certificateFacts(of: error, checkingIssuer: false), host: url.host()) : nil
        let reason = problem.map { #"<p class="why" id="why" data-page="\#(escape(nonce))">\#(escape(certificateReason($0)))</p>"# + noWay } ?? ""
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
