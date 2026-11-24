import Foundation
import Testing
@testable import Zigzag

/// Zigzag's MCP server, below the browser: reading HTTP, the checks every request passes, JSON-RPC and the protocol
/// versions, and a real server on this Mac's loopback.
struct MCPServerTests {
    nonisolated struct StubRunner: MCPToolRunner {
        var tools: [JSON] { [["name": "echo", "inputSchema": ["type": "object"]]] }
        func call(_ name: String, arguments: [String: JSON], client: MCPClient) async -> MCPToolResult {
            .data(["name": .string(name), "arguments": .object(arguments), "client": .string(client.name ?? "")])
        }
    }

    static let token = "k" + String(repeating: "x", count: 42)

    private func endpoint() -> MCPEndpoint { MCPEndpoint(token: Self.token, runner: StubRunner(), serverVersion: "1.0") }

    private func post(_ body: JSON, headers: [String: String] = [:], auth: Bool = true) -> HTTPRequest {
        var all = ["host": "127.0.0.1:39217", "content-type": "application/json", "accept": "application/json, text/event-stream"]
        if auth { all["authorization"] = "Bearer \(Self.token)" }
        for (k, v) in headers { all[k.lowercased()] = v }
        return HTTPRequest(method: "POST", path: "/mcp", headers: all, body: body.data)
    }

    private func body(_ response: HTTPResponse) -> JSON { JSON.parse(response.body) ?? .null }

