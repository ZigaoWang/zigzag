import Foundation
import WebKit

/// A site's own sign-in (HTTP Basic, Digest or NTLM), offered to extensions' webRequest.onAuthRequired listeners
/// before Zigzag's sheet asks you, as Chrome offers it. WebKit's webRequest only watches, so its onAuthRequired can't
/// answer: Zigzag asks the listeners itself (bridge.js), with Chrome's details, and signs in with what they give.
///
/// Only extensions that could answer in Chrome are asked: those with webRequest and webRequestAuthProvider (Manifest
/// V3) or webRequestBlocking (V2), and access to the address asking. Private tabs are never offered, as extensions
/// never see them. The first extension to give a name and password signs in, one that cancels cancels the sign-in,
/// and with no answer within a few seconds the sheet asks. What they give is never written down or logged.
@available(macOS 15.4, *)
@MainActor
final class BridgeWebRequest: BridgeNamespace {
    static let name = "webRequest"
    static let permission = "webRequest"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }
    static let event = "webRequest.onAuthRequired"
    /// How long extensions have to answer before the sheet asks. 1Password answers at once, from its own fill.
    static let timeout: Duration = .seconds(4)

    enum Answer: Equatable {
        case credentials(username: String, password: String)
        case cancel
        /// Nobody said: Zigzag's sheet asks.
        case none
    }

    /// One sign-in put to extensions, until one answers, all have said nothing, or time runs out.
    private final class Question {
        let details: [String: Any]
        var waiting: Set<String>
        /// Those it went to: one whose background was asleep gets it once it listens again.
        var sent: Set<String> = []
        let continuation: CheckedContinuation<Answer, Never>
        init(details: [String: Any], waiting: Set<String>, continuation: CheckedContinuation<Answer, Never>) {
            self.details = details
            self.waiting = waiting
            self.continuation = continuation
        }
    }

    private var questions: [String: Question] = [:]
    private var asked = 0
    /// Extensions that have listened for sign-ins this run, so one whose background went to sleep is woken to answer.
    private var heard: Set<String> = []
    /// How a question reaches an extension; tests stand in for the bridge's port.
    lazy var send: (String, [String: Any]) -> Void = { [unowned self] in host.bridge.emit(BridgeWebRequest.event, [$1], to: $0) }
    lazy var isListening: (String) -> Bool = { [unowned self] in host.bridge.isListened(BridgeWebRequest.event, by: $0) }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "authAnswer":
            // What the extension's listeners said: { authCredentials }, { cancel: true }, or nothing.
            guard let id = args.string(0) else { return nil }
            receive(Self.answer(from: args.object(1)), from: extensionID, for: id)
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    // MARK: Asking

    /// Asks the extensions that may answer this sign-in, and says what the first of them answered.
    func askForSignIn(_ challenge: SiteChallenge, tab: (any WKWebExtensionTab)?) async -> Answer {
        let contexts = host.contexts.filter { context in
            Self.mayAnswer(allows: { ExtensionBridge.allows($0, for: context) }, manifestVersion: context.webExtension.manifestVersion,
                           hasAccess: context.hasAccess(to: challenge.url))
        }
        let ids = contexts.map(\.uniqueIdentifier).filter { isListening($0) || heard.contains($0) }
        guard !ids.isEmpty else { return .none }
        // Asleep since it last listened: woken, and asked once it's listening again.
        for context in contexts where heard.contains(context.uniqueIdentifier) && !isListening(context.uniqueIdentifier) {
            context.loadBackgroundContent { _ in }
        }
        let hint = contexts.first.flatMap { context in tab.map { Self.tabHint($0, for: context) } }
        let answer = await ask(Self.details(challenge, tabHint: hint), of: ids)
        let names = ids.map { host.displayName(for: $0) }.joined(separator: ", ")
        switch answer {
        case .credentials: ExtensionLog.write("site sign-in for \(challenge.host): an extension answered (asked \(names))")
        case .cancel: ExtensionLog.write("site sign-in for \(challenge.host): an extension cancelled it (asked \(names))")
        case .none: ExtensionLog.write("site sign-in for \(challenge.host): no extension answered (asked \(names))")
        }
        return answer
    }

    /// Puts `details` to each extension, and waits for the first that answers, all of them saying nothing, or `timeout`.
    func ask(_ details: [String: Any], of extensionIDs: [String], timeout: Duration = BridgeWebRequest.timeout) async -> Answer {
        guard !extensionIDs.isEmpty else { return .none }
        asked += 1
        let id = "zigzag-auth-\(asked)"
        var details = details
        details["requestId"] = id
        return await withCheckedContinuation { continuation in
            let question = Question(details: details, waiting: Set(extensionIDs), continuation: continuation)
            questions[id] = question
            for extensionID in extensionIDs where isListening(extensionID) {
                question.sent.insert(extensionID)
                send(extensionID, details)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(id, with: .none)
            }
        }
    }

    private func receive(_ answer: Answer, from extensionID: String, for id: String) {
        guard let question = questions[id], question.waiting.remove(extensionID) != nil else { return }
        if answer != .none || question.waiting.isEmpty { finish(id, with: answer) }
    }

    private func finish(_ id: String, with answer: Answer) {
        questions.removeValue(forKey: id)?.continuation.resume(returning: answer)
    }

    /// Something listens again: a background that slept, now awake, gets the questions it's still owed.
    func startEvents() {
        for context in host.contexts where isListening(context.uniqueIdentifier) { heard.insert(context.uniqueIdentifier) }
        for question in questions.values {
            for extensionID in question.waiting.subtracting(question.sent) where isListening(extensionID) {
                question.sent.insert(extensionID)
                send(extensionID, question.details)
            }
        }
    }

    func release(_ extensionID: String) {
        heard.remove(extensionID)
        for (id, question) in questions where question.waiting.contains(extensionID) { receive(.none, from: extensionID, for: id) }
    }

    // MARK: Chrome's rules and shapes

    /// Whether an extension may answer sign-ins in Chrome: webRequest, and webRequestAuthProvider in Manifest V3 or
    /// webRequestBlocking in V2 (which also takes the newer permission), with access to the address asking.
    nonisolated static func mayAnswer(allows: (String) -> Bool, manifestVersion: Double, hasAccess: Bool) -> Bool {
        guard hasAccess, allows("webRequest") else { return false }
        if manifestVersion >= 3 { return allows("webRequestAuthProvider") }
        return allows("webRequestBlocking") || allows("webRequestAuthProvider")
    }

    /// What a listener said, as the bridge passes it on.
    static func answer(from reply: [String: Any]) -> Answer {
        if reply["cancel"] as? Bool == true { return .cancel }
        guard let credentials = reply["authCredentials"] as? [String: Any], let username = credentials.string("username") else { return .none }
        return .credentials(username: username, password: credentials.string("password") ?? "")
    }

    /// Chrome's details for onAuthRequired. Its tab ID is WebKit's, which only the extension's own tabs.query knows:
    /// the hint (`__zigzagTab`) lets the bridge find it there, and goes before any listener sees the details.
    nonisolated static func details(_ challenge: SiteChallenge, tabHint: [String: Any]?, now: Date = Date()) -> [String: Any] {
        var details: [String: Any] = [
            "url": challenge.url.absoluteString, "method": challenge.method, "frameId": 0, "parentFrameId": -1, "tabId": -1,
            "type": challenge.isMainFrame ? "main_frame" : "other", "timeStamp": now.timeIntervalSince1970 * 1000, "isProxy": false,
            "scheme": challenge.scheme, "challenger": ["host": challenge.host, "port": challenge.port],
            "statusCode": challenge.statusCode, "statusLine": challenge.statusLine,
            "responseHeaders": challenge.responseHeaders.map { ["name": $0.name, "value": $0.value] },
        ]
        if let realm = challenge.realm { details["realm"] = realm }
        if let tabHint { details["__zigzagTab"] = tabHint }
        return details
    }

    /// The asking tab as the extension's tabs.query lists it.
    private static func tabHint(_ tab: any WKWebExtensionTab, for context: WKWebExtensionContext) -> [String: Any] {
        var hint: [String: Any] = ["index": tab.indexInWindow?(for: context) ?? 0, "active": tab.isSelected?(for: context) ?? false]
        if let url = tab.url?(for: context) { hint["url"] = url.absoluteString }
        return hint
    }
}

