import Foundation

/// What Settings › Automation copies for an app to connect with: the setup most MCP apps take as JSON, and a
/// short prompt to paste into an app's chat instead. Plain text from the address and key, so it's tested on its own.
nonisolated enum MCPSetup {
    /// The server's name in the setup, as the app lists it.
    static let serverName = "zigzag"

    /// `{"mcpServers": {"zigzag": {"type": "http", "url": …, "headers": {"Authorization": "Bearer …"}}}}`, indented
    /// as people paste it into a settings file. Written by JSONSerialization, so any character comes out escaped.
    static func configuration(address: String, token: String) -> String {
        let server: [String: Any] = ["type": "http", "url": address, "headers": ["Authorization": "Bearer \(token)"]]
        let object: [String: Any] = ["mcpServers": [serverName: server]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What to tell an AI app so it connects by itself: where, with which header, and what it may do.
    static func prompt(address: String, token: String) -> String {
        let header = "Authorization: Bearer \(token)"
        return String(localized: "Connect to Zigzag, my web browser, as an MCP server. Use the HTTP transport at \(address) and send this header with every request: \(header). It works on this Mac only. Once connected, you can list my tabs, open, read and screenshot pages, and click, type and scroll in them. Zigzag never lets you use private windows, passwords or its own pages, and I can stop you on any tab. If you can’t add an MCP server yourself, tell me where to add it in your settings.",
                      comment: "Copied by Copy Prompt in Settings › Automation, to paste into an AI app's chat so it connects to Zigzag. The first placeholder is the server's address, the second the Authorization header with its key; keep both as they are.")
    }
}
