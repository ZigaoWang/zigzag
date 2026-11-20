import AppKit
import WebKit

/// OldTwitter signs each request to X with a transaction id from X's own challenge script. Chrome runs that script in a
/// sandbox page with no extension APIs. Here the page's Content-Security-Policy blocks both the blob iframe it uses and
/// `eval`, so the script never starts and every request times out.
///
/// Zigzag runs the extension's own `sandbox.html` in a fresh content world in the page's frame: the page's address and
/// document, WebKit's eval outside the site's policy, and no `chrome` APIs. A new world for each init keeps the webpack
/// chunk fresh, and no two tabs share one. The site's policy is left alone. Only OldTwitter, and only on its sites.
@available(macOS 15.4, *)
@MainActor
final class OldTwitterSolver: NSObject {
    /// The Chrome Web Store's Old Twitter Layout.
    static let extensionID = "jgejdcdoeeabklepnkdbglgccjpdgpmf"
    /// What a copy loaded from a folder is known by, since its identifier comes from where it was loaded.
    static let home = "https://github.com/dimdengd/oldtwitter"
    /// The handler the extension's content script calls, and the name Zigzag gives it.
    static let handlerName = "zigzagOldTwitterSolver"
    /// The handler the sandbox world posts back to.
    /// The one function Zigzag puts in the extension's world. It answers with a promise.
    static let callName = "__zigzagOldTwitterCall"
    static let bridge = """
    (() => {
      const host = location.hostname;
      if (host !== "x.com" && host !== "twitter.com") return;
      const handlers = window.webkit && window.webkit.messageHandlers;
      const handler = handlers && handlers.\(handlerName);
      if (!handler) return;
      try {
        Object.defineProperty(window, "\(callName)", { value: (message) => handler.postMessage(message), configurable: true });
      } catch (e) {}
      // The sandbox world has no handlers of its own; its replies come through the page's own window, with a token
      // only this extension and the sandbox know. A page can send one too, but a token it doesn't have is ignored.
      window.addEventListener("message", (event) => {
        const data = event.data;
        if (!data || !data.__zigzagSolverReply || typeof data.token !== "string") return;
        try { handler.postMessage({ op: "reply", token: data.token, message: data.message }).catch(() => {}); } catch (e) {}
      });
      // OldTwitter's own pages write Chrome's address for their icons and fonts. WebKit serves them at its own, so
      // the text it reads is fixed before it's used. Only extension pages and stylesheets are touched.
      const api = globalThis.chrome || globalThis.browser;
      const nativeFetch = window.fetch;
      try {
        Object.defineProperty(window, "fetch", { configurable: true, value: async (input, options) => {
          const response = await nativeFetch.call(window, input, options);
          const url = typeof input === "string" ? input : (input && input.url) || "";
          if (!/^webkit-extension:/i.test(url) || !/[.](html|css)([?#]|$)/i.test(url)) return response;
          const id = api && api.runtime && api.runtime.id ? api.runtime.id : "";
          const text = (await response.text())
            .replaceAll("chrome-extension://", "webkit-extension://")
            .replaceAll("__MSG_@@extension_id__", id);
          return new Response(text, { status: response.status, statusText: response.statusText, headers: response.headers });
        } });
      } catch (e) {}
    })();
    """



    struct Failure: LocalizedError {
        let message: String
        /// Whether the sandbox itself said the challenge code failed, rather than a timeout or the tab moving on.
        var initError = false
        init(_ message: String, initError: Bool = false) {
            self.message = message
            self.initError = initError
        }
        var errorDescription: String? { message }
    }

    /// How long a tab's sandbox is kept after its last request. A tab left for a moment doesn't redo its init, and one
    /// left for good doesn't hold X's vendor bundle in memory for the session.
    static let idleLimit: TimeInterval = 600

