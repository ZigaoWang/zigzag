import AppKit
import UniformTypeIdentifiers
import UserNotifications
import WebKit

/// Web notifications, for Gmail, Slack, Calendar and the like while their tab is open. WebKit gives an app's web
/// views no Notification API of its own, so a page script stands in for it and macOS shows what it posts. Sites
/// ask once, with Zigzag's own prompt, and only right after a click or a key; private windows never get them.
@MainActor
final class WebNotifications: NSObject, WKScriptMessageHandlerWithReply, UNUserNotificationCenterDelegate {
    static let shared = WebNotifications()
    static let messageName = "zigzagNotification"
    private static let category = "zigzag.web"

    /// What a delivered notification belongs to, so a click finds its tab and tells the page.
    private struct Entry {
        let tabID: UUID
        let origin: String
        let id: String
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let posted: Date
    }

    private var entries: [String: Entry] = [:]
    /// Sites whose question was put off in a tab (Esc): not asked again there this session.
    private var putOff: Set<String> = []
    /// Sites that asked this session, answered or not, so site controls can offer the answer later: a question
    /// that goes before you get to it (a click elsewhere, the page moving on) leaves no other way back.
    private var asked: Set<String> = []
    private var authorized: Bool?
    private var started = false

    /// The page script, knowing every site's answer up front so `Notification.permission` is right before the
    /// page's own scripts run. Added per web view, since a private window's answer is always no.
    static func attach(to configuration: WKWebViewConfiguration, isPrivate: Bool) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        let decisions = isPrivate ? [:] : SitePermissions.notificationDecisions
        let json = (try? JSONSerialization.data(withJSONObject: decisions)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let source = marker + "\n" + shim.replacingOccurrences(of: "__DECISIONS__", with: json)
            .replacingOccurrences(of: "__PRIVATE__", with: isPrivate ? "true" : "false")
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(shared, contentWorld: .page, name: messageName)
    }

    private static let marker = "/* zigzag notifications */"

