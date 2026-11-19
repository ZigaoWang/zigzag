import Foundation
import WebKit

/// A WebSocket for an extension's background, opened by Zigzag instead of WebKit.
///
/// In WebKit's extension service workers `new WebSocket(…)` never returns and freezes the whole background.
/// 1Password opens one as the last step of signing in, so it stalled there. Its background gets a stand-in
/// WebSocket (see `ExtensionShims.webSocketShim`) that talks to this over a native port; this opens the real
/// connection with URLSession and passes frames both ways. Only hosts and close codes are logged, never frames.
@available(macOS 15.4, *)
@MainActor final class WebSocketBridge: NSObject, URLSessionWebSocketDelegate {
    static let host = "zigzag.websocket"

    private let port: WKWebExtension.MessagePort
    private let origin: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var host = "?"
    private var finished = false
    /// The extension asked to close: the connection ending is expected, not an error.
    private var closeRequested: URLSessionWebSocketTask.CloseCode?
    private let onClose: () -> Void
    /// Profile proxies (from chrome.proxy), so sockets route like the profile's pages.
    private let proxies: [ProxyConfiguration]
    /// Whether the extension may reach this address; checked on open.
    private let mayConnect: (URL) -> Bool

    init(port: WKWebExtension.MessagePort, extensionID: String, proxies: [ProxyConfiguration] = [],
         mayConnect: @escaping (URL) -> Bool, onClose: @escaping () -> Void) {
        self.port = port
        self.proxies = proxies
        self.mayConnect = mayConnect
        // What Chrome sends for an extension's background, so servers that check it see what they expect.
        origin = "chrome-extension://\(extensionID)"
        self.onClose = onClose
        super.init()
        port.messageHandler = { [weak self] message, _ in self?.handle(message) }
        port.disconnectHandler = { [weak self] _ in self?.finish(code: .goingAway, tellExtension: false) }
    }

    private func handle(_ message: Any?) {
        guard let message = message as? [String: Any], let op = message["op"] as? String else { return }
        switch op {
        case "open":
            guard let text = message["url"] as? String, let url = URL(string: text),
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), mayConnect(url) else {
                send(["ev": "error"])
                finish(code: .protocolError, tellExtension: true)
                return
            }
            host = url.host() ?? "?"
            var request = URLRequest(url: url)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let protocols = message["protocols"] as? [String], !protocols.isEmpty {
                request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.proxyConfigurations = proxies
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            self.session = session
            let task = session.webSocketTask(with: request)
            self.task = task
            ExtensionLog.write("socket for an extension opening to \(host)")
            task.resume()
            receive()
        case "send":
            guard let task else { return }
            if let text = message["text"] as? String {
                task.send(.string(text)) { _ in }
            } else if let encoded = message["binary"] as? String, let data = Data(base64Encoded: encoded) {
                task.send(.data(data)) { _ in }
            }
        case "close":
            let code = (message["code"] as? Int).flatMap { URLSessionWebSocketTask.CloseCode(rawValue: $0) } ?? .normalClosure
            let reason = (message["reason"] as? String)?.data(using: .utf8)
            closeRequested = code
            task?.cancel(with: code, reason: reason)
        default:
            break
        }
    }

    /// Allowed socket targets for a background. Chrome needs no host access here; Zigzag limits it to what the extension
    /// could reach anyway: this Mac (a companion app's server), host_permissions, or granted optional hosts. `wss://host`
    /// matches as `https://host`.
    static func allows(_ url: URL, context: WKWebExtensionContext, localReceivers: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["ws", "wss"].contains(scheme), let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // This Mac used to be allowed with nothing asked, because WebKit's own socket couldn't reach it at all. Now it
        // is a door like the site's: the person's switch for this extension, and nothing else. A host permission cannot
        // stand in for it, since a loopback address is never one a manifest can ask for.
        if isLoopback(host) { return localReceivers }
        parts.scheme = scheme == "wss" ? "https" : "http"
        guard let web = parts.url else { return false }
        return context.hasAccess(to: web) || context.webExtension.requestedPermissionMatchPatterns.contains { $0.matches(web) }
    }

    /// localhost, 127.0.0.0/8 or ::1: this Mac.
    nonisolated static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name == "::1" || name == "0:0:0:0:0:0:0:1" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && UInt8($0) != nil }) else { return false }
        return octets[0] == "127"
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    switch result {
                    case .success(.string(let text)):
                        self.send(["ev": "message", "text": text])
                        self.receive()
                    case .success(.data(let data)):
                        self.send(["ev": "message", "binary": data.base64EncodedString()])
                        self.receive()
                    case .success:
                        self.receive()
                    case .failure:
                        if let requested = self.closeRequested {
                            self.finish(code: requested, tellExtension: true)
                        } else if self.task?.closeCode == .invalid {
                            // The close callback reports a clean close; this covers a dropped connection.
                            self.send(["ev": "error"])
                            self.finish(code: .abnormalClosure, tellExtension: true)
                        }
                    }
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            ExtensionLog.write("socket to \(host) connected")
            send(["ev": "open", "protocol": `protocol` ?? ""])
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated { finish(code: closeCode, reason: reason, tellExtension: true) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        MainActor.assumeIsolated {
            guard !finished else { return }
            if let requested = closeRequested { finish(code: requested, tellExtension: true); return }
            send(["ev": "error"])
            finish(code: .abnormalClosure, tellExtension: true)
        }
    }

    private func send(_ event: sending [String: Any]) {
        guard !finished else { return }
        port.sendMessage(event, completionHandler: nil)
    }

    private func finish(code: URLSessionWebSocketTask.CloseCode, reason: Data? = nil, tellExtension: Bool) {
        guard !finished else { return }
        if tellExtension {
            send(["ev": "close", "code": code.rawValue, "reason": reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""])
        }
        finished = true
        ExtensionLog.write("socket to \(host) closed, code \(code.rawValue)")
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        if tellExtension { port.disconnect() }
        onClose()
    }
}
