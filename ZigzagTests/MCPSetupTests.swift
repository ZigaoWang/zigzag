import Foundation
import Testing
@testable import Zigzag

/// What Settings › Automation copies for an app: the JSON setup and the prompt, from the address and key.
struct MCPSetupTests {
    private let address = "http://127.0.0.1:39220/mcp"
    private let token = "abc_DEF-123"

    private func parsed(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func setupIsTheFormMCPAppsTake() throws {
        let text = MCPSetup.configuration(address: address, token: token)
        let servers = try #require(try parsed(text)["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["zigzag"])
        let server = try #require(servers["zigzag"] as? [String: Any])
        #expect(server["type"] as? String == "http")
        #expect(server["url"] as? String == address)
        #expect(server["headers"] as? [String: String] == ["Authorization": "Bearer \(token)"])
        // Indented to paste into a file, the address's slashes left as they are.
        #expect(text.contains("\n"))
        #expect(text.contains("\"url\" : \"http://127.0.0.1:39220/mcp\""))
    }

    @Test func setupTakesThePortItIsGiven() throws {
        let text = MCPSetup.configuration(address: "http://127.0.0.1:41000/mcp", token: token)
        let server = try #require((try parsed(text)["mcpServers"] as? [String: Any])?["zigzag"] as? [String: Any])
        #expect(server["url"] as? String == "http://127.0.0.1:41000/mcp")
    }

    @Test func setupEscapesWhatItHolds() throws {
        // A key is URL-safe base64, but whatever it holds, the setup stays valid JSON and reads back the same.
        let odd = #"a"b\c"# + "\n\u{1}"
        let text = MCPSetup.configuration(address: address, token: odd)
        let server = try #require((try parsed(text)["mcpServers"] as? [String: Any])?["zigzag"] as? [String: Any])
        #expect(server["headers"] as? [String: String] == ["Authorization": "Bearer \(odd)"])
        #expect(!text.contains("\n\u{1}"))
    }

    @Test func promptSaysWhereAndWithWhichHeader() {
        let prompt = MCPSetup.prompt(address: address, token: token)
        #expect(prompt.contains(address))
        #expect(prompt.contains("Authorization: Bearer \(token)"))
        #expect(prompt.contains("MCP"))
        #expect(prompt.contains("this Mac"))
        // Short enough to paste into a chat, and the key is the only secret in it.
        #expect(prompt.count < 900)
        #expect(prompt.components(separatedBy: token).count == 2)
    }
}