    /// Whether this is OldTwitter: the store's copy by its identifier, one loaded from a folder by what its manifest says.
    static func isOldTwitter(id: String, manifest: [String: Any]) -> Bool {
        if id == extensionID { return true }
        let home = (manifest["homepage_url"] as? String)?.lowercased()
        let name = manifest["name"] as? String ?? ""
        return home == self.home && name.hasPrefix("Old Twitter Layout")
    }

    unowned let host: ExtensionHost
    /// The copy of OldTwitter this profile runs.
    private(set) var extensionID: String?
    /// The sandbox script, read from the extension's loaded copy once.
    private var sandboxScript: String?
    /// One tab and frame's running sandbox, by its token.
    private struct Sandbox {
        let token: String
        let key: String
        let world: WKContentWorld
        let frame: WKFrameInfo
        weak var webView: WKWebView?
        var initTask: Task<Void, Error>?
        var initialized = false
        var ready: CheckedContinuation<Void, Error>?
        var pending: [Int: CheckedContinuation<String, Error>] = [:]
        var lastUsed = Date()
    }
    private var sandboxes: [String: Sandbox] = [:]
    private var next = 0
    private var sweeper: Task<Void, Never>?

    init(host: ExtensionHost) { self.host = host }

    /// Puts the one call into this web view's extension world, for x.com and twitter.com.
    func attach(to configuration: WKWebViewConfiguration, extensionID: String) {
        // A tab's setup is configured once when it is made and again with its page: only the first adds this.
        guard !configuration.userContentController.userScripts.contains(where: { $0.source == Self.bridge }) else { return }
        self.extensionID = extensionID
        let world = BridgeUserScripts.contentScriptWorld(extensionID)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: world, name: Self.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: false, in: world))
    }

    /// A fresh content world for the tab and frame this page is in, started with the codes its page worked out.
    func initialize(for webView: WKWebView, key: String, frame: WKFrameInfo, data: [String: Any]) async throws {
        closeSandbox(for: key, because: "Solver restarted")
        let script = try script()
        var data = data
        data["action"] = "init"
        if data["challengeUrl"] == nil, data["vendorData"] == nil,
           let vendorCode = data["vendorCode"] as? String, let challengeCode = data["challengeCode"] as? String {
            let base = "https://abs.twimg.com/responsive-web/client-web/"
            async let vendor = fetchText(URL(string: base + "vendor.\(vendorCode).js"))
            async let challenge = fetchText(URL(string: base + "ondemand.s.\(challengeCode)a.js"))
            let (vendorData, challengeData) = await (vendor, challenge)
            if let vendorData, let challengeData {
                data["vendorData"] = vendorData
                data["challengeData"] = challengeData
            } else {
                ExtensionLog.write("OldTwitter solver: challenge scripts couldn't be fetched here")
            }
        }
        let world = WKContentWorld.world(name: "ZigzagOldTwitter-\(UUID().uuidString)")
        let token = UUID().uuidString
        var sandbox = Sandbox(token: token, key: key, world: world, frame: frame, webView: webView)
        let task = Task { @MainActor [weak self] in
            guard let self else { throw Failure("Solver stopped") }
            try await webView.evaluateJavaScript("(() => {\n\(script)\n})();", in: frame, contentWorld: world)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.sandboxes[token]?.ready = continuation
                let call = self.initCall(token: token, data: data)
                Task { @MainActor [weak self] in
                    do {
                        _ = try await webView.evaluateJavaScript(call, in: frame, contentWorld: world)
                    } catch {
                        guard let self else { return }
                        self.sandboxes[token]?.ready?.resume(throwing: error)
                        self.sandboxes[token]?.ready = nil
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, let ready = self.sandboxes[token]?.ready else { return }
                    self.sandboxes[token]?.ready = nil
                    ready.resume(throwing: Failure("Solver timed out"))
                }
            }
            self.sandboxes[token]?.initialized = true
        }
        sandbox.initTask = task
        sandboxes[token] = sandbox
        startSweeper()
        do {
            try await task.value
            sandboxes[token]?.initTask = nil
            touch(token)
        } catch {
            ExtensionLog.write("OldTwitter solver: init failed: \(error.localizedDescription)")
            closeSandbox(for: key, because: "The solver didn't start")
            throw error
        }
    }

    /// One transaction id for the address and method. A solve that arrives while the tab's init runs waits for it.
    func solve(for webView: WKWebView, key: String, frame: WKFrameInfo, path: String, method: String) async throws -> String {
        guard let token = sandboxes.first(where: { $0.value.key == key })?.key, var sandbox = sandboxes[token] else {
            throw Failure("Solver timed out")
        }
        if let task = sandbox.initTask {
            do { try await task.value } catch { throw Failure("Solver timed out") }
        }
        guard let current = sandboxes[token], current.initialized else { throw Failure("Solver timed out") }
        let id = next
        next += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            sandboxes[token]?.pending[id] = continuation
            sandboxes[token]?.lastUsed = Date()
            let call = self.solveCall(token: token, id: id, path: path, method: method)
            let world = current.world
            let target = current.frame
            Task { @MainActor [weak self] in
                do {
                    _ = try await webView.evaluateJavaScript(call, in: target, contentWorld: world)
                } catch {
                    self?.finish(token: token, id: id, .failure(error))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(35))
                self?.finish(token: token, id: id, .failure(Failure("Solver timed out")))
            }
        }
    }

    /// The extension is gone: its sandboxes and whatever waited on them go too.
    func release() {
        for token in Array(sandboxes.keys) { closeToken(token, because: "The extension stopped") }
        sweeper?.cancel()
        sweeper = nil
        extensionID = nil
    }

    // MARK: Words

    private func initCall(token: String, data: [String: Any]) -> String {
        """
        void window.__zigzagSolveMessage({
          origin: "https://x.com",
          data: \(json(data)),
          source: { postMessage: (message) => window.postMessage({ __zigzagSolverReply: true, token: \(json(token)), message }, "*") },
        });
        """
    }

    private func solveCall(token: String, id: Int, path: String, method: String) -> String {
        let message: [String: Any] = ["action": "solve", "id": id, "path": path, "method": method]
        return """
        void window.__zigzagSolveMessage({
          origin: "https://x.com",
          data: \(json(message)),
          source: { postMessage: (message) => window.postMessage({ __zigzagSolverReply: true, token: \(json(token)), message }, "*") },
        });
        """
    }

    private func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: The sandbox

    private func script() throws -> String {
        if let sandboxScript { return sandboxScript }
        guard let extensionID, let directory = host.profile.installs.overlayDirectory(for: extensionID) else {
            throw Failure("OldTwitter's sandbox isn't in its loaded copy")
        }
        let html = try String(contentsOf: directory.appendingPathComponent("sandbox.html"), encoding: .utf8)
        guard let start = html.range(of: "<script>"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw Failure("OldTwitter's sandbox has no script")
        }
        let code = String(html[start.upperBound..<end.lowerBound])
        sandboxScript = code
        return code
    }

    /// A challenge script, fetched by Zigzag rather than the sandbox, so a proxy or the page can't stop it.
    private func fetchText(_ url: URL?) async -> String? {
        guard let url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = host.profile.store.proxyConfigurations
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func closeSandbox(for key: String, because reason: String) {
        guard let token = sandboxes.first(where: { $0.value.key == key })?.key else { return }
        closeToken(token, because: reason)
    }

    private func closeToken(_ token: String, because reason: String) {
        guard let sandbox = sandboxes.removeValue(forKey: token) else { return }
        sandbox.ready?.resume(throwing: Failure(reason))
        for continuation in sandbox.pending.values { continuation.resume(throwing: Failure(reason)) }
        if let webView = sandbox.webView {
            let frame = sandbox.frame, world = sandbox.world
            Task { @MainActor in
                _ = try? await webView.evaluateJavaScript("""
                try {
                  window.__SCRIPTS_LOADED__ = undefined; window._CHALLENGE = undefined;
                  window.webpackChunk_twitter_responsive_web = undefined; window.__zigzagSolveMessage = undefined;
                } catch (e) {}
                """, in: frame, contentWorld: world)
            }
        }
    }

    private func touch(_ token: String) {
        sandboxes[token]?.lastUsed = Date()
    }

    // MARK: Idle

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    private func sweep() {
        let now = Date()
        for (token, sandbox) in Array(sandboxes) where sandbox.pending.isEmpty && sandbox.initTask == nil {
            // A tab that left its window can come back, so its sandbox waits for the idle limit like any other; only a
            // tab that's gone, with nothing left of its web view, ends at once.
            if sandbox.webView == nil {
                closeToken(token, because: "The tab closed")
            } else if now.timeIntervalSince(sandbox.lastUsed) > Self.idleLimit {
                closeToken(token, because: "Idle")
            }
        }
    }

    // MARK: Replies

    fileprivate func receive(token: String, message: [String: Any]) {
        guard let sandbox = sandboxes[token] else { return }
        switch message["action"] as? String {
        case "ready":
            sandbox.ready?.resume()
            sandboxes[token]?.ready = nil
        case "initError":
            sandbox.ready?.resume(throwing: Failure(message["error"] as? String ?? "The solver didn't start",
                                                     initError: true))
            sandboxes[token]?.ready = nil
        case "solved":
            guard let id = (message["id"] as? NSNumber)?.intValue else { return }
            finish(token: token, id: id, .success(message["result"] as? String ?? ""))
        case "error":
            guard let id = (message["id"] as? NSNumber)?.intValue else { return }
            finish(token: token, id: id, .failure(Failure(message["error"] as? String ?? "The solver failed")))
        default:
            break
        }
    }

    private func finish(token: String, id: Int, _ result: Result<String, Error>) {
        guard let continuation = sandboxes[token]?.pending.removeValue(forKey: id) else { return }
        touch(token)
        continuation.resume(with: result)
    }

    /// One sandbox for each tab and frame: a page's frames don't reset each other's challenge.
    private func frameKey(for message: WKScriptMessage) -> String? {
        guard let webView = message.webView else { return nil }
        let tab = String(describing: ObjectIdentifier(webView))
        let frame = message.frameInfo.isMainFrame ? "main" : (message.frameInfo.request.url?.absoluteString ?? "frame")
        return tab + "\u{0}" + frame
    }
}

