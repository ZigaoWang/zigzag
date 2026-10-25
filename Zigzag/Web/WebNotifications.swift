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
        let host: String
        let id: String
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let posted: Date
    }

    private var entries: [String: Entry] = [:]
    /// Sites whose question was put off in a tab (Esc): not asked again there this session.
    private var putOff: Set<String> = []
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
        guard let host = Self.host(of: message.frameInfo, in: webView) else { return (kind == "show" ? false : "denied", nil) }
        switch kind {
        case "state":
            return (permission(host: host, tab: tab), nil)
        case "request":
            let state = permission(host: host, tab: tab)
            guard state == "default", body["gesture"] as? Bool == true, !putOff.contains("\(tab.id)|\(host)") else { return (state, nil) }
            let answer = await SitePermissions.requestNotifications(host: host, window: tab.host?.hostWindow, isPrivate: tab.isPrivate)
            if answer == nil { putOff.insert("\(tab.id)|\(host)") }
            // A private window asks, so the page isn't left waiting, but it still never shows one.
            return (answer.map { $0 && !tab.isPrivate ? "granted" : "denied" } ?? "default", nil)
        case "show":
            guard permission(host: host, tab: tab) == "granted", let id = body["id"] as? String, let title = body["title"] as? String else { return (false, nil) }
            let shown = await show(id: id, title: title, body: body["body"] as? String ?? "", tag: body["tag"] as? String ?? "",
                                   icon: (body["icon"] as? String).flatMap { URL(string: $0) }, silent: body["silent"] as? Bool == true,
                                   host: host, tab: tab, webView: webView, frame: message.frameInfo)
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

    private func permission(host: String, tab: Tab) -> String {
        if tab.isPrivate { return "denied" }
        return SitePermissions.notifications(host: host).map { $0 ? "granted" : "denied" } ?? "default"
    }

    /// The frame's host when it may use notifications: https (or http on this Mac), the page itself or a frame
    /// from the same origin.
    private static func host(of frame: WKFrameInfo, in webView: WKWebView) -> String? {
        let origin = frame.securityOrigin, host = origin.host.lowercased()
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard !host.isEmpty, origin.protocol == "https" || (origin.protocol == "http" && local) else { return nil }
        if frame.isMainFrame { return host }
        guard let page = webView.url, page.scheme == origin.protocol, page.host()?.lowercased() == host else { return nil }
        let standard = origin.protocol == "https" ? 443 : 80
        return (page.port ?? standard) == (origin.port == 0 ? standard : origin.port) ? host : nil
    }

    // MARK: Showing

    private func show(id: String, title: String, body: String, tag: String, icon: URL?, silent: Bool,
                      host: String, tab: Tab, webView: WKWebView, frame: WKFrameInfo) async -> Bool {
        guard !AppDelegate.isHostingTests else { return false }
        // The tab you're looking at already shows what it would say, as in Safari.
        if NSApp.isActive, let controller = WindowManager.shared.keyController, controller.window?.isKeyWindow == true,
           let shown = controller.tabManager.selectedTab, shown === tab || controller.tabManager.partner(of: shown) === tab {
            return true
        }
        guard await authorize() else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.subtitle = host
        content.body = String(body.prefix(1000))
        content.threadIdentifier = host
        content.categoryIdentifier = Self.category
        content.sound = silent ? nil : .default
        if let attachment = await attachment(icon: icon, fallback: tab.favicon) { content.attachments = [attachment] }
        // The same tag in the same tab replaces the one before it.
        let key = "\(tab.id.uuidString)|" + (tag.isEmpty ? "id:\(id)" : "tag:\(tag)")
        entries[key] = Entry(tabID: tab.id, host: host, id: id, webView: webView, frame: frame, posted: Date())
        trim()
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            return true
        } catch {
            entries[key] = nil
            return false
        }
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
        if let icon, ["https", "http", "data"].contains(icon.scheme ?? "") {
            var request = URLRequest(url: icon, timeoutInterval: 4)
            request.setValue(WebKitSetup.applicationNameForUserAgent, forHTTPHeaderField: "User-Agent")
            if let (bytes, response) = try? await Self.session.data(for: request), bytes.count < 4_000_000,
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

    private func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        keys.forEach { entries[$0] = nil }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: keys)
        center.removePendingNotificationRequests(withIdentifiers: keys)
    }

    /// Notifications from a site you've just turned off go too.
    func removeAll(host: String) {
        remove(entries.filter { $0.value.host == host }.map(\.key))
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
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      if (!handler || !window.isSecureContext) return;
      const decisions = __DECISIONS__;
      const isPrivate = __PRIVATE__;
      const local = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
      let sameSite = window === window.top;
      if (!sameSite) { try { sameSite = window.top.location.origin === location.origin; } catch (e) {} }
      const usable = sameSite && (location.protocol === 'https:' || (location.protocol === 'http:' && local));
      const host = location.hostname.toLowerCase();
      let permission = !usable || isPrivate ? 'denied' : (host in decisions ? (decisions[host] ? 'granted' : 'denied') : 'default');
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
