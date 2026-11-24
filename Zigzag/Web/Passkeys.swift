import Security
import WebKit

/// Passkeys in a third-party Mac browser need Apple's browser passkey entitlement. Released Zigzag has it, so passkeys
/// work as in Safari. The dev build can't (Apple grants it per bundle id): without it, WebKit can only offer a phone
/// over Bluetooth and sign-ins like Google's end on "Something went wrong", so there pages are told there are no
/// passkeys and go straight to a password. A password manager (1Password and the like) brings its own passkeys, so
/// with one on in a normal window, pages are left alone.
///
/// With the entitlement, pages get the script below that keeps one passkey request open at a time. WebKit keeps one
/// request per page and replaces it without cancelling: a sign-in page's waiting offer in its username field
/// (`mediation: 'conditional'`), then a second request from the page, one of its frames or the next page in the tab.
/// macOS allows an app one such request, refuses the new one and never lets go of the old, so every passkey on
/// every site failed until the Mac restarted. The script can go once WebKit cancels the open request itself.
enum Passkeys {
    /// Whether this copy is signed with the passkey entitlement.
    static let available: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
        return (value as? Bool) == true
    }()

    /// Every page's scripts this has been asked about, so turning a password manager on or off reaches them.
    private static let controllers = NSMapTable<WKUserContentController, Profile>.weakToWeakObjects()

    /// `isPrivate`: private windows have no extensions, so no password manager to hand passkeys to. Otherwise it's
    /// the page's own profile that has one or not.
    static func attach(to configuration: WKWebViewConfiguration, isPrivate: Bool, profile: Profile) {
        let controller = configuration.userContentController
        if !controller.userScripts.contains(where: { ($0.source as NSString).hasPrefix(keeperMarker) }) {
            controller.addUserScript(WKUserScript(source: keeper, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let forAIApps = !profile.getsYourData
        // Where a password manager turning on or off changes the answer, it's followed (`refresh`).
        if !available, !isPrivate, !forAIApps { controllers.setObject(profile, forKey: controller) }
        if isShimmed(available: available, isPrivate: isPrivate, forAIApps: forAIApps, managerOn: !isPrivate && passwordManagerOn(in: profile)) {
            install(in: controller)
        }
    }

    /// Whether pages are told there are no passkeys: without the entitlement, unless a password manager brings its
    /// own (a private window has none). Always in AI apps' profile: a passkey needs you there to confirm it.
    nonisolated static func isShimmed(available: Bool, isPrivate: Bool, forAIApps: Bool, managerOn: Bool) -> Bool {
        forAIApps || (!available && (isPrivate || !managerOn))
    }

    /// Puts the shim in or takes it out after a password manager is turned on or off. Pages see it from their next load.
    static func refresh() {
        guard !available else { return }
        for controller in controllers.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            guard let profile = controllers.object(forKey: controller) else { continue }
            let wanted = isShimmed(available: available, isPrivate: false, forAIApps: false, managerOn: passwordManagerOn(in: profile))
            guard has(controller) != wanted else { continue }
            if wanted {
                install(in: controller)
            } else {
                OwnScripts.remove(from: controller, where: isOurs)
            }
        }
    }

    /// Read from what's installed and turned on rather than what's loaded, so pages restored at launch, before
    /// extensions finish loading, already get it right.
    private static func passwordManagerOn(in profile: Profile) -> Bool { PasswordManagers.active(in: profile) != nil }

    private static func has(_ controller: WKUserContentController) -> Bool {
        controller.userScripts.contains(where: isOurs)
    }

    /// By its first line, compared as Foundation does: a page's scripts come to hundreds of kilobytes (#89).
    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(marker) }

    private static func install(in controller: WKUserContentController) {
        guard !has(controller) else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + shim, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    private static let marker = "/* zigzag passkeys */"

    /// WebKit drops `navigator.credentials` once nothing holds it and hands out a new one without what was set on it,
    /// so a password manager's passkey hook (Bitwarden sets `navigator.credentials.get`) vanished mid-page (#344).
    /// Held for the page's life.
    private static let keeperMarker = "/* zigzag credentials keeper */"

    private static let keeper = """
    \(keeperMarker)
    (() => {
      const credentials = navigator.credentials;
      if (credentials) addEventListener('pagehide', () => credentials, { passive: true });
    })();
    """

    private static let shim = """
    (() => {
      try {
        Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true, writable: true });
        const credentials = navigator.credentials;
        if (credentials) {
          const unsupported = () => Promise.reject(new DOMException('Passkeys are not available in this browser.', 'NotSupportedError'));
          for (const name of ['get', 'create']) {
            const original = credentials[name] && credentials[name].bind(credentials);
            if (!original) continue;
            credentials[name] = (options) => options && options.publicKey ? unsupported() : original(options);
          }
        }
      } catch (_) {}
    })();
    """

    // MARK: - One request at a time

    static let messageName = "zigzagPasskeyRequests"

    /// By its first line, as `isOurs`.
    static func isRequests(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(requestsMarker) }

    /// For every page of a copy with the entitlement, and for a page's pop-ups, which share its scripts. The handler
    /// is taken out first: adding one twice under a name raises.
    static func attachRequests(to controller: WKUserContentController) {
        if !controller.userScripts.contains(where: isRequests) { controller.addUserScript(requests) }
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: .page)
        controller.addScriptMessageHandler(Messages.shared, contentWorld: .page, name: messageName)
    }

    /// Ends the waiting passkey requests in every frame of a page, then calls `done`: a page's frames share WebKit's
    /// one request, and a frame's script can only end its own. A frame that is gone or stuck doesn't answer, so
    /// `done` never waits longer than `patience`.
    static func endRequests(in webView: WKWebView, then done: @escaping @MainActor () -> Void) {
        let frames = [nil] + PageFrames.shared.frames(in: webView)
        var unanswered = frames.count
        var isDone = false
        let finish = {
            guard !isDone else { return }
            isDone = true
            done()
        }
        for frame in frames {
            webView.runOwnScript(endCall, in: frame, world: .page) { _ in
                unanswered -= 1
                if unanswered == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { finish() }
    }

    static let patience: TimeInterval = 0.25

    private static let endCall = "window[Symbol.for('zigzag.passkeys')]?.end() ?? false"

    /// A page with frames asks before a passkey request. The page's own world can post this, so nothing in the
    /// message is read: it can only end the waiting requests of the page it came from.
    private final class Messages: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Messages()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            guard let webView = message.webView else {
                replyHandler(nil, nil)
                return
            }
            Passkeys.endRequests(in: webView) { replyHandler(nil, nil) }
        }
    }

    private static let requestsMarker = "/* zigzag passkey requests */"

    /// In the page's own world, where a site asks for passkeys, and in every frame.
    ///
    /// Only the page's abort signal makes WebKit cancel a waiting request properly, and WebKit then holds the next
    /// request until that's done. So a waiting request (a conditional `get`) is started with a signal of the
    /// script's own beside the site's, and aborted before any other passkey request starts, in the same turn, and
    /// when the page is left. A waiting request asked for while a passkey sheet is up starts when the sheet is done:
    /// started over it, the sheet could no longer be closed by the page. Nothing here waits on the page.
    static let requests = WKUserScript(source: """
    \(requestsMarker)
    (() => {
      const KEY = Symbol.for('zigzag.passkeys');
      if (window[KEY]) return;
      // This frame's waiting request, and its passkey sheets (a sheet asked for twice is still one on screen).
      let waiting = null;
      const sheets = new Set();
      const end = () => {
        const controller = waiting;
        if (!controller) return false;
        waiting = null;
        controller.abort();
        return true;
      };
      // In every frame, before anything can return: a frame without passkeys still answers, and can't bring its own.
      try { Object.defineProperty(window, KEY, { value: Object.freeze({ end }) }); } catch (_) { return; }
      const Container = window.CredentialsContainer;
      if (!Container || !Container.prototype) return;
      // Page globals captured before its scripts run, so redefinitions aren't called.
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      const post = handler && handler.postMessage.bind(handler);
      const Controller = window.AbortController, Signal = window.AbortSignal;
      const any = Signal.any.bind(Signal), settled = Promise.allSettled.bind(Promise);
      const apply = Reflect.apply, read = Reflect.get, then = Promise.prototype.then;
      // No frames above or below: nothing else shares this page's request, so there is nobody to ask.
      const alone = () => { try { return window.top === window && window.length === 0; } catch (_) { return false; } };

      const start = (name, target, self, args) => {
        let options, quiet, site;
        try {
          options = args[0];
          quiet = options.mediation === 'conditional';
          if (quiet && name === 'get') site = options.signal;
        } catch (_) {
          end();
          return apply(target, self, args);
        }
        if (quiet && sheets.size) {
          const again = () => start(name, target, self, args);
          return apply(then, settled([...sheets]), [again, again]);
        }
        end();
        if (!quiet) {
          const request = apply(target, self, args);
          const closed = () => { sheets.delete(request); };
          sheets.add(request);
          apply(then, request, [closed, closed]);
          return request;
        }
        // Only a waiting `get` is kept track of. A signal WebKit would refuse anyway is left for it to refuse.
        if (name !== 'get' || (site !== undefined && (!(site instanceof Signal) || site.aborted))) return apply(target, self, args);
        const controller = new Controller();
        const signal = site ? any([site, controller.signal]) : controller.signal;
        // The site's own options, read by WebKit as they are, with the one signal in place of the site's.
        const forwarded = new Proxy(options, {
          get: (object, key) => (key === 'signal' ? signal : key === 'mediation' ? 'conditional' : read(object, key, object)),
        });
        const closed = () => { if (waiting === controller) waiting = null; };
        waiting = controller;
        let request;
        try {
          request = apply(target, self, [forwarded, ...args.slice(1)]);
        } catch (error) {
          closed();
          throw error;
        }
        apply(then, request, [closed, closed]);
        return request;
      };

      for (const name of ['get', 'create']) {
        const described = Object.getOwnPropertyDescriptor(Container.prototype, name);
        if (!described || typeof described.value !== 'function') continue;
        // A Proxy, so get and create still look native to the page.
        described.value = new Proxy(described.value, {
          apply(target, self, args) {
            let passkey = false;
            try { passkey = args[0] != null && args[0].publicKey != null; } catch (_) {}
            if (!passkey) return apply(target, self, args);
            const go = () => start(name, target, self, args);
            if (!post || alone()) return go();
            let asked;
            try { asked = post(null); } catch (_) { return go(); }
            return apply(then, asked, [go, go]);
          },
        });
        Object.defineProperty(Container.prototype, name, described);
      }
      window.addEventListener('pagehide', end, true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}
