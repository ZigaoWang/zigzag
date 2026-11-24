import Foundation
import Security
import WebKit

/// Client certificates (#297): a site that asks (mutual TLS, e.g. some Microsoft sign-ins and intranets) is offered
/// matching Keychain identities, as in Safari. Importing is Keychain Access's job; Zigzag only reads. The choice
/// holds for the host for the session; "Always use" keeps it until it leaves the Keychain or expires. Private windows
/// ignore kept choices and keep nothing past their session.
enum ClientCertificates {
    nonisolated struct Info: Equatable, Sendable {
        var name: String
        var issuer: String?
        var validFrom: Date?
        var validUntil: Date?
        /// Kept choices are matched by this.
        var sha256: String
    }

    nonisolated struct Found: @unchecked Sendable {
        let identity: SecIdentity
        let certificate: SecCertificate
        let info: Info
    }

    /// What this session already answered for a host.
    nonisolated enum SessionAnswer: Equatable, Sendable {
        case identity(sha256: String)
        /// Cancel holds briefly so the page's other connections don't ask again at once.
        case declined(until: Date)
    }

    nonisolated enum Decision: Equatable, Sendable {
        /// Nothing fits: default WebKit handling.
        case noMatch
        case use(Int)
        case declined
        case ask
    }

    nonisolated static let declineHolds: TimeInterval = 60

    /// Session choice first, then the kept one; a choice whose identity is gone or expired asks again.
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

    nonisolated static func isValid(_ info: Info, at now: Date) -> Bool {
        if let from = info.validFrom, from > now { return false }
        if let until = info.validUntil, until < now { return false }
        return true
    }

    /// Limited to chains containing one of the site's issuers (DER distinguished names), if it named any.
    nonisolated static func query(issuers: [Data]?, searchList: [SecKeychain]? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
        if let issuers, !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        if let searchList { query[kSecMatchSearchList] = searchList }
        return query
    }

    /// Matching Keychain and smart card identities valid at `now`, by name. Listing doesn't prompt; using a key later
    /// may bring up macOS's key access prompt. Call off the main thread. `searchList` is for tests: only those
    /// keychains, no smart cards.
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

    /// Includes the intermediates up to the root so the server can follow the chain. No network. Call off the main
    /// thread.
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

    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "ClientCertificateChoices"

    struct Kept: Equatable {
        var sha256: String
        var name: String
    }

    private static var stored: [String: [String: String]] {
        get { defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: key) : defaults.set(newValue, forKey: key) }
    }

    /// The asking host, lowercased.
    nonisolated static func site(_ host: String) -> String { host.lowercased() }

    static func kept(host: String) -> Kept? {
        guard let entry = stored[site(host)], let sha256 = entry["sha256"] else { return nil }
        return Kept(sha256: sha256, name: entry["name"] ?? sha256)
    }

    /// For Settings › Privacy › Sites.
    static var sites: Set<String> { Set(stored.keys) }

    static func forget(site host: String) { stored[site(host)] = nil }

    static func forgetAll() { defaults.removeObject(forKey: key) }

    /// Per data store, so a private window's answers go with it.
    private static let sessions = NSMapTable<WKWebsiteDataStore, SessionBox>.weakToStrongObjects()
    private final class SessionBox {
        var answers: [String: SessionAnswer] = [:]
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

    /// How long after a certificate request a dropped connection counts as a refusal.
    nonisolated static let refusalWindow: TimeInterval = 30

    /// Whether a failed load was the site rejecting us for lack of an accepted certificate. Over TLS 1.3 the server
    /// says so only after the handshake, so it shows up as a lost connection that would read as offline.
    nonisolated static func isRefusal(code: Int, askedAt: Date?, now: Date) -> Bool {
        guard let askedAt, now.timeIntervalSince(askedAt) < refusalWindow, askedAt <= now else { return false }
        return code == NSURLErrorNetworkConnectionLost || code == NSURLErrorSecureConnectionFailed
    }

    /// Shows a refusal (`isRefusal`) as a certificate error; other errors unchanged.
    static func explain(_ error: NSError, url: URL?, store: WKWebsiteDataStore, now: Date = Date()) -> NSError {
        guard error.domain == NSURLErrorDomain, let host = url?.host(),
              isRefusal(code: error.code, askedAt: sessions.object(forKey: store)?.asked[site(host)], now: now) else { return error }
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorClientCertificateRequired, userInfo: error.userInfo)
    }

    /// Always for the session; kept for the host only with `always` and never from a non-persistent (private) store.
    static func noteChosen(_ info: Info, host: String, store: WKWebsiteDataStore, always: Bool) {
        setSession(.identity(sha256: info.sha256), host: host, store: store)
        guard always, store.isPersistent else { return }
        stored[site(host)] = ["sha256": info.sha256, "name": info.name]
    }

    static func noteDeclined(host: String, store: WKWebsiteDataStore, now: Date = Date()) {
        setSession(.declined(until: now.addingTimeInterval(declineHolds)), host: host, store: store)
    }

    /// Settings' Forget also clears session choices in every store, so the site asks again.
    static func forgetSessions(site host: String) {
        for store in sessions.keyEnumerator().allObjects.compactMap({ $0 as? WKWebsiteDataStore }) {
            sessions.object(forKey: store)?.answers[site(host)] = nil
        }
    }

    static func forgetAllSessions() { sessions.removeAllObjects() }

    // MARK: Answering

    /// One question per store and host; simultaneous connections share one sheet.
    private static var asking: [String: Task<(URLSession.AuthChallengeDisposition, URLCredential?), Never>] = [:]

    /// No match: default handling. Cancel continues without one (`rejectProtectionSpace`), like Safari and Chrome, so
    /// the site can show its own page instead of failing.
    static func respond(to challenge: URLAuthenticationChallenge, window: NSWindow?, store: WKWebsiteDataStore,
                        page: WKWebView?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // AI apps' profile is given nothing of yours (`Profile.getsYourData`): no certificate from your Keychain, kept or
        // not. The site goes on without one, as after Cancel.
        if Profiles.shared.profile(ofStore: store)?.getsYourData == false { return (.rejectProtectionSpace, nil) }
        let space = challenge.protectionSpace
        let host = space.host
        let key = "\(ObjectIdentifier(store).hashValue)|\(site(host))"
        noteAsked(host: host, store: store)
        if let running = asking[key] { return await running.value }
        let task = Task { @MainActor () -> (URLSession.AuthChallengeDisposition, URLCredential?) in
            let issuers = space.distinguishedNames
            let candidates = await Task.detached { find(issuers: issuers) }.value
            // Private windows never send a kept choice unasked.
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
