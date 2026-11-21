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
    /// The one function Zigzag puts in the extension's world. It answers with a promise.
    static let callName = "__zigzagOldTwitterCall"
    static let bridge = """
    (() => {
      const host = location.hostname;
      if (host !== "x.com" && host !== "twitter.com") return;
      // A page keeps one run of this bridge, whether it came from the user script or from a page that was open when
      // OldTwitter started again: a second run would add a second set of listeners and observers.
      if (window.__zigzagOldTwitterBridge) return;
      window.__zigzagOldTwitterBridge = true;
      const handlers = window.webkit && window.webkit.messageHandlers;
      const handler = handlers && handlers.\(handlerName);
      if (!handler) return;
      try {
        Object.defineProperty(window, "\(callName)", { value: (message) => handler.postMessage(message), configurable: true });
      } catch (e) {}
      // The sandbox world's replies come through the window with its token; the page's own scripts can see them too.
      window.addEventListener("message", (event) => {
        const data = event.data;
        if (event.source !== window || !data || !data.__zigzagSolverReply || typeof data.token !== "string") return;
        try { handler.postMessage({ op: "reply", token: data.token, message: data.message }).catch(() => {}); } catch (e) {}
      });
      // OldTwitter's layout names its own files with Chrome's address. WebKit serves the same files at its own
      // address, which the page's security policy lets through, so the addresses are fixed as the layout is made:
      // its icon font, the loading picture, its images and the tab's icon.
      const api = globalThis.chrome || globalThis.browser;
      const id = api && api.runtime && api.runtime.id;
      if (!id) return;
      const from = "chrome-extension://" + id;
      const to = "webkit-extension://" + id;
      const fixed = (text) => (text.includes(from) ? text.split(from).join(to) : text);
      // A quoted tweet is a link to itself, and its video sits inside it. WebKit's play button on that video never
      // reaches the page: it follows the quote's link in the UI instead, so play opened the quote in a new tab and a
      // click could not be taken back. The link is kept aside, so the video is not inside a link at all, and a click
      // on the quote's text opens it as the link did.
      const unlinkQuote = (element) => {
        if (!element || element.tagName !== "A" || !element.classList || !element.classList.contains("tweet-body-quote")) return;
        // A ⌘, ⌃ or middle press puts the address back for the browser to follow; a right press for its menu.
        if (element.hasAttribute("data-zigzag-modified") || element.hasAttribute("data-zigzag-menu")) return;
        const href = element.getAttribute("href");
        if (!href) return;
        element.setAttribute("data-zigzag-href", href);
        element.removeAttribute("href");
        element.style.cursor = "pointer";
      };
      // WebKit's own play button on a quoted video does nothing here: the click never reaches the page and no play
      // starts. A play button of our own over the video answers a real click, which can start it. The mark on the
      // video outlives the run that made its layer, so a later run never stacks a second one.
      const addPlay = (video) => {
        if (!video || video.tagName !== "VIDEO" || !video.closest("a.tweet-body-quote")) return;
        if (video.hasAttribute("data-zigzag-play-video")) return;
        const holder = video.parentElement;
        if (!holder) return;
        video.setAttribute("data-zigzag-play-video", "");
        if (getComputedStyle(holder).position === "static") holder.style.position = "relative";
        // Metadata only, so a timeline of quoted videos does not download them. The seek asks for just enough for
        // the first frame, which otherwise shows black.
        try {
          video.preload = "metadata";
          if (!video.currentTime) video.currentTime = 0.1;
        } catch (e) {}
        // An invisible layer over the picture, so a click there plays or pauses it. It takes the video's own box,
        // never the strip around it, and the video's controls at the top and in the bar stay outside it. No button of
        // Zigzag's is drawn: WebKit's own shows.
        const layer = document.createElement("div");
        layer.setAttribute("data-zigzag-play", "");
        layer.style.cssText = "position:absolute;z-index:3;background:transparent;cursor:pointer;";
        const place = () => {
          const box = video.getBoundingClientRect(), holderBox = holder.getBoundingClientRect();
          if (!box.width || !box.height) return;
          layer.style.left = (box.left - holderBox.left) + "px";
          layer.style.top = (box.top - holderBox.top + box.height * 0.28) + "px";
          layer.style.width = box.width + "px";
          layer.style.height = (box.height * 0.5) + "px";
        };
        layer.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (video.paused) video.play().catch(() => {});
          else video.pause();
        });
        holder.appendChild(layer);
        // A click on the video belongs to WebKit's controls. The quote's own handler sits on the link around the
        // video and takes the same click as a request for the quote, which opens it. The controls have already had
        // the click when it reaches their holder, so it stops there. A ⌘ or ⌃ press is the browser's.
        if (!holder.hasAttribute("data-zigzag-quote-click")) {
          holder.setAttribute("data-zigzag-quote-click", "");
          holder.addEventListener("click", (event) => {
            if (event.metaKey || event.ctrlKey) return;
            const target = event.target;
            if (!target || !target.closest || !target.closest("video")) return;
            event.preventDefault();
            event.stopPropagation();
          }, false);
        }
        place();
        new ResizeObserver(place).observe(holder);
        new ResizeObserver(place).observe(video);
        addEventListener("resize", place);
      };
      const fix = (element) => {
        if (!element || element.nodeType !== 1) return;
        unlinkQuote(element);
        addPlay(element);
        if (element.tagName === "STYLE") {
          const text = element.textContent;
          if (text && text.includes(from)) element.textContent = fixed(text);
          return;
        }
        for (const name of ["src", "href", "srcset", "poster", "data"]) {
          const value = element.getAttribute(name);
          if (value && value.includes(from)) element.setAttribute(name, fixed(value));
        }
        const style = element.getAttribute("style");
        if (style && style.includes(from)) element.setAttribute("style", fixed(style));
      };
      const fixTree = (node) => {
        fix(node);
        if (node.querySelectorAll) node.querySelectorAll("a,style,img,link,source,video,use,[style]").forEach(fix);
      };
      fixTree(document.documentElement);
      document.addEventListener("click", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        if (!target) return;
        if (target.closest("[data-zigzag-play]")) return;
        const quote = target.closest("a.tweet-body-quote");
        // A click on the video is the video's own controls'. The controls stop the click before it leaves them,
        // so the quote's own handler never sees it, but the link under the video still would. The default is
        // stopped here, before the controls, and a ⌘ or ⌃ press is left to the browser.
        if (target.closest("video")) {
          if (quote && !event.metaKey && !event.ctrlKey) event.preventDefault();
          return;
        }
        // ⌘ takes the quoted tweet itself, in a new tab: the click reaches the link, and the extension's own
        // handlers let a modified click through.
        if (quote && (event.metaKey || quote.hasAttribute("data-zigzag-modified"))) return;
        // A link in the quoted text (a URL, a mention, the quoted account) is its own.
        if (target.closest("a[href]")) return;
        // A quoted tweet opens in the extension's own modal, which is its own handler's doing. Without the href,
        // nothing follows it in a tab.
        if (quote) event.preventDefault();
      }, true);
      // A timeline video lists the HLS playlist before its mp4 files, and Safari plays the playlist. WebKit's own
      // Download Video would save that playlist as a text file, so the menu is told the mp4 the page lists instead.
      const bestMp4 = (sources) => {
        let best = "", area = 0;
        for (const source of sources) {
          if (source.type !== "video/mp4" || !source.src) continue;
          const size = source.src.split("/").find((part) => /^[0-9]+x[0-9]+$/.test(part));
          const pixels = size ? Number(size.split("x")[0]) * Number(size.split("x")[1]) : 0;
          if (!best || pixels > area) { best = source.src; area = pixels; }
        }
        return best;
      };
      document.addEventListener("contextmenu", (event) => {
        const target = event.target;
        const video = target && target.closest ? target.closest("video") : null;
        if (!video) return;
        const sources = video.querySelectorAll ? video.querySelectorAll("source") : [];
        try {
          handler.postMessage({ op: "video", src: video.currentSrc || video.src || "", file: bestMp4(sources) });
        } catch (e) {}
      }, true);
      // The address is put back for the right-click menu alone, so Open in New Tab still has a link, and taken off
      // again once the menu has it, so a click on the quote or its video never follows it. The right press is marked
      // like a ⌘ or middle one, so the observer below leaves its link in place until the menu is built.
      document.addEventListener("mousedown", (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const quote = target ? target.closest("a.tweet-body-quote") : null;
        if (!quote) return;
        const href = quote.getAttribute("data-zigzag-href");
        if (!href) return;
        if (event.button === 2) {
          quote.setAttribute("href", href);
          quote.setAttribute("data-zigzag-menu", "");
          setTimeout(() => {
            quote.removeAttribute("data-zigzag-menu");
            // A ⌘ or middle press in the meantime keeps its own link for its own moment.
            if (quote.hasAttribute("data-zigzag-modified")) return;
            if (quote.getAttribute("data-zigzag-href")) quote.removeAttribute("href");
          }, 3000);
          return;
        }
        // Any other press ends a right press's mark before the browser acts on it.
        quote.removeAttribute("data-zigzag-menu");
        // The page's own world has already put it back for a ⌘, ⌃ or middle press, and marked it.
        if (quote.hasAttribute("data-zigzag-modified")) {
          quote.setAttribute("href", href);
          return;
        }
        const newTab = event.button === 1 || (event.button === 0 && event.metaKey);
        if (newTab) quote.setAttribute("href", href);
        else if (event.button === 0) quote.removeAttribute("href");
      }, true);
      new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          if (mutation.type === "attributes") fix(mutation.target);
          else if (mutation.type === "characterData") { if (mutation.target.parentElement) fix(mutation.target.parentElement); }
          else mutation.addedNodes.forEach((node) => { if (node.nodeType === 1) fixTree(node); });
        }
      }).observe(document.documentElement || document, {
        childList: true, subtree: true, attributes: true, attributeFilter: ["src", "href", "srcset", "poster", "style", "data"], characterData: true,
      });
    })();
    """

    /// The page's own world sees the keys held on a click; the extension's own world does not always. A ⌘ or middle
    /// press puts the quoted tweet's link back and marks it, so every handler can tell that click is the browser's.
    static let modified = """
    (() => {
      // It is added to every site's page world; it acts only on x.com and twitter.com.
      const host = location.hostname;
      if (host !== "x.com" && host !== "twitter.com") return;
      if (window.__zigzagOldTwitterModified) return;
      window.__zigzagOldTwitterModified = true;
      document.addEventListener("mousedown", (event) => {
        if (!event.isTrusted || !(event.metaKey || event.button === 1)) return;
        const quote = event.target.closest && event.target.closest("a.tweet-body-quote");
        const href = quote && quote.getAttribute("data-zigzag-href");
        if (!href) return;
        quote.setAttribute("href", href);
        quote.setAttribute("data-zigzag-modified", "");
        setTimeout(() => {
          quote.removeAttribute("data-zigzag-modified");
          quote.removeAttribute("href");
        }, 2000);
      }, true);
      // ⌘ on a tweet's own body is that tweet's link: it opens in a new tab, not in the extension's viewer.
      document.addEventListener("click", (event) => {
        if (!event.isTrusted || !event.metaKey) return;
        const target = event.target;
        if (!target.closest) return;
        if (target.closest("a[href], button, video, [data-zigzag-play], .tweet-button")) return;
        const tweet = target.closest(".tweet");
        if (!tweet || target.closest("a.tweet-body-quote")) return;
        const link = tweet.querySelector(".tweet-time");
        const href = link && link.getAttribute("href");
        if (!href) return;
        event.preventDefault();
        event.stopPropagation();
        window.open(href, "_blank", "noopener");
      }, true);
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
    /// The pages' controllers that may carry the call, so one made before OldTwitter was installed or started again
    /// gets it too, without a new window.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Those of them in private windows: they keep the call only while OldTwitter may run there.
    private let privateControllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Those that have its handler: WebKit takes a name in a world once.
    private let handlers = NSHashTable<WKUserContentController>.weakObjects()

    init(host: ExtensionHost) { self.host = host }

    /// Whether OldTwitter may run in a private window, from what the person allowed. WebKit holds the same answer on
    /// its context, but a page can be made before the extension has loaded, so the stored setting is what's read.
    private func mayRunInPrivate(_ extensionID: String) -> Bool {
        host.profile.installs.allowsPrivate(extensionID)
    }

    /// Puts the one call into this web view's extension world, for x.com and twitter.com. A private page gets it only
    /// when OldTwitter may run there, as WebKit's own content scripts do.
    func attach(to configuration: WKWebViewConfiguration, extensionID: String, isPrivate: Bool = false) {
        guard PrivateAccess.sees(isPrivate: isPrivate, allowed: mayRunInPrivate(extensionID)) else { return }
        self.extensionID = extensionID
        let controller = configuration.userContentController
        controllers.add(controller)
        if isPrivate { privateControllers.add(controller) }
        addCall(to: controller)
    }

    /// A page made before OldTwitter was installed, updated or started again gets the call as well, from its next load
    /// and in the page it shows now. Without it the extension's script asks for a function no page has.
    func attach(toOpenPagesOf extensionID: String) {
        self.extensionID = extensionID
        let privateAllowed = mayRunInPrivate(extensionID)
        for controller in controllers.allObjects {
            // Turned off for private windows since this page was made: its next load doesn't get the bridge.
            guard privateAllowed || !privateControllers.contains(controller) else {
                removeCall(from: controller)
                continue
            }
            addCall(to: controller)
        }
        for window in WindowManager.shared.controllers where window.tabManager.profile === host.profile {
            for tab in window.tabManager.allTabs where tab.extensionHost === host && window.holds(tab) {
                guard let webView = tab.webView else { continue }
                guard PrivateAccess.sees(isPrivate: tab.isPrivate, allowed: privateAllowed) else { continue }
                let controller = webView.configuration.userContentController
                controllers.add(controller)
                if tab.isPrivate { privateControllers.add(controller) }
                addCall(to: controller)
                guard let page = webView.url?.host(), page == "x.com" || page == "twitter.com" else { continue }
                let world = BridgeUserScripts.contentScriptWorld(extensionID)
                webView.callAsyncJavaScript(Self.bridge, arguments: [:], in: nil, in: world) { _ in }
                webView.callAsyncJavaScript(Self.modified, arguments: [:], in: nil, in: .page) { _ in }
            }
        }
    }

    /// Takes the call back out of a page that may no longer have it, from its next load.
    private func removeCall(from controller: WKUserContentController) {
        OwnScripts.remove(from: controller) { $0.source == Self.bridge || $0.source == Self.modified }
        guard handlers.contains(controller), let extensionID else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName,
                                              contentWorld: BridgeUserScripts.contentScriptWorld(extensionID))
        handlers.remove(controller)
    }

    private func addCall(to controller: WKUserContentController) {
        guard let extensionID else { return }
        let world = BridgeUserScripts.contentScriptWorld(extensionID)
        if !handlers.contains(controller) {
            controller.addScriptMessageHandler(self, contentWorld: world, name: Self.handlerName)
            handlers.add(controller)
        }
        guard !controller.userScripts.contains(where: { $0.source == Self.bridge }) else { return }
        controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: world))
        if !controller.userScripts.contains(where: { $0.source == Self.modified }) {
            controller.addUserScript(WKUserScript(source: Self.modified, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
        }
    }

    /// A fresh content world for the tab and frame this page is in, started with the codes its page worked out.
    func initialize(for webView: WKWebView, key: String, frame: WKFrameInfo, data: [String: Any]) async throws {
        closeSandbox(for: key, because: "Solver restarted")
        let script = try script()
        var data = data
        data["action"] = "init"
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
        guard let token = sandboxes.first(where: { $0.value.key == key })?.key, let sandbox = sandboxes[token] else {
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
        // An update loads a new copy: its sandbox is read again.
        sandboxScript = nil
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
        // Unpatched, it would listen to the page's own messages in its world.
        guard code.contains("window.__zigzagSolveMessage = ") else { throw Failure("OldTwitter's sandbox isn't patched") }
        sandboxScript = code
        return code
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
        case "video":
            // The video under a right press, for the page menu's Download Video. The page's own frame reports it.
            guard message.frameInfo.isMainFrame, let src = body["src"] as? String,
                  let source = URL(string: src), source.scheme != nil,
                  let webView = webView as? BrowserWebView else {
                replyHandler(nil, nil)
                return
            }
            let file = (body["file"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            webView.contextVideo = BrowserWebView.ContextVideo(source: source, file: file)
            replyHandler(nil, nil)
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