/// A site asking for a name and password, as onAuthRequired describes it.
nonisolated struct SiteChallenge {
    var url: URL
    var method = "GET"
    /// Chrome's names: "basic", "digest", "ntlm".
    var scheme: String
    var realm: String?
    var host: String
    var port: Int
    var statusCode = 401
    var isMainFrame = true
    var responseHeaders: [(name: String, value: String)] = []

    var statusLine: String { "HTTP/1.1 \(statusCode) \(statusCode == 401 ? "Unauthorized" : HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)" }

    /// From WebKit's challenge: the address and status from the response that asked, the rest from its protection
    /// space. `pageURL`: where the asking tab is, to tell the page itself from something on it.
    init?(_ challenge: URLAuthenticationChallenge, pageURL: URL?) {
        let space = challenge.protectionSpace
        guard !space.isProxy() else { return nil }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic: scheme = "basic"
        case NSURLAuthenticationMethodHTTPDigest: scheme = "digest"
        case NSURLAuthenticationMethodNTLM: scheme = "ntlm"
        default: return nil
        }
        let response = challenge.failureResponse as? HTTPURLResponse
        let fallback = URL(string: "\(space.protocol ?? "https")://\(space.host):\(space.port)/")
        guard let url = response?.url ?? fallback else { return nil }
        self.url = url
        realm = space.realm
        host = space.host
        port = space.port
        statusCode = response?.statusCode ?? 401
        isMainFrame = pageURL == nil || pageURL == url
        responseHeaders = (response?.allHeaderFields ?? [:]).compactMap { key, value in
            guard let name = key as? String, let value = value as? String else { return nil }
            return (name, value)
        }.sorted { $0.name < $1.name }
    }

    init(url: URL, scheme: String, realm: String?, host: String, port: Int) {
        self.url = url
        self.scheme = scheme
        self.realm = realm
        self.host = host
        self.port = port
    }
}