    private static let initialize: JSON = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                           "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Test App", "version": "1"]]]

    // MARK: JSON

    @Test func jsonKeepsWholeNumbersWhole() {
        let value = JSON.parse(Data(#"{"id":7,"x":1.5,"t":true,"n":null,"a":[1,"b"]}"#.utf8))
        #expect(value?["id"] == .int(7))
        #expect(value?["x"] == .double(1.5))
        #expect(value?["t"] == .bool(true))
        #expect(value?["n"] == .null)
        #expect(value?["a"] == [1, "b"])
        #expect(JSON.int(7).text == "7")
        #expect(JSON.parse(Data("{nope".utf8)) == nil)
    }

    // MARK: HTTP

    @Test func readsRequestsOneAfterAnother() {
        var reader = HTTPRequestReader()
        reader.append(Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        guard case .request(let first) = reader.next() else { Issue.record("no first request"); return }
        #expect(first.method == "POST" && first.path == "/mcp" && first.body == Data("{}".utf8) && first.header("HOST") == "127.0.0.1")
        guard case .request(let second) = reader.next() else { Issue.record("no second request"); return }
        #expect(second.method == "GET" && second.body.isEmpty)
        #expect(reader.next() == .incomplete)
    }

    @Test func waitsForTheWholeBody() {
        var reader = HTTPRequestReader()
        reader.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8))
        #expect(reader.next() == .incomplete)
        reader.append(Data("67890".utf8))
        guard case .request(let request) = reader.next() else { Issue.record("no request"); return }
        #expect(request.body == Data("1234567890".utf8))
    }

    @Test func readsChunkedBodies() {
        var reader = HTTPRequestReader()
        reader.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8))
        guard case .request(let request) = reader.next() else { Issue.record("no request"); return }
        #expect(String(decoding: request.body, as: UTF8.self) == "Wikipedia")
    }

    @Test func refusesWhatIsntARequest() {
        var bad = HTTPRequestReader()
        bad.append(Data("hello there\r\n\r\n".utf8))
        #expect(bad.next() == .failure(400))
        var big = HTTPRequestReader()
        big.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: \(HTTPRequestReader.maxBodyBytes + 1)\r\n\r\n".utf8))
        #expect(big.next() == .failure(413))
        var negative = HTTPRequestReader()
        negative.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        #expect(negative.next() == .failure(400))
        var endless = HTTPRequestReader()
        endless.append(Data(String(repeating: "a", count: HTTPRequestReader.maxHeaderBytes + 1).utf8))
        #expect(endless.next() == .failure(431))
    }

    @Test func responsesSayTheirLength() {
        let text = String(decoding: HTTPResponse.json(200, ["ok": true]).serialized(keepAlive: true), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 11\r\n") && text.contains("Content-Type: application/json\r\n") && text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    // MARK: Access

    @Test func onlyThisMacsOriginsAndHosts() {
        #expect(MCPAccess.originAllowed(nil))
        for origin in ["http://127.0.0.1:39217", "http://localhost:3000", "https://localhost", "http://[::1]:8080"] { #expect(MCPAccess.originAllowed(origin), "\(origin)") }
        for origin in ["https://evil.example", "http://127.0.0.1.evil.example", "null", "file://", "http://localhost.evil.example:39217", ""] {
            #expect(!MCPAccess.originAllowed(origin), "\(origin)")
        }
        for host in ["127.0.0.1:39217", "localhost:39217", "localhost", "[::1]:39217"] { #expect(MCPAccess.hostAllowed(host), "\(host)") }
        for host in ["evil.example:39217", "192.168.1.2:39217", "0.0.0.0:39217"] { #expect(!MCPAccess.hostAllowed(host), "\(host)") }
        #expect(!MCPAccess.hostAllowed(nil))
    }

    @Test func theKeyMustMatch() {
        #expect(MCPAccess.authorized("Bearer \(Self.token)", token: Self.token))
        #expect(MCPAccess.authorized("bearer  \(Self.token) ", token: Self.token))
        #expect(!MCPAccess.authorized("Bearer \(Self.token)x", token: Self.token))
        #expect(!MCPAccess.authorized("Bearer \(Self.token.dropLast())", token: Self.token))
        #expect(!MCPAccess.authorized("Basic \(Self.token)", token: Self.token))
        #expect(!MCPAccess.authorized(nil, token: Self.token))
        #expect(!MCPAccess.authorized("Bearer ", token: ""))
        let a = MCPAccess.newToken(), b = MCPAccess.newToken()
        #expect(a != b && a.count >= 43 && a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(MCPAccess.decodedHeader("=?base64?" + Data("é tool".utf8).base64EncodedString() + "?=") == "é tool")
        #expect(MCPAccess.decodedHeader("plain") == "plain")
    }

    @Test func refusedWithoutTheKeyFromAPageOrOffThePath() async {
        let endpoint = endpoint()
        let noKey = await endpoint.handle(post(Self.initialize, auth: false))
        #expect(noKey.status == 401 && noKey.header("WWW-Authenticate") == "Bearer")
        let page = await endpoint.handle(post(Self.initialize, headers: ["Origin": "https://evil.example"]))
        #expect(page.status == 403)
        let rebound = await endpoint.handle(post(Self.initialize, headers: ["Host": "evil.example:39217"]))
        #expect(rebound.status == 403)
        var elsewhere = post(Self.initialize)
        elsewhere.path = "/other"
        #expect(await endpoint.handle(elsewhere).status == 404)
        var get = post(Self.initialize)
        get.method = "GET"
        let stream = await endpoint.handle(get)
        #expect(stream.status == 405 && stream.header("Allow") == "POST")
    }

    @Test func keyFileIsForYouAlone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MCPKeyFile.token(at: url, creating: false) == nil)
        let first = try #require(MCPKeyFile.token(at: url, creating: true))
        #expect(MCPKeyFile.token(at: url, creating: true) == first)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let second = try #require(MCPKeyFile.reset(at: url))
        #expect(second != first && MCPKeyFile.token(at: url, creating: false) == second)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(after?.intValue == 0o600)
    }

    // MARK: JSON-RPC, versions before 2026-07-28

    @Test func initializeAgreesOnAVersionAndStartsASession() async throws {
        let endpoint = endpoint()
        let response = await endpoint.handle(post(Self.initialize))
        #expect(response.status == 200)
        let result = try #require(body(response)["result"])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["serverInfo"]?["name"] == "zigzag")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(body(response)["id"] == 1)
        let session = try #require(response.header("Mcp-Session-Id"))
        #expect(endpoint.sessionCount == 1)
        // A version Zigzag doesn't know gets its newest.
        var future = Self.initialize.object!
        future["params"] = ["protocolVersion": "2099-01-01", "capabilities": [:], "clientInfo": ["name": "x", "version": "1"]]
        #expect(body(await endpoint.handle(post(.object(future))))["result"]?["protocolVersion"] == .string(MCPVersion.legacy[0]))

        // Then: initialized is taken quietly, tools are listed and called as that app.
        let headers = ["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-06-18"]
        #expect(await endpoint.handle(post(["jsonrpc": "2.0", "method": "notifications/initialized"], headers: headers)).status == 202)
        let list = await endpoint.handle(post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: headers))
        #expect(body(list)["result"]?["tools"]?.array?.first?["name"] == "echo")
        let call = await endpoint.handle(post(["jsonrpc": "2.0", "id": "c", "method": "tools/call", "params": ["name": "echo", "arguments": ["a": 1]]], headers: headers))
        #expect(body(call)["id"] == "c")
        #expect(body(call)["result"]?["structuredContent"]?["client"] == "Test App")
        #expect(body(call)["result"]?["content"]?.array?.first?["type"] == "text")
        #expect(await endpoint.handle(post(["jsonrpc": "2.0", "id": 3, "method": "ping"], headers: headers)).status == 200)
    }

    @Test func clearErrorsForBadMessages() async throws {
        let endpoint = endpoint()
        let session = try #require(await endpoint.handle(post(Self.initialize)).header("Mcp-Session-Id"))
        let headers = ["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-06-18"]
        let notJSON = HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "localhost", "authorization": "Bearer \(Self.token)"], body: Data("{oops".utf8))
        let parse = await endpoint.handle(notJSON)
        #expect(parse.status == 400 && body(parse)["error"]?["code"] == .int(RPCError.parse))
        let batch = await endpoint.handle(post([Self.initialize]))
        #expect(batch.status == 400 && body(batch)["error"]?["code"] == .int(RPCError.invalidRequest))
        let version = await endpoint.handle(post(["jsonrpc": "1.0", "id": 1, "method": "ping"]))
        #expect(body(version)["error"]?["code"] == .int(RPCError.invalidRequest))
        let unknown = await endpoint.handle(post(["jsonrpc": "2.0", "id": 4, "method": "resources/list"], headers: headers))
        #expect(body(unknown)["error"]?["code"] == .int(RPCError.methodNotFound) && body(unknown)["id"] == 4)
        let noTool = await endpoint.handle(post(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm_rf"]], headers: headers))
        #expect(body(noTool)["error"]?["code"] == .int(RPCError.invalidParams))
        let badArgs = await endpoint.handle(post(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "echo", "arguments": [1]]], headers: headers))
        #expect(body(badArgs)["error"]?["code"] == .int(RPCError.invalidParams))
        let badID = await endpoint.handle(post(["jsonrpc": "2.0", "id": [1], "method": "ping"]))
        #expect(badID.status == 400)
        let type = await endpoint.handle(post(Self.initialize, headers: ["Content-Type": "text/plain"]))
        #expect(type.status == 415)
        let badHeader = await endpoint.handle(post(["jsonrpc": "2.0", "id": 7, "method": "ping"], headers: ["MCP-Protocol-Version": "1999-01-01"]))
        #expect(badHeader.status == 400 && body(badHeader)["error"]?["code"] == .int(RPCError.unsupportedVersion))
    }

    @Test func anEndedSessionSendsTheAppBackToInitialize() async throws {
        let endpoint = endpoint()
        let ended = Box()
        endpoint.onSessionEnded = { client in ended.add(client.name ?? "") }
        let session = try #require(await endpoint.handle(post(Self.initialize)).header("Mcp-Session-Id"))
        endpoint.endSession(of: MCPClient(key: session, name: "Test App"))
        #expect(ended.names == ["Test App"])
        let gone = await endpoint.handle(post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: ["Mcp-Session-Id": session]))
        #expect(gone.status == 404 && body(gone)["error"]?["code"] == .int(RPCError.sessionNotFound))
        // A new key ends every session, and the old key stops working.
        let again = try #require(await endpoint.handle(post(Self.initialize)).header("Mcp-Session-Id"))
        endpoint.setToken("new" + Self.token)
        #expect(ended.names.count == 2 && endpoint.sessionCount == 0)
        #expect(await endpoint.handle(post(["jsonrpc": "2.0", "id": 3, "method": "ping"], headers: ["Mcp-Session-Id": again])).status == 401)
        // DELETE ends one.
        var delete = post(Self.initialize, auth: false)
        delete.headers["authorization"] = "Bearer new\(Self.token)"
        let third = try #require(await endpoint.handle(delete).header("Mcp-Session-Id"))
        delete.method = "DELETE"
        delete.headers["mcp-session-id"] = third
        #expect(await endpoint.handle(delete).status == 200)
        #expect(endpoint.sessionCount == 0)
    }

    /// Stop in the browser: every session ends and nothing gets through after, with a session, the key, a new key or none.
    @Test func stopRefusesEverythingAfter() async throws {
        let endpoint = endpoint()
        let session = try #require(await endpoint.handle(post(Self.initialize)).header("Mcp-Session-Id"))
        let list: JSON = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        let inSession = ["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-06-18"]
        #expect(await endpoint.handle(post(list, headers: inSession)).status == 200)
        // No session is no session: a request without one isn't let through as nobody in particular.
        #expect(await endpoint.handle(post(list)).status == 400)
        endpoint.refuseAll()
        #expect(endpoint.refusesAll && endpoint.sessionCount == 0)
        #expect(await endpoint.handle(post(list, headers: inSession)).status == 403)
        #expect(await endpoint.handle(post(list)).status == 403)
        #expect(await endpoint.handle(post(Self.initialize)).status == 403)
        #expect(await endpoint.handle(post(Self.initialize, auth: false)).status == 403)
        #expect(await endpoint.handle(modern("ping")).status == 403)
        endpoint.setToken(Self.token)
        #expect(await endpoint.handle(post(Self.initialize)).status == 403)
    }

    // MARK: 2026-07-28: everything in each request

    private func modern(_ method: String, id: JSON = 1, params: [String: JSON] = [:], version: String = "2026-07-28",
                        headers: [String: String]? = nil) -> HTTPRequest {
        var params = params
        params["_meta"] = ["io.modelcontextprotocol/protocolVersion": .string(version), "io.modelcontextprotocol/clientInfo": ["name": "New App", "version": "2"],
                           "io.modelcontextprotocol/clientCapabilities": [:]]
        var all = ["MCP-Protocol-Version": version, "Mcp-Method": method]
        if let name = params["name"]?.string { all["Mcp-Name"] = name }
        return post(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": .object(params)], headers: headers ?? all)
    }

    @Test func modernRequestsCarryTheirVersion() async {
        let endpoint = endpoint()
        let discover = body(await endpoint.handle(modern("server/discover")))["result"]
        #expect(discover?["supportedVersions"]?.array?.contains("2026-07-28") == true)
        #expect(discover?["supportedVersions"]?.array?.contains("2025-11-25") == true)
        #expect(discover?["resultType"] == "complete")
        #expect(discover?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "zigzag")
        let list = body(await endpoint.handle(modern("tools/list")))["result"]
        #expect(list?["tools"]?.array?.count == 1 && list?["resultType"] == "complete" && list?["ttlMs"] != nil)
        let call = body(await endpoint.handle(modern("tools/call", params: ["name": "echo", "arguments": [:]])))["result"]
        #expect(call?["structuredContent"]?["client"] == "New App" && call?["resultType"] == "complete")
        #expect(endpoint.sessionCount == 0)
    }

    /// Only an accepted request counts as an app at work.
    @Test func everyRequestTakenUpCounts() async throws {
        let refused = endpoint()
        _ = await refused.handle(post(Self.initialize, auth: false))
        _ = await refused.handle(post(Self.initialize, headers: ["origin": "https://evil.example"]))
        _ = await refused.handle(post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: ["mcp-session-id": "gone"]))
        _ = await refused.handle(modern("tools/list", headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call"]))
        var goodbye = post([:], headers: ["mcp-session-id": "gone"])
        goodbye.method = "DELETE"
        _ = await refused.handle(goodbye)
        #expect(refused.lastRequest == nil)

        let newer = endpoint()
        let before = Date()
        _ = await newer.handle(modern("tools/list"))
        #expect(try #require(newer.lastRequest) >= before)

        let older = endpoint()
        let session = try #require(await older.handle(post(Self.initialize)).headers.first { $0.0 == "Mcp-Session-Id" }?.1)
        let opened = try #require(older.lastRequest)
        try await Task.sleep(for: .milliseconds(20))
        _ = await older.handle(post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: ["mcp-session-id": session]))
        #expect(try #require(older.lastRequest) > opened)
    }

    @Test func modernHeadersMustMatchTheBody() async {
        let endpoint = endpoint()
        let noHeaders = await endpoint.handle(modern("tools/list", headers: [:]))
        #expect(noHeaders.status == 400 && body(noHeaders)["error"]?["code"] == .int(RPCError.headerMismatch))
        let wrongMethod = await endpoint.handle(modern("tools/list", headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call"]))
        #expect(body(wrongMethod)["error"]?["code"] == .int(RPCError.headerMismatch))
        let wrongName = await endpoint.handle(modern("tools/call", params: ["name": "echo"],
                                                     headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call", "Mcp-Name": "other"]))
        #expect(body(wrongName)["error"]?["code"] == .int(RPCError.headerMismatch))
        let unsupported = await endpoint.handle(modern("tools/list", version: "2030-01-01"))
        #expect(unsupported.status == 400 && body(unsupported)["error"]?["code"] == .int(RPCError.unsupportedVersion))
        #expect(body(unsupported)["error"]?["data"]?["requested"] == "2030-01-01")
        let unknown = await endpoint.handle(modern("prompts/list"))
        #expect(unknown.status == 404 && body(unknown)["error"]?["code"] == .int(RPCError.methodNotFound))
        // A legacy request that claims the new version in its header only.
        let mixed = await endpoint.handle(post(["jsonrpc": "2.0", "id": 9, "method": "tools/list"], headers: ["MCP-Protocol-Version": "2026-07-28"]))
        #expect(mixed.status == 400 && body(mixed)["error"]?["code"] == .int(RPCError.headerMismatch))
    }

    @Test func aToolThatHangsIsGivenUp() async {
        let value = await MCPEndpoint.withTimeout(0.05) { () async -> Int in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        #expect(value == nil)
        #expect(await MCPEndpoint.withTimeout(2) { 5 } == 5)
    }

    // MARK: A real server

    @Test func servesOnLoopbackWithTheKeyOnly() async throws {
        let server = MCPServer(port: 0, endpoint: endpoint())
        server.start()
        defer { server.stop() }
        let port = try #require(await server.waitUntilReady())
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
        func send(_ message: JSON, key: String?, session: String? = nil) async throws -> (HTTPURLResponse, JSON) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = message.data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id"); request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try #require(response as? HTTPURLResponse), JSON.parse(data) ?? .null)
        }
        let (refused, _) = try await send(Self.initialize, key: nil)
        #expect(refused.statusCode == 401)
        let (wrong, _) = try await send(Self.initialize, key: "nope")
        #expect(wrong.statusCode == 401)
        let (ok, initialized) = try await send(Self.initialize, key: Self.token)
        #expect(ok.statusCode == 200 && initialized["result"]?["protocolVersion"] == "2025-06-18")
        let session = try #require(ok.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (listed, tools) = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], key: Self.token, session: session)
        #expect(listed.statusCode == 200 && tools["result"]?["tools"]?.array?.first?["name"] == "echo")
    }

    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ name: String) { lock.withLock { all.append(name) } }
        var names: [String] { lock.withLock { all } }
    }
}

// MARK: Connections that don't send the key

extension MCPServerTests {
    /// A raw TCP connection to the test server, with a read timeout.
    nonisolated final class RawConnection {
        let socket: Int32

        init?(port: UInt16) {
            socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { close(socket); return nil }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        deinit { close(socket) }

        func send(_ text: String) {
            _ = Array(text.utf8).withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
        }

        /// Everything until the server closes, or nil on timeout.
        func readToEnd() -> String? {
            var all = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(socket, &buffer, buffer.count, 0)
                if count == 0 { return String(decoding: all, as: UTF8.self) }
                if count < 0 { return nil }
                all.append(contentsOf: buffer[0..<count])
            }
        }
    }

    private static func request(key: String?) -> String {
        let body = Self.initialize.text
        var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let key { head += "Authorization: Bearer \(key)\r\n" }
        return head + "\r\n" + body
    }

    @Test func refusedConnectionsAreClosed() async throws {
        let server = MCPServer(port: 0, endpoint: endpoint())
        server.start()
        defer { server.stop() }
        let port = try #require(await server.waitUntilReady())
        let refused = try #require(RawConnection(port: port))
        refused.send(Self.request(key: nil))
        let answer = try #require(refused.readToEnd())
        #expect(answer.hasPrefix("HTTP/1.1 401") && answer.contains("Connection: close"))
        let wrongPath = try #require(RawConnection(port: port))
        wrongPath.send("POST /other HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(Self.token)\r\nContent-Length: 0\r\n\r\n")
        #expect(try #require(wrongPath.readToEnd()).hasPrefix("HTTP/1.1 404"))
        // With the key, the connection is kept alive.
        let kept = try #require(RawConnection(port: port))
        kept.send(Self.request(key: Self.token))
        #expect(kept.readToEnd() == nil)
    }

    @Test func connectionsWithoutTheKeyCantFillTheServer() async throws {
        let server = MCPServer(port: 0, endpoint: endpoint())
        server.start()
        defer { server.stop() }
        let port = try #require(await server.waitUntilReady())
        var idle: [RawConnection] = []
        for _ in 0..<MCPServer.maxKeylessConnections {
            idle.append(try #require(RawConnection(port: port)))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // One more evicts the oldest unkeyed connection; a keyed app still gets in.
        let app = try #require(RawConnection(port: port))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(idle[0].readToEnd() == "")
        app.send(Self.request(key: Self.token))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(app.socket, &buffer, buffer.count, 0)
        #expect(count > 0 && String(decoding: buffer[0..<max(count, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200"))
    }

    /// The first response, without waiting for close.
    private static func firstAnswer(_ connection: RawConnection) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(connection.socket, &buffer, buffer.count, 0)
        return String(decoding: buffer[0..<max(count, 0)], as: UTF8.self)
    }

    /// A 404 to a keyed request (ended session, unknown method) keeps the connection alive.
    @Test func aNotFoundWithTheKeyKeepsTheConnection() async throws {
        let server = MCPServer(port: 0, endpoint: endpoint())
        server.start()
        defer { server.stop() }
        let port = try #require(await server.waitUntilReady())
        let app = try #require(RawConnection(port: port))
        let body = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        app.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(Self.token)\r\n"
                 + "Mcp-Session-Id: ended\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        let answer = Self.firstAnswer(app)
        #expect(answer.hasPrefix("HTTP/1.1 404") && !answer.contains("Connection: close"))
        #expect(app.readToEnd() == nil)
    }

    nonisolated struct SlowRunner: MCPToolRunner {
        var tools: [JSON] { [["name": "slow", "inputSchema": ["type": "object"]]] }
        func call(_ name: String, arguments: [String: JSON], client: MCPClient) async -> MCPToolResult {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return .text("done")
        }
    }

    /// A keyed connection counts as keyed from acceptance, so unkeyed ones can't evict it mid-call.
    @Test func aLongToolCallIsNeverPushedOut() async throws {
        let server = MCPServer(port: 0, endpoint: MCPEndpoint(token: Self.token, runner: SlowRunner(), serverVersion: "1.0"))
        server.start()
        defer { server.stop() }
        let port = try #require(await server.waitUntilReady())
        let app = try #require(RawConnection(port: port))
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        app.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(Self.token)\r\n"
                 + "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: slow\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        try await Task.sleep(nanoseconds: 200_000_000)
        var idle: [RawConnection] = []
        for _ in 0...MCPServer.maxKeylessConnections {
            idle.append(try #require(RawConnection(port: port)))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(Self.firstAnswer(app).hasPrefix("HTTP/1.1 200"))
    }

    @Test func aTakenPortSaysSoAndReplacesTheKey() async throws {
        let holder = MCPServer(port: 0, endpoint: endpoint())
        holder.start()
        defer { holder.stop() }
        let port = try #require(await holder.waitUntilReady())
        let second = MCPServer(port: port, endpoint: endpoint())
        let states = Box()
        second.onState = { state in
            if case .failed(_, let inUse) = state { states.add(inUse ? "in use" : "failed") }
        }
        second.start()
        defer { second.stop() }
        #expect(await second.waitUntilReady() == nil)
        #expect(states.names == ["in use"])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let suite = "mcp-key-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = try #require(MCPKeyFile.token(at: file, creating: true))
        let endpoint = endpoint()
        #expect(MCPService.replaceKeyForBusyPort(endpoint, keyFile: file, defaults: defaults))
        let new = try #require(MCPKeyFile.token(at: file, creating: false))
        #expect(new != old)
        #expect(await endpoint.handle(post(Self.initialize)).status == 401)
        // Still taken next launch: the new key was never handed out, so it stays.
        #expect(!MCPService.replaceKeyForBusyPort(endpoint, keyFile: file, defaults: defaults))
        #expect(MCPKeyFile.token(at: file, creating: false) == new)
        // Once copied for an app, a taken port replaces it again.
        MCPService.noteKeyHandedOut(defaults: defaults)
        #expect(MCPService.replaceKeyForBusyPort(endpoint, keyFile: file, defaults: defaults))
        #expect(MCPKeyFile.token(at: file, creating: false) != new)
    }
}
