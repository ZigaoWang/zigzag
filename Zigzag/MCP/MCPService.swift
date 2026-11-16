import AppKit
import CryptoKit
import WebKit

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
    /// The key was replaced because the port was taken; whatever holds the port may have the old one. Shown in
    /// Settings.
    private(set) static var replacedKeyForBusyPort = false
    /// Told when the server starts, stops or fails.
    static let changed = Signal<Void>()

    private static var server: MCPServer?

    /// When an AI app last asked anything of Zigzag, if one has since the server started.
    static var lastRequest: Date? { server?.endpoint.lastRequest }

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
        server.onState = { [weak server] state in
            Task { @MainActor in
                switch state {
                case .failed(let message, let portInUse):
                    problem = message
                    NSLog("Zigzag MCP: %@", message)
                    if portInUse, let server, self.server === server {
                        replaceKeyForBusyPort(server.endpoint)
                    }
                case .ready: problem = nil
                default: break
                }
                changed.send()
            }
        }
        self.server = server
        problem = nil
        replacedKeyForBusyPort = false
        server.start()
    }

    /// Replaces the key when another process listens on the port, since apps connecting there hand it the key. Only if
    /// the key may have reached an app: one made for a taken port and never copied from Settings can't have, so a
    /// persistently taken port doesn't rotate the key every launch and lock out apps. Returns whether it changed.
    @discardableResult
    static func replaceKeyForBusyPort(_ endpoint: MCPEndpoint, keyFile: URL = MCPKeyFile.url, defaults: UserDefaults = .standard) -> Bool {
        replacedKeyForBusyPort = true
        guard keyMayHaveReachedApps(MCPKeyFile.token(at: keyFile, creating: false), defaults: defaults) else { return false }
        let new = MCPKeyFile.reset(at: keyFile) ?? ""
        endpoint.setToken(new)
        defaults.set(fingerprint(new), forKey: unsharedKey)
        return true
    }

    /// Fingerprint of a key made for a taken port, until copied from Settings. Only a fingerprint; the key stays in its
    /// file.
    private static let unsharedKey = "MCPKeyNotHandedOut"

    /// Whether apps may have the key: unless it's the taken-port key never copied since. Keys Zigzag didn't track
    /// (older, reset by hand) count as handed out.
    static func keyMayHaveReachedApps(_ token: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return defaults.string(forKey: unsharedKey) != fingerprint(token)
    }

    /// Copied from Settings, so it may now be anywhere.
    static func noteKeyHandedOut(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: unsharedKey) }

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func stop() {
        MCPWait.cancelAll(MCPWait.stoppedMessage)
        server?.stop()
        server = nil
        problem = nil
        replacedKeyForBusyPort = false
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

    /// Created on first use. Read only to copy for an app (Settings), so reading counts as handing out.
    static var token: String {
        noteKeyHandedOut()
        return MCPKeyFile.token(creating: true) ?? ""
    }

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
         "inUse": AgentControl.shared.inUse.count, "banners": AgentControl.shared.debugBannerLines,
         "headless": Headless.isActive, "headlessWindow": Headless.window != nil, "backgroundOnly": Headless.isBackgroundOnly,
         "headlessTabs": Headless.window?.tabManager.allTabs.count ?? 0,
         "headlessAsleep": Headless.window?.tabManager.allTabs.filter(\.isSuspended).count ?? 0,
         // Muted as Zigzag has it and as WebKit has the page (a tab with no page yet counts by its own).
         "headlessMuted": Headless.window?.tabManager.allTabs.filter { $0.isMuted && ($0.webView?.pageMutedState.map(WKWebView.isAudioMuted) ?? true) }.count ?? 0,
         "headlessKey": Headless.window?.window.map { $0.isKeyWindow || $0.isMainWindow } ?? false]
    }
    #endif
}

/// The key lives in a file of Zigzag's own, readable by you alone (0600), never in the Keychain.
nonisolated enum MCPKeyFile {
    static var url: URL { Paths.file("MCP Key") }

    static func token(at url: URL = url, creating: Bool) -> String? {
        // Replace a key not in Zigzag's format (written by hand or by something else).
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           MCPAccess.isZigzagKey(text) {
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
