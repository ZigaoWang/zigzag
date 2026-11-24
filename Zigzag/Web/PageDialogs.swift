import AppKit
import WebKit
import UniformTypeIdentifiers

/// Dialogs pages are allowed to ask for. Always sheets over the page that asked, never free-floating.
enum PageDialogs {
    private static func originText(_ frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        return origin.host.isEmpty ? String(localized: "This page", comment: "Stands for the site in a page's JavaScript dialog when the page has no host, as in “This page says”.") : origin.host
    }

    /// Dialogs shown per page (web view and the address it's on), and pages whose dialogs were blocked.
    private static var shown: [ObjectIdentifier: (url: URL?, count: Int)] = [:]
    private static var blocked: [ObjectIdentifier: Bool] = [:]

    /// A page loaded (a reload included): its count and any block are forgotten, as in Safari.
    static func pageLoaded(_ webView: WKWebView) {
        shown[ObjectIdentifier(webView)] = nil
        blocked[ObjectIdentifier(webView)] = nil
    }

    /// Asks in Zigzag's own sheet. A page whose dialogs were blocked gets its quiet default at once, until it
    /// loads again.
    private static func ask(_ frame: WKFrameInfo, window: NSWindow?, message: String, fields: [PageDialogSheet.Field] = [],
                            showsCancel: Bool) async -> PageDialogSheet.Result {
        guard let window else { return .cancelled }
        let page = frame.webView.map(ObjectIdentifier.init)
        let url = frame.webView?.url
        if let page, blocked[page] != nil { return .cancelled }
        var count = 1
        if let page {
            count = shown[page].map { $0.url == url ? $0.count + 1 : 1 } ?? 1
            shown[page] = (url, count)
        }
        let result = await PageDialogSheet.ask(in: window, title: String(localized: "\(originText(frame)) says", comment: "Title of a page's JavaScript alert, confirm or prompt sheet. The placeholder is the site's host name, or “This page”."), message: message, fields: fields,
                                               showsCancel: showsCancel, offersBlock: count >= 2, page: frame.webView)
        if case .blocked = result, let page { blocked[page] = true }
        if case .blocked = result {
            Diagnostics.note("Page’s dialogs blocked", site: frame.webView?.url?.host(), isPrivate: frame.webView?.configuration.websiteDataStore.isPersistent == false)
        }
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
/// Sites whose certificate you chose to trust anyway, from the warning page. A choice for a local server (a NAS, a
/// container on this Mac's network) is remembered in Settings › Developer until its certificate changes or you remove
/// it. Every other choice lasts until Zigzag quits, as Safari's do, and never longer than `lifetime`, as Chrome's.
/// Kept per website data store, so a private window's choices stay in that window and go when it does.
@MainActor enum CertificateExceptions {
    /// How long a choice lasts at most, if Zigzag is left open that long.
    static let lifetime: TimeInterval = 24 * 60 * 60

    /// A remembered choice changed: Settings › Developer's list follows.
    static let changed = Signal<Void>()

    /// Where remembered local certificates are kept; tests use their own.
    static var defaults: UserDefaults = .standard

    /// The one certificate a host may show, and until when.
    private final class Exception {
        let leaf: Data
        let until: Date
        init(leaf: Data, until: Date) { self.leaf = leaf; self.until = until }
    }

    /// Per data store, each host's trusted certificate, as Safari keeps it: the one you were warned about and
    /// chose to trust, not whatever that host shows next.
    private static let trusted = NSMapTable<WKWebsiteDataStore, NSMutableDictionary>.weakToStrongObjects()

    /// Local servers whose certificate you chose to trust for good, by host and port, as base64. A private window
    /// never reads or writes them, so its choices still go with it. One list for the whole app: Chromium and Firefox
    /// keep their exceptions per profile. A future PR can store these per profile, with the profile named on each row,
    /// if that isolation is wanted.
    private static let rememberedKey = "TrustedCertificates"

    /// A local server whose certificate is trusted across launches: one web address, not one host with every port.
    struct RememberedSite: Equatable {
        let host: String
        let port: Int
        var name: String { CertificateExceptions.name(host: host, port: port) }
    }

    private static func key(host: String, port: Int) -> String { "\(host.lowercased())|\(port)" }

    private static func host(of key: String) -> String? {
        key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// How a remembered server is named in Settings › Developer, as a page's address names it.
    static func name(host: String, port: Int) -> String {
        let host = host.lowercased()
        return (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }

    private static var remembered: [String: String] {
        get { defaults.dictionary(forKey: rememberedKey)?.compactMapValues { $0 as? String } ?? [:] }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: rememberedKey) }
            else { defaults.set(newValue, forKey: rememberedKey) }
        }
    }

    /// The local servers whose certificate is trusted across launches, as Settings › Developer lists them.
    static var rememberedSites: [RememberedSite] {
        remembered.keys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let port = Int(parts[1]) else { return nil }
            return RememberedSite(host: String(parts[0]), port: port)
        }.sorted { $0.name < $1.name }
    }

