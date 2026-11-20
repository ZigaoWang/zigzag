import Foundation
import WebKit

/// Reaching a program listening on this Mac for a page or an extension whose own networking WebKit refuses.
///
/// WebKit treats loopback as an untrustworthy origin: an https page may not `fetch` or open a WebSocket to
/// `http://localhost`, while Chrome and Firefox allow it. Zigzag can make the request itself, as itself, and hand
/// the answer back. This is that request. It is native, so the caller's `Origin` is presented exactly, and because
/// `URLSession` does not enforce CORS at all, this file does: a site reads only what the helper's own CORS reply
/// lets it read, and an extension is exempt exactly as Chrome exempts one with host access.
nonisolated enum LocalReceivers {
    /// This Mac, by every name loopback is reached by: `localhost`, `*.localhost`, `127.0.0.0/8`, `::1`. Ports are
    /// free. Only `http` and `ws` are caught; `https` and `wss` on loopback are not blocked by WebKit and stay with it.
    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "ws"].contains(scheme),
              let host = url.host(), isLoopback(host: host) else { return false }
        return true
    }

    /// The same test for a host on its own, as a WebSocket bridge has it before it has a URL.
    static func isLoopback(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost")
            || name == "::1" || name == "0:0:0:0:0:0:0:1" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && UInt8($0) != nil })
        else { return false }
        return octets[0] == "127"
    }

    /// Whose permission was checked, and what the helper sees as the caller.
    enum Identity: Equatable, Sendable {
        /// A page, as its origin: `https://creator.zerowork.io`.
        case site(origin: String)
        /// An extension, as Chrome presents it: `chrome-extension://<id>`.
        case webExtension(id: String)

        var origin: String {
            switch self {
            case .site(let origin): origin
            case .webExtension(let id): "chrome-extension://\(id)"
            }
        }

        var isWebExtension: Bool {
            if case .webExtension = self { return true }
            return false
        }
    }

    /// What the page's `fetch(…, { credentials })` said. The target is always another origin on this Mac, so
    /// `same-origin` sends no cookies; only `include` does.
    enum Credentials: String, Sendable {
        case omit, sameOrigin, include

        var sendsCookies: Bool { self == .include }
    }

    struct Request: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var credentials: Credentials

        init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
             credentials: Credentials = .sameOrigin) {
            self.url = url
            self.method = method.uppercased()
            self.headers = headers
            self.body = body
            self.credentials = credentials
        }
    }

    struct Response: Sendable {
        var url: URL
        var status: Int
        /// Names lowercased, so a CORS header is found however the helper spelled it.
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum Failure: Error, Equatable {
        case notLoopback
        /// The helper did not answer at all.
        case noAnswer
        /// The helper answered, and its reply does not let this caller read it.
        case cors(String)
        /// The helper asked for something this door does not do, like leaving loopback.
        case refused(String)
        case tooLarge
        /// A port browsers never load from, so a page can't speak HTTP to a mail or file server.
        case blockedPort(Int)
    }

    /// The Fetch spec's bad ports, as WebKit blocks them for any load (WTF's `portAllowed`), port 0 included.
    static let blockedPorts: Set<Int> = [
        0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104, 109,
        110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530, 531,
        532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060,
        5061, 6000, 6566, 6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080,
    ]

    /// The port `url` names, if it's one of those.
    static func blockedPort(of url: URL) -> Int? {
        guard let port = url.port, blockedPorts.contains(port) else { return nil }
        return port
    }

    /// The master switch: Settings › Privacy, off until the person reads the briefing and turns it on. The per-site
    /// switch is offered only while this is on, and a call is refused without it however the site answered.
    private static let enabledKey = "AllowWebsitesToReachLocalApps"

    @MainActor
    static var isEnabled: Bool {
        get { SitePermissions.defaults.bool(forKey: enabledKey) }
        set { SitePermissions.defaults.set(newValue, forKey: enabledKey) }
    }

    /// Whether a page at `origin` may use this door now: the person allowed websites in Settings, and allowed this
    /// one in Site Controls. A private tab is refused by the caller before this is read.
    @MainActor
    static func allowsSite(origin: String) -> Bool {
        isEnabled && SitePermissions.localReceivers(origin: origin)
    }

    /// The one thing a caller may replace, so the policy can be tested without a helper running.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Makes the request for `identity`, with the preflight a browser would send first, and refuses an answer the
    /// helper's CORS reply does not cover.
    static func send(_ request: Request, as identity: Identity,
                     transport: Transport? = nil) async throws -> Response {
        guard isLoopback(request.url) else { throw Failure.notLoopback }
        guard isWellFormed(request) else { throw Failure.refused("the request is malformed") }
        if let port = blockedPort(of: request.url) { throw Failure.blockedPort(port) }
        let run = transport ?? defaultTransport
        if !identity.isWebExtension, needsPreflight(request) {
            let preflight = try await run(urlRequest(for: preflightRequest(for: request), as: identity))
            let answer = try response(preflight, for: request.url)
            try requirePreflight(answer, for: request, as: identity)
        }
        let (data, raw) = try await run(urlRequest(for: request, as: identity))
        let answer = try response(data, raw, for: request.url)
        guard answer.body.count <= responseLimit else { throw Failure.tooLarge }
        if let location = answer.header("location"),
           (300..<400).contains(answer.status) {
            // A redirect is followed by a browser, but each hop is another CORS decision. Refusing one keeps every
            // door honest; a helper that needs a redirect can be asked to answer where it is.
            guard let target = URL(string: location, relativeTo: answer.url)?.absoluteURL,
                  isLoopback(target) else { throw Failure.refused("the helper redirected off this Mac") }
            throw Failure.refused("the helper redirected")
        }
        if !identity.isWebExtension { try requireRead(answer, for: request, as: identity) }
        return answer
    }

    /// A method this door sends and headers HTTP can carry as they are: a name that is a token, a value on one line.
    /// A page can post to the handler without WebKit's own checks, so they are made here.
    static func isWellFormed(_ request: Request) -> Bool {
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
            .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        let isToken = { (text: String) in !text.isEmpty && text.unicodeScalars.allSatisfy(tokenCharacters.contains) }
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(request.method) else { return false }
        return request.headers.allSatisfy { name, value in
            isToken(name) && !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
        }
    }

    // MARK: - What a browser would ask first

    /// The request headers a CORS preflight does not know.
    private static let safelistedHeaders: Set<String> = [
        "accept", "accept-language", "content-language", "content-type", "range",
    ]
    private static let safelistedContentTypes: Set<String> = [
        "application/x-www-form-urlencoded", "multipart/form-data", "text/plain",
    ]
    private static let safelistedMethods: Set<String> = ["GET", "HEAD", "POST"]

    /// Whether a browser would send an `OPTIONS` before this request. A header the app itself adds (the cookie, the
    /// origin, the fetch metadata) is not the page's and does not count.
    static func needsPreflight(_ request: Request) -> Bool {
        if !safelistedMethods.contains(request.method) { return true }
        return request.headers.contains { !isSafelisted($0.key, value: $0.value) }
    }

    /// The headers the preflight must name, lowercased and sorted as browsers send them.
    static func preflightHeaderNames(_ request: Request) -> [String] {
        request.headers
            .filter { !isSafelisted($0.key, value: $0.value) }
            .map { $0.key.lowercased() }
            .sorted()
    }

    /// A header a preflight doesn't have to name: one the app adds itself, or one the CORS rules let through.
    private static func isSafelisted(_ name: String, value: String) -> Bool {
        let key = name.lowercased()
        if ["cookie", "origin", "referer"].contains(key) || key.hasPrefix("sec-") || key.hasPrefix("proxy-") {
            return true
        }
        guard safelistedHeaders.contains(key) else { return false }
        guard key == "content-type" else { return true }
        let type = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        return safelistedContentTypes.contains(type.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func preflightRequest(for request: Request) -> Request {
        var headers = ["Access-Control-Request-Method": request.method]
        let names = preflightHeaderNames(request)
        if !names.isEmpty { headers["Access-Control-Request-Headers"] = names.joined(separator: ", ") }
        if request.credentials.sendsCookies, let cookie = request.headers.first(where: { $0.key.lowercased() == "cookie" })?.value {
            headers["Cookie"] = cookie
        }
        return Request(url: request.url, method: "OPTIONS", headers: headers, credentials: request.credentials)
    }

    // MARK: - The reply

    /// Whether this reply lets the site read the body. A `*` is a reply to the world, and the world cannot have the
    /// caller's cookies: with credentials, the helper must name the origin and say credentials are allowed.
    static func allowsRead(_ response: Response, for request: Request, as identity: Identity) -> Bool {
        if identity.isWebExtension { return true }
        guard let allowed = response.header("access-control-allow-origin") else { return false }
        let origin = identity.origin
        let star = allowed.trimmingCharacters(in: .whitespaces) == "*"
        let named = allowed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(origin) == .orderedSame
        if request.credentials.sendsCookies {
            return named && response.header("access-control-allow-credentials")?.lowercased() == "true"
        }
        return star || named
    }

    /// Whether the preflight lets the request it is for through.
    static func allowsPreflight(_ response: Response, for request: Request, as identity: Identity) -> Bool {
        if identity.isWebExtension { return true }
        guard (200..<300).contains(response.status) else { return false }
        guard allowsRead(response, for: request, as: identity) else { return false }
        let methods = list(response.header("access-control-allow-methods"))
        guard methods.contains("*") || methods.contains(request.method.lowercased()) else { return false }
        let allowed = list(response.header("access-control-allow-headers"))
        guard !allowed.isEmpty || preflightHeaderNames(request).isEmpty else { return false }
        return preflightHeaderNames(request).allSatisfy { allowed.contains("*") || allowed.contains($0) }
    }

    private static func list(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    private static func requireRead(_ response: Response, for request: Request, as identity: Identity) throws {
        guard allowsRead(response, for: request, as: identity) else {
            throw Failure.cors("the helper's reply does not allow \(identity.origin)")
        }
    }

    private static func requirePreflight(_ response: Response, for request: Request, as identity: Identity) throws {
        guard allowsPreflight(response, for: request, as: identity) else {
            throw Failure.cors("the helper did not allow the preflight for \(request.method) \(request.url.path)")
        }
    }

    // MARK: - Building the request

    /// The `URLRequest` one of these becomes: the caller's own `Origin`, its fetch metadata, and no cookie handling
    /// of the session's own — the profile's cookies are the caller's to pass.
    static func urlRequest(for request: Request, as identity: Identity) -> URLRequest {
        var built = URLRequest(url: request.url)
        built.httpMethod = request.method
        built.httpBody = request.body
        built.timeoutInterval = 30
        built.cachePolicy = .reloadIgnoringLocalCacheData
        built.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            let key = name.lowercased()
            if ["host", "content-length", "connection", "transfer-encoding", "upgrade", "keep-alive",
                "origin", "referer"].contains(key) { continue }
            built.setValue(value, forHTTPHeaderField: name)
        }
        built.setValue(identity.origin, forHTTPHeaderField: "Origin")
        built.setValue(identity.isWebExtension ? "none" : "cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        built.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        built.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        if case .site(let origin) = identity {
            built.setValue(origin.hasSuffix("/") ? origin : origin + "/", forHTTPHeaderField: "Referer")
        }
        return built
    }

    /// The most a helper's answer may be, the same as an extension read.
    static let responseLimit = 32 * 1024 * 1024

    private static let defaultTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Nothing is followed: a hop is another origin, and another CORS decision this door cannot make for the
        // helper. A redirect that stays on this Mac is refused by `send` with its own words.
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    /// Refuses every redirect. `URLSession` would otherwise follow one to wherever it points, LAN address and all,
    /// and hand back that answer as if the helper had given it.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func response(_ data: Data, _ raw: URLResponse, for url: URL) throws -> Response {
        guard let http = raw as? HTTPURLResponse else { throw Failure.noAnswer }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return Response(url: http.url ?? url, status: http.statusCode, headers: headers, body: data)
    }

    private static func response(_ pair: (Data, URLResponse), for url: URL) throws -> Response {
        try response(pair.0, pair.1, for: url)
    }

    /// The cookies WebKit would have sent to the helper from this store, for the moment the call is made. A site's
    /// call is cross-site, so it leaves out SameSite cookies, as WebKit would.
    @MainActor
    static func cookies(for url: URL, in store: WKWebsiteDataStore?, crossSite: Bool) async -> String? {
        guard let store = store?.httpCookieStore else { return nil }
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let matching = sendable(all, to: url, crossSite: crossSite)
        return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    static func sendable(_ cookies: [HTTPCookie], to url: URL, crossSite: Bool, now: Date = Date()) -> [HTTPCookie] {
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
            if crossSite, cookie.sameSitePolicy == .sameSiteLax || cookie.sameSitePolicy == .sameSiteStrict { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
            return path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
        }
    }

    /// Cookies the helper set, kept where WebKit keeps the profile's, so the next call sends them back.
    @MainActor
    static func store(_ answer: Response, for url: URL, in store: WKWebsiteDataStore?) async {
        guard let value = answer.header("set-cookie"), let store = store?.httpCookieStore else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: url) {
            await store.setCookie(cookie)
        }
    }
}

/// What an extension is told when the door refuses: a sentence, not Swift's own `Zigzag.LocalReceivers.Failure
/// error 1.` The page door turns every failure into the same `TypeError` WebKit's block would have given it.
extension LocalReceivers.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notLoopback: return "That address isn't on this Mac."
        case .noAnswer: return "Nothing answered at that address."
        case .cors(let reason), .refused(let reason): return "\(reason.prefix(1).uppercased())\(reason.dropFirst())."
        case .tooLarge: return "The answer was too large to read."
        case .blockedPort(let port): return "Port \(port) is blocked, as browsers block it."
        }
    }
}
