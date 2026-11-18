import AppKit
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

extension MCPSetupTests {
    /// Copies with the key are marked concealed for clipboard managers; the address alone isn't.
    @MainActor @Test func keyCopiesAreConcealed() {
        let board = NSPasteboard(name: NSPasteboard.Name("zigzag-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let marker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        SettingsView.copy("Authorization: Bearer \(token)", concealed: true, to: board)
        #expect(board.string(forType: .string) == "Authorization: Bearer \(token)")
        #expect(board.types?.contains(marker) == true)
        #expect(board.types?.contains(Clipboard.transientType) == true)
        SettingsView.copy(address, to: board)
        #expect(board.string(forType: .string) == address)
        #expect(board.types?.contains(marker) == false)
        #expect(board.types?.contains(Clipboard.transientType) == false)
    }

    /// Only keys in Zigzag's format count; a hand-written key is replaced.
    @Test func onlyZigzagsOwnKeysAreUsed() throws {
        for _ in 0..<200 { #expect(MCPAccess.isZigzagKey(MCPAccess.newToken())) }
        let good = MCPAccess.newToken()
        for text in [String(good.dropLast()), good + "A", String(repeating: "x", count: 32), String(repeating: "a", count: 64),
                     String(good.dropLast()) + "+", String(good.dropLast()) + "=", String(good.dropLast()) + "é",
                     String(repeating: "A", count: 42) + "B"] {
            #expect(!MCPAccess.isZigzagKey(text), "\(text)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("chosen-by-someone-else-0123456789abcdef".utf8).write(to: url)
        #expect(MCPKeyFile.token(at: url, creating: false) == nil)
        let made = try #require(MCPKeyFile.token(at: url, creating: true))
        #expect(MCPAccess.isZigzagKey(made) && MCPKeyFile.token(at: url, creating: false) == made)
    }
}

extension MCPSetupTests {
    /// Copied passwords get concealed markers in the same write and are cleared on quit if nothing was copied since.
    @MainActor @Test func copiedPasswordsAreMarkedAndCleared() {
        let board = NSPasteboard(name: NSPasteboard.Name("zigzag-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        Clipboard.copy("hunter22", concealed: true, to: board)
        #expect(board.string(forType: .string) == "hunter22")
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.pasteboardItems?.first?.types.contains(Clipboard.concealedType) == true)
        #expect(board.pasteboardItems?.first?.types.contains(Clipboard.transientType) == true)
        Clipboard.clearIfStillOurs()
        #expect(board.string(forType: .string) == nil)

        // Something copied since is left alone.
        Clipboard.copy("hunter22", concealed: true, to: board)
        board.clearContents()
        board.setString("mine", forType: .string)
        Clipboard.clearIfStillOurs()
        #expect(board.string(forType: .string) == "mine")

        Clipboard.copy("alice", concealed: false, to: board)
        #expect(board.types?.contains(Clipboard.concealedType) == false)
        Clipboard.clearIfStillOurs()
        #expect(board.string(forType: .string) == "alice")
    }
}
