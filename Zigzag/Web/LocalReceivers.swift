import Foundation

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
    }

    /// The one thing a caller may replace, so the policy can be tested without a helper running.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Makes the request for `identity`, with the preflight a browser would send first, and refuses an answer the
    /// helper's CORS reply does not cover.
    static func send(_ request: Request, as identity: Identity,
                     transport: Transport? = nil) async throws -> Response {
        guard isLoopback(request.url) else { throw Failure.notLoopback }
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
        return try await URLSession(configuration: configuration).data(for: request)
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
}
