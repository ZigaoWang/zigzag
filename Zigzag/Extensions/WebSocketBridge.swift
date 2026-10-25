import Foundation
import WebKit

/// A WebSocket for an extension's background, opened by Zigzag instead of WebKit.
///
/// In WebKit's extension service workers `new WebSocket(…)` never returns and freezes the whole background.
/// 1Password opens one as the last step of signing in, so it stalled there. Its background gets a stand-in
/// WebSocket (see `ExtensionProfile.webSocketShim`) that talks to this over a native port; this opens the real
/// connection with URLSession and passes frames both ways. Only hosts and close codes are logged, never frames.
@available(macOS 15.4, *)
final class WebSocketBridge: NSObject, URLSessionWebSocketDelegate {
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

    init(port: WKWebExtension.MessagePort, extensionID: String, onClose: @escaping () -> Void) {
        self.port = port
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
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
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
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
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