@available(macOS 15.4, *)
extension OldTwitterSolver: WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        // Only from a page of OldTwitter's own sites, whatever a page script could send.
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https", ["x.com", "twitter.com"].contains(origin.host),
              let webView = message.webView, let key = frameKey(for: message),
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "OldTwitter's solver is only for x.com and twitter.com")
            return
        }
        switch op {
        case "init":
            guard let data = body["data"] as? [String: Any] else { replyHandler(nil, "Bad challenge data"); return }
            Task { @MainActor in
                do {
                    try await initialize(for: webView, key: key, frame: message.frameInfo, data: data)
                    replyHandler(nil, nil)
                } catch let failure as Failure where failure.initError {
                    // OldTwitter stops signing requests on this one, as Chrome does. A timeout or a restart comes back
                    // as a plain error instead, so the next solve can try again (see the init patch).
                    replyHandler(["initError": failure.message], nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "reply":
            guard let token = body["token"] as? String, let reply = body["message"] as? [String: Any] else {
                replyHandler(nil, nil)
                return
            }
            receive(token: token, message: reply)
            replyHandler(nil, nil)
        case "solve":
            guard let path = body["path"] as? String, let method = body["method"] as? String else {
                replyHandler(nil, "Bad challenge request")
                return
            }
            Task { @MainActor in
                do { replyHandler(try await solve(for: webView, key: key, frame: message.frameInfo, path: path, method: method), nil) }
                catch { replyHandler(nil, error.localizedDescription) }
            }
        default:
            replyHandler(nil, "Unknown challenge request")
        }
    }
}