    /// Whether a choice for `host` in `store` should outlast this launch: only a local server, where a certificate
    /// of its own is the norm, and never a private window.
    static func mayRemember(host: String, in store: WKWebsiteDataStore) -> Bool {
        guard store.isPersistent else { return false }
        var parts = URLComponents()
        parts.scheme = "https"
        // An address with colons goes in brackets, as it does in a page's address.
        parts.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = parts.url else { return false }
        return ErrorPage.isOnThisMac(url) || IconAddress.isLocal(url)
    }

    /// Forgets one remembered certificate, in every window. The site's warning comes back the next time it loads.
    static func forgetRemembered(_ site: RememberedSite) { forgetRemembered(host: site.host, port: site.port) }

    static func forgetRemembered(host: String, port: Int) {
        var kept = remembered
        let had = kept.removeValue(forKey: key(host: host, port: port)) != nil
        if had { remembered = kept }
        forgetSession(host: host, port: port)
        if had { changed.send() }
    }

    /// Whether `host` is `site` or covered by it, as site data's names cover subdomains and a parent domain.
    private static func covered(_ host: String, by site: String) -> Bool {
        host == site || host.hasSuffix("." + site) || site.hasSuffix("." + host)
    }

    private static func remember(_ host: String, port: Int, certificate: Data) {
        var kept = remembered
        kept[key(host: host, port: port)] = certificate.base64EncodedString()
        remembered = kept
        changed.send()
    }

    private static func rememberedCertificate(for host: String, port: Int) -> Data? {
        remembered[key(host: host, port: port)].flatMap { Data(base64Encoded: $0) }
    }

    private static func forgetSession(site: String?) {
        guard let site else {
            trusted.removeAllObjects()
            return
        }
        for store in stores {
            guard let hosts = trusted.object(forKey: store) else { continue }
            for case let key as String in hosts.allKeys {
                guard let host = host(of: key), covered(host, by: site) else { continue }
                hosts.removeObject(forKey: key)
            }
        }
    }

    private static func forgetSession(host: String, port: Int) {
        let siteKey = key(host: host, port: port)
        for store in stores { (trusted.object(forKey: store))?.removeObject(forKey: siteKey) }
    }

    /// The stores that have a choice in memory, without keeping one alive.
    private static var stores: [WKWebsiteDataStore] {
        var stores: [WKWebsiteDataStore] = []
        let enumerator = trusted.keyEnumerator()
        while let store = enumerator.nextObject() as? WKWebsiteDataStore { stores.append(store) }
        return stores
    }

    /// Whether the warning may offer "Visit anyway": only with the certificate it's about in hand, the one choice
    /// is for, and never for a site that asked to be reached only securely (HSTS), as in Chrome.
    static func mayOffer(certificate: Data?, strictTransport: Bool) -> Bool {
        guard let certificate, !certificate.isEmpty else { return false }
        return !strictTransport
    }

    /// Trusts `certificate` for `host:port` in `store`. Refused without a certificate: an empty one would stand for
    /// any. A local server's choice is remembered across launches; any other's lasts this session.
    @discardableResult
    static func allow(_ host: String, port: Int = 443, certificate: Data?, in store: WKWebsiteDataStore, now: Date = Date()) -> Bool {
        guard let certificate, !certificate.isEmpty, !host.isEmpty else { return false }
        let host = host.lowercased()
        let siteKey = key(host: host, port: port)
        let hosts = trusted.object(forKey: store) ?? NSMutableDictionary()
        hosts[siteKey] = Exception(leaf: certificate, until: now.addingTimeInterval(lifetime))
        trusted.setObject(hosts, forKey: store)
        if mayRemember(host: host, in: store) { remember(host, port: port, certificate: certificate) }
        return true
    }

