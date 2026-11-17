import Foundation
import Security
import WebKit

/// Certificates that identify you to a site (#297): a site that asks for one (mutual TLS, as some organizations'
/// Microsoft sign-in and intranets do) is offered the identities in your Keychain that it would take, as Safari offers
/// them. Importing one is Keychain Access's job (a .p12, or a .pem with its key); Zigzag only reads what's there.
///
/// The one you choose is used for the site's host for the session; with "Always use", it's kept for that host and
/// used without asking until it's gone from the Keychain or expires. Private windows keep nothing and use nothing
/// kept: they ask, and their choice holds for that window's session only.
enum ClientCertificates {
    /// One identity as the sheet lists it.
    nonisolated struct Info: Equatable, Sendable {
        var name: String
        var issuer: String?
        var validFrom: Date?
        var validUntil: Date?
        /// The certificate's SHA-256, which a kept choice is found again by.
        var sha256: String
    }

    /// An identity from the Keychain with what the sheet shows of it.
    nonisolated struct Found: @unchecked Sendable {
        let identity: SecIdentity
        let certificate: SecCertificate
        let info: Info
    }

    /// What a session already said for a host.
    nonisolated enum SessionAnswer: Equatable, Sendable {
        case identity(sha256: String)
        /// Cancel: holds a little while, so the page's other connections don't ask again at once.
        case declined(until: Date)
    }

    nonisolated enum Decision: Equatable, Sendable {
        /// Nothing in the Keychain fits: WebKit goes on as it would without Zigzag.
        case noMatch
        /// Use the candidate at this index without asking.
        case use(Int)
        /// You said no a moment ago.
        case declined
        case ask
    }

    /// How long a Cancel holds before the site may ask again.
    nonisolated static let declineHolds: TimeInterval = 60

    /// What to do with the candidates found: what this session chose first, then what's kept for the site; a choice
    /// whose identity is gone or expired (no longer a candidate) is asked again.
    nonisolated static func decide(candidates: [Info], session: SessionAnswer?, kept: String?, now: Date) -> Decision {
        guard !candidates.isEmpty else { return .noMatch }
        switch session {
        case .identity(let sha256):
            if let index = candidates.firstIndex(where: { $0.sha256 == sha256 }) { return .use(index) }
        case .declined(let until):
            if until > now { return .declined }
        case nil: break
        }
        if let kept, let index = candidates.firstIndex(where: { $0.sha256 == kept }) { return .use(index) }
        return .ask
    }

    /// Valid at `now`: not before its start and not after its end.
    nonisolated static func isValid(_ info: Info, at now: Date) -> Bool {
        if let from = info.validFrom, from > now { return false }
        if let until = info.validUntil, until < now { return false }
        return true
    }

    /// The Keychain query for identities a site would take: limited to those whose chain includes one of the issuers
    /// it named (DER distinguished names), when it named any.
    nonisolated static func query(issuers: [Data]?, searchList: [SecKeychain]? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
        if let issuers, !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        if let searchList { query[kSecMatchSearchList] = searchList }
        return query
    }

    /// The identities in the Keychain (and on smart cards) a site naming `issuers` would take, valid at `now`, by name.
    /// Listing them asks nothing; using one's key later may bring up macOS's own "wants to use the key" prompt.
    /// Call off the main thread. `searchList` is for tests: only those keychains, and no smart cards.
    nonisolated static func find(issuers: [Data]?, searchList: [SecKeychain]? = nil, now: Date = Date()) -> [Found] {
        var queries = [query(issuers: issuers, searchList: searchList)]
        if searchList == nil {
            var tokens = query(issuers: issuers)
            tokens[kSecUseDataProtectionKeychain] = true
            tokens[kSecAttrAccessGroup] = kSecAttrAccessGroupToken
            queries.append(tokens)
        }
        var found: [Found] = []
        for query in queries {
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [Any] else { continue }
            for item in items {
                guard CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { continue }
                let identity = item as! SecIdentity
                var certificate: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
                let summary = CertificateDetails.summary(certificate)
                let info = Info(name: summary.name, issuer: summary.issuer, validFrom: summary.validFrom, validUntil: summary.validUntil,
                                sha256: summary.sha256)
                guard isValid(info, at: now), !found.contains(where: { $0.info.sha256 == info.sha256 }) else { continue }
                found.append(Found(identity: identity, certificate: certificate, info: info))
            }
        }
        return found.sorted { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }
    }

