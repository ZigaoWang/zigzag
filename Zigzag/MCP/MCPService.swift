import AppKit

/// Settings › Automation › Let AI apps use Zigzag: an MCP server on this Mac only, off until you turn it
/// on. Off, nothing listens at all. On, apps that have its key can list, open, read and use your tabs.
@MainActor
enum MCPService {
    static let defaultPort: UInt16 = 39217
    private static let key = "AllowsAIApps"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The port, 39217 unless `defaults write … MCPPort` says another.
    static var port: UInt16 {
        let set = UserDefaults.standard.integer(forKey: "MCPPort")
        return (1024...65535).contains(set) ? UInt16(set) : defaultPort
    }

    static var address: String { "http://127.0.0.1:\(port)\(MCPEndpoint.path)" }

    /// What Settings shows under the address: nil while all is well.
    private(set) static var problem: String?
    /// Told when the server starts, stops or fails.
    static let changed = Signal<Void>()

    private static var server: MCPServer?

    static func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        on ? start() : stop()
    }

    /// At launch: the server comes up only if you turned it on.
    static func startIfOn() {
        if isOn { start() }
    }

    private static func start() {
        guard server == nil else { return }
        let token = MCPKeyFile.token(creating: true) ?? ""
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let endpoint = MCPEndpoint(token: token, runner: MCPBrowserRunner(), serverVersion: version)
        endpoint.onSessionEnded = { client in
            Task { @MainActor in AgentControl.shared.release(client) }
        }
        AgentControl.shared.onStop = { [weak endpoint] _ in
            endpoint?.refuseAll()
            stopAccess()
        }
        let server = MCPServer(port: port, endpoint: endpoint)
        server.onState = { state in
            Task { @MainActor in
                switch state {
                case .failed(let message):
                    problem = message
                    NSLog("Zigzag MCP: %@", message)
                case .ready: problem = nil
                default: break
                }
                changed.send()
            }
        }
        self.server = server
        problem = nil
        server.start()
    }

    private static func stop() {
        MCPWait.cancelAll(MCPWait.stoppedMessage)
        server?.stop()
        server = nil
        problem = nil
        AgentControl.shared.onStop = nil
        AgentControl.shared.reset()
        changed.send()
    }

    /// Stop on the bar over a tab: no AI app uses Zigzag any more, not only the one on that tab. Its key is replaced,
    /// so none can carry on with the old one, and the setting goes off, so nothing listens until you turn it back on
    /// in Settings › Automation and give the app the new key.
    static func stopAccess() {
        server?.endpoint.refuseAll()
        MCPKeyFile.reset()
        setOn(false)
        if let controller = WindowManager.shared.keyController {
            Toast.show(String(localized: "AI apps can’t use Zigzag now. Turn them back on in Settings › Automation.", comment: "Toast after Stop on the bar over a tab an AI app was using: every AI app is cut off until the setting is turned on again."),
                       symbol: "hand.raised", duration: 5, in: controller)
        }
    }

    /// The key apps send, made the first time it's needed.
    static var token: String { MCPKeyFile.token(creating: true) ?? "" }

    static var authorizationHeader: String { "Authorization: Bearer \(token)" }

    /// A new key: every app connected with the old one is cut off and has to be given this one.
    static func resetKey() {
        let new = MCPKeyFile.reset() ?? ""
        server?.endpoint.setToken(new)
        MCPWait.cancelAll(MCPWait.stoppedMessage)
        AgentControl.shared.reset()
        changed.send()
    }

    #if DEBUG
    static var debugState: [String: Any] {
        ["on": isOn, "port": Int(port), "problem": problem ?? "", "running": server != nil, "sessions": server?.endpoint.sessionCount ?? 0,
         "inUse": AgentControl.shared.inUse.count, "banners": AgentControl.shared.debugBannerLines]
    }
    #endif
}

/// The key lives in a file of Zigzag's own, readable by you alone (0600), never in the Keychain.
nonisolated enum MCPKeyFile {
    static var url: URL { Paths.file("MCP Key") }

    static func token(at url: URL = url, creating: Bool) -> String? {
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.count >= 32 {
            // Kept to you alone, even if something loosened it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return text
        }
        return creating ? write(MCPAccess.newToken(), to: url) : nil
    }

    @discardableResult
    static func reset(at url: URL = url) -> String? { write(MCPAccess.newToken(), to: url) }

    private static func write(_ token: String, to url: URL) -> String? {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        // Made 0600 from the start, so it's never readable by others even for a moment.
        guard manager.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }
}