    static func allows(_ host: String, port: Int = 443, trust: SecTrust, in store: WKWebsiteDataStore) -> Bool {
        allows(host, port: port, leaf: leaf(of: trust), in: store)
    }

    /// Whether `leaf` is the certificate you chose to trust for `host:port`, and the choice still holds. A local
    /// server's remembered choice has no time limit; it ends when its certificate changes or you remove it. None holds
    /// once the host is known for HSTS, which covers every port, as in Chrome.
    static func allows(_ host: String, port: Int = 443, leaf: Data?, in store: WKWebsiteDataStore, now: Date = Date()) -> Bool {
        guard let leaf, !leaf.isEmpty, !StrictTransport.isKnown(host, in: store, now: now) else { return false }
        if let exception = trusted.object(forKey: store)?[key(host: host, port: port)] as? Exception,
           now < exception.until, exception.leaf == leaf { return true }
        return store.isPersistent && rememberedCertificate(for: host, port: port) == leaf
    }

    /// Whether the shown page was loaded through a certificate trusted from the warning page.
    static func isShowingException(in webView: WKWebView?) -> Bool {
        guard let webView, let url = webView.url, url.scheme?.lowercased() == "https", let host = url.host(),
              let trust = webView.serverTrust else { return false }
        return wasTrusted(host, port: url.port ?? 443, leaf: leaf(of: trust), in: webView.configuration.websiteDataStore)
    }

    /// Whether you trusted `leaf` for `host:port`, even if that has since expired: a page still showing it isn't secure.
    static func wasTrusted(_ host: String, port: Int = 443, leaf: Data?, in store: WKWebsiteDataStore) -> Bool {
        guard let leaf, !leaf.isEmpty else { return false }
        if let exception = trusted.object(forKey: store)?[key(host: host, port: port)] as? Exception { return exception.leaf == leaf }
        return store.isPersistent && rememberedCertificate(for: host, port: port) == leaf
    }

    /// Whether `host:port` has a choice to trust a certificate in `store` (it may be the one it shows, or not).
    static func hasException(for host: String, port: Int = 443, in store: WKWebsiteDataStore, now: Date = Date()) -> Bool {
        if let exception = trusted.object(forKey: store)?[key(host: host, port: port)] as? Exception, now < exception.until { return true }
        return store.isPersistent && rememberedCertificate(for: host, port: port) != nil
    }

    /// Clears choices after site data is cleared: all, or one site's (its subdomains and parent domains, on every
    /// port). A private window's own data never clears a normal window's remembered local servers.
    static func forget(in store: WKWebsiteDataStore, site: String? = nil) {
        var forgotRemembered = false
        if store.isPersistent {
            if let site = site?.lowercased() {
                var kept = remembered
                for key in Array(kept.keys) {
                    guard let host = host(of: key), covered(host, by: site) else { continue }
                    kept.removeValue(forKey: key)
                    forgotRemembered = true
                }
                if forgotRemembered { remembered = kept }
            } else if !remembered.isEmpty {
                defaults.removeObject(forKey: rememberedKey)
                forgotRemembered = true
            }
        }
        if forgotRemembered { changed.send() }
        guard let site = site?.lowercased() else {
            trusted.removeObject(forKey: store)
            return
        }
        guard let hosts = trusted.object(forKey: store) else { return }
        for case let key as String in hosts.allKeys {
            guard let host = host(of: key), covered(host, by: site) else { continue }
            hosts.removeObject(forKey: key)
        }
    }

    /// Per data store, the certificate each development server on this Mac first showed, by host and port: two
    /// servers on localhost each have their own. Kept apart from the ones you chose to trust on the warning page,
    /// and only read while the setting that trusts them is on.
    private static let localServers = NSMapTable<WKWebsiteDataStore, NSMutableDictionary>.weakToStrongObjects()

