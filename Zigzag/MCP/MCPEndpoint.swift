import Foundation
import Security

/// The protocol versions Zigzag speaks. The newest (2026-07-28) has no handshake: each request says its version in
/// `_meta`. The older ones start with `initialize`, which picks one of them, and are what most apps send today.
nonisolated enum MCPVersion {
    static let modern = ["2026-07-28"]
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static var all: [String] { modern + legacy }

    /// `initialize`'s answer to the version an app asks for: that one if Zigzag speaks it, else its newest.
    static func negotiate(_ requested: String?) -> String {
        guard let requested, legacy.contains(requested) else { return legacy[0] }
        return requested
    }
}

/// JSON-RPC's error codes, and MCP's own.
nonisolated enum RPCError {
    static let parse = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let sessionNotFound = -32001
    static let headerMismatch = -32020
    static let unsupportedVersion = -32022

    static func response(id: JSON?, code: Int, message: String, data: JSON? = nil) -> JSON {
        var error: [String: JSON] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        var object: [String: JSON] = ["jsonrpc": "2.0", "error": .object(error)]
        // A response to a request carries its id; one to something that couldn't be read has none.
        if let id { object["id"] = id }
        return .object(object)
    }
}

/// Who a request comes from: the app's own name (from `initialize`'s clientInfo, or each request's `_meta`) and the
/// key that ties its requests together (its session, or its name).
nonisolated struct MCPClient: Sendable, Hashable {
    let key: String
    let name: String?
}

/// What a tool gives back: text and pictures for the model, and the same as data where there is some.
nonisolated struct MCPToolResult: Sendable, Equatable {
    var content: [JSON]
    var structured: JSON?
    var isError = false

    static func text(_ text: String) -> MCPToolResult { MCPToolResult(content: [["type": "text", "text": .string(text)]]) }

    static func data(_ value: JSON) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": .string(value.text)]], structured: value)
    }

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": .string(message)]], isError: true)
    }

    var json: [String: JSON] {
        var object: [String: JSON] = ["content": .array(content)]
        if let structured { object["structuredContent"] = structured }
        if isError { object["isError"] = true }
        return object
    }
}

/// Runs the tools: the browser itself, or a stand-in in tests.
nonisolated protocol MCPToolRunner: Sendable {
    var tools: [JSON] { get }
    func call(_ name: String, arguments: [String: JSON], client: MCPClient) async -> MCPToolResult
}

/// The checks every request passes before anything reads it: from this Mac only, never from a web page, and with the key.
nonisolated enum MCPAccess {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// A Host or Origin's host name, without its port or scheme.
    static func hostName(of value: String) -> String? {
        var rest = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            return String(rest[...close])
        }
        if let colon = rest.lastIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            guard port.allSatisfy(\.isNumber) else { return nil }
            rest = String(rest[..<colon])
        }
        return rest.isEmpty ? nil : rest
    }

    /// A web page's request carries the page's Origin: anything but this Mac's own address is refused, so a site
    /// that renames itself to 127.0.0.1 (DNS rebinding) can't reach Zigzag. Apps send none.
    static func originAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard origin.lowercased().hasPrefix("http://") || origin.lowercased().hasPrefix("https://"),
              let host = hostName(of: origin) else { return false }
        return loopbackHosts.contains(host)
    }

    /// The address the request was sent to must be this Mac's own, by number or as localhost.
    static func hostAllowed(_ host: String?) -> Bool {
        guard let host, let name = hostName(of: host) else { return false }
        return loopbackHosts.contains(name)
    }

    /// `Authorization: Bearer <key>`, compared in constant time.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let given = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8), wanted = Array(token.utf8)
        var difference = UInt8(given.count == wanted.count ? 0 : 1)
        for i in 0..<wanted.count { difference |= wanted[i] ^ (i < given.count ? given[i] : 0) }
        return difference == 0
    }

    /// A new key: 32 random bytes, as URL-safe base64.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Mcp-Name may come base64-encoded, as `=?base64?…?=`, when the name isn't plain ASCII.
    static func decodedHeader(_ value: String) -> String {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="), value.count > 11 else { return value }
        let inner = String(value.dropFirst(9).dropLast(2))
        guard let data = Data(base64Encoded: inner), let text = String(data: data, encoding: .utf8) else { return value }
        return text
    }
}