    /// The credential for an identity: with the certificates between it and its root, so a server that knows only
    /// the root can follow the chain. Built without the network. Call off the main thread.
    nonisolated static func credential(for found: Found) -> URLCredential {
        var trust: SecTrust?
        var intermediates: [SecCertificate] = []
        if SecTrustCreateWithCertificates(found.certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
            _ = SecTrustEvaluateWithError(trust, nil)
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
            intermediates = Array(chain.dropFirst())
            if let root = intermediates.last, CertificateDetails.summary(root).isSelfSigned { intermediates.removeLast() }
        }
        return URLCredential(identity: found.identity, certificates: intermediates.isEmpty ? nil : intermediates, persistence: .forSession)
    }

    // MARK: Kept choices

    /// Where kept choices live; tests use their own.
    static var defaults: UserDefaults = .standard
    /// Host → ["sha256": …, "name": …].
    private static let key = "ClientCertificateChoices"

    struct Kept: Equatable {
        var sha256: String
        var name: String
    }

    private static var stored: [String: [String: String]] {
        get { defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: key) : defaults.set(newValue, forKey: key) }
    }

    /// The host a choice is kept under: the one that asked, lowercased.
    nonisolated static func site(_ host: String) -> String { host.lowercased() }

    static func kept(host: String) -> Kept? {
        guard let entry = stored[site(host)], let sha256 = entry["sha256"] else { return nil }
        return Kept(sha256: sha256, name: entry["name"] ?? sha256)
    }

    /// Hosts with a kept certificate, as Settings › Privacy › Sites lists them.
    static var sites: Set<String> { Set(stored.keys) }

    static func forget(site host: String) { stored[site(host)] = nil }

    static func forgetAll() { defaults.removeObject(forKey: key) }

    /// Session answers per data store: a private window's go with it, and one store's never answer another's.
    private static let sessions = NSMapTable<WKWebsiteDataStore, SessionBox>.weakToStrongObjects()
    private final class SessionBox {
        var answers: [String: SessionAnswer] = [:]
        /// When each host last asked for a certificate.
        var asked: [String: Date] = [:]
    }

    static func sessionAnswer(host: String, store: WKWebsiteDataStore) -> SessionAnswer? {
        sessions.object(forKey: store)?.answers[site(host)]
    }

    private static func setSession(_ answer: SessionAnswer?, host: String, store: WKWebsiteDataStore) {
        let box = sessions.object(forKey: store) ?? SessionBox()
        box.answers[site(host)] = answer
        sessions.setObject(box, forKey: store)
    }

    private static func noteAsked(host: String, store: WKWebsiteDataStore, now: Date = Date()) {
        let box = sessions.object(forKey: store) ?? SessionBox()
        box.asked[site(host)] = now
        sessions.setObject(box, forKey: store)
    }

    /// How long after a site asked for a certificate a dropped connection is put down to it.
    nonisolated static let refusalWindow: TimeInterval = 30

    /// Whether a failed load was the site turning you away for want of a certificate it accepts. Over TLS 1.3 the
    /// server says so only after the handshake, so the load fails as a lost or failed connection, which would read
    /// as being offline; right after the site asked for a certificate, that's what it was.
    nonisolated static func isRefusal(code: Int, askedAt: Date?, now: Date) -> Bool {
        guard let askedAt, now.timeIntervalSince(askedAt) < refusalWindow, askedAt <= now else { return false }
        return code == NSURLErrorNetworkConnectionLost || code == NSURLErrorSecureConnectionFailed
    }

    /// The error a page shows: a refusal (`isRefusal`) as the certificate error it is, anything else as it was.
    static func explain(_ error: NSError, url: URL?, store: WKWebsiteDataStore, now: Date = Date()) -> NSError {
        guard error.domain == NSURLErrorDomain, let host = url?.host(),
              isRefusal(code: error.code, askedAt: sessions.object(forKey: store)?.asked[site(host)], now: now) else { return error }
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRequired, userInfo: error.userInfo)
    }

    /// Writes down a choice: for the store's session always, and kept for the host only when asked to and never from
    /// a private window (a store that isn't persistent), whatever `always` says.
    static func noteChosen(_ info: Info, host: String, store: WKWebsiteDataStore, always: Bool) {
        setSession(.identity(sha256: info.sha256), host: host, store: store)
        guard always, store.isPersistent else { return }
        stored[site(host)] = ["sha256": info.sha256, "name": info.name]
    }

    static func noteDeclined(host: String, store: WKWebsiteDataStore, now: Date = Date()) {
        setSession(.declined(until: now.addingTimeInterval(declineHolds)), host: host, store: store)
    }

    /// Settings' Forget: the session's choice for the host goes too, in every store, so the site asks again.
    static func forgetSessions(site host: String) {
        for store in sessions.keyEnumerator().allObjects.compactMap({ $0 as? WKWebsiteDataStore }) {
            sessions.object(forKey: store)?.answers[site(host)] = nil
        }
    }

    static func forgetAllSessions() { sessions.removeAllObjects() }

    // MARK: Answering

    /// One question per store and host at a time: a page's several connections asking at once share one sheet.
    private static var asking: [String: Task<(URLSession.AuthChallengeDisposition, URLCredential?), Never>] = [:]

    /// Answers a site's request for a certificate. No identity fits: default handling, as before. Cancel goes on
    /// without one (`rejectProtectionSpace`), as Safari and Chrome do, so the site can show its own page or try
    /// another way to sign in, rather than the load failing.
    static func respond(to challenge: URLAuthenticationChallenge, window: NSWindow?, store: WKWebsiteDataStore,
                        page: WKWebView?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host
        let key = "\(ObjectIdentifier(store).hashValue)|\(site(host))"
        noteAsked(host: host, store: store)
        if let running = asking[key] { return await running.value }
        let task = Task { @MainActor () -> (URLSession.AuthChallengeDisposition, URLCredential?) in
            let issuers = space.distinguishedNames
            let candidates = await Task.detached { find(issuers: issuers) }.value
            // A private window asks for itself: what's kept for the site isn't sent from there unasked.
            let keptHere = store.isPersistent ? kept(host: host)?.sha256 : nil
            switch decide(candidates: candidates.map(\.info), session: sessionAnswer(host: host, store: store), kept: keptHere, now: Date()) {
            case .noMatch:
                return (.performDefaultHandling, nil)
            case .declined:
                return (.rejectProtectionSpace, nil)
            case .use(let index):
                let found = candidates[index]
                return (.useCredential, await Task.detached { credential(for: found) }.value)
            case .ask:
                guard let window, window.isVisible, page.map({ $0.window === window }) ?? true else { return (.rejectProtectionSpace, nil) }
                Diagnostics.note("Site asked for a certificate", site: host, isPrivate: !store.isPersistent)
                let rows = candidates.map { PageDialogSheet.Choice(title: $0.info.name, detail: detail(of: $0.info)) }
                let result = await PageDialogSheet.ask(in: window, title: String(localized: "Choose a certificate", comment: "Title of the sheet a site asks for a certificate from your Keychain with."),
                                                       message: String(localized: "\(host) wants a certificate to identify you.", comment: "Message in the sheet a site asks for a certificate with. The placeholder is the site's host name."),
                                                       confirmTitle: String(localized: "Continue", comment: "Button in the sheet a site asks for a certificate with: sends the chosen one."),
                                                       showsCancel: true, offersBlock: false, page: page, choices: rows,
                                                       remember: store.isPersistent ? String(localized: "Always use this certificate for \(host)", comment: "Choice in the sheet a site asks for a certificate with. The placeholder is the site's host name.") : nil)
                guard case .chose(let index, let always) = result, candidates.indices.contains(index) else {
                    noteDeclined(host: host, store: store)
                    return (.rejectProtectionSpace, nil)
                }
                let found = candidates[index]
                noteChosen(found.info, host: host, store: store, always: always)
                return (.useCredential, await Task.detached { credential(for: found) }.value)
            }
        }
        asking[key] = task
        let answer = await task.value
        asking[key] = nil
        return answer
    }

    /// "Issued by …, expires …" under a certificate's name in the sheet.
    static func detail(of info: Info) -> String {
        let date = info.validUntil.map { $0.formatted(date: .abbreviated, time: .omitted) }
        switch (info.issuer, date) {
        case let (issuer?, date?):
            return String(localized: "Issued by \(issuer), expires \(date)", comment: "Under a certificate's name in the sheet a site asks for one with. The placeholders are who issued it and the date it expires.")
        case let (issuer?, nil):
            return String(localized: "Issued by \(issuer)", comment: "Under a certificate's name in the sheet a site asks for one with. The placeholder is who issued it.")
        case let (nil, date?):
            return String(localized: "Expires \(date)", comment: "Under a certificate's name in the sheet a site asks for one with. The placeholder is the date it expires.")
        case (nil, nil):
            return ""
        }
    }
}