    /// Whether a development server on this Mac is trusted with the certificate it shows (#141,
    /// `DeveloperTools.trustsServer`): the first one it shows is, and is the only one for the session, so another
    /// later gets the warning as anywhere. `page`: the address of the page that asks. Only a development page's own
    /// loads are trusted this way: a page from anywhere else that reaches for a server on this Mac gets what it
    /// always got.
    static func allowsLocalServer(_ host: String, port: Int, leaf: Data?, askedBy page: URL?, in store: WKWebsiteDataStore) -> Bool {
        guard let leaf, DeveloperTools.trustsServer(host), DeveloperTools.applies(to: page) else { return false }
        let key = "\(host.lowercased()):\(port)"
        let servers = localServers.object(forKey: store) ?? NSMutableDictionary()
        if let shown = servers[key] as? Data { return shown == leaf }
        servers[key] = leaf
        localServers.setObject(servers, forKey: store)
        return true
    }

    /// The site's own certificate (not its issuers'), as data to compare.
    nonisolated static func leaf(of trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first else { return nil }
        return SecCertificateCopyData(first) as Data
    }

    /// The certificate a failed load was shown, from its error.
    nonisolated static func certificate(in error: NSError) -> Data? {
        if let chain = error.userInfo["NSErrorPeerCertificateChainKey"] as? [SecCertificate], let first = chain.first {
            return SecCertificateCopyData(first) as Data
        }
        if let value = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey], CFGetTypeID(value as CFTypeRef) == SecTrustGetTypeID() {
            return leaf(of: value as! SecTrust)
        }
        return nil
    }

    /// The link the warning page's "Visit anyway" goes to; the tab catches it before it loads.
    static let scheme = "zigzag-proceed"
    /// Carries the nonce on that link, so a page can't make one up.
    private static let nonceItem = "zigzag-nonce"
    /// Made fresh for each warning and written only into that page: one a page read from another warning (its own
    /// site's) opens nothing.
    static func makeNonce() -> String { UUID().uuidString }

    /// The "Visit anyway" link for a page whose certificate failed.
    static func proceedLink(for url: URL, nonce: String) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        parts.scheme = scheme
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: nonceItem, value: nonce)]
        return parts.url
    }

    /// The page a "Visit anyway" link opens, or nil unless it carries the warning's nonce and is for the host the
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
    /// whose tab the sign-in sheet stays with; without one it covers the window. `tab`: the tab asking, as extensions
    /// know it, whose onAuthRequired listeners may answer before the sheet; never a private one.
    static func respond(to challenge: URLAuthenticationChallenge, window: NSWindow?, store: WKWebsiteDataStore,
                        page: WKWebView? = nil, tab: (any WKWebExtensionTab)? = nil) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        // A certificate you chose to trust on the warning page: accepted for this session.
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
           CertificateExceptions.allows(challenge.protectionSpace.host, port: challenge.protectionSpace.port,
                                        trust: trust, in: store) {
            return (.useCredential, URLCredential(trust: trust))
        }
        // A development server on this Mac, asked for by a development page (Settings › Developer › Local Servers).
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
           CertificateExceptions.allowsLocalServer(challenge.protectionSpace.host, port: challenge.protectionSpace.port,
                                                   leaf: CertificateExceptions.leaf(of: trust), askedBy: page?.url, in: store) {
            return (.useCredential, URLCredential(trust: trust))
        }
        // Client certificate from the Keychain, as in Safari.
        if method == NSURLAuthenticationMethodClientCertificate {
            return await ClientCertificates.respond(to: challenge, window: window, store: store, page: page)
        }
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodNTLM else {
            return (.performDefaultHandling, nil)
        }
        // Only the page's own site can sign in over it. Cross-site resources (images, frames) get no sheet and no
        // saved credentials; checked before saved logins are read.
        let pageHost = await MainActor.run { page?.url?.host() }
        guard Self.mayAnswer(pageHost: pageHost, askingHost: challenge.protectionSpace.host) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // Your saved sign-ins are never offered to AI apps' pages; their own extensions still are.
        let offersYours = await MainActor.run { Profiles.shared.profile(ofPage: page).getsYourData }
        if offersYours, challenge.previousFailureCount == 0, let saved = URLCredentialStorage.shared.defaultCredential(for: challenge.protectionSpace) {
            return (.useCredential, saved)
        }
        guard let window else { return (.cancelAuthenticationChallenge, nil) }
        // Several loads asking for the same sign-in at once (a page and its images): one question, one answer for all.
        let space = challenge.protectionSpace
        let key = "\(ObjectIdentifier(store).hashValue)|\(space.host):\(space.port)|\(space.realm ?? "")"
        // A private tab's sign-ins go only to extensions allowed in private windows (BridgeWebRequest.askForSignIn).
        let asker = tab
        if challenge.previousFailureCount == 0, let asking = signingIn[key] {
            // Asked again while the sheet is up: the page loaded again, often because an extension was told what to
            // fill (1Password reloads the tab once you pick a login in it). Its answer answers the sheet too.
            if asking.sheetShown, case .credentials(let username, let password) = await askExtensions(challenge, page: page, tab: asker) {
                PageDialogSheet.answer(tag: key, with: [username, password])
                return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            }
            return await asking.task?.value ?? (.cancelAuthenticationChallenge, nil)
        }
        let attempt = SigningIn()
        signingIn[key] = attempt
        // While the sheet asks, an extension's late name and password signs in with it (#387).
        let late = BridgeWebRequest.LateAnswer { username, password in
            if !PageDialogSheet.answer(tag: key, with: [username, password]) { attempt.early = [username, password] }
        }
        let task = Task { @MainActor () -> (URLSession.AuthChallengeDisposition, URLCredential?) in
            defer { late.end() }
            switch await askExtensions(challenge, page: page, tab: asker, late: late) {
            case .credentials(let username, let password):
                return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            case .cancel:
                return (.cancelAuthenticationChallenge, nil)
            case .none:
                return await ask(challenge, window: window, page: page, tag: key, offersYours: offersYours) {
                    attempt.sheetShown = true
                    return attempt.early
                }
            }
        }
        attempt.task = task
        let answer = await task.value
        if signingIn[key] === attempt { signingIn[key] = nil }
        return answer
    }

    /// Only on its own site; with no page, allowed.
    nonisolated static func mayAnswer(pageHost: String?, askingHost: String) -> Bool {
        guard let pageHost = pageHost?.lowercased(), !pageHost.isEmpty else { return true }
        return sameSite(pageHost, askingHost.lowercased())
    }

    nonisolated private static func sameSite(_ a: String, _ b: String) -> Bool {
        a == b || (PublicSuffix.registrableDomain(a) ?? a) == (PublicSuffix.registrableDomain(b) ?? b)
    }

    /// One sign-in being answered, by extensions and then the sheet.
    @MainActor private final class SigningIn {
        var task: Task<(URLSession.AuthChallengeDisposition, URLCredential?), Never>?
        var sheetShown = false
        /// An extension's name and password that came before the sheet showed.
        var early: [String]?
    }

    @MainActor private static var signingIn: [String: SigningIn] = [:]

    /// Extensions' onAuthRequired listeners, asked as Chrome asks them before its own dialog. After a wrong password
    /// they're asked once more, as in Chrome; after that only the sheet asks, so a wrong answer can't go round and round.
    @MainActor
    private static func askExtensions(_ challenge: URLAuthenticationChallenge, page: WKWebView?, tab: (any WKWebExtensionTab)?,
                                      late: BridgeWebRequest.LateAnswer? = nil) async -> BridgeWebRequest.Answer {
        // The extensions of the profile the page is in: another profile's never hear of its sign-ins.
        guard challenge.previousFailureCount < 2, let page, let site = SiteChallenge(challenge, pageURL: page.url),
              let host = (page as? BrowserWebView)?.owner?.extensionHost ?? Profiles.shared.profile(of: page)?.extensions else { return .none }
        return await host.bridge.webRequest.askForSignIn(site, tab: tab, isPrivate: !page.configuration.websiteDataStore.isPersistent, late: late)
    }

    @MainActor
    /// `offersYours`: whether your saved passwords for the site are offered in the sheet.
    private static func ask(_ challenge: URLAuthenticationChallenge, window: NSWindow,
                            page: WKWebView?, tag: String, offersYours: Bool, shown: () -> [String]?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let isPrivate = page?.configuration.websiteDataStore.isPersistent != true
        Diagnostics.note(challenge.previousFailureCount > 0 ? "Site sign-in didn’t work" : "Site asked to sign in", site: challenge.protectionSpace.host,
                         isPrivate: isPrivate)
        let message = challenge.previousFailureCount > 0 ? String(localized: "That name or password didn’t work. Try again.", comment: "Message in the sheet a site's HTTP sign-in asks with, after a wrong name or password.") : String(localized: "This site needs a name and password.", comment: "Message in the sheet a site's HTTP sign-in asks with.")
        var fields: [PageDialogSheet.Field] = [.init(placeholder: String(localized: "Username", comment: "Placeholder of the name field in a site's HTTP sign-in sheet.")), .init(placeholder: String(localized: "Password", comment: "Placeholder of the password field in a site's HTTP sign-in sheet."), secure: true)]
        // Passwords you saved for the site: the one saved for this exact address comes filled in; others (several, or
        // saved for another part of the site) wait behind a quiet button. Filling asks for no Touch ID, as filling a
        // page's form doesn't. After a wrong password, nothing is filled in again by itself.
        let saved = offersYours ? await savedLogins(for: challenge.protectionSpace) : nil
        var prefilled: Credential?
        if let saved, challenge.previousFailureCount == 0, let login = Self.prefill(saved.logins, for: saved.origin),
           let values = await saved.fill(login) {
            fields[0].value = values[0]
            fields[1].value = values[1]
            prefilled = login
        }
        let offered = saved.flatMap { prefilled != nil && $0.logins.count == 1 ? nil : $0 }
        // The tab or window may have gone while extensions and saved passwords were asked: nothing to put a sheet on,
        // and a sheet on nothing would never be answered, leaving the site's next sign-in waiting on it.
        guard window.isVisible, page.map({ $0.window === window }) ?? true else { return (.cancelAuthenticationChallenge, nil) }
        // An extension answered while saved passwords were read: no sheet.
        if let early = shown(), early.count == 2 { return (.useCredential, URLCredential(user: early[0], password: early[1], persistence: .forSession)) }
        let result = await PageDialogSheet.ask(in: window, title: String(localized: "Sign in to \(challenge.protectionSpace.host)", comment: "Title of the sheet a site's HTTP sign-in asks with. The placeholder is the site's host name."), message: message,
                                               fields: fields, confirmTitle: String(localized: "Sign In", comment: "Button in a site's HTTP sign-in sheet."), showsCancel: true, offersBlock: false, page: page,
                                               savedLogins: offered, tag: tag)
        guard case .confirmed(let values) = result, values.count == 2 else { return (.cancelAuthenticationChallenge, nil) }
        // Only once you've signed in with it is a saved login "used". Private windows leave no trace, not even that.
        if let saved, !isPrivate { await markUsed(saved.logins, signingInWith: values) }
        return (.useCredential, URLCredential(user: values[0], password: values[1], persistence: .forSession))
    }

    /// The login the sheet comes with filled in: the only one saved for this exact address. One saved for another part
    /// of the site waits behind Saved Passwords, for you to choose.
    nonisolated static func prefill(_ logins: [Credential], for origin: Origin) -> Credential? {
        let exact = logins.filter { $0.origin.isExact(for: origin) }
        return exact.count == 1 ? exact[0] : nil
    }

    @MainActor
    private static func markUsed(_ logins: [Credential], signingInWith values: [String]) async {
        for login in logins where login.username == values[0] {
            guard let password = try? await PasswordStore.shared.password(for: login.id), password.withUnsafeString({ String($0) == values[1] }) else { continue }
            try? await PasswordStore.shared.markUsed(login.id)
            return
        }
    }

    /// The logins saved for the site asking, as the menu that fills a page's form lists them: those saved for this
    /// exact address first, then other parts of the site, newest used first.
    @MainActor
    private static func savedLogins(for space: URLProtectionSpace) async -> PageDialogSheet.SavedLogins? {
        guard let origin = Origin(URL(string: "\(space.protocol ?? "https")://\(space.host):\(space.port)")),
              let all = try? await PasswordStore.shared.all() else { return nil }
        let logins = all.filter { $0.origin.fills(on: origin) }.sorted { a, b in
            let exactA = a.origin.isExact(for: origin), exactB = b.origin.isExact(for: origin)
            if exactA != exactB { return exactA }
            return (a.lastUsed ?? a.modified) > (b.lastUsed ?? b.modified)
        }
        guard !logins.isEmpty else { return nil }
        return PageDialogSheet.SavedLogins(logins: logins, origin: origin) { login in
            guard let password = try? await PasswordStore.shared.password(for: login.id) else { return nil }
            return [login.username, password.withUnsafeString { String($0) }]
        }
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
}