    // MARK: Messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.name == Self.messageName, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let webView = message.webView as? BrowserWebView, let tab = webView.owner else { return (nil, nil) }
        // Secure pages only, and frames only on the page's own site: an ad in a frame never gets to ask.
        guard let origin = Self.origin(of: message.frameInfo, in: webView) else { return (kind == "show" ? false : "denied", nil) }
        switch kind {
        case "state":
            return (permission(origin: origin, tab: tab), nil)
        case "request":
            if !tab.isPrivate { asked.insert(origin) }
            let state = permission(origin: origin, tab: tab)
            // Only right after a click or key: the page's own word for it isn't enough, as a script can say anything.
            let clicked = body["gesture"] as? Bool == true && Date().timeIntervalSince(UndoClock.lastPageInput) < 5
            guard state == "default", clicked, !putOff.contains("\(tab.id)|\(origin)") else { return (state, nil) }
            let answer = await SitePermissions.requestNotifications(origin: origin, window: tab.host?.hostWindow, isPrivate: tab.isPrivate, tab: tab)
            if answer == nil { putOff.insert("\(tab.id)|\(origin)") }
            // A private window asks, so the page isn't left waiting, but it still never shows one.
            return (answer.map { $0 && !tab.isPrivate ? "granted" : "denied" } ?? "default", nil)
        case "show":
            guard permission(origin: origin, tab: tab) == "granted", let id = body["id"] as? String, let title = body["title"] as? String else { return (false, nil) }
            let shown = await show(id: id, title: title, body: body["body"] as? String ?? "", tag: body["tag"] as? String ?? "",
                                   icon: (body["icon"] as? String).flatMap { URL(string: $0) }, silent: body["silent"] as? Bool == true,
                                   origin: origin, tab: tab, webView: webView, frame: message.frameInfo)
            return (shown, nil)
        case "close":
            if let id = body["id"] as? String, let key = entries.first(where: { $0.value.id == id && $0.value.tabID == tab.id })?.key {
                remove([key])
            }
            return (true, nil)
        default:
            return (nil, nil)
        }
    }

    /// Whether the site asked to show notifications this session.
    func hasAsked(origin: String) -> Bool { asked.contains(origin) }

    private func permission(origin: String, tab: Tab) -> String {
        if tab.isPrivate { return "denied" }
        return SitePermissions.notifications(origin: origin).map { $0 ? "granted" : "denied" } ?? "default"
    }

    /// The frame's origin when it may use notifications: https (or http on this Mac), the page itself or a frame
    /// from the same origin.
    private static func origin(of frame: WKFrameInfo, in webView: WKWebView) -> String? {
        let security = frame.securityOrigin, host = security.host.lowercased()
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard security.protocol == "https" || (security.protocol == "http" && local), let origin = SiteOrigin.of(security) else { return nil }
        if frame.isMainFrame { return origin }
        return SiteOrigin.of(webView.url) == origin ? origin : nil
    }

    // MARK: Showing

    private func show(id: String, title: String, body: String, tag: String, icon: URL?, silent: Bool,
                      origin: String, tab: Tab, webView: WKWebView, frame: WKFrameInfo) async -> Bool {
        guard !AppDelegate.isHostingTests else { return false }
        // The tab you're looking at already shows what it would say, as in Safari.
        if NSApp.isActive, let controller = WindowManager.shared.keyController, controller.window?.isKeyWindow == true,
           let shown = controller.tabManager.selectedTab, shown === tab || controller.tabManager.partner(of: shown) === tab {
            return true
        }
        guard await authorize() else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.subtitle = SiteOrigin.label(origin)
        content.body = String(body.prefix(1000))
        content.threadIdentifier = origin
        content.categoryIdentifier = Self.category
        content.sound = silent ? nil : .default
        if let attachment = await attachment(icon: icon, fallback: tab.favicon) { content.attachments = [attachment] }
        // The same tag in the same tab replaces the one before it.
        let key = "\(tab.id.uuidString)|" + (tag.isEmpty ? "id:\(id)" : "tag:\(tag)")
        entries[key] = Entry(tabID: tab.id, origin: origin, id: id, webView: webView, frame: frame, posted: Date())
        trim()
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            return true
        } catch {
            entries[key] = nil
            return false
        }
    }

    // MARK: Extensions

    /// An extension's notification (`chrome.notifications`), titled with its name. Unlike a site's, it shows even
    /// with Zigzag in front: the extension isn't a tab you're looking at.
    func showForExtension(key: String, extensionID: String, name: String, title: String, message: String, context: String?, silent: Bool) async -> Bool {
        guard !AppDelegate.isHostingTests, await authorize() else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.subtitle = name
        content.body = String(([message] + [context].compactMap { $0 }).joined(separator: "\n").prefix(1000))
        content.threadIdentifier = "extension:\(extensionID)"
        content.categoryIdentifier = Self.category
        content.sound = silent ? nil : .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    func clearForExtension(keys: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: keys)
        center.removePendingNotificationRequests(withIdentifiers: keys)
    }

    /// Asks macOS once, the first time a site you've allowed has something to show.
    private func authorize() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        if !started {
            started = true
            center.delegate = self
            let category = UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [], options: [.customDismissAction])
            center.setNotificationCategories([category])
        }
        let settings = await center.notificationSettings()
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional: granted = true
        case .notDetermined: granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: granted = false
        }
        // Turned off in System Settings later: asked again next launch rather than remembered as yes.
        authorized = granted ? nil : false
        return granted
    }

    /// The page's icon (or the site's own), as the picture beside the text.
    private func attachment(icon: URL?, fallback: NSImage?) async -> UNNotificationAttachment? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WebNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data: Data?, type = UTType.png
        // A data: icon is the page's own bytes; one on the web only from a public address (`IconAddress`), as
        // fetched by Zigzag, never from this Mac or its network. Otherwise the site's own icon stands in.
        var fetches = icon?.scheme?.lowercased() == "data"
        if let icon, !fetches { fetches = await IconAddress.mayFetch(icon) }
        if let icon, fetches {
            var request = URLRequest(url: icon, timeoutInterval: 4)
            request.setValue(WebKitSetup.applicationNameForUserAgent, forHTTPHeaderField: "User-Agent")
            if let (bytes, response) = try? await Self.session.data(for: request, delegate: Self.redirects), bytes.count < 4_000_000,
               let mime = response.mimeType, let found = UTType(mimeType: mime), [UTType.png, .jpeg, .gif].contains(found) {
                data = bytes
                type = found
            }
        }
        if data == nil, let fallback, let tiff = fallback.tiffRepresentation {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            type = .png
        }
        guard let data else { return nil }
        let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "png")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: type.identifier])
    }

    /// No cookies or cache: an icon is fetched like a stranger would.
    private static let session = URLSession(configuration: .ephemeral)
    private static let redirects = IconRedirects()

    private func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        keys.forEach { entries[$0] = nil }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: keys)
        center.removePendingNotificationRequests(withIdentifiers: keys)
    }

    /// Notifications from a site you've just turned off go too.
    func removeAll(origin: String) {
        remove(entries.filter { $0.value.origin == origin }.map(\.key))
    }

    private func trim() {
        guard entries.count > 200 else { return }
        let oldest = entries.sorted { $0.value.posted < $1.value.posted }.prefix(entries.count - 200).map(\.key)
        oldest.forEach { entries[$0] = nil }
    }

    // MARK: Answers from macOS

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.identifier
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        await MainActor.run { self.answered(key: key, dismissed: dismissed) }
    }

    /// A click brings its tab forward, wherever it is, then tells the page. Swiping it away just tells the page.
    private func answered(key: String, dismissed: Bool) {
        // An extension's: it decides what a click does.
        if key.hasPrefix(BridgeNotifications.prefix) {
            if #available(macOS 15.4, *) { BridgeNotifications.answered(key: key, dismissed: dismissed) }
            return
        }
        let entry = entries[key]
        entries[key] = nil
        if !dismissed {
            NSApp.activate()
            let tabID = entry?.tabID ?? key.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
            if let tabID, let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.tab(with: tabID) != nil }),
               let tab = controller.tabManager.tab(with: tabID) {
                if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
                controller.window?.makeKeyAndOrderFront(nil)
                controller.tabManager.select(tab)
            }
        }
        guard let entry, let webView = entry.webView else { return }
        webView.callAsyncJavaScript("window.__zigzagNotification && window.__zigzagNotification(id, type)",
                                    arguments: ["id": entry.id, "type": dismissed ? "close" : "click"],
                                    in: entry.frame, in: .page, completionHandler: nil)
    }

    // MARK: Page script

    /// `window.Notification`, the standard shape. Pages call it as they would in Safari or Chrome.
    private static let shim = """
    (() => {
      // Push (notifications while a site is closed) needs a push service Zigzag doesn't have. Saying so up front,
      // as Safari did before it had one, lets a site use ordinary notifications or hide its switch, instead of
      // offering push and then failing ("Couldn't turn on notifications").
      try { delete window.PushManager; } catch (e) {}
      try {
        if (window.ServiceWorkerRegistration) Object.defineProperty(ServiceWorkerRegistration.prototype, 'pushManager', { get() { return undefined; }, configurable: true });
      } catch (e) {}
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      if (!handler || !window.isSecureContext) return;
      const decisions = __DECISIONS__;
      const isPrivate = __PRIVATE__;
      const local = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
      let sameSite = window === window.top;
      if (!sameSite) { try { sameSite = window.top.location.origin === location.origin; } catch (e) {} }
      const usable = sameSite && (location.protocol === 'https:' || (location.protocol === 'http:' && local));
      // Answers are kept per origin (scheme, host and port), as location.origin spells it.
      const origin = location.origin;
      let permission = !usable || isPrivate ? 'denied' : (origin in decisions ? (decisions[origin] ? 'granted' : 'denied') : 'default');
      // A question only follows a click or a key: a page can't ask the moment it opens.
      let lastGesture = 0;
      for (const type of ['pointerdown', 'keydown', 'click']) window.addEventListener(type, (e) => { if (e.isTrusted) lastGesture = Date.now(); }, true);
      const gesture = () => (navigator.userActivation && navigator.userActivation.isActive) || Date.now() - lastGesture < 1000;
      const send = (body) => { try { return Promise.resolve(handler.postMessage(body)); } catch (e) { return Promise.resolve(null); } };
      const live = new Map();
      const page = Math.random().toString(36).slice(2, 10);
      let count = 0;
      const types = ['click', 'close', 'show', 'error'];

      class Notification extends EventTarget {
        #id; #title; #options; #handlers = {};
        constructor(title, options) {
          if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
          super();
          const o = options || {};
          this.#id = page + '-' + (++count);
          this.#title = String(title);
          let icon = '';
          if (o.icon) { try { icon = new URL(String(o.icon), document.baseURI).href; } catch (e) {} }
          this.#options = {
            body: o.body == null ? '' : String(o.body), tag: o.tag == null ? '' : String(o.tag), icon,
            silent: o.silent == null ? null : !!o.silent, data: o.data === undefined ? null : o.data,
            dir: o.dir || 'auto', lang: o.lang || '', badge: o.badge || '', image: o.image || '',
            requireInteraction: !!o.requireInteraction, renotify: !!o.renotify, timestamp: o.timestamp || Date.now()
          };
          for (const type of types) {
            this.addEventListener(type, (e) => { const f = this.#handlers[type]; if (typeof f === 'function') f.call(this, e); });
          }
          if (permission !== 'granted') { setTimeout(() => this.dispatchEvent(new Event('error')), 0); return; }
          const tag = this.#options.tag;
          if (tag) for (const [id, other] of live) if (other.tag === tag) live.delete(id);
          live.set(this.#id, this);
          send({ kind: 'show', id: this.#id, title: this.#title, body: this.#options.body, tag, icon, silent: this.#options.silent === true })
            .then((shown) => {
              if (shown) { this.dispatchEvent(new Event('show')); } else { live.delete(this.#id); this.dispatchEvent(new Event('error')); }
            });
        }
        get title() { return this.#title; }
        get body() { return this.#options.body; }
        get tag() { return this.#options.tag; }
        get icon() { return this.#options.icon; }
        get silent() { return this.#options.silent; }
        get data() { return this.#options.data; }
        get dir() { return this.#options.dir; }
        get lang() { return this.#options.lang; }
        get badge() { return this.#options.badge; }
        get image() { return this.#options.image; }
        get requireInteraction() { return this.#options.requireInteraction; }
        get renotify() { return this.#options.renotify; }
        get timestamp() { return this.#options.timestamp; }
        get actions() { return []; }
        get vibrate() { return []; }
        close() {
          if (!live.delete(this.#id)) return;
          send({ kind: 'close', id: this.#id });
          this.dispatchEvent(new Event('close'));
        }
        static get permission() { return permission; }
        static get maxActions() { return 0; }
        static requestPermission(callback) {
          const ask = permission === 'default' && usable && !isPrivate
            ? send({ kind: 'request', gesture: gesture() }).then((answer) => { if (answer === 'granted' || answer === 'denied' || answer === 'default') permission = answer; return permission; })
            : Promise.resolve(permission);
          return ask.then((answer) => { if (typeof callback === 'function') { try { callback(answer); } catch (e) { setTimeout(() => { throw e; }); } } return answer; });
        }
        get onclick() { return this.#handlers.click || null; }
        set onclick(f) { this.#handlers.click = typeof f === 'function' ? f : null; }
        get onclose() { return this.#handlers.close || null; }
        set onclose(f) { this.#handlers.close = typeof f === 'function' ? f : null; }
        get onshow() { return this.#handlers.show || null; }
        set onshow(f) { this.#handlers.show = typeof f === 'function' ? f : null; }
        get onerror() { return this.#handlers.error || null; }
        set onerror(f) { this.#handlers.error = typeof f === 'function' ? f : null; }
      }
      Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true, enumerable: false });
      // Clicked or swiped away in Notification Center: Zigzag tells the page here.
      Object.defineProperty(window, '__zigzagNotification', {
        value: (id, type) => {
          const n = live.get(id);
          if (!n) return;
          if (type === 'close') live.delete(id);
          n.dispatchEvent(new Event(type, { cancelable: type === 'click' }));
        }
      });
      // Sites that show theirs through a service worker registration get the same notifications.
      if (window.ServiceWorkerRegistration && !ServiceWorkerRegistration.prototype.showNotification) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          if (permission !== 'granted') return Promise.reject(new TypeError('No notification permission has been granted for this origin.'));
          new Notification(title, options);
          return Promise.resolve();
        };
        ServiceWorkerRegistration.prototype.getNotifications = function () { return Promise.resolve([]); };
      }
      // The answer may have changed since this window opened (allowed in another tab): ask for the current one.
      if (usable && !isPrivate) send({ kind: 'state' }).then((state) => { if (state === 'granted' || state === 'denied' || state === 'default') permission = state; });
    })();
    """
}