/// Zigzag's MCP endpoint, POST /mcp, as the Streamable HTTP transport has it: every check, every message, and the
/// sessions apps on the older versions keep. Answers are plain JSON, one per request; Zigzag never starts a stream.
nonisolated final class MCPEndpoint: @unchecked Sendable {
    static let path = "/mcp"
    static let toolTimeout: TimeInterval = 60
    static let maxSessions = 32

    struct Session {
        var client: MCPClient
        var version: String
        var lastSeen: Date
    }

    private let lock = NSLock()
    private var token: String
    private var sessions: [String: Session] = [:]
    private let runner: MCPToolRunner
    private let serverVersion: String
    /// Told when a session ends (the app said goodbye, or a new key cut it off), with the session's client.
    var onSessionEnded: (@Sendable (MCPClient) -> Void)?

    init(token: String, runner: MCPToolRunner, serverVersion: String) {
        self.token = token
        self.runner = runner
        self.serverVersion = serverVersion
    }

    func setToken(_ new: String) {
        lock.lock()
        token = new
        let ended = sessions.values.map(\.client)
        sessions = [:]
        lock.unlock()
        ended.forEach { onSessionEnded?($0) }
    }

    /// Ends a client's session, as Stop in the browser does: its next request finds none, and it has to start over.
    func endSession(of client: MCPClient) {
        lock.lock()
        let removed = sessions.removeValue(forKey: client.key) != nil
        lock.unlock()
        if removed { onSessionEnded?(client) }
    }

    var sessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    private var currentToken: String {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    private var serverInfo: JSON { ["name": "zigzag", "title": "Zigzag", "version": .string(serverVersion)] }

    static let instructions = """
        Zigzag is the person's own web browser. Tabs are named by the id list_tabs gives; a tool given no id acts on \
        the tab in front of the person. Private windows, Zigzag's own pages (Settings, History), extension pages and \
        password fields are off-limits. A tab you use shows the person a bar with Stop: when a tool says control was \
        stopped, leave that tab alone and ask the person.
        """

    // MARK: Requests

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // From a web page (DNS rebinding) or sent to an address other than this Mac's: refused before anything else.
        guard MCPAccess.originAllowed(request.header("origin")), MCPAccess.hostAllowed(request.header("host")) else {
            return .json(403, RPCError.response(id: nil, code: RPCError.invalidRequest, message: "Forbidden: requests must come from this Mac, not a web page."))
        }
        guard request.path == Self.path else {
            return .json(404, RPCError.response(id: nil, code: RPCError.invalidRequest, message: "Not found. Zigzag's MCP endpoint is \(Self.path)."))
        }
        guard MCPAccess.authorized(request.header("authorization"), token: currentToken) else {
            return .json(401, RPCError.response(id: nil, code: RPCError.invalidRequest,
                                                message: "Unauthorized. Send the key from Zigzag's Settings › Automation as Authorization: Bearer <key>."),
                         headers: [("WWW-Authenticate", "Bearer")])
        }
        switch request.method {
        case "POST": return await post(request)
        case "DELETE":
            // An older app ending its session.
            guard let id = request.header("mcp-session-id") else { return .empty(405, headers: [("Allow", "POST")]) }
            let removed = lock.withLock { sessions.removeValue(forKey: id) }
            if let removed { onSessionEnded?(removed.client) }
            return removed == nil ? .json(404, RPCError.response(id: nil, code: RPCError.sessionNotFound, message: "Session not found.")) : .empty(200)
        default:
            // No stream for the server to talk first on: Zigzag only answers.
            return .empty(405, headers: [("Allow", "POST")])
        }
    }

    private func post(_ request: HTTPRequest) async -> HTTPResponse {
        if let type = request.header("content-type"), !type.lowercased().contains("application/json") {
            return .json(415, RPCError.response(id: nil, code: RPCError.invalidRequest, message: "Content-Type must be application/json."))
        }
        guard let message = JSON.parse(request.body) else {
            return .json(400, RPCError.response(id: nil, code: RPCError.parse, message: "Parse error: the body isn't JSON."))
        }
        guard case .object(let object) = message else {
            return .json(400, RPCError.response(id: nil, code: RPCError.invalidRequest, message: "Invalid request: send one JSON-RPC message, not a batch."))
        }
        guard object["jsonrpc"] == "2.0" else {
            return .json(400, RPCError.response(id: object["id"], code: RPCError.invalidRequest, message: "Invalid request: jsonrpc must be \"2.0\"."))
        }
        // A response or a notification ("initialized", "cancelled"): taken, with nothing to say back.
        guard let method = object["method"]?.string else {
            if object["result"] != nil || object["error"] != nil { return .empty(202) }
            return .json(400, RPCError.response(id: object["id"], code: RPCError.invalidRequest, message: "Invalid request: no method."))
        }
        guard let id = object["id"], id != .null else { return .empty(202) }
        guard id.string != nil || id.int != nil else {
            return .json(400, RPCError.response(id: nil, code: RPCError.invalidRequest, message: "Invalid request: id must be a string or a number."))
        }
        let params = object["params"]?.object ?? [:]
        if object["params"] != nil, object["params"]?.object == nil {
            return .json(400, RPCError.response(id: id, code: RPCError.invalidParams, message: "Invalid params: params must be an object."))
        }
        let meta = params["_meta"]?.object ?? [:]
        if let version = meta["io.modelcontextprotocol/protocolVersion"]?.string, !MCPVersion.legacy.contains(version) {
            return await modern(id: id, method: method, params: params, version: version, request: request)
        }
        return await legacy(id: id, method: method, params: params, request: request)
    }

    // MARK: 2026-07-28 and later: no handshake, everything in each request

    private func modern(id: JSON, method: String, params: [String: JSON], version: String, request: HTTPRequest) async -> HTTPResponse {
        guard MCPVersion.modern.contains(version) else {
            return .json(400, RPCError.response(id: id, code: RPCError.unsupportedVersion, message: "Unsupported protocol version",
                                                data: ["supported": .array(MCPVersion.all.map { .string($0) }), "requested": .string(version)]))
        }
        func mismatch(_ what: String) -> HTTPResponse {
            .json(400, RPCError.response(id: id, code: RPCError.headerMismatch, message: "Header mismatch: \(what)"))
        }
        guard request.header("mcp-protocol-version") == version else { return mismatch("MCP-Protocol-Version must be \(version), as in _meta.") }
        guard request.header("mcp-method") == method else { return mismatch("Mcp-Method must be \(method).") }
        if method == "tools/call" {
            guard let header = request.header("mcp-name"), MCPAccess.decodedHeader(header) == params["name"]?.string else {
                return mismatch("Mcp-Name must be the tool's name.")
            }
        }
        let info = params["_meta"]?["io.modelcontextprotocol/clientInfo"]
        let name = info?["name"]?.string
        let client = MCPClient(key: "app:" + (name ?? "unnamed"), name: name)
        func complete(_ result: [String: JSON]) -> HTTPResponse {
            var result = result
            result["resultType"] = "complete"
            var meta = result["_meta"]?.object ?? [:]
            meta["io.modelcontextprotocol/serverInfo"] = serverInfo
            result["_meta"] = .object(meta)
            return .json(200, ["jsonrpc": "2.0", "id": id, "result": .object(result)])
        }
        switch method {
        case "server/discover":
            return complete(["supportedVersions": .array(MCPVersion.all.map { .string($0) }), "capabilities": ["tools": [:]],
                             "instructions": .string(Self.instructions), "ttlMs": 0, "cacheScope": "private"])
        case "ping": return complete([:])
        case "tools/list": return complete(["tools": .array(runner.tools), "ttlMs": 0, "cacheScope": "private"])
        case "tools/call":
            switch await callTool(params, client: client) {
            case .success(let result): return complete(result.json)
            case .failure(let error): return .json(200, RPCError.response(id: id, code: error.code, message: error.message))
            }
        default:
            return .json(404, RPCError.response(id: id, code: RPCError.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    // MARK: 2025-03-26 to 2025-11-25: initialize, then a session

    private func legacy(id: JSON, method: String, params: [String: JSON], request: HTTPRequest) async -> HTTPResponse {
        let headerVersion = request.header("mcp-protocol-version")
        if let headerVersion, method != "initialize", !MCPVersion.legacy.contains(headerVersion) {
            if MCPVersion.modern.contains(headerVersion) {
                return .json(400, RPCError.response(id: id, code: RPCError.headerMismatch,
                                                    message: "Header mismatch: _meta has no io.modelcontextprotocol/protocolVersion for \(headerVersion)."))
            }
            return .json(400, RPCError.response(id: id, code: RPCError.unsupportedVersion, message: "Unsupported protocol version",
                                                data: ["supported": .array(MCPVersion.all.map { .string($0) }), "requested": .string(headerVersion)]))
        }
        if method == "initialize" {
            let version = MCPVersion.negotiate(params["protocolVersion"]?.string)
            let name = params["clientInfo"]?["name"]?.string
            let sessionID = UUID().uuidString.lowercased()
            let client = MCPClient(key: sessionID, name: name)
            let dropped: [MCPClient] = lock.withLock {
                sessions[sessionID] = Session(client: client, version: version, lastSeen: Date())
                guard sessions.count > Self.maxSessions, let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen }) else { return [] }
                sessions[oldest.key] = nil
                return [oldest.value.client]
            }
            dropped.forEach { onSessionEnded?($0) }
            let result: JSON = ["protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                                "serverInfo": serverInfo, "instructions": .string(Self.instructions)]
            return .json(200, ["jsonrpc": "2.0", "id": id, "result": result], headers: [("Mcp-Session-Id", sessionID)])
        }
        // The session the app was given; one that ended (Stop, a new key) sends it back to initialize.
        var client = MCPClient(key: "anonymous", name: nil)
        if let sessionID = request.header("mcp-session-id") {
            let session: Session? = lock.withLock {
                let found = sessions[sessionID]
                if found != nil { sessions[sessionID]?.lastSeen = Date() }
                return found
            }
            guard let session else {
                return .json(404, RPCError.response(id: id, code: RPCError.sessionNotFound, message: "Session not found. Initialize again."))
            }
            client = session.client
        }
        func result(_ value: [String: JSON]) -> HTTPResponse { .json(200, ["jsonrpc": "2.0", "id": id, "result": .object(value)]) }
        switch method {
        case "ping": return result([:])
        case "tools/list": return result(["tools": .array(runner.tools)])
        case "tools/call":
            switch await callTool(params, client: client) {
            case .success(let value): return result(value.json)
            case .failure(let error): return .json(200, RPCError.response(id: id, code: error.code, message: error.message))
            }
        default:
            return .json(200, RPCError.response(id: id, code: RPCError.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    // MARK: Tools

    struct CallError: Error {
        let code: Int
        let message: String
    }

    private func callTool(_ params: [String: JSON], client: MCPClient) async -> Result<MCPToolResult, CallError> {
        guard let name = params["name"]?.string else { return .failure(CallError(code: RPCError.invalidParams, message: "Invalid params: name is missing.")) }
        guard runner.tools.contains(where: { $0["name"]?.string == name }) else {
            return .failure(CallError(code: RPCError.invalidParams, message: "Unknown tool: \(name)"))
        }
        if let arguments = params["arguments"], arguments != .null, arguments.object == nil {
            return .failure(CallError(code: RPCError.invalidParams, message: "Invalid params: arguments must be an object."))
        }
        let arguments = params["arguments"]?.object ?? [:]
        let runner = self.runner
        let result = await Self.withTimeout(Self.toolTimeout) {
            await runner.call(name, arguments: arguments, client: client)
        }
        return .success(result ?? .error("\(name) took longer than \(Int(Self.toolTimeout)) seconds and was given up."))
    }

    /// The work's result, or nil once `seconds` pass first. The work isn't stopped; its answer just isn't waited for.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Lets only the first of several callers through.
nonisolated private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