/// Where Zigzag itself may fetch a notification's icon from. The fetch is Zigzag's, not the page's, so it could go
/// where a page's own requests can't reach unseen: this Mac (localhost), the network it's on (a router's page, a
/// printer), a link-local address. Only http and https to a public address, then, checked for every address the
/// name resolves to, and again for any redirect.
nonisolated enum IconAddress {
    /// Whether `url` may be fetched: http or https, on a host that's a public address or resolves only to them.
    static func mayFetch(_ url: URL) async -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(percentEncoded: false), isPublicName(host) else { return false }
        if let literal = bytes(of: host) { return isPublic(literal) }
        let addresses = await Task.detached { resolve(host) }.value
        return !addresses.isEmpty && addresses.allSatisfy(isPublic)
    }

    /// Names that are this Mac or its own network, whatever they resolve to, are not.
    static func isPublicName(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name != "localhost" else { return false }
        return !["localhost", "local", "internal", "home.arpa"].contains { name.hasSuffix("." + $0) }
    }

    /// Whether an address, as text ("10.0.0.1", "::1"), is a public one. Text that isn't an address is not.
    static func isPublic(_ text: String) -> Bool { bytes(of: text).map(isPublic) ?? false }

    /// The address's bytes, 4 or 16, when the text is one.
    private static func bytes(of text: String) -> [UInt8]? {
        var host = text
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    private static func isPublic(_ a: [UInt8]) -> Bool {
        if a.count == 4 {
            switch (a[0], a[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31): return false
            // Carrier NAT's shared space, and the one kept for testing networks.
            case (100, 64...127), (198, 18...19): return false
            case (192, 0) where a[2] == 0: return false
            // Multicast and the reserved space above it.
            default: return a[0] < 224
            }
        }
        guard a.count == 16 else { return false }
        // An IPv4 address carried in IPv6 (::ffff:a.b.c.d, ::a.b.c.d, 64:ff9b::a.b.c.d, 6to4) is judged as itself;
        // :: and ::1 are this Mac.
        if a[0..<10].allSatisfy({ $0 == 0 }), (a[10] == 0xff && a[11] == 0xff) || (a[10] == 0 && a[11] == 0) {
            if a[10] == 0, a[12..<15].allSatisfy({ $0 == 0 }), a[15] <= 1 { return false }
            return isPublic(Array(a[12..<16]))
        }
        if Array(a[0..<12]) == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(Array(a[12..<16])) }
        if a[0] == 0x20, a[1] == 0x02 { return isPublic(Array(a[2..<6])) }
        // Unique local (fc00::/7), link-local (fe80::/10) and the old site-local (fec0::/10), and multicast.
        if a[0] & 0xfe == 0xfc { return false }
        if a[0] == 0xfe, a[1] & 0x80 == 0x80 { return false }
        return a[0] != 0xff
    }

    /// Every address the name resolves to, as bytes.
    private static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var found: [[UInt8]] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let info = next {
            if let address = info.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    var v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    found.append(withUnsafeBytes(of: &v4) { Array($0) })
                case AF_INET6:
                    var v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    found.append(withUnsafeBytes(of: &v6) { Array($0) })
                default: break
                }
            }
            next = info.pointee.ai_next
        }
        return found
    }
}

/// Follows an icon's redirect only to where the icon itself could have been.
nonisolated final class IconRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); return }
        Task { completionHandler(await IconAddress.mayFetch(url) ? request : nil) }
    }
}
